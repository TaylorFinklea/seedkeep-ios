import Testing
import Foundation
import SwiftData
@testable import Seedkeep
import SeedkeepKit

/// Stabilization B3 — flushPending hardening:
///
/// 1. **Failure classification** — transport errors (URLError), 5xx and
///    429 do NOT increment `attemptCount` (no dead-letter strikes); 429
///    honors the envelope `retry_after_seconds`. Only definitive 4xx
///    rejections count.
/// 2. **Tombstoned-target updates** — `update` + `not_found` is a clean
///    drop (mirrors the delete-on-404 idiom), not six retries followed
///    by permanent dead-letter junk.
/// 3. **Reentrancy** — concurrent flushPending invocations dispatch each
///    pending row exactly once (second caller awaits the in-flight pass).
/// 4. **Coalescing** — successive update-enqueues for the same
///    (entity, id) merge into one pending write instead of one per
///    keystroke, preserving explicit-null clears.
@MainActor
@Suite("SyncEngine — flush hardening (Stabilization B3)", .serialized)
struct FlushHardeningTests {

    private static let householdID = "hh_flush"

    private static func makeContainer(_ name: String) -> ModelContainer {
        let schema = Schema(SeedkeepSchema.all)
        let config = ModelConfiguration(name, schema: schema, isStoredInMemoryOnly: true)
        return try! ModelContainer(for: schema, configurations: config)
    }

    private static func makeEngine(container: ModelContainer) -> SyncEngine {
        let session = FlushMockURLProtocol.makeSession()
        let client = SeedkeepClient(
            configuration: .init(
                baseURL: URL(string: "https://test.local")!,
                session: session
            ),
            bearerToken: "test_token"
        )
        return SyncEngine(client: client, container: container)
    }

    private static func insertSeedAndPendingUpdate(
        _ container: ModelContainer,
        seedID: String = "seed_flush_1"
    ) throws {
        let context = ModelContext(container)
        context.insert(LocalSeed(
            id: seedID, householdID: householdID, state: .active,
            packetCount: 1, source: .store, createdAt: 1, updatedAt: 1))
        context.insert(LocalPendingWrite(
            id: "pw_\(seedID)",
            entityType: "seed", entityID: seedID, operation: "update",
            payloadJSON: #"{"packet_count":2}"#,
            createdAt: 1
        ))
        try context.save()
    }

    private static func onlyPendingRow(_ container: ModelContainer) throws -> LocalPendingWrite? {
        let context = ModelContext(container)
        return try context.fetch(FetchDescriptor<LocalPendingWrite>()).first
    }

    // MARK: - Classification

    @Test("offline URLError defers the retry without a dead-letter strike")
    func transportFailureDoesNotStrike() async throws {
        let container = Self.makeContainer("flushTransport")
        let engine = Self.makeEngine(container: container)
        try Self.insertSeedAndPendingUpdate(container)
        FlushMockURLProtocol.setStub(
            "PATCH /api/seeds/seed_flush_1",
            .failure(URLError(.notConnectedToInternet)))

        let before = SyncEngine.nowMs()
        try await engine.flushPending()

        let row = try #require(try Self.onlyPendingRow(container))
        #expect(row.attemptCount == 0, "offline must not consume a dead-letter strike")
        #expect(!row.isDeadLettered)
        #expect(row.nextAttemptAt >= before + SyncEngine.transientRetryMillis - 1_000,
                "transient backoff must push nextAttemptAt out")
    }

    @Test("HTTP 500 defers without a strike")
    func serverErrorDoesNotStrike() async throws {
        let container = Self.makeContainer("flush5xx")
        let engine = Self.makeEngine(container: container)
        try Self.insertSeedAndPendingUpdate(container)
        FlushMockURLProtocol.setStub(
            "PATCH /api/seeds/seed_flush_1",
            .response(status: 500, body: Data(
                #"{"ok":false,"error":{"code":"internal_error","message":"boom"}}"#.utf8)))

        try await engine.flushPending()

        let row = try #require(try Self.onlyPendingRow(container))
        #expect(row.attemptCount == 0)
        #expect(!row.isDeadLettered)
        #expect(row.lastError?.contains("internal_error") == true)
    }

    @Test("429 honors retry_after_seconds without a strike")
    func rateLimitHonorsRetryAfter() async throws {
        let container = Self.makeContainer("flush429")
        let engine = Self.makeEngine(container: container)
        try Self.insertSeedAndPendingUpdate(container)
        FlushMockURLProtocol.setStub(
            "PATCH /api/seeds/seed_flush_1",
            .response(status: 429, body: Data(
                #"{"ok":false,"error":{"code":"rate_limited","message":"slow down"},"retry_after_seconds":1800}"#.utf8)))

        let before = SyncEngine.nowMs()
        try await engine.flushPending()

        let row = try #require(try Self.onlyPendingRow(container))
        #expect(row.attemptCount == 0, "429 must not consume a strike")
        #expect(row.nextAttemptAt >= before + 1_800_000 - 1_000,
                "Retry-After (1800s) must drive the backoff, got delta \(row.nextAttemptAt - before)ms")
    }

    @Test("definitive 4xx rejection still counts toward dead-letter")
    func definitiveRejectionCounts() async throws {
        let container = Self.makeContainer("flush4xx")
        let engine = Self.makeEngine(container: container)
        try Self.insertSeedAndPendingUpdate(container)
        FlushMockURLProtocol.setStub(
            "PATCH /api/seeds/seed_flush_1",
            .response(status: 400, body: Data(
                #"{"ok":false,"error":{"code":"validation_failed","message":"bad packet_count"}}"#.utf8)))

        try await engine.flushPending()

        let row = try #require(try Self.onlyPendingRow(container))
        #expect(row.attemptCount == 1, "a definitive rejection must strike")
        #expect(row.lastError?.contains("validation_failed") == true)
    }

    // MARK: - Tombstoned-target update

    @Test("update against a tombstoned entity (404 not_found) is dropped cleanly")
    func tombstonedUpdateDropped() async throws {
        let container = Self.makeContainer("flushTombstone")
        let engine = Self.makeEngine(container: container)
        try Self.insertSeedAndPendingUpdate(container)
        FlushMockURLProtocol.setStub(
            "PATCH /api/seeds/seed_flush_1",
            .response(status: 404, body: Data(
                #"{"ok":false,"error":{"code":"not_found","message":"seed not found"}}"#.utf8)))

        try await engine.flushPending()

        let context = ModelContext(container)
        let rows = try context.fetch(FetchDescriptor<LocalPendingWrite>())
        #expect(rows.isEmpty,
                "an update whose target was tombstoned by a sibling device must be dropped, not dead-lettered")
    }

    // MARK: - Reentrancy

    @Test("concurrent flushPending invocations dispatch a pending create exactly once")
    func concurrentFlushDispatchesOnce() async throws {
        let container = Self.makeContainer("flushReentrant")
        let engine = Self.makeEngine(container: container)
        let local = try engine.enqueueCreateLocation(
            name: "Greenhouse", householdID: Self.householdID)
        FlushMockURLProtocol.setStub(
            "POST /api/locations",
            .response(status: 200, body: Data("""
            {"ok":true,"data":{"location":{"id":"\(local.id)","household_id":"\(Self.householdID)","name":"Greenhouse","sort_order":0,"created_at":1,"updated_at":2,"deleted_at":null}}}
            """.utf8), delayMs: 150))

        async let first: Void = engine.flushPending()
        async let second: Void = engine.flushPending()
        _ = try await (first, second)

        #expect(FlushMockURLProtocol.requestCount(
            method: "POST", path: "/api/locations") == 1,
                "overlapping flushes must not POST the same create twice")
        let context = ModelContext(container)
        #expect(try context.fetch(FetchDescriptor<LocalPendingWrite>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<LocalLocation>()).count == 1)
    }

    // MARK: - Coalescing

    @Test("successive seed update enqueues coalesce into one pending write with merged patch")
    func keystrokeUpdatesCoalesce() async throws {
        let container = Self.makeContainer("flushCoalesce")
        let engine = Self.makeEngine(container: container)
        let context = ModelContext(container)
        context.insert(LocalSeed(
            id: "seed_co_1", householdID: Self.householdID, state: .active,
            packetCount: 1, source: .store, notes: "old", createdAt: 1, updatedAt: 1))
        try context.save()

        // Simulated keystrokes: notes evolves, then a clear of the name.
        try engine.enqueueUpdateSeed(id: "seed_co_1", .init(notes: "w"))
        try engine.enqueueUpdateSeed(id: "seed_co_1", .init(notes: "wa"))
        try engine.enqueueUpdateSeed(id: "seed_co_1", .init(notes: "water daily"))
        try engine.enqueueUpdateSeed(id: "seed_co_1", .init(custom_name: .some(nil)))

        let rows = try context.fetch(FetchDescriptor<LocalPendingWrite>())
        #expect(rows.count == 1, "per-keystroke enqueues must coalesce, got \(rows.count) rows")
        let payload = try #require(rows.first?.payloadJSON)
        let obj = try #require(JSONSerialization.jsonObject(
            with: Data(payload.utf8)) as? [String: Any])
        #expect(obj["notes"] as? String == "water daily", "latest keystroke wins")
        #expect(obj["custom_name"] is NSNull, "explicit-null clear must survive the merge")
    }

    @Test("coalescing keeps distinct entities and non-update ops separate")
    func coalescingScopedToEntityAndOp() async throws {
        let container = Self.makeContainer("flushCoalesceScope")
        let engine = Self.makeEngine(container: container)
        let context = ModelContext(container)
        for id in ["seed_sc_1", "seed_sc_2"] {
            context.insert(LocalSeed(
                id: id, householdID: Self.householdID, state: .active,
                packetCount: 1, source: .store, createdAt: 1, updatedAt: 1))
        }
        try context.save()

        try engine.enqueueUpdateSeed(id: "seed_sc_1", .init(packet_count: 2))
        try engine.enqueueUpdateSeed(id: "seed_sc_2", .init(packet_count: 3))
        try engine.enqueueDeleteSeed(id: "seed_sc_1")
        // An update AFTER a queued delete must not merge into the delete.
        try engine.enqueueUpdateSeed(id: "seed_sc_1", .init(packet_count: 4))

        let rows = (try context.fetch(FetchDescriptor<LocalPendingWrite>()))
        let updates = rows.filter { $0.operation == "update" }
        let deletes = rows.filter { $0.operation == "delete" }
        #expect(deletes.count == 1)
        // seed_sc_2 keeps its own row; seed_sc_1's two updates coalesce.
        #expect(updates.count == 2, "got \(updates.map { "\($0.entityID)/\($0.operation)" })")
        let sc1Update = updates.first { $0.entityID == "seed_sc_1" }
        let obj = try #require(JSONSerialization.jsonObject(
            with: Data((sc1Update?.payloadJSON ?? "{}").utf8)) as? [String: Any])
        #expect((obj["packet_count"] as? NSNumber)?.intValue == 4)
    }
}

// MARK: - Stub-capable router mock

/// Test-local URLProtocol (house pattern) with per-route status codes,
/// transport-error injection, optional response delay, and request
/// counting — the existing router mocks only support a uniform status.
final class FlushMockURLProtocol: URLProtocol, @unchecked Sendable {
    enum Stub {
        case response(status: Int, body: Data, delayMs: Int = 0)
        case failure(Error)
    }

    nonisolated(unsafe) static var stubs: [String: Stub] = [:]
    nonisolated(unsafe) static var counts: [String: Int] = [:]
    static let lock = NSLock()

    static let fallbackBody = Data(
        #"{"ok":true,"data":{"items":[],"cursor":0,"has_more":false}}"#.utf8)

    static func makeSession() -> URLSession {
        lock.lock()
        defer { lock.unlock() }
        stubs = [:]
        counts = [:]
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FlushMockURLProtocol.self]
        return URLSession(configuration: config)
    }

    static func setStub(_ key: String, _ stub: Stub) {
        lock.lock()
        defer { lock.unlock() }
        stubs[key] = stub
    }

    static func requestCount(method: String, path: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return counts["\(method) \(path)"] ?? 0
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let key = "\(request.httpMethod ?? "GET") \(request.url?.path ?? "")"
        Self.lock.lock()
        Self.counts[key, default: 0] += 1
        let stub = Self.stubs[key]
        Self.lock.unlock()

        let url = request.url ?? URL(string: "https://test.local")!
        switch stub {
        case .failure(let error):
            client?.urlProtocol(self, didFailWithError: error)
        case .response(let status, let body, let delayMs):
            let deliver = { [weak self] in
                guard let self else { return }
                let response = HTTPURLResponse(
                    url: url, statusCode: status, httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"])!
                self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                self.client?.urlProtocol(self, didLoad: body)
                self.client?.urlProtocolDidFinishLoading(self)
            }
            if delayMs > 0 {
                DispatchQueue.global().asyncAfter(
                    deadline: .now() + .milliseconds(delayMs), execute: deliver)
            } else {
                deliver()
            }
        case nil:
            let response = HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Self.fallbackBody)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}
