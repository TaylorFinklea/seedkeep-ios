import Testing
import Foundation
import SwiftData
@testable import Seedkeep
import SeedkeepKit

/// Stabilization B3 — identity lifecycle:
///
/// 1. `SyncEngine.eraseAllLocalData` wipes every model generically from
///    `SeedkeepSchema.all` (store + pending-write queue + cursors).
/// 2. Session restore is offline-first: transport/5xx failures with a
///    cached identity enter `.signedIn` and KEEP the keychain token;
///    only a definitive `unauthorized` clears it.
/// 3. Sign-out and sign-in-as-someone-else run the local-data eraser so
///    the next account never sees (or pushes) the prior account's data.
@MainActor
@Suite("Auth lifecycle (Stabilization B3)", .serialized)
struct AuthLifecycleTests {

    private static let householdID = "hh_auth"

    private static func makeContainer(_ name: String) -> ModelContainer {
        makeTestContainer(name: name)
    }

    private static func makeDefaults(_ name: String) -> UserDefaults {
        let suite = "AuthLifecycleTests.\(name)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    // In-memory token store: the real KeychainTokenStore silently loses
    // writes in the unit-test host (no keychain-access-group entitlement on
    // the sim → SecItemAdd returns errSecMissingEntitlement), which made every
    // restore test collapse to .signedOut. Reference type so the controller's
    // own clear()/save() are observable by the test's post-restore assertions.
    private static func makeTokenStore(_ name: String) -> InMemoryTokenStore {
        InMemoryTokenStore()
    }

    private static func makeClient() -> SeedkeepClient {
        let session = AuthMockURLProtocol.makeSession()
        return SeedkeepClient(
            configuration: .init(
                baseURL: URL(string: "https://test.local")!,
                session: session
            )
        )
    }

    private static func stubIdentity(userID: String, householdID: String) {
        AuthMockURLProtocol.setRoute("GET /api/me", Data("""
        {"ok":true,"data":{"user":{"id":"\(userID)","name":"Gardener","email":"g@example.com"}}}
        """.utf8))
        AuthMockURLProtocol.setRoute("POST /api/households", Data("""
        {"ok":true,"data":{"household":{"id":"\(householdID)","name":"My household","created_at":1,"updated_at":1},"role":"owner"}}
        """.utf8))
        // Consistent with the generic route above by default — tests that
        // exercise `resolveHousehold`'s exact-vs-generic branching stub
        // this route separately (or with a deliberately different
        // household/role) after calling `stubIdentity`.
        AuthMockURLProtocol.setRoute("GET /api/households/\(householdID)", Data("""
        {"ok":true,"data":{"household":{"id":"\(householdID)","name":"My household","created_at":1,"updated_at":1},"role":"owner"}}
        """.utf8))
    }

    private static func stubNotAMember(householdID: String) {
        AuthMockURLProtocol.setRoute("GET /api/households/\(householdID)", Data("""
        {"ok":false,"error":{"code":"not_a_member","message":"Not a member of this household."}}
        """.utf8))
    }

    private static func cacheIdentity(
        _ defaults: UserDefaults, userID: String, householdID: String
    ) throws {
        // The DTOs have no public memberwise init — round-trip the same
        // JSON shape `saveCachedIdentity` persists.
        let json = """
        {"user":{"id":"\(userID)","name":"Gardener","email":"g@example.com"},"household":{"id":"\(householdID)","name":"My household","created_at":1,"updated_at":1}}
        """
        // Validate it decodes as a CachedIdentity before planting it.
        _ = try JSONDecoder().decode(AuthController.CachedIdentity.self, from: Data(json.utf8))
        defaults.set(Data(json.utf8), forKey: AuthController.identityCacheKey)
    }

    // MARK: - Generic wipe

    @Test("eraseAllLocalData wipes every model in SeedkeepSchema.all, including queue and cursors")
    func eraseWipesGenerically() async throws {
        let container = Self.makeContainer("authErase")
        let client = Self.makeClient()
        let engine = SyncEngine(client: client, container: container)
        let context = ModelContext(container)
        context.insert(LocalSeed(
            id: "seed_wipe", householdID: Self.householdID, state: .active,
            packetCount: 1, source: .store, createdAt: 1, updatedAt: 1))
        context.insert(LocalPendingWrite(
            id: "pw_wipe", entityType: "seed", entityID: "seed_wipe",
            operation: "update", payloadJSON: "{}", createdAt: 1))
        context.insert(LocalSyncCursor(
            householdID: Self.householdID, kind: "seeds", cursor: 999, lastSyncedAt: 1))
        context.insert(LocalJournalEntry(
            id: "je_wipe", householdID: Self.householdID,
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

    // MARK: - Offline-first restore

    @Test("offline restore with a cached identity enters signedIn and keeps the token")
    func offlineRestoreUsesCache() async throws {
        let defaults = Self.makeDefaults("offlineRestore")
        let tokenStore = Self.makeTokenStore("offlineRestore")
        tokenStore.save("tok_alive")
        try Self.cacheIdentity(defaults, userID: "u1", householdID: "hh1")
        let client = Self.makeClient()
        AuthMockURLProtocol.failAll(with: URLError(.notConnectedToInternet))
        let auth = AuthController(client: client, tokenStore: tokenStore, defaults: defaults)

        await auth.restoreSession()

        guard case .signedIn(let user, let household) = auth.state else {
            Issue.record("expected signedIn from cache, got \(auth.state)")
            return
        }
        #expect(user.id == "u1")
        #expect(household.id == "hh1")
        #expect(tokenStore.load() == "tok_alive", "transport failure must not clear the token")
    }

    @Test("5xx during restore keeps the token and falls back to cache")
    func serverErrorRestoreKeepsToken() async throws {
        let defaults = Self.makeDefaults("serverErrorRestore")
        let tokenStore = Self.makeTokenStore("serverErrorRestore")
        tokenStore.save("tok_alive")
        try Self.cacheIdentity(defaults, userID: "u1", householdID: "hh1")
        let client = Self.makeClient()
        AuthMockURLProtocol.respondAll(status: 503, body: Data(
            #"{"ok":false,"error":{"code":"internal_error","message":"deploying"}}"#.utf8))
        let auth = AuthController(client: client, tokenStore: tokenStore, defaults: defaults)

        await auth.restoreSession()

        if case .signedIn = auth.state {} else {
            Issue.record("expected signedIn from cache, got \(auth.state)")
        }
        #expect(tokenStore.load() == "tok_alive",
                "a mid-deploy 5xx must not destroy the session")
    }

    @Test("unauthorized during restore clears the token but keeps the identity cache")
    func unauthorizedClearsTokenOnly() async throws {
        let defaults = Self.makeDefaults("unauthorizedRestore")
        let tokenStore = Self.makeTokenStore("unauthorizedRestore")
        tokenStore.save("tok_dead")
        try Self.cacheIdentity(defaults, userID: "u1", householdID: "hh1")
        let client = Self.makeClient()
        AuthMockURLProtocol.respondAll(status: 401, body: Data(
            #"{"ok":false,"error":{"code":"unauthorized","message":"Missing authorization token"}}"#.utf8))
        let auth = AuthController(client: client, tokenStore: tokenStore, defaults: defaults)

        await auth.restoreSession()

        guard case .failed(let message) = auth.state else {
            Issue.record("expected failed, got \(auth.state)")
            return
        }
        #expect(tokenStore.load() == nil, "a definitive unauthorized must clear the token")
        #expect(message.contains("Sign in"), "reason must be humanized: \(message)")
        #expect(auth.loadCachedIdentity() != nil,
                "the cache records store ownership — a later different-user sign-in still wipes")
    }

    @Test("offline restore with NO cache fails with a humanized reason and keeps the token")
    func offlineRestoreNoCacheSurfacesReason() async throws {
        let defaults = Self.makeDefaults("offlineNoCache")
        let tokenStore = Self.makeTokenStore("offlineNoCache")
        tokenStore.save("tok_alive")
        let client = Self.makeClient()
        AuthMockURLProtocol.failAll(with: URLError(.notConnectedToInternet))
        let auth = AuthController(client: client, tokenStore: tokenStore, defaults: defaults)

        await auth.restoreSession()

        guard case .failed(let message) = auth.state else {
            Issue.record("expected failed, got \(auth.state)")
            return
        }
        #expect(message == "You're offline. Sync paused until the connection returns.")
        #expect(tokenStore.load() == "tok_alive")
    }

    // MARK: - Wipe triggers

    @Test("signOut runs the eraser and clears token + cache")
    func signOutWipes() async throws {
        let defaults = Self.makeDefaults("signOutWipe")
        let tokenStore = Self.makeTokenStore("signOutWipe")
        tokenStore.save("tok_alive")
        try Self.cacheIdentity(defaults, userID: "u1", householdID: "hh1")
        let client = Self.makeClient()
        let auth = AuthController(client: client, tokenStore: tokenStore, defaults: defaults)

        final class Counter { var count = 0 }
        let eraser = Counter()
        auth.wireLocalDataEraser { eraser.count += 1 }

        await auth.signOut()

        #expect(eraser.count == 1, "sign-out must wipe the local store")
        #expect(tokenStore.load() == nil)
        #expect(auth.loadCachedIdentity() == nil)
        #expect(auth.state == .signedOut)
    }

    @Test("sign-in as a different user wipes before entering signedIn; same user does not")
    func identitySwitchWipes() async throws {
        let defaults = Self.makeDefaults("identitySwitch")
        let tokenStore = Self.makeTokenStore("identitySwitch")
        try Self.cacheIdentity(defaults, userID: "u_old", householdID: "hh_old")
        let client = Self.makeClient()
        Self.stubIdentity(userID: "u_new", householdID: "hh_new")
        let auth = AuthController(client: client, tokenStore: tokenStore, defaults: defaults)

        final class Counter { var count = 0 }
        let eraser = Counter()
        auth.wireLocalDataEraser { eraser.count += 1 }

        await auth.adoptBearerToken("tok_user_b")

        #expect(eraser.count == 1, "different user/household must wipe the prior store")
        guard case .signedIn(let user, let household) = auth.state else {
            Issue.record("expected signedIn, got \(auth.state)")
            return
        }
        #expect(user.id == "u_new")
        #expect(household.id == "hh_new")
        // Cache updated to the new owner — the SAME user signing in
        // again must not wipe.
        await auth.adoptBearerToken("tok_user_b_again")
        #expect(eraser.count == 1, "same identity must not re-wipe")
    }

    @Test("fresh sign-in (adoptBearerToken) does NOT fall back to a stale cache on transport failure")
    func freshSignInNoCacheFallback() async throws {
        let defaults = Self.makeDefaults("freshSignIn")
        let tokenStore = Self.makeTokenStore("freshSignIn")
        try Self.cacheIdentity(defaults, userID: "u_old", householdID: "hh_old")
        let client = Self.makeClient()
        AuthMockURLProtocol.failAll(with: URLError(.timedOut))
        let auth = AuthController(client: client, tokenStore: tokenStore, defaults: defaults)

        await auth.adoptBearerToken("tok_unknown_owner")

        if case .signedIn = auth.state {
            Issue.record("a fresh token of unknown ownership must not adopt the previous user's cache")
        }
    }

    // MARK: - Exact-household adoption (account-deletion successor cutover)

    @Test("adoptHousehold switches state and the cache to the exact household given")
    func adoptHouseholdSwitchesStateAndCache() async throws {
        let defaults = Self.makeDefaults("adoptHousehold")
        let tokenStore = Self.makeTokenStore("adoptHousehold")
        try Self.cacheIdentity(defaults, userID: "u_succ", householdID: "hh_own")
        let client = Self.makeClient()
        Self.stubIdentity(userID: "u_succ", householdID: "hh_own")
        let auth = AuthController(client: client, tokenStore: tokenStore, defaults: defaults)
        await auth.adoptBearerToken("tok_succ")
        guard case .signedIn(let user, _) = auth.state else {
            Issue.record("setup failed to sign in")
            return
        }

        let transferred = try JSONDecoder().decode(
            HouseholdDTO.self,
            from: Data(#"{"id":"hh_transferred","name":"Transferred garden","created_at":1,"updated_at":1}"#.utf8))
        auth.adoptHousehold(transferred)

        guard case .signedIn(let sameUser, let household) = auth.state else {
            Issue.record("expected signedIn, got \(auth.state)")
            return
        }
        #expect(sameUser.id == user.id, "adopting a household must not change WHO is signed in")
        #expect(household.id == "hh_transferred")
        let cached = auth.loadCachedIdentity()
        #expect(cached?.household.id == "hh_transferred",
                "the cache must move together with state — a later restore must see the same household")
        #expect(cached?.user.id == user.id)
    }

    @Test("a later restore that agrees with the adopted household does not wipe it")
    func restoreAfterAdoptionDoesNotWipe() async throws {
        // The bug this defends against: `loadIdentity`'s wipe check
        // compares the SERVER's answer to `loadCachedIdentity()`, not to
        // `state`. If `adoptHousehold` moved `state` to the transferred
        // household but left the CACHE pointing at the old one, then even
        // a later restore that correctly resolves the SAME (transferred)
        // household would look like an identity switch against the stale
        // cache and wipe a garden that is still perfectly valid.
        let defaults = Self.makeDefaults("restoreAfterAdoption")
        let tokenStore = Self.makeTokenStore("restoreAfterAdoption")
        tokenStore.save("tok_succ")
        try Self.cacheIdentity(defaults, userID: "u_succ", householdID: "hh_own")
        let client = Self.makeClient()
        Self.stubIdentity(userID: "u_succ", householdID: "hh_own")
        let auth = AuthController(client: client, tokenStore: tokenStore, defaults: defaults)
        await auth.adoptBearerToken("tok_succ")

        let transferred = try JSONDecoder().decode(
            HouseholdDTO.self,
            from: Data(#"{"id":"hh_transferred","name":"Transferred garden","created_at":1,"updated_at":1}"#.utf8))
        auth.adoptHousehold(transferred)

        final class Counter { var count = 0 }
        let eraser = Counter()
        auth.wireLocalDataEraser { eraser.count += 1 }

        // The server now correctly resolves the SAME household this
        // device just adopted (the realistic post-re-home answer).
        Self.stubIdentity(userID: "u_succ", householdID: "hh_transferred")
        await auth.restoreSession()

        #expect(eraser.count == 0,
                "the cache must already agree with the adopted household — a correct restore must not wipe it")
        guard case .signedIn(_, let household) = auth.state else {
            Issue.record("expected signedIn, got \(auth.state)")
            return
        }
        #expect(household.id == "hh_transferred")
    }

    @Test("adoptHousehold is a no-op when nobody is signed in")
    func adoptHouseholdNoOpWhenSignedOut() throws {
        let defaults = Self.makeDefaults("adoptHouseholdSignedOut")
        let tokenStore = Self.makeTokenStore("adoptHouseholdSignedOut")
        let client = Self.makeClient()
        let auth = AuthController(client: client, tokenStore: tokenStore, defaults: defaults)

        let household = try JSONDecoder().decode(
            HouseholdDTO.self,
            from: Data(#"{"id":"hh_x","name":"X","created_at":1,"updated_at":1}"#.utf8))
        auth.adoptHousehold(household)

        #expect(auth.state == .signedOut)
        #expect(auth.loadCachedIdentity() == nil)
    }

    // MARK: - Exact-household-first restore resolution

    @Test("restore prefers the cached exact household over the ambiguous generic route")
    func restorePrefersCachedExactHousehold() async throws {
        let defaults = Self.makeDefaults("preferExact")
        let tokenStore = Self.makeTokenStore("preferExact")
        tokenStore.save("tok_succ")
        try Self.cacheIdentity(defaults, userID: "u_succ", householdID: "hh_transferred")
        let client = Self.makeClient()
        // The GENERIC route disagrees — it would resolve the OLD household
        // (the ambiguous joined_at heuristic, as if a stale second
        // membership sorted first). The EXACT route, stubbed separately
        // for the cached household, is what must win.
        AuthMockURLProtocol.setRoute("GET /api/me", Data("""
        {"ok":true,"data":{"user":{"id":"u_succ","name":"Gardener","email":"g@example.com"}}}
        """.utf8))
        AuthMockURLProtocol.setRoute("POST /api/households", Data("""
        {"ok":true,"data":{"household":{"id":"hh_own","name":"Own household","created_at":1,"updated_at":1},"role":"owner"}}
        """.utf8))
        AuthMockURLProtocol.setRoute("GET /api/households/hh_transferred", Data("""
        {"ok":true,"data":{"household":{"id":"hh_transferred","name":"Transferred garden","created_at":1,"updated_at":1},"role":"owner"}}
        """.utf8))
        let auth = AuthController(client: client, tokenStore: tokenStore, defaults: defaults)

        await auth.restoreSession()

        guard case .signedIn(_, let household) = auth.state else {
            Issue.record("expected signedIn, got \(auth.state)")
            return
        }
        #expect(household.id == "hh_transferred",
                "the cached exact household must win over the ambiguous generic resolution")
        #expect(!AuthMockURLProtocol.requestedPaths().contains("/api/households"),
                "the generic route must not even be called once the exact one succeeds")
    }

    @Test("a cached household this device left falls through to the generic route")
    func notAMemberFallsThroughToGenericResolution() async throws {
        let defaults = Self.makeDefaults("fallThrough")
        let tokenStore = Self.makeTokenStore("fallThrough")
        tokenStore.save("tok_succ")
        try Self.cacheIdentity(defaults, userID: "u_succ", householdID: "hh_left")
        let client = Self.makeClient()
        Self.stubIdentity(userID: "u_succ", householdID: "hh_current")
        Self.stubNotAMember(householdID: "hh_left")
        let auth = AuthController(client: client, tokenStore: tokenStore, defaults: defaults)

        await auth.restoreSession()

        guard case .signedIn(_, let household) = auth.state else {
            Issue.record("expected signedIn, got \(auth.state)")
            return
        }
        #expect(household.id == "hh_current",
                "a household this device is no longer a member of must fall through, not fail")
    }

    @Test("an unreachable exact-household check falls back to cache like any other transport failure")
    func exactHouseholdTransportFailureFallsBackToCache() async throws {
        let defaults = Self.makeDefaults("exactTransportFailure")
        let tokenStore = Self.makeTokenStore("exactTransportFailure")
        tokenStore.save("tok_succ")
        try Self.cacheIdentity(defaults, userID: "u_succ", householdID: "hh_own")
        let client = Self.makeClient()
        AuthMockURLProtocol.setRoute("GET /api/me", Data("""
        {"ok":true,"data":{"user":{"id":"u_succ","name":"Gardener","email":"g@example.com"}}}
        """.utf8))
        // The exact route 500s — a real outage, not a definitive "you are
        // not a member". Must NOT be reinterpreted as that; must fall back
        // to cache exactly like any other mid-restore transport failure.
        AuthMockURLProtocol.setRoute("GET /api/households/hh_own", Data("""
        {"ok":false,"error":{"code":"internal_error","message":"deploying"}}
        """.utf8))
        let auth = AuthController(client: client, tokenStore: tokenStore, defaults: defaults)

        await auth.restoreSession()

        guard case .signedIn(let user, let household) = auth.state else {
            Issue.record("expected signedIn from cache, got \(auth.state)")
            return
        }
        #expect(user.id == "u_succ")
        #expect(household.id == "hh_own")
        #expect(tokenStore.load() == "tok_succ", "a mid-restore 5xx must not clear the token")
    }
}

// MARK: - Auth router mock

/// Test-local URLProtocol (house pattern): method-qualified routes plus
/// uniform fail/respond modes for whole-flow failures.
final class AuthMockURLProtocol: URLProtocol, @unchecked Sendable {
    enum Mode {
        case routed
        case fail(Error)
        case respond(status: Int, body: Data)
    }

    nonisolated(unsafe) static var routes: [String: Data] = [:]
    nonisolated(unsafe) static var mode: Mode = .routed
    nonisolated(unsafe) static var requestLog: [String] = []
    static let lock = NSLock()

    static func makeSession() -> URLSession {
        lock.lock()
        defer { lock.unlock() }
        routes = [:]
        mode = .routed
        requestLog = []
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AuthMockURLProtocol.self]
        return URLSession(configuration: config)
    }

    static func requestedPaths() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return requestLog
    }

    static func setRoute(_ key: String, _ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        mode = .routed
        routes[key] = data
    }

    static func failAll(with error: Error) {
        lock.lock()
        defer { lock.unlock() }
        mode = .fail(error)
    }

    static func respondAll(status: Int, body: Data) {
        lock.lock()
        defer { lock.unlock() }
        mode = .respond(status: status, body: body)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        let mode = Self.mode
        let key = "\(request.httpMethod ?? "GET") \(request.url?.path ?? "")"
        let routedBody = Self.routes[key]
        Self.requestLog.append(request.url?.path ?? "")
        Self.lock.unlock()
        let url = request.url ?? URL(string: "https://test.local")!

        func deliver(status: Int, body: Data) {
            let response = HTTPURLResponse(
                url: url, statusCode: status, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }

        switch mode {
        case .fail(let error):
            client?.urlProtocol(self, didFailWithError: error)
        case .respond(let status, let body):
            deliver(status: status, body: body)
        case .routed:
            if let routedBody {
                deliver(status: 200, body: routedBody)
            } else {
                deliver(status: 404, body: Data(
                    #"{"ok":false,"error":{"code":"not_found","message":"unstubbed route"}}"#.utf8))
            }
        }
    }

    override func stopLoading() {}
}
