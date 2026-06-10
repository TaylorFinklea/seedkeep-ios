import Testing
import Foundation
import SwiftData
@testable import Seedkeep
import SeedkeepKit

/// Stabilization B3 · contract decision 7 — create enqueues send the
/// local row's id (seeds pattern) so the id is stable across the create
/// sync. This kills the temp-id swap class: queued child payloads stay
/// valid, offline create-then-delete deletes the right row, and the
/// planting-event reminder identifier (keyed by event id) survives the
/// sync so complete/delete can still cancel it.
@MainActor
@Suite("SyncEngine — client-supplied create ids (Stabilization B3)", .serialized)
struct ClientSuppliedCreateIDTests {

    private static let householdID = "hh_create_id"

    private static func makeContainer() -> ModelContainer {
        let schema = Schema(SeedkeepSchema.all)
        let config = ModelConfiguration(
            "clientSuppliedCreateIDTests",
            schema: schema,
            isStoredInMemoryOnly: true
        )
        return try! ModelContainer(for: schema, configurations: config)
    }

    private static func makeClient() -> SeedkeepClient {
        let session = BodyCaptureMockURLProtocol.makeSession()
        return SeedkeepClient(
            configuration: .init(
                baseURL: URL(string: "https://test.local")!,
                session: session
            ),
            bearerToken: "test_token"
        )
    }

    @Test("location create payload + POST body carry the local id; row id is stable after flush")
    func locationCreateSendsLocalID() async throws {
        let container = Self.makeContainer()
        let client = Self.makeClient()
        let engine = SyncEngine(client: client, container: container)

        let local = try engine.enqueueCreateLocation(
            name: "Shed", householdID: Self.householdID)
        #expect(local.id.hasPrefix("loc_local_"))

        // Queued payload carries the id.
        let context = ModelContext(container)
        let pending = try #require(try context.fetch(
            FetchDescriptor<LocalPendingWrite>()).first)
        let payload = try #require(JSONSerialization.jsonObject(
            with: Data(pending.payloadJSON.utf8)) as? [String: Any])
        #expect(payload["id"] as? String == local.id)

        // Server echoes the client id (decision 7 contract).
        BodyCaptureMockURLProtocol.setRoute(
            "POST /api/locations",
            Data("""
            {"ok":true,"data":{"location":{"id":"\(local.id)","household_id":"\(Self.householdID)","name":"Shed","sort_order":0,"created_at":1,"updated_at":2,"deleted_at":null}}}
            """.utf8)
        )
        try await engine.flushPending()

        // The POST body the server received carried the id.
        let body = try #require(
            BodyCaptureMockURLProtocol.capturedBody(method: "POST", path: "/api/locations"))
        let sent = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(sent["id"] as? String == local.id, "POST body must carry the client id")

        // Exactly one local row, same id, queue drained.
        let rows = try context.fetch(FetchDescriptor<LocalLocation>())
        #expect(rows.map(\.id) == [local.id])
        #expect(try context.fetch(FetchDescriptor<LocalPendingWrite>()).isEmpty)
    }

    @Test("planting-event create sends the local id; the row (and reminder key) survive the sync")
    func plantingEventCreateKeepsStableID() async throws {
        let container = Self.makeContainer()
        let client = Self.makeClient()
        let engine = SyncEngine(client: client, container: container)

        let local = try engine.enqueueCreatePlantingEvent(
            .init(kind: .sowing, planned_for: "2026-07-01"),
            householdID: Self.householdID
        )
        #expect(local.id.hasPrefix("pe_local_"))
        let localID = local.id

        BodyCaptureMockURLProtocol.setRoute(
            "POST /api/planting-events",
            Data("""
            {"ok":true,"data":{"planting_event":{"id":"\(localID)","household_id":"\(Self.householdID)","bed_id":null,"seed_id":null,"catalog_seed_id":null,"kind":"sowing","planned_for":"2026-07-01","completed_at":null,"notes":null,"x_feet":null,"y_feet":null,"created_at":1,"updated_at":2,"deleted_at":null}}}
            """.utf8)
        )
        try await engine.flushPending()

        let body = try #require(BodyCaptureMockURLProtocol.capturedBody(
            method: "POST", path: "/api/planting-events"))
        let sent = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(sent["id"] as? String == localID)

        // The row's id is unchanged — so the UN reminder identifier
        // (IdPrefix.event + id, scheduled at enqueue time) still matches
        // and a later complete/delete can cancel it.
        let context = ModelContext(container)
        let rows = try context.fetch(FetchDescriptor<LocalPlantingEvent>())
        #expect(rows.map(\.id) == [localID],
                "planting-event id must be stable across the create sync")
    }

    @Test("tag and bed create payloads carry the local id")
    func tagAndBedCreatePayloadsCarryID() async throws {
        let container = Self.makeContainer()
        let client = Self.makeClient()
        let engine = SyncEngine(client: client, container: container)

        let tag = try engine.enqueueCreateTag(
            name: "Heirloom", color: nil, householdID: Self.householdID)
        let bed = try engine.enqueueCreateBed(
            .init(name: "North bed"), householdID: Self.householdID)

        let context = ModelContext(container)
        let pending = try context.fetch(FetchDescriptor<LocalPendingWrite>())
        let byType = Dictionary(grouping: pending, by: \.entityType)

        let tagPayload = try #require(byType["tag"]?.first?.payloadJSON)
        let tagObj = try #require(JSONSerialization.jsonObject(
            with: Data(tagPayload.utf8)) as? [String: Any])
        #expect(tagObj["id"] as? String == tag.id)

        let bedPayload = try #require(byType["bed"]?.first?.payloadJSON)
        let bedObj = try #require(JSONSerialization.jsonObject(
            with: Data(bedPayload.utf8)) as? [String: Any])
        #expect(bedObj["id"] as? String == bed.id)
    }
}

// MARK: - Body-capturing router mock

/// Test-local URLProtocol (house pattern — see `RouterMockURLProtocol` /
/// `CatalogRouterMockURLProtocol`) that additionally captures request
/// BODIES. URLSession surfaces POST bodies to protocols via
/// `httpBodyStream`, so plain `request.httpBody` capture comes back nil —
/// this mock drains the stream.
final class BodyCaptureMockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var routes: [String: Data] = [:]
    nonisolated(unsafe) static var captured: [(method: String, path: String, body: Data?)] = []
    static let lock = NSLock()

    static let fallbackBody = Data(
        #"{"ok":true,"data":{"items":[],"cursor":0,"has_more":false}}"#.utf8)

    static func makeSession() -> URLSession {
        lock.lock()
        defer { lock.unlock() }
        routes = [:]
        captured = []
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [BodyCaptureMockURLProtocol.self]
        return URLSession(configuration: config)
    }

    static func setRoute(_ key: String, _ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        routes[key] = data
    }

    static func capturedBody(method: String, path: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return captured.last(where: { $0.method == method && $0.path == path })?.body
    }

    private static func drainBody(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufSize = 4096
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
        defer { buf.deallocate() }
        while stream.hasBytesAvailable {
            let n = stream.read(buf, maxLength: bufSize)
            if n <= 0 { break }
            data.append(buf, count: n)
        }
        return data
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let method = request.httpMethod ?? "GET"
        let path = request.url?.path ?? ""
        let body = Self.drainBody(of: request)
        Self.lock.lock()
        Self.captured.append((method: method, path: path, body: body))
        let responseBody = Self.routes["\(method) \(path)"] ?? Self.fallbackBody
        Self.lock.unlock()
        let url = request.url ?? URL(string: "https://test.local")!
        let response = HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: responseBody)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
