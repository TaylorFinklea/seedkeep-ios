import CloudKit
import Foundation
import SwiftData
import Testing
@testable import Seedkeep
import SeedkeepKit
import SeedkeepCloudKit

/// N2-E (G2) review round: regression tests for the ordering bugs the reviews found. Each one runs
/// the real sequence (a signal during an active drain, an account change during an await, a failed
/// commit) on the real coordinator, runner and environment over fakes. No CloudKit.
@MainActor
@Suite("Deleted-garden guard: review fixes", .serialized)
struct GardenReviewFixTests {
    typealias Rig = GardenGoneCoordinatorTests.Rig
    static let account = GardenGoneCoordinatorTests.account
    static let otherAccount = GardenGoneCoordinatorTests.otherAccount
    static let keyA = GardenWriteFenceTests.keyA

    /// Records every share save; runs `beforeSave` first, like the real flow.
    final class FakeOwnerShares: OwnerShareMaking, @unchecked Sendable {
        private let lock = NSLock()
        private var _saves = 0
        var saves: Int { lock.withLock { _saves } }
        func makeOrFetch(householdID: String, title: String, beforeSave: @Sendable () async throws -> Void) async throws -> CKShare {
            try await beforeSave()
            lock.withLock { _saves += 1 }
            return CKShare(recordZoneID: SeedkeepZoneProvisioner.zoneID(householdID: householdID))
        }
    }

    // MARK: 1. Sharing checks the garden right before the save

    private static func shareEnv(
        _ name: String, root: FakeGardenProvisioner.Root = .present(creationDate: GardenGoneCoordinatorTests.created)
    ) async throws -> (GardenWriteFenceTests.Env, FakeGardenProvisioner, FakeOwnerShares) {
        let shares = FakeOwnerShares()
        let provisioner = FakeGardenProvisioner()
        provisioner.setRoot(householdID: "hhr_g", root)
        let rig = try GardenWriteFenceTests.makeEnv(name, ownerShares: shares, prepare: { store in
            try store.setBinding(keyA, GardenWriteFenceTests.binding("hhr_g"))
            try store.recordSeen(keyA, "hhr_g", generation: GardenGoneCoordinatorTests.generation)
        })
        rig.coordinators.provisioner = provisioner
        await rig.env.auth.restoreSession()
        return (rig, provisioner, shares)
    }

    @Test("a share is saved after the root's generation is read and matches")
    func shareSavedWhenGardenConfirmed() async throws {
        let (rig, provisioner, shares) = try await Self.shareEnv("shareOk")
        let share = await rig.env.makeOwnerShare()
        #expect(share != nil)
        #expect(shares.saves == 1)
        #expect(provisioner.readRootCalls.count == 1)
        #expect(!rig.env.isActiveGardenGone)
    }

    @Test("a recreated, missing-root or missing-zone garden is gone and nothing is shared")
    func shareRefusedWhenGone() async throws {
        for (root, reason) in [
            (FakeGardenProvisioner.Root.present(creationDate: Date(timeIntervalSince1970: 7_000)), GardenGoneRecord.Reason.recreated),
            (.rootMissing, .rootMissing), (.zoneMissing, .zoneMissing),
        ] {
            let (rig, _, shares) = try await Self.shareEnv("shareGone", root: root)
            let share = await rig.env.makeOwnerShare()
            #expect(share == nil)
            #expect(shares.saves == 0)
            #expect(rig.store.journal(Self.keyA, "hhr_g")?.reason == reason)
            #expect(rig.env.isActiveGardenGone)
            #expect(rig.env.writableGarden == nil)
            #expect(rig.env.bannerError == nil)   // gone is the placeholder, not a banner
        }
    }

    @Test("a root that cannot be read refuses the share without calling the garden gone")
    func shareRefusedWhenUnconfirmed() async throws {
        let (rig, provisioner, shares) = try await Self.shareEnv("shareUnread")
        provisioner.scriptReads(.failed(.timedOut))
        #expect(await rig.env.makeOwnerShare() == nil)
        #expect(shares.saves == 0)
        #expect(!rig.store.isGone(Self.keyA, "hhr_g"))
        #expect(rig.env.bannerError != nil)
    }

    @Test("a scope change or a wipe while the root is read refuses the share, and the garden is not gone")
    func shareRefusedWhenScopeMoves() async throws {
        let (rig, provisioner, shares) = try await Self.shareEnv("shareScope")
        let env = rig.env
        provisioner.onReadRoot { await MainActor.run { env.gardenRunner.bumpScopeEpoch() } }
        #expect(await env.makeOwnerShare() == nil)
        #expect(shares.saves == 0)
        #expect(!rig.store.isGone(Self.keyA, "hhr_g"))

        let (rig2, provisioner2, shares2) = try await Self.shareEnv("shareWipe")
        let built = rig2.coordinators
        provisioner2.onReadRoot {
            await MainActor.run { built.built.first?.coordinator.wipeAndClear() }
        }
        #expect(await rig2.env.makeOwnerShare() == nil)
        #expect(shares2.saves == 0)
        #expect(!rig2.store.isGone(Self.keyA, "hhr_g"))
    }

    // MARK: 2. Gone handling is bound to the pass's account, and a participant's waits for the listing

    @Test("a gone result from a drain is dropped when the account moved on: no entry under either account")
    func goneFromDrainDroppedAfterAccountChange() async throws {
        let rig = try GardenGoneCoordinatorTests.rig(batchesPerSend: 2)
        await rig.coordinator.sync()
        let box = rig.box
        rig.engine.batchCheck = { box.key = GardenGoneCoordinatorTests.otherAccount; return .gone(.recreated) }
        GardenGoneCoordinatorTests.stagePendingRecord(rig)
        await rig.coordinator.sync()
        await GardenGoneCoordinatorTests.settle()
        #expect(!rig.coordinator.isGone)
        #expect(!rig.store.isGone(Self.account, rig.householdID))
        #expect(!rig.store.isGone(Self.otherAccount, rig.householdID))
        #expect(rig.store.account(Self.otherAccount).gone.isEmpty)
    }

    @Test("a participant's gone signal during an active drain is not gone until the listing confirms it")
    func participantDrainSignalWaitsForListing() async throws {
        let rig = try GardenGoneCoordinatorTests.rig(participant: true, batchesPerSend: 3)
        await rig.coordinator.sync()
        let engine = rig.engine
        // The first batch's check sees a deletion event arrive while the drain is running.
        rig.engine.batchCheck = { engine.fire(.gone(.zoneDeleted(.deleted))); return .ok }
        GardenGoneCoordinatorTests.stagePendingRecord(rig)
        let sent = rig.engine.batchesSent
        await rig.coordinator.sync()          // the listing still shows the zone: refuted
        await GardenGoneCoordinatorTests.settle()
        #expect(!rig.coordinator.isGone)
        #expect(!rig.store.isGone(Self.account, rig.householdID))
        #expect(rig.engine.batchesSent == sent)   // no batch in the same pass after the signal
        #expect(rig.engine.sendGate.isHeld)       // the rest of the pass stays stopped
        #expect(!rig.engine.sendGate.isFenced)
        #expect(rig.coordinator.sendsStoppedForPass)
        // Batch admission honours the stop whatever the root says.
        let outcome = await rig.coordinator.performBatchCheck(0)
        #expect(outcome == .failed(.unavailable))
    }

    @Test("a participant's drain error with an ambiguous listing retires nothing")
    func participantDrainSignalAmbiguousListing() async throws {
        let rig = try GardenGoneCoordinatorTests.rig(participant: true, batchesPerSend: 3)
        await rig.coordinator.sync()
        let engine = rig.engine
        rig.engine.batchCheck = { engine.fire(.gone(.zoneNotFound)); return .ok }
        rig.provisioner.failInspections(CKError(.networkFailure), CKError(.networkFailure))
        GardenGoneCoordinatorTests.stagePendingRecord(rig)
        await rig.coordinator.sync()
        await GardenGoneCoordinatorTests.settle()
        #expect(!rig.coordinator.isGone)
        #expect(!rig.store.isGone(Self.account, rig.householdID))
    }

    @Test("with no account to write under, the garden is fenced in memory and every writer stops")
    func noAccountStillFences() async throws {
        let rig = try GardenGoneCoordinatorTests.rig()
        await rig.coordinator.sync()
        let epoch = rig.runner.scopeEpoch
        rig.box.key = nil
        rig.coordinator.handleGone(.zoneNotFound)
        #expect(rig.coordinator.isGone)
        #expect(rig.runner.scopeEpoch == epoch + 1)
        #expect(rig.runner.isBlocked(account: Self.account, householdID: rig.householdID))
        #expect(rig.store.account(Self.account).gone.isEmpty)   // nothing written under any account
    }

    // MARK: 3. A listed shared zone is not confirmed missing

    @Test("a shared zone the listing shows is never confirmed missing by a missing-zone read")
    func listedZoneIsNotGone() {
        let zone = GardenRootRead.zoneMissing
        if case .failed = LiveGardenProvisioner.confirmed(zone, listed: true) {} else { Issue.record("listed zone: unconfirmed") }
        if case .zoneMissing = LiveGardenProvisioner.confirmed(zone, listed: false) {} else { Issue.record("unlisted: gone") }
        if case .rootMissing = LiveGardenProvisioner.confirmed(.rootMissing, listed: true) {} else { Issue.record("root stays missing") }
        if case .zoneMissing = LiveGardenProvisioner.confirmed(.rootMissing, listed: false) {} else { Issue.record("unlisted: zone missing") }
        if case .failed(.timedOut) = LiveGardenProvisioner.confirmed(.failed(.timedOut), listed: false) {} else { Issue.record("failures pass through") }
    }

    // MARK: 4. A failed commit still fences the garden for the process

    @Test("when the gone entry can't be written the garden is fenced in memory for the rest of the process")
    func failedCommitFencesInMemory() async throws {
        final class Flag: @unchecked Sendable { var failing = false }
        let flag = Flag()
        let store = GardenGuardStore(directory: GuardTestDirectory.make(), write: { data, url in
            if flag.failing { throw CocoaError(.fileWriteUnknown) }
            try GardenGuardStore.atomicWrite(data, to: url)
        })
        let provisioner = FakeGardenProvisioner()
        provisioner.setRoot(householdID: "hhr_g", .zoneMissing)
        let rig = try GardenWriteFenceTests.makeEnv("failedCommit", store: store, prepare: {
            try $0.setBinding(Self.keyA, GardenWriteFenceTests.binding("hhr_g"))
            try $0.recordSeen(Self.keyA, "hhr_g", generation: GardenGoneCoordinatorTests.generation)
        })
        rig.coordinators.provisioner = provisioner
        await rig.env.auth.restoreSession()
        flag.failing = true
        await rig.env.syncIfPossible()

        let env = rig.env
        #expect(!store.isGone(Self.keyA, "hhr_g"))        // nothing durable: detection repeats at launch
        #expect(env.writableGarden == nil)                 // but nothing may write
        #expect(env.isActiveGardenGone)
        #expect(env.writableScopeToken() == nil)           // no notification is scheduled
        #expect(rig.notifier.removedAll == 1)
        let refused = await GardenWriteFenceTests.isRefused { _ = try env.sync.enqueueCreateLocation(name: "x", householdID: "hhr_g") }
        #expect(refused)
        await env.syncIfPossible()
        #expect(provisioner.inspectCalls.count == 1)       // and it stays stopped
    }

    // MARK: 5 and 6. The launch gate and a single hand-off

    @Test("the runner does not open the gate without a verified account")
    func runnerNeedsAccount() {
        let store = GardenGuardStore(directory: nil)
        try? store.setBinding(Self.keyA, GardenWriteFenceTests.binding("hhr_g"),
                              journals: ["hhr_g": GardenGoneRecord(reason: .absentZone, action: .rehome, phase: .journaled,
                                                                   replacementID: "hhr_new", createdAt: Date())])
        let rehomer = RecordingRehomer()
        let runner = GardenGuardRunner(store: store, rehomer: rehomer)
        runner.resume(accountKey: nil)
        #expect(!runner.isLaunchResolved)
        #expect(rehomer.requests.isEmpty)
    }

    @Test("two resumes hand a journal to the re-home seam once")
    func resumeIsIdempotent() {
        let store = GardenGuardStore(directory: nil)
        try? store.setBinding(Self.keyA, GardenWriteFenceTests.binding("hhr_g"),
                              journals: ["hhr_g": GardenGoneRecord(reason: .absentZone, action: .rehome, phase: .journaled,
                                                                   replacementID: "hhr_new", createdAt: Date())])
        let rehomer = RecordingRehomer()
        let runner = GardenGuardRunner(store: store, rehomer: rehomer)
        runner.resume(accountKey: Self.keyA)
        let epoch = runner.scopeEpoch
        runner.resume(accountKey: Self.keyA)
        #expect(rehomer.requests.count == 1)
        #expect(runner.scopeEpoch == epoch)
        #expect(runner.isLaunchResolved)
    }

    // MARK: 7. A refuted signal keeps the pass stopped (also in the package: clearFence)

    // See `participantDrainSignalWaitsForListing`.

    // MARK: 8. View only follows the permission each pass

    @Test("view only clears when read-write returns, and for a gone garden")
    func viewOnlyFollowsPermission() async throws {
        let rig = try GardenGoneCoordinatorTests.rig(participant: true)
        rig.provisioner.permission = .readOnly
        await rig.coordinator.sync()
        #expect(rig.coordinator.isViewOnly)
        rig.provisioner.permission = .unknown
        await rig.coordinator.sync()
        #expect(rig.coordinator.isViewOnly)        // an unreadable permission changes nothing
        rig.provisioner.permission = .readWrite
        await rig.coordinator.sync()
        #expect(!rig.coordinator.isViewOnly)
        rig.provisioner.permission = .readOnly
        await rig.coordinator.sync()
        #expect(rig.coordinator.isViewOnly)
        rig.coordinator.handleGone(.zoneNotFound)
        #expect(!rig.coordinator.isViewOnly)       // no view-only notice for a gone garden
    }

    // MARK: 10. The async photo writers re-check at their final boundary

    /// A fence that allows the start of a write and refuses its final check.
    private final class FlipFence: @unchecked Sendable {
        var calls = 0
        func current() -> WritableGarden? {
            calls += 1
            return calls == 1 ? WritableGarden(householdID: "hhr_g", epoch: 1) : nil
        }
    }

    @Test("photo writers refuse at the save when the scope changed after they began")
    func photoWritersFenceAtTheSave() async throws {
        let container = makeTestContainer(name: "photos-\(UUID().uuidString)")
        let household = "hhr_photo_\(UUID().uuidString)"
        let context = ModelContext(container)
        context.insert(LocalSeed(id: "s1", householdID: household, state: .active, packetCount: 1,
                                 source: .store, createdAt: 1, updatedAt: 1))
        context.insert(LocalSeedPhoto(id: "p-del", seedID: "s1", householdID: household, r2Key: "", role: .front,
                                      width: 1, height: 1, byteSize: 1, capturedAt: 1))
        context.insert(LocalJournalEntry(id: "e1", householdID: household, occurredOn: "2026-10-24", body: "b",
                                         seedID: nil, bedID: nil, plantingEventID: nil, createdAt: 1, updatedAt: 1, deletedAt: nil))
        context.insert(LocalJournalEntryPhoto(id: "jp-del", entryID: "e1", storageKey: nil, sortOrder: 0,
                                              width: nil, height: nil, createdAt: 1, updatedAt: 1))
        try context.save()

        func engine() -> (SyncEngine, FlipFence) {
            let e = SyncEngine(container: container)
            let flip = FlipFence()
            e.writeFence = GardenWriteFence(current: { flip.current() })
            e.cloudKitScopeIDProvider = { "scope" }
            return (e, flip)
        }
        func refused(_ body: () async throws -> Void) async -> Bool { await GardenWriteFenceTests.isRefused(body) }

        let (a, _) = engine()
        let up = await refused { try await a.uploadPhoto(seedID: "s1", role: .front, jpegData: Data([1]), householdID: household, photoID: "p-new") }
        #expect(up)
        let (b, _) = engine()
        let del = await refused { try await b.deleteSeedPhoto("p-del", householdID: household) }
        #expect(del)
        let (c, _) = engine()
        let jup = await refused { _ = try await c.uploadJournalPhoto(entryId: "e1", jpegData: Data([1]), householdID: household) }
        #expect(jup)
        let (d, _) = engine()
        let jdel = await refused { try await d.deleteJournalPhoto("jp-del", householdID: household) }
        #expect(jdel)

        let check = ModelContext(container)
        #expect(try check.fetch(FetchDescriptor<LocalSeedPhoto>()).map(\.id) == ["p-del"])
        #expect(try check.fetch(FetchDescriptor<LocalJournalEntryPhoto>()).map(\.id) == ["jp-del"])
        #expect(try check.fetch(FetchDescriptor<LocalCloudKitDeletion>()).isEmpty)
        // The bytes written before the refused save are taken back.
        let pending = PhotoByteStore(lifetime: .pendingUploads, householdID: household)
        #expect(pending.data(for: SeedkeepRecordNames.seedPhoto("p-new")) == nil)
        try? PhotoByteStore.purgeHousehold(household)
    }

    // MARK: Round 3

    @Test("a listed zone whose read says missing is unconfirmed through the inspection path, not access lost")
    func listedZoneReadMissingIsNotAccessLost() async throws {
        #expect(throws: SyncEngineError.self) { try LiveGardenProvisioner.inspection(listed: true, read: .zoneMissing) }
        if case .zoneMissing = try LiveGardenProvisioner.inspection(listed: false, read: .zoneMissing) {} else { Issue.record("unlisted is missing") }

        // The start check: a seen shared zone that the listing shows is never access lost.
        let start = try GardenGoneCoordinatorTests.rig(participant: true, root: .listedButZoneReadMissing)
        await start.coordinator.sync()
        #expect(!start.coordinator.isGone)
        #expect(!start.store.isGone(Self.account, start.householdID))

        // Confirmation of a signal during an active drain: the same inspection, the same answer.
        let rig = try GardenGoneCoordinatorTests.rig(participant: true, batchesPerSend: 3)
        await rig.coordinator.sync()
        rig.provisioner.setRoot(householdID: rig.householdID, .listedButZoneReadMissing)
        let engine = rig.engine
        rig.engine.batchCheck = { engine.fire(.gone(.zoneNotFound)); return .ok }
        GardenGoneCoordinatorTests.stagePendingRecord(rig)
        await rig.coordinator.sync()
        await GardenGoneCoordinatorTests.settle()
        #expect(!rig.coordinator.isGone)
        #expect(!rig.store.isGone(Self.account, rig.householdID))
        #expect(rig.coordinator.sendsStoppedForPass)
    }

    @Test("a recreated, still-listed shared zone is gone (recreated) when a signal arrives during a drain")
    func recreatedListedZoneIsGone() async throws {
        let rig = try GardenGoneCoordinatorTests.rig(participant: true, batchesPerSend: 3)
        await rig.coordinator.sync()
        rig.provisioner.setRoot(householdID: rig.householdID, .present(creationDate: Date(timeIntervalSince1970: 7_000)))
        let engine = rig.engine
        rig.engine.batchCheck = { engine.fire(.gone(.zoneDeleted(.deleted))); return .ok }
        GardenGoneCoordinatorTests.stagePendingRecord(rig)
        let sent = rig.engine.batchesSent
        await rig.coordinator.sync()
        await GardenGoneCoordinatorTests.settle()
        #expect(rig.coordinator.isGone)
        #expect(rig.coordinator.goneReason == .recreated)
        #expect(rig.store.journal(Self.account, rig.householdID)?.reason == .recreated)
        #expect(rig.engine.batchesSent == sent)
    }

    // MARK: Account-keyed in-memory fence

    @Test("a failed commit for one account does not block another account on the same shared garden")
    func memoryFenceIsPerAccount() throws {
        final class Flag: @unchecked Sendable { var failing = false }
        let flag = Flag()
        let store = GardenGuardStore(directory: GuardTestDirectory.make(), write: { data, url in
            if flag.failing { throw CocoaError(.fileWriteUnknown) }
            try GardenGuardStore.atomicWrite(data, to: url)
        })
        let runner = GardenGuardRunner(store: store, rehomer: RecordingRehomer())
        flag.failing = true
        let event = GardenGoneEvent(accountKey: Self.account, householdID: "hhr_shared", reason: .accessLost)
        #expect(!runner.commitGone(event))
        #expect(runner.isBlocked(account: Self.account, householdID: "hhr_shared"))
        #expect(!runner.isBlocked(account: Self.otherAccount, householdID: "hhr_shared"))
        #expect(!runner.isBlocked(account: Self.account, householdID: "hhr_other"))
        // An unresolved account blocks the household for every account.
        runner.fenceInMemory(account: "", householdID: "hhr_unknown")
        #expect(runner.isBlocked(account: Self.otherAccount, householdID: "hhr_unknown"))
    }

    @Test("switching accounts after a failed commit leaves the other account's garden writable")
    func memoryFenceSwitchThroughTheEnvironment() async throws {
        final class Flag: @unchecked Sendable { var failing = false }
        let flag = Flag()
        let store = GardenGuardStore(directory: GuardTestDirectory.make(), write: { data, url in
            if flag.failing { throw CocoaError(.fileWriteUnknown) }
            try GardenGuardStore.atomicWrite(data, to: url)
        })
        let provisioner = FakeGardenProvisioner()
        provisioner.setRoot(householdID: "hhr_g", .zoneMissing)
        let provider = FakeCloudIdentityProvider(recordName: GardenWriteFenceTests.userA, owned: nil, shared: nil)
        let rig = try GardenWriteFenceTests.makeEnv("memoryFenceSwitch", store: store, provider: provider, prepare: {
            try $0.setBinding(Self.keyA, GardenWriteFenceTests.binding("hhr_g"))
            try $0.recordSeen(Self.keyA, "hhr_g", generation: GardenGoneCoordinatorTests.generation)
        })
        rig.coordinators.provisioner = provisioner
        await rig.env.auth.restoreSession()
        flag.failing = true
        await rig.env.syncIfPossible()
        #expect(rig.env.writableGarden == nil)

        // Account B signs in on the same device and is bound to the same garden ID.
        flag.failing = false
        GardenWriteFenceTests.cache(rig.defaults, user: GardenWriteFenceTests.userB, household: "hhr_g")
        provider.recordName = GardenWriteFenceTests.userB
        await rig.env.auth.restoreSession()
        #expect(rig.env.auth.currentAccountKey == GardenWriteFenceTests.keyB)
        #expect(rig.env.writableGarden != nil)
        #expect(!rig.env.isActiveGardenGone)
    }

    // MARK: Round 4

    final class FailingWrites: @unchecked Sendable { var on = false }

    private static func failingStore() -> (GardenGuardStore, FailingWrites) {
        let flag = FailingWrites()
        let store = GardenGuardStore(directory: GuardTestDirectory.make(), write: { data, url in
            if flag.on { throw CocoaError(.fileWriteUnknown) }
            try GardenGuardStore.atomicWrite(data, to: url)
        })
        return (store, flag)
    }

    @Test("a root without a server creationDate can't be trusted on first use: typed failure, nothing sent")
    func missingCreationDateIsNotTrusted() async throws {
        // The start check.
        let rig = try GardenGoneCoordinatorTests.rig(root: .present(creationDate: nil), recorded: nil)
        await rig.coordinator.sync()
        #expect(!rig.coordinator.isGone)
        #expect(rig.store.seen(Self.account, rig.householdID)?.generation == nil)
        #expect(rig.provisioner.shareSaves.isEmpty)
        #expect(rig.engine.sendUntilDrainedCallCount == 0)
        #expect(rig.coordinator.lastHumanizedError != nil)

        // The batch check, with and without a recorded generation.
        for recorded in [nil, GardenGoneCoordinatorTests.generation] as [Int64?] {
            let started = try GardenGoneCoordinatorTests.rig(recorded: recorded)
            await started.coordinator.sync()
            started.provisioner.setRoot(householdID: started.householdID, .present(creationDate: nil))
            let outcome = await started.coordinator.performBatchCheck(0)
            #expect(outcome == .failed(.missingMetadata))
            // And a drain sends nothing.
            GardenGoneCoordinatorTests.stagePendingRecord(started)
            let sent = started.engine.batchesSent
            await started.coordinator.sync()
            #expect(started.engine.batchesSent == sent)
            #expect(!started.coordinator.isGone)
        }
    }

    @Test("a first-use generation that can't be written to the guard is a check failure: nothing is sent")
    func unrecordedFirstUseSendsNothing() async throws {
        let (store, flag) = Self.failingStore()
        let rig = try GardenGoneCoordinatorTests.rig(recorded: nil, store: store)
        flag.on = true
        await rig.coordinator.sync()                       // the start check
        #expect(rig.store.seen(Self.account, rig.householdID)?.generation == nil)
        #expect(rig.provisioner.shareSaves.isEmpty)
        #expect(rig.engine.sendUntilDrainedCallCount == 0)
        #expect(!rig.coordinator.isGone)
        #expect(rig.coordinator.lastHumanizedError != nil)
        // The batch check says the same.
        let outcome = await rig.coordinator.performBatchCheck(0)
        #expect(outcome == .failed(.guardWriteFailed))
        // Once the guard can be written, the generation is recorded and the garden proceeds.
        flag.on = false
        await rig.coordinator.sync()
        #expect(rig.store.seen(Self.account, rig.householdID)?.generation == GardenGoneCoordinatorTests.generation)
        #expect(rig.provisioner.shareSaves.count == 1)
    }

    @Test("a recorded generation and a root without a creationDate: not gone, sends stop, later checks fail")
    func participantConfirmationWithoutCreationDate() async throws {
        let rig = try GardenGoneCoordinatorTests.rig(participant: true, batchesPerSend: 3)
        await rig.coordinator.sync()
        rig.provisioner.setRoot(householdID: rig.householdID, .present(creationDate: nil))
        let engine = rig.engine
        rig.engine.batchCheck = { engine.fire(.gone(.zoneDeleted(.deleted))); return .ok }
        GardenGoneCoordinatorTests.stagePendingRecord(rig)
        let sent = rig.engine.batchesSent
        await rig.coordinator.sync()
        await GardenGoneCoordinatorTests.settle()
        #expect(!rig.coordinator.isGone)
        #expect(!rig.store.isGone(Self.account, rig.householdID))
        #expect(rig.coordinator.sendsStoppedForPass)
        #expect(rig.engine.batchesSent == sent)
        // The next pass's batch checks fail on the missing metadata instead of sending.
        rig.engine.batchCheck = { [coordinator = rig.coordinator] in await coordinator.performBatchCheck(0) }
        GardenGoneCoordinatorTests.stagePendingRecord(rig)
        await rig.coordinator.sync()
        #expect(rig.engine.batchesSent == sent)
        #expect(!rig.coordinator.isGone)
    }
}
