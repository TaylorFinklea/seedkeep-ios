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

    private var syncEngine: CKSyncEngine!
    private let automaticSync: Bool
    private let lifecycleGate = HouseholdEngineLifecycleGate()
    private var zoneEnsured = false

    /// Optional field-merger. When set, records whose type it `handles` are field-merged
    /// at the fetch + serverRecordChanged seams instead of blanket LWW.
    ///
    /// `merger` + the two callbacks below are lock-guarded. Every read AND write of the `syncEngine`
    /// / `zoneEnsured` pair happens inside `lifecycleGate`; delegate-driven code never re-reads
    /// `self.syncEngine` — it operates on the instance `handleEvent` already validated and passes
    /// down. Failure counters, the projection checkpoint, and the trace each carry their own lock;
    /// `store` enforces its own. Those boundaries justify the explicit `@unchecked Sendable` required
    /// by CKSyncEngineDelegate's concurrent callbacks.
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
        self.syncEngine = CKSyncEngine(configuration)
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
        lifecycleGate.withActive {
            store.setRecord(record)
            if !zoneEnsured {
                syncEngine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
                zoneEnsured = true
            }
            syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(record.recordID)])
        }
    }

    public func delete(_ recordID: CKRecord.ID) {
        lifecycleGate.withActive {
            store.removeRecord(recordID)
            syncEngine.state.add(pendingRecordZoneChanges: [.deleteRecord(recordID)])
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
    /// durable serialization) if SwiftData refused the fetched batch, so the caller never treats an
    /// unapplied batch as delivered.
    public func fetchChanges() async throws {
        let engine = try currentActiveEngine()
        checkpoint.beginPass()
        try await engine.fetchChanges()
        try ensureCurrent(engine)
        try finishCheckpointPass(on: engine)
    }

    /// Push staged changes once. Symmetric with `fetchChanges()`: a SENT batch's projection (the
    /// merged `serverRecordChanged` result) is the last chance to land that merge locally, so a
    /// refused projection throws here too rather than reporting a clean push.
    public func sendChanges() async throws {
        let engine = try currentActiveEngine()
        checkpoint.beginPass()
        try await engine.sendChanges()
        try ensureCurrent(engine)
        try finishCheckpointPass(on: engine)
    }

    public var hasPendingRecordChanges: Bool {
        lifecycleGate.withActive { !syncEngine.state.pendingRecordZoneChanges.isEmpty } ?? false
    }

    /// Discard the outbound state that was staged for an account or shared-garden scope that is no
    /// longer active. The coordinator has already erased its SwiftData source rows, so retaining these
    /// IDs would let a later drain send deletes or saves into the replacement account.
    public func discardPendingChanges() {
        _ = retirePendingChanges(originatingFrom: nil)
    }

    public func activateForCurrentAccount() { lifecycleGate.activate() }

    private func currentActiveEngine() throws -> CKSyncEngine {
        guard let engine = lifecycleGate.withActive({ syncEngine! }) else {
            throw SyncEngineError.accountInvalidated
        }
        return engine
    }

    private func ensureCurrent(_ engine: CKSyncEngine) throws {
        guard lifecycleGate.withActive({ engine === syncEngine }) == true else {
            throw SyncEngineError.accountInvalidated
        }
    }

    @discardableResult
    private func retirePendingChanges(originatingFrom origin: CKSyncEngine?) -> Bool {
        lifecycleGate.retireIfActive(
            when: { origin == nil || origin === self.syncEngine },
            perform: {
                let retiringEngine = self.syncEngine!
                retiringEngine.state.remove(
                    pendingRecordZoneChanges: retiringEngine.state.pendingRecordZoneChanges)
                retiringEngine.state.remove(
                    pendingDatabaseChanges: retiringEngine.state.pendingDatabaseChanges)
                // A delegate event from the retiring engine can arrive after its queue was cleared.
                // Replacing the engine plus the lifecycle gate makes every such callback inert.
                self.syncEngine = self.makeSyncEngine(stateSerialization: nil)
                self.zoneEnsured = false
                self.failLock.lock()
                self.attemptCounts.removeAll()
                self.surfacedFailure = nil
                self.failLock.unlock()
            })
    }

    /// Send repeatedly until nothing is pending (G11: a serverRecordChanged re-enqueues
    /// a merged save; stopping on the throw loses it). Backs off between thrown passes honoring
    /// CloudKit's retry-after hint (rate-limit / service-unavailable / zone-busy). THROWS if the
    /// budget is exhausted with changes still pending, so the caller does NOT report a false success
    /// or advance its watermark past records CloudKit never confirmed.
    public func sendUntilDrained(maxPasses: Int = 6) async throws {
        let engine = try currentActiveEngine()
        failLock.withLock { surfacedFailure = nil }
        checkpoint.beginPass()
        var lastError: Error?
        for pass in 0..<maxPasses {
            var passError: Error?
            do {
                try await engine.sendChanges()
            } catch {
                passError = error
                lastError = error
            }
            try ensureCurrent(engine)
            // A SENT batch's SwiftData projection is the LAST place a merged serverRecordChanged
            // result can land — this device never re-fetches records it authored — so a refused
            // projection aborts the drain instead of letting the caller mark those records synced.
            try finishCheckpointPass(on: engine)
            // A permanent per-record failure is reported via the .sentRecordZoneChanges event
            // (processed during sendChanges, NOT thrown) — surface it instead of a false success.
            if let surfaced = takeSurfacedFailure() { throw surfaced }
            let pending = lifecycleGate.withActive {
                engine === syncEngine && !engine.state.pendingRecordZoneChanges.isEmpty
            } ?? false
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
        try finishCheckpointPass(on: engine)
        if let surfaced = takeSurfacedFailure() { throw surfaced }
        let pending = lifecycleGate.withActive {
            engine === syncEngine && !engine.state.pendingRecordZoneChanges.isEmpty
        } ?? false
        if pending {
            log.error("sendUntilDrained exhausted \(maxPasses, privacy: .public) passes — record changes STILL pending")
            throw lastError ?? SyncEngineError.drainIncomplete
        }
    }

    // MARK: - CKSyncEngineDelegate

    public func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        guard let pending = lifecycleGate.withActive({
            guard syncEngine === self.syncEngine else { return [CKSyncEngine.PendingRecordZoneChange]() }
            return syncEngine.state.pendingRecordZoneChanges.filter {
                context.options.scope.contains($0)
            }
        }), !pending.isEmpty else { return nil }
        let batch = await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pending) { recordID in
            self.store.record(for: recordID)
        }
        guard lifecycleGate.withActive({ syncEngine === self.syncEngine }) == true else { return nil }
        return batch
    }

    public func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        if case .accountChange(let change) = event {
            handleAccountChange(change, originatingFrom: syncEngine)
            return
        }
        guard lifecycleGate.withActive({ syncEngine === self.syncEngine }) == true else { return }
        await handleCurrentEvent(event, syncEngine: syncEngine)
    }

    private func handleCurrentEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        switch event {
        case .stateUpdate(let update):
            guard checkpoint.allowsDurableCheckpoint else { return }
            Self.saveState(update.stateSerialization, to: stateURL)

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

    /// Close a driven pass. When a batch's SwiftData projection failed, rewind this engine to the
    /// last serialization on disk (so CloudKit re-delivers a fetched batch) and throw, so the caller
    /// records no false success. Mirrors `retirePendingChanges`' rebuild — including clearing
    /// `zoneEnsured`, because the rebuilt engine carries no staged `.saveZone`.
    private func finishCheckpointPass(on engine: CKSyncEngine) throws {
        try checkpoint.finishPass {
            _ = lifecycleGate.withActive {
                guard engine === syncEngine else { return }
                syncEngine = makeSyncEngine(stateSerialization: Self.loadState(from: stateURL))
                zoneEnsured = false
            }
        }
    }

    /// `engine` is the instance `handleEvent` validated against `syncEngine` under `lifecycleGate`;
    /// re-reading `self.syncEngine` here would be an unsynchronized read of a property a concurrent
    /// account retirement writes.
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
            guard lifecycleGate.withActive({ engine === syncEngine }) == true else { return }
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

/// Serializes the narrow synchronous boundary where an account event retires one CKSyncEngine and
/// the coordinator later rearms its replacement. No lock is held across an `await`.
final class HouseholdEngineLifecycleGate: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true

    @discardableResult
    func withActive<T>(_ body: () -> T) -> T? {
        lock.lock()
        defer { lock.unlock() }
        guard active else { return nil }
        return body()
    }

    @discardableResult
    func retireIfActive(when predicate: () -> Bool, perform: () -> Void) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard active, predicate() else { return false }
        active = false
        perform()
        return true
    }

    func activate() {
        lock.lock()
        active = true
        lock.unlock()
    }
}
#endif
