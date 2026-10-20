import Testing
import Foundation
import SwiftData
@testable import Seedkeep
import SeedkeepKit

/// Identity lifecycle (Stabilization B3, rewritten for N1 Apple-only entry):
///
/// 1. `SyncEngine.eraseAllLocalData` wipes every model generically from `SeedkeepSchema.all`
///    (store + pending-write queue + cursors).
/// 2. The iCloud account is the identity. Transient failures enter from the cache with CloudKit
///    paused and never wipe; failed listings never read as "no gardens".
/// 3. Only a confirmed different iCloud user, an explicit chooser discard, or sign-out run the
///    eraser, and a failed wipe binds nothing.
/// 4. A legacy server identity is rebound in place (no wipe) once its garden is found.
///
/// No live CloudKit: every controller gets a `FakeCloudIdentityProvider`.
@MainActor
@Suite("Auth lifecycle (N1 iCloud identity)", .serialized)
struct AuthLifecycleTests {

    private static let userA = "_userA"
    private static let userB = "_userB"

    // MARK: - Fixtures

    private static func makeDefaults(_ name: String) -> UserDefaults {
        let suite = "AuthLifecycleTests.\(name)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    /// Counts eraser runs: `count` for the full (different-user) eraser, `switchCount` for the
    /// garden-switch (chooser discard) eraser. Each throws while its `failing` flag is set; the
    /// garden-switch eraser can also be held open mid-erase.
    @MainActor
    final class EraserSpy {
        var count = 0
        var failing = false
        var switchCount = 0
        var switchFailing = false
        struct Failed: Error {}

        private var holdSwitch = false
        private var heldSwitch: CheckedContinuation<Void, Never>?
        func holdNextSwitch() { holdSwitch = true }
        func releaseSwitch() { heldSwitch?.resume(); heldSwitch = nil }
        func waitUntilSwitchIsHeld() async { while heldSwitch == nil { await Task.yield() } }

        @MainActor
        func runSwitch() async throws {
            if holdSwitch {
                holdSwitch = false
                await withCheckedContinuation { heldSwitch = $0 }
            }
            if switchFailing { throw Failed() }
            switchCount += 1
        }
    }

    private static func makeAuth(
        _ provider: FakeCloudIdentityProvider,
        defaults: UserDefaults,
        tokenStore: InMemoryTokenStore = InMemoryTokenStore(),
        eraser: EraserSpy = EraserSpy()
    ) -> AuthController {
        let auth = AuthController(identity: provider, tokenStore: tokenStore, defaults: defaults)
        auth.wireLocalDataEraser {
            if eraser.failing { throw EraserSpy.Failed() }
            eraser.count += 1
        }
        auth.wireGardenSwitchEraser { try await eraser.runSwitch() }
        return auth
    }

    private static func identityJSON(userID: String, householdID: String) -> Data {
        Data("""
        {"user":{"id":"\(userID)","name":"Gardener","email":"g@example.com"},"household":{"id":"\(householdID)","name":"My household","created_at":1,"updated_at":1}}
        """.utf8)
    }

    private static func cacheICloud(_ defaults: UserDefaults, userID: String, householdID: String) throws {
        let data = identityJSON(userID: userID, householdID: householdID)
        _ = try JSONDecoder().decode(AuthController.CachedIdentity.self, from: data)
        defaults.set(data, forKey: AuthController.identityCacheKey)
    }

    private static func cacheLegacy(_ defaults: UserDefaults, userID: String, householdID: String) throws {
        let data = identityJSON(userID: userID, householdID: householdID)
        _ = try JSONDecoder().decode(AuthController.CachedIdentity.self, from: data)
        defaults.set(data, forKey: AuthController.legacyIdentityCacheKey)
    }

    private static func cached(_ defaults: UserDefaults, _ key: String) -> AuthController.CachedIdentity? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(AuthController.CachedIdentity.self, from: data)
    }

    private static func zone(_ id: String, _ scope: GardenDatabaseScope = .owned) -> GardenZoneSummary {
        FakeCloudIdentityProvider.zone(id, scope: scope, name: "Garden \(id)", updatedAt: 5)
    }

    private static func signedIn(_ auth: AuthController) -> (user: String, household: String)? {
        guard case .signedIn(let user, let household) = auth.state else { return nil }
        return (user.id, household.id)
    }

    enum CacheKind: String, CaseIterable, Sendable { case iCloud, legacy, none }

    private static func plant(_ kind: CacheKind, _ defaults: UserDefaults) throws {
        switch kind {
        case .iCloud: try cacheICloud(defaults, userID: userA, householdID: "hh_cached")
        case .legacy: try cacheLegacy(defaults, userID: "u_server", householdID: "hh_cached")
        case .none: break
        }
    }

    // MARK: - Generic wipe

    @Test("eraseAllLocalData wipes every model in SeedkeepSchema.all, including queue and cursors")
    func eraseWipesGenerically() async throws {
        let container = makeTestContainer(name: "authErase")
        let client = SeedkeepClient(configuration: .init(
            baseURL: URL(string: "https://test.local")!, session: ServerRetirement.makeRefusingSession()))
        let engine = SyncEngine(client: client, container: container)
        let context = ModelContext(container)
        context.insert(LocalSeed(
            id: "seed_wipe", householdID: "hh_auth", state: .active,
            packetCount: 1, source: .store, createdAt: 1, updatedAt: 1))
        context.insert(LocalPendingWrite(
            id: "pw_wipe", entityType: "seed", entityID: "seed_wipe",
            operation: "update", payloadJSON: "{}", createdAt: 1))
        context.insert(LocalSyncCursor(
            householdID: "hh_auth", kind: "seeds", cursor: 999, lastSyncedAt: 1))
        context.insert(LocalJournalEntry(
            id: "je_wipe", householdID: "hh_auth",
            occurredOn: "2026-06-01", body: "wipe me",
            seedID: nil, bedID: nil, plantingEventID: nil,
            createdAt: 1, updatedAt: 1, deletedAt: nil))
        try context.save()

        try engine.eraseAllLocalData()

        let fresh = ModelContext(container)
        #expect(try fresh.fetch(FetchDescriptor<LocalSeed>()).isEmpty)
        #expect(try fresh.fetch(FetchDescriptor<LocalPendingWrite>()).isEmpty,
                "queued writes must never flush into another account's household")
        #expect(try fresh.fetch(FetchDescriptor<LocalSyncCursor>()).isEmpty,
                "cursors must reset — corrections feed is per-user")
        #expect(try fresh.fetch(FetchDescriptor<LocalJournalEntry>()).isEmpty)
    }

    // MARK: - iCloud cache

    @Test("the same user from the iCloud cache enters directly: no listing, no wipe")
    func sameUserFromCache() async throws {
        let defaults = Self.makeDefaults("sameUser")
        try Self.cacheICloud(defaults, userID: Self.userA, householdID: "hh_a")
        let provider = FakeCloudIdentityProvider(recordName: Self.userA, owned: nil, shared: nil)
        let eraser = EraserSpy()
        let auth = Self.makeAuth(provider, defaults: defaults, eraser: eraser)

        await auth.restoreSession()

        #expect(Self.signedIn(auth)?.user == Self.userA)
        #expect(Self.signedIn(auth)?.household == "hh_a")
        #expect(auth.isIdentityVerified)
        #expect(provider.listCalls.isEmpty, "a confirmed cached user needs no zone listing")
        #expect(eraser.count == 0)
    }

    @Test("a different iCloud user wipes, then resolves fresh")
    func differentUserWipesThenResolvesFresh() async throws {
        let defaults = Self.makeDefaults("differentUser")
        try Self.cacheICloud(defaults, userID: Self.userA, householdID: "hh_a")
        ActiveGardenContext.recordParticipant(zoneName: "seedkeep-hh_x", ownerName: "_x", in: defaults)
        let provider = FakeCloudIdentityProvider(recordName: Self.userB, owned: [Self.zone("hh_b")])
        let eraser = EraserSpy()
        let auth = Self.makeAuth(provider, defaults: defaults, eraser: eraser)

        await auth.restoreSession()

        #expect(eraser.count == 1, "account B must never see account A's store")
        #expect(eraser.switchCount == 0, "a different user gets the full eraser")
        #expect(Self.signedIn(auth)?.user == Self.userB)
        #expect(Self.signedIn(auth)?.household == "hh_b")
        #expect(ActiveGardenContext.participant(in: defaults) == nil, "A's shared garden is not B's")
        #expect(Self.cached(defaults, AuthController.identityCacheKey)?.user.id == Self.userB)
    }

    // MARK: - Account states

    @Test("no iCloud account asks to sign in to iCloud and wipes nothing", arguments: CacheKind.allCases)
    func noAccount(_ kind: CacheKind) async throws {
        let defaults = Self.makeDefaults("noAccount.\(kind)")
        try Self.plant(kind, defaults)
        let provider = FakeCloudIdentityProvider(status: .noAccount)
        let eraser = EraserSpy()
        let auth = Self.makeAuth(provider, defaults: defaults, eraser: eraser)

        await auth.restoreSession()

        #expect(auth.state == .needsICloud(.noAccount))
        #expect(eraser.count == 0)
        #expect((auth.loadCachedIdentity() != nil) == (kind != .none), "the cache must survive")
        #expect(provider.recordNameCalls == 0)
    }

    @Test("restricted iCloud explains and wipes nothing", arguments: CacheKind.allCases)
    func restricted(_ kind: CacheKind) async throws {
        let defaults = Self.makeDefaults("restricted.\(kind)")
        try Self.plant(kind, defaults)
        let provider = FakeCloudIdentityProvider(status: .restricted)
        let eraser = EraserSpy()
        let auth = Self.makeAuth(provider, defaults: defaults, eraser: eraser)

        await auth.restoreSession()

        #expect(auth.state == .needsICloud(.restricted))
        #expect(eraser.count == 0)
        #expect((auth.loadCachedIdentity() != nil) == (kind != .none))
    }

    @Test("unverified iCloud enters from any cache as-is, unverified; with none, offers Retry",
          arguments: CacheKind.allCases)
    func unverified(_ kind: CacheKind) async throws {
        let defaults = Self.makeDefaults("unverified.\(kind)")
        try Self.plant(kind, defaults)
        let provider = FakeCloudIdentityProvider(status: .unverified)
        let eraser = EraserSpy()
        let tokenStore = InMemoryTokenStore("tok_legacy")
        let auth = Self.makeAuth(provider, defaults: defaults, tokenStore: tokenStore, eraser: eraser)

        await auth.restoreSession()

        switch kind {
        case .iCloud:
            #expect(Self.signedIn(auth)?.user == Self.userA)
            #expect(!auth.isIdentityVerified)
        case .legacy:
            #expect(Self.signedIn(auth)?.user == "u_server", "no rebind without a confirmed account")
            #expect(!auth.isIdentityVerified)
            #expect(defaults.data(forKey: AuthController.legacyIdentityCacheKey) != nil)
            #expect(tokenStore.load() == "tok_legacy")
        case .none:
            #expect(auth.state == .needsICloud(.couldNotVerify))
        }
        #expect(eraser.count == 0)
        #expect(provider.listCalls.isEmpty)
    }

    @Test("a failed record-name fetch follows the unverified rule")
    func recordNameFetchThrows() async throws {
        let cachedDefaults = Self.makeDefaults("recordNameThrows.cached")
        try Self.cacheICloud(cachedDefaults, userID: Self.userA, householdID: "hh_a")
        let provider = FakeCloudIdentityProvider(recordName: nil)
        let eraser = EraserSpy()
        let cachedAuth = Self.makeAuth(provider, defaults: cachedDefaults, eraser: eraser)
        await cachedAuth.restoreSession()
        #expect(Self.signedIn(cachedAuth)?.household == "hh_a")
        #expect(!cachedAuth.isIdentityVerified)

        let emptyDefaults = Self.makeDefaults("recordNameThrows.empty")
        let emptyAuth = Self.makeAuth(provider, defaults: emptyDefaults, eraser: eraser)
        await emptyAuth.restoreSession()
        #expect(emptyAuth.state == .needsICloud(.couldNotVerify))
        #expect(eraser.count == 0)
        #expect(provider.listCalls.isEmpty)
    }

    @Test("an unverified entry becomes verified on the next resolution for the same user")
    func unverifiedThenVerified() async throws {
        let defaults = Self.makeDefaults("unverifiedThenVerified")
        try Self.cacheICloud(defaults, userID: Self.userA, householdID: "hh_a")
        let provider = FakeCloudIdentityProvider(status: .unverified)
        let auth = Self.makeAuth(provider, defaults: defaults)

        await auth.restoreSession()
        #expect(Self.signedIn(auth) != nil)
        #expect(auth.isIdentityVerified == false)

        provider.status = .available
        await auth.restoreSession()
        #expect(Self.signedIn(auth)?.household == "hh_a")
        #expect(auth.isIdentityVerified == true)
    }

    // MARK: - Legacy rebind

    @Test("legacy owner: the garden zone is found and rebound in place, no wipe")
    func legacyOwnerRebind() async throws {
        let defaults = Self.makeDefaults("legacyOwner")
        try Self.cacheLegacy(defaults, userID: "u_server", householdID: "hh_h")
        let provider = FakeCloudIdentityProvider(owned: [Self.zone("hh_h")])
        let tokenStore = InMemoryTokenStore("tok_legacy")
        let eraser = EraserSpy()
        let auth = Self.makeAuth(provider, defaults: defaults, tokenStore: tokenStore, eraser: eraser)

        await auth.restoreSession()

        #expect(Self.signedIn(auth)?.user == Self.userA, "user.id becomes the iCloud record name")
        #expect(Self.signedIn(auth)?.household == "hh_h", "the household ID is kept")
        #expect(auth.isIdentityVerified)
        #expect(eraser.count == 0)
        #expect(defaults.data(forKey: AuthController.legacyIdentityCacheKey) == nil)
        #expect(Self.cached(defaults, AuthController.identityCacheKey)?.household.id == "hh_h")
        #expect(Self.cached(defaults, AuthController.identityCacheKey)?.household.name == "My household")
        #expect(tokenStore.load() == nil, "the server bearer token goes once the rebind lands")
    }

    @Test("legacy participant: the recorded shared zone is found and rebound, marker kept")
    func legacyParticipantRebind() async throws {
        let defaults = Self.makeDefaults("legacyParticipant")
        try Self.cacheLegacy(defaults, userID: "u_server", householdID: "hh_h")
        let sharedZone = Self.zone("hh_owner", .shared)
        ActiveGardenContext.recordParticipant(zoneName: sharedZone.zoneName, ownerName: sharedZone.ownerName,
                                              in: defaults)
        let provider = FakeCloudIdentityProvider(owned: nil, shared: [sharedZone])
        let eraser = EraserSpy()
        let auth = Self.makeAuth(provider, defaults: defaults, eraser: eraser)

        await auth.restoreSession()

        #expect(Self.signedIn(auth)?.household == "hh_h", "the own household stays; the marker scopes the garden")
        #expect(ActiveGardenContext.participant(in: defaults)?.zoneName == sharedZone.zoneName)
        #expect(provider.listCalls == [.shared])
        #expect(eraser.count == 0)
        #expect(defaults.data(forKey: AuthController.legacyIdentityCacheKey) == nil)
    }

    @Test("legacy: a listing failure enters as-is and the rebind retries on the next resolution")
    func legacyListingThrows() async throws {
        let defaults = Self.makeDefaults("legacyListingThrows")
        try Self.cacheLegacy(defaults, userID: "u_server", householdID: "hh_h")
        let provider = FakeCloudIdentityProvider(owned: nil)
        let tokenStore = InMemoryTokenStore("tok_legacy")
        let eraser = EraserSpy()
        let auth = Self.makeAuth(provider, defaults: defaults, tokenStore: tokenStore, eraser: eraser)

        await auth.restoreSession()

        #expect(Self.signedIn(auth)?.user == "u_server")
        #expect(Self.signedIn(auth)?.household == "hh_h")
        #expect(!auth.isIdentityVerified, "CloudKit waits until the garden is confirmed")
        #expect(defaults.data(forKey: AuthController.legacyIdentityCacheKey) != nil)
        #expect(defaults.data(forKey: AuthController.identityCacheKey) == nil)
        #expect(tokenStore.load() == "tok_legacy")

        provider.owned = [Self.zone("hh_h")]
        await auth.restoreSession()

        #expect(Self.signedIn(auth)?.user == Self.userA)
        #expect(auth.isIdentityVerified)
        #expect(tokenStore.load() == nil)
        #expect(eraser.count == 0)
    }

    @Test("legacy: not found and nothing else in the account rebinds and keeps the device's data")
    func legacyNotFoundNoCandidates() async throws {
        let defaults = Self.makeDefaults("legacyNoCandidates")
        try Self.cacheLegacy(defaults, userID: "u_server", householdID: "hh_h")
        let provider = FakeCloudIdentityProvider(owned: [], shared: [])
        let eraser = EraserSpy()
        let auth = Self.makeAuth(provider, defaults: defaults, eraser: eraser)

        await auth.restoreSession()

        #expect(Self.signedIn(auth)?.household == "hh_h")
        #expect(Self.signedIn(auth)?.user == Self.userA)
        #expect(eraser.count == 0)
        #expect(provider.listCalls == [.owned, .shared])
    }

    @Test("legacy: not found while other gardens exist asks; keeping the device garden never wipes")
    func legacyNotFoundKeep() async throws {
        let defaults = Self.makeDefaults("legacyKeep")
        try Self.cacheLegacy(defaults, userID: "u_server", householdID: "hh_h")
        let provider = FakeCloudIdentityProvider(owned: [Self.zone("hh_other")], shared: [Self.zone("hh_s", .shared)])
        let tokenStore = InMemoryTokenStore("tok_legacy")
        let eraser = EraserSpy()
        let auth = Self.makeAuth(provider, defaults: defaults, tokenStore: tokenStore, eraser: eraser)

        await auth.restoreSession()

        guard case .choosingGarden(let choice) = auth.state else {
            Issue.record("expected the chooser, got \(auth.state)")
            return
        }
        #expect(choice.reason == .deviceGardenNotFound(householdID: "hh_h"))
        #expect(Set(choice.candidates.map(\.householdID)) == ["hh_other", "hh_s"])
        #expect(choice.ownGarden == nil)
        #expect(choice.canKeepDeviceGarden)
        #expect(tokenStore.load() == "tok_legacy", "nothing is rebound until the user decides")

        await auth.keepDeviceGarden()

        #expect(Self.signedIn(auth)?.household == "hh_h")
        #expect(Self.signedIn(auth)?.user == Self.userA)
        #expect(eraser.count == 0)
        #expect(defaults.data(forKey: AuthController.legacyIdentityCacheKey) == nil)
        #expect(tokenStore.load() == nil)
    }

    @Test("legacy: choosing another garden after confirmation wipes exactly once")
    func legacyNotFoundChooseDiscards() async throws {
        let defaults = Self.makeDefaults("legacyChoose")
        try Self.cacheLegacy(defaults, userID: "u_server", householdID: "hh_h")
        let other = Self.zone("hh_other")
        let provider = FakeCloudIdentityProvider(owned: [other], shared: [])
        let eraser = EraserSpy()
        let auth = Self.makeAuth(provider, defaults: defaults, eraser: eraser)
        await auth.restoreSession()
        guard case .choosingGarden(let choice) = auth.state else {
            Issue.record("expected the chooser, got \(auth.state)")
            return
        }
        #expect(AuthController.choiceDiscardsDeviceData(choice, other))

        await auth.chooseGarden(other, discardingDeviceData: true)

        #expect(eraser.switchCount == 1, "a chooser discard uses the garden-switch eraser")
        #expect(eraser.count == 0, "the same iCloud user keeps device-only data")
        #expect(Self.signedIn(auth)?.household == "hh_other")
        #expect(Self.signedIn(auth)?.user == Self.userA)
        #expect(defaults.data(forKey: AuthController.legacyIdentityCacheKey) == nil)
    }

    @Test("crash mid-rebind: the iCloud cache wins, the legacy key goes, nothing is wiped")
    func crashMidRebind() async throws {
        let defaults = Self.makeDefaults("crashMidRebind")
        try Self.cacheLegacy(defaults, userID: "u_server", householdID: "hh_h")
        try Self.cacheICloud(defaults, userID: Self.userA, householdID: "hh_h")
        let provider = FakeCloudIdentityProvider(owned: nil, shared: nil)
        let tokenStore = InMemoryTokenStore("tok_legacy")
        let eraser = EraserSpy()
        let auth = Self.makeAuth(provider, defaults: defaults, tokenStore: tokenStore, eraser: eraser)

        await auth.restoreSession()

        #expect(Self.signedIn(auth)?.user == Self.userA)
        #expect(Self.signedIn(auth)?.household == "hh_h")
        #expect(defaults.data(forKey: AuthController.legacyIdentityCacheKey) == nil)
        #expect(tokenStore.load() == nil)
        #expect(eraser.count == 0)
        #expect(provider.listCalls.isEmpty)
    }

    @Test("the bearer token is cleared only after the rebind, never while it is pending")
    func tokenClearedOnlyAfterRebind() async throws {
        let defaults = Self.makeDefaults("tokenAfterRebind")
        try Self.cacheLegacy(defaults, userID: "u_server", householdID: "hh_h")
        let provider = FakeCloudIdentityProvider(owned: [Self.zone("hh_h")])
        let tokenStore = InMemoryTokenStore("tok_legacy")
        let auth = Self.makeAuth(provider, defaults: defaults, tokenStore: tokenStore)

        provider.holdNextListing()
        let pass = Task { await auth.restoreSession() }
        await provider.waitUntilListingIsHeld()
        #expect(tokenStore.load() == "tok_legacy")
        #expect(defaults.data(forKey: AuthController.identityCacheKey) == nil)
        provider.releaseListing()
        await pass.value

        #expect(Self.signedIn(auth)?.user == Self.userA)
        #expect(tokenStore.load() == nil)
    }

    // MARK: - Fresh device

    @Test("no cache, one shared garden: the participant marker is written before entering")
    func freshOneShared() async throws {
        let defaults = Self.makeDefaults("freshOneShared")
        let shared = Self.zone("hh_owner", .shared)
        let provider = FakeCloudIdentityProvider(owned: [], shared: [shared])
        let auth = Self.makeAuth(provider, defaults: defaults)

        await auth.restoreSession()

        let marker = ActiveGardenContext.participant(in: defaults)
        #expect(marker?.zoneName == shared.zoneName)
        #expect(marker?.ownerName == shared.ownerName)
        #expect(Self.signedIn(auth)?.household == DeterministicHouseholdID.make(userRecordName: Self.userA),
                "the own household is still the user's own")
    }

    @Test("adopting a different shared garden resets its sync state; keeping the recorded one does not")
    func participantAdoptionHook() async throws {
        // Fresh device: the found shared garden is new to this device, so its engine state resets.
        let freshDefaults = Self.makeDefaults("adoptionHookFresh")
        let shared = Self.zone("hh_owner", .shared)
        let fresh = Self.makeAuth(FakeCloudIdentityProvider(owned: [], shared: [shared]), defaults: freshDefaults)
        var adopted: [String] = []
        fresh.wireParticipantGardenAdopted { zoneName, ownerName in adopted.append("\(ownerName)/\(zoneName)") }
        await fresh.restoreSession()
        #expect(adopted == ["\(shared.ownerName)/\(shared.zoneName)"])
        #expect(ActiveGardenContext.participant(in: freshDefaults)?.zoneName == shared.zoneName)

        // Legacy participant rebind: the recorded garden is kept, cursor and all.
        let legacyDefaults = Self.makeDefaults("adoptionHookLegacy")
        try Self.cacheLegacy(legacyDefaults, userID: "u_server", householdID: "hh_h")
        ActiveGardenContext.recordParticipant(zoneName: shared.zoneName, ownerName: shared.ownerName,
                                              in: legacyDefaults)
        let legacy = Self.makeAuth(FakeCloudIdentityProvider(owned: nil, shared: [shared]), defaults: legacyDefaults)
        var legacyAdopted = 0
        legacy.wireParticipantGardenAdopted { _, _ in legacyAdopted += 1 }
        await legacy.restoreSession()
        #expect(Self.signedIn(legacy)?.household == "hh_h")
        #expect(legacyAdopted == 0)
    }

    @Test("no cache, one owned garden: it is the household, no marker")
    func freshOneOwned() async throws {
        let defaults = Self.makeDefaults("freshOneOwned")
        let provider = FakeCloudIdentityProvider(owned: [Self.zone("hh_o")], shared: [])
        let auth = Self.makeAuth(provider, defaults: defaults)

        await auth.restoreSession()

        guard case .signedIn(let user, let household) = auth.state else {
            Issue.record("expected signedIn, got \(auth.state)")
            return
        }
        #expect(user.id == Self.userA)
        #expect(household.id == "hh_o")
        #expect(household.name == "Garden hh_o")
        #expect(household.updated_at == 5)
        #expect(ActiveGardenContext.participant(in: defaults) == nil)
        #expect(Self.cached(defaults, AuthController.identityCacheKey)?.household.id == "hh_o")
    }

    @Test("no cache, no gardens: the deterministic household, the same for the same user")
    func freshNoZones() async throws {
        let provider = FakeCloudIdentityProvider(owned: [], shared: [])
        let first = Self.makeAuth(provider, defaults: Self.makeDefaults("freshNoZones.1"))
        let second = Self.makeAuth(provider, defaults: Self.makeDefaults("freshNoZones.2"))

        await first.restoreSession()
        await second.restoreSession()

        guard case .signedIn(_, let household) = first.state else {
            Issue.record("expected signedIn, got \(first.state)")
            return
        }
        #expect(household.id == DeterministicHouseholdID.make(userRecordName: Self.userA))
        #expect(household.name == "My garden")
        #expect(Self.signedIn(second)?.household == household.id,
                "two devices bootstrapping at once must converge on one zone")
    }

    @Test("no cache, several owned gardens: the user chooses, then the shared step runs")
    func freshSeveralOwned() async throws {
        let defaults = Self.makeDefaults("freshSeveralOwned")
        let a = Self.zone("hh_1"), b = Self.zone("hh_2")
        let provider = FakeCloudIdentityProvider(owned: [a, b], shared: [])
        let eraser = EraserSpy()
        let auth = Self.makeAuth(provider, defaults: defaults, eraser: eraser)

        await auth.restoreSession()

        guard case .choosingGarden(let choice) = auth.state else {
            Issue.record("expected the chooser, got \(auth.state)")
            return
        }
        #expect(choice.reason == .multipleOwnGardens)
        #expect(choice.candidates == [a, b])
        #expect(choice.ownGarden == nil)
        #expect(!AuthController.choiceDiscardsDeviceData(choice, b))

        await auth.chooseGarden(b, discardingDeviceData: false)

        #expect(Self.signedIn(auth)?.household == "hh_2")
        #expect(eraser.count == 0)
    }

    @Test("no cache, several shared gardens: the chooser offers them and the own garden")
    func freshSeveralShared() async throws {
        let defaults = Self.makeDefaults("freshSeveralShared")
        let s1 = Self.zone("hh_s1", .shared), s2 = Self.zone("hh_s2", .shared)
        let provider = FakeCloudIdentityProvider(owned: [], shared: [s1, s2])
        let auth = Self.makeAuth(provider, defaults: defaults)

        await auth.restoreSession()

        guard case .choosingGarden(let choice) = auth.state else {
            Issue.record("expected the chooser, got \(auth.state)")
            return
        }
        #expect(choice.reason == .multipleSharedGardens)
        #expect(choice.candidates == [s1, s2])
        let own = try #require(choice.ownGarden)
        #expect(own.householdID == DeterministicHouseholdID.make(userRecordName: Self.userA))

        await auth.chooseGarden(own, discardingDeviceData: false)
        #expect(Self.signedIn(auth)?.household == own.householdID)
        #expect(ActiveGardenContext.participant(in: defaults) == nil)
    }

    @Test("several shared gardens with one owned: a shared choice keeps that owned household")
    func sharedChoiceKeepsOwnedHousehold() async throws {
        let defaults = Self.makeDefaults("sharedChoiceKeepsOwned")
        let owned = Self.zone("hh_mine")
        let s1 = Self.zone("hh_s1", .shared), s2 = Self.zone("hh_s2", .shared)
        let provider = FakeCloudIdentityProvider(owned: [owned], shared: [s1, s2])
        let auth = Self.makeAuth(provider, defaults: defaults)

        await auth.restoreSession()
        guard case .choosingGarden(let choice) = auth.state else {
            Issue.record("expected the chooser, got \(auth.state)")
            return
        }
        #expect(choice.ownGarden == owned)

        await auth.chooseGarden(s2, discardingDeviceData: false)

        #expect(Self.signedIn(auth)?.household == "hh_mine", "not the deterministic household")
        #expect(ActiveGardenContext.participant(in: defaults)?.zoneName == s2.zoneName)
        #expect(Self.cached(defaults, AuthController.identityCacheKey)?.household.id == "hh_mine")
    }

    @Test("no cache and a failed listing: couldNotVerify, nothing minted or cached")
    func freshListingThrows() async throws {
        let cases: [(owned: [GardenZoneSummary]?, shared: [GardenZoneSummary]?)] = [(nil, []), ([], nil)]
        for (index, listing) in cases.enumerated() {
            let defaults = Self.makeDefaults("freshListingThrows.\(index)")
            let provider = FakeCloudIdentityProvider(owned: listing.owned, shared: listing.shared)
            let auth = Self.makeAuth(provider, defaults: defaults)

            await auth.restoreSession()

            #expect(auth.state == .needsICloud(.couldNotVerify))
            #expect(defaults.data(forKey: AuthController.identityCacheKey) == nil)
            #expect(ActiveGardenContext.participant(in: defaults) == nil)
        }
    }

    // MARK: - Shared garden gone

    @Test("a shared garden no longer shared: choosing the own garden wipes once and clears the marker")
    func sharedGardenUnavailable() async throws {
        let defaults = Self.makeDefaults("sharedUnavailable")
        try Self.cacheLegacy(defaults, userID: "u_server", householdID: "hh_h")
        ActiveGardenContext.recordParticipant(zoneName: "seedkeep-hh_gone", ownerName: "_owner_gone", in: defaults)
        let other = Self.zone("hh_other_shared", .shared)
        let provider = FakeCloudIdentityProvider(owned: [Self.zone("hh_h")], shared: [other])
        let eraser = EraserSpy()
        let auth = Self.makeAuth(provider, defaults: defaults, eraser: eraser)

        await auth.restoreSession()

        guard case .choosingGarden(let choice) = auth.state else {
            Issue.record("expected the chooser, got \(auth.state)")
            return
        }
        #expect(choice.reason == .sharedGardenUnavailable(zoneName: "seedkeep-hh_gone"))
        #expect(choice.candidates == [other])
        #expect(choice.ownGarden?.householdID == "hh_h")
        #expect(!choice.canKeepDeviceGarden)
        #expect(eraser.count == 0 && eraser.switchCount == 0, "nothing is removed before the user confirms")
        let own = try #require(choice.ownGarden)
        #expect(AuthController.choiceDiscardsDeviceData(choice, own))

        await auth.chooseGarden(own, discardingDeviceData: true)

        #expect(eraser.switchCount == 1)
        #expect(eraser.count == 0)
        #expect(ActiveGardenContext.participant(in: defaults) == nil)
        #expect(Self.signedIn(auth)?.household == "hh_h")
        #expect(Self.signedIn(auth)?.user == Self.userA)
    }

    // MARK: - Concurrency

    @Test("two concurrent restores share one pass: one listing")
    func singleFlight() async throws {
        let defaults = Self.makeDefaults("singleFlight")
        let provider = FakeCloudIdentityProvider(owned: [Self.zone("hh_o")], shared: [])
        let auth = Self.makeAuth(provider, defaults: defaults)

        provider.holdNextListing()
        let first = Task { await auth.restoreSession() }
        await provider.waitUntilListingIsHeld()
        let second = Task { await auth.restoreSession() }
        await Task.yield()
        provider.releaseListing()
        await first.value
        await second.value

        #expect(provider.listCalls.filter { $0 == .shared }.count == 1)
        #expect(provider.recordNameCalls == 1)
        #expect(Self.signedIn(auth)?.household == "hh_o")
    }

    @Test("a pass suspended in listing while revalidation binds another user publishes nothing")
    func staleListingPublishesNothing() async throws {
        let defaults = Self.makeDefaults("staleListing")
        let provider = FakeCloudIdentityProvider(recordName: Self.userA, owned: [], shared: [])
        let eraser = EraserSpy()
        let auth = Self.makeAuth(provider, defaults: defaults, eraser: eraser)

        provider.holdNextListing()
        let stale = Task { await auth.restoreSession() }
        await provider.waitUntilListingIsHeld()

        provider.recordName = Self.userB
        await auth.revalidateAfterAccountChange()
        let bHousehold = DeterministicHouseholdID.make(userRecordName: Self.userB)
        #expect(Self.signedIn(auth)?.household == bHousehold)

        provider.releaseListing()
        await stale.value

        #expect(Self.signedIn(auth)?.user == Self.userB, "the stale pass for A must not publish")
        #expect(Self.signedIn(auth)?.household == bHousehold)
        #expect(Self.cached(defaults, AuthController.identityCacheKey)?.user.id == Self.userB)
        #expect(eraser.count == 0)
    }

    @Test("a pass suspended before a different-user wipe never wipes once it is stale")
    func staleRecordNameNeverWipes() async throws {
        let defaults = Self.makeDefaults("staleRecordName")
        try Self.cacheICloud(defaults, userID: Self.userA, householdID: "hh_a")
        let provider = FakeCloudIdentityProvider(recordName: Self.userA)
        let eraser = EraserSpy()
        let auth = Self.makeAuth(provider, defaults: defaults, eraser: eraser)

        provider.holdNextRecordNameFetch()
        let stale = Task { await auth.restoreSession() }
        await provider.waitUntilRecordNameFetchIsHeld()

        await auth.revalidateAfterAccountChange()
        #expect(Self.signedIn(auth)?.household == "hh_a")

        // The suspended fetch now answers with another user; its pass is stale.
        provider.recordName = Self.userB
        provider.releaseRecordNameFetch()
        await stale.value

        #expect(eraser.count == 0)
        #expect(Self.signedIn(auth)?.user == Self.userA)
        #expect(Self.cached(defaults, AuthController.identityCacheKey)?.user.id == Self.userA)
    }

    // MARK: - Failing eraser

    @Test("a failed wipe binds nothing and keeps the caches; Retry then succeeds")
    func eraserThrows() async throws {
        let defaults = Self.makeDefaults("eraserThrows")
        try Self.cacheICloud(defaults, userID: Self.userA, householdID: "hh_a")
        let provider = FakeCloudIdentityProvider(recordName: Self.userB, owned: [Self.zone("hh_b")])
        let eraser = EraserSpy()
        eraser.failing = true
        let auth = Self.makeAuth(provider, defaults: defaults, eraser: eraser)

        await auth.restoreSession()

        guard case .failed = auth.state else {
            Issue.record("expected failed, got \(auth.state)")
            return
        }
        #expect(Self.cached(defaults, AuthController.identityCacheKey)?.user.id == Self.userA,
                "the cache still records who owns the store")
        #expect(provider.listCalls.isEmpty, "no binding after a failed wipe")

        eraser.failing = false
        await auth.retry()

        #expect(eraser.count == 1)
        #expect(Self.signedIn(auth)?.user == Self.userB)
        #expect(Self.signedIn(auth)?.household == "hh_b")
    }

    // MARK: - Account change

    @Test("revalidation for the same user changes nothing")
    func revalidateSameUser() async throws {
        let defaults = Self.makeDefaults("revalidateSame")
        try Self.cacheICloud(defaults, userID: Self.userA, householdID: "hh_a")
        let provider = FakeCloudIdentityProvider(recordName: Self.userA)
        let eraser = EraserSpy()
        let auth = Self.makeAuth(provider, defaults: defaults, eraser: eraser)
        await auth.restoreSession()
        let before = auth.state

        await auth.revalidateAfterAccountChange()

        #expect(auth.state == before)
        #expect(eraser.count == 0)
        #expect(provider.listCalls.isEmpty)
    }

    @Test("revalidation for a different user wipes and resolves fresh")
    func revalidateDifferentUser() async throws {
        let defaults = Self.makeDefaults("revalidateDifferent")
        try Self.cacheICloud(defaults, userID: Self.userA, householdID: "hh_a")
        let provider = FakeCloudIdentityProvider(recordName: Self.userA, owned: [Self.zone("hh_b")])
        let eraser = EraserSpy()
        let auth = Self.makeAuth(provider, defaults: defaults, eraser: eraser)
        await auth.restoreSession()

        provider.recordName = Self.userB
        await auth.revalidateAfterAccountChange()

        #expect(eraser.count == 1)
        #expect(Self.signedIn(auth)?.user == Self.userB)
        #expect(Self.signedIn(auth)?.household == "hh_b")
    }

    @Test("revalidation with no account asks for iCloud and wipes nothing")
    func revalidateNoAccount() async throws {
        let defaults = Self.makeDefaults("revalidateNoAccount")
        try Self.cacheICloud(defaults, userID: Self.userA, householdID: "hh_a")
        let provider = FakeCloudIdentityProvider(recordName: Self.userA)
        let eraser = EraserSpy()
        let auth = Self.makeAuth(provider, defaults: defaults, eraser: eraser)
        await auth.restoreSession()

        provider.status = .noAccount
        await auth.revalidateAfterAccountChange()

        #expect(auth.state == .needsICloud(.noAccount))
        #expect(eraser.count == 0)
        #expect(Self.cached(defaults, AuthController.identityCacheKey)?.user.id == Self.userA)

        // Signing back in to the same account re-enters without a wipe.
        provider.status = .available
        await auth.retry()
        #expect(Self.signedIn(auth)?.household == "hh_a")
        #expect(eraser.count == 0)
    }

    // MARK: - Sign-out and adoption seams

    @Test("signOut runs the eraser and clears token, caches and marker")
    func signOutWipes() async throws {
        let defaults = Self.makeDefaults("signOutWipe")
        try Self.cacheICloud(defaults, userID: Self.userA, householdID: "hh_a")
        try Self.cacheLegacy(defaults, userID: "u_server", householdID: "hh_a")
        ActiveGardenContext.recordParticipant(zoneName: "seedkeep-hh_x", ownerName: "_x", in: defaults)
        let tokenStore = InMemoryTokenStore("tok_alive")
        let eraser = EraserSpy()
        let auth = Self.makeAuth(FakeCloudIdentityProvider(), defaults: defaults,
                                 tokenStore: tokenStore, eraser: eraser)

        await auth.signOut()

        #expect(eraser.count == 1, "sign-out must wipe the local store")
        #expect(tokenStore.load() == nil)
        #expect(auth.loadCachedIdentity() == nil)
        #expect(ActiveGardenContext.participant(in: defaults) == nil)
        #expect(auth.state == .signedOut)
    }

    @Test("adoptHousehold moves state and the cache together; a later restore does not wipe")
    func adoptHouseholdThenRestore() async throws {
        let defaults = Self.makeDefaults("adoptHousehold")
        try Self.cacheICloud(defaults, userID: Self.userA, householdID: "hh_own")
        let provider = FakeCloudIdentityProvider(recordName: Self.userA)
        let eraser = EraserSpy()
        let auth = Self.makeAuth(provider, defaults: defaults, eraser: eraser)
        await auth.restoreSession()

        let transferred = try JSONDecoder().decode(
            HouseholdDTO.self,
            from: Data(#"{"id":"hh_transferred","name":"Transferred garden","created_at":1,"updated_at":1}"#.utf8))
        auth.adoptHousehold(transferred)

        #expect(Self.signedIn(auth)?.user == Self.userA, "adopting a household must not change WHO is signed in")
        #expect(Self.signedIn(auth)?.household == "hh_transferred")
        #expect(auth.loadCachedIdentity()?.household.id == "hh_transferred")

        await auth.restoreSession()
        #expect(eraser.count == 0)
        #expect(Self.signedIn(auth)?.household == "hh_transferred")
    }

    @Test("adoptHousehold on an unrebound legacy identity keeps it legacy, so it never reads as a switch")
    func adoptHouseholdKeepsLegacy() async throws {
        let defaults = Self.makeDefaults("adoptHouseholdLegacy")
        try Self.cacheLegacy(defaults, userID: "u_server", householdID: "hh_own")
        let provider = FakeCloudIdentityProvider(status: .unverified)
        let auth = Self.makeAuth(provider, defaults: defaults)
        await auth.restoreSession()

        let transferred = try JSONDecoder().decode(
            HouseholdDTO.self,
            from: Data(#"{"id":"hh_t","name":"T","created_at":1,"updated_at":1}"#.utf8))
        auth.adoptHousehold(transferred)

        #expect(defaults.data(forKey: AuthController.identityCacheKey) == nil)
        #expect(Self.cached(defaults, AuthController.legacyIdentityCacheKey)?.household.id == "hh_t")
    }

    @Test("adoptHousehold is a no-op when nobody is signed in")
    func adoptHouseholdNoOpWhenSignedOut() throws {
        let defaults = Self.makeDefaults("adoptHouseholdSignedOut")
        let auth = Self.makeAuth(FakeCloudIdentityProvider(), defaults: defaults)

        let household = try JSONDecoder().decode(
            HouseholdDTO.self,
            from: Data(#"{"id":"hh_x","name":"X","created_at":1,"updated_at":1}"#.utf8))
        auth.adoptHousehold(household)

        #expect(auth.state == .signedOut)
        #expect(auth.loadCachedIdentity() == nil)
    }

    // MARK: - Review fixes (F2, F4, F10, F11, F12, F14)

    /// Legacy device garden `hh_h` not found, with another owned and a shared garden in iCloud.
    private static func deviceGardenNotFoundChooser(
        _ name: String, eraser: EraserSpy
    ) async throws -> (AuthController, UserDefaults, GardenChoice) {
        let defaults = makeDefaults(name)
        try cacheLegacy(defaults, userID: "u_server", householdID: "hh_h")
        let provider = FakeCloudIdentityProvider(owned: [zone("hh_other")], shared: [zone("hh_s", .shared)])
        let auth = makeAuth(provider, defaults: defaults, eraser: eraser)
        await auth.restoreSession()
        guard case .choosingGarden(let choice) = auth.state else {
            throw ChooserMissing(state: auth.state)
        }
        return (auth, defaults, choice)
    }

    struct ChooserMissing: Error { let state: AuthController.State }

    @Test("a chooser discard whose eraser throws fails, binds nothing and keeps the caches")
    func chooserDiscardEraserThrows() async throws {
        let eraser = EraserSpy()
        eraser.switchFailing = true
        let (auth, defaults, choice) = try await Self.deviceGardenNotFoundChooser("discardThrows", eraser: eraser)
        let other = try #require(choice.candidates.first { $0.householdID == "hh_other" })

        await auth.chooseGarden(other, discardingDeviceData: true)

        guard case .failed = auth.state else {
            Issue.record("expected failed, got \(auth.state)")
            return
        }
        #expect(Self.cached(defaults, AuthController.legacyIdentityCacheKey)?.household.id == "hh_h",
                "the cache still records whose garden is on disk")
        #expect(defaults.data(forKey: AuthController.identityCacheKey) == nil)
        #expect(ActiveGardenContext.participant(in: defaults) == nil)
        #expect(eraser.count == 0)
    }

    @Test("a chooser choice superseded mid-erase publishes nothing")
    func staleChooseGardenPublishesNothing() async throws {
        let eraser = EraserSpy()
        let (auth, defaults, choice) = try await Self.deviceGardenNotFoundChooser("staleChoose", eraser: eraser)
        let other = try #require(choice.candidates.first { $0.householdID == "hh_other" })

        eraser.holdNextSwitch()
        let choosing = Task { await auth.chooseGarden(other, discardingDeviceData: true) }
        await eraser.waitUntilSwitchIsHeld()
        await auth.retry()   // a newer transition: the chooser is offered again
        eraser.releaseSwitch()
        await choosing.value

        guard case .choosingGarden = auth.state else {
            Issue.record("expected the chooser, got \(auth.state)")
            return
        }
        #expect(defaults.data(forKey: AuthController.identityCacheKey) == nil, "nothing bound")
        #expect(defaults.data(forKey: AuthController.legacyIdentityCacheKey) != nil)
    }

    @Test("chooseGarden refuses a discarding choice that was not confirmed")
    func chooseGardenRefusesUnconfirmedDiscard() async throws {
        let eraser = EraserSpy()
        let (auth, defaults, choice) = try await Self.deviceGardenNotFoundChooser("refuseDiscard", eraser: eraser)
        let other = try #require(choice.candidates.first { $0.householdID == "hh_other" })

        await auth.chooseGarden(other, discardingDeviceData: false)

        #expect(auth.state == .choosingGarden(choice))
        #expect(eraser.switchCount == 0)
        #expect(defaults.data(forKey: AuthController.identityCacheKey) == nil)
    }

    @Test("deviceGardenNotFound: choosing a shared garden discards once and records it")
    func deviceGardenNotFoundChooseShared() async throws {
        let eraser = EraserSpy()
        let (auth, defaults, choice) = try await Self.deviceGardenNotFoundChooser("notFoundShared", eraser: eraser)
        let shared = try #require(choice.candidates.first { $0.scope == .shared })

        await auth.chooseGarden(shared, discardingDeviceData: true)

        #expect(eraser.switchCount == 1)
        #expect(eraser.count == 0)
        #expect(Self.signedIn(auth)?.user == Self.userA)
        #expect(Self.signedIn(auth)?.household == "hh_h", "the own household stays the device's")
        #expect(ActiveGardenContext.participant(in: defaults)?.zoneName == shared.zoneName)
        #expect(defaults.data(forKey: AuthController.legacyIdentityCacheKey) == nil)
    }

    @Test("sharedGardenUnavailable: choosing another shared garden discards once and switches the marker")
    func sharedGardenUnavailableChooseOtherShared() async throws {
        let defaults = Self.makeDefaults("sharedUnavailableOther")
        try Self.cacheLegacy(defaults, userID: "u_server", householdID: "hh_h")
        ActiveGardenContext.recordParticipant(zoneName: "seedkeep-hh_gone", ownerName: "_owner_gone", in: defaults)
        let other = Self.zone("hh_other_shared", .shared)
        let provider = FakeCloudIdentityProvider(owned: [Self.zone("hh_h")], shared: [other])
        let eraser = EraserSpy()
        let auth = Self.makeAuth(provider, defaults: defaults, eraser: eraser)
        var adopted: [String] = []
        auth.wireParticipantGardenAdopted { zoneName, _ in adopted.append(zoneName) }
        await auth.restoreSession()

        await auth.chooseGarden(other, discardingDeviceData: true)

        #expect(eraser.switchCount == 1)
        #expect(eraser.count == 0)
        #expect(adopted == [other.zoneName])
        #expect(ActiveGardenContext.participant(in: defaults)?.zoneName == other.zoneName)
        #expect(Self.signedIn(auth)?.household == "hh_h")
    }

    @Test("several owned gardens, then several shared: a second chooser keeps the chosen own garden")
    func severalOwnedThenSeveralShared() async throws {
        let defaults = Self.makeDefaults("ownedThenShared")
        let a = Self.zone("hh_1"), b = Self.zone("hh_2")
        let s1 = Self.zone("hh_s1", .shared), s2 = Self.zone("hh_s2", .shared)
        let auth = Self.makeAuth(FakeCloudIdentityProvider(owned: [a, b], shared: [s1, s2]), defaults: defaults)
        await auth.restoreSession()

        await auth.chooseGarden(b, discardingDeviceData: false)

        guard case .choosingGarden(let choice) = auth.state else {
            Issue.record("expected a second chooser, got \(auth.state)")
            return
        }
        #expect(choice.reason == .multipleSharedGardens)
        #expect(choice.candidates == [s1, s2])
        #expect(choice.ownGarden == b)

        await auth.chooseGarden(s1, discardingDeviceData: false)
        #expect(Self.signedIn(auth)?.household == "hh_2")
        #expect(ActiveGardenContext.participant(in: defaults)?.zoneName == s1.zoneName)
    }

    @Test("one owned and one shared garden on a fresh device: the user chooses, nothing is joined")
    func freshOwnedAndOneShared() async throws {
        let defaults = Self.makeDefaults("ownedAndShared")
        let owned = Self.zone("hh_mine"), shared = Self.zone("hh_s", .shared)
        let auth = Self.makeAuth(FakeCloudIdentityProvider(owned: [owned], shared: [shared]), defaults: defaults)

        await auth.restoreSession()

        guard case .choosingGarden(let choice) = auth.state else {
            Issue.record("expected the chooser, got \(auth.state)")
            return
        }
        #expect(choice.reason == .sharedOrOwnGarden)
        #expect(choice.candidates == [shared])
        #expect(choice.ownGarden == owned)
        #expect(!AuthController.choiceDiscardsDeviceData(choice, shared))
        #expect(ActiveGardenContext.participant(in: defaults) == nil, "not joined before the user decides")

        await auth.chooseGarden(shared, discardingDeviceData: false)
        #expect(Self.signedIn(auth)?.household == "hh_mine")
        #expect(ActiveGardenContext.participant(in: defaults)?.zoneName == shared.zoneName)
    }

    @Test("a chosen own garden followed by one shared garden asks too")
    func severalOwnedThenOneShared() async throws {
        let defaults = Self.makeDefaults("ownedThenOneShared")
        let a = Self.zone("hh_1"), b = Self.zone("hh_2"), shared = Self.zone("hh_s", .shared)
        let auth = Self.makeAuth(FakeCloudIdentityProvider(owned: [a, b], shared: [shared]), defaults: defaults)
        await auth.restoreSession()

        await auth.chooseGarden(a, discardingDeviceData: false)

        guard case .choosingGarden(let choice) = auth.state else {
            Issue.record("expected the chooser, got \(auth.state)")
            return
        }
        #expect(choice.reason == .sharedOrOwnGarden)
        #expect(choice.ownGarden == a)

        await auth.chooseGarden(a, discardingDeviceData: false)
        #expect(Self.signedIn(auth)?.household == "hh_1")
        #expect(ActiveGardenContext.participant(in: defaults) == nil)
    }

    @Test("a failed shared-garden reset fails the binding: no marker, no cache; Retry then joins")
    func participantAdoptionHookThrows() async throws {
        let defaults = Self.makeDefaults("adoptionHookThrows")
        let shared = Self.zone("hh_owner", .shared)
        let auth = Self.makeAuth(FakeCloudIdentityProvider(owned: [], shared: [shared]), defaults: defaults)
        let hook = EraserSpy()
        hook.failing = true
        auth.wireParticipantGardenAdopted { _, _ in
            if hook.failing { throw EraserSpy.Failed() }
        }

        await auth.restoreSession()

        guard case .failed = auth.state else {
            Issue.record("expected failed, got \(auth.state)")
            return
        }
        #expect(ActiveGardenContext.participant(in: defaults) == nil)
        #expect(defaults.data(forKey: AuthController.identityCacheKey) == nil)

        hook.failing = false
        await auth.retry()
        #expect(ActiveGardenContext.participant(in: defaults)?.zoneName == shared.zoneName)
        #expect(Self.signedIn(auth) != nil)
    }

    @Test("an account change pauses CloudKit before iCloud answers, and resumes for the same user")
    func revalidatePausesImmediately() async throws {
        let defaults = Self.makeDefaults("revalidatePauses")
        try Self.cacheICloud(defaults, userID: Self.userA, householdID: "hh_a")
        let provider = FakeCloudIdentityProvider(recordName: Self.userA)
        let eraser = EraserSpy()
        let auth = Self.makeAuth(provider, defaults: defaults, eraser: eraser)
        await auth.restoreSession()
        #expect(auth.isIdentityVerified)
        let listingsBefore = provider.listCalls.count

        // The observer path: a synchronous pause on the main queue, then the revalidation.
        auth.pauseForAccountChange()
        #expect(!auth.isIdentityVerified, "CloudKit must pause before the observer returns")
        provider.holdNextRecordNameFetch()
        let revalidation = Task { await auth.revalidateAfterAccountChange() }
        await provider.waitUntilRecordNameFetchIsHeld()
        #expect(!auth.isIdentityVerified, "CloudKit must pause before the user is known")

        provider.releaseRecordNameFetch()
        await revalidation.value
        #expect(auth.isIdentityVerified)
        #expect(Self.signedIn(auth)?.household == "hh_a")
        #expect(provider.listCalls.count == listingsBefore, "the same verified user resumes directly")
        #expect(eraser.count == 0)
    }

    @Test("a chooser tap after an account change withdrew the choice resolves again, never silently")
    func withdrawnChoiceReResolves() async throws {
        let eraser = EraserSpy()
        let (auth, defaults, choice) = try await Self.deviceGardenNotFoundChooser("withdrawn", eraser: eraser)
        let other = try #require(choice.candidates.first { $0.householdID == "hh_other" })

        auth.pauseForAccountChange()   // withdraws the pending choice
        await auth.chooseGarden(other, discardingDeviceData: true)

        #expect(eraser.switchCount == 0, "a withdrawn choice discards nothing")
        guard case .choosingGarden(let offered) = auth.state else {
            Issue.record("expected the chooser again, got \(auth.state)")
            return
        }
        #expect(offered == choice)
        #expect(defaults.data(forKey: AuthController.identityCacheKey) == nil)

        await auth.chooseGarden(other, discardingDeviceData: true)   // the fresh choice binds
        #expect(eraser.switchCount == 1)
        #expect(Self.signedIn(auth)?.household == "hh_other")
    }

    @Test("an account change that iCloud cannot verify keeps CloudKit paused until the next resolution")
    func revalidateUnverifiedStaysPaused() async throws {
        let defaults = Self.makeDefaults("revalidateUnverified")
        try Self.cacheICloud(defaults, userID: Self.userA, householdID: "hh_a")
        let provider = FakeCloudIdentityProvider(recordName: Self.userA)
        let auth = Self.makeAuth(provider, defaults: defaults)
        await auth.restoreSession()

        provider.status = .unverified
        await auth.revalidateAfterAccountChange()
        #expect(Self.signedIn(auth)?.household == "hh_a")
        #expect(!auth.isIdentityVerified)

        provider.status = .available
        await auth.restoreSession()
        #expect(auth.isIdentityVerified)
    }

    @Test("restoreSession returns only once a superseding pass has finished too")
    func restoreWaitsThroughSupersedingPass() async throws {
        let defaults = Self.makeDefaults("restoreWaits")
        let provider = FakeCloudIdentityProvider(owned: [Self.zone("hh_o")], shared: [])
        let auth = Self.makeAuth(provider, defaults: defaults)
        @MainActor final class Done { var value = false }
        let waiterDone = Done()

        provider.holdNextListing()
        let first = Task { await auth.restoreSession() }
        await provider.waitUntilListingIsHeld()
        let waiter = Task {
            await auth.restoreSession()
            waiterDone.value = true
        }
        for _ in 0..<5 { await Task.yield() }
        provider.holdNextRecordNameFetch()
        let revalidation = Task { await auth.revalidateAfterAccountChange() }
        await provider.waitUntilRecordNameFetchIsHeld()

        provider.releaseListing()   // the superseded pass ends, publishing nothing
        for _ in 0..<20 { await Task.yield() }
        #expect(!waiterDone.value, "the account-change pass is still in flight")

        provider.releaseRecordNameFetch()
        await revalidation.value
        await first.value
        await waiter.value
        #expect(waiterDone.value)
        #expect(Self.signedIn(auth)?.household == "hh_o")
    }

    // MARK: - Deterministic household

    @Test("spike-check test zones are never gardens; real garden zones are")
    func spikeZonesAreNotGardens() {
        #expect(LiveCloudIdentityProvider.isGardenZoneName("seedkeep-hh_abc123"))
        #expect(LiveCloudIdentityProvider.isGardenZoneName(
            "seedkeep-\(DeterministicHouseholdID.make(userRecordName: Self.userA))"))
        for spike in ["seedkeep-spike-asset-engine", "seedkeep-spike-merge", "seedkeep-spike-roundtrip",
                      "seedkeep-spike-share", "seedkeep-spike-share-handoff"] {
            #expect(!LiveCloudIdentityProvider.isGardenZoneName(spike), "\(spike)")
        }
        #expect(!LiveCloudIdentityProvider.isGardenZoneName("com.apple.coredata.cloudkit.zone"))
    }

    @Test("DeterministicHouseholdID is stable, UUID-shaped and lowercase")
    func deterministicHouseholdID() {
        let id = DeterministicHouseholdID.make(userRecordName: "_abc123")
        #expect(id == DeterministicHouseholdID.make(userRecordName: "_abc123"))
        #expect(id != DeterministicHouseholdID.make(userRecordName: "_abc124"))
        #expect(UUID(uuidString: id) != nil)
        #expect(id == id.lowercased())
        #expect(id.count == 36)
    }
}
