import CloudKit
import Foundation
import SwiftData
import Testing
@testable import Seedkeep
import SeedkeepCloudKit

/// N2-E (G2) §3 and §5: the start checks, the per-batch root check and the gone signals, run on the
/// real `HouseholdCloudCoordinator` over `FakeEngine` (which drives the production `GardenSendGate`
/// exactly as the real engine's delegate does) and `FakeGardenProvisioner`. No CloudKit.
@MainActor
@Suite("Deleted-garden guard: checks and signals", .serialized)
struct GardenGoneCoordinatorTests {
    nonisolated static let account = "_userA|production"
    nonisolated static let otherAccount = "_userB|production"
    nonisolated static let created = Date(timeIntervalSince1970: 1_000)   // generation 1_000_000
    nonisolated static let generation: Int64 = 1_000_000

    final class AccountBox: @unchecked Sendable {
        var key: String?
        init(_ key: String?) { self.key = key }
    }

    final class Flag: @unchecked Sendable {
        var value = false
    }

    struct Rig {
        let coordinator: HouseholdCloudCoordinator
        let provisioner: FakeGardenProvisioner
        let store: GardenGuardStore
        let runner: GardenGuardRunner
        let engine: HouseholdCloudCoordinatorTests.FakeEngine
        let box: AccountBox
        let householdID: String
        let container: ModelContainer
    }

    /// An established garden (no grant). `recorded` is the generation the guard already holds for it
    /// (nil: nothing recorded, trust on first use; `seen: false`: never seen).
    static func rig(
        householdID: String = "hhr_\(UUID().uuidString)",
        participant: Bool = false,
        root: FakeGardenProvisioner.Root = .present(creationDate: created),
        recorded: Int64? = generation,
        seen: Bool = true,
        store: GardenGuardStore? = nil,
        provisioner: FakeGardenProvisioner? = nil,
        batchesPerSend: Int = 1,
        box: AccountBox? = nil
    ) throws -> Rig {
        let store = store ?? GardenGuardStore(directory: GuardTestDirectory.make())
        let provisioner = provisioner ?? FakeGardenProvisioner()
        let box = box ?? AccountBox(account)
        let engine = HouseholdCloudCoordinatorTests.FakeEngine()
        engine.batchesPerSend = batchesPerSend
        let zoneID: CKRecordZone.ID
        if participant {
            zoneID = CKRecordZone.ID(zoneName: SeedkeepRecordNames.zoneName(householdID: householdID), ownerName: "_owner")
            try store.setBinding(account, GardenGuardBinding(
                household: .init(id: "hhr_own", name: "Mine", createdAt: 1, updatedAt: 1),
                participant: .init(zoneName: zoneID.zoneName, ownerName: "_owner")))
        } else {
            zoneID = SeedkeepZoneProvisioner.zoneID(householdID: householdID)
            try store.setBinding(account, GardenGuardBinding(
                household: .init(id: householdID, name: "Mine", createdAt: 1, updatedAt: 1), participant: nil))
        }
        provisioner.setRoot(householdID: householdID, root)
        if seen { try store.recordSeen(account, householdID, generation: recorded) }
        let container = makeTestContainer(name: "gone-\(UUID().uuidString)")
        let coordinator = HouseholdCloudCoordinator(
            engine: engine, zoneID: zoneID, householdID: householdID, householdName: "Mine",
            householdCreatedAt: 1, householdUpdatedAt: 1, container: container,
            provisioner: participant ? nil : provisioner, stateURL: nil, isParticipant: participant,
            inspector: participant ? provisioner : nil)
        let runner = GardenGuardRunner(store: store, rehomer: RecordingRehomer())
        coordinator.guardContext = GardenGuardContext(
            store: store, accountKey: { box.key }, rehomer: RecordingRehomer(), runner: runner)
        return Rig(coordinator: coordinator, provisioner: provisioner, store: store, runner: runner,
                   engine: engine, box: box, householdID: householdID, container: container)
    }

    /// Lets the main-actor tasks the engine's signals spawn run.
    static func settle() async {
        for _ in 0..<80 { await Task.yield() }
    }

    static func stagePendingRecord(_ rig: Rig) {
        let id = CKRecord.ID(recordName: "seed:pending-\(UUID().uuidString)",
                             zoneID: SeedkeepZoneProvisioner.zoneID(householdID: rig.householdID))
        rig.engine.save(CKRecord(recordType: "Seed", recordID: id))
        rig.engine.hasPendingRecordChanges = true
    }

    // MARK: - Start checks: the established owner garden (§3)

    @Test("a zone missing from the listing is gone: nothing is created or sent, and the entry is written")
    func missingZoneIsGone() async throws {
        let rig = try Self.rig(root: .zoneMissing)
        await rig.coordinator.sync()
        #expect(rig.coordinator.isGone)
        #expect(rig.coordinator.goneReason == .zoneMissing)
        #expect(rig.store.isGone(Self.account, rig.householdID))
        #expect(rig.store.journal(Self.account, rig.householdID)?.phase == .awaitingChoice)
        #expect(rig.provisioner.totalCreations == 0)
        #expect(rig.provisioner.shareSaves.isEmpty)
        #expect(rig.engine.sendUntilDrainedCallCount == 0)
        #expect(rig.engine.fetchChangesCallCount == 0)
        #expect(rig.coordinator.lastHumanizedError == nil)   // gone is not a sync hiccup
        #expect(rig.runner.scopeEpoch > 0)
        // A gone coordinator stays stopped.
        #expect(await rig.coordinator.sync() == false)
        #expect(rig.provisioner.inspectCalls.count == 1)
    }

    @Test("a root confirmed missing in an existing zone is gone, never re-created")
    func missingRootIsGone() async throws {
        let rig = try Self.rig(root: .rootMissing)
        await rig.coordinator.sync()
        #expect(rig.coordinator.goneReason == .rootMissing)
        #expect(rig.store.isGone(Self.account, rig.householdID))
        #expect(rig.provisioner.rootSaves.isEmpty)
        #expect(rig.provisioner.zoneSaves.isEmpty)
        #expect(rig.engine.savedRecords.isEmpty)
    }

    @Test("a root whose creationDate differs from the recorded generation is gone (recreated)")
    func recreatedRootIsGone() async throws {
        let rig = try Self.rig(root: .present(creationDate: Date(timeIntervalSince1970: 2_000)))
        await rig.coordinator.sync()
        #expect(rig.coordinator.goneReason == .recreated)
        #expect(rig.store.isGone(Self.account, rig.householdID))
        #expect(rig.engine.sendUntilDrainedCallCount == 0)
        #expect(rig.provisioner.shareSaves.isEmpty)
        // The recorded generation is not overwritten by the recreated root.
        #expect(rig.store.seen(Self.account, rig.householdID)?.generation == Self.generation)
    }

    @Test("no recorded generation is trust on first use: it is recorded, and the garden proceeds")
    func trustOnFirstUse() async throws {
        let rig = try Self.rig(root: .present(creationDate: Date(timeIntervalSince1970: 2_000)), recorded: nil)
        await rig.coordinator.sync()
        #expect(!rig.coordinator.isGone)
        #expect(rig.store.seen(Self.account, rig.householdID)?.generation == 2_000_000)
        #expect(rig.provisioner.shareSaves.count == 1)
        #expect(rig.coordinator.lastHumanizedError == nil)
    }

    @Test("a matching generation proceeds; a garden never seen is recorded")
    func matchingGenerationProceeds() async throws {
        let rig = try Self.rig(seen: false)
        await rig.coordinator.sync()
        #expect(!rig.coordinator.isGone)
        #expect(rig.store.seen(Self.account, rig.householdID)?.generation == Self.generation)
        #expect(rig.provisioner.shareSaves.count == 1)
    }

    @Test("a network, account or unknown error is not gone: nothing is sent and the pass retries as today")
    func listingErrorIsNotGone() async throws {
        for error in [CKError(.networkUnavailable), CKError(.notAuthenticated), CKError(.serviceUnavailable)] {
            let rig = try Self.rig(root: .zoneMissing)   // even a garden whose zone is missing
            rig.provisioner.failInspections(error, error)
            await rig.coordinator.sync()
            #expect(!rig.coordinator.isGone)
            #expect(!rig.store.isGone(Self.account, rig.householdID))
            #expect(rig.engine.sendUntilDrainedCallCount == 0)
            #expect(rig.engine.fetchChangesCallCount == 0)
            #expect(rig.provisioner.totalCreations == 0)
        }
    }

    @Test("an unreadable root is not gone either")
    func unreadableRootIsNotGone() async throws {
        let rig = try Self.rig()
        rig.provisioner.failInspections(SyncEngineError.batchCheckFailed(.timedOut), SyncEngineError.batchCheckFailed(.timedOut))
        await rig.coordinator.sync()
        #expect(!rig.coordinator.isGone)
        #expect(rig.coordinator.lastHumanizedError != nil)
        #expect(rig.engine.sendUntilDrainedCallCount == 0)
    }

    @Test("a coordinator built for a garden that is already gone inspects nothing and sends nothing")
    func alreadyGoneStaysStopped() async throws {
        let rig = try Self.rig()
        try rig.store.markGone(Self.account, rig.householdID, reason: .zoneDeleted)
        await rig.coordinator.sync()
        #expect(rig.provisioner.inspectCalls.isEmpty)
        #expect(rig.engine.fetchChangesCallCount == 0)
        #expect(rig.engine.sendUntilDrainedCallCount == 0)
        #expect(rig.coordinator.lastHumanizedError == "This garden is no longer in iCloud.")
    }

    @Test("an account switch during the zone listing writes nothing and sends nothing")
    func accountSwitchDuringStartListing() async throws {
        let rig = try Self.rig(root: .zoneMissing)
        let box = rig.box
        rig.provisioner.onInspect { box.key = Self.otherAccount }
        await rig.coordinator.sync()
        #expect(!rig.coordinator.isGone)
        #expect(!rig.store.isGone(Self.account, rig.householdID))
        #expect(!rig.store.isGone(Self.otherAccount, rig.householdID))
        #expect(rig.engine.sendUntilDrainedCallCount == 0)
    }

    @Test("a Reset guard (no grant, no seen record) treats an absent zone as gone and never creates it")
    func resetNeverCreates() async throws {
        let rig = try Self.rig(root: .zoneMissing, seen: false)
        try rig.store.reset()
        try rig.store.setBinding(Self.account, GardenGuardBinding(
            household: .init(id: rig.householdID, name: "Mine", createdAt: 1, updatedAt: 1), participant: nil))
        await rig.coordinator.sync()
        #expect(rig.store.isGone(Self.account, rig.householdID))
        #expect(rig.provisioner.totalCreations == 0)
    }

    @Test("a cold relaunch with pending writes into a deleted zone detects before sending")
    func coldRelaunchDetectsBeforeSending() async throws {
        let rig = try Self.rig(root: .zoneMissing)
        Self.stagePendingRecord(rig)   // restored engine state: changes waiting for a zone that is gone
        await rig.coordinator.sync()
        #expect(rig.store.isGone(Self.account, rig.householdID))
        #expect(rig.engine.sendUntilDrainedCallCount == 0)
        #expect(rig.engine.batchesSent == 0)
        #expect(rig.engine.staged == 0)   // discarded with the retired generation
    }

    @Test("a crash before the gone write repeats the detection at the next start")
    func crashBeforeGoneWriteRepeatsDetection() async throws {
        let failing = Flag()
        let directory = GuardTestDirectory.make()
        let store = GardenGuardStore(directory: directory, write: { data, url in
            if failing.value { throw CocoaError(.fileWriteUnknown) }
            try GardenGuardStore.atomicWrite(data, to: url)
        })
        let first = try Self.rig(root: .zoneMissing, store: store)
        failing.value = true
        Self.stagePendingRecord(first)
        await first.coordinator.sync()
        // The commit point failed: the coordinator stays stopped, nothing was sent, nothing recorded.
        #expect(first.coordinator.isGone)
        #expect(first.coordinator.goneCommitFailed)
        #expect(first.coordinator.lastHumanizedError != nil)
        #expect(!store.isGone(Self.account, first.householdID))
        #expect(first.engine.batchesSent == 0)

        // Next start (a new coordinator over the same guard): the detection repeats and now commits.
        failing.value = false
        let second = try Self.rig(householdID: first.householdID, root: .zoneMissing, recorded: Self.generation,
                                  store: store, provisioner: first.provisioner)
        await second.coordinator.sync()
        #expect(store.isGone(Self.account, first.householdID))
        #expect(second.engine.batchesSent == 0)
    }

    // MARK: - Batch check (§3)

    @Test("the root is read before every batch and once before the share save: the cost per send")
    func rootReadOncePerBatch() async throws {
        let rig = try Self.rig(batchesPerSend: 3)
        await rig.coordinator.sync()   // start (share check) + the migration's send of three batches
        #expect(rig.engine.batchesSent == 3)
        #expect(rig.provisioner.readRootCalls.count == 1 + 3)
        Self.stagePendingRecord(rig)
        await rig.coordinator.sync()   // another send of three batches
        #expect(rig.engine.batchesSent == 6)
        #expect(rig.provisioner.readRootCalls.count == 1 + 3 + 3)
        #expect(rig.engine.sendGate.checkCount == 6)
        #expect(!rig.coordinator.isGone)
    }

    @Test("a mismatch on the second batch stops the send: one batch went out, none after")
    func mismatchOnSecondBatch() async throws {
        let rig = try Self.rig(batchesPerSend: 3)
        let ok = GardenRootRead.present(GardenRootSnapshot(
            record: CKRecord(recordType: "Household", recordID: CKRecord.ID(recordName: "household:x")),
            creationDate: Self.created))
        let recreated = GardenRootRead.present(GardenRootSnapshot(
            record: CKRecord(recordType: "Household", recordID: CKRecord.ID(recordName: "household:x")),
            creationDate: Date(timeIntervalSince1970: 3_000)))
        rig.provisioner.scriptReads(ok, ok, recreated)   // share check, first batch, second batch
        await rig.coordinator.sync()
        #expect(rig.engine.batchesSent == 1)
        #expect(rig.coordinator.isGone)
        #expect(rig.coordinator.goneReason == .recreated)
        #expect(rig.store.isGone(Self.account, rig.householdID))
        #expect(rig.engine.sendGate.isFenced)
        #expect(rig.engine.staged == 0)   // discarded with the retired generation
        // Zero new sends afterwards.
        let sends = rig.engine.sendUntilDrainedCallCount
        #expect(await rig.coordinator.sync() == false)
        #expect(rig.engine.sendUntilDrainedCallCount == sends)
        #expect(rig.engine.batchesSent == 1)
    }

    @Test("a missing zone or root found by the batch check is gone")
    func batchCheckMissingIsGone() async throws {
        for (read, reason) in [(GardenRootRead.zoneMissing, GardenGoneRecord.Reason.zoneMissing),
                               (.rootMissing, .rootMissing)] {
            let rig = try Self.rig()
            let ok = GardenRootRead.present(GardenRootSnapshot(
                record: CKRecord(recordType: "Household", recordID: CKRecord.ID(recordName: "household:x")),
                creationDate: Self.created))
            rig.provisioner.scriptReads(ok, read)   // share check passes; the first batch finds it gone
            await rig.coordinator.sync()
            #expect(rig.coordinator.goneReason == reason)
            #expect(rig.engine.batchesSent == 0)
        }
    }

    @Test("a failed check stops the drain loop with the pending changes kept, and is not gone")
    func failedCheckKeepsPending() async throws {
        let rig = try Self.rig(batchesPerSend: 3)
        let ok = GardenRootRead.present(GardenRootSnapshot(
            record: CKRecord(recordType: "Household", recordID: CKRecord.ID(recordName: "household:x")),
            creationDate: Self.created))
        // Share check ok; the first batch's check times out; the retry's share check times out too.
        rig.provisioner.scriptReads(ok, .failed(.timedOut), .failed(.timedOut))
        await rig.coordinator.sync()
        #expect(!rig.coordinator.isGone)
        #expect(!rig.store.isGone(Self.account, rig.householdID))
        #expect(rig.engine.batchesSent == 0)
        #expect(rig.engine.staged > 0)             // the migration's records stay queued
        #expect(rig.coordinator.lastHumanizedError != nil)   // today's backoff: the pass ended with an error
        #expect(rig.engine.sendUntilDrainedCallCount == 1)   // the loop stopped, it did not send again
    }

    @Test("an account switch while the root is read fails the check: not gone")
    func accountSwitchDuringBatchCheck() async throws {
        let rig = try Self.rig()
        await rig.coordinator.sync()
        let box = rig.box
        rig.provisioner.onReadRoot { box.key = Self.otherAccount }
        // Even a root that would be a mismatch is not acted on for an account that has moved on.
        rig.provisioner.setRoot(householdID: rig.householdID, .zoneMissing)
        let outcome = await rig.coordinator.performBatchCheck(0)
        #expect(outcome == .failed(.superseded))
        #expect(!rig.coordinator.isGone)
        #expect(!rig.store.isGone(Self.account, rig.householdID))
    }

    @Test("an epoch change while the root is read fails the check: not gone")
    func epochChangeDuringBatchCheck() async throws {
        let rig = try Self.rig()
        await rig.coordinator.sync()
        let coordinator = rig.coordinator
        rig.provisioner.onReadRoot { await MainActor.run { coordinator.wipeAndClear() } }
        rig.provisioner.setRoot(householdID: rig.householdID, .zoneMissing)
        let outcome = await rig.coordinator.performBatchCheck(0)
        #expect(outcome == .failed(.superseded))
        #expect(!rig.coordinator.isGone)
    }

    @Test("an account change that pauses CloudKit during the share check shares and sends nothing")
    func pausedDuringShareCheck() async throws {
        let rig = try Self.rig()
        let box = rig.box
        let coordinator = rig.coordinator
        rig.provisioner.onReadRoot {
            box.key = Self.otherAccount
            await MainActor.run { coordinator.isCloudKitAllowed = { false } }
        }
        await rig.coordinator.sync()
        #expect(!rig.coordinator.isGone)
        #expect(rig.provisioner.shareSaves.isEmpty)
        #expect(rig.engine.batchesSent == 0)
        #expect(rig.engine.sendUntilDrainedCallCount == 0)
    }

    // MARK: - Gone signals (§5)

    private func started(_ rig: Rig) async {
        await rig.coordinator.sync()
        #expect(!rig.coordinator.isGone)
    }

    @Test("every deletion reason is a gone signal that fences with zero new sends", arguments: ZoneDeletionReason.allCases)
    func deletionReasonFences(reason: ZoneDeletionReason) async throws {
        let rig = try Self.rig()
        await started(rig)
        Self.stagePendingRecord(rig)
        let before = (rig.engine.batchesSent, rig.engine.sendUntilDrainedCallCount)
        rig.engine.fire(.gone(.zoneDeleted(reason)))
        #expect(rig.engine.sendGate.isFenced)   // fenced at once, before the main-actor hop
        await Self.settle()
        #expect(rig.coordinator.isGone)
        #expect(rig.coordinator.goneReason == .zoneDeleted)
        #expect(rig.store.isGone(Self.account, rig.householdID))
        #expect(rig.engine.staged == 0)
        #expect(await rig.coordinator.sync() == false)
        #expect(rig.engine.batchesSent == before.0)
        #expect(rig.engine.sendUntilDrainedCallCount == before.1)
    }

    @Test("a zone fetch error or a failed save with zoneNotFound or userDeletedZone is gone",
          arguments: [GardenGoneCause.zoneNotFound, .userDeletedZone])
    func zoneErrorFences(cause: GardenGoneCause) async throws {
        let rig = try Self.rig()
        await started(rig)
        Self.stagePendingRecord(rig)
        let sends = rig.engine.sendUntilDrainedCallCount
        rig.engine.fire(.gone(cause))
        await Self.settle()
        #expect(rig.coordinator.isGone)
        #expect(rig.coordinator.goneReason == .zoneMissing)
        #expect(rig.store.isGone(Self.account, rig.householdID))
        #expect(await rig.coordinator.sync() == false)
        #expect(rig.engine.sendUntilDrainedCallCount == sends)
    }

    @Test("the entry is written once, in one step, however many signals arrive (two windows share one runner)")
    func oneEntryManySignals() async throws {
        let rig = try Self.rig()
        await started(rig)
        rig.engine.fire(.gone(.zoneDeleted(.deleted)))
        rig.engine.fire(.gone(.zoneNotFound))
        rig.engine.fire(.gone(.recreated))
        await Self.settle()
        #expect(rig.runner.goneCommits == 1)
        #expect(rig.store.account(Self.account).gone.count == 1)
        #expect(rig.coordinator.goneReason == .zoneDeleted)   // the first signal wins
        // A third party asking the runner directly changes nothing either.
        #expect(rig.runner.commitGone(GardenGoneEvent(accountKey: Self.account, householdID: rig.householdID,
                                                      reason: .recreated)))
        #expect(rig.store.journal(Self.account, rig.householdID)?.reason == .zoneDeleted)
    }

    @Test("a deletion outranks changes fetched in the same batch: nothing lands in a gone garden")
    func deletionOutranksModification() async throws {
        let rig = try Self.rig()
        await started(rig)
        rig.engine.fire(.gone(.zoneDeleted(.purged)))
        let zone = SeedkeepZoneProvisioner.zoneID(householdID: rig.householdID)
        let local = LocalSeed(id: "s-late", householdID: rig.householdID, state: .active, packetCount: 1,
                              source: .store, createdAt: 1, updatedAt: 5)
        rig.engine.pendingFetch = ([SeedkeepRecordCodec.encode(local.cloudKitValue, zoneID: zone)], [])
        try await rig.engine.fetchChanges()
        #expect(rig.engine.ignoredFetchesWhileFenced == 1)
        let rows = try ModelContext(rig.container).fetch(FetchDescriptor<LocalSeed>())
        #expect(rows.isEmpty)
    }

    @Test("an ambiguous signal stops sends for the pass and retires nothing; the next pass lifts it")
    func ambiguousStopsThePass() async throws {
        let rig = try Self.rig()
        await started(rig)
        Self.stagePendingRecord(rig)
        rig.engine.fire(.ambiguous)
        await Self.settle()
        #expect(rig.coordinator.sendsStoppedForPass)
        #expect(!rig.coordinator.isGone)
        #expect(!rig.store.isGone(Self.account, rig.householdID))
        #expect(rig.engine.sendGate.isHeld)
        // The next pass releases the hold and sends.
        let sent = rig.engine.batchesSent
        await rig.coordinator.sync()
        #expect(!rig.coordinator.sendsStoppedForPass)
        #expect(rig.engine.releaseSendHoldCalls >= 2)
        #expect(rig.engine.batchesSent > sent)
    }

    @Test("an owner's permission failure without a confirmed read-only permission is ambiguous")
    func ownerPermissionFailureIsAmbiguous() async throws {
        let rig = try Self.rig()
        await started(rig)
        rig.engine.fire(.permissionDenied)
        await Self.settle()
        #expect(rig.coordinator.sendsStoppedForPass)
        #expect(!rig.coordinator.isViewOnly)
        #expect(!rig.coordinator.isGone)
    }

    // MARK: - Participants (§5)

    @Test("a share whose permission is read-only is view only: sends stop and fetching continues")
    func viewOnlyByParticipantPermission() async throws {
        let rig = try Self.rig(participant: true)
        rig.provisioner.permission = .readOnly
        Self.stagePendingRecord(rig)
        await rig.coordinator.sync()
        #expect(rig.coordinator.isViewOnly)
        #expect(!rig.coordinator.isGone)
        #expect(rig.engine.fetchChangesCallCount >= 1)
        #expect(rig.engine.sendUntilDrainedCallCount == 0)
        #expect(rig.engine.batchesSent == 0)
        #expect(!rig.store.isGone(Self.account, rig.householdID))
        #expect(AppEnvironment.viewOnlyNotice == "You can view this shared garden but not change it.")
    }

    @Test("a permission failure is view only only when the permission is confirmed read-only")
    func permissionFailureNeedsConfirmedReadOnly() async throws {
        let writable = try Self.rig(participant: true)
        await writable.coordinator.sync()
        #expect(!writable.coordinator.isViewOnly)
        writable.engine.fire(.permissionDenied)
        await Self.settle()
        #expect(!writable.coordinator.isViewOnly)     // readWrite: ambiguous
        #expect(writable.coordinator.sendsStoppedForPass)
        #expect(!writable.coordinator.isGone)

        let readOnly = try Self.rig(participant: true)
        await readOnly.coordinator.sync()
        readOnly.provisioner.permission = .readOnly
        readOnly.engine.fire(.permissionDenied)
        await Self.settle()
        #expect(readOnly.coordinator.isViewOnly)
        let unknown = try Self.rig(participant: true)
        await unknown.coordinator.sync()
        unknown.provisioner.permission = .unknown
        unknown.engine.fire(.permissionDenied)
        await Self.settle()
        #expect(!unknown.coordinator.isViewOnly)
    }

    @Test("a seen shared zone missing from the shared listing is access lost (gone)")
    func accessLost() async throws {
        let rig = try Self.rig(participant: true, root: .zoneMissing)
        Self.stagePendingRecord(rig)
        await rig.coordinator.sync()
        #expect(rig.coordinator.isGone)
        #expect(rig.coordinator.goneReason == .accessLost)
        #expect(rig.store.journal(Self.account, rig.householdID)?.reason == .accessLost)
        #expect(rig.engine.fetchChangesCallCount == 0)
        #expect(rig.engine.sendUntilDrainedCallCount == 0)
    }

    @Test("a shared garden recreated under the same name is gone when its generation differs")
    func participantRecreatedIsGone() async throws {
        let rig = try Self.rig(participant: true, root: .present(creationDate: Date(timeIntervalSince1970: 9_000)))
        await rig.coordinator.sync()
        #expect(rig.coordinator.goneReason == .recreated)
        #expect(rig.store.isGone(Self.account, rig.householdID))
        #expect(rig.engine.fetchChangesCallCount == 0)
    }

    @Test("a just-accepted share not yet seen is never gone: today's propagation-delay handling goes on")
    func notYetAvailable() async throws {
        let rig = try Self.rig(participant: true, root: .zoneMissing, seen: false)
        await rig.coordinator.sync()
        #expect(!rig.coordinator.isGone)
        #expect(!rig.store.isGone(Self.account, rig.householdID))
        #expect(rig.engine.fetchChangesCallCount >= 1)   // the accept-race fetches still run
        #expect(rig.store.account(Self.account).retired.isEmpty)
    }

    @Test("a participant's deletion signal is confirmed by the shared listing before it is gone")
    func participantSignalConfirmedByListing() async throws {
        let confirmed = try Self.rig(participant: true)
        await confirmed.coordinator.sync()
        #expect(!confirmed.coordinator.isGone)
        confirmed.provisioner.setRoot(householdID: confirmed.householdID, .zoneMissing)
        confirmed.engine.fire(.gone(.zoneDeleted(.deleted)))
        #expect(confirmed.engine.sendGate.isFenced)   // sends stop at once, while the listing is read
        await Self.settle()
        #expect(confirmed.coordinator.isGone)
        #expect(confirmed.coordinator.goneReason == .accessLost)

        let refuted = try Self.rig(participant: true)
        await refuted.coordinator.sync()
        refuted.engine.fire(.gone(.zoneNotFound))      // the listing still shows the zone
        await Self.settle()
        #expect(!refuted.coordinator.isGone)
        #expect(!refuted.store.isGone(Self.account, refuted.householdID))
        #expect(refuted.engine.clearFenceCalls == 1)
        #expect(!refuted.engine.sendGate.isFenced)
        #expect(refuted.coordinator.sendsStoppedForPass)

        let ambiguous = try Self.rig(participant: true)
        await ambiguous.coordinator.sync()
        ambiguous.provisioner.failInspections(CKError(.networkFailure))
        ambiguous.engine.fire(.gone(.zoneDeleted(.deleted)))
        await Self.settle()
        #expect(!ambiguous.coordinator.isGone)         // the listing could not confirm: nothing retired
        #expect(ambiguous.coordinator.sendsStoppedForPass)
    }

    @Test("a participant's batch check finds a missing seen zone gone, and an unseen one not available yet")
    func participantBatchCheck() async throws {
        let seen = try Self.rig(participant: true)
        await seen.coordinator.sync()
        seen.provisioner.setRoot(householdID: seen.householdID, .zoneMissing)
        let outcome = await seen.coordinator.performBatchCheck(0)
        #expect(outcome == .gone(.zoneNotFound))

        let unseen = try Self.rig(participant: true, root: .zoneMissing, seen: false)
        let waiting = await unseen.coordinator.performBatchCheck(0)
        #expect(waiting == .failed(.notAvailableYet))
    }

    @Test("an account switch during the participant's confirming listing retires nothing")
    func accountSwitchDuringConfirmation() async throws {
        let rig = try Self.rig(participant: true)
        await rig.coordinator.sync()
        rig.provisioner.setRoot(householdID: rig.householdID, .zoneMissing)
        let box = rig.box
        rig.provisioner.onInspect { box.key = Self.otherAccount }
        rig.engine.fire(.gone(.zoneDeleted(.deleted)))
        await Self.settle()
        #expect(!rig.coordinator.isGone)
        #expect(!rig.store.isGone(Self.account, rig.householdID))
    }

    @Test("an account switch during the participant's start listing retires nothing")
    func accountSwitchDuringParticipantStart() async throws {
        let rig = try Self.rig(participant: true, root: .zoneMissing)
        let box = rig.box
        rig.provisioner.onInspect { box.key = Self.otherAccount }
        await rig.coordinator.sync()
        #expect(!rig.coordinator.isGone)
        #expect(!rig.store.isGone(Self.account, rig.householdID))
        #expect(rig.engine.fetchChangesCallCount == 0)
    }

    // MARK: - Reasons

    @Test("the gone reason the guard records follows the cause and the role")
    func goneReasonMapping() {
        let owner: [(GardenGoneCause, GardenGoneRecord.Reason)] = [
            (.zoneDeleted(.deleted), .zoneDeleted), (.zoneDeleted(.purged), .zoneDeleted),
            (.zoneDeleted(.encryptedDataReset), .zoneDeleted), (.zoneNotFound, .zoneMissing),
            (.userDeletedZone, .zoneMissing), (.rootMissing, .rootMissing), (.recreated, .recreated),
        ]
        for (cause, reason) in owner {
            #expect(HouseholdCloudCoordinator.goneReason(for: cause, isParticipant: false) == reason)
        }
        for (cause, _) in owner where cause != .recreated {
            #expect(HouseholdCloudCoordinator.goneReason(for: cause, isParticipant: true) == .accessLost)
        }
        #expect(HouseholdCloudCoordinator.goneReason(for: .recreated, isParticipant: true) == .recreated)
    }
}
