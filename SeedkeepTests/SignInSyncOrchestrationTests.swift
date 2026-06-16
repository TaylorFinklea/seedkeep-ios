import Testing
import Foundation
import SwiftData
@testable import Seedkeep
import SeedkeepKit

/// E2E integration tests for the adoptBearerToken → syncAll orchestration (M5).
///
/// Tests the post-exchange path only. `exchangeAppleToken` uses
/// `URLSession.shared` and is device-only; these tests cover the contract
/// that begins AFTER the token is in hand.
@MainActor
@Suite("Sign-in + sync orchestration (M5)", .serialized)
struct SignInSyncOrchestrationTests {

    private static let householdID = "hh_orch"

    private static func makeContainer(_ name: String) -> ModelContainer {
        makeTestContainer(name: name)
    }

    private static func makeDefaults(_ name: String) -> UserDefaults {
        let suite = "SignInSyncOrchestrationTests.\(name)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    /// Empty-page envelope for feeds this test doesn't exercise.
    private static let emptyPage = Data(
        #"{"ok":true,"data":{"items":[],"cursor":0,"has_more":false}}"#.utf8
    )

    // MARK: - Test 1: adoptBearerToken → full syncAll succeeds

    @Test("adoptBearerToken → syncAll: auth state signedIn + stubbed rows persisted")
    func adoptTokenThenSyncAll() async throws {
        let container = Self.makeContainer("adoptTokenSync")
        let defaults = Self.makeDefaults("adoptTokenSync")
        let tokenStore = InMemoryTokenStore()

        // A seed row returned by the seeds delta feed.
        let seedBody = Data("""
        {
          "ok": true,
          "data": {
            "items": [
              {
                "id": "seed_orch_1",
                "household_id": "\(Self.householdID)",
                "catalog_id": null,
                "state": "active",
                "packet_count": 3,
                "location_id": null,
                "year_packed": null,
                "source": "store",
                "custom_name": "Test Tomato",
                "custom_variety": null,
                "custom_company": null,
                "notes": null,
                "tag_ids": [],
                "created_at": 1000,
                "updated_at": 1000,
                "deleted_at": null
              }
            ],
            "cursor": 1000,
            "has_more": false
          }
        }
        """.utf8)

        // A journal entry returned by the journal feed.
        // NOTE: JournalEntryDTO uses camelCase keys (route convention differs
        // from the other snake_case feeds).
        let journalBody = Data("""
        {
          "ok": true,
          "data": {
            "items": [
              {
                "id": "je_orch_1",
                "householdId": "\(Self.householdID)",
                "occurredOn": "2026-01-15",
                "body": "First entry",
                "seedId": null,
                "bedId": null,
                "plantingEventId": null,
                "createdAt": 1001,
                "updatedAt": 1001,
                "deletedAt": null
              }
            ],
            "cursor": 1001,
            "has_more": false
          }
        }
        """.utf8)

        // Build auth client with identity stubs.
        let authSession = SyncOrchAuthMockURLProtocol.makeSession(routes: [
            "GET /api/me": Data("""
            {"ok":true,"data":{"user":{"id":"u_orch","name":"Grower","email":"g@example.com"}}}
            """.utf8),
            "POST /api/households": Data("""
            {"ok":true,"data":{"household":{"id":"\(Self.householdID)","name":"My household","created_at":1,"updated_at":1},"role":"owner"}}
            """.utf8)
        ])
        let authClient = SeedkeepClient(
            configuration: .init(
                baseURL: URL(string: "https://test.local")!,
                session: authSession
            )
        )
        let auth = AuthController(client: authClient, tokenStore: tokenStore, defaults: defaults)

        // Build sync client with feed stubs.
        let syncSession = SyncOrchSyncMockURLProtocol.makeSession(
            routes: [
                "/api/seeds": seedBody,
                "/api/journal": journalBody
            ],
            fallbackBody: Self.emptyPage,
            fallbackStatus: 200
        )
        let syncClient = SeedkeepClient(
            configuration: .init(
                baseURL: URL(string: "https://test.local")!,
                session: syncSession
            ),
            bearerToken: "tok_orch"
        )
        let engine = SyncEngine(client: syncClient, container: container)

        // Call adoptBearerToken (post-exchange path).
        await auth.adoptBearerToken("tok_orch")

        guard case .signedIn(let user, let household) = auth.state else {
            Issue.record("expected signedIn after adoptBearerToken, got \(String(describing: auth.state))")
            return
        }
        #expect(user.id == "u_orch")
        #expect(household.id == Self.householdID)

        // Now run syncAll against the household we just resolved.
        let ran = await engine.syncAll(householdID: household.id)
        #expect(ran == true, "syncAll must return true (not skipped)")
        #expect(engine.lastError == nil,
                "clean sync should produce no errors; got: \(engine.lastError ?? "nil")")

        let ctx = ModelContext(container)
        let seeds = try ctx.fetch(FetchDescriptor<LocalSeed>(
            predicate: #Predicate { $0.id == "seed_orch_1" }
        ))
        #expect(seeds.count == 1, "stubbed seed must persist to the container")
        #expect(seeds.first?.customName == "Test Tomato")

        let journals = try ctx.fetch(FetchDescriptor<LocalJournalEntry>(
            predicate: #Predicate { $0.id == "je_orch_1" }
        ))
        #expect(journals.count == 1, "stubbed journal entry must persist to the container")

        // Cursor for seeds feed must be saved.
        let cursorKey = LocalSyncCursor.key(householdID: household.id, kind: "seeds")
        let cursors = try ctx.fetch(FetchDescriptor<LocalSyncCursor>(
            predicate: #Predicate { $0.id == cursorKey }
        ))
        #expect(cursors.first?.cursor == 1000, "seeds cursor must be persisted after sync")
    }

    // MARK: - Test 2: Feed isolation under partial failure

    @Test("syncAll: one feed HTTP 503 (at route level) does not abort other feeds; lastError names the failed feed")
    func feedIsolationUnderPartialFailure() async throws {
        let container = Self.makeContainer("feedIsolation")

        // Seed body for the beds feed (one that succeeds).
        let bedBody = Data("""
        {
          "ok": true,
          "data": {
            "items": [
              {
                "id": "bed_iso_1",
                "household_id": "\(Self.householdID)",
                "name": "South Bed",
                "description": null,
                "width_feet": null,
                "length_feet": null,
                "sort_order": 0,
                "created_at": 2000,
                "updated_at": 2000,
                "deleted_at": null
              }
            ],
            "cursor": 2000,
            "has_more": false
          }
        }
        """.utf8)

        // Force the seeds feed to return a non-ok JSON envelope at the
        // HTTP 503 route level. This exercises per-feed do/catch isolation:
        // the error is recorded but the sweep continues with remaining feeds.
        // (Do NOT throw in client init — that short-circuits before per-feed catch.)
        let seedsErrorBody = Data(
            #"{"ok":false,"error":{"code":"internal_error","message":"seeds unavailable"}}"#.utf8
        )

        let session = FeedIsolationMockURLProtocol.makeSession(
            routes: [
                "/api/beds": bedBody,
                "/api/seeds": seedsErrorBody
            ],
            routeStatus: [
                "/api/seeds": 503
            ],
            fallbackBody: Self.emptyPage,
            fallbackStatus: 200
        )
        let client = SeedkeepClient(
            configuration: .init(
                baseURL: URL(string: "https://test.local")!,
                session: session
            ),
            bearerToken: "tok_iso"
        )
        let engine = SyncEngine(client: client, container: container)

        let ran = await engine.syncAll(householdID: Self.householdID)

        #expect(ran == true, "syncAll must run (not be skipped)")

        // Seeds feed failed; lastError must mention "seeds".
        let lastErr = engine.lastError ?? ""
        #expect(lastErr.contains("seeds"),
                "lastError must identify the failed seeds feed; got: '\(lastErr)'")

        // The beds feed (and others) must have succeeded and persisted rows.
        let ctx = ModelContext(container)
        let beds = try ctx.fetch(FetchDescriptor<LocalBed>(
            predicate: #Predicate { $0.id == "bed_iso_1" }
        ))
        #expect(beds.count == 1,
                "bed rows from a successful feed must persist even when seeds feed fails")

        // flushPending must have been attempted: no LocalPendingWrite rows
        // were seeded, so the flush is a no-op, but it must not have thrown
        // in a way that prevented lastError from being set.
        // (Verified indirectly: lastError set → sweep completed past flush.)
    }
}

// MARK: - URLProtocol: auth identity stubs (SyncOrchAuthMockURLProtocol)

/// Method-qualified routing for the AuthController's /api/me and
/// /api/households calls. Separate class from sync stubs so suites running
/// concurrently don't corrupt each other's static state.
final class SyncOrchAuthMockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var routes: [String: Data] = [:]
    static let lock = NSLock()

    static func makeSession(routes: [String: Data]) -> URLSession {
        lock.lock()
        defer { lock.unlock() }
        Self.routes = routes
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SyncOrchAuthMockURLProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        let key = "\(request.httpMethod ?? "GET") \(request.url?.path ?? "")"
        let body = Self.routes[key] ?? Data(
            #"{"ok":false,"error":{"code":"not_found","message":"unstubbed auth route"}}"#.utf8
        )
        Self.lock.unlock()
        let url = request.url ?? URL(string: "https://test.local")!
        let response = HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

// MARK: - URLProtocol: sync feed stubs (SyncOrchSyncMockURLProtocol)

/// Path-routed URLProtocol for sync-engine feed stubs in orchestration tests.
/// Every unhandled path returns the empty-page envelope so syncAll's full
/// sweep completes without blowing up on feeds this test doesn't exercise.
final class SyncOrchSyncMockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var routes: [String: Data] = [:]
    nonisolated(unsafe) static var fallbackBody: Data = Data()
    nonisolated(unsafe) static var fallbackStatus: Int = 200
    static let lock = NSLock()

    static func makeSession(
        routes: [String: Data],
        fallbackBody: Data,
        fallbackStatus: Int
    ) -> URLSession {
        lock.lock()
        defer { lock.unlock() }
        Self.routes = routes
        Self.fallbackBody = fallbackBody
        Self.fallbackStatus = fallbackStatus
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SyncOrchSyncMockURLProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        let path = request.url?.path ?? ""
        let body = Self.routes[path] ?? Self.fallbackBody
        let status = Self.routes[path] != nil ? 200 : Self.fallbackStatus
        Self.lock.unlock()
        let url = request.url ?? URL(string: "https://test.local")!
        let response = HTTPURLResponse(
            url: url, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

// MARK: - URLProtocol: feed isolation with per-route status (FeedIsolationMockURLProtocol)

/// Path-routed URLProtocol that supports per-route HTTP status overrides.
/// Used to force a single feed to HTTP 503 at the network layer (not by
/// throwing in client init) so the per-feed do/catch in SyncEngine is
/// exercised properly.
final class FeedIsolationMockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var routes: [String: Data] = [:]
    nonisolated(unsafe) static var routeStatus: [String: Int] = [:]
    nonisolated(unsafe) static var fallbackBody: Data = Data()
    nonisolated(unsafe) static var fallbackStatus: Int = 200
    static let lock = NSLock()

    static func makeSession(
        routes: [String: Data],
        routeStatus: [String: Int] = [:],
        fallbackBody: Data,
        fallbackStatus: Int
    ) -> URLSession {
        lock.lock()
        defer { lock.unlock() }
        Self.routes = routes
        Self.routeStatus = routeStatus
        Self.fallbackBody = fallbackBody
        Self.fallbackStatus = fallbackStatus
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FeedIsolationMockURLProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        let path = request.url?.path ?? ""
        let body = Self.routes[path] ?? Self.fallbackBody
        let status = Self.routeStatus[path] ?? (Self.routes[path] != nil ? 200 : Self.fallbackStatus)
        Self.lock.unlock()
        let url = request.url ?? URL(string: "https://test.local")!
        let response = HTTPURLResponse(
            url: url, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
