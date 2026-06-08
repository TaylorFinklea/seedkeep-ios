import Testing
import Foundation
import os
import SwiftData
@testable import Seedkeep
import SeedkeepKit

/// Layer 5 — exercises the `NotificationCenter.default` glue between
/// `SyncEngine` and `WeatherWarningsService`. When the engine performs
/// `enqueueCreate / enqueueUpdate / enqueueDelete` for a planting event,
/// it posts `.weatherWarningsActivePlantingsChanged` — the service's
/// debounced observer should fire.
///
/// We don't drive the service's observer directly here (the service's
/// 300ms debounce + actor isolation makes that a flaky-timing test).
/// Instead we attach a synchronous `NotificationCenter` observer in the
/// test and assert the post itself happens. Service-side debounce
/// behavior is covered in `WeatherWarningsServiceTests`.
///
/// Network stub mirrors `PetStateEngineTests`'s `MockURLProtocol` shape
/// (renamed to `ObsMockURLProtocol` to avoid linker collisions).
///
/// Spec: `.docs/ai/specs/2026-06-07-phase-4c-native-warnings-design.md`
/// §11 (Layer 5 — ActivePlantingsObserverTests).
@MainActor
@Suite("ActivePlantingsObserver — Phase 4C SyncEngine post integration", .serialized)
struct ActivePlantingsObserverTests {

    private static let householdID = "hh_obs_test"

    private static func makeContainer() -> ModelContainer {
        let schema = Schema([
            LocalForecastSnapshot.self,
            LocalPlantingEvent.self,
            LocalPetMoodSnapshot.self,
            LocalPetDeparture.self,
            LocalJournalEntry.self,
            LocalJournalChecklistItem.self,
            LocalJournalEntryPhoto.self,
            LocalSeed.self,
            LocalBed.self,
            LocalLocation.self,
            LocalTag.self,
            LocalSeedPhoto.self,
            LocalPendingWrite.self,
            LocalSyncCursor.self,
            LocalRecommendation.self,
            LocalAssistantThread.self,
            LocalAssistantMessage.self,
            LocalAssistantToolCall.self,
            LocalAssistantKeyStatus.self,
        ])
        let config = ModelConfiguration(
            "activePlantingsObserverTests-\(UUID().uuidString)",
            schema: schema,
            isStoredInMemoryOnly: true
        )
        return try! ModelContainer(for: schema, configurations: config)
    }

    private static func makeClient() -> SeedkeepClient {
        let session = ObsMockURLProtocol.makeSession(
            responseBody: Data(),
            statusCode: 200
        )
        return SeedkeepClient(
            configuration: .init(
                baseURL: URL(string: "https://test.local")!,
                session: session
            ),
            bearerToken: "test_token"
        )
    }

    // MARK: - Tests

    @Test("enqueueCreatePlantingEvent posts .weatherWarningsActivePlantingsChanged")
    func createPlantingEventPostsNotification() async throws {
        let container = Self.makeContainer()
        let engine = SyncEngine(client: Self.makeClient(), container: container)

        // Observer state — assigned BEFORE `enqueueCreate` so the post
        // can't race the observer registration.
        let bucket = NotificationBucket()
        let token = NotificationCenter.default.addObserver(
            forName: .weatherWarningsActivePlantingsChanged,
            object: nil,
            queue: nil
        ) { _ in
            bucket.markFired()
        }
        defer { NotificationCenter.default.removeObserver(token) }

        let input = SeedkeepClient.CreatePlantingEventInput(
            kind: .sowing,
            planned_for: "2026-07-01"
        )
        _ = try engine.enqueueCreatePlantingEvent(input, householdID: Self.householdID)

        #expect(bucket.fired)
    }

    @Test("enqueueUpdatePlantingEvent posts .weatherWarningsActivePlantingsChanged")
    func updatePlantingEventPostsNotification() async throws {
        let container = Self.makeContainer()
        let engine = SyncEngine(client: Self.makeClient(), container: container)

        // Pre-seed an active planting we can update.
        let input = SeedkeepClient.CreatePlantingEventInput(
            kind: .sowing,
            planned_for: "2026-07-01"
        )
        let created = try engine.enqueueCreatePlantingEvent(input, householdID: Self.householdID)

        let bucket = NotificationBucket()
        let token = NotificationCenter.default.addObserver(
            forName: .weatherWarningsActivePlantingsChanged,
            object: nil,
            queue: nil
        ) { _ in
            bucket.markFired()
        }
        defer { NotificationCenter.default.removeObserver(token) }

        let patch = SeedkeepClient.UpdatePlantingEventInput(notes: "new note")
        try engine.enqueueUpdatePlantingEvent(id: created.id, patch)

        #expect(bucket.fired)
    }

    @Test("enqueueDeletePlantingEvent posts .weatherWarningsActivePlantingsChanged")
    func deletePlantingEventPostsNotification() async throws {
        let container = Self.makeContainer()
        let engine = SyncEngine(client: Self.makeClient(), container: container)

        let input = SeedkeepClient.CreatePlantingEventInput(
            kind: .sowing,
            planned_for: "2026-07-01"
        )
        let created = try engine.enqueueCreatePlantingEvent(input, householdID: Self.householdID)

        let bucket = NotificationBucket()
        let token = NotificationCenter.default.addObserver(
            forName: .weatherWarningsActivePlantingsChanged,
            object: nil,
            queue: nil
        ) { _ in
            bucket.markFired()
        }
        defer { NotificationCenter.default.removeObserver(token) }

        try engine.enqueueDeletePlantingEvent(id: created.id)

        #expect(bucket.fired)
    }
}

// MARK: - Synchronous notification bucket

/// `NotificationCenter.addObserver(forName:object:queue:using:)` with
/// `queue: nil` runs the callback synchronously on the posting thread.
/// The bucket is lock-guarded so the closure (which the compiler treats
/// as nonisolated) can call into it without a `@MainActor` hop.
final class NotificationBucket: @unchecked Sendable {
    private let state: OSAllocatedUnfairLock<Bool>
    init() {
        self.state = OSAllocatedUnfairLock(initialState: false)
    }
    var fired: Bool { state.withLock { $0 } }
    func markFired() { state.withLock { $0 = true } }
}

// MARK: - URLProtocol stub

/// Renamed clone of `PetStateEngineTests.MockURLProtocol` so the linker
/// doesn't see two symbols with the same name. Returns 200 + empty body
/// for every request, which is enough to satisfy the SeedkeepKit client
/// methods these tests don't actually invoke (the enqueue paths are
/// purely local).
final class ObsMockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var responseBody: Data = Data()
    nonisolated(unsafe) static var statusCode: Int = 200
    static let lock = NSLock()

    static func makeSession(responseBody: Data, statusCode: Int) -> URLSession {
        lock.lock()
        defer { lock.unlock() }
        Self.responseBody = responseBody
        Self.statusCode = statusCode
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ObsMockURLProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
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
