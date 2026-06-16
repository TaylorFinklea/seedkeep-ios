import Testing
import Foundation
import SwiftData
@testable import Seedkeep
import SeedkeepKit

/// Verifies that `flushPending` is genuinely load-bearing: a successful
/// dispatch removes the `LocalPendingWrite` row, and a transient 5xx
/// failure leaves it queued for retry.
///
/// Chosen op: `seed` / `delete` (DELETE /api/seeds/:id)
///   — dispatch maps to `client.deleteSeed(id:)`, which is the simplest
///   confirmed case in the dispatcher (no body decode, no local-row
///   replacement). The success stub returns the wire `DeleteResult`
///   envelope; the 5xx stub returns a generic error envelope.
@MainActor
@Suite("SyncEngine — flushPending is load-bearing", .serialized)
struct FlushPendingTests {

    private static let householdID = "hh_flush_pending"
    private static let seedID = "seed_fp_delete_1"

    // MARK: - Helpers

    private static func makeEngine(stub: FlushPendingMockURLProtocol.Stub) -> (SyncEngine, ModelContainer) {
        let container = makeTestContainer(name: "flushPending_\(UUID().uuidString)")
        let session = FlushPendingMockURLProtocol.makeSession(stub: stub)
        let client = SeedkeepClient(
            configuration: .init(
                baseURL: URL(string: "https://test.local")!,
                session: session
            ),
            bearerToken: "test_token"
        )
        let engine = SyncEngine(client: client, container: container)
        return (engine, container)
    }

    /// Inserts a `LocalSeed` + a matching `seed/delete` `LocalPendingWrite`.
    private static func seedDeleteWrite(in container: ModelContainer) throws {
        let context = ModelContext(container)
        context.insert(LocalSeed(
            id: seedID, householdID: householdID,
            state: .active, packetCount: 1, source: .store,
            createdAt: 1, updatedAt: 1
        ))
        context.insert(LocalPendingWrite(
            id: "pw_fp_\(seedID)",
            entityType: "seed", entityID: seedID, operation: "delete",
            payloadJSON: "{}",
            createdAt: 1
        ))
        try context.save()
    }

    private static func pendingWrites(in container: ModelContainer) throws -> [LocalPendingWrite] {
        let context = ModelContext(container)
        return try context.fetch(FetchDescriptor<LocalPendingWrite>())
    }

    // MARK: - Success: row is deleted

    @Test("successful seed delete flush removes the LocalPendingWrite row")
    func successfulFlushRemovesRow() async throws {
        // Wire: {"ok":true,"data":{"id":"seed_fp_delete_1","deleted_at":1000}}
        let successBody = Data("""
        {"ok":true,"data":{"id":"\(Self.seedID)","deleted_at":1000}}
        """.utf8)

        let (engine, container) = Self.makeEngine(
            stub: .response(method: "DELETE",
                            path: "/api/seeds/\(Self.seedID)",
                            status: 200, body: successBody)
        )
        try Self.seedDeleteWrite(in: container)

        // Confirm pre-condition: one pending write.
        let before = try Self.pendingWrites(in: container)
        #expect(before.count == 1, "precondition: one pending write must exist before flush")

        try await engine.flushPending()

        // The row must be gone after a successful flush.
        let after = try Self.pendingWrites(in: container)
        #expect(after.isEmpty,
                "LocalPendingWrite must be deleted from the store after a successful 2xx flush")
    }

    // MARK: - 5xx: row stays queued

    @Test("transient 5xx failure leaves the LocalPendingWrite queued for retry")
    func serverErrorLeavesRowQueued() async throws {
        let errorBody = Data(
            #"{"ok":false,"error":{"code":"internal_error","message":"boom"}}"#.utf8
        )
        let (engine, container) = Self.makeEngine(
            stub: .response(method: "DELETE",
                            path: "/api/seeds/\(Self.seedID)",
                            status: 500, body: errorBody)
        )
        try Self.seedDeleteWrite(in: container)

        try await engine.flushPending()

        let rows = try Self.pendingWrites(in: container)
        #expect(rows.count == 1, "LocalPendingWrite must remain queued after a 5xx transient failure")

        let row = try #require(rows.first)
        #expect(row.attemptCount == 0,
                "5xx must not consume a dead-letter strike (transient failure path)")
        #expect(!row.isDeadLettered,
                "5xx must not dead-letter the write")
        #expect(row.nextAttemptAt > SyncEngine.nowMs() - 1_000,
                "5xx must push nextAttemptAt into the future for backoff")
    }
}

// MARK: - Minimal URLProtocol for these tests

/// Targeted mock: one route can be stubbed with a fixed status + body; all
/// other requests fall back to the empty-page envelope so pull feeds don't
/// fail the engine during a `syncAll` call.
final class FlushPendingMockURLProtocol: URLProtocol, @unchecked Sendable {
    enum Stub {
        case response(method: String, path: String, status: Int, body: Data)
    }

    nonisolated(unsafe) static var stub: Stub?
    static let lock = NSLock()

    static let emptyPage = Data(
        #"{"ok":true,"data":{"items":[],"cursor":0,"has_more":false}}"#.utf8
    )

    static func makeSession(stub: Stub) -> URLSession {
        lock.lock()
        defer { lock.unlock() }
        Self.stub = stub
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FlushPendingMockURLProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let method = request.httpMethod ?? "GET"
        let path = request.url?.path ?? ""
        let url = request.url ?? URL(string: "https://test.local")!

        Self.lock.lock()
        let matched: (Int, Data)? = {
            guard case .response(let m, let p, let status, let body) = Self.stub,
                  m == method, p == path else { return nil }
            return (status, body)
        }()
        Self.lock.unlock()

        let (status, body) = matched ?? (200, Self.emptyPage)
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
