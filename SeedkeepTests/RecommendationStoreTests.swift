import Foundation
import SwiftData
import Testing
@testable import Seedkeep
import SeedkeepKit

/// Contract coverage for the recommendation client/store seam.
///
/// The production store deliberately degrades to its cached SwiftData value
/// when the recommendation service is unavailable. These tests keep that
/// behavior observable without adding a second transport protocol: the
/// existing SeedkeepClient.Configuration URLSession injection routes through
/// the private suite-local RecommendationRouterMockURLProtocol fixture.
@MainActor
@Suite("RecommendationStore — request, persistence, pending, and error contracts", .serialized)
struct RecommendationStoreTests {

    private static let baseURL = URL(string: "https://test.local")!

    private static func makeStore(
        routes: [String: Data] = [:],
        sequences: [String: [Data]] = [:],
        fallbackBody: Data = Data(),
        fallbackStatus: Int = 200
    ) -> (RecommendationStore, ModelContainer) {
        let session = RecommendationRouterMockURLProtocol.makeSession(
            routes: routes,
            sequences: sequences,
            fallbackBody: fallbackBody,
            fallbackStatus: fallbackStatus
        )
        let client = SeedkeepClient(
            configuration: .init(baseURL: baseURL, session: session),
            bearerToken: "recommendation-test-token"
        )
        let container = makeTestContainer(name: "recommendation-store-\(UUID().uuidString)")
        return (RecommendationStore(client: client, container: container), container)
    }

    private static func recommendation(
        id: String,
        verdict: String = "plant_now",
        computedAt: Int64 = 1_725_000_000_000
    ) -> [String: Any] {
        [
            "catalogSeedId": id,
            "locationSignature": "zip:66204",
            "computedAt": computedAt,
            "source": "rule",
            "confidence": 0.92,
            "verdict": verdict,
            "recommendedRange": ["start": "2026-09-04", "end": "2026-09-18"],
            "indoorRange": NSNull(),
            "dailyScores": [
                "anchorDate": "2026-09-01",
                "scores": [0.9, 0.8, 0.7]
            ],
            "reasoning": "Warm soil and a clear planting window.",
            "inputsUsed": ["location", "forecast"]
        ]
    }

    private static func successEnvelope(_ value: Any) -> Data {
        try! JSONSerialization.data(withJSONObject: ["ok": true, "data": value])
    }

    private static func failureEnvelope(code: String, message: String) -> Data {
        try! JSONSerialization.data(withJSONObject: [
            "ok": false,
            "error": ["code": code, "message": message]
        ])
    }

    private static func persistedRecommendation(
        _ container: ModelContainer,
        id: String
    ) throws -> LocalRecommendation? {
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<LocalRecommendation>(
            predicate: #Predicate { $0.catalogSeedID == id }
        )
        return try context.fetch(descriptor).first
    }

    @Test("single recommendation request decodes DTO and persists one SwiftData row")
    func singleRefreshPersistsDTO() async throws {
        let response = Self.successEnvelope(Self.recommendation(id: "cat-tomato"))
        let (store, container) = Self.makeStore(
            routes: ["GET /api/recommendations/cat-tomato": response]
        )

        await store.refresh(catalogSeedID: "cat-tomato")

        let requests = RecommendationRouterMockURLProtocol.capturedMethodPaths()
        #expect(requests.count == 1)
        #expect(requests.first?.method == "GET")
        #expect(requests.first?.path == "/api/recommendations/cat-tomato")
        let persisted = try #require(try Self.persistedRecommendation(container, id: "cat-tomato"))
        #expect(persisted.verdict == "plant_now")
        #expect(persisted.locationSignature == "zip:66204")
        #expect(persisted.dailyScores == [0.9, 0.8, 0.7])
        #expect(store.updateEpoch == 1)
    }

    @Test("refresh upserts a changed DTO instead of duplicating the catalog row")
    func refreshUpsertsExistingRow() async throws {
        let first = Self.successEnvelope(Self.recommendation(
            id: "cat-pepper", verdict: "plant_soon", computedAt: 1
        ))
        let second = Self.successEnvelope(Self.recommendation(
            id: "cat-pepper", verdict: "plant_now", computedAt: 2
        ))
        let (store, container) = Self.makeStore(
            sequences: ["/api/recommendations/cat-pepper": [first, second]]
        )

        await store.refresh(catalogSeedID: "cat-pepper")
        await store.refresh(catalogSeedID: "cat-pepper")

        let context = ModelContext(container)
        let rows = try context.fetch(FetchDescriptor<LocalRecommendation>(
            predicate: #Predicate { $0.catalogSeedID == "cat-pepper" }
        ))
        #expect(rows.count == 1)
        #expect(rows.first?.verdict == "plant_now")
        #expect(rows.first?.computedAt == 2)
        #expect(store.updateEpoch == 2)
    }

    @Test("bulk refresh retries IDs returned as pending on the next call")
    func bulkRefreshCarriesPendingIDsForward() async throws {
        let first = Self.successEnvelope([
            "recommendations": [Self.recommendation(id: "cat-tomato")],
            "pending": ["cat-pepper"]
        ])
        let second = Self.successEnvelope([
            "recommendations": [Self.recommendation(id: "cat-pepper", verdict: "plant_soon")],
            "pending": []
        ])
        let (store, container) = Self.makeStore(
            sequences: ["/api/recommendations/bulk": [first, second]]
        )

        await store.bulkRefresh(catalogSeedIDs: ["cat-tomato"])
        await store.bulkRefresh(catalogSeedIDs: [])

        let requests = RecommendationRouterMockURLProtocol.capturedMethodPaths()
        #expect(requests.count == 2)
        #expect(requests.allSatisfy {
            $0.method == "POST" && $0.path == "/api/recommendations/bulk"
        })
        let bodies = RecommendationRouterMockURLProtocol.capturedBodies()
        let firstIDs = try #require(try Self.ids(from: bodies[0]))
        let secondIDs = try #require(try Self.ids(from: bodies[1]))
        #expect(Set(firstIDs) == ["cat-tomato"])
        #expect(Set(secondIDs) == ["cat-pepper"])
        let pepper = try Self.persistedRecommendation(container, id: "cat-pepper")
        #expect(pepper?.verdict == "plant_soon")
    }

    @Test("no_household_location sets the location prompt and does not persist a partial row")
    func missingLocationIsObservableAndNonPersistent() async throws {
        let response = Self.failureEnvelope(
            code: "no_household_location",
            message: "Set a home location first."
        )
        let (store, container) = Self.makeStore(
            routes: ["GET /api/recommendations/cat-bean": response],
            fallbackStatus: 400
        )

        await store.refresh(catalogSeedID: "cat-bean")

        #expect(store.needsHomeLocation)
        #expect(store.updateEpoch == 0)
        let persisted = try Self.persistedRecommendation(container, id: "cat-bean")
        #expect(persisted == nil)
    }

    @Test("server errors leave cached recommendation untouched")
    func serverErrorDoesNotEraseCachedValue() async throws {
        let cached = Self.successEnvelope(Self.recommendation(id: "cat-squash"))
        let failure = Self.failureEnvelope(code: "service_unavailable", message: "Try again later.")
        let (store, container) = Self.makeStore(
            sequences: ["/api/recommendations/cat-squash": [cached, failure]],
            fallbackStatus: 503
        )

        await store.refresh(catalogSeedID: "cat-squash")
        await store.refresh(catalogSeedID: "cat-squash")

        let persisted = try #require(try Self.persistedRecommendation(container, id: "cat-squash"))
        #expect(persisted.verdict == "plant_now")
        #expect(store.updateEpoch == 1)
        #expect(!store.needsHomeLocation)
    }

    private static func ids(from body: Data?) throws -> [String]? {
        let body = try #require(body)
        let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        return object["catalogSeedIds"] as? [String]
    }
}

/// A suite-local URLProtocol fixture keeps recommendation request state isolated
/// from the URLProtocol fixtures used by unrelated test suites.
private final class RecommendationRouterMockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) private static var routes: [String: Data] = [:]
    nonisolated(unsafe) private static var sequences: [String: [Data]] = [:]
    nonisolated(unsafe) private static var sequenceCursors: [String: Int] = [:]
    nonisolated(unsafe) private static var fallbackBody = Data()
    nonisolated(unsafe) private static var fallbackStatus = 200
    nonisolated(unsafe) private static var capturedRequests: [URLRequest] = []
    private static let lock = NSLock()

    static func makeSession(
        routes: [String: Data],
        sequences: [String: [Data]],
        fallbackBody: Data,
        fallbackStatus: Int
    ) -> URLSession {
        lock.lock()
        Self.routes = routes
        Self.sequences = sequences
        Self.sequenceCursors = [:]
        Self.fallbackBody = fallbackBody
        Self.fallbackStatus = fallbackStatus
        Self.capturedRequests = []
        lock.unlock()

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Self.self]
        return URLSession(configuration: config)
    }

    static func capturedMethodPaths() -> [(method: String, path: String)] {
        lock.lock()
        defer { lock.unlock() }
        return capturedRequests.map {
            (method: $0.httpMethod ?? "", path: $0.url?.path ?? "")
        }
    }

    static func capturedBodies() -> [Data?] {
        lock.lock()
        defer { lock.unlock() }
        return capturedRequests.map(\.httpBody)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        var capturedRequest = request
        if capturedRequest.httpBody == nil, let stream = capturedRequest.httpBodyStream {
            stream.open()
            var bytes = [UInt8](repeating: 0, count: 4_096)
            var body = Data()
            while stream.hasBytesAvailable {
                let count = stream.read(&bytes, maxLength: bytes.count)
                guard count > 0 else { break }
                body.append(bytes, count: count)
            }
            stream.close()
            capturedRequest.httpBody = body
        }
        Self.capturedRequests.append(capturedRequest)

        let path = request.url?.path ?? ""
        let method = request.httpMethod ?? "GET"
        let body: Data
        if let sequence = Self.sequences[path], !sequence.isEmpty {
            let cursor = Self.sequenceCursors[path] ?? 0
            let index = min(cursor, sequence.count - 1)
            body = sequence[index]
            Self.sequenceCursors[path] = cursor + 1
        } else if let methodRoute = Self.routes["\(method) \(path)"] {
            body = methodRoute
        } else if let route = Self.routes[path] {
            body = route
        } else {
            body = Self.fallbackBody
        }
        let status = Self.fallbackStatus
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
