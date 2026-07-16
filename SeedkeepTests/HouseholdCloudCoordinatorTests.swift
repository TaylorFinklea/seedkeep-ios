import Testing
import Foundation
import SwiftData
import CloudKit
@testable import Seedkeep
import SeedkeepKit
import SeedkeepCloudKit

// R1 live-engine wiring — the coordinator + migration executor + apply-gate + AC5 wipe, exercised
// against a FAKE engine (no CKContainer / iCloud account). The engine's own callback firing is
// validated on-device (CKSyncEngine.Event isn't synthetically constructible); these tests cover all
// the SwiftData<->engine LOGIC the coordinator owns: reverse apply with the updatedAt-LWW gate,
// watermark push with echo exclusion, the receipt-gated migration (AC3), and the account-wipe (AC5).
@MainActor
struct HouseholdCloudCoordinatorTests {

    // MARK: Fake engine

    /// Records saves/deletes; `pendingFetch` is delivered once via `fetchChanges()` (simulating a
    /// remote batch) — both into the store and through `onFetchedChanges`, exactly as the real engine.
    final class FakeEngine: HouseholdRecordSyncing, @unchecked Sendable {
        let store = HouseholdLocalStore()
        var merger: RecordMerger?
        var onFetchedChanges: (([CKRecord], [CKRecord.ID]) -> Void)?
        var onAccountChange: ((HouseholdAccountChange) -> Void)?
        private(set) var savedRecords: [CKRecord] = []
        private(set) var deletedIDs: [CKRecord.ID] = []
        private(set) var fetchChangesCallCount = 0
        private(set) var sendUntilDrainedCallCount = 0
        var pendingFetch: ([CKRecord], [CKRecord.ID]) = ([], [])
        var hasPendingRecordChanges = false
        var drainGate: DrainGate?
        var drainFailuresRemaining = 0
        /// Number of leading fetchChanges() calls that should throw `fetchError` (simulating a
        /// transient hiccup that clears on retry). Decrements per throw.
        var fetchFailuresRemaining = 0
        var fetchError: Error = URLError(.timedOut)

        func save(_ record: CKRecord) { store.setRecord(record); savedRecords.append(record) }
        func delete(_ recordID: CKRecord.ID) {
            store.removeRecord(recordID)
            deletedIDs.append(recordID)
            hasPendingRecordChanges = true
        }
        func fetchChanges() async throws {
            fetchChangesCallCount += 1
            if fetchFailuresRemaining > 0 { fetchFailuresRemaining -= 1; throw fetchError }
            let (mods, dels) = pendingFetch
            pendingFetch = ([], [])
            guard !mods.isEmpty || !dels.isEmpty else { return }
            for m in mods { store.applyRemoteModification(m) }
            for d in dels { store.removeRecord(d) }
            onFetchedChanges?(mods, dels)
        }
        func sendUntilDrained(maxPasses: Int) async throws {
            sendUntilDrainedCallCount += 1
            if drainFailuresRemaining > 0 {
                drainFailuresRemaining -= 1
                throw fetchError
            }
            if let drainGate { await drainGate.waitForDrain() }
            hasPendingRecordChanges = false
        }

        var savedTypes: [String] { savedRecords.map(\.recordType) }
    }

    actor DrainGate {
        private var started = false
        private var startWaiter: CheckedContinuation<Void, Never>?
        private var releaseWaiter: CheckedContinuation<Void, Never>?

        func waitForDrain() async {
            started = true
            startWaiter?.resume()
            startWaiter = nil
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                releaseWaiter = continuation
            }
        }

        func waitUntilStarted() async {
            guard !started else { return }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                startWaiter = continuation
            }
        }

        func release() {
            releaseWaiter?.resume()
            releaseWaiter = nil
        }
    }

    // MARK: Helpers

    private func makeContainer() -> ModelContainer {
        makeTestContainer(name: "coord-\(UUID().uuidString)")
    }

    private func makeCoordinator(
        engine: FakeEngine, container: ModelContainer, householdID: String
    ) -> HouseholdCloudCoordinator {
        let zoneID = CKRecordZone.ID(
            zoneName: SeedkeepZoneProvisioner.zoneName(householdID: householdID),
            ownerName: CKCurrentUserDefaultName)
        return HouseholdCloudCoordinator(
            engine: engine, zoneID: zoneID, householdID: householdID, householdName: "Test House",
            householdCreatedAt: 1, householdUpdatedAt: 1, container: container,
            provisioner: nil, stateURL: nil)   // provisioner nil → skip live provisioning
    }

    private func zoneID(_ householdID: String) -> CKRecordZone.ID {
        CKRecordZone.ID(zoneName: SeedkeepZoneProvisioner.zoneName(householdID: householdID),
                        ownerName: CKCurrentUserDefaultName)
    }

    /// A remote Seed CKRecord (round-tripped through the real codec) with a chosen clock + name.
    private func remoteSeed(id: String, householdID: String, name: String, updatedAt: Int64) -> CKRecord {
        let local = LocalSeed(id: id, householdID: householdID, state: .active, packetCount: 5,
                              source: .store, createdAt: 1, updatedAt: updatedAt)
        local.customName = name
        return SeedkeepRecordCodec.encode(local.cloudKitValue, zoneID: zoneID(householdID))
    }

    /// A remote Seed CKRecord carrying a TOMBSTONE (deletedAt set) — for the apply-only-tombstone path
    /// where a peer pushed a delete this device learns purely by fetching (never pushes itself).
    private func remoteTombstoneSeed(id: String, householdID: String, deletedAt: Int64) -> CKRecord {
        let local = LocalSeed(id: id, householdID: householdID, state: .active, packetCount: 1,
                              source: .store, createdAt: 1, updatedAt: deletedAt)
        local.deletedAt = deletedAt
        return SeedkeepRecordCodec.encode(local.cloudKitValue, zoneID: zoneID(householdID))
    }

    private func fetchSeed(_ c: ModelContext, _ id: String) -> LocalSeed? {
        try? c.fetch(FetchDescriptor<LocalSeed>(predicate: #Predicate { $0.id == id })).first
    }

    // MARK: - Migration executor (AC3)

    @Test("executor writes the full plan + receipt when none exists, then skips on re-run")
    func executorIdempotent() async throws {
        let hid = "hh-\(UUID().uuidString)"
        let engine = FakeEngine()
        let z = zoneID(hid)
        let input = HouseholdMigrationPlanner.Input(
            householdID: hid, householdName: "H", householdCreatedAt: 1, householdUpdatedAt: 1,
            seeds: [LocalSeed(id: "s1", householdID: hid, state: .active, packetCount: 3, source: .store, createdAt: 1, updatedAt: 2)])
        let plan = HouseholdMigrationPlanner.plan(input, completedAt: 100)

        let r1 = try await HouseholdMigrationExecutor.run(into: engine, zoneID: z, householdID: hid, plan: plan)
        #expect(r1.alreadyMigrated == false)
        #expect(r1.written == plan.count)
        #expect(engine.savedTypes.contains("Household"))
        #expect(engine.savedTypes.contains("Seed"))
        #expect(engine.savedTypes.contains("MigrationReceipt"))

        // Second run: receipt now in the store → no-op.
        let before = engine.savedRecords.count
        let r2 = try await HouseholdMigrationExecutor.run(into: engine, zoneID: z, householdID: hid, plan: plan)
        #expect(r2.alreadyMigrated == true)
        #expect(r2.written == 0)
        #expect(engine.savedRecords.count == before, "skip must write nothing")
    }

    @Test("coordinator skips migration when a receipt is already synced from another device")
    func migrationSkippedWhenReceiptFetched() async throws {
        let hid = "hh-\(UUID().uuidString)"
        let container = makeContainer()
        let engine = FakeEngine()
        // Seed local data that WOULD be migrated…
        let setup = ModelContext(container)
        setup.insert(LocalSeed(id: "s1", householdID: hid, state: .active, packetCount: 3, source: .store, createdAt: 1, updatedAt: 2))
        try setup.save()
        // …but a receipt arrives on the first fetch (another device already migrated).
        let receipt = SeedkeepRecordCodec.encode(
            SeedkeepRecordValues.migrationReceipt(householdID: hid, completedAt: 1, schemaVersion: 1), zoneID: zoneID(hid))
        engine.pendingFetch = ([receipt], [])

        let coordinator = makeCoordinator(engine: engine, container: container, householdID: hid)
        await coordinator.sync()
        // The migration is SKIPPED (no receipt re-written) — that is the idempotency signal. The
        // local seed still reconciles via the normal forward push (pushDirty), which is correct: a
        // device that missed migration must still converge its local data with the migrated zone.
        #expect(engine.savedTypes.contains("MigrationReceipt") == false, "migration must not re-export when the receipt is present")
    }

    // MARK: - Reverse apply + updatedAt-LWW gate

    @Test("fetched remote is projected into SwiftData")
    func fetchedRemoteApplied() async throws {
        let hid = "hh-\(UUID().uuidString)"
        let container = makeContainer()
        let engine = FakeEngine()
        engine.pendingFetch = ([remoteSeed(id: "s1", householdID: hid, name: "Brandywine", updatedAt: 500)], [])
        let coordinator = makeCoordinator(engine: engine, container: container, householdID: hid)
        await coordinator.sync()
        let m = fetchSeed(ModelContext(container), "s1")
        #expect(m?.customName == "Brandywine")
        #expect(m?.updatedAt == 500)
    }

    @Test("updatedAt-LWW gate: an OLDER remote does not clobber a newer local edit")
    func lwwGateSkipsOlderRemote() async throws {
        let hid = "hh-\(UUID().uuidString)"
        let container = makeContainer()
        let engine = FakeEngine()
        let coordinator = makeCoordinator(engine: engine, container: container, householdID: hid)
        await coordinator.sync()   // start (empty graph)

        // Local edit at clock 500.
        let setup = ModelContext(container)
        let local = LocalSeed(id: "s1", householdID: hid, state: .active, packetCount: 5, source: .store, createdAt: 1, updatedAt: 500)
        local.customName = "LocalName"
        setup.insert(local); try setup.save()

        // Stale remote at clock 100 arrives.
        engine.pendingFetch = ([remoteSeed(id: "s1", householdID: hid, name: "StaleRemote", updatedAt: 100)], [])
        await coordinator.sync()
        #expect(fetchSeed(ModelContext(container), "s1")?.customName == "LocalName", "older remote must not win")

        // A genuinely newer remote at clock 900 DOES win.
        engine.pendingFetch = ([remoteSeed(id: "s1", householdID: hid, name: "FreshRemote", updatedAt: 900)], [])
        await coordinator.sync()
        let after = fetchSeed(ModelContext(container), "s1")
        #expect(after?.customName == "FreshRemote")
        #expect(after?.updatedAt == 900)
    }

    @Test("a CloudKit deletion hard-deletes the local row")
    func deletionRemovesLocalRow() async throws {
        let hid = "hh-\(UUID().uuidString)"
        let container = makeContainer()
        let engine = FakeEngine()
        let coordinator = makeCoordinator(engine: engine, container: container, householdID: hid)
        await coordinator.sync()
        let setup = ModelContext(container)
        setup.insert(LocalSeed(id: "s1", householdID: hid, state: .active, packetCount: 1, source: .store, createdAt: 1, updatedAt: 1))
        try setup.save()
        #expect(fetchSeed(ModelContext(container), "s1") != nil)

        let delID = CKRecord.ID(recordName: SeedkeepRecordNames.recordName(for: .seed, id: "s1"), zoneID: zoneID(hid))
        engine.pendingFetch = ([], [delID])
        await coordinator.sync()
        #expect(fetchSeed(ModelContext(container), "s1") == nil, "deletion must remove the local row")
    }

    // MARK: - Watermark push + echo exclusion

    @Test("pushDirty stages a local edit newer than the watermark")
    func pushStagesLocalEdit() async throws {
        let hid = "hh-\(UUID().uuidString)"
        let container = makeContainer()
        let engine = FakeEngine()
        let coordinator = makeCoordinator(engine: engine, container: container, householdID: hid)
        await coordinator.sync()   // start (empty)

        let setup = ModelContext(container)
        setup.insert(LocalSeed(id: "s1", householdID: hid, state: .active, packetCount: 9, source: .store, createdAt: 1, updatedAt: 500))
        try setup.save()
        await coordinator.sync()
        #expect(engine.savedRecords.contains { $0.recordID.recordName == "seed:s1" }, "a local edit must be pushed")
    }

    @Test("save nudges a local edit through sync and commits synced state")
    func saveNudgesLocalEdit() async throws {
        let hid = "hh-\(UUID().uuidString)"
        let container = makeContainer()
        let engine = FakeEngine()
        let coordinator = makeCoordinator(engine: engine, container: container, householdID: hid)
        coordinator.pushDebounceIntervalNanoseconds = 0
        await coordinator.sync()

        let setup = ModelContext(container)
        setup.insert(LocalSeed(id: "s1", householdID: hid, state: .active, packetCount: 1,
                               source: .store, createdAt: 1, updatedAt: 500))
        try setup.save()

        await coordinator.save()
        await coordinator.awaitPendingImmediacy()

        #expect(engine.savedRecords.contains { $0.recordID.recordName == "seed:s1" },
                "save must push the local edit through the coordinator")
        let url = HouseholdCloudCoordinator.ownerSyncedStateURL(householdID: hid)
        let data = try Data(contentsOf: url)
        let state = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(state["seed:s1"] != nil, "immediacy push must commit per-record synced state")
    }

    @Test("save coalesces a burst into one sync push")
    func saveCoalescesBurst() async throws {
        let hid = "hh-\(UUID().uuidString)"
        let container = makeContainer()
        let engine = FakeEngine()
        let coordinator = makeCoordinator(engine: engine, container: container, householdID: hid)
        coordinator.pushDebounceIntervalNanoseconds = 1_000_000
        await coordinator.sync()
        let baselineFetches = engine.fetchChangesCallCount
        let baselineDrains = engine.sendUntilDrainedCallCount

        let setup = ModelContext(container)
        setup.insert(LocalSeed(id: "s1", householdID: hid, state: .active, packetCount: 1,
                               source: .store, createdAt: 1, updatedAt: 500))
        try setup.save()

        await coordinator.save()
        await coordinator.save()
        await coordinator.save()
        await coordinator.awaitPendingImmediacy()

        #expect(engine.savedRecords.filter { $0.recordID.recordName == "seed:s1" }.count == 1,
                "a burst of nudges must push the dirty record once")
        #expect(engine.fetchChangesCallCount == baselineFetches + 1,
                "a burst of nudges must run one reconcile pass")
        #expect(engine.sendUntilDrainedCallCount == baselineDrains + 1,
                "a burst of nudges must drain once")
    }

    @Test("durable checklist deletion drains once and is not resurrected as a save")
    func durableChecklistDeletionDrainsExactlyOnce() async throws {
        let hid = "hh-\(UUID().uuidString)"
        let container = makeContainer()
        let engine = FakeEngine()
        let coordinator = makeCoordinator(engine: engine, container: container, householdID: hid)
        coordinator.pushDebounceIntervalNanoseconds = 0
        await coordinator.sync()

        let setup = ModelContext(container)
        setup.insert(LocalJournalEntry(
            id: "entry-1", householdID: hid, occurredOn: "2026-07-15", body: "Entry",
            seedID: nil, bedID: nil, plantingEventID: nil,
            createdAt: 1, updatedAt: 500, deletedAt: nil
        ))
        setup.insert(LocalJournalChecklistItem(
            id: "item-1", entryID: "entry-1", text: "Water",
            completed: false, sortOrder: 0, updatedAt: 500
        ))
        try setup.save()
        await coordinator.sync()
        let baselineChecklistSaves = engine.savedRecords.filter {
            $0.recordID.recordName == SeedkeepRecordNames.journalChecklistItem("item-1")
        }.count
        let baselineDrains = engine.sendUntilDrainedCallCount

        let recordName = SeedkeepRecordNames.journalChecklistItem("item-1")
        let deletionContext = ModelContext(container)
        let itemID = "item-1"
        let item = try #require(deletionContext.fetch(
            FetchDescriptor<LocalJournalChecklistItem>(predicate: #Predicate { $0.id == itemID })
        ).first)
        deletionContext.insert(LocalCloudKitDeletion(
            scopeID: HouseholdCloudCoordinator.ownerScopeID(householdID: hid), householdID: hid,
            recordName: recordName,
            createdAt: 600
        ))
        deletionContext.delete(item)
        try deletionContext.save()
        await coordinator.sync()

        #expect(engine.deletedIDs.map(\.recordName) == [recordName])
        #expect(engine.sendUntilDrainedCallCount == baselineDrains + 1)
        #expect(engine.savedRecords.filter { $0.recordID.recordName == recordName }.count == baselineChecklistSaves,
                "an absent hard-deleted checklist item must not be re-saved")
        #expect(try ModelContext(container).fetch(FetchDescriptor<LocalCloudKitDeletion>()).isEmpty,
                "the intent clears only after the CloudKit drain succeeds")
    }

    @Test("a pending hard delete suppresses remote re-import before its drain")
    func pendingHardDeleteSuppressesRemoteReimport() async throws {
        let hid = "hh-\(UUID().uuidString)"
        let container = makeContainer()
        let engine = FakeEngine()
        let coordinator = makeCoordinator(engine: engine, container: container, householdID: hid)
        await coordinator.sync()

        let recordName = SeedkeepRecordNames.journalChecklistItem("item-1")
        let setup = ModelContext(container)
        setup.insert(LocalCloudKitDeletion(
            scopeID: HouseholdCloudCoordinator.ownerScopeID(householdID: hid),
            householdID: hid, recordName: recordName, createdAt: 500
        ))
        try setup.save()
        let remoteItem = LocalJournalChecklistItem(
            id: "item-1", entryID: "entry-1", text: "Remote",
            completed: false, sortOrder: 0, updatedAt: 400
        )
        engine.pendingFetch = ([SeedkeepRecordCodec.encode(remoteItem.cloudKitValue, zoneID: zoneID(hid))], [])
        let gate = DrainGate()
        engine.drainGate = gate

        let syncTask = Task { await coordinator.sync() }
        await gate.waitUntilStarted()

        #expect(try ModelContext(container).fetch(FetchDescriptor<LocalJournalChecklistItem>()).isEmpty,
                "a queued local delete must win while the CloudKit delete is still draining")

        await gate.release()
        _ = await syncTask.value
    }

    @Test("a failed hard-delete drain survives coordinator relaunch")
    func failedHardDeleteDrainSurvivesRelaunch() async throws {
        let hid = "hh-\(UUID().uuidString)"
        let container = makeContainer()
        let engine1 = FakeEngine()
        let coordinator1 = makeCoordinator(engine: engine1, container: container, householdID: hid)
        await coordinator1.sync()

        let recordName = SeedkeepRecordNames.journalChecklistItem("item-1")
        let setup = ModelContext(container)
        setup.insert(LocalCloudKitDeletion(
            scopeID: HouseholdCloudCoordinator.ownerScopeID(householdID: hid),
            householdID: hid, recordName: recordName, createdAt: 500
        ))
        try setup.save()
        engine1.drainFailuresRemaining = 2

        await coordinator1.sync()

        #expect(try ModelContext(container).fetch(FetchDescriptor<LocalCloudKitDeletion>()).count == 1,
                "an unconfirmed delete must remain durable after the retry budget is exhausted")

        let engine2 = FakeEngine()
        let coordinator2 = makeCoordinator(engine: engine2, container: container, householdID: hid)
        await coordinator2.sync()

        #expect(engine2.deletedIDs.map(\.recordName) == [recordName])
        #expect(try ModelContext(container).fetch(FetchDescriptor<LocalCloudKitDeletion>()).isEmpty)
    }

    @Test("participant hard deletes target the owner's shared zone")
    func participantHardDeleteUsesOwnerZone() async throws {
        let ownerZone = CKRecordZone.ID(zoneName: "seedkeep-shared-garden", ownerName: "owner-record-name")
        let hid = SeedkeepRecordNames.householdID(fromZoneName: ownerZone.zoneName)
        let container = makeContainer()
        let setup = ModelContext(container)
        let recordName = SeedkeepRecordNames.journalChecklistItem("item-1")
        let participantScope = HouseholdCloudCoordinator.participantScopeID(ownerZoneID: ownerZone)
        setup.insert(LocalCloudKitDeletion(
            scopeID: participantScope, householdID: hid, recordName: recordName, createdAt: 500
        ))
        try setup.save()
        let engine = FakeEngine()
        let coordinator = HouseholdCloudCoordinator(
            engine: engine, zoneID: ownerZone, householdID: hid, householdName: "",
            householdCreatedAt: 0, householdUpdatedAt: 0, container: container,
            provisioner: nil, stateURL: nil, isParticipant: true
        )

        await coordinator.sync()

        #expect(engine.deletedIDs.map(\.zoneID) == [ownerZone])
    }

    @Test("participant hard-delete outboxes are isolated by owner identity")
    func participantHardDeleteScopesIncludeOwnerIdentity() async throws {
        let zoneName = "seedkeep-shared-garden"
        let ownerA = CKRecordZone.ID(zoneName: zoneName, ownerName: "owner-a")
        let ownerB = CKRecordZone.ID(zoneName: zoneName, ownerName: "owner-b")
        let hid = SeedkeepRecordNames.householdID(fromZoneName: zoneName)
        let recordName = SeedkeepRecordNames.journalChecklistItem("item-1")
        let container = makeContainer()
        let setup = ModelContext(container)
        setup.insert(LocalCloudKitDeletion(
            scopeID: HouseholdCloudCoordinator.participantScopeID(ownerZoneID: ownerA),
            householdID: hid, recordName: recordName, createdAt: 500
        ))
        setup.insert(LocalCloudKitDeletion(
            scopeID: HouseholdCloudCoordinator.participantScopeID(ownerZoneID: ownerB),
            householdID: hid, recordName: recordName, createdAt: 501
        ))
        try setup.save()
        let engine = FakeEngine()
        let coordinator = HouseholdCloudCoordinator(
            engine: engine, zoneID: ownerA, householdID: hid, householdName: "",
            householdCreatedAt: 0, householdUpdatedAt: 0, container: container,
            provisioner: nil, stateURL: nil, isParticipant: true
        )

        await coordinator.sync()

        #expect(engine.deletedIDs.map(\.zoneID) == [ownerA])
        let remaining = try ModelContext(container).fetch(FetchDescriptor<LocalCloudKitDeletion>())
        #expect(remaining.map(\.scopeID) == [HouseholdCloudCoordinator.participantScopeID(ownerZoneID: ownerB)])
        #expect(
            HouseholdCloudCoordinator.participantStateTokenURL(ownerZoneID: ownerA)
                != HouseholdCloudCoordinator.participantStateTokenURL(ownerZoneID: ownerB)
        )
        #expect(
            HouseholdCloudCoordinator.participantSyncedStateURL(ownerZoneID: ownerA)
                != HouseholdCloudCoordinator.participantSyncedStateURL(ownerZoneID: ownerB)
        )
    }

    @Test("wipe cancels a pending save nudge")
    func wipeCancelsPendingSave() async throws {
        let hid = "hh-\(UUID().uuidString)"
        let container = makeContainer()
        let engine = FakeEngine()
        let coordinator = makeCoordinator(engine: engine, container: container, householdID: hid)
        coordinator.pushDebounceIntervalNanoseconds = 1_000_000_000

        let setup = ModelContext(container)
        setup.insert(LocalSeed(id: "s1", householdID: hid, state: .active, packetCount: 1,
                               source: .store, createdAt: 1, updatedAt: 500))
        try setup.save()

        await coordinator.save()
        let pending = try #require(coordinator.pendingImmediacyTaskForTesting())
        coordinator.handleAccountChange(.signOut)
        await pending.value

        #expect(engine.savedRecords.isEmpty, "a wiped coordinator must not push a queued nudge")
    }

    @Test("echo exclusion: a record applied from remote this pass is not re-pushed")
    func echoExcluded() async throws {
        let hid = "hh-\(UUID().uuidString)"
        let container = makeContainer()
        let engine = FakeEngine()
        let coordinator = makeCoordinator(engine: engine, container: container, householdID: hid)
        await coordinator.sync()   // start (empty) → only Household + receipt written

        engine.pendingFetch = ([remoteSeed(id: "s1", householdID: hid, name: "FromPeer", updatedAt: 400)], [])
        await coordinator.sync()
        #expect(engine.savedRecords.contains { $0.recordID.recordName == "seed:s1" } == false,
                "a just-applied remote record must not echo back as a push")
        // It IS now in SwiftData.
        #expect(fetchSeed(ModelContext(container), "s1")?.customName == "FromPeer")
    }

    @Test("watermark is not poisoned by a peer's high clock — a later lower-clock local edit still pushes")
    func watermarkNotPoisonedByPeerClock() async throws {
        let hid = "hh-\(UUID().uuidString)"
        let container = makeContainer()
        let engine = FakeEngine()
        let coordinator = makeCoordinator(engine: engine, container: container, householdID: hid)
        await coordinator.sync()   // start (empty)

        // A peer record with a FAR-AHEAD clock is fetched + applied (peer's wall clock runs fast).
        engine.pendingFetch = ([remoteSeed(id: "peer", householdID: hid, name: "Peer", updatedAt: 10_000)], [])
        await coordinator.sync()

        // A genuine LOCAL edit to a DIFFERENT record with a LOWER clock than the peer's.
        let setup = ModelContext(container)
        let local = LocalSeed(id: "mine", householdID: hid, state: .active, packetCount: 1, source: .store, createdAt: 1, updatedAt: 500)
        local.customName = "Mine"
        setup.insert(local); try setup.save()
        await coordinator.sync()
        #expect(engine.savedRecords.contains { $0.recordID.recordName == "seed:mine" },
                "the local edit must push even though a peer's clock is far ahead — the watermark must advance only over pushed records, never absorb peer clocks")
    }

    @Test("migration does not re-run after relaunch (durable marker survives a fresh engine store)")
    func migrationDurableAcrossRelaunch() async throws {
        let hid = "hh-\(UUID().uuidString)"
        let container = makeContainer()
        let setup = ModelContext(container)
        setup.insert(LocalSeed(id: "s1", householdID: hid, state: .active, packetCount: 2, source: .store, createdAt: 1, updatedAt: 2))
        try setup.save()

        // First launch: migrates (writes the receipt).
        let engine1 = FakeEngine()
        await makeCoordinator(engine: engine1, container: container, householdID: hid).sync()
        #expect(engine1.savedTypes.contains("MigrationReceipt"), "first run migrates")

        // Relaunch: a FRESH engine with an empty in-memory store (as on a real relaunch), SAME household.
        // The in-memory receipt is gone, but the durable marker must still suppress re-export.
        let engine2 = FakeEngine()
        await makeCoordinator(engine: engine2, container: container, householdID: hid).sync()
        #expect(engine2.savedTypes.contains("MigrationReceipt") == false,
                "the durable migration marker must prevent a full re-export on every relaunch")
    }

    @Test("a record applied from a peer is not re-uploaded on relaunch (AC1)")
    func relaunchDoesNotReUploadPeerAppliedRecord() async throws {
        let hid = "hh-\(UUID().uuidString)"
        let container = makeContainer()
        let engine1 = FakeEngine()
        let coordinator1 = makeCoordinator(engine: engine1, container: container, householdID: hid)
        await coordinator1.sync()   // start (empty migrate)

        // A peer record is fetched + applied this session.
        engine1.pendingFetch = ([remoteSeed(id: "peer1", householdID: hid, name: "Peer", updatedAt: 200)], [])
        await coordinator1.sync()
        #expect(fetchSeed(ModelContext(container), "peer1")?.customName == "Peer")

        // Relaunch: a FRESH engine with an empty in-memory store, SAME household + container. The
        // in-session echo guard (`appliedSinceLastPush`) is gone; only the durable per-record
        // synced-state can suppress the re-upload.
        let engine2 = FakeEngine()
        let coordinator2 = makeCoordinator(engine: engine2, container: container, householdID: hid)
        await coordinator2.sync()
        #expect(engine2.savedRecords.contains { $0.recordID.recordName == "seed:peer1" } == false,
                "a record applied from a peer must not be re-uploaded on relaunch")
    }

    @Test("a local tombstone pushes even when the store holds a higher-clock LIVE peer record")
    func tombstonePushesOverLiveStore() async throws {
        let hid = "hh-\(UUID().uuidString)"
        let container = makeContainer()
        let engine = FakeEngine()
        let coordinator = makeCoordinator(engine: engine, container: container, householdID: hid)
        await coordinator.sync()   // start (empty)

        // A peer's LIVE edit at a FAR-AHEAD clock lands in the engine store + SwiftData.
        engine.pendingFetch = ([remoteSeed(id: "s1", householdID: hid, name: "PeerLive", updatedAt: 10_000)], [])
        await coordinator.sync()

        // Now locally SOFT-DELETE that seed at a LOWER clock (deletedAt set, updatedAt below the peer's).
        let setup = ModelContext(container)
        let m = fetchSeed(setup, "s1")
        m?.deletedAt = 500
        m?.updatedAt = 500
        try setup.save()
        await coordinator.sync()

        let pushedTombstone = engine.savedRecords.contains {
            $0.recordID.recordName == "seed:s1" && ($0["deletedAt"] as? Int) != nil
        }
        #expect(pushedTombstone, "the tombstone must push despite the store holding a higher-clock LIVE peer record (sticky-deletedAt converges)")
    }

    @Test("a tombstone PUSHED by this device records its tombstoned bit + does not re-push on relaunch")
    func pushedTombstoneRecordsBitAndDoesNotRePushOnRelaunch() async throws {
        let hid = "hh-\(UUID().uuidString)"
        let container = makeContainer()
        let engine = FakeEngine()
        let coordinator = makeCoordinator(engine: engine, container: container, householdID: hid)
        await coordinator.sync()   // start (empty)

        // A peer's LIVE edit at a FAR-AHEAD clock lands in the engine store + SwiftData.
        engine.pendingFetch = ([remoteSeed(id: "s1", householdID: hid, name: "PeerLive", updatedAt: 10_000)], [])
        await coordinator.sync()

        // Now locally SOFT-DELETE that seed at a LOWER clock (deletedAt set, updatedAt below the peer's).
        let setup = ModelContext(container)
        let m = fetchSeed(setup, "s1")
        m?.deletedAt = 500
        m?.updatedAt = 500
        try setup.save()
        await coordinator.sync()

        let pushedTombstone = engine.savedRecords.contains {
            $0.recordID.recordName == "seed:s1" && ($0["deletedAt"] as? Int) != nil
        }
        #expect(pushedTombstone, "the tombstone must push despite the store holding a higher-clock LIVE peer record (sticky-deletedAt converges)")

        // Relaunch: a FRESH engine with an empty in-memory store, SAME household + container — the
        // durable per-record synced-state (not the in-memory store) must remember the tombstone is
        // already confirmed in CloudKit and not re-push it.
        let engine2 = FakeEngine()
        let coordinator2 = makeCoordinator(engine: engine2, container: container, householdID: hid)
        await coordinator2.sync()
        let rePushedTombstone = engine2.savedRecords.contains { $0.recordID.recordName == "seed:s1" }
        #expect(rePushedTombstone == false, "a tombstone already confirmed in CloudKit must not re-push on relaunch")
    }

    @Test("an APPLY-ONLY peer tombstone (never pushed by this device) is not re-uploaded on relaunch (AC3 mirror of AC1)")
    func applyOnlyTombstoneDoesNotRePushOnRelaunch() async throws {
        let hid = "hh-\(UUID().uuidString)"
        let container = makeContainer()
        let engine1 = FakeEngine()
        let coordinator1 = makeCoordinator(engine: engine1, container: container, householdID: hid)
        await coordinator1.sync()   // start (empty migrate)

        // A peer's TOMBSTONE for a record this device never created locally arrives + is APPLIED. This
        // device NEVER pushes it (learned purely via apply) — the exact case the old global watermark
        // missed (an applied record never advanced the push ceiling, so it re-uploaded every relaunch).
        engine1.pendingFetch = ([remoteTombstoneSeed(id: "ghost", householdID: hid, deletedAt: 700)], [])
        await coordinator1.sync()
        #expect(fetchSeed(ModelContext(container), "ghost")?.deletedAt == 700, "the peer tombstone is applied locally")
        #expect(engine1.savedRecords.contains { $0.recordID.recordName == "seed:ghost" } == false,
                "the applied tombstone is not echoed back this session")

        // Relaunch: fresh engine + coordinator, SAME household + container. Only the durable apply-success
        // synced-state write (tombstoned:true) can suppress the re-upload — proving the AC1 fix extends
        // to apply-only tombstones. This assertion FAILS against the pre-change global-watermark code.
        let engine2 = FakeEngine()
        let coordinator2 = makeCoordinator(engine: engine2, container: container, householdID: hid)
        await coordinator2.sync()
        #expect(engine2.savedRecords.contains { $0.recordID.recordName == "seed:ghost" } == false,
                "an apply-only peer tombstone must not be re-uploaded on relaunch")
    }

    // MARK: - Transient auto-retry (R3)

    @Test("a transient error auto-recovers within sync() — no error surfaced, no double-tap")
    func autoRetryRecoversTransient() async throws {
        let hid = "hh-\(UUID().uuidString)"
        let container = makeContainer()
        let engine = FakeEngine()
        engine.fetchFailuresRemaining = 1   // first fetch throws, retry succeeds (maxAttempts = 2)
        let coordinator = makeCoordinator(engine: engine, container: container, householdID: hid)
        await coordinator.sync()
        #expect(coordinator.lastHumanizedError == nil, "the transient must self-heal without surfacing an error")
        #expect(coordinator.lastSyncedAt != nil, "the recovered pass completes")
    }

    @Test("a persistent error gives up after the retry budget and surfaces humanized + detail")
    func transientGivesUpAfterMax() async throws {
        let hid = "hh-\(UUID().uuidString)"
        let container = makeContainer()
        let engine = FakeEngine()
        engine.fetchFailuresRemaining = 99   // never clears within the budget
        let coordinator = makeCoordinator(engine: engine, container: container, householdID: hid)
        await coordinator.sync()
        #expect(coordinator.lastHumanizedError != nil, "an unrecoverable error must surface")
        #expect(coordinator.lastErrorDetail != nil, "raw detail is recorded for the diagnostics row")
    }

    @Test("error classification: transient vs permanent")
    func errorClassification() {
        #expect(HouseholdCloudCoordinator.isTransient(URLError(.timedOut)) == true)
        #expect(HouseholdCloudCoordinator.isTransient(SyncEngineError.drainIncomplete) == true)
        #expect(HouseholdCloudCoordinator.isTransient(HouseholdCloudCoordinator.CoordinatorError.iCloudUnavailable(.noAccount)) == false)
        #expect(HouseholdCloudCoordinator.humanizeCloudError(HouseholdCloudCoordinator.CoordinatorError.iCloudUnavailable(.noAccount)).contains("iCloud"))
    }

    // MARK: - Apply-path sticky-deletedAt (R4)

    @Test("sticky-deletedAt on apply: a live remote edit does NOT resurrect a locally-deleted row")
    func applyGateStickyDeletedAt() throws {
        let container = makeContainer()
        let ctx = ModelContext(container)
        let hid = "hh1"
        // Local row is tombstoned at clock 100.
        let local = LocalSeed(id: "s1", householdID: hid, state: .active, packetCount: 1, source: .store, createdAt: 1, updatedAt: 100)
        local.deletedAt = 100
        ctx.insert(local); try ctx.save()
        // Incoming LIVE peer edit (no deletedAt) at a HIGHER clock must NOT resurrect it.
        let liveIncoming = LocalSeed(id: "s1", householdID: hid, state: .active, packetCount: 2, source: .store, createdAt: 1, updatedAt: 200)
        #expect(HouseholdApplyGate.shouldApply(liveIncoming.cloudKitValue, into: ctx) == false,
                "a live remote edit must not resurrect a locally-deleted row")

        // Incoming TOMBSTONE over a live local row wins regardless of clock.
        let liveLocal = LocalSeed(id: "s2", householdID: hid, state: .active, packetCount: 1, source: .store, createdAt: 1, updatedAt: 500)
        ctx.insert(liveLocal); try ctx.save()
        let tombstoneIncoming = LocalSeed(id: "s2", householdID: hid, state: .active, packetCount: 1, source: .store, createdAt: 1, updatedAt: 50)
        tombstoneIncoming.deletedAt = 50
        #expect(HouseholdApplyGate.shouldApply(tombstoneIncoming.cloudKitValue, into: ctx) == true,
                "an incoming tombstone wins over a live local row even at a lower clock")
    }

    // MARK: - Participant mode (cross-account sharing)

    @Test("participant coordinator imports NOTHING — no migration receipt / household export")
    func participantSkipsMigration() async throws {
        let hid = "hh-\(UUID().uuidString)"
        let container = makeContainer()
        let engine = FakeEngine()
        let setup = ModelContext(container)
        setup.insert(LocalSeed(id: "s1", householdID: hid, state: .active, packetCount: 1, source: .store, createdAt: 1, updatedAt: 2))
        try setup.save()
        // Build a participant coordinator directly (the .participant factory builds a real engine on
        // sharedCloudDatabase; here we inject the fake + isParticipant to test the no-migration path).
        let ownerZone = CKRecordZone.ID(zoneName: SeedkeepZoneProvisioner.zoneName(householdID: hid), ownerName: "_ownerRecordName")
        let coordinator = HouseholdCloudCoordinator(
            engine: engine, zoneID: ownerZone, householdID: hid, householdName: "",
            householdCreatedAt: 0, householdUpdatedAt: 0, container: container,
            provisioner: nil, stateURL: nil, isParticipant: true)
        await coordinator.sync()
        #expect(engine.savedTypes.contains("MigrationReceipt") == false, "a participant must not write a migration receipt")
        #expect(engine.savedTypes.contains("Household") == false, "a participant must not export the household root")
    }

    @Test("participant relaunch pushes an unpushed local edit")
    func participantRelaunchPushesUnpushedLocalEdit() async throws {
        let hid = "hh-\(UUID().uuidString)"
        let container = makeContainer()
        let ownerZone = CKRecordZone.ID(
            zoneName: SeedkeepZoneProvisioner.zoneName(householdID: hid), ownerName: "_ownerRecordName")

        let engine1 = FakeEngine()
        engine1.pendingFetch = ([remoteSeed(id: "peer1", householdID: hid, name: "P", updatedAt: 100)], [])
        let coordinator1 = HouseholdCloudCoordinator(
            engine: engine1, zoneID: ownerZone, householdID: hid, householdName: "",
            householdCreatedAt: 0, householdUpdatedAt: 0, container: container,
            provisioner: nil, stateURL: nil, isParticipant: true)
        await coordinator1.sync()

        let setup = ModelContext(container)
        let local = try #require(fetchSeed(setup, "peer1"))
        local.customName = "Edited"
        local.updatedAt = 200
        try setup.save()

        let engine2 = FakeEngine()
        let coordinator2 = HouseholdCloudCoordinator(
            engine: engine2, zoneID: ownerZone, householdID: hid, householdName: "",
            householdCreatedAt: 0, householdUpdatedAt: 0, container: container,
            provisioner: nil, stateURL: nil, isParticipant: true)
        await coordinator2.sync()

        let pushed = engine2.savedRecords.first { $0.recordID.recordName == "seed:peer1" }
        #expect(pushed != nil, "a participant's unpushed local edit must survive relaunch")
        #expect(pushed?["updatedAt"] as? Int == 200)
    }

    @Test("participant relaunch does not re-upload an imported record")
    func participantRelaunchDoesNotReUploadImportedRecord() async throws {
        let hid = "hh-\(UUID().uuidString)"
        let container = makeContainer()
        let ownerZone = CKRecordZone.ID(
            zoneName: SeedkeepZoneProvisioner.zoneName(householdID: hid), ownerName: "_ownerRecordName")

        let engine1 = FakeEngine()
        engine1.pendingFetch = ([remoteSeed(id: "peer1", householdID: hid, name: "P", updatedAt: 100)], [])
        let coordinator1 = HouseholdCloudCoordinator(
            engine: engine1, zoneID: ownerZone, householdID: hid, householdName: "",
            householdCreatedAt: 0, householdUpdatedAt: 0, container: container,
            provisioner: nil, stateURL: nil, isParticipant: true)
        await coordinator1.sync()

        let engine2 = FakeEngine()
        let coordinator2 = HouseholdCloudCoordinator(
            engine: engine2, zoneID: ownerZone, householdID: hid, householdName: "",
            householdCreatedAt: 0, householdUpdatedAt: 0, container: container,
            provisioner: nil, stateURL: nil, isParticipant: true)
        await coordinator2.sync()

        #expect(engine2.savedRecords.contains { $0.recordID.recordName == "seed:peer1" } == false,
                "an imported participant record must not be re-uploaded on relaunch")
    }

    @Test("owner already-migrated path does not suppress an unpushed edit")
    func ownerAlreadyMigratedDoesNotSuppressUnpushedEdit() async throws {
        let hid = "hh-\(UUID().uuidString)"
        let container = makeContainer()
        let setup = ModelContext(container)
        let local = LocalSeed(id: "s1", householdID: hid, state: .active, packetCount: 1,
                              source: .store, createdAt: 1, updatedAt: 200)
        local.customName = "Edited"
        setup.insert(local)
        try setup.save()

        let engine = FakeEngine()
        let receipt = CKRecord(
            recordType: "MigrationReceipt",
            recordID: CKRecord.ID(
                recordName: SeedkeepRecordNames.migrationReceipt(hid), zoneID: zoneID(hid)))
        engine.store.setRecord(receipt)

        await makeCoordinator(engine: engine, container: container, householdID: hid).sync()

        #expect(engine.savedRecords.contains { $0.recordID.recordName == "seed:s1" },
                "an already-migrated retry must still push the current local edit")
    }

    @Test("householdID derives from the (shared) zone name")
    func householdIDFromZoneName() {
        #expect(SeedkeepRecordNames.householdID(fromZoneName: "seedkeep-hh1") == "hh1")
        #expect(SeedkeepRecordNames.householdID(fromZoneName: "seedkeep-ABC-123") == "ABC-123")
        #expect(SeedkeepRecordNames.householdID(fromZoneName: "noprefix") == "noprefix")
    }

    // MARK: - Account change (AC5)

    @Test("a stable drain commits synced state")
    func stableDrainCommitsSyncedState() async throws {
        let hid = "hh-\(UUID().uuidString)"
        let container = makeContainer()
        let engine = FakeEngine()
        let coordinator = makeCoordinator(engine: engine, container: container, householdID: hid)
        await coordinator.sync()

        let setup = ModelContext(container)
        setup.insert(LocalSeed(id: "s1", householdID: hid, state: .active, packetCount: 1, source: .store, createdAt: 1, updatedAt: 500))
        try setup.save()
        let gate = DrainGate()
        engine.drainGate = gate
        let syncTask = Task { await coordinator.sync() }
        await gate.waitUntilStarted()
        await gate.release()
        _ = await syncTask.value

        let url = HouseholdCloudCoordinator.ownerSyncedStateURL(householdID: hid)
        let data = try Data(contentsOf: url)
        let state = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(state["seed:s1"] != nil, "a stable push must commit the staged record")
    }

    @Test("a mid-drain account wipe does not commit stale synced state")
    func midDrainAccountWipeDoesNotCommitStaleSyncedState() async throws {
        let hid = "hh-\(UUID().uuidString)"
        let container = makeContainer()
        let engine = FakeEngine()
        let coordinator = makeCoordinator(engine: engine, container: container, householdID: hid)
        await coordinator.sync()

        let setup = ModelContext(container)
        setup.insert(LocalSeed(id: "s1", householdID: hid, state: .active, packetCount: 1, source: .store, createdAt: 1, updatedAt: 500))
        try setup.save()
        let url = HouseholdCloudCoordinator.ownerSyncedStateURL(householdID: hid)
        let gate = DrainGate()
        engine.drainGate = gate
        let syncTask = Task { await coordinator.sync() }
        await gate.waitUntilStarted()

        coordinator.handleAccountChange(.signOut)
        await gate.release()
        _ = await syncTask.value

        #expect(FileManager.default.fileExists(atPath: url.path) == false,
                "a stale push must not recreate synced state after an account wipe")
    }

    @Test("signOut wipes household SwiftData; signIn does not")
    func accountWipe() async throws {
        let hid = "hh-\(UUID().uuidString)"
        let container = makeContainer()
        let engine = FakeEngine()
        let coordinator = makeCoordinator(engine: engine, container: container, householdID: hid)
        let setup = ModelContext(container)
        setup.insert(LocalSeed(id: "s1", householdID: hid, state: .active, packetCount: 1, source: .store, createdAt: 1, updatedAt: 1))
        setup.insert(LocalBed(id: "b1", householdID: hid, name: "North", createdAt: 1, updatedAt: 1))
        setup.insert(LocalCloudKitDeletion(
            scopeID: HouseholdCloudCoordinator.ownerScopeID(householdID: hid), householdID: hid,
            recordName: SeedkeepRecordNames.journalChecklistItem("pending"),
            createdAt: 1
        ))
        try setup.save()

        coordinator.handleAccountChange(.signIn)
        #expect(fetchSeed(ModelContext(container), "s1") != nil, "signIn must not wipe")

        coordinator.handleAccountChange(.signOut)
        let c = ModelContext(container)
        #expect((try? c.fetch(FetchDescriptor<LocalSeed>()))?.isEmpty == true)
        #expect((try? c.fetch(FetchDescriptor<LocalBed>()))?.isEmpty == true)
        #expect((try? c.fetch(FetchDescriptor<LocalCloudKitDeletion>()))?.isEmpty == true,
                "an old account's unconfirmed delete must never replay into a replacement account")
    }

    @Test("wipeAndClear removes the durable per-record synced-state file")
    func wipeRemovesSyncedStateFile() async throws {
        let hid = "hh-\(UUID().uuidString)"
        let container = makeContainer()
        let engine = FakeEngine()
        let coordinator = makeCoordinator(engine: engine, container: container, householdID: hid)
        await coordinator.sync()   // start (empty)

        let setup = ModelContext(container)
        setup.insert(LocalSeed(id: "s1", householdID: hid, state: .active, packetCount: 1, source: .store, createdAt: 1, updatedAt: 500))
        try setup.save()
        await coordinator.sync()   // pushes s1 → commits the synced-state file

        let url = HouseholdCloudCoordinator.ownerSyncedStateURL(householdID: hid)
        #expect(FileManager.default.fileExists(atPath: url.path), "a push must commit the synced-state file")

        coordinator.handleAccountChange(.signOut)
        #expect(FileManager.default.fileExists(atPath: url.path) == false,
                "wipeAndClear must remove the durable synced-state file")
    }
}
