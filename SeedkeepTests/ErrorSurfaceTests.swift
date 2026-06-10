import Testing
import Foundation
import SwiftData
@testable import Seedkeep
import SeedkeepKit

/// Stabilization B3 — error surfaces:
///
/// 1. `SyncEngine.lastHumanizedError` carries `humanizeError` copy for
///    the banner (no raw codes / HTTP statuses / body excerpts), while
///    `lastError` keeps the machine string for diagnostics.
/// 2. `JournalStore` forwards refresh failures through its error sink
///    (wired to the app-root banner) instead of dead-ending in
///    `lastError`.
@MainActor
@Suite("Error surfaces (Stabilization B3)", .serialized)
struct ErrorSurfaceTests {

    private static let householdID = "hh_errors"

    private static func makeContainer(_ name: String) -> ModelContainer {
        let schema = Schema(SeedkeepSchema.all)
        let config = ModelConfiguration(name, schema: schema, isStoredInMemoryOnly: true)
        return try! ModelContainer(for: schema, configurations: config)
    }

    private static func makeClient() -> SeedkeepClient {
        let session = ErrorSurfaceMockURLProtocol.makeSession()
        return SeedkeepClient(
            configuration: .init(
                baseURL: URL(string: "https://test.local")!,
                session: session
            ),
            bearerToken: "test_token"
        )
    }

    @Test("offline sync sets humanized banner copy alongside the machine mirror")
    func offlineSyncHumanizedError() async throws {
        let container = Self.makeContainer("errorSurfaceOffline")
        let client = Self.makeClient()
        ErrorSurfaceMockURLProtocol.failAll(with: URLError(.notConnectedToInternet))
        let engine = SyncEngine(client: client, container: container)

        await engine.syncAll(householdID: Self.householdID)

        let banner = try #require(engine.lastHumanizedError)
        #expect(banner == "You're offline. Sync paused until the connection returns.")
        #expect(engine.lastError?.contains("locations") == true,
                "machine mirror keeps the per-feed detail")
    }

    @Test("server decode drift never leaks machine strings into the banner copy")
    func decodeDriftHumanized() async throws {
        let container = Self.makeContainer("errorSurfaceDrift")
        let client = Self.makeClient()
        // Non-envelope body — the classic proxy/drift shape.
        ErrorSurfaceMockURLProtocol.respondAll(
            status: 502, body: Data("<html>Bad Gateway</html>".utf8))
        let engine = SyncEngine(client: client, container: container)

        await engine.syncAll(householdID: Self.householdID)

        let banner = try #require(engine.lastHumanizedError)
        #expect(!banner.contains("HTTP"), "banner must not leak statuses: \(banner)")
        #expect(!banner.contains("body:"), "banner must not leak body excerpts")
        #expect(!banner.contains("decode"), "banner must not leak decode internals")
    }

    @Test("clean sync clears the humanized error")
    func cleanSyncClears() async throws {
        let container = Self.makeContainer("errorSurfaceClean")
        let client = Self.makeClient()
        ErrorSurfaceMockURLProtocol.failAll(with: URLError(.timedOut))
        let engine = SyncEngine(client: client, container: container)
        await engine.syncAll(householdID: Self.householdID)
        #expect(engine.lastHumanizedError != nil)

        ErrorSurfaceMockURLProtocol.succeedAll()
        await engine.syncAll(householdID: Self.householdID)
        #expect(engine.lastHumanizedError == nil)
        #expect(engine.lastError == nil)
    }

    @Test("JournalStore.refresh failure reaches the wired error sink")
    func journalRefreshFailureSurfaces() async throws {
        let container = Self.makeContainer("errorSurfaceJournal")
        let client = Self.makeClient()
        ErrorSurfaceMockURLProtocol.failAll(with: URLError(.notConnectedToInternet))
        let store = JournalStore(client: client, container: container)

        final class Sink {
            var captured: [Error] = []
        }
        let sink = Sink()
        store.wireErrorSink { error in
            sink.captured.append(error)
        }

        await store.refresh(seedID: "seed_x")

        #expect(sink.captured.count == 1,
                "a failing scoped journal refresh must surface through the sink")
        #expect((sink.captured.first as? URLError)?.code == .notConnectedToInternet)
        #expect(store.lastError != nil)
    }
}

// MARK: - Uniform-response mock

/// Test-local URLProtocol that applies ONE behavior to every route:
/// fail with a transport error, return a fixed status/body, or return
/// the standard empty page. Enough for whole-sweep error-surface tests.
final class ErrorSurfaceMockURLProtocol: URLProtocol, @unchecked Sendable {
    enum Mode {
        case fail(Error)
        case respond(status: Int, body: Data)
        case emptyPage
    }

    nonisolated(unsafe) static var mode: Mode = .emptyPage
    static let lock = NSLock()

    static let emptyPage = Data(
        #"{"ok":true,"data":{"items":[],"cursor":0,"has_more":false}}"#.utf8)

    static func makeSession() -> URLSession {
        lock.lock()
        defer { lock.unlock() }
        mode = .emptyPage
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ErrorSurfaceMockURLProtocol.self]
        return URLSession(configuration: config)
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

    static func succeedAll() {
        lock.lock()
        defer { lock.unlock() }
        mode = .emptyPage
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        let mode = Self.mode
        Self.lock.unlock()
        let url = request.url ?? URL(string: "https://test.local")!
        switch mode {
        case .fail(let error):
            client?.urlProtocol(self, didFailWithError: error)
        case .respond(let status, let body):
            let response = HTTPURLResponse(
                url: url, statusCode: status, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/html"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        case .emptyPage:
            let response = HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Self.emptyPage)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}
