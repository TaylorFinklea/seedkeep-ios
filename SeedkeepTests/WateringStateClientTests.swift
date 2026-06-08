import Testing
import Foundation
@testable import Seedkeep
import SeedkeepKit

/// Layer 6 — `SystemWateringStateClient` GET/PUT round-trip against a
/// `MockURLProtocol`-backed `SeedkeepClient`. Verifies:
///   - GET success → `.success(Date?)` parsed from `{ ok: true, data: { last_watering_notification_at: ... } }`
///   - GET success with null payload → `.success(nil)`
///   - GET network error → `.failure(...)`
///   - PUT success → `.success(Date)` and the request hits the documented route
///   - PUT failure → `.failure(...)`
///
/// Cross-device merge semantics (server `GREATEST(existing, scheduled_for)`)
/// are owned by the integration test in `seedkeep-server`; here we only
/// confirm the iOS client correctly serializes / deserializes either side.
///
/// Spec: `.docs/ai/specs/2026-06-07-phase-4c-native-warnings-design.md`
/// §7 (server piece) + §11 (Layer 6 — WateringStateClientTests).
@Suite("WateringStateClient — Phase 4C server I/O", .serialized)
struct WateringStateClientTests {

    private static let householdID = "hh_water_test"

    // MARK: - Helpers

    private static func makeClient(
        responseBody: Data,
        statusCode: Int = 200
    ) -> SeedkeepClient {
        let session = WSCMockURLProtocol.makeSession(
            responseBody: responseBody,
            statusCode: statusCode
        )
        return SeedkeepClient(
            configuration: .init(
                baseURL: URL(string: "https://test.local")!,
                session: session
            ),
            bearerToken: "test_token"
        )
    }

    // MARK: - GET round-trip

    @Test("GET success → parses last_watering_notification_at into Date")
    func getReturnsParsedDate() async {
        let iso = "2026-06-15T13:30:00.000Z"
        let body = Data(#"""
        {"ok":true,"data":{"last_watering_notification_at":"\#(iso)"}}
        """#.utf8)
        let client = Self.makeClient(responseBody: body)
        let wsc = SystemWateringStateClient(client: client)
        let result = await wsc.get(householdID: Self.householdID)
        switch result {
        case .success(let date):
            #expect(date != nil)
            // Round-trip via ISO8601 to confirm parsing.
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            #expect(formatter.string(from: date ?? Date.distantPast) == iso)
        case .failure(let error):
            Issue.record("expected success, got \(error)")
        }
    }

    @Test("GET success with null payload → .success(nil)")
    func getReturnsNilForNullPayload() async {
        let body = Data(#"""
        {"ok":true,"data":{"last_watering_notification_at":null}}
        """#.utf8)
        let client = Self.makeClient(responseBody: body)
        let wsc = SystemWateringStateClient(client: client)
        let result = await wsc.get(householdID: Self.householdID)
        switch result {
        case .success(let date):
            #expect(date == nil)
        case .failure(let error):
            Issue.record("expected .success(nil), got \(error)")
        }
    }

    @Test("GET HTTP 500 → .failure")
    func getHTTP500ReturnsFailure() async {
        // The client surfaces a decode_failed envelope error on 500 + empty
        // body — `Result.failure` is the contract regardless of which
        // specific error variant lands.
        let body = Data(#"""
        {"ok":false,"error":{"code":"server_error","message":"oops"}}
        """#.utf8)
        let client = Self.makeClient(responseBody: body, statusCode: 500)
        let wsc = SystemWateringStateClient(client: client)
        let result = await wsc.get(householdID: Self.householdID)
        switch result {
        case .success:
            Issue.record("expected .failure on HTTP 500")
        case .failure:
            // OK
            break
        }
    }

    // MARK: - PUT round-trip

    @Test("PUT success → .success with returned timestamp; route is POST /watering-state")
    func putRoundTripSuccess() async {
        let iso = "2026-06-15T13:30:00.000Z"
        let body = Data(#"""
        {"ok":true,"data":{"last_watering_notification_at":"\#(iso)"}}
        """#.utf8)
        let client = Self.makeClient(responseBody: body)
        let wsc = SystemWateringStateClient(client: client)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let scheduled = formatter.date(from: iso) ?? Date()
        let result = await wsc.put(
            householdID: Self.householdID,
            scheduledFor: scheduled
        )
        switch result {
        case .success(let date):
            #expect(date != nil)
        case .failure(let error):
            Issue.record("expected success, got \(error)")
        }
        // Verify the request hit the documented route.
        let captured = WSCMockURLProtocol.lastRequest()
        let path = captured?.url?.path
        #expect(path == "/api/households/\(Self.householdID)/watering-state")
        #expect(captured?.httpMethod == "POST")
    }

    @Test("PUT HTTP 500 → .failure")
    func putHTTP500ReturnsFailure() async {
        let body = Data(#"""
        {"ok":false,"error":{"code":"server_error","message":"oops"}}
        """#.utf8)
        let client = Self.makeClient(responseBody: body, statusCode: 500)
        let wsc = SystemWateringStateClient(client: client)
        let result = await wsc.put(
            householdID: Self.householdID,
            scheduledFor: Date()
        )
        switch result {
        case .success:
            Issue.record("expected .failure on HTTP 500")
        case .failure:
            // OK
            break
        }
    }
}

// MARK: - URLProtocol stub

/// Renamed clone of `PetStateEngineTests.MockURLProtocol` so the linker
/// sees only one symbol of each name. Captures the request for path /
/// method assertions.
final class WSCMockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var responseBody: Data = Data()
    nonisolated(unsafe) static var statusCode: Int = 200
    nonisolated(unsafe) static var captured: URLRequest?
    static let lock = NSLock()

    static func makeSession(responseBody: Data, statusCode: Int) -> URLSession {
        lock.lock()
        defer { lock.unlock() }
        Self.responseBody = responseBody
        Self.statusCode = statusCode
        Self.captured = nil
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [WSCMockURLProtocol.self]
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
        let status = Self.statusCode
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
