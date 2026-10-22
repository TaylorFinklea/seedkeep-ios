import Foundation
import SwiftData
import Testing
@testable import Seedkeep
import SeedkeepKit

/// N1 gates at the `AppEnvironment` level, through `AppEnvironment.makeForTesting`: the real
/// erasers, the CloudKit gate, the share-adoption epoch and the refusing server transport. No live
/// CloudKit: every test keeps `canUseCloudKit` false wherever a coordinator would be built.
@MainActor
@Suite("AppEnvironment N1 gates", .serialized)
struct AppEnvironmentGateTests {
    private static let userA = "_userA"
    private static let userB = "_userB"

    /// One isolated environment: its own defaults suite, sync-state directory, legacy
    /// account-deletion checkpoint directory, token store and in-memory container.
    struct Harness {
        let env: AppEnvironment
        let provider: FakeCloudIdentityProvider
        let defaults: UserDefaults
        let container: ModelContainer
        let syncDirectory: URL
        let checkpointDirectory: URL
        let tokenStore: InMemoryTokenStore
        let cleanup: () -> Void
    }

    /// `checkpoints` maps file names to the bytes an older build left in the legacy checkpoint
    /// directory; nil leaves no directory at all. `prepare` runs before the environment exists,
    /// so it sees the state the launch-time cleanup will find.
    private static func makeHarness(
        _ name: String, provider: FakeCloudIdentityProvider, checkpoints: [String: Data]? = nil,
        cache: (user: String, household: String)? = nil, legacy: Bool = false,
        token: String? = nil,
        prepare: (ModelContainer, UserDefaults, URL) throws -> Void = { _, _, _ in }
    ) throws -> Harness {
        let suite = "AppEnvironmentGateTests.\(name).\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppEnvironmentGateTests-\(UUID().uuidString)", isDirectory: true)
        let syncDirectory = root.appendingPathComponent("HouseholdSync", isDirectory: true)
        try FileManager.default.createDirectory(at: syncDirectory, withIntermediateDirectories: true)
        let checkpointDirectory = root.appendingPathComponent("AccountDeletion", isDirectory: true)
        if let checkpoints {
            try FileManager.default.createDirectory(at: checkpointDirectory, withIntermediateDirectories: true)
            for (file, data) in checkpoints {
                try data.write(to: checkpointDirectory.appendingPathComponent(file))
            }
        }
        if let cache {
            let json = """
            {"user":{"id":"\(cache.user)","name":null,"email":null},"household":{"id":"\(cache.household)","name":"Garden","created_at":1,"updated_at":1}}
            """
            defaults.set(Data(json.utf8), forKey: legacy ? AuthController.legacyIdentityCacheKey : AuthController.identityCacheKey)
        }
        let container = makeTestContainer(name: "appEnvGate-\(UUID().uuidString)")
        try prepare(container, defaults, syncDirectory)
        let tokenStore = InMemoryTokenStore(token)
        let env = AppEnvironment.makeForTesting(
            identity: provider, tokenStore: tokenStore, defaults: defaults,
            container: container, durableStateDirectory: syncDirectory,
            legacyCheckpointDirectory: checkpointDirectory)
        return Harness(env: env, provider: provider, defaults: defaults, container: container,
                       syncDirectory: syncDirectory, checkpointDirectory: checkpointDirectory,
                       tokenStore: tokenStore, cleanup: {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: env.scanStagingRoot)
        })
    }

    private static func insertGardenAndRecoveryItem(_ container: ModelContainer, household: String) throws {
        let context = ModelContext(container)
        context.insert(LocalSeed(id: "seed_\(household)", householdID: household, state: .active,
                                 packetCount: 1, source: .store, createdAt: 1, updatedAt: 1))
        context.insert(LocalJournalRecoveryItem(id: "rec_1", scopeKey: "scope", snapshotJSON: "{}",
                                                detectedAt: 1, status: "pending"))
        try context.save()
    }

    /// Stages one scan photo under the environment's staging root, as a scan in progress would.
    private static func stageScan(_ env: AppEnvironment, household: String) throws -> UUID {
        let scanID = UUID()
        try ScanPhotoStaging.write(
            Data("front".utf8), side: .front, scanID: scanID,
            scope: ScanPhotoStaging.Scope(userRecordName: "_any", householdID: household),
            root: env.scanStagingRoot
        )
        return scanID
    }

    private static func counts(_ container: ModelContainer) throws -> (seeds: Int, recovery: Int) {
        let context = ModelContext(container)
        return (try context.fetchCount(FetchDescriptor<LocalSeed>()),
                try context.fetchCount(FetchDescriptor<LocalJournalRecoveryItem>()))
    }

    // MARK: - Erasers

    @Test("a chooser discard removes the garden but keeps journal recovery items")
    func gardenSwitchEraserKeepsRecoveryItems() async throws {
        let provider = FakeCloudIdentityProvider(
            owned: [FakeCloudIdentityProvider.zone("hh_other", name: "Other")], shared: [])
        let h = try Self.makeHarness("switch", provider: provider, cache: ("u_server", "hh_h"), legacy: true)
        defer { h.cleanup() }
        try Self.insertGardenAndRecoveryItem(h.container, household: "hh_h")
        await h.env.auth.restoreSession()
        let scanID = try Self.stageScan(h.env, household: "hh_h")
        let epochBefore = h.env.scanSessionEpoch
        guard case .choosingGarden(let choice) = h.env.auth.state else {
            Issue.record("expected the chooser, got \(h.env.auth.state)")
            return
        }
        let other = try #require(choice.candidates.first)

        await h.env.auth.chooseGarden(other, discardingDeviceData: true)

        guard case .signedIn(_, let household) = h.env.auth.state else {
            Issue.record("expected signedIn, got \(h.env.auth.state)")
            return
        }
        #expect(household.id == "hh_other")
        let after = try Self.counts(h.container)
        #expect(after.seeds == 0, "the discarded garden's rows go")
        #expect(after.recovery == 1, "device-only journal recovery items stay")
        #expect(ScanPhotoStaging.manifest(for: scanID, root: h.env.scanStagingRoot) == nil,
                "the discarded garden's staged scan photos go (N2)")
        #expect(h.env.scanSessionEpoch > epochBefore, "open scan and save sheets are invalidated (V1)")
    }

    @Test("a different iCloud user's wipe removes journal recovery items too")
    func fullEraserRemovesRecoveryItems() async throws {
        let provider = FakeCloudIdentityProvider(recordName: Self.userB, owned: [], shared: [])
        let h = try Self.makeHarness("full", provider: provider, cache: (Self.userA, "hh_a"))
        defer { h.cleanup() }
        try Self.insertGardenAndRecoveryItem(h.container, household: "hh_a")
        let scanID = try Self.stageScan(h.env, household: "hh_a")
        let epochBefore = h.env.scanSessionEpoch

        await h.env.auth.restoreSession()

        guard case .signedIn(let user, _) = h.env.auth.state else {
            Issue.record("expected signedIn, got \(h.env.auth.state)")
            return
        }
        #expect(user.id == Self.userB)
        let after = try Self.counts(h.container)
        #expect(after.seeds == 0)
        #expect(after.recovery == 0, "another user's device-only data must not survive")
        #expect(ScanPhotoStaging.manifest(for: scanID, root: h.env.scanStagingRoot) == nil,
                "another user's staged scan photos must not survive (N2)")
        #expect(h.env.scanSessionEpoch > epochBefore, "open scan and save sheets are invalidated (V1)")
    }

    // MARK: - CloudKit gate

    @Test("with CloudKit paused, sharing, saves and share draining build no coordinator")
    func pausedCloudKitBlocksCoordinatorWork() async throws {
        let provider = FakeCloudIdentityProvider(status: .unverified)
        let h = try Self.makeHarness("paused", provider: provider, cache: (Self.userA, "hh_a"))
        defer { h.cleanup() }
        await h.env.auth.restoreSession()
        guard case .signedIn = h.env.auth.state else {
            Issue.record("expected signedIn, got \(h.env.auth.state)")
            return
        }
        #expect(!h.env.canUseCloudKit)
        #expect(h.env.cloudKitPauseReason != nil)

        #expect(await h.env.prepareOwnerShare() == nil)
        h.env.sync.onLocalHouseholdMutation?()
        #expect(!h.env.canDrainPendingShares, "a pending share stays pending")
        await h.env.processPendingShare()

        #expect(!h.env.hasCloudCoordinator)
        #expect(h.env.cloudKit == nil)
    }

    // MARK: - N3 legacy account-deletion files

    private static let legacyFiles: [String: Data] = [
        "checkpoint-dV9zZXJ2ZXI.json": Data(#"{"user_id":"u_server","role":"solo_owner","phase":"deleting_account","updated_at":1}"#.utf8),
        "checkpoint-ZGFtYWdlZA.json": Data("not json".utf8),
        ".checkpoint-dV9zZXJ2ZXI.json.1234.tmp": Data("partial".utf8),
    ]

    private static let migrationMarker = "\(HouseholdCloudCoordinator.migratedKeyPrefix)production.hh_h"

    /// What a device holds for garden `hh_h`: a row, a pending CloudKit deletion, a journal
    /// recovery item, a migration marker, a participant marker, engine state, pending-upload
    /// bytes and transfer-workspace bytes.
    private static func prepareDevice(
        _ container: ModelContainer, _ defaults: UserDefaults, _ syncDirectory: URL
    ) throws {
        try insertGardenAndRecoveryItem(container, household: "hh_h")
        let context = ModelContext(container)
        context.insert(LocalCloudKitDeletion(scopeID: "owner|hh_h", householdID: "hh_h",
                                             recordName: "seed:gone", createdAt: 1))
        try context.save()
        defaults.set(true, forKey: migrationMarker)
        ActiveGardenContext.recordParticipant(zoneName: "seedkeep-hh_x", ownerName: "_x", in: defaults)
        try Data("x".utf8).write(to: syncDirectory.appendingPathComponent("engine-state-production-hh_h.json"))
        for lifetime in [PhotoByteStore.Lifetime.pendingUploads, .transferWorkspace] {
            let dir = syncDirectory.appendingPathComponent(lifetime.rawValue, isDirectory: true)
                .appendingPathComponent("production/hh_h", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data("jpeg".utf8).write(to: dir.appendingPathComponent("seedPhoto_p1.abc.jpg"))
        }
    }

    private static func exists(_ url: URL, _ path: String = "") -> Bool {
        FileManager.default.fileExists(atPath: path.isEmpty ? url.path : url.appendingPathComponent(path).path)
    }

    /// Everything but the legacy files is exactly as `prepareDevice` left it.
    private static func expectDeviceUntouched(_ h: Harness, sourceLocation: SourceLocation = #_sourceLocation) {
        let context = ModelContext(h.container)
        #expect((try? context.fetchCount(FetchDescriptor<LocalSeed>())) == 1, sourceLocation: sourceLocation)
        #expect((try? context.fetchCount(FetchDescriptor<LocalJournalRecoveryItem>())) == 1, sourceLocation: sourceLocation)
        #expect((try? context.fetchCount(FetchDescriptor<LocalCloudKitDeletion>())) == 1,
                "pending CloudKit deletions stay", sourceLocation: sourceLocation)
        #expect(h.defaults.bool(forKey: migrationMarker), sourceLocation: sourceLocation)
        #expect(h.env.isViewingSharedHousehold, "the participant marker stays", sourceLocation: sourceLocation)
        #expect(exists(h.syncDirectory, "engine-state-production-hh_h.json"), sourceLocation: sourceLocation)
        #expect(exists(h.syncDirectory, "PendingUploads/production/hh_h/seedPhoto_p1.abc.jpg"), sourceLocation: sourceLocation)
        #expect(h.env.auth.loadCachedIdentity()?.household.id == "hh_h", sourceLocation: sourceLocation)
        #expect(h.tokenStore.load() == "tok", sourceLocation: sourceLocation)
    }

    @Test("with no checkpoint directory the legacy cleanup changes nothing")
    func legacyCleanupWithoutCheckpointsIsANoOp() async throws {
        let h = try Self.makeHarness("noCheckpoint", provider: FakeCloudIdentityProvider(recordName: Self.userA),
                                     cache: (Self.userA, "hh_h"), token: "tok", prepare: Self.prepareDevice)
        defer { h.cleanup() }

        Self.expectDeviceUntouched(h)
        #expect(!Self.exists(h.checkpointDirectory))
        #expect(!Self.exists(h.syncDirectory, "TransferWorkspace"), "transfer bytes go even without checkpoints")
    }

    @Test("legacy checkpoint files (damaged and scratch included) and transfer bytes go; nothing else changes")
    func legacyCleanupRemovesOnlyLegacyFiles() async throws {
        let h = try Self.makeHarness("checkpoints", provider: FakeCloudIdentityProvider(recordName: Self.userA),
                                     checkpoints: Self.legacyFiles, cache: (Self.userA, "hh_h"), token: "tok",
                                     prepare: Self.prepareDevice)
        defer { h.cleanup() }

        #expect(!Self.exists(h.checkpointDirectory), "every checkpoint file goes, whatever it holds")
        #expect(!Self.exists(h.syncDirectory, "TransferWorkspace"))
        Self.expectDeviceUntouched(h)

        await h.env.auth.restoreSession()
        guard case .signedIn(_, let household) = h.env.auth.state else {
            Issue.record("expected signedIn, got \(h.env.auth.state)")
            return
        }
        #expect(household.id == "hh_h", "the same garden is bound")
        #expect(h.env.canUseCloudKit, "a checkpoint never pauses CloudKit")
        #expect(h.env.cloudKitPauseReason == nil)
    }

    // MARK: - Share adoption epoch

    @Test("an adoption begun before a different-user wipe is dropped and never holds up the new user")
    func adoptionEpochDropsAfterDifferentUserWipe() async throws {
        let provider = FakeCloudIdentityProvider(recordName: Self.userB, owned: [], shared: [])
        let h = try Self.makeHarness("epoch", provider: provider, cache: (Self.userA, "hh_a"))
        defer { h.cleanup() }

        let oldEpoch = h.env.beginAdoption()
        #expect(h.env.isAdoptingShare)
        #expect(h.env.adoptionIsCurrent(oldEpoch))

        await h.env.auth.restoreSession()   // user B: the full eraser bumps the epoch

        #expect(!h.env.adoptionIsCurrent(oldEpoch), "the old share is dropped, not re-deposited")
        #expect(!h.env.isAdoptingShare, "the old adoption does not block the new user")
        await h.env.endAdoption(oldEpoch, adopted: false)
        #expect(!h.env.isAdoptingShare)

        let newEpoch = h.env.beginAdoption()
        #expect(newEpoch != oldEpoch)
        #expect(h.env.isAdoptingShare)
        await h.env.endAdoption(newEpoch, adopted: false)
        #expect(!h.env.isAdoptingShare)
    }

    #if DEBUG   // `cloudKitSyncOverrideForTesting` exists only in Debug builds
    @Test("a sync skipped for an adoption runs once the adoption ends, even unadopted")
    func skippedSyncRerunsAfterAdoption() async throws {
        // Unverified: each sync re-resolves (one account-status call) and builds no coordinator.
        let provider = FakeCloudIdentityProvider(status: .unverified)
        let h = try Self.makeHarness("skipped", provider: provider, cache: (Self.userA, "hh_a"))
        defer { h.cleanup() }
        h.env.cloudKitSyncOverrideForTesting = true   // the shipping CloudKit branch
        await h.env.auth.restoreSession()

        let quiet = h.env.beginAdoption()
        await h.env.endAdoption(quiet, adopted: false)
        let baseline = provider.accountStatusCalls
        #expect(baseline == 1, "an adoption with no skipped sync runs none")

        let epoch = h.env.beginAdoption()
        await h.env.syncIfPossible()
        #expect(provider.accountStatusCalls == baseline + 1)
        await h.env.endAdoption(epoch, adopted: false)

        #expect(provider.accountStatusCalls == baseline + 2, "the held-back sync runs")
        #expect(!h.env.hasCloudCoordinator)
    }
    #endif

    // MARK: - Pending-share deposits

    @Test("removeResolvedDeposits keeps a share delivered before any identity resolved")
    func slotKeepsUnresolvedDeposit() {
        let slot = PendingShareSlot<String>()
        slot.deposit("cold-launch", underResolvedIdentity: false)
        slot.removeResolvedDeposits()
        #expect(slot.take() == "cold-launch")

        slot.deposit("user-a", underResolvedIdentity: true)
        slot.removeResolvedDeposits()
        #expect(slot.isEmpty)
    }

    #if os(macOS)
    @Test("the macOS queue drops only shares deposited under a resolved identity")
    func queueKeepsUnresolvedDeposits() {
        let queue = PendingShareDrainQueue<String>()
        queue.deposit("user-a", underResolvedIdentity: true)
        queue.deposit("cold-launch", underResolvedIdentity: false)
        queue.removeResolvedDeposits()
        #expect(queue.count == 1)
        #expect(queue.take() == "cold-launch")
    }
    #endif

    // MARK: - Transport

    @Test("the live server client's session refuses every request")
    func serverClientUsesRefusingProtocol() async throws {
        let client = AppEnvironment.makeServerClient(baseURL: URL(string: "https://seedkeep.invalid")!)
        let protocols = await client.configuration.session.configuration.protocolClasses ?? []
        #expect(protocols.contains { $0 == RefusingURLProtocol.self })
        #expect(protocols.first.map { $0 == RefusingURLProtocol.self } == true,
                "RefusingURLProtocol must be consulted first")
    }
}

/// T2: a timed-out share accept keeps running and a retry of the same share collects it.
@MainActor
@Suite("In-flight share accepts")
struct InFlightOperationsTests {
    actor Probe {
        var starts = 0
        private var gate: CheckedContinuation<Void, Never>?
        private var open = false
        func start() async -> String {
            starts += 1
            if !open { await withCheckedContinuation { gate = $0 } }
            return "zone-\(starts)"
        }
        func release() { open = true; gate?.resume(); gate = nil }
    }

    @Test("a timeout releases the caller but keeps the accept; the retry reuses its result")
    func timedOutAcceptIsReused() async throws {
        let operations = InFlightOperations<String>()
        let probe = Probe()

        await #expect(throws: LiveCloudIdentityProvider.TimedOut.self) {
            try await operations.run(key: "share-1", epoch: 0, timeoutNanoseconds: 50_000_000) {
                await probe.start()
            }
        }
        #expect(operations.count == 1, "the accept is kept, not abandoned")

        await probe.release()   // the late accept completes
        let value = try await operations.run(key: "share-1", epoch: 0, timeoutNanoseconds: 5_000_000_000) {
            await probe.start()
        }
        #expect(value == "zone-1", "the retry collects the first accept's result")
        #expect(await probe.starts == 1, "no overlapping accept")
        #expect(operations.count == 0, "consumed")
    }

    @Test("an accept from an older epoch is dropped and a new one starts")
    func olderEpochIsDropped() async throws {
        let operations = InFlightOperations<String>()
        let probe = Probe()
        await #expect(throws: LiveCloudIdentityProvider.TimedOut.self) {
            try await operations.run(key: "share-1", epoch: 0, timeoutNanoseconds: 50_000_000) {
                await probe.start()
            }
        }
        await probe.release()

        let value = try await operations.run(key: "share-1", epoch: 1, timeoutNanoseconds: 5_000_000_000) {
            await probe.start()
        }
        #expect(value == "zone-2")
        #expect(await probe.starts == 2)
    }

    @Test("an accept older than the age limit is not rejoined; a fresh one starts")
    func staleAcceptIsNotRejoined() async throws {
        let operations = InFlightOperations<String>(maxAge: .zero)
        let probe = Probe()
        await #expect(throws: LiveCloudIdentityProvider.TimedOut.self) {
            try await operations.run(key: "share-1", epoch: 0, timeoutNanoseconds: 50_000_000) {
                await probe.start()
            }
        }
        await probe.release()

        let value = try await operations.run(key: "share-1", epoch: 0, timeoutNanoseconds: 5_000_000_000) {
            await probe.start()
        }
        #expect(value == "zone-2", "the stale entry is dropped, not awaited")
        #expect(await probe.starts == 2)
    }
}
