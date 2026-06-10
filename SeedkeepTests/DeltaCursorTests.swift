import Testing
import Foundation
import SwiftData
@testable import Seedkeep
import SeedkeepKit

/// Stabilization B3 · contract decision 9 — delta-cursor tiebreaker.
///
/// The sync engine stores the page envelope's `cursor_id` beside the
/// existing `updated_at` cursor and echoes it back as `since_id` on
/// every delta pull, so rows sharing one `updated_at` millisecond can't
/// be skipped across page boundaries. Servers that omit `cursor_id`
/// (legacy builds) leave the tiebreaker nil and the pull degrades to
/// the strict legacy behavior.
@MainActor
@Suite("SyncEngine — delta cursor tiebreaker (Stabilization B3)", .serialized)
struct DeltaCursorTests {

    private static let householdID = "hh_cursor"

    private static func makeContainer(_ name: String) -> ModelContainer {
        let schema = Schema(SeedkeepSchema.all)
        let config = ModelConfiguration(name, schema: schema, isStoredInMemoryOnly: true)
        return try! ModelContainer(for: schema, configurations: config)
    }

    private static func makeEngine(container: ModelContainer) -> SyncEngine {
        let session = CursorMockURLProtocol.makeSession()
        let client = SeedkeepClient(
            configuration: .init(
                baseURL: URL(string: "https://test.local")!,
                session: session
            ),
            bearerToken: "test_token"
        )
        return SyncEngine(client: client, container: container)
    }

    private static func seedsPage(
        cursor: Int64, cursorID: String?, hasMore: Bool
    ) -> Data {
        let cursorIDJSON = cursorID.map { "\"\($0)\"" } ?? "null"
        return Data("""
        {"ok":true,"data":{"items":[],"cursor":\(cursor),"has_more":\(hasMore),"cursor_id":\(cursorIDJSON)}}
        """.utf8)
    }

    private static func cursorRow(
        _ container: ModelContainer, kind: String
    ) throws -> LocalSyncCursor? {
        let key = LocalSyncCursor.key(householdID: householdID, kind: kind)
        let context = ModelContext(container)
        return try context.fetch(FetchDescriptor<LocalSyncCursor>(
            predicate: #Predicate { $0.id == key })).first
    }

    @Test("cursor_id from the page envelope is persisted and echoed as since_id on the next pull")
    func cursorIDPersistedAndEchoed() async throws {
        let container = Self.makeContainer("cursorPersist")
        let engine = Self.makeEngine(container: container)
        CursorMockURLProtocol.setSequence("/api/seeds", [
            Self.seedsPage(cursor: 1_000, cursorID: "seed_tiebreak", hasMore: false)
        ])

        await engine.syncAll(householdID: Self.householdID)

        let row = try #require(try Self.cursorRow(container, kind: "seeds"))
        #expect(row.cursor == 1_000)
        #expect(row.cursorID == "seed_tiebreak")

        // Second sweep: the seeds pull must send both since and since_id.
        CursorMockURLProtocol.setSequence("/api/seeds", [
            Self.seedsPage(cursor: 1_000, cursorID: "seed_tiebreak", hasMore: false)
        ])
        await engine.syncAll(householdID: Self.householdID)

        let queries = CursorMockURLProtocol.capturedQueries(path: "/api/seeds")
        let last = try #require(queries.last)
        #expect(last["since"] == "1000")
        #expect(last["since_id"] == "seed_tiebreak",
                "the stored tiebreaker must ride every delta pull")
    }

    @Test("multi-page pull threads cursor_id between pages")
    func multiPageThreadsCursorID() async throws {
        let container = Self.makeContainer("cursorPaged")
        let engine = Self.makeEngine(container: container)
        CursorMockURLProtocol.setSequence("/api/seeds", [
            Self.seedsPage(cursor: 500, cursorID: "seed_page1_last", hasMore: true),
            Self.seedsPage(cursor: 900, cursorID: "seed_page2_last", hasMore: false),
        ])

        await engine.syncAll(householdID: Self.householdID)

        let queries = CursorMockURLProtocol.capturedQueries(path: "/api/seeds")
        #expect(queries.count == 2)
        #expect(queries.first?["since_id"] == nil, "first pull has no tiebreaker yet")
        #expect(queries.last?["since"] == "500")
        #expect(queries.last?["since_id"] == "seed_page1_last",
                "page 2 must resume from page 1's tiebreaker")
        let row = try #require(try Self.cursorRow(container, kind: "seeds"))
        #expect(row.cursor == 900)
        #expect(row.cursorID == "seed_page2_last")
    }

    @Test("a legacy server omitting cursor_id leaves the tiebreaker nil and since_id off the wire")
    func legacyServerTolerated() async throws {
        let container = Self.makeContainer("cursorLegacy")
        let engine = Self.makeEngine(container: container)
        // Legacy page shape: no cursor_id key at all.
        CursorMockURLProtocol.setSequence("/api/seeds", [
            Data(#"{"ok":true,"data":{"items":[],"cursor":777,"has_more":false}}"#.utf8)
        ])

        await engine.syncAll(householdID: Self.householdID)

        let row = try #require(try Self.cursorRow(container, kind: "seeds"))
        #expect(row.cursor == 777)
        #expect(row.cursorID == nil)

        await engine.syncAll(householdID: Self.householdID)
        let queries = CursorMockURLProtocol.capturedQueries(path: "/api/seeds")
        let last = try #require(queries.last)
        #expect(last["since"] == "777")
        #expect(last["since_id"] == nil, "no tiebreaker means legacy cursor-only behavior")
    }

    @Test("a server that stops emitting cursor_id clears the stored tiebreaker")
    func staleTiebreakerCleared() async throws {
        let container = Self.makeContainer("cursorCleared")
        let engine = Self.makeEngine(container: container)
        CursorMockURLProtocol.setSequence("/api/seeds", [
            Self.seedsPage(cursor: 100, cursorID: "seed_a", hasMore: false)
        ])
        await engine.syncAll(householdID: Self.householdID)

        // Rollback scenario: next page omits cursor_id.
        CursorMockURLProtocol.setSequence("/api/seeds", [
            Data(#"{"ok":true,"data":{"items":[],"cursor":200,"has_more":false}}"#.utf8)
        ])
        await engine.syncAll(householdID: Self.householdID)

        let row = try #require(try Self.cursorRow(container, kind: "seeds"))
        #expect(row.cursor == 200)
        #expect(row.cursorID == nil,
                "a stale id must not pair with a newer watermark")
    }
}

// MARK: - Query-capturing sequence mock

/// Test-local URLProtocol (house pattern): per-path response sequences
/// (last element repeats) + captured query items per path.
final class CursorMockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var sequences: [String: [Data]] = [:]
    nonisolated(unsafe) static var sequenceCursors: [String: Int] = [:]
    nonisolated(unsafe) static var capturedURLs: [URL] = []
    static let lock = NSLock()

    static let emptyPage = Data(
        #"{"ok":true,"data":{"items":[],"cursor":0,"has_more":false}}"#.utf8)

    static func makeSession() -> URLSession {
        lock.lock()
        defer { lock.unlock() }
        sequences = [:]
        sequenceCursors = [:]
        capturedURLs = []
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CursorMockURLProtocol.self]
        return URLSession(configuration: config)
    }

    static func setSequence(_ path: String, _ bodies: [Data]) {
        lock.lock()
        defer { lock.unlock() }
        sequences[path] = bodies
        sequenceCursors[path] = 0
    }

    /// Query dictionaries of every captured request to `path`, in order.
    static func capturedQueries(path: String) -> [[String: String]] {
        lock.lock()
        defer { lock.unlock() }
        return capturedURLs
            .filter { $0.path == path }
            .map { url in
                let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                    .queryItems ?? []
                return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
            }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url ?? URL(string: "https://test.local")!
        Self.lock.lock()
        Self.capturedURLs.append(url)
        let path = url.path
        let body: Data
        if let seq = Self.sequences[path], !seq.isEmpty {
            let cursor = Self.sequenceCursors[path] ?? 0
            body = seq[min(cursor, seq.count - 1)]
            Self.sequenceCursors[path] = cursor + 1
        } else {
            body = Self.emptyPage
        }
        Self.lock.unlock()
        let response = HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
