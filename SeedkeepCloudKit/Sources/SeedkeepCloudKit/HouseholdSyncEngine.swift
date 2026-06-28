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
/// `automaticSync` is configurable: tests drive `sync()` manually for determinism;
/// the app turns automatic sync on.
public final class HouseholdSyncEngine: CKSyncEngineDelegate, HouseholdRecordSyncing {
    public let database: CKDatabase
    public let zoneID: CKRecordZone.ID
    public let store: HouseholdLocalStore
    private let stateURL: URL
    private let log = Logger(subsystem: "app.seedkeep.cloud", category: "HouseholdSync")

    private var syncEngine: CKSyncEngine!
    private var zoneEnsured = false

    /// Optional field-merger. When set, records whose type it `handles` are field-merged
    /// at the fetch + serverRecordChanged seams instead of blanket LWW.
    ///
    /// `merger` + the two callbacks below are lock-guarded: they are written once from the
    /// coordinator (MainActor) before the first sync and READ on the CKSyncEngine delegate queue.
    /// The lock makes the `Sendable` conformance sound; the live coordinator additionally builds the
    /// engine with `automaticSync: false`, so no delegate event can fire before they are wired.
    private let callbackLock = NSLock()
    private var _merger: RecordMerger?
    private var _onFetchedChanges: (([CKRecord], [CKRecord.ID]) -> Void)?
    private var _onAccountChange: ((HouseholdAccountChange) -> Void)?

    public var merger: RecordMerger? {
        get { callbackLock.lock(); defer { callbackLock.unlock() }; return _merger }
        set { callbackLock.lock(); _merger = newValue; callbackLock.unlock() }
    }

    /// Fired after a fetched batch is reconciled into the local store (and after a SENT batch's
    /// saved records land), with the records actually applied + the deletion IDs. The coordinator
    /// decodes these and projects them into SwiftData. Called off arbitrary tasks (CKSyncEngine's
    /// queue) — the coordinator must hop to @MainActor before touching ModelContext.
    public var onFetchedChanges: (([CKRecord], [CKRecord.ID]) -> Void)? {
        get { callbackLock.lock(); defer { callbackLock.unlock() }; return _onFetchedChanges }
        set { callbackLock.lock(); _onFetchedChanges = newValue; callbackLock.unlock() }
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

        var configuration = CKSyncEngine.Configuration(
            database: database,
            stateSerialization: Self.loadState(from: stateURL),
            delegate: self)
        configuration.automaticallySync = automaticSync
        self.syncEngine = CKSyncEngine(configuration)
    }

    // MARK: - Public mutation API

    /// Stage a record save: write it locally, then tell the engine it's pending.
    /// The zone is created lazily on the first save.
    public func save(_ record: CKRecord) {
        store.setRecord(record)
        if !zoneEnsured {
            syncEngine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
            zoneEnsured = true
        }
        syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(record.recordID)])
    }

    public func delete(_ recordID: CKRecord.ID) {
        store.removeRecord(recordID)
        syncEngine.state.add(pendingRecordZoneChanges: [.deleteRecord(recordID)])
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

    /// Fetch remote changes then push local ones. Manual drive for deterministic tests.
    public func sync() async throws {
        try await syncEngine.fetchChanges()
        try await syncEngine.sendChanges()
    }

    public func fetchChanges() async throws { try await syncEngine.fetchChanges() }
    public func sendChanges() async throws { try await syncEngine.sendChanges() }

    public var hasPendingRecordChanges: Bool {
        !syncEngine.state.pendingRecordZoneChanges.isEmpty
    }

    /// Send repeatedly until nothing is pending (G11: a serverRecordChanged re-enqueues
    /// a merged save; stopping on the throw loses it).
    public func sendUntilDrained(maxPasses: Int = 8) async throws {
        for _ in 0..<maxPasses {
            do {
                try await syncEngine.sendChanges()
                if !hasPendingRecordChanges { return }
            } catch {
                if !hasPendingRecordChanges { throw error }
            }
        }
        // Budget exhausted with changes still pending (a conflict storm). Don't silently abandon
        // them — surface it so a drain that never converged is diagnosable rather than a false success.
        if hasPendingRecordChanges {
            log.error("sendUntilDrained exhausted \(maxPasses, privacy: .public) passes — record changes STILL pending")
        }
    }

    // MARK: - CKSyncEngineDelegate

    public func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let pending = syncEngine.state.pendingRecordZoneChanges.filter {
            context.options.scope.contains($0)
        }
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pending) { recordID in
            self.store.record(for: recordID)
        }
    }

    public func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        switch event {
        case .stateUpdate(let update):
            Self.saveState(update.stateSerialization, to: stateURL)

        case .fetchedRecordZoneChanges(let changes):
            let pendingSaves = pendingSaveIDs()
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
            if !applied.isEmpty || !deletedIDs.isEmpty {
                onFetchedChanges?(applied, deletedIDs)
            }

        case .sentRecordZoneChanges(let sent):
            var saved: [CKRecord] = []
            for record in sent.savedRecords {
                store.setRecord(record)
                saved.append(record)
                note("saved \(record.recordID.recordName)")
            }
            for failure in sent.failedRecordSaves {
                note("FAILED \(failure.record.recordID.recordName) code=\(failure.error.code.rawValue)")
                handleFailedSave(failure)
            }
            // Project the SAVED records back to SwiftData. For a serverRecordChanged conflict, the
            // re-saved record IS the merged result (packetCount-min / tagIDs-union / sticky-deletedAt)
            // produced in handleFailedSave — without this, the editing device's SwiftData keeps its
            // pre-merge values forever (it authored the last write, so it never re-fetches them).
            if !saved.isEmpty { onFetchedChanges?(saved, []) }

        case .accountChange(let change):
            handleAccountChange(change)

        case .willFetchChanges, .didFetchChanges,
             .willSendChanges, .didSendChanges,
             .fetchedDatabaseChanges, .sentDatabaseChanges,
             .willFetchRecordZoneChanges, .didFetchRecordZoneChanges:
            break

        @unknown default:
            break
        }
    }

    private func pendingSaveIDs() -> Set<CKRecord.ID> {
        var ids = Set<CKRecord.ID>()
        for change in syncEngine.state.pendingRecordZoneChanges {
            if case .saveRecord(let id) = change { ids.insert(id) }
        }
        return ids
    }

    // MARK: - Conflict + failure handling

    private func handleFailedSave(_ failure: CKSyncEngine.Event.SentRecordZoneChanges.FailedRecordSave) {
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
                if shouldResave {
                    syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
                }
            }
        case .zoneNotFound, .userDeletedZone:
            syncEngine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
            syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
        case .unknownItem:
            store.removeRecord(recordID)
        default:
            log.error("seed save failed for \(recordID.recordName, privacy: .public): \(failure.error, privacy: .public)")
        }
    }

    private func handleAccountChange(_ change: CKSyncEngine.Event.AccountChange) {
        switch change.changeType {
        case .signOut:
            store.removeAll()
            onAccountChange?(.signOut)
        case .switchAccounts:
            store.removeAll()
            onAccountChange?(.switchAccounts)
        case .signIn:
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
