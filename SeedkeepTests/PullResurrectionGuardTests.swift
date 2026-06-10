import Testing
import Foundation
import SwiftData
@testable import Seedkeep
import SeedkeepKit

/// Stabilization B3 — pull-side guards:
///
/// 1. **Resurrection guard** — `syncAll` pulls before it pushes, so a
///    row soft-deleted locally (its delete still queued) comes back from
///    the server still live. The upsert must NOT clear the local
///    tombstone; the queued delete flushes at the end of the same sweep.
/// 2. **Insert guard** — same scenario when the local row is already
///    hard-deleted: the pull must not re-insert it.
/// 3. **Skip signal** — `syncAll` returns `false` when another pass is
///    in flight so `syncIfPossible` neither re-presents a stale
///    `lastError` nor runs post-sync orchestration mid-sweep.
@MainActor
@Suite("SyncEngine — pull guards + skip signal (Stabilization B3)", .serialized)
struct PullResurrectionGuardTests {

    private static let householdID = "hh_pull_guard"

    private static func makeContainer(_ name: String) -> ModelContainer {
        let schema = Schema(SeedkeepSchema.all)
        let config = ModelConfiguration(name, schema: schema, isStoredInMemoryOnly: true)
        return try! ModelContainer(for: schema, configurations: config)
    }

    private static func makeEngine(container: ModelContainer) -> SyncEngine {
        let session = PullGuardMockURLProtocol.makeSession()
        let client = SeedkeepClient(
            configuration: .init(
                baseURL: URL(string: "https://test.local")!,
                session: session
            ),
            bearerToken: "test_token"
        )
        return SyncEngine(client: client, container: container)
    }

    private static func liveSeedPage(id: String, updatedAt: Int64) -> Data {
        Data("""
        {"ok":true,"data":{"items":[{"id":"\(id)","household_id":"\(householdID)","catalog_id":null,"state":"active","packet_count":1,"location_id":null,"year_packed":null,"source":"store","custom_name":"Zombie Seed","custom_variety":null,"custom_company":null,"notes":null,"created_at":1,"updated_at":\(updatedAt),"deleted_at":null,"tag_ids":[]}],"cursor":\(updatedAt),"has_more":false}}
        """.utf8)
    }

    @Test("a queued local delete is not resurrected by an incoming live upsert")
    func queuedDeleteWinsOverPullUpsert() async throws {
        let container = Self.makeContainer("pullGuardSoftDelete")
        let engine = Self.makeEngine(container: container)
        let context = ModelContext(container)
        context.insert(LocalSeed(
            id: "seed_zombie", householdID: Self.householdID, state: .active,
            packetCount: 1, source: .store, createdAt: 1, updatedAt: 1))
        try context.save()

        // Soft-delete locally; the delete waits in the queue.
        try engine.enqueueDeleteSeed(id: "seed_zombie")

        // A sibling device touched the seed: the feed reports it live
        // with a newer updated_at. The DELETE push succeeds.
        PullGuardMockURLProtocol.setRoute(
            "GET /api/seeds", Self.liveSeedPage(id: "seed_zombie", updatedAt: 999))
        PullGuardMockURLProtocol.setRoute(
            "DELETE /api/seeds/seed_zombie",
            Data(#"{"ok":true,"data":{"id":"seed_zombie","deleted_at":1000}}"#.utf8))

        await engine.syncAll(householdID: Self.householdID)

        let seed = try context.fetch(FetchDescriptor<LocalSeed>(
            predicate: #Predicate { $0.id == "seed_zombie" })).first
        #expect(seed?.deletedAt != nil,
                "the local tombstone must win — pull apply resurrected the deleted seed")
        let pending = try context.fetch(FetchDescriptor<LocalPendingWrite>())
        #expect(pending.isEmpty, "the queued delete should have flushed in the same sweep")
    }

    @Test("a pull does not re-insert a hard-deleted row whose delete is still queued")
    func pullDoesNotReinsertWithQueuedDelete() async throws {
        let container = Self.makeContainer("pullGuardInsert")
        let engine = Self.makeEngine(container: container)
        let context = ModelContext(container)
        // No local seed row — only the queued delete intent remains.
        context.insert(LocalPendingWrite(
            id: "pw_zombie2",
            entityType: "seed", entityID: "seed_zombie2", operation: "delete",
            payloadJSON: "{}",
            createdAt: 1
        ))
        try context.save()

        PullGuardMockURLProtocol.setRoute(
            "GET /api/seeds", Self.liveSeedPage(id: "seed_zombie2", updatedAt: 999))
        PullGuardMockURLProtocol.setRoute(
            "DELETE /api/seeds/seed_zombie2",
            Data(#"{"ok":true,"data":{"id":"seed_zombie2","deleted_at":1000}}"#.utf8))

        await engine.syncAll(householdID: Self.householdID)

        let seeds = try context.fetch(FetchDescriptor<LocalSeed>())
        #expect(seeds.isEmpty, "pull must not re-insert a row with a queued local delete")
    }

    @Test("syncAll returns false when another pass is in flight and leaves lastError alone")
    func skippedSyncIsDistinguishable() async throws {
        let container = Self.makeContainer("pullGuardSkip")
        let engine = Self.makeEngine(container: container)

        // Pass 1: poisoned feed seeds a lastError.
        PullGuardMockURLProtocol.setRoute(
            "GET /api/seeds",
            Data(#"{"ok":false,"error":{"code":"server_error","message":"poisoned"}}"#.utf8))
        let ranFirst = await engine.syncAll(householdID: Self.householdID)
        #expect(ranFirst, "an uncontended sync must report that it ran")
        let staleError = engine.lastError
        #expect(staleError?.contains("server_error") == true)

        // Pass 2 is slow; pass 3 overlaps it and must be skipped.
        PullGuardMockURLProtocol.setRoute(
            "GET /api/locations",
            PullGuardMockURLProtocol.emptyPage, delayMs: 250)
        async let slow = engine.syncAll(householdID: Self.householdID)
        try await Task.sleep(nanoseconds: 50_000_000)
        let ranOverlapping = await engine.syncAll(householdID: Self.householdID)
        #expect(!ranOverlapping, "overlapping syncAll must signal that it was skipped")
        #expect(engine.lastError == staleError,
                "a skipped pass must not touch lastError mid-flight")
        _ = await slow
    }
}

// MARK: - Router mock with per-route delay

/// Test-local URLProtocol (house pattern): method-qualified routes,
/// optional per-route delay, empty-page fallback.
final class PullGuardMockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var routes: [String: (body: Data, delayMs: Int)] = [:]
    static let lock = NSLock()

    static let emptyPage = Data(
        #"{"ok":true,"data":{"items":[],"cursor":0,"has_more":false}}"#.utf8)

    static func makeSession() -> URLSession {
        lock.lock()
        defer { lock.unlock() }
        routes = [:]
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PullGuardMockURLProtocol.self]
        return URLSession(configuration: config)
    }

    static func setRoute(_ key: String, _ body: Data, delayMs: Int = 0) {
        lock.lock()
        defer { lock.unlock() }
        routes[key] = (body: body, delayMs: delayMs)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let key = "\(request.httpMethod ?? "GET") \(request.url?.path ?? "")"
        Self.lock.lock()
        let stub = Self.routes[key]
        Self.lock.unlock()
        let body = stub?.body ?? Self.emptyPage
        let delayMs = stub?.delayMs ?? 0
        let url = request.url ?? URL(string: "https://test.local")!
        let deliver = { [weak self] in
            guard let self else { return }
            let response = HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: "HTTP/1.1",
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
    }

    override func stopLoading() {}
}
