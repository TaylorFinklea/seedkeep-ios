#if canImport(CloudKit)
import CloudKit
import Foundation
import OSLog

/// Seedkeep household zone CKSyncEngine driver.
///
/// Adapted from SimmerSmith's HouseholdSyncEngine with:
///   - Log subsystem: `app.seedkeep.cloud` (spec requirement)
///   - Container id: `iCloud.app.seedkeep`
///   - Merger seam wired to SeedkeepRecordMerger (Seed + JournalChecklistItem custom rules)
///
/// One CKSyncEngine per household zone (owner's private DB; participants' shared DB).
/// Two stacks racing the change token would fork the household — this driver owns the
/// single stack for a given zone.
///
/// `automaticSync` is configurable, and BOTH production factories pass `false`
/// (`HouseholdCloudCoordinator.live` / `.participant`): the coordinator drives `fetchChanges()` and
/// `sendUntilDrained(maxPasses:)` explicitly, so no delegate event can fire before it has wired the
/// merger and callbacks. Pass `true` only for a driver that wants CloudKit's own scheduling.
public enum SyncEngineError: Error {
    /// `sendUntilDrained` ran its full budget with record changes still pending (a conflict storm or
    /// a persistent failure). Thrown so the caller treats the pass as incomplete, not a false success.
    case drainIncomplete
    /// The coordinator retired this engine generation at an account/garden boundary.
    case accountInvalidated
    /// SwiftData rejected a fetched/sent projection; durable CKSyncEngine state was not advanced.
    case projectionFailed
}

public final class HouseholdSyncEngine: CKSyncEngineDelegate, HouseholdRecordSyncing, @unchecked Sendable {
    enum DeleteFailureDisposition: Equatable {
        case confirmedAbsent
        case retry
        case surface
    }

    static func deleteFailureDisposition(for code: CKError.Code) -> DeleteFailureDisposition {
        switch code {
        case .unknownItem, .zoneNotFound, .userDeletedZone:
            return .confirmedAbsent
        case .batchRequestFailed, .zoneBusy, .serviceUnavailable,
             .requestRateLimited, .networkFailure, .networkUnavailable, .serverResponseLost:
            return .retry
        default:
            return .surface
        }
    }

    public let database: CKDatabase
    public let zoneID: CKRecordZone.ID
    public let store: HouseholdLocalStore
    private let stateURL: URL
    private let log = Logger(subsystem: "app.seedkeep.cloud", category: "HouseholdSync")

    /// The live CKSyncEngine generation + its staged-zone bit. Private to the holder, so no
    /// delegate task can read them outside its lock (see `EngineGeneration`). Implicitly unwrapped
    /// only because CKSyncEngine.Configuration needs `self` as its delegate: assigned exactly once,
    /// on the last line of `init`, and never reassigned.
    private var generation: EngineGeneration<CKSyncEngine>!
    private let automaticSync: Bool

    /// Optional field-merger. When set, records whose type it `handles` are field-merged
    /// at the fetch + serverRecordChanged seams instead of blanket LWW.
    ///
    /// `merger` + the two callbacks below are lock-guarded. The live CKSyncEngine and its
    /// staged-zone bit are not stored here at all: `EngineGeneration` owns them and hands them out
    /// only inside its lock, and delegate-driven code operates on the instance `handleEvent`
    /// already validated. Failure counters, the projection checkpoint, and the trace each carry
    /// their own lock; `store` enforces its own. Those boundaries justify the explicit
    /// `@unchecked Sendable` required by CKSyncEngineDelegate's concurrent callbacks.
    private let callbackLock = NSLock()
    private var _merger: RecordMerger?
    private var _onFetchedChanges: (@Sendable ([CKRecord], [CKRecord.ID]) async throws -> Void)?
    private var _onAccountChange: ((HouseholdAccountChange) -> Void)?

    public var merger: RecordMerger? {
        get { callbackLock.lock(); defer { callbackLock.unlock() }; return _merger }
        set { callbackLock.lock(); _merger = newValue; callbackLock.unlock() }
    }

    /// Fired after a fetched batch is reconciled into the local store (and after a SENT batch's
    /// saved records land), with the records actually applied + the deletion IDs. CKSyncEngine
    /// awaits this callback before accepting a later state checkpoint, so durable state cannot
    /// advance past a failed SwiftData projection.
    public var onFetchedChanges: (@Sendable ([CKRecord], [CKRecord.ID]) async throws -> Void)? {
        get { callbackLock.withLock { _onFetchedChanges } }
        set { callbackLock.withLock { _onFetchedChanges = newValue } }
    }

    /// Fired on an iCloud account transition (mapped to the app-level kind) so the coordinator
    /// can wipe SwiftData (AC5). Called in addition to the engine's own `store.removeAll()`.
    public var onAccountChange: ((HouseholdAccountChange) -> Void)? {
        get { callbackLock.lock(); defer { callbackLock.unlock() }; return _onAccountChange }
        set { callbackLock.lock(); _onAccountChange = newValue; callbackLock.unlock() }
    }

    private let traceLock = NSLock()
    private var trace: [String] = []
    /// Diagnostic trace of sync events (used by deterministic tests).
    public var eventTrace: [String] {
        traceLock.lock(); defer { traceLock.unlock() }
        return trace
    }
    private func note(_ s: String) {
        traceLock.lock(); trace.append(s); traceLock.unlock()
    }

    public init(
        database: CKDatabase,
        zoneID: CKRecordZone.ID,
        store: HouseholdLocalStore,
        stateURL: URL,
        automaticSync: Bool = false
    ) {
        self.database = database
        self.zoneID   = zoneID
        self.store    = store
        self.stateURL = stateURL
        self.automaticSync = automaticSync

        var configuration = CKSyncEngine.Configuration(
            database: database,
            stateSerialization: Self.loadState(from: stateURL),
            delegate: self)
        configuration.automaticallySync = automaticSync
        self.generation = EngineGeneration(CKSyncEngine(configuration))
    }

    // MARK: - Public mutation API

    private func makeSyncEngine(stateSerialization: CKSyncEngine.State.Serialization?) -> CKSyncEngine {
        var configuration = CKSyncEngine.Configuration(
            database: database,
            stateSerialization: stateSerialization,
            delegate: self)
        configuration.automaticallySync = automaticSync
        return CKSyncEngine(configuration)
    }

    /// Stage a record save: write it locally, then tell the engine it's pending.
    /// The zone is created lazily on the first save.
    public func save(_ record: CKRecord) {
        generation.withLive { engine, zoneStaged in
            store.setRecord(record)
            if !zoneStaged {
                engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
                zoneStaged = true
            }
            engine.state.add(pendingRecordZoneChanges: [.saveRecord(record.recordID)])
        }
    }

    public func delete(_ recordID: CKRecord.ID) {
        generation.withLive { engine, _ in
            store.removeRecord(recordID)
            engine.state.add(pendingRecordZoneChanges: [.deleteRecord(recordID)])
        }
    }

    /// Delete a record AND sweep its local CASCADE subtree (G5: CloudKit's `.deleteSelf`
    /// only fires on the deleting device; client must enqueue child deletes itself).
    public func deleteCascading(_ recordID: CKRecord.ID) {
        deleteCascading(recordID, visited: [])
    }

    private func deleteCascading(_ recordID: CKRecord.ID, visited: Set<String>) {
        guard !visited.contains(recordID.recordName) else { return }
        var visited = visited
        visited.insert(recordID.recordName)
        for childID in store.recordIDsCascadingFrom(recordID.recordName) {
            deleteCascading(childID, visited: visited)
        }
        delete(recordID)
    }

    /// Pull remote changes. Throws `.projectionFailed` (after rewinding this engine to its last
    /// durable serialization) if SwiftData refused the fetched batch — even when the CloudKit
    /// operation ITSELF also failed — so the caller never treats an unapplied batch as delivered.
    public func fetchChanges() async throws {
        let engine = try currentActiveEngine()
        if let operationError = try await runCheckpointedPass(on: engine, { try await engine.fetchChanges() }) {
            throw operationError
        }
    }

    /// Push staged changes once. Symmetric with `fetchChanges()`: a SENT batch's projection (the
    /// merged `serverRecordChanged` result) is the last chance to land that merge locally, so a
    /// refused projection throws here too rather than reporting a clean push.
    public func sendChanges() async throws {
        let engine = try currentActiveEngine()
        if let operationError = try await runCheckpointedPass(on: engine, { try await engine.sendChanges() }) {
            throw operationError
        }
    }

    public var hasPendingRecordChanges: Bool {
        generation.withLive { engine, _ in !engine.state.pendingRecordZoneChanges.isEmpty } ?? false
    }

    /// Discard the outbound state that was staged for an account or shared-garden scope that is no
    /// longer active. The coordinator has already erased its SwiftData source rows, so retaining these
    /// IDs would let a later drain send deletes or saves into the replacement account.
    public func discardPendingChanges() {
        _ = retirePendingChanges(originatingFrom: nil)
    }

    public func activateForCurrentAccount() { generation.reactivate() }

    private func currentActiveEngine() throws -> CKSyncEngine {
        guard let engine = generation.current() else {
            throw SyncEngineError.accountInvalidated
        }
        return engine
    }

    private func ensureCurrent(_ engine: CKSyncEngine) throws {
        guard generation.isCurrent(engine) else {
            throw SyncEngineError.accountInvalidated
        }
    }

    @discardableResult
    private func retirePendingChanges(originatingFrom origin: CKSyncEngine?) -> Bool {
        let retired = generation.replaceLive(
            origin: origin,
            retire: true,
            // A delegate event from the retiring engine can arrive after its queue was cleared.
            // Replacing the generation makes every such callback inert.
            drain: { retiring in
                retiring.state.remove(pendingRecordZoneChanges: retiring.state.pendingRecordZoneChanges)
                retiring.state.remove(pendingDatabaseChanges: retiring.state.pendingDatabaseChanges)
            },
            make: { self.makeSyncEngine(stateSerialization: nil) })
        guard retired else { return false }
        failLock.lock()
        attemptCounts.removeAll()
        surfacedFailure = nil
        failLock.unlock()
        return true
    }

    /// Send repeatedly until nothing is pending (G11: a serverRecordChanged re-enqueues
    /// a merged save; stopping on the throw loses it). Backs off between thrown passes honoring
    /// CloudKit's retry-after hint (rate-limit / service-unavailable / zone-busy). THROWS if the
    /// budget is exhausted with changes still pending, so the caller does NOT report a false success
    /// or advance its watermark past records CloudKit never confirmed.
    public func sendUntilDrained(maxPasses: Int = 6) async throws {
        let engine = try currentActiveEngine()
        failLock.withLock { surfacedFailure = nil }
        var lastError: Error?
        for pass in 0..<maxPasses {
            // A SENT batch's SwiftData projection is the LAST place a merged serverRecordChanged
            // result can land — this device never re-fetches records it authored — so a refused
            // projection throws out of the drain instead of letting the caller mark those records
            // synced, whether or not the send itself also failed.
            let passError = try await runCheckpointedPass(on: engine, { try await engine.sendChanges() })
            if let passError { lastError = passError }
            // A permanent per-record failure is reported via the .sentRecordZoneChanges event
            // (processed during sendChanges, NOT thrown) — surface it instead of a false success.
            if let surfaced = takeSurfacedFailure() { throw surfaced }
            let pending = hasPendingChanges(on: engine)
            if let passError {
                if !pending { throw passError }
                if pass < maxPasses - 1 {
                    let hint = (passError as? CKError)?.retryAfterSeconds ?? 0.5
                    let delay = min(max(0, hint), 2)   // cap so a foreground sync can't hang for long
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
                continue
            }
            if !pending { return }
        }
        try ensureCurrent(engine)
        if let surfaced = takeSurfacedFailure() { throw surfaced }
        if hasPendingChanges(on: engine) {
            log.error("sendUntilDrained exhausted \(maxPasses, privacy: .public) passes — record changes STILL pending")
            throw lastError ?? SyncEngineError.drainIncomplete
        }
    }

    private func hasPendingChanges(on engine: CKSyncEngine) -> Bool {
        generation.withCurrent(engine) { !$0.state.pendingRecordZoneChanges.isEmpty } ?? false
    }

    // MARK: - CKSyncEngineDelegate

    public func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        guard let pending = generation.withCurrent(syncEngine, { engine in
            engine.state.pendingRecordZoneChanges.filter { context.options.scope.contains($0) }
        }), !pending.isEmpty else { return nil }
        let batch = await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pending) { recordID in
            self.store.record(for: recordID)
        }
        guard generation.isCurrent(syncEngine) else { return nil }
        return batch
    }

    public func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        if case .accountChange(let change) = event {
            handleAccountChange(change, originatingFrom: syncEngine)
            return
        }
        guard generation.isCurrent(syncEngine) else { return }
        await handleCurrentEvent(event, syncEngine: syncEngine)
    }

    private func handleCurrentEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        switch event {
        case .stateUpdate(let update):
            // Suppressed while this pass is poisoned: a cursor persisted past a batch SwiftData
            // refused would strand that batch forever.
            checkpoint.persistCheckpoint { Self.saveState(update.stateSerialization, to: stateURL) }

        case .fetchedRecordZoneChanges(let changes):
            let pendingSaves = pendingSaveIDs(on: syncEngine)
            // Collect the records ACTUALLY applied this batch (post-merge; local-pending skips
            // excluded) + the deletion IDs, then hand them to the coordinator for SwiftData
            // projection. A skipped (local-pending) mod must NOT reach SwiftData either — local wins.
            var applied: [CKRecord] = []
            var deletedIDs: [CKRecord.ID] = []
            for modification in changes.modifications {
                let remote = modification.record
                let hasPendingEdit = pendingSaves.contains(remote.recordID)
                if hasPendingEdit, let merger, merger.handles(remote.recordType),
                   let local = store.record(for: remote.recordID) {
                    let result = merger.resolve(local: local, remote: remote)
                    if let ckRecord = result.record as? CKRecord {
                        store.setRecord(ckRecord)
                        applied.append(ckRecord)
                        if result.needsResave {
                            syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(ckRecord.recordID)])
                        }
                    }
                    note("merged fetched \(remote.recordID.recordName) resave=\(result.needsResave)")
                    continue
                }
                if hasPendingEdit {
                    note("skip fetched mod (local pending) \(remote.recordID.recordName)")
                    continue
                }
                store.applyRemoteModification(remote)
                applied.append(remote)
                note("fetched mod \(remote.recordID.recordName)")
            }
            for deletion in changes.deletions {
                store.removeRecord(deletion.recordID)
                deletedIDs.append(deletion.recordID)
                note("fetched del \(deletion.recordID.recordName)")
            }
            await checkpoint.project(applied, deletedIDs, via: onFetchedChanges)

        case .sentRecordZoneChanges(let sent):
            var saved: [CKRecord] = []
            for record in sent.savedRecords {
                store.setRecord(record)
                saved.append(record)
                clearAttempts(record.recordID)   // confirmed → reset its re-enqueue counter
                note("saved \(record.recordID.recordName)")
            }
            for failure in sent.failedRecordSaves {
                note("FAILED \(failure.record.recordID.recordName) code=\(failure.error.code.rawValue)")
                handleFailedSave(failure, on: syncEngine)
            }
            for recordID in sent.deletedRecordIDs {
                store.removeRecord(recordID)
                clearAttempts(recordID)
                note("deleted \(recordID.recordName)")
            }
            for (recordID, error) in sent.failedRecordDeletes {
                note("FAILED DELETE \(recordID.recordName) code=\(error.code.rawValue)")
                handleFailedDelete(recordID, error: error, on: syncEngine)
            }
            // Project the SAVED records back to SwiftData. For a serverRecordChanged conflict, the
            // re-saved record IS the merged result (packetCount-min / tagIDs-union / sticky-deletedAt)
            // produced in handleFailedSave — without this, the editing device's SwiftData keeps its
            // pre-merge values forever (it authored the last write, so it never re-fetches them).
            await checkpoint.project(saved, [], via: onFetchedChanges)

        case .accountChange:
            break

        case .willFetchChanges, .didFetchChanges,
             .willSendChanges, .didSendChanges,
             .fetchedDatabaseChanges, .sentDatabaseChanges,
             .willFetchRecordZoneChanges, .didFetchRecordZoneChanges:
            break

        @unknown default:
            break
        }
    }

    /// Shared fetch/send durable-checkpoint policy — see `ProjectionCheckpointGate`.
    private let checkpoint = ProjectionCheckpointGate()

    /// Drive one checkpointed pass over `engine`. Returns the CloudKit operation's own error (the
    /// caller decides whether it is retryable); throws `.projectionFailed` — after rewinding this
    /// engine to the last serialization on disk, so CloudKit re-delivers a fetched batch — when the
    /// SwiftData projection was refused, even if the operation ALSO failed. The rewind mirrors
    /// `retirePendingChanges`, including resetting the staged-zone bit: a rebuilt engine carries no
    /// staged `.saveZone`.
    private func runCheckpointedPass(
        on engine: CKSyncEngine,
        _ operation: () async throws -> Void
    ) async throws -> Error? {
        try await checkpoint.runPass(
            operation: operation,
            validate: { try self.ensureCurrent(engine) },
            rollback: {
                self.generation.replaceLive(
                    origin: engine,
                    retire: false,
                    drain: { _ in },
                    make: { self.makeSyncEngine(stateSerialization: Self.loadState(from: self.stateURL)) })
            })
    }

    /// `engine` is the instance `handleEvent` validated as current; the live generation is private to
    /// `EngineGeneration`, so there is no shared property here for a delegate task to race on.
    private func pendingSaveIDs(on engine: CKSyncEngine) -> Set<CKRecord.ID> {
        var ids = Set<CKRecord.ID>()
        for change in engine.state.pendingRecordZoneChanges {
            if case .saveRecord(let id) = change { ids.insert(id) }
        }
        return ids
    }

    // MARK: - Conflict + failure handling

    /// Per-record re-enqueue attempt counter + the worst PERMANENT failure observed during the current
    /// drain. Lock-guarded — `handleFailedSave` runs on CKSyncEngine's delegate task, off the actor.
    private let failLock = NSLock()
    private var attemptCounts: [String: Int] = [:]
    private var surfacedFailure: CKError?
    /// Cap on per-record re-enqueues, so a persistently-failing record can't poison every future sync
    /// (it's surfaced + dropped instead). Reset on a confirmed save / account change / relaunch.
    private static let maxReEnqueues = 5

    private func clearAttempts(_ recordID: CKRecord.ID) {
        failLock.lock(); attemptCounts[recordID.recordName] = nil; failLock.unlock()
    }
    /// Re-enqueue a save, but give up + surface (as permanent) after `maxReEnqueues` attempts, so a
    /// record that keeps failing for the same reason can't loop the drain across every sync forever.
    private func reEnqueue(_ recordID: CKRecord.ID, after error: CKError, on engine: CKSyncEngine) {
        failLock.lock()
        let n = (attemptCounts[recordID.recordName] ?? 0) + 1
        attemptCounts[recordID.recordName] = n
        failLock.unlock()
        if n <= Self.maxReEnqueues {
            engine.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
        } else {
            log.error("giving up on \(recordID.recordName, privacy: .public) after \(n, privacy: .public) re-enqueues: \(error, privacy: .public)")
            surface(error)
            clearAttempts(recordID)
        }
    }
    private func reEnqueueDelete(_ recordID: CKRecord.ID, after error: CKError, on engine: CKSyncEngine) {
        failLock.lock()
        let n = (attemptCounts[recordID.recordName] ?? 0) + 1
        attemptCounts[recordID.recordName] = n
        failLock.unlock()
        if n <= Self.maxReEnqueues {
            engine.state.add(pendingRecordZoneChanges: [.deleteRecord(recordID)])
        } else {
            log.error("giving up deleting \(recordID.recordName, privacy: .public) after \(n, privacy: .public) re-enqueues: \(error, privacy: .public)")
            surface(error)
            clearAttempts(recordID)
        }
    }
    /// Record a permanent failure so `sendUntilDrained` surfaces it (false-success otherwise — the
    /// record is already dropped from CloudKit's pending set, so the drain would report clean).
    private func surface(_ error: CKError) {
        failLock.lock(); if surfacedFailure == nil { surfacedFailure = error }; failLock.unlock()
    }
    private func takeSurfacedFailure() -> CKError? {
        failLock.lock(); defer { surfacedFailure = nil; failLock.unlock() }
        return surfacedFailure
    }

    private func handleFailedSave(
        _ failure: CKSyncEngine.Event.SentRecordZoneChanges.FailedRecordSave,
        on engine: CKSyncEngine
    ) {
        let recordID = failure.record.recordID
        switch failure.error.code {
        case .serverRecordChanged:
            if let serverRecord = failure.error.serverRecord {
                var shouldResave = true
                if let merger, merger.handles(serverRecord.recordType) {
                    let result = merger.resolve(local: failure.record, remote: serverRecord)
                    guard let ckRecord = result.record as? CKRecord else {
                        // Merger returned a non-CKRecord — must not happen; don't re-enqueue a
                        // stale record (that would loop on serverRecordChanged forever).
                        log.error("merge produced non-CKRecord for \(recordID.recordName, privacy: .public)")
                        return
                    }
                    store.setRecord(ckRecord)
                    shouldResave = result.needsResave   // only push back when the merge changed something
                } else if let local = store.record(for: recordID) {
                    // No merger for this type: local-wins LWW onto a COPY (never mutate the
                    // framework's serverRecord in place — same aliasing hazard the merger avoids).
                    let merged = serverRecord.copy() as! CKRecord
                    for key in local.allKeys() { merged[key] = local[key] }
                    store.setRecord(merged)
                } else {
                    // No local copy: adopt the server's record as-is; nothing to push back.
                    store.setRecord(serverRecord)
                    shouldResave = false
                }
                if shouldResave { reEnqueue(recordID, after: failure.error, on: engine) }
            } else {
                // serverRecordChanged with no attached serverRecord (uncommon). Re-enqueue (capped) so a
                // later pass re-attempts; the cap stops a persistent nil-serverRecord from poisoning sync.
                reEnqueue(recordID, after: failure.error, on: engine)
            }
        case .zoneNotFound, .userDeletedZone:
            engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
            reEnqueue(recordID, after: failure.error, on: engine)
        case .unknownItem:
            store.removeRecord(recordID)
            clearAttempts(recordID)
        // Retriable / collateral failures: CKSyncEngine reports a record ONCE in failedRecordSaves and
        // drops it from pending — so we MUST re-enqueue or the local edit never reaches CloudKit.
        // `.batchRequestFailed` is routine (a sibling in the same atomic batch conflicted). All clear on
        // a backed-off retry (sendUntilDrained); the cap stops a stuck one from looping forever.
        case .batchRequestFailed, .zoneBusy, .serviceUnavailable,
             .requestRateLimited, .networkFailure, .networkUnavailable, .serverResponseLost:
            reEnqueue(recordID, after: failure.error, on: engine)
        default:
            // Genuinely permanent (serverRejectedRequest / invalidArguments / permissionFailure /
            // quotaExceeded / …) — re-enqueueing would loop. Drop + SURFACE so the drain reports it as a
            // real error instead of a false success, and the watermark doesn't advance past it.
            log.error("save permanently failed for \(recordID.recordName, privacy: .public): \(failure.error, privacy: .public)")
            surface(failure.error)
            clearAttempts(recordID)
        }
    }

    private func handleFailedDelete(_ recordID: CKRecord.ID, error: CKError, on engine: CKSyncEngine) {
        switch Self.deleteFailureDisposition(for: error.code) {
        case .confirmedAbsent:
            store.removeRecord(recordID)
            clearAttempts(recordID)
        case .retry:
            reEnqueueDelete(recordID, after: error, on: engine)
        case .surface:
            log.error("delete permanently failed for \(recordID.recordName, privacy: .public): \(error, privacy: .public)")
            surface(error)
            clearAttempts(recordID)
        }
    }

    private func handleAccountChange(
        _ change: CKSyncEngine.Event.AccountChange,
        originatingFrom engine: CKSyncEngine
    ) {
        switch change.changeType {
        case .signOut:
            guard retirePendingChanges(originatingFrom: engine) else { return }
            store.removeAll()
            onAccountChange?(.signOut)
        case .switchAccounts:
            guard retirePendingChanges(originatingFrom: engine) else { return }
            store.removeAll()
            onAccountChange?(.switchAccounts)
        case .signIn:
            guard generation.isCurrent(engine) else { return }
            onAccountChange?(.signIn)
        @unknown default:
            break
        }
    }

    // MARK: - State persistence

    private static func loadState(from url: URL) -> CKSyncEngine.State.Serialization? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: data)
    }

    private static func saveState(_ serialization: CKSyncEngine.State.Serialization, to url: URL) {
        guard let data = try? JSONEncoder().encode(serialization) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
#endif
