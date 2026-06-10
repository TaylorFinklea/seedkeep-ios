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
        let schema = Schema(SeedkeepSchema.all)
        let config = ModelConfiguration(name, schema: schema, isStoredInMemoryOnly: true)
        return try! ModelContainer(for: schema, configurations: config)
    }

    private static func makeDefaults(_ name: String) -> UserDefaults {
        let suite = "AuthLifecycleTests.\(name)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private static func makeTokenStore(_ name: String) -> KeychainTokenStore {
        let store = KeychainTokenStore(service: "AuthLifecycleTests.\(name)")
        store.clear()
        return store
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
    static let lock = NSLock()

    static func makeSession() -> URLSession {
        lock.lock()
        defer { lock.unlock() }
        routes = [:]
        mode = .routed
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AuthMockURLProtocol.self]
        return URLSession(configuration: config)
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
