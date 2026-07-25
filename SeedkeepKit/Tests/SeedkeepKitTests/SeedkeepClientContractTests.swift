import Testing
import Foundation
@testable import SeedkeepKit

/// M4 Phase 3a — Table-driven SeedkeepClient request-contract tests.
///
/// Catches the %3F regression class (build 33: query-string characters
/// percent-encoded INTO the URL path). One shared `ContractStubURLProtocol`
/// captures every outgoing `URLRequest`; each table row asserts:
///   - `httpMethod` matches
///   - `url.path` contains NO "%3F" and no raw "?" in the path component
///   - `queryItems` match the expected set
///   - key headers are present (`Idempotency-Key` where sent, `since_id`
///     on delta pulls)
///
/// Mirrors the `StabilizationB3WireTests` precedent. ADDITIVE — no client
/// source changes.
///
/// The suite is `.serialized` because the stub uses global static state.
@Suite("SeedkeepClient — request contract (M4 Phase 3a)", .serialized)
struct SeedkeepClientContractTests {

    // MARK: - Helpers

    private static let baseURL = URL(string: "https://api.test.local")!

    private func makeClient(responseBody: Data? = nil) -> SeedkeepClient {
        let session = ContractStub.makeSession(responseBody: responseBody)
        return SeedkeepClient(
            configuration: .init(
                baseURL: Self.baseURL,
                session: session
            ),
            bearerToken: "tok_test"
        )
    }

    /// Assert the captured request has the expected method and no %3F / raw "?" in its path.
    private func assertRequest(
        method: String,
        path expectedPath: String,
        queryItems expectedItems: [URLQueryItem] = [],
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let req = try #require(
            ContractStub.lastRequest(),
            "no request was captured",
            sourceLocation: sourceLocation
        )
        #expect(
            req.httpMethod == method,
            "expected method \(method), got \(req.httpMethod ?? "nil")",
            sourceLocation: sourceLocation
        )

        let urlPath = req.url?.path ?? ""
        #expect(
            !urlPath.contains("%3F"),
            "path contains percent-encoded '?' (%3F) — regression class: \(urlPath)",
            sourceLocation: sourceLocation
        )
        #expect(
            !urlPath.contains("?"),
            "path contains raw '?' — query string leaked into path: \(urlPath)",
            sourceLocation: sourceLocation
        )
        #expect(
            urlPath == expectedPath,
            "expected path \(expectedPath), got \(urlPath)",
            sourceLocation: sourceLocation
        )

        let components = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)
        let actualItems = components?.queryItems ?? []

        for expected in expectedItems {
            let found = actualItems.first(where: { $0.name == expected.name })
            #expect(
                found != nil,
                "missing query item '\(expected.name)'",
                sourceLocation: sourceLocation
            )
            #expect(
                found?.value == expected.value,
                "query item '\(expected.name)': expected '\(expected.value ?? "nil")', got '\(found?.value ?? "nil")'",
                sourceLocation: sourceLocation
            )
        }
    }

    // MARK: - Delta-pull methods

    @Test("seeds delta-pull: GET /api/seeds, since + since_id query items, no %3F in path")
    func seedsDeltaPull() async throws {
        let client = makeClient()
        _ = try? await client.seeds(since: 1_000, sinceID: "seed_abc", limit: 50)
        try assertRequest(
            method: "GET",
            path: "/api/seeds",
            queryItems: [
                .init(name: "since", value: "1000"),
                .init(name: "since_id", value: "seed_abc"),
                .init(name: "limit", value: "50"),
            ]
        )
    }

    @Test("seeds delta-pull without sinceID: since_id absent from query")
    func seedsDeltaPullNoSinceID() async throws {
        let client = makeClient()
        _ = try? await client.seeds(since: 0)
        let req = try #require(ContractStub.lastRequest())
        let components = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)
        let items = components?.queryItems ?? []
        #expect(!items.contains(where: { $0.name == "since_id" }),
                "since_id must be absent when sinceID is nil")
    }

    @Test("locations delta-pull: GET /api/locations, since + since_id, no %3F")
    func locationsDeltaPull() async throws {
        let client = makeClient()
        _ = try? await client.locations(since: 500, sinceID: "loc_zzz", limit: 25)
        try assertRequest(
            method: "GET",
            path: "/api/locations",
            queryItems: [
                .init(name: "since", value: "500"),
                .init(name: "since_id", value: "loc_zzz"),
                .init(name: "limit", value: "25"),
            ]
        )
    }

    @Test("tags delta-pull: GET /api/tags, since + since_id, no %3F")
    func tagsDeltaPull() async throws {
        let client = makeClient()
        _ = try? await client.tags(since: 200, sinceID: "tag_xyz")
        try assertRequest(
            method: "GET",
            path: "/api/tags",
            queryItems: [
                .init(name: "since", value: "200"),
                .init(name: "since_id", value: "tag_xyz"),
            ]
        )
    }

    @Test("beds delta-pull: GET /api/beds, since + since_id, no %3F")
    func bedsDeltaPull() async throws {
        let client = makeClient()
        _ = try? await client.beds(since: 100, sinceID: "bed_abc")
        try assertRequest(
            method: "GET",
            path: "/api/beds",
            queryItems: [
                .init(name: "since", value: "100"),
                .init(name: "since_id", value: "bed_abc"),
            ]
        )
    }

    @Test("plantingEvents delta-pull: GET /api/planting-events, since + since_id, no %3F")
    func plantingEventsDeltaPull() async throws {
        let client = makeClient()
        _ = try? await client.plantingEvents(since: 300, sinceID: "pe_abc")
        try assertRequest(
            method: "GET",
            path: "/api/planting-events",
            queryItems: [
                .init(name: "since", value: "300"),
                .init(name: "since_id", value: "pe_abc"),
            ]
        )
    }

    @Test("journalFeed delta-pull: GET /api/journal, since + since_id, no %3F")
    func journalFeedDeltaPull() async throws {
        let responseBody = Data(#"""
        {"ok":true,"data":{"items":[],"cursor":0,"has_more":false,"count":0}}
        """#.utf8)
        let client = makeClient(responseBody: responseBody)
        _ = try? await client.journalFeed(since: 400, sinceID: "je_abc")
        try assertRequest(
            method: "GET",
            path: "/api/journal",
            queryItems: [
                .init(name: "since", value: "400"),
                .init(name: "since_id", value: "je_abc"),
            ]
        )
    }

    @Test("assistantThreads delta-pull: GET /api/assistant/threads, since + since_id, no %3F in path")
    func assistantThreadsDeltaPull() async throws {
        // This is the original %3F culprit from build 33: a since_id with
        // special characters could be percent-encoded into the path component
        // if URLComponents merges query and path incorrectly.
        let responseBody = Data(#"""
        {"ok":true,"data":{"items":[],"cursor":0,"has_more":false}}
        """#.utf8)
        let client = makeClient(responseBody: responseBody)
        _ = try? await client.assistantThreads(since: 600, sinceID: "thread_abc")
        try assertRequest(
            method: "GET",
            path: "/api/assistant/threads",
            queryItems: [
                .init(name: "since", value: "600"),
                .init(name: "since_id", value: "thread_abc"),
            ]
        )
    }

    @Test("assistantThreads delta-pull with zero since: path is clean, no %3F")
    func assistantThreadsDeltaPullZeroSince() async throws {
        let responseBody = Data(#"""
        {"ok":true,"data":{"items":[],"cursor":0,"has_more":false}}
        """#.utf8)
        let client = makeClient(responseBody: responseBody)
        _ = try? await client.assistantThreads(since: 0)
        let req = try #require(ContractStub.lastRequest())
        let path = req.url?.path ?? ""
        #expect(!path.contains("%3F"), "path must not contain percent-encoded '?': \(path)")
        #expect(!path.contains("?"), "raw '?' must not appear in path: \(path)")
        #expect(path == "/api/assistant/threads",
                "unexpected path: \(path)")
    }

    @Test("petDepartures delta-pull: GET /api/pets/departures, since + since_id, no %3F")
    func petDeparturesDeltaPull() async throws {
        let client = makeClient()
        _ = try? await client.petDepartures(since: 700, sinceID: "dep_abc", limit: 20)
        try assertRequest(
            method: "GET",
            path: "/api/pets/departures",
            queryItems: [
                .init(name: "since", value: "700"),
                .init(name: "since_id", value: "dep_abc"),
                .init(name: "limit", value: "20"),
            ]
        )
    }

    @Test("catalogCorrectionsMine delta-pull: GET /api/catalog/corrections/mine, since + since_id, no %3F")
    func catalogCorrectionsMine() async throws {
        let client = makeClient()
        _ = try? await client.catalogCorrectionsMine(since: 800, sinceID: "corr_abc", limit: 10)
        try assertRequest(
            method: "GET",
            path: "/api/catalog/corrections/mine",
            queryItems: [
                .init(name: "since", value: "800"),
                .init(name: "since_id", value: "corr_abc"),
                .init(name: "limit", value: "10"),
            ]
        )
    }

    // MARK: - Catalog correction POST/PUT/escalate/notified

    @Test("submitCatalogFeedback: POST /api/catalog/:id/feedback, Idempotency-Key header present when provided")
    func submitCatalogFeedbackWithIdempotencyKey() async throws {
        let feedbackResponse = Data(#"""
        {"ok":true,"data":{"id":"fb_1","status":"open"}}
        """#.utf8)
        let client = makeClient(responseBody: feedbackResponse)
        _ = try? await client.submitCatalogFeedback(
            catalogID: "cs_tomato",
            body: "Days to maturity is wrong",
            idempotencyKey: "idem_key_abc"
        )
        let req = try #require(ContractStub.lastRequest())
        #expect(req.httpMethod == "POST")
        let path = req.url?.path ?? ""
        #expect(path == "/api/catalog/cs_tomato/feedback",
                "unexpected path: \(path)")
        #expect(!path.contains("%3F"), "path must not contain %3F: \(path)")
        #expect(!path.contains("?"), "raw '?' must not appear in path: \(path)")
        #expect(req.value(forHTTPHeaderField: "Idempotency-Key") == "idem_key_abc",
                "Idempotency-Key header must be present with the supplied key")
    }

    @Test("submitCatalogFeedback without idempotencyKey: Idempotency-Key header absent")
    func submitCatalogFeedbackNoIdempotencyKey() async throws {
        let feedbackResponse = Data(#"""
        {"ok":true,"data":{"id":"fb_2","status":"open"}}
        """#.utf8)
        let client = makeClient(responseBody: feedbackResponse)
        _ = try? await client.submitCatalogFeedback(
            catalogID: "cs_pepper",
            body: "Notes correction"
        )
        let req = try #require(ContractStub.lastRequest())
        #expect(req.value(forHTTPHeaderField: "Idempotency-Key") == nil,
                "Idempotency-Key header must be absent when no key supplied")
    }

    @Test("editOpenCorrection: PUT /api/catalog/:catalogID/corrections/:correctionID, no %3F")
    func editOpenCorrection() async throws {
        let correctionResponse = Data(#"""
        {"ok":true,"data":{"correction":{"id":"corr_1","catalog_seed_id":"cs_x","catalog_seed_name":"Tomato","field_name":"days_to_maturity_min","value_type":"integer","suggested_value":"75","client_seen_value":null,"body":null,"status":"open","ai_review_score":null,"ai_notes":null,"dismissed_reason":null,"conflict_with_id":null,"user_acknowledged_bounds":false,"created_at":1,"reviewed_at":null,"applied_at":null,"escalated_at":null,"updated_at":2,"deleted_at":null}}}
        """#.utf8)
        let client = makeClient(responseBody: correctionResponse)
        _ = try? await client.editOpenCorrection(
            catalogID: "cs_x",
            correctionID: "corr_1",
            suggestedValue: "75"
        )
        let req = try #require(ContractStub.lastRequest())
        #expect(req.httpMethod == "PUT")
        let path = req.url?.path ?? ""
        #expect(path == "/api/catalog/cs_x/corrections/corr_1",
                "unexpected path: \(path)")
        #expect(!path.contains("%3F"), "path must not contain %3F: \(path)")
        #expect(!path.contains("?"), "raw '?' must not appear in path: \(path)")
    }

    @Test("escalateDismissedCorrection: POST /api/catalog/:catalogID/corrections/:correctionID/escalate, no %3F")
    func escalateDismissedCorrection() async throws {
        let correctionResponse = Data(#"""
        {"ok":true,"data":{"correction":{"id":"corr_2","catalog_seed_id":"cs_y","catalog_seed_name":"Pepper","field_name":null,"value_type":null,"suggested_value":null,"client_seen_value":null,"body":"free form","status":"reviewed","ai_review_score":null,"ai_notes":null,"dismissed_reason":"user_escalated","conflict_with_id":null,"user_acknowledged_bounds":false,"created_at":1,"reviewed_at":2,"applied_at":null,"escalated_at":2,"updated_at":2,"deleted_at":null}}}
        """#.utf8)
        let client = makeClient(responseBody: correctionResponse)
        _ = try? await client.escalateDismissedCorrection(
            catalogID: "cs_y",
            correctionID: "corr_2"
        )
        let req = try #require(ContractStub.lastRequest())
        #expect(req.httpMethod == "POST")
        let path = req.url?.path ?? ""
        #expect(path == "/api/catalog/cs_y/corrections/corr_2/escalate",
                "unexpected path: \(path)")
        #expect(!path.contains("%3F"), "path must not contain %3F: \(path)")
        #expect(!path.contains("?"), "raw '?' must not appear in path: \(path)")
    }

    @Test("catalogCorrectionNotified GET: GET /api/catalog/corrections/:id/notified, no %3F")
    func catalogCorrectionNotifiedGet() async throws {
        let responseBody = Data(#"""
        {"ok":true,"data":{"devices":["device_abc"]}}
        """#.utf8)
        let client = makeClient(responseBody: responseBody)
        _ = try? await client.catalogCorrectionNotified(correctionID: "corr_3")
        let req = try #require(ContractStub.lastRequest())
        #expect(req.httpMethod == "GET")
        let path = req.url?.path ?? ""
        #expect(path == "/api/catalog/corrections/corr_3/notified",
                "unexpected path: \(path)")
        #expect(!path.contains("%3F"), "path must not contain %3F: \(path)")
        #expect(!path.contains("?"), "raw '?' must not appear in path: \(path)")
    }

    @Test("markCatalogCorrectionNotified POST: POST /api/catalog/corrections/:id/notified, no %3F")
    func markCatalogCorrectionNotifiedPost() async throws {
        let responseBody = Data(#"""
        {"ok":true,"data":{"inserted":true}}
        """#.utf8)
        let client = makeClient(responseBody: responseBody)
        _ = try? await client.markCatalogCorrectionNotified(
            correctionID: "corr_4",
            deviceID: "device_xyz"
        )
        let req = try #require(ContractStub.lastRequest())
        #expect(req.httpMethod == "POST")
        let path = req.url?.path ?? ""
        #expect(path == "/api/catalog/corrections/corr_4/notified",
                "unexpected path: \(path)")
        #expect(!path.contains("%3F"), "path must not contain %3F: \(path)")
        #expect(!path.contains("?"), "raw '?' must not appear in path: \(path)")
    }

    // MARK: - Account deletion

    /// Path/method only — the required `cloudkit_disposition` body is
    /// pinned key-by-key in `AccountDeletionTransferClientTests`, whose
    /// stub drains `httpBodyStream`. This stub does not capture bodies.
    @Test("deleteAccount: DELETE /api/me, no %3F in path")
    func deleteAccount() async throws {
        let responseBody = Data(#"""
        {"ok":true,"data":{"deleted":true}}
        """#.utf8)
        let client = makeClient(responseBody: responseBody)
        _ = try? await client.deleteAccount(
            disposition: .noCloudKitGarden,
            deletionReceiptHash: String(repeating: "d", count: 64)
        )
        try assertRequest(
            method: "DELETE",
            path: "/api/me"
        )
    }

    // MARK: - Parametric path cleanness

    @Test("assistantThread detail GET: path has no %3F, id in path not in query")
    func assistantThreadDetailPathClean() async throws {
        let responseBody = Data(#"""
        {"ok":true,"data":{"id":"t_1","household_id":"hh","title":"Thread","thread_kind":"chat","created_at":1,"updated_at":2,"deleted_at":null,"messages":[]}}
        """#.utf8)
        let client = makeClient(responseBody: responseBody)
        _ = try? await client.assistantThread(id: "t_1")
        let req = try #require(ContractStub.lastRequest())
        let path = req.url?.path ?? ""
        #expect(!path.contains("%3F"), "path must not contain %3F: \(path)")
        #expect(!path.contains("?"), "raw '?' must not appear in path: \(path)")
        #expect(path == "/api/assistant/threads/t_1", "unexpected path: \(path)")
    }
}

// MARK: - Shared single-capture URLProtocol stub

/// Captures the most-recent outgoing `URLRequest` for method/path/query
/// assertions. Must be top-level (not nested) so URLSession can register
/// it. Tests that use this stub run in the `.serialized` suite above
/// to avoid static-state contamination between concurrent runs.
final class ContractStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var captured: URLRequest?
    nonisolated(unsafe) static var responseBody: Data = Data(
        #"{"ok":true,"data":{"items":[],"cursor":0,"has_more":false}}"#.utf8)
    static let lock = NSLock()

    static func makeSession(responseBody: Data? = nil) -> URLSession {
        lock.lock()
        defer { lock.unlock() }
        Self.captured = nil
        Self.responseBody = responseBody ?? Data(
            #"{"ok":true,"data":{"items":[],"cursor":0,"has_more":false}}"#.utf8)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ContractStub.self]
        return URLSession(configuration: config)
    }

    static func lastRequest() -> URLRequest? {
        lock.lock()
        defer { lock.unlock() }
        return captured
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.captured = request
        let body = Self.responseBody
        Self.lock.unlock()
        let url = request.url ?? URL(string: "https://test.local")!
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
