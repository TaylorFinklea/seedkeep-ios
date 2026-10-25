import Foundation
import Testing
@testable import Seedkeep
import SeedkeepKit
import SeedkeepCloudKit
import CloudKit

/// N2-E (G1) §1 and §4: the guard's binding authority, the resolution order, fresh IDs and discovery.
/// No CloudKit: `FakeCloudIdentityProvider` answers every listing.
@MainActor
@Suite("Garden guard binding authority", .serialized)
struct GardenGuardAuthTests {
    private static let userA = "_userA"
    private static let userB = "_userB"
    private static let keyA = GardenGuardStore.accountKey(recordName: userA)
    private static let keyB = GardenGuardStore.accountKey(recordName: userB)

    private static func defaults(_ name: String) -> UserDefaults {
        let suite = "GardenGuardAuthTests.\(name)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private static func makeAuth(
        _ provider: FakeCloudIdentityProvider, defaults: UserDefaults, store: GardenGuardStore,
        rehomer: RecordingRehomer = RecordingRehomer(), onFullErase: @escaping () -> Void = {},
        ids: [String] = []
    ) -> AuthController {
        var queue = ids
        let auth = AuthController(
            identity: provider, tokenStore: InMemoryTokenStore(), defaults: defaults,
            guardStore: store, rehomer: rehomer,
            makeHouseholdID: { queue.isEmpty ? GardenHouseholdID.make() : queue.removeFirst() })
        auth.wireLocalDataEraser { onFullErase() }
        auth.wireGardenSwitchEraser {}
        return auth
    }

    private static func cache(_ defaults: UserDefaults, user: String, household: String) {
        let json = """
        {"user":{"id":"\(user)","name":null,"email":null},"household":{"id":"\(household)","name":"Mine","created_at":1,"updated_at":1}}
        """
        defaults.set(Data(json.utf8), forKey: AuthController.identityCacheKey)
    }

    private static func cachedHousehold(_ defaults: UserDefaults) -> String? {
        guard let data = defaults.data(forKey: AuthController.identityCacheKey) else { return nil }
        return (try? JSONDecoder().decode(AuthController.CachedIdentity.self, from: data))?.household.id
    }

    private static func binding(_ id: String) -> GardenGuardBinding {
        GardenGuardBinding(household: .init(id: id, name: "Mine", createdAt: 1, updatedAt: 1), participant: nil)
    }

    private static func zone(
        _ id: String, hasRoot: Bool = true, root: GardenZoneSummary.RootStatus? = nil,
        scope: GardenDatabaseScope = .owned
    ) -> GardenZoneSummary {
        var zone = FakeCloudIdentityProvider.zone(id, scope: scope, name: "Garden \(id)", updatedAt: 5)
        zone.rootStatus = root ?? (hasRoot ? .present : .absent)
        return zone
    }

    private static func household(_ auth: AuthController) -> String? {
        if case .signedIn(_, let household) = auth.state { return household.id }
        return nil
    }

    // MARK: - Binding authority

    @Test("a binding is written to the guard, with the pending grant of a minted garden, in one write")
    func bindingWritesGuardWithGrant() async {
        let store = GardenGuardStore(directory: GuardTestDirectory.make())
        let defaults = Self.defaults("bindGuard")
        let auth = Self.makeAuth(FakeCloudIdentityProvider(owned: [], shared: []), defaults: defaults,
                                 store: store, ids: ["hhr_minted"])
        await auth.restoreSession()
        #expect(Self.household(auth) == "hhr_minted")
        #expect(store.latestBinding(Self.keyA) == GardenGuardBinding(
            household: .init(id: "hhr_minted", name: "My garden",
                             createdAt: store.latestBinding(Self.keyA)!.household.createdAt,
                             updatedAt: store.latestBinding(Self.keyA)!.household.updatedAt),
            participant: nil))
        #expect(store.grant(Self.keyA, "hhr_minted")?.state == .pending)
        #expect(Self.cachedHousehold(defaults) == "hhr_minted")
    }

    @Test("a guard that can't be written binds nothing: the defaults are untouched")
    func unwritableGuardBindsNothing() async throws {
        let dir = GuardTestDirectory.make()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("bad".utf8).write(to: dir.appendingPathComponent(GardenGuardStore.fileName))
        let store = GardenGuardStore(directory: dir)
        let defaults = Self.defaults("unwritable")
        let auth = Self.makeAuth(FakeCloudIdentityProvider(owned: [], shared: []), defaults: defaults, store: store)
        await auth.restoreSession()
        guard case .failed = auth.state else { Issue.record("expected .failed, got \(auth.state)"); return }
        #expect(Self.cachedHousehold(defaults) == nil)
    }

    @Test("defaults are repaired from the guard's latest binding after resolution (crash after consuming a grant)")
    func defaultsRepairedFromLatestBinding() async throws {
        let store = GardenGuardStore(directory: GuardTestDirectory.make())
        // The guard saw the bind and the grant's consumption; the defaults still name the old household.
        try store.setBinding(Self.keyA, Self.binding("hhr_new"), newGrants: ["hhr_new"])
        try store.markAttempting(Self.keyA, "hhr_new")
        try store.consumeGrant(Self.keyA, "hhr_new", generation: 7)
        let defaults = Self.defaults("repair")
        Self.cache(defaults, user: Self.userA, household: "hh_old")
        let provider = FakeCloudIdentityProvider(owned: nil, shared: nil)
        let auth = Self.makeAuth(provider, defaults: defaults, store: store)

        await auth.restoreSession()

        #expect(Self.household(auth) == "hhr_new")
        #expect(Self.cachedHousehold(defaults) == "hhr_new")
        #expect(store.seen(Self.keyA, "hhr_new")?.generation == 7)
    }

    @Test("a different-account wipe still runs first, and only then are the defaults reconciled")
    func wipeRunsBeforeReconcile() async throws {
        let store = GardenGuardStore(directory: GuardTestDirectory.make())
        try store.setBinding(Self.keyB, Self.binding("hhr_b"))
        let defaults = Self.defaults("wipeFirst")
        Self.cache(defaults, user: Self.userA, household: "hh_a")
        var cacheAtWipe: String?
        let provider = FakeCloudIdentityProvider(recordName: Self.userB, owned: [], shared: [])
        let auth = Self.makeAuth(provider, defaults: defaults, store: store,
                                 onFullErase: { cacheAtWipe = Self.cachedHousehold(defaults) })

        await auth.restoreSession()

        #expect(cacheAtWipe == "hh_a", "the wipe sees the previous owner's identity, untouched by the guard")
        #expect(Self.household(auth) == "hhr_b")
        #expect(Self.cachedHousehold(defaults) == "hhr_b")
        #expect(store.latestBinding(Self.keyA) == nil)
    }

    @Test("existing installs seed the guard from their defaults")
    func seedsGuardFromDefaults() async {
        let store = GardenGuardStore(directory: nil)
        let defaults = Self.defaults("seed")
        Self.cache(defaults, user: Self.userA, household: "hh_a")
        ActiveGardenContext.recordParticipant(zoneName: "seedkeep-hh_o", ownerName: "_o", in: defaults)
        let auth = Self.makeAuth(FakeCloudIdentityProvider(owned: nil, shared: nil), defaults: defaults, store: store)
        await auth.restoreSession()
        let binding = store.latestBinding(Self.keyA)
        #expect(binding?.household.id == "hh_a")
        #expect(binding?.participant == .init(zoneName: "seedkeep-hh_o", ownerName: "_o"))
        #expect(binding?.gardenHouseholdID == "hh_o")
    }

    @Test("discard, then a successor bind, then relaunch: the successor and its grant survive; no other garden is made")
    func successorSurvivesRelaunch() async throws {
        let store = GardenGuardStore(directory: GuardTestDirectory.make())
        // The guard holds the successor and its pending grant; the defaults are durably empty.
        try store.setBinding(Self.keyA, Self.binding("hhr_successor"), newGrants: ["hhr_successor"])
        let defaults = Self.defaults("successor")
        let provider = FakeCloudIdentityProvider(owned: [], shared: [])
        let auth = Self.makeAuth(provider, defaults: defaults, store: store)

        await auth.restoreSession()

        #expect(Self.household(auth) == "hhr_successor")
        #expect(Self.cachedHousehold(defaults) == "hhr_successor")
        #expect(store.grant(Self.keyA, "hhr_successor")?.state == .pending)
        #expect(store.account(Self.keyA).grants.count == 1, "no second garden was minted")
        #expect(!provider.listCalls.contains(.shared), "the fresh resolution did not run")
    }

    @Test("account entries are kept across identity switches, and a returning account re-enters its binding")
    func accountEntriesKeptAcrossSwitches() async {
        let store = GardenGuardStore(directory: GuardTestDirectory.make())
        let defaults = Self.defaults("switches")
        let provider = FakeCloudIdentityProvider(recordName: Self.userA, owned: [], shared: [])
        let auth = Self.makeAuth(provider, defaults: defaults, store: store, ids: ["hhr_a", "hhr_b"])
        await auth.restoreSession()
        #expect(Self.household(auth) == "hhr_a")

        provider.recordName = Self.userB
        await auth.revalidateAfterAccountChange()
        #expect(Self.household(auth) == "hhr_b")
        #expect(store.latestBinding(Self.keyA)?.household.id == "hhr_a")
        #expect(store.grant(Self.keyA, "hhr_a")?.state == .pending)

        provider.recordName = Self.userA
        await auth.revalidateAfterAccountChange()
        #expect(Self.household(auth) == "hhr_a", "the returning account is re-entered, not replaced")
        #expect(store.latestBinding(Self.keyB)?.household.id == "hhr_b")
    }

    // MARK: - Fresh IDs and the keep paths

    @Test("legacy rebind with the device garden's zone absent: fresh ID, pending grant, journal, re-home seam")
    func legacyAbsentZoneRehomes() async throws {
        let store = GardenGuardStore(directory: GuardTestDirectory.make())
        let rehomer = RecordingRehomer()
        let defaults = Self.defaults("legacyAbsent")
        defaults.set(Data("""
        {"user":{"id":"u_server","name":null,"email":null},"household":{"id":"hh_legacy","name":"Old","created_at":1,"updated_at":1}}
        """.utf8), forKey: AuthController.legacyIdentityCacheKey)
        let auth = Self.makeAuth(FakeCloudIdentityProvider(owned: [], shared: []), defaults: defaults,
                                 store: store, rehomer: rehomer, ids: ["hhr_fresh"])

        await auth.restoreSession()

        #expect(Self.household(auth) == "hh_legacy", "the rows stay under the old ID until the re-home runs")
        #expect(store.grant(Self.keyA, "hhr_fresh")?.state == .pending)
        let journal = try #require(store.journal(Self.keyA, "hh_legacy"))
        #expect(journal.replacementID == "hhr_fresh")
        #expect(journal.reason == .absentZone)
        #expect(rehomer.requests == [GardenRehomeRequest(
            accountKey: Self.keyA, fromHouseholdID: "hh_legacy", toHouseholdID: "hhr_fresh", reason: .absentZone)])
        #expect(store.hasOpenJournal(Self.keyA, "hh_legacy"))
    }

    @Test("legacy rebind with the zone present keeps the household and creates nothing")
    func legacyPresentZoneKeeps() async {
        let store = GardenGuardStore(directory: nil)
        let rehomer = RecordingRehomer()
        let defaults = Self.defaults("legacyPresent")
        defaults.set(Data("""
        {"user":{"id":"u_server","name":null,"email":null},"household":{"id":"hh_legacy","name":"Old","created_at":1,"updated_at":1}}
        """.utf8), forKey: AuthController.legacyIdentityCacheKey)
        let auth = Self.makeAuth(FakeCloudIdentityProvider(owned: [Self.zone("hh_legacy")], shared: []),
                                 defaults: defaults, store: store, rehomer: rehomer)
        await auth.restoreSession()
        #expect(Self.household(auth) == "hh_legacy")
        #expect(rehomer.requests.isEmpty)
        #expect(store.account(Self.keyA).grants.isEmpty)
        #expect(store.isAcknowledged(Self.keyA, "hh_legacy"))
    }

    @Test("the chooser's keep-this-device's-garden goes through a fresh ID and the re-home seam")
    func chooserKeepRehomes() async throws {
        let store = GardenGuardStore(directory: nil)
        let rehomer = RecordingRehomer()
        let defaults = Self.defaults("chooserKeep")
        defaults.set(Data("""
        {"user":{"id":"u_server","name":null,"email":null},"household":{"id":"hh_legacy","name":"Old","created_at":1,"updated_at":1}}
        """.utf8), forKey: AuthController.legacyIdentityCacheKey)
        let other = Self.zone("hh_other")
        let auth = Self.makeAuth(FakeCloudIdentityProvider(owned: [other], shared: []), defaults: defaults,
                                 store: store, rehomer: rehomer, ids: ["hhr_fresh"])
        await auth.restoreSession()
        guard case .choosingGarden(let choice) = auth.state, choice.canKeepDeviceGarden else {
            Issue.record("expected the keep chooser, got \(auth.state)"); return
        }
        await auth.keepDeviceGarden()
        #expect(Self.household(auth) == "hh_legacy")
        #expect(store.grant(Self.keyA, "hhr_fresh")?.state == .pending)
        #expect(rehomer.requests.map(\.toHouseholdID) == ["hhr_fresh"])
        #expect(store.account(Self.keyA).gone["hh_legacy"]?.replacementID == "hhr_fresh")
    }

    @Test("owning the shared-garden-unavailable choice with the own zone absent makes a new garden under a grant")
    func sharedUnavailableOwnAbsentMintsFresh() async throws {
        let store = GardenGuardStore(directory: nil)
        let defaults = Self.defaults("sharedGone")
        defaults.set(Data("""
        {"user":{"id":"u_server","name":null,"email":null},"household":{"id":"hh_legacy","name":"Old","created_at":1,"updated_at":1}}
        """.utf8), forKey: AuthController.legacyIdentityCacheKey)
        ActiveGardenContext.recordParticipant(zoneName: "seedkeep-hh_gone", ownerName: "_o", in: defaults)
        let auth = Self.makeAuth(FakeCloudIdentityProvider(owned: [], shared: []), defaults: defaults,
                                 store: store, ids: ["hhr_fresh"])
        await auth.restoreSession()
        guard case .choosingGarden(let choice) = auth.state, let own = choice.ownGarden else {
            Issue.record("expected the chooser, got \(auth.state)"); return
        }
        await auth.chooseGarden(own, discardingDeviceData: true)
        #expect(Self.household(auth) == "hhr_fresh")
        #expect(store.grant(Self.keyA, "hhr_fresh")?.state == .pending)
    }

    // MARK: - Discovery

    private static func cachedAuth(
        _ name: String, owned: [GardenZoneSummary], store: GardenGuardStore, ids: [String] = []
    ) -> (AuthController, UserDefaults) {
        let defaults = Self.defaults(name)
        cache(defaults, user: userA, household: "hh_a")
        let auth = makeAuth(FakeCloudIdentityProvider(owned: owned, shared: []), defaults: defaults,
                            store: store, ids: ids)
        return (auth, defaults)
    }

    /// Runs discovery as the owner coordinator's start does after entry.
    private static func discover(_ auth: AuthController, owned: [GardenZoneSummary]) {
        guard case .signedIn(let user, let household) = auth.state else { return }
        auth.considerDiscovery(owned: owned, accountKey: GardenGuardStore.accountKey(recordName: user.id),
                               householdID: household.id)
    }

    @Test("first launch acknowledges pre-N2-E IDs silently; a random-format garden is offered once")
    func discoveryFirstLaunch() async throws {
        let store = GardenGuardStore(directory: GuardTestDirectory.make())
        let preN2E = Self.zone("hh_pre"), random = Self.zone("hhr_found")
        let ownedList = [Self.zone("hh_a"), preN2E, random]
        let (auth, defaults) = Self.cachedAuth("discovery1", owned: ownedList, store: store)

        await auth.restoreSession()
        #expect(Self.household(auth) == "hh_a", "entry comes first")
        Self.discover(auth, owned: ownedList)

        guard case .choosingGarden(let choice) = auth.state else {
            Issue.record("expected the discovery chooser, got \(auth.state)"); return
        }
        #expect(choice.reason == .discoveredOwnGardens)
        #expect(choice.candidates == [preN2E, random], "every eligible garden is offered, acknowledged ones included")
        #expect(choice.ownGarden?.householdID == "hh_a")
        #expect(store.isAcknowledged(Self.keyA, "hh_pre"))
        #expect(!store.isAcknowledged(Self.keyA, "hhr_found"))
        #expect(!AuthController.choiceDiscardsDeviceData(choice, try #require(choice.ownGarden)))
        #expect(AuthController.choiceDiscardsDeviceData(choice, random))

        // Keep this device's garden: everything shown is acknowledged, and it is not asked again.
        await auth.chooseGarden(try #require(choice.ownGarden), discardingDeviceData: false)
        #expect(Self.household(auth) == "hh_a")
        #expect(store.isAcknowledged(Self.keyA, "hhr_found"))
        #expect(Self.cachedHousehold(defaults) == "hh_a")
        await auth.restoreSession()
        #expect(Self.household(auth) == "hh_a")
        Self.discover(auth, owned: ownedList)   // acknowledged: not asked again
        #expect(Self.household(auth) == "hh_a")
    }

    @Test("picking the discovered garden replaces this device's, after the discard")
    func discoveryPickOther() async throws {
        let store = GardenGuardStore(directory: nil)
        let random = Self.zone("hhr_found")
        let (auth, _) = Self.cachedAuth("discovery2", owned: [], store: store)
        await auth.restoreSession()
        Self.discover(auth, owned: [Self.zone("hh_a"), random])
        await auth.chooseGarden(random, discardingDeviceData: false)   // needs the confirmation
        guard case .choosingGarden = auth.state else { Issue.record("must wait for the confirmation"); return }
        await auth.chooseGarden(random, discardingDeviceData: true)
        #expect(Self.household(auth) == "hhr_found")
        #expect(store.latestBinding(Self.keyA)?.household.id == "hhr_found")
    }

    @Test("incomplete, retired and seen gardens are never offered")
    func discoveryEligibility() async throws {
        let store = GardenGuardStore(directory: nil)
        try store.markDiscoveryInitialized(Self.keyA, acknowledging: [])
        try store.setBinding(Self.keyA, Self.binding("hh_a"), newGrants: ["hhr_retired"])
        _ = try store.abandonGrant(Self.keyA, "hhr_retired", freshID: "hhr_next")
        try store.recordSeen(Self.keyA, "hhr_seen", generation: 3)
        let (auth, _) = Self.cachedAuth("discovery3", owned: [], store: store)
        await auth.restoreSession()
        Self.discover(auth, owned: [
            Self.zone("hh_a"), Self.zone("hhr_incomplete", hasRoot: false),
            Self.zone("hhr_retired"), Self.zone("hhr_seen"),
        ])
        #expect(Self.household(auth) == "hh_a")
    }

    @Test("after the first launch a new pre-N2-E-format garden is offered too")
    func discoveryAfterFirstLaunch() async throws {
        let store = GardenGuardStore(directory: nil)
        try store.markDiscoveryInitialized(Self.keyA, acknowledging: ["hh_a"])
        let late = Self.zone("hh_late")
        let (auth, _) = Self.cachedAuth("discovery4", owned: [], store: store)
        await auth.restoreSession()
        Self.discover(auth, owned: [Self.zone("hh_a"), late])
        guard case .choosingGarden(let choice) = auth.state else { Issue.record("expected the chooser"); return }
        #expect(choice.candidates == [late])
    }

    @Test("a hanging or failing listing never delays entry: the cached path makes no listing")
    func listingNeverDelaysEntry() async {
        let defaults = Self.defaults("discovery5")
        Self.cache(defaults, user: Self.userA, household: "hh_a")
        let provider = FakeCloudIdentityProvider(owned: nil, shared: nil)
        provider.holdNextListing()   // would hang forever if anything listed
        let auth = Self.makeAuth(provider, defaults: defaults, store: GardenGuardStore(directory: nil))
        await auth.restoreSession()
        #expect(Self.household(auth) == "hh_a")
        #expect(provider.listCalls.isEmpty)
    }

    @Test("a discovery result for another account or garden is dropped, and wipes or rebinds nothing")
    func staleDiscoveryDropped() async {
        let store = GardenGuardStore(directory: nil)
        let (auth, defaults) = Self.cachedAuth("discovery6", owned: [], store: store)
        await auth.restoreSession()
        let found = [Self.zone("hh_a"), Self.zone("hhr_found")]
        auth.considerDiscovery(owned: found, accountKey: Self.keyB, householdID: "hh_a")
        auth.considerDiscovery(owned: found, accountKey: Self.keyA, householdID: "hh_other")
        #expect(Self.household(auth) == "hh_a")
        #expect(Self.cachedHousehold(defaults) == "hh_a")
    }

    @Test("the owner coordinator's start lists once after entry and the chooser appears through the auth controller")
    func coordinatorStartTriggersDiscovery() async throws {
        let store = GardenGuardStore(directory: nil)
        let (auth, _) = Self.cachedAuth("discovery7", owned: [], store: store)
        await auth.restoreSession()
        let provisioner = FakeGardenProvisioner()
        provisioner.setExistingRoot(householdID: "hh_a")
        provisioner.setOwnedListing([Self.zone("hh_a"), Self.zone("hhr_found")])
        let coordinator = HouseholdCloudCoordinator(
            engine: HouseholdCloudCoordinatorTests.FakeEngine(),
            zoneID: SeedkeepZoneProvisioner.zoneID(householdID: "hh_a"), householdID: "hh_a",
            householdName: "Mine", householdCreatedAt: 1, householdUpdatedAt: 1,
            container: makeTestContainer(name: "disc-\(UUID().uuidString)"),
            provisioner: provisioner, stateURL: nil)
        coordinator.guardContext = GardenGuardContext(
            store: store, accountKey: { Self.keyA }, rehomer: RecordingRehomer())
        coordinator.onOwnedGardensListed = { owned, account, household in
            auth.considerDiscovery(owned: owned, accountKey: account, householdID: household)
        }
        await coordinator.sync()
        for _ in 0..<200 {
            if case .choosingGarden = auth.state { break }
            await Task.yield()
        }
        guard case .choosingGarden(let choice) = auth.state else { Issue.record("expected the chooser"); return }
        #expect(choice.reason == .discoveredOwnGardens)
        #expect(choice.candidates.map(\.householdID) == ["hhr_found"])
    }

    // MARK: - Review fixes

    private static let legacyJSON = """
    {"user":{"id":"u_server","name":null,"email":null},"household":{"id":"hh_legacy","name":"Old","created_at":1,"updated_at":1}}
    """

    @Test("a cleared binding clears the defaults and is never re-seeded from the stale cache")
    func clearedBindingIsNotReseeded() async throws {
        let store = GardenGuardStore(directory: GuardTestDirectory.make())
        try store.setBinding(Self.keyA, Self.binding("hh_old"))
        try store.setBinding(Self.keyA, nil)   // the discard cleared it; the defaults never caught up
        let defaults = Self.defaults("cleared")
        Self.cache(defaults, user: Self.userA, household: "hh_old")
        ActiveGardenContext.recordParticipant(zoneName: "seedkeep-hh_o", ownerName: "_o", in: defaults)
        let provider = FakeCloudIdentityProvider(owned: [], shared: [])
        let auth = Self.makeAuth(provider, defaults: defaults, store: store, ids: ["hhr_next"])

        await auth.restoreSession()

        #expect(Self.household(auth) == "hhr_next", "the discarded garden is not re-entered")
        #expect(store.latestBinding(Self.keyA)?.household.id == "hhr_next")
        #expect(ActiveGardenContext.participant(in: defaults) == nil)
        #expect(Self.cachedHousehold(defaults) == "hhr_next")
    }

    @Test("a newer binding supersedes an open re-home journal, and a relaunch never replays it")
    func newerBindingSupersedesJournal() async throws {
        let store = GardenGuardStore(directory: GuardTestDirectory.make())
        let rehomer = RecordingRehomer()
        let defaults = Self.defaults("supersede")
        defaults.set(Data(Self.legacyJSON.utf8), forKey: AuthController.legacyIdentityCacheKey)
        let first = Self.makeAuth(FakeCloudIdentityProvider(owned: [], shared: []), defaults: defaults,
                                  store: store, rehomer: rehomer, ids: ["hhr_fresh"])
        await first.restoreSession()
        #expect(store.hasOpenJournal(Self.keyA, "hh_legacy"))
        #expect(rehomer.requests.count == 1)

        // A share adopted while the journal is open (AppEnvironment.writeGuardBinding's write).
        var adopted = try #require(store.latestBinding(Self.keyA))
        adopted.participant = .init(zoneName: "seedkeep-hh_o", ownerName: "_o")
        try store.setBinding(Self.keyA, adopted)
        #expect(store.journal(Self.keyA, "hh_legacy")?.phase == .superseded)
        #expect(!store.hasOpenJournal(Self.keyA, "hh_legacy"))

        // Relaunch: the newer binding is entered, nothing is replayed.
        let relaunchRehomer = RecordingRehomer()
        let second = Self.makeAuth(FakeCloudIdentityProvider(owned: nil, shared: nil), defaults: defaults,
                                   store: store, rehomer: relaunchRehomer)
        await second.restoreSession()
        #expect(Self.household(second) == "hh_legacy")
        #expect(ActiveGardenContext.participant(in: defaults)?.zoneName == "seedkeep-hh_o")
        #expect(relaunchRehomer.requests.isEmpty)
        #expect(!store.hasOpenJournal(Self.keyA, "hh_legacy"))
    }

    @Test("a binding to the journal's own replacement completes it instead of superseding")
    func bindingToReplacementKeepsJournal() throws {
        let store = GardenGuardStore(directory: nil)
        try store.setBinding(Self.keyA, Self.binding("hh_old"), newGrants: ["hhr_new"], journals: [
            "hh_old": GardenGoneRecord(reason: .absentZone, action: .rehome, phase: .journaled,
                                       replacementID: "hhr_new", createdAt: Date())])
        try store.setBinding(Self.keyA, Self.binding("hhr_new"))
        #expect(store.journal(Self.keyA, "hh_old")?.phase == .journaled)
    }

    @Test("one rootless zone is treated as no garden: a fresh random garden under a grant")
    func rootlessZoneIsNoGarden() async {
        let store = GardenGuardStore(directory: nil)
        let auth = Self.makeAuth(
            FakeCloudIdentityProvider(owned: [Self.zone("hh_rootless", hasRoot: false)], shared: []),
            defaults: Self.defaults("rootless1"), store: store, ids: ["hhr_fresh"])
        await auth.restoreSession()
        #expect(Self.household(auth) == "hhr_fresh")
        #expect(store.grant(Self.keyA, "hhr_fresh")?.state == .pending)
    }

    @Test("a rootless zone among several never appears in the chooser")
    func rootlessZoneNotOffered() async {
        let a = Self.zone("hh_1"), c = Self.zone("hh_3")
        let auth = Self.makeAuth(
            FakeCloudIdentityProvider(owned: [a, Self.zone("hh_2", hasRoot: false), c], shared: []),
            defaults: Self.defaults("rootless2"), store: GardenGuardStore(directory: nil))
        await auth.restoreSession()
        guard case .choosingGarden(let choice) = auth.state else { Issue.record("expected the chooser"); return }
        #expect(choice.candidates == [a, c])
    }

    @Test("a legacy garden whose zone has no root takes the absent-zone path")
    func legacyRootlessIsAbsent() async {
        let store = GardenGuardStore(directory: nil)
        let rehomer = RecordingRehomer()
        let defaults = Self.defaults("rootless3")
        defaults.set(Data(Self.legacyJSON.utf8), forKey: AuthController.legacyIdentityCacheKey)
        let auth = Self.makeAuth(
            FakeCloudIdentityProvider(owned: [Self.zone("hh_legacy", hasRoot: false)], shared: []),
            defaults: defaults, store: store, rehomer: rehomer, ids: ["hhr_fresh"])
        await auth.restoreSession()
        #expect(rehomer.requests.map(\.toHouseholdID) == ["hhr_fresh"])
        #expect(store.grant(Self.keyA, "hhr_fresh")?.state == .pending)
    }

    @Test("a legacy rebind acknowledges the bound garden, not an unseen random-format one")
    func legacyRebindDoesNotAcknowledgeUnseen() async {
        let store = GardenGuardStore(directory: nil)
        let defaults = Self.defaults("ack1")
        defaults.set(Data(Self.legacyJSON.utf8), forKey: AuthController.legacyIdentityCacheKey)
        let owned = [Self.zone("hh_legacy"), Self.zone("hhr_new")]
        let auth = Self.makeAuth(FakeCloudIdentityProvider(owned: owned, shared: []), defaults: defaults, store: store)
        await auth.restoreSession()
        #expect(Self.household(auth) == "hh_legacy")
        #expect(!store.isAcknowledged(Self.keyA, "hhr_new"))
        Self.discover(auth, owned: owned)
        guard case .choosingGarden(let choice) = auth.state else { Issue.record("expected discovery"); return }
        #expect(choice.candidates.map(\.householdID) == ["hhr_new"])
    }

    @Test("discovery offers every eligible garden, acknowledged ones included, once one is new")
    func discoveryOffersAllEligible() async throws {
        let store = GardenGuardStore(directory: nil)
        try store.markDiscoveryInitialized(Self.keyA, acknowledging: ["hh_a", "hh_b"])
        let b = Self.zone("hh_b"), c = Self.zone("hhr_c")
        let (auth, _) = Self.cachedAuth("discovery8", owned: [], store: store)
        await auth.restoreSession()
        Self.discover(auth, owned: [Self.zone("hh_a"), b, c])
        guard case .choosingGarden(let choice) = auth.state else { Issue.record("expected discovery"); return }
        #expect(choice.candidates == [b, c])
        #expect(choice.ownGarden?.householdID == "hh_a")
    }

    @Test("keeping the device garden re-homes only a zone the listings confirmed absent")
    func keepOnlyRehomesConfirmedAbsent() async throws {
        // Confirmed absent (both listings succeeded, other gardens exist): re-homed.
        let absentRehomer = RecordingRehomer()
        let absentDefaults = Self.defaults("keep1")
        absentDefaults.set(Data(Self.legacyJSON.utf8), forKey: AuthController.legacyIdentityCacheKey)
        let absent = Self.makeAuth(FakeCloudIdentityProvider(owned: [Self.zone("hh_other")], shared: []),
                                   defaults: absentDefaults, store: GardenGuardStore(directory: nil),
                                   rehomer: absentRehomer, ids: ["hhr_fresh"])
        await absent.restoreSession()
        await absent.keepDeviceGarden()
        #expect(absentRehomer.requests.count == 1)

        // The shared-garden-unavailable choice never offers keep, so nothing is re-homed or bound.
        let sharedRehomer = RecordingRehomer()
        let sharedDefaults = Self.defaults("keep2")
        sharedDefaults.set(Data(Self.legacyJSON.utf8), forKey: AuthController.legacyIdentityCacheKey)
        ActiveGardenContext.recordParticipant(zoneName: "seedkeep-hh_gone", ownerName: "_o", in: sharedDefaults)
        let shared = Self.makeAuth(FakeCloudIdentityProvider(owned: [Self.zone("hh_legacy")], shared: []),
                                   defaults: sharedDefaults, store: GardenGuardStore(directory: nil),
                                   rehomer: sharedRehomer)
        await shared.restoreSession()
        await shared.keepDeviceGarden()
        guard case .choosingGarden = shared.state else { Issue.record("still choosing"); return }
        #expect(sharedRehomer.requests.isEmpty)
    }

    // MARK: - Root status is tri-state (present / confirmed absent / unknown)

    private static func expectNothingMinted(_ store: GardenGuardStore, _ rehomer: RecordingRehomer) {
        let account = store.account(keyA)
        #expect(account.grants.isEmpty)
        #expect(account.gone.isEmpty)
        #expect(account.binding == nil)
        #expect(rehomer.requests.isEmpty)
    }

    @Test("only unknownItem confirms a root absent; every other read error is unknown")
    func rootReadClassification() {
        #expect(LiveCloudIdentityProvider.rootStatus(forReadError: CKError(.unknownItem)) == .absent)
        for error in [CKError(.networkFailure), CKError(.networkUnavailable), CKError(.zoneNotFound),
                      CKError(.requestRateLimited), CKError(.partialFailure)] as [Error] {
            #expect(LiveCloudIdentityProvider.rootStatus(forReadError: error) == .unknown)
        }
        #expect(LiveCloudIdentityProvider.rootStatus(forReadError: LiveCloudIdentityProvider.TimedOut()) == .unknown)
    }

    @Test("fresh resolution with an unknown owned root verifies nothing: no garden, grant or binding")
    func freshUnknownOwnedRoot() async {
        let store = GardenGuardStore(directory: nil), rehomer = RecordingRehomer()
        let defaults = Self.defaults("unknown1")
        let auth = Self.makeAuth(FakeCloudIdentityProvider(owned: [Self.zone("hh_x", root: .unknown)], shared: []),
                                 defaults: defaults, store: store, rehomer: rehomer)
        await auth.restoreSession()
        #expect(auth.state == .needsICloud(.couldNotVerify))
        Self.expectNothingMinted(store, rehomer)
        #expect(Self.cachedHousehold(defaults) == nil)
    }

    @Test("an unknown root among several owned gardens never reaches the chooser")
    func chooserUnknownOwnedRoot() async {
        let store = GardenGuardStore(directory: nil), rehomer = RecordingRehomer()
        let auth = Self.makeAuth(
            FakeCloudIdentityProvider(owned: [Self.zone("hh_1"), Self.zone("hh_2", root: .unknown)], shared: []),
            defaults: Self.defaults("unknown2"), store: store, rehomer: rehomer)
        await auth.restoreSession()
        #expect(auth.state == .needsICloud(.couldNotVerify))
        Self.expectNothingMinted(store, rehomer)
    }

    @Test("legacy resolution with an unknown owned root neither re-homes nor binds")
    func legacyUnknownOwnedRoot() async {
        let store = GardenGuardStore(directory: nil), rehomer = RecordingRehomer()
        let defaults = Self.defaults("unknown3")
        defaults.set(Data(Self.legacyJSON.utf8), forKey: AuthController.legacyIdentityCacheKey)
        let auth = Self.makeAuth(
            FakeCloudIdentityProvider(owned: [Self.zone("hh_legacy", root: .unknown)], shared: []),
            defaults: defaults, store: store, rehomer: rehomer, ids: ["hhr_fresh"])
        await auth.restoreSession()
        #expect(!auth.isIdentityVerified, "entered as-is and unconfirmed")
        Self.expectNothingMinted(store, rehomer)
    }

    @Test("legacy marker, unavailable share and an unknown own root: unconfirmed, nothing offered or minted")
    func legacyMarkerUnknownOwnRoot() async {
        let store = GardenGuardStore(directory: nil), rehomer = RecordingRehomer()
        let defaults = Self.defaults("unknown7")
        defaults.set(Data(Self.legacyJSON.utf8), forKey: AuthController.legacyIdentityCacheKey)
        ActiveGardenContext.recordParticipant(zoneName: "seedkeep-hh_gone", ownerName: "_owner_hh_gone", in: defaults)
        let auth = Self.makeAuth(
            FakeCloudIdentityProvider(owned: [Self.zone("hh_legacy", root: .unknown)], shared: []),
            defaults: defaults, store: store, rehomer: rehomer, ids: ["hhr_fresh"])
        await auth.restoreSession()
        #expect(!auth.isIdentityVerified, "entered as-is and unconfirmed")
        if case .choosingGarden = auth.state { Issue.record("no chooser on an unconfirmed own root") }
        Self.expectNothingMinted(store, rehomer)
    }

    @Test("an unknown shared root fails verification in fresh and legacy resolution")
    func unknownSharedRoot() async {
        let store = GardenGuardStore(directory: nil), rehomer = RecordingRehomer()
        let fresh = Self.makeAuth(
            FakeCloudIdentityProvider(owned: [], shared: [Self.zone("hh_s", root: .unknown, scope: .shared)]),
            defaults: Self.defaults("unknown4"), store: store, rehomer: rehomer)
        await fresh.restoreSession()
        #expect(fresh.state == .needsICloud(.couldNotVerify))

        let defaults = Self.defaults("unknown5")
        defaults.set(Data(Self.legacyJSON.utf8), forKey: AuthController.legacyIdentityCacheKey)
        ActiveGardenContext.recordParticipant(zoneName: "seedkeep-hh_s", ownerName: "_owner_hh_s", in: defaults)
        let legacy = Self.makeAuth(
            FakeCloudIdentityProvider(owned: [], shared: [Self.zone("hh_s", root: .unknown, scope: .shared)]),
            defaults: defaults, store: store, rehomer: rehomer)
        await legacy.restoreSession()
        #expect(!legacy.isIdentityVerified)
        Self.expectNothingMinted(store, rehomer)
    }

    @Test("discovery gives no prompt for an unknown root, and offers only the complete gardens otherwise")
    func discoveryUnknownRoot() async throws {
        let store = GardenGuardStore(directory: nil)
        try store.markDiscoveryInitialized(Self.keyA, acknowledging: ["hh_a"])
        let (auth, _) = Self.cachedAuth("unknown6", owned: [], store: store)
        await auth.restoreSession()
        Self.discover(auth, owned: [Self.zone("hh_a"), Self.zone("hhr_u", root: .unknown)])
        #expect(Self.household(auth) == "hh_a")
        let ok = Self.zone("hhr_ok")
        Self.discover(auth, owned: [Self.zone("hh_a"), Self.zone("hhr_u", root: .unknown), ok])
        guard case .choosingGarden(let choice) = auth.state else { Issue.record("expected discovery"); return }
        #expect(choice.candidates == [ok])
    }

    // MARK: Shared gardens are filtered like owned ones

    @Test("a matching legacy shared marker whose zone has no root is not rejoined: the chooser appears")
    func legacySharedMarkerRootless() async {
        let store = GardenGuardStore(directory: nil)
        let defaults = Self.defaults("sharedRootless1")
        defaults.set(Data(Self.legacyJSON.utf8), forKey: AuthController.legacyIdentityCacheKey)
        let shared = Self.zone("hh_s", root: .absent, scope: .shared)
        ActiveGardenContext.recordParticipant(zoneName: shared.zoneName, ownerName: shared.ownerName, in: defaults)
        let auth = Self.makeAuth(FakeCloudIdentityProvider(owned: [Self.zone("hh_legacy")], shared: [shared]),
                                 defaults: defaults, store: store)
        await auth.restoreSession()
        guard case .choosingGarden(let choice) = auth.state,
              case .sharedGardenUnavailable = choice.reason else { Issue.record("expected the unavailable chooser"); return }
        #expect(choice.candidates.isEmpty)
        #expect(store.latestBinding(Self.keyA) == nil)
    }

    @Test("a lone rootless shared garden is not auto-bound on a fresh device")
    func freshLoneSharedRootless() async {
        let store = GardenGuardStore(directory: nil)
        let defaults = Self.defaults("sharedRootless2")
        let auth = Self.makeAuth(
            FakeCloudIdentityProvider(owned: [], shared: [Self.zone("hh_s", root: .absent, scope: .shared)]),
            defaults: defaults, store: store, ids: ["hhr_fresh"])
        await auth.restoreSession()
        #expect(Self.household(auth) == "hhr_fresh")
        #expect(ActiveGardenContext.participant(in: defaults) == nil)
        #expect(store.latestBinding(Self.keyA)?.participant == nil)
    }

    @Test("a rootless shared garden is absent from a shared chooser")
    func sharedChooserExcludesRootless() async {
        let a = Self.zone("hh_s1", scope: .shared), b = Self.zone("hh_s3", scope: .shared)
        let auth = Self.makeAuth(
            FakeCloudIdentityProvider(owned: [], shared: [a, Self.zone("hh_s2", root: .absent, scope: .shared), b]),
            defaults: Self.defaults("sharedRootless3"), store: GardenGuardStore(directory: nil))
        await auth.restoreSession()
        guard case .choosingGarden(let choice) = auth.state else { Issue.record("expected the chooser"); return }
        #expect(choice.candidates == [a, b])
    }

    @Test("a rootless shared garden is not a legacy candidate: the absent-zone path runs")
    func legacyCandidatesExcludeRootlessShared() async {
        let store = GardenGuardStore(directory: nil), rehomer = RecordingRehomer()
        let defaults = Self.defaults("sharedRootless4")
        defaults.set(Data(Self.legacyJSON.utf8), forKey: AuthController.legacyIdentityCacheKey)
        let auth = Self.makeAuth(
            FakeCloudIdentityProvider(owned: [], shared: [Self.zone("hh_s", root: .absent, scope: .shared)]),
            defaults: defaults, store: store, rehomer: rehomer, ids: ["hhr_fresh"])
        await auth.restoreSession()
        #expect(rehomer.requests.map(\.toHouseholdID) == ["hhr_fresh"])
    }
}
