import CloudKit
import Foundation
import SwiftData
import Testing
@testable import Seedkeep
import SeedkeepKit
import SeedkeepCloudKit

private final class FlowPhotoWritePause: @unchecked Sendable {
    private let lock = NSLock()
    private let entered = DispatchSemaphore(value: 0)
    private let released = DispatchSemaphore(value: 0)
    private var used = false

    func pauseFirstWrite() {
        let shouldPause = lock.withLock {
            guard !used else { return false }
            used = true
            return true
        }
        guard shouldPause else { return }
        entered.signal()
        released.wait()
    }

    func waitUntilEntered() -> Bool { entered.wait(timeout: .now() + 10) == .success }
    func resume() { released.signal() }
}

/// N2-E (G3) §7 end to end over `AppEnvironment`: the choice, the runner, the auth rebinding, the
/// relaunch. Fakes only: `FakeCloudIdentityProvider`, `FakeCloudCoordinators`, `FakeGardenProvisioner`,
/// a fake engine. No CloudKit, no real notifications.
@MainActor
@Suite("Garden journals: the choice, the runner and relaunches", .serialized)
struct GardenJournalFlowTests {
    static let user = "_userA"
    static let account = "_userA|production"

    /// One "device": a guard file, a defaults suite and a store that survive a relaunch.
    @MainActor final class Device {
        let name: String
        let guardDirectory = GuardTestDirectory.make()
        let container: ModelContainer
        let defaults: UserDefaults
        let provider = FakeCloudIdentityProvider(recordName: GardenJournalFlowTests.user, owned: [], shared: [])
        init(_ name: String) {
            self.name = name
            container = makeTestContainer(name: "flow-\(UUID().uuidString)")
            let suite = "GardenJournalFlowTests.\(name).\(UUID().uuidString)"
            defaults = UserDefaults(suiteName: suite)!
            defaults.removePersistentDomain(forName: suite)
        }

        /// A launch: a new store object reading the same file, and a new environment over the same store.
        func launch(
            makeHouseholdID: @escaping () -> String = { "hhr_minted-" + UUID().uuidString },
            notifier: GardenWriteFenceTests.RecordingNotifier = GardenWriteFenceTests.RecordingNotifier()
        ) -> Launch {
            let store = GardenGuardStore(directory: guardDirectory)
            let relay = GardenRehomeRelay()
            let env = AppEnvironment.makeForTesting(
                identity: provider, tokenStore: InMemoryTokenStore(), defaults: defaults, container: container,
                durableStateDirectory: FileManager.default.temporaryDirectory
                    .appendingPathComponent("flow-\(UUID().uuidString)", isDirectory: true),
                cloudCoordinators: FakeCloudCoordinators().factory, gardenGuard: store, gardenRehomer: relay,
                notifier: notifier, makeHouseholdID: makeHouseholdID)
            relay.runner = env.gardenRunner
            return Launch(env: env, store: store, notifier: notifier)
        }

        /// Opens a launch the way the app does: resolve the session, then let the runner resume.
        func open(_ launch: Launch) async {
            await launch.env.auth.restoreSession()
            launch.env.resumeGuardAfterLaunch()
        }

        func cache(household: String) {
            GardenWriteFenceTests.cache(defaults, user: GardenJournalFlowTests.user, household: household)
        }
    }

    struct Launch {
        let env: AppEnvironment
        let store: GardenGuardStore
        let notifier: GardenWriteFenceTests.RecordingNotifier
    }

    static func binding(_ id: String) -> GardenGuardBinding { JournalRig.binding(id) }

    /// A device whose cached garden `hhr_g` has rows, and whose guard holds it gone (awaiting the choice).
    static func goneDevice(_ name: String, participant: Bool = false) throws -> Device {
        let device = Device(name)
        let store = GardenGuardStore(directory: device.guardDirectory)
        if participant {
            device.cache(household: "hh_me")
            try store.setBinding(account, JournalRig.binding(
                "hhr_g", participant: .init(zoneName: SeedkeepRecordNames.zoneName(householdID: "hhr_g"), ownerName: "_ownerX"),
                signedIn: "hh_me"))
            ActiveGardenContext.recordParticipant(zoneName: SeedkeepRecordNames.zoneName(householdID: "hhr_g"),
                                                  ownerName: "_ownerX", in: device.defaults)
            try store.markGone(account, "hhr_g", reason: .accessLost)
        } else {
            device.cache(household: "hhr_g")
            try store.setBinding(account, binding("hhr_g"))
            try store.markGone(account, "hhr_g", reason: .zoneDeleted)
        }
        let context = ModelContext(device.container)
        context.insert(LocalSeed(id: "s1", householdID: "hhr_g", state: .active, packetCount: 1, source: .store,
                                 customName: "Tomato", createdAt: 1, updatedAt: 1))
        context.insert(LocalSeed(id: "s2", householdID: "hhr_g", state: .active, packetCount: 1, source: .store,
                                 customName: "Bean", createdAt: 1, updatedAt: 1))
        context.insert(LocalBed(id: "b1", householdID: "hhr_g", name: "North", createdAt: 1, updatedAt: 1))
        try context.save()
        return device
    }

    @Test("first launch resume does not cancel a silent re-home already started by legacy resolution")
    func launchResumeKeepsLegacyRehomeGeneration() async throws {
        let device = Device("legacy-resume")
        defer { try? FileManager.default.removeItem(at: device.guardDirectory) }
        device.defaults.set(Data("""
        {"user":{"id":"_userA","name":null,"email":null},"household":{"id":"hh_legacy","name":"Old","created_at":1,"updated_at":1}}
        """.utf8), forKey: AuthController.legacyIdentityCacheKey)
        var legacyZone = FakeCloudIdentityProvider.zone("hh_legacy")
        legacyZone.rootStatus = .absent
        let provider = FakeCloudIdentityProvider(owned: [legacyZone], shared: [])
        let store = GardenGuardStore(directory: device.guardDirectory)
        let relay = GardenRehomeRelay()
        let runner = GardenGuardRunner(store: store, rehomer: relay)
        relay.runner = runner
        let pause = JournalPausePoint()
        let scanRoot = FileManager.default.temporaryDirectory.appendingPathComponent("legacy-resume-scan-\(UUID().uuidString)")
        let env = AppEnvironment.makeForTesting(
            identity: provider, tokenStore: InMemoryTokenStore(), defaults: device.defaults,
            container: device.container,
            durableStateDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("legacy-resume-state-\(UUID().uuidString)"),
            cloudCoordinators: FakeCloudCoordinators().factory, gardenGuard: store, gardenRehomer: relay,
            gardenRunner: runner, makeHouseholdID: { "hhr_legacy-successor" })
        let executor = try #require(env.gardenRunner.executor as? GardenJournalExecutor)
        executor.deps.quiesce = { await pause.pause() }

        await env.auth.restoreSession() // the actual legacy absent-zone bind dispatches the re-home
        await pause.waitUntilStarted()
        #expect(store.journal(Self.account, "hh_legacy")?.action == .rehome)
        #expect(runner.runningJournals.contains(GardenGuardRunner.journalKey(Self.account, "hh_legacy")))

        env.resumeGuardAfterLaunch() // launch resume overlaps the already-running silent journal
        pause.resume()
        await runner.awaitJournal(account: Self.account, householdID: "hh_legacy")

        #expect(store.journal(Self.account, "hh_legacy")?.phase == .done)
        #expect(runner.journalFailure(account: Self.account, householdID: "hh_legacy") == nil)
        #expect(runner.runningJournals.isEmpty)
        #expect(store.latestBinding(Self.account)?.household.id == "hhr_legacy-successor")
        #expect(store.grant(Self.account, "hhr_legacy-successor")?.state == .pending)
        try? FileManager.default.removeItem(at: scanRoot)
    }

    @Test("first launch resume preserves legacy silent re-home during detached photo copy")
    func launchResumeKeepsLegacyRehomeDuringPhotoCopy() async throws {
        let device = Device("legacy-resume-copy")
        let old = "hh_legacy"
        let successor = "hhr_legacy-copy-successor"
        let photoName = SeedkeepRecordNames.seedPhoto("legacy-resume-photo")
        defer {
            try? FileManager.default.removeItem(at: device.guardDirectory)
            try? PhotoByteStore.purgeHousehold(old)
            try? PhotoByteStore.purgeHousehold(successor)
        }
        device.defaults.set(Data("""
        {"user":{"id":"_userA","name":null,"email":null},"household":{"id":"hh_legacy","name":"Old","created_at":1,"updated_at":1}}
        """.utf8), forKey: AuthController.legacyIdentityCacheKey)
        var legacyZone = FakeCloudIdentityProvider.zone(old)
        legacyZone.rootStatus = .absent
        let provider = FakeCloudIdentityProvider(owned: [legacyZone], shared: [])
        let store = GardenGuardStore(directory: device.guardDirectory)
        let relay = GardenRehomeRelay()
        let runner = GardenGuardRunner(store: store, rehomer: relay)
        relay.runner = runner
        let pause = FlowPhotoWritePause()
        let scanRoot = FileManager.default.temporaryDirectory.appendingPathComponent("legacy-resume-copy-scan-\(UUID().uuidString)")
        let context = ModelContext(device.container)
        context.insert(LocalSeed(id: "legacy-seed", householdID: old, state: .active, packetCount: 1,
            source: .store, createdAt: 1, updatedAt: 2))
        context.insert(LocalSeedPhoto(id: "legacy-resume-photo", seedID: "legacy-seed", householdID: old,
            r2Key: nil, role: .front, byteSize: 9, capturedAt: 3))
        try context.save()
        try PhotoByteStore(lifetime: .pendingUploads, householdID: old).write(Data("legacy-photo".utf8), for: photoName)
        let env = AppEnvironment.makeForTesting(
            identity: provider, tokenStore: InMemoryTokenStore(), defaults: device.defaults,
            container: device.container,
            durableStateDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("legacy-resume-copy-state-\(UUID().uuidString)"),
            cloudCoordinators: FakeCloudCoordinators().factory, gardenGuard: store, gardenRehomer: relay,
            gardenRunner: runner, makeHouseholdID: { successor })
        let executor = try #require(env.gardenRunner.executor as? GardenJournalExecutor)
        executor.deps.writeBytes = { byteStore, data, name in
            pause.pauseFirstWrite()
            return try byteStore.write(data, for: name)
        }

        await env.auth.restoreSession() // actual legacy absent-zone binding starts the journal
        #expect(await Task.detached { pause.waitUntilEntered() }.value)
        #expect(store.journal(Self.account, old)?.action == .rehome)
        env.resumeGuardAfterLaunch() // overlaps the awaited detached byte copy
        pause.resume()
        await runner.awaitJournal(account: Self.account, householdID: old)

        #expect(store.journal(Self.account, old)?.phase == .done)
        #expect(runner.journalFailure(account: Self.account, householdID: old) == nil)
        #expect(runner.runningJournals.isEmpty)
        #expect(store.latestBinding(Self.account)?.household.id == successor)
        #expect(store.grant(Self.account, successor)?.state == .pending)
        #expect(GardenInventory.hasBytes(photoName, household: successor))
        #expect(try ModelContext(device.container).fetch(FetchDescriptor<LocalSeedPhoto>(predicate: #Predicate { $0.id == "legacy-resume-photo" })).first?.householdID == successor)
        try? FileManager.default.removeItem(at: scanRoot)
    }

    static func seedIDs(_ device: Device, in household: String) throws -> Set<String> {
        Set(try ModelContext(device.container).fetch(FetchDescriptor<LocalSeed>())
            .filter { $0.householdID == household }.map(\.id))
    }

    // MARK: - The choice screen's state

    enum SuspendedErase: CaseIterable, Sendable { case differentAccount, signOut, gardenSwitch }

    @Test("a superseded real environment eraser awaits journals and preserves the restored account store",
          arguments: SuspendedErase.allCases)
    func supersededEnvironmentEraser(_ transition: SuspendedErase) async throws {
        let device = Device("stale-erase-\(transition)")
        device.cache(household: "hhr_original")
        let launch = device.launch()
        let env = launch.env
        try launch.store.setBinding(Self.account, Self.binding("hhr_original"))
        let context = ModelContext(device.container)
        context.insert(LocalSeed(id: "preserve", householdID: "hhr_original", state: .active, packetCount: 1,
                                 source: .store, customName: "Restored A", createdAt: 1, updatedAt: 1))
        context.insert(LocalJournalRecoveryItem(id: "preserve-recovery", scopeKey: "hhr_other|A", snapshotJSON: "{}",
                                               detectedAt: 1, status: "pending"))
        try context.save()
        await env.auth.restoreSession()
        let candidate = FakeCloudIdentityProvider.zone("hhr_discovered-\(UUID().uuidString)")
        if transition == .gardenSwitch {
            env.auth.considerDiscovery(owned: [FakeCloudIdentityProvider.zone("hhr_original"), candidate],
                                       accountKey: Self.account, householdID: "hhr_original")
            guard case .choosingGarden = env.auth.state else { Issue.record("missing discovery choice"); return }
        }
        try launch.store.markGone(Self.account, "hhr_original", reason: .zoneDeleted)
        try launch.store.chooseAction(Self.account, "hhr_original", action: .keep, replacementID: "hhr_unused")
        let pause = JournalPausePoint()
        let executor = GardenJournalExecutor(store: launch.store, deps: GardenJournalDependencies(
            container: device.container, defaults: device.defaults,
            scanStagingRoot: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
        executor.deps.quiesce = { await pause.pause() }
        env.gardenRunner.executor = executor
        env.gardenRunner.startJournal(account: Self.account, householdID: "hhr_original")
        await pause.waitUntilStarted()
        if transition == .differentAccount { device.provider.recordName = "_userB" }
        let epoch = env.gardenScopeEpoch
        let erasing = Task { @MainActor in
            switch transition {
            case .differentAccount: await env.auth.revalidateAfterAccountChange()
            case .signOut: await env.auth.signOut()
            case .gardenSwitch: await env.auth.chooseGarden(candidate, discardingDeviceData: true)
            }
        }
        while env.gardenScopeEpoch == epoch { await Task.yield() }
        if transition == .differentAccount {
            while env.auth.isIdentityVerified { await Task.yield() }
        }
        #expect(try context.fetchCount(FetchDescriptor<LocalSeed>()) == 1, "eraser must await the journal")
        device.provider.recordName = Self.user
        await env.auth.revalidateAfterAccountChange()
        guard case .signedIn(let user, let household) = env.auth.state else { Issue.record("A did not restore"); pause.resume(); await erasing.value; return }
        #expect(user.id == Self.user && household.id == "hhr_original")
        pause.resume()
        await erasing.value
        let fresh = ModelContext(device.container)
        #expect(try fresh.fetch(FetchDescriptor<LocalSeed>()).map(\.id) == ["preserve"])
        #expect(try fresh.fetch(FetchDescriptor<LocalJournalRecoveryItem>()).map(\.id) == ["preserve-recovery"])
        #expect(launch.store.latestBinding(Self.account)?.household.id == "hhr_original")
        #expect(launch.store.journal(Self.account, "hhr_original")?.steps == [])
    }

    @Test("a gone owned garden shows the choice with owner wording; a lost shared garden shows participant wording")
    func choiceStates() async throws {
        let owner = try Self.goneDevice("owner")
        let ownerLaunch = owner.launch()
        await owner.open(ownerLaunch)
        let ownerScreen = try #require(ownerLaunch.env.gardenGoneScreen)
        #expect(ownerScreen.phase == .choice && !ownerScreen.isParticipant && !ownerScreen.isRunning)
        #expect(ownerLaunch.env.writableGarden == nil)

        let shared = try Self.goneDevice("shared", participant: true)
        let sharedLaunch = shared.launch()
        await shared.open(sharedLaunch)
        let sharedScreen = try #require(sharedLaunch.env.gardenGoneScreen)
        #expect(sharedScreen.phase == .choice && sharedScreen.isParticipant)
        #expect(sharedScreen.householdID == "hhr_g")
    }

    @Test("the words of the choice screen are the contract's")
    func wording() {
        #expect(GardenGoneView.title(isParticipant: false) + " " + GardenGoneView.message(isParticipant: false)
            == "This garden was deleted from iCloud. It may have been deleted on another device or in iCloud Settings.")
        #expect(GardenGoneView.title(isParticipant: true) + " " + GardenGoneView.message(isParticipant: true)
            == "You no longer have access to this shared garden. The owner stopped sharing it or removed you.")
        #expect(GardenGoneView.keepTitle == "Keep a copy as a new garden")
        #expect(GardenGoneView.discardTitle == "Discard this copy")
        let inventory = GardenInventory(seeds: 12, beds: 1, journalEntries: 40, photos: 18, photosNotOnDevice: 2)
        #expect(GardenGoneView.inventorySentence(inventory)
            == "This device still has 12 seeds, 1 bed, 40 journal entries and 18 photos.")
        #expect(GardenGoneView.missingPhotosSentence(inventory) == "2 photos aren't on this device and can't be kept.")
        #expect(GardenGoneView.missingPhotosSentence(GardenInventory(photosNotOnDevice: 1)) == "1 photo isn't on this device and can't be kept.")
        #expect(GardenGoneView.missingPhotosSentence(GardenInventory()) == nil)
    }

    @Test("the counts are the live rows on the device and the photos without bytes")
    func inventoryCounts() async throws {
        let rig = Rig()
        defer { rig.cleanUp() }
        try rig.seed()
        try rig.seedPhotoBytes()
        let inventory = try await GardenInventory.count(container: rig.container, householdID: rig.old)
        // The fixture: two live seeds (one tombstoned), one live bed (one tombstoned), two live entries
        // (one tombstoned), four photos of live parents, two of them without usable bytes.
        #expect(inventory == GardenInventory(seeds: 2, beds: 1, journalEntries: 2, photos: 4, photosNotOnDevice: 2))   // all photo rows, as dropped
    }
    typealias Rig = JournalRig

    // MARK: - Keep

    @Test("keep: the answer fixes the journal, the rows move, and the new garden replaces the old everywhere")
    func keepEndToEnd() async throws {
        let device = try Self.goneDevice("keep")
        let launch = device.launch()
        await device.open(launch)
        let env = launch.env
        env.answerGardenChoice(.keep)

        let record = try #require(launch.store.journal(Self.account, "hhr_g"))
        let new = try #require(record.replacementID)
        #expect(record.action == .keep)
        #expect(launch.store.grant(Self.account, new)?.state == .pending)
        #expect(env.writableGarden == nil)   // blocked from the moment the journal starts
        await env.gardenRunner.awaitJournal(account: Self.account, householdID: "hhr_g")

        #expect(launch.store.journal(Self.account, "hhr_g")?.phase == .done)
        guard case .signedIn(_, let household) = env.auth.state else { Issue.record("not signed in"); return }
        #expect(household.id == new)
        #expect(env.auth.loadCachedIdentity()?.household.id == new)
        #expect(!env.isViewingSharedHousehold)
        #expect(env.activeGardenHouseholdID == new)
        #expect(env.gardenGoneScreen == nil)
        #expect(env.writableGarden?.householdID == new)
        #expect(try Self.seedIDs(device, in: "hhr_g").isEmpty)
        #expect(try Self.seedIDs(device, in: new) == ["s1", "s2"])
        #expect(!env.hasCloudCoordinator)   // the next sync builds the new garden's coordinator
    }

    @Test("keep of a lost shared garden makes an owned garden of the user's own")
    func keepSharedEndToEnd() async throws {
        let device = try Self.goneDevice("keepShared", participant: true)
        let launch = device.launch()
        await device.open(launch)
        launch.env.answerGardenChoice(.keep)
        await launch.env.gardenRunner.awaitJournal(account: Self.account, householdID: "hhr_g")

        let new = try #require(launch.store.journal(Self.account, "hhr_g")?.replacementID)
        let binding = try #require(launch.store.latestBinding(Self.account))
        #expect(binding.household.id == new && binding.participant == nil)
        #expect(!launch.env.isViewingSharedHousehold)   // the participant marker is cleared
        #expect(launch.env.activeGardenHouseholdID == new)
        #expect(try Self.seedIDs(device, in: new) == ["s1", "s2"])
    }

    @Test("repeated taps and two windows run one journal with one replacement ID")
    func repeatedTapsRunOne() async throws {
        let device = try Self.goneDevice("taps")
        let launch = device.launch()
        await device.open(launch)
        let env = launch.env
        // Two windows share this environment: the same screen state, the same runner.
        env.answerGardenChoice(.keep)
        env.answerGardenChoice(.keep)
        env.answerGardenChoice(.keep)
        env.answerGardenChoice(.discard)   // the other button, in the other window, after the first answer
        env.gardenRunner.choose(account: Self.account, householdID: "hhr_g", action: .discard, freshID: "hhr_second")
        let new = try #require(launch.store.journal(Self.account, "hhr_g")?.replacementID)
        await env.gardenRunner.awaitJournal(account: Self.account, householdID: "hhr_g")

        #expect(env.gardenRunner.journalStarts == 1)
        #expect(launch.store.journal(Self.account, "hhr_g")?.action == .keep)
        #expect(launch.store.journal(Self.account, "hhr_g")?.replacementID == new)
        #expect(launch.store.grant(Self.account, "hhr_second") == nil)
        #expect(try Self.seedIDs(device, in: new) == ["s1", "s2"])
        // Answered once, the screen is gone and a late tap does nothing.
        env.answerGardenChoice(.discard)
        #expect(env.gardenRunner.journalStarts == 1)
        #expect(try Self.seedIDs(device, in: new) == ["s1", "s2"])
    }

    @Test("a failed step shows the failure with Try again, and Try again finishes the keep")
    func failedStepThenTryAgain() async throws {
        let device = try Self.goneDevice("retry")
        let launch = device.launch()
        await device.open(launch)
        let env = launch.env
        // A model commit that fails once, through the executor's seam.
        let executor = try #require(env.gardenRunner.executor as? GardenJournalExecutor)
        var failures = 1
        executor.deps.commit = { context in
            if failures > 0 { failures -= 1; throw JournalRig.Crash() }
            try context.save()
        }
        env.answerGardenChoice(.keep)
        await env.gardenRunner.awaitJournal(account: Self.account, householdID: "hhr_g")

        let stalled = try #require(env.gardenGoneScreen)
        #expect(stalled.phase == .working(.keep) && !stalled.isRunning && stalled.failure != nil)
        #expect(env.writableGarden == nil, "a failed open journal stays fenced until retry or completion")
        #expect(try Self.seedIDs(device, in: "hhr_g") == ["s1", "s2"])   // nothing moved

        await env.retryGardenJournal()
        await env.gardenRunner.awaitJournal(account: Self.account, householdID: "hhr_g")
        #expect(env.gardenGoneScreen == nil)
        let new = try #require(launch.store.journal(Self.account, "hhr_g")?.replacementID)
        #expect(try Self.seedIDs(device, in: new) == ["s1", "s2"])
    }

    @Test("an account notification during quiescence stops the stale journal and a verified return resumes it")
    func accountNotificationDuringQuiescence() async throws {
        let device = try Self.goneDevice("accountNotification")
        let launch = device.launch()
        await device.open(launch)
        let env = launch.env
        let executor = try #require(env.gardenRunner.executor as? GardenJournalExecutor)
        let pause = JournalPausePoint()
        executor.deps.quiesce = { await pause.pause() }

        env.answerGardenChoice(.keep)
        await pause.waitUntilStarted()
        env.auth.pauseForAccountChange()
        pause.resume()
        await env.gardenRunner.awaitJournal(account: Self.account, householdID: "hhr_g")

        #expect(launch.store.journal(Self.account, "hhr_g")?.phase == .journaled)
        #expect(launch.store.journal(Self.account, "hhr_g")?.steps == [])
        #expect(try Self.seedIDs(device, in: "hhr_g") == ["s1", "s2"])
        #expect(env.writableGarden == nil)
        #expect(env.gardenGoneScreen?.failure != nil)

        // Same-account verification re-enters the open journal instead of leaving its spinner stranded.
        executor.deps.quiesce = {}
        await env.retryGardenJournal()
        await env.gardenRunner.awaitJournal(account: Self.account, householdID: "hhr_g")
        #expect(launch.store.journal(Self.account, "hhr_g")?.phase == .done)
        let successor = try #require(launch.store.journal(Self.account, "hhr_g")?.replacementID)
        #expect(try Self.seedIDs(device, in: successor) == ["s1", "s2"])
    }

    @Test("a discard follow-up paused at the account boundary keeps ownership evidence and retries after verification")
    func discardFollowUpAccountPause() async throws {
        let device = try Self.goneDevice("discardAccountBoundary")
        let launch = device.launch()
        await device.open(launch)
        let env = launch.env
        let executor = try #require(env.gardenRunner.executor as? GardenJournalExecutor)
        let continueDiscard = executor.deps.didDiscard
        var pauseAtBoundary = true
        executor.deps.didDiscard = { account, householdID, scopeEpoch in
            if pauseAtBoundary {
                pauseAtBoundary = false
                env.auth.pauseForAccountChange()
            }
            return await continueDiscard(account, householdID, scopeEpoch)
        }

        env.answerGardenChoice(.discard)
        await env.gardenRunner.awaitJournal(account: Self.account, householdID: "hhr_g")

        #expect(launch.store.journal(Self.account, "hhr_g")?.phase == .done)
        #expect(launch.store.latestBinding(Self.account) == nil)
        #expect(env.auth.loadCachedIdentity()?.household.id == "hhr_g", "the cache remains ownership evidence until identity verification")
        #expect(launch.store.isRetired(Self.account, "hhr_g"))
        #expect(env.gardenRunner.isBlocked(account: Self.account, householdID: "hhr_g"))
        #expect(env.writableGarden == nil)
        #expect(env.gardenGoneScreen?.failure != nil, "a paused discard has a visible recovery action")

        await env.retryGardenJournal()
        await env.gardenRunner.awaitJournal(account: Self.account, householdID: "hhr_g")

        guard case .signedIn(_, let successor) = env.auth.state else { Issue.record("not signed in after verification"); return }
        #expect(successor.id != "hhr_g")
        #expect(env.auth.loadCachedIdentity()?.household.id == successor.id)
        #expect(env.writableGarden?.householdID == successor.id)
        #expect(env.gardenRunner.isBlocked(account: Self.account, householdID: "hhr_g"))
    }

    // MARK: - Discard

    @Test("discard: the rows go, the binding clears, the session resolves again to a new garden with a grant")
    func discardEndToEnd() async throws {
        let device = try Self.goneDevice("discard")
        let launch = device.launch()
        await device.open(launch)
        let env = launch.env
        env.answerGardenChoice(.discard)
        await env.gardenRunner.awaitJournal(account: Self.account, householdID: "hhr_g")

        #expect(try Self.seedIDs(device, in: "hhr_g").isEmpty)
        #expect(try ModelContext(device.container).fetchCount(FetchDescriptor<LocalBed>()) == 0)
        #expect(launch.store.isRetired(Self.account, "hhr_g"))
        #expect(launch.store.journal(Self.account, "hhr_g")?.phase == .done)
        #expect(launch.notifier.removedAll >= 1)
        // No other garden in the account: restoreSession mints a fresh one, through a pending grant.
        guard case .signedIn(_, let household) = env.auth.state else { Issue.record("not signed in"); return }
        #expect(household.id.hasPrefix("hhr_minted-"))
        #expect(launch.store.latestBinding(Self.account)?.household.id == household.id)
        #expect(launch.store.grant(Self.account, household.id)?.state == .pending)
        #expect(env.gardenGoneScreen == nil)
        #expect(env.writableGarden?.householdID == household.id)
    }

    @Test("discard, then a successor, then a relaunch: the successor stays and the discard journal never replays")
    func discardSuccessorRelaunch() async throws {
        let device = try Self.goneDevice("discardRelaunch")
        let first = device.launch()
        await device.open(first)
        first.env.answerGardenChoice(.discard)
        await first.env.gardenRunner.awaitJournal(account: Self.account, householdID: "hhr_g")
        guard case .signedIn(_, let successor) = first.env.auth.state else { Issue.record("not signed in"); return }
        // The launch that ran the discard never removes its journal.
        first.env.resumeGuardAfterLaunch()
        #expect(first.store.journal(Self.account, "hhr_g") != nil)

        // Rows of the successor made since: a replay would delete them.
        let context = ModelContext(device.container)
        context.insert(LocalSeed(id: "later", householdID: successor.id, state: .active, packetCount: 1, source: .store,
                                 customName: "Later", createdAt: 2, updatedAt: 2))
        try context.save()

        // A later launch: defaults confirmed against the successor, so the journal goes; nothing replays.
        let second = device.launch()
        await device.open(second)
        #expect(second.store.latestBinding(Self.account)?.household.id == successor.id)
        #expect(second.store.journal(Self.account, "hhr_g") == nil)
        #expect(second.store.isRetired(Self.account, "hhr_g"))
        #expect(second.store.account(Self.account).grants.keys.sorted() == [successor.id])   // no other garden was made
        #expect(try Self.seedIDs(device, in: successor.id) == ["later"])
        guard case .signedIn(_, let again) = second.env.auth.state else { Issue.record("not signed in"); return }
        #expect(again.id == successor.id)
    }

    // MARK: - Keep: journal lifetime across launches

    @Test("keep: the journal stays until the grant is consumed and a later launch confirmed the defaults")
    func keepJournalLifetime() async throws {
        let device = try Self.goneDevice("keepLifetime")
        let first = device.launch()
        await device.open(first)
        first.env.answerGardenChoice(.keep)
        await first.env.gardenRunner.awaitJournal(account: Self.account, householdID: "hhr_g")
        let new = try #require(first.store.journal(Self.account, "hhr_g")?.replacementID)

        // Later launch, grant still pending (the first sync hasn't created the zone): the journal stays.
        let second = device.launch()
        await device.open(second)
        #expect(second.store.journal(Self.account, "hhr_g")?.phase == .done)
        #expect(second.store.grant(Self.account, new)?.state == .pending)

        // The grant is consumed; the next launch removes it.
        try second.store.consumeGrant(Self.account, new, generation: 42)
        let third = device.launch()
        await device.open(third)
        #expect(third.store.journal(Self.account, "hhr_g") == nil)
        #expect(third.store.latestBinding(Self.account)?.household.id == new)
        #expect(third.store.isRetired(Self.account, "hhr_g"))
    }

    @Test("a crash between the binding and the defaults is repaired by the next launch, which then does not confirm it")
    func defaultsRepairedAtNextLaunch() async throws {
        let device = try Self.goneDevice("repair")
        // The keep finished its closing guard write, and the process died before the defaults persisted.
        let store = GardenGuardStore(directory: device.guardDirectory)
        try store.chooseAction(Self.account, "hhr_g", action: .keep, replacementID: "hhr_new")
        try store.completeRehome(Self.account, from: "hhr_g", binding: Self.binding("hhr_new"))
        try store.consumeGrant(Self.account, "hhr_new", generation: 1)
        #expect(device.defaults.data(forKey: AuthController.identityCacheKey) != nil)   // still names hhr_g

        let first = device.launch()
        await device.open(first)
        guard case .signedIn(_, let household) = first.env.auth.state else { Issue.record("not signed in"); return }
        #expect(household.id == "hhr_new")                     // repaired from the latest binding
        #expect(first.store.journal(Self.account, "hhr_g") != nil)   // not confirmed by the launch that repaired it

        let second = device.launch()
        await device.open(second)
        #expect(second.store.journal(Self.account, "hhr_g") == nil)
    }

    // MARK: - The silent re-home

    @Test("the silent re-home runs at launch without the screen, with the keep's steps")
    func silentRehomeAtLaunch() async throws {
        let device = Device("silent")
        device.cache(household: "hhr_g")
        let store = GardenGuardStore(directory: device.guardDirectory)
        try store.setBinding(Self.account, Self.binding("hhr_g"), newGrants: ["hhr_new"], journals: [
            "hhr_g": GardenGoneRecord(reason: .absentZone, action: .rehome, phase: .journaled,
                                      replacementID: "hhr_new", createdAt: Date())])
        let context = ModelContext(device.container)
        context.insert(LocalSeed(id: "s1", householdID: "hhr_g", state: .active, packetCount: 1, source: .store,
                                 customName: "Tomato", createdAt: 1, updatedAt: 1))
        try context.save()

        let launch = device.launch()
        #expect(launch.env.isLaunchGuardPending)   // nothing mutates before the account is verified
        await device.open(launch)
        await launch.env.gardenRunner.awaitJournal(account: Self.account, householdID: "hhr_g")

        #expect(launch.store.journal(Self.account, "hhr_g")?.phase == .done)
        #expect(launch.store.latestBinding(Self.account)?.household.id == "hhr_new")
        #expect(launch.store.grant(Self.account, "hhr_new")?.state == .pending)
        #expect(try Self.seedIDs(device, in: "hhr_new") == ["s1"])
        #expect(launch.env.gardenGoneScreen == nil)
        guard case .signedIn(_, let household) = launch.env.auth.state else { Issue.record("not signed in"); return }
        #expect(household.id == "hhr_new")
    }

    // MARK: - The new garden uploads through its grant

    @Test("the kept garden creates its zone through the grant and uploads every row, tombstones as tombstones")
    func newGardenUploadsThroughItsGrant() async throws {
        let rig = Rig(standard: true)
        defer { rig.cleanUp() }
        try rig.seed()
        try rig.seedPhotoBytes()
        try rig.chooseGone(.keep)
        try await rig.makeExecutor().run(account: Self.account, householdID: rig.old)
        #expect(rig.store.grant(Self.account, rig.new)?.state == .pending)

        let provisioner = FakeGardenProvisioner()
        let engine = HouseholdCloudCoordinatorTests.FakeEngine()
        let binding = try #require(rig.store.latestBinding(Self.account))
        let coordinator = HouseholdCloudCoordinator(
            engine: engine, zoneID: SeedkeepZoneProvisioner.zoneID(householdID: rig.new),
            householdID: rig.new, householdName: binding.household.name,
            householdCreatedAt: binding.household.createdAt, householdUpdatedAt: binding.household.updatedAt,
            container: rig.container, provisioner: provisioner, stateURL: nil)
        coordinator.guardContext = GardenGuardContext(store: rig.store, accountKey: { Self.account }, rehomer: RecordingRehomer())
        await coordinator.sync()

        // The zone and root were created once, through the grant, and the grant was consumed.
        #expect(provisioner.zoneSaves == [rig.new])
        #expect(rig.store.grant(Self.account, rig.new) == nil)
        #expect(rig.store.isSeen(Self.account, rig.new))
        #expect(provisioner.inspectCalls.isEmpty)
        #expect(coordinator.lastHumanizedError == nil)   // the dropped photos raise no sync notice
        // Everything uploaded, live and tombstoned; nothing went to the old zone.
        let saved = engine.savedRecords
        let names = Set(saved.map(\.recordID.recordName))
        #expect(names.isSuperset(of: [SeedkeepRecordNames.seed("seed_1"), SeedkeepRecordNames.seed("seed_2"),
                                      SeedkeepRecordNames.seed("seed_local_pending")]))
        #expect(saved.allSatisfy { $0.recordID.zoneID == SeedkeepZoneProvisioner.zoneID(householdID: rig.new) })
        let tombstone = try #require(saved.first { $0.recordID.recordName == SeedkeepRecordNames.seed("seed_2") })
        #expect(tombstone["deletedAt"] != nil)
        let live = try #require(saved.first { $0.recordID.recordName == SeedkeepRecordNames.seed("seed_1") })
        #expect(live["deletedAt"] == nil)
        // The photo with bytes carries its asset; the ones without are not uploaded.
        let withBytes = try #require(saved.first { $0.recordID.recordName == SeedkeepRecordNames.seedPhoto("seed_photo_local_ck") })
        #expect(withBytes["asset"] != nil)
        #expect(!names.contains(SeedkeepRecordNames.seedPhoto("photo_legacy")))
        #expect(!names.contains(SeedkeepRecordNames.journalEntryPhoto("jp_legacy")))
        // The migration marker keeps the one-time export from running a second upload.
        #expect(coordinator.initialUploadComplete)
    }

    // MARK: - Smaller guarantees

    @Test("an unreadable recovery snapshot can't hold a keep up")
    func unreadableSnapshotIsSkipped() async throws {
        let rig = Rig()
        defer { rig.cleanUp() }
        try rig.seed()
        let context = ModelContext(rig.container)
        context.insert(LocalJournalRecoveryItem(id: "garbage", scopeKey: "\(rig.old)|\(rig.signedIn)",
                                                snapshotJSON: "not json", detectedAt: 1, status: "pending"))
        try context.save()
        try rig.chooseGone(.keep, participant: true)
        try await rig.makeExecutor().run(account: Self.account, householdID: rig.old)
        #expect(rig.store.journal(Self.account, rig.old)?.phase == .done)
        #expect(try rig.recoveryItems().map(\.id) == ["other_rec"])
    }

    @Test("the sample garden can launch as a gone garden, with the owner or the participant wording")
    func sampleGardenGoneLaunch() throws {
        #expect(FixtureMode.gardenGone(arguments: ["-SeedkeepFixture", "-SeedkeepGardenGone", "owner"]) == .owner)
        #expect(FixtureMode.gardenGone(arguments: ["-SeedkeepFixture", "-SeedkeepGardenGone", "participant"]) == .participant)
        #expect(FixtureMode.gardenGone(arguments: ["-SeedkeepGardenGone", "owner"]) == nil)   // only in sample-garden mode
        #expect(FixtureMode.gardenGone(arguments: ["-SeedkeepFixture", "-SeedkeepGardenGone", "other"]) == nil)
        #expect(FixtureMode.gardenGone(arguments: ["-SeedkeepFixture"]) == nil)
        let account = GardenGuardStore.accountKey(recordName: FixtureCloudIdentityProvider.userRecordName)
        let id = FixtureCloudIdentityProvider.householdID
        for wording in [FixtureMode.GoneWording.owner, .participant] {
            let store = FixtureMode.goneGuard(wording)
            #expect(store.isGone(account, id))
            #expect((store.latestBinding(account)?.participant != nil) == (wording == .participant))
            #expect(store.journal(account, id)?.reason == (wording == .participant ? .accessLost : .zoneDeleted))
        }
    }

    @Test("quiescing the weather service returns when nothing is running")
    func weatherQuiesce() async throws {
        let device = try Self.goneDevice("quiesce")
        let launch = device.launch()
        await launch.env.weatherWarnings.quiesce()
    }
}
