import Testing
import Foundation
import SwiftData
@testable import Seedkeep
import SeedkeepKit

/// E2E integration tests for the account-deletion flow (M5, YouView sequence).
///
/// The production sequence (YouView) is:
///   1. `_ = try await client.deleteAccount()`  → DELETE /api/me
///   2. `await auth.signOut()` (only on success)
///
/// The eraser is wired as in AppEnvironment.live(): `auth.wireLocalDataEraser`
/// receives a closure that calls `sync.eraseAllLocalData()`.
@MainActor
@Suite("Account deletion flow (M5)", .serialized)
struct AccountDeletionFlowTests {

    private static let householdID = "hh_del"

    private static func makeContainer(_ name: String) -> ModelContainer {
        makeTestContainer(name: name)
    }

    private static func makeDefaults(_ name: String) -> UserDefaults {
        let suite = "AccountDeletionFlowTests.\(name)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    /// Seeds several model types into the container so we can assert generic wipe.
    private static func seedContainer(_ container: ModelContainer) throws {
        let ctx = ModelContext(container)
        ctx.insert(LocalSeed(
            id: "seed_del_1",
            householdID: householdID,
            state: .active,
            packetCount: 2,
            source: .store,
            createdAt: 1, updatedAt: 1
        ))
        ctx.insert(LocalBed(
            id: "bed_del_1",
            householdID: householdID,
            name: "Raised bed",
            createdAt: 1, updatedAt: 1
        ))
        ctx.insert(LocalJournalEntry(
            id: "je_del_1",
            householdID: householdID,
            occurredOn: "2026-01-01",
            body: "first entry",
            seedID: nil, bedID: nil, plantingEventID: nil,
            createdAt: 1, updatedAt: 1, deletedAt: nil
        ))
        ctx.insert(LocalPendingWrite(
            id: "pw_del_1",
            entityType: "seed", entityID: "seed_del_1",
            operation: "update", payloadJSON: "{}",
            createdAt: 1
        ))
        ctx.insert(LocalSyncCursor(
            householdID: householdID,
            kind: "seeds",
            cursor: 999,
            lastSyncedAt: 1
        ))
        try ctx.save()
    }

    private static func cacheIdentity(
        _ defaults: UserDefaults, userID: String, householdID: String
    ) throws {
        let json = """
        {"user":{"id":"\(userID)","name":"Gardener","email":"g@example.com"},"household":{"id":"\(householdID)","name":"My household","created_at":1,"updated_at":1}}
        """
        _ = try JSONDecoder().decode(AuthController.CachedIdentity.self, from: Data(json.utf8))
        defaults.set(Data(json.utf8), forKey: AuthController.identityCacheKey)
    }

    // MARK: - Happy-path: deleteAccount succeeds → signOut wipes everything

    @Test("deleteAccount success: token cleared, identity cleared, all SwiftData rows wiped")
    func deleteAccountFullFlow() async throws {
        let container = Self.makeContainer("deleteAccountFull")
        let defaults = Self.makeDefaults("deleteAccountFull")
        let tokenStore = InMemoryTokenStore("tok_del")
        try Self.seedContainer(container)
        try Self.cacheIdentity(defaults, userID: "u_del", householdID: Self.householdID)

        // Stub DELETE /api/me → {ok:true,data:{deleted:true}}
        let session = AccountDeletionMockURLProtocol.makeSession(
            routes: [
                "DELETE /api/me": Data(
                    #"{"ok":true,"data":{"deleted":true}}"#.utf8
                )
            ]
        )
        let client = SeedkeepClient(
            configuration: .init(
                baseURL: URL(string: "https://test.local")!,
                session: session
            ),
            bearerToken: "tok_del"
        )
        let sync = SyncEngine(client: client, container: container)
        let auth = AuthController(client: client, tokenStore: tokenStore, defaults: defaults)
        auth.wireLocalDataEraser { [sync] in
            try? sync.eraseAllLocalData()
        }

        // Replicate the YouView sequence exactly.
        let deleted = try await client.deleteAccount()
        await auth.signOut()

        #expect(deleted == true, "deleteAccount() must return true on ok:true response")
        #expect(tokenStore.load() == nil, "signOut must clear the keychain token")
        #expect(auth.loadCachedIdentity() == nil, "signOut must clear the cached identity")
        guard case .signedOut = auth.state else {
            Issue.record("expected signedOut, got \(auth.state)")
            return
        }

        // Verify every schema model's row count == 0.
        let fresh = ModelContext(container)
        let rowCounts = try rowCountsAllModels(context: fresh)
        for (name, count) in rowCounts {
            #expect(count == 0, "model \(name) must be empty after deletion but had \(count) row(s)")
        }
    }

    // MARK: - Failure path: deleteAccount throws → signOut NOT reached

    @Test("deleteAccount RPC failure: token, identity, and SwiftData rows all intact")
    func deleteAccountRPCFailure() async throws {
        let container = Self.makeContainer("deleteAccountFail")
        let defaults = Self.makeDefaults("deleteAccountFail")
        let tokenStore = InMemoryTokenStore("tok_alive")
        try Self.seedContainer(container)
        try Self.cacheIdentity(defaults, userID: "u_alive", householdID: Self.householdID)

        // Stub DELETE /api/me → ok:false error (client decodes envelope; non-ok throws)
        let session = AccountDeletionMockURLProtocol.makeSession(
            routes: [
                "DELETE /api/me": Data(
                    #"{"ok":false,"error":{"code":"internal_error","message":"account deletion failed"}}"#.utf8
                )
            ],
            fallbackStatus: 500
        )
        let client = SeedkeepClient(
            configuration: .init(
                baseURL: URL(string: "https://test.local")!,
                session: session
            ),
            bearerToken: "tok_alive"
        )
        let sync = SyncEngine(client: client, container: container)
        let auth = AuthController(client: client, tokenStore: tokenStore, defaults: defaults)
        auth.wireLocalDataEraser { [sync] in
            try? sync.eraseAllLocalData()
        }

        // Replicate YouView's catch branch: deleteAccount throws → signOut NOT called.
        var threwError = false
        do {
            _ = try await client.deleteAccount()
        } catch {
            threwError = true
            // signOut() is intentionally NOT called here — mirroring YouView's catch branch.
        }

        #expect(threwError, "deleteAccount() must throw on a non-ok response")
        #expect(tokenStore.load() == "tok_alive",
                "token must be intact when deleteAccount() throws before signOut()")
        #expect(auth.loadCachedIdentity() != nil,
                "cached identity must be intact when deleteAccount() throws")
        // Auth state is still .signedOut (default) because adoptBearerToken was not called;
        // the key assertion is that rows are still present.

        let ctx = ModelContext(container)
        let seeds = try ctx.fetch(FetchDescriptor<LocalSeed>())
        let journals = try ctx.fetch(FetchDescriptor<LocalJournalEntry>())
        let pending = try ctx.fetch(FetchDescriptor<LocalPendingWrite>())
        let cursors = try ctx.fetch(FetchDescriptor<LocalSyncCursor>())
        #expect(!seeds.isEmpty, "seed rows must survive when deleteAccount() throws")
        #expect(!journals.isEmpty, "journal rows must survive when deleteAccount() throws")
        #expect(!pending.isEmpty, "pending writes must survive when deleteAccount() throws")
        #expect(!cursors.isEmpty, "sync cursors must survive when deleteAccount() throws")
    }
}

// MARK: - Per-model row counter helper

/// Returns a dictionary of model-type-name → row count for every model in
/// SeedkeepSchema.all. Uses the same eraseAllRows-style generic walk the
/// production eraser uses, but for reads.
@MainActor
private func rowCountsAllModels(context: ModelContext) throws -> [String: Int] {
    var result: [String: Int] = [:]
    for modelType in SeedkeepSchema.all {
        let count = try countRows(of: modelType, in: context)
        result[String(describing: modelType)] = count
    }
    return result
}

@MainActor
private func countRows<T: PersistentModel>(of type: T.Type, in context: ModelContext) throws -> Int {
    try context.fetch(FetchDescriptor<T>()).count
}

// MARK: - Account-deletion URLProtocol

/// Suite-local URLProtocol for account-deletion tests. Supports
/// method-qualified keys ("DELETE /api/me") so the same path can be
/// stubbed with different methods independently.
final class AccountDeletionMockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var routes: [String: Data] = [:]
    nonisolated(unsafe) static var fallbackStatus: Int = 200
    nonisolated(unsafe) static var fallbackBody: Data = Data(
        #"{"ok":false,"error":{"code":"not_found","message":"unstubbed"}}"#.utf8
    )
    static let lock = NSLock()

    static func makeSession(
        routes: [String: Data] = [:],
        fallbackStatus: Int = 200
    ) -> URLSession {
        lock.lock()
        defer { lock.unlock() }
        Self.routes = routes
        Self.fallbackStatus = fallbackStatus
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AccountDeletionMockURLProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        let path = request.url?.path ?? ""
        let method = request.httpMethod ?? "GET"
        let key = "\(method) \(path)"
        let body = Self.routes[key] ?? Self.routes[path] ?? Self.fallbackBody
        let status = Self.routes[key] != nil || Self.routes[path] != nil ? 200 : Self.fallbackStatus
        Self.lock.unlock()

        let url = request.url ?? URL(string: "https://test.local")!
        let response = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
