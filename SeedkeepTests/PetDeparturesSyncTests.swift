import Testing
import Foundation
import SwiftData
@testable import Seedkeep
import SeedkeepKit

/// Tests for the Phase 5.1.2 sync wiring around `pet_departures`:
///
/// 1. `syncAll` pulls the `GET /api/pets/departures` feed strictly **after**
///    `GET /api/planting-events`. The parent planting (with its `pet_*`
///    identity columns) must already exist locally when a departure row
///    for that planting arrives — otherwise `LocalPetDeparture`'s
///    plantingEventID foreign reference would dangle.
/// 2. The `pet_departures` `LocalSyncCursor` row tracks the latest
///    `cursor` returned by the route.
/// 3. When the planting-events feed surfaces a tombstone (`deleted_at`
///    non-NULL) for a planting whose pet had materialized
///    `LocalPetMoodSnapshot` rows, the cascade in
///    `cleanupPlantingEventChildren` hard-deletes those snapshots
///    (snapshots are iOS-only and never round-trip the server).
@MainActor
@Suite("SyncEngine — pet_departures pull + cascade (Phase 5.1.2)", .serialized)
struct PetDeparturesSyncTests {

    // MARK: - Fixture

    private static let householdID = "hh_sync"

    private static func makeContainer() -> ModelContainer {
        let schema = Schema(SeedkeepSchema.all)
        let config = ModelConfiguration(
            "petDeparturesSyncTests",
            schema: schema,
            isStoredInMemoryOnly: true
        )
        return try! ModelContainer(for: schema, configurations: config)
    }

    /// Standard `{ ok: true, data: { items: [], cursor: 0, has_more: false } }`
    /// empty-page envelope used to short-circuit every pull endpoint we
    /// aren't exercising in a given test.
    private static let emptyEnvelope = Data(
        #"{"ok":true,"data":{"items":[],"cursor":0,"has_more":false}}"#.utf8
    )

    /// Build a `RouterMockURLProtocol`-backed client. The router lets each
    /// test return route-specific JSON without re-stubbing the whole API
    /// surface — every unhandled route just gets the empty-page envelope.
    private static func makeRoutedClient(
        routes: [String: Data] = [:]
    ) -> SeedkeepClient {
        let session = RouterMockURLProtocol.makeSession(
            routes: routes,
            fallbackBody: emptyEnvelope,
            fallbackStatus: 200
        )
        return SeedkeepClient(
            configuration: .init(
                baseURL: URL(string: "https://test.local")!,
                session: session
            ),
            bearerToken: "test_token"
        )
    }

    // MARK: - Test 1: Ordering invariant

    @Test("pullPetDepartures runs after pullPlantingEvents inside syncAll")
    func departuresPulledAfterPlantingEvents() async {
        let container = Self.makeContainer()
        let client = Self.makeRoutedClient()
        let engine = SyncEngine(client: client, container: container)

        RouterMockURLProtocol.resetCapture()
        await engine.syncAll(householdID: Self.householdID)

        let captured = RouterMockURLProtocol.capturedPaths()
        let plantingIdx = captured.firstIndex(where: {
            $0 == "/api/planting-events"
        })
        let departuresIdx = captured.firstIndex(where: {
            $0 == "/api/pets/departures"
        })
        #expect(plantingIdx != nil, "syncAll did not call /api/planting-events")
        #expect(departuresIdx != nil, "syncAll did not call /api/pets/departures")
        if let p = plantingIdx, let d = departuresIdx {
            #expect(p < d, "pet_departures pulled before planting_events — parent rows wouldn't exist yet")
        }
    }

    // MARK: - Test 2: Cursor correctness

    @Test("syncAll persists the pet_departures cursor returned by the route")
    func cursorPersistedAfterPull() async {
        let container = Self.makeContainer()
        // Route response: one populated departure + cursor=1717000000000.
        let now: Int64 = 1_717_000_000_000
        let routeBody = Data("""
        {
          "ok": true,
          "data": {
            "items": [
              {
                "planting_event_id": "pe_dep_cursor",
                "household_id": "\(Self.householdID)",
                "goodbye_note": null,
                "reason": "wilted_too_long",
                "departed_at": \(now),
                "created_at": \(now),
                "updated_at": \(now),
                "deleted_at": null
              }
            ],
            "cursor": \(now),
            "has_more": false
          }
        }
        """.utf8)
        let client = Self.makeRoutedClient(routes: [
            "/api/pets/departures": routeBody
        ])
        let engine = SyncEngine(client: client, container: container)

        await engine.syncAll(householdID: Self.householdID)

        // Assert cursor row exists with the right watermark.
        let context = ModelContext(container)
        let key = LocalSyncCursor.key(
            householdID: Self.householdID,
            kind: "pet_departures"
        )
        let cursorDescriptor = FetchDescriptor<LocalSyncCursor>(
            predicate: #Predicate { $0.id == key }
        )
        let cursor = try? context.fetch(cursorDescriptor).first
        #expect(cursor?.cursor == now)

        // The departure row should also have landed.
        let depDescriptor = FetchDescriptor<LocalPetDeparture>(
            predicate: #Predicate { $0.plantingEventID == "pe_dep_cursor" }
        )
        let rows = (try? context.fetch(depDescriptor)) ?? []
        #expect(rows.count == 1)
        #expect(rows.first?.reason == "wilted_too_long")
        #expect(rows.first?.departedAt == now)
    }

    // MARK: - Test 3: Tombstone cleanup of mood snapshots

    @Test("planting-event tombstone cascades to LocalPetMoodSnapshot hard-delete")
    func plantingTombstoneCleansSnapshots() async {
        let container = Self.makeContainer()
        let context = ModelContext(container)

        // Pre-seed a parent planting and a mood snapshot for it. These
        // mirror what `PetStateEngine.tick` would have written on prior
        // foregrounds.
        let eventID = "pe_tombstone_cascade"
        let createdAt: Int64 = 1_700_000_000_000
        let planting = LocalPlantingEvent(
            id: eventID,
            householdID: Self.householdID,
            kindRaw: "sowing",
            plannedFor: "2026-01-01",
            createdAt: createdAt,
            updatedAt: createdAt,
            petSeed: "seed_x",
            petRarity: "common",
            petCreatureKind: "garden_worm",
            petName: "Pip",
            petSpawnedAt: createdAt
        )
        context.insert(planting)
        context.insert(LocalPetMoodSnapshot(
            plantingEventID: eventID,
            dayYMD: "2026-05-30",
            moodLabel: PetMoodLabel.content.rawValue,
            compositeScore: 82,
            createdAt: createdAt
        ))
        context.insert(LocalPetMoodSnapshot(
            plantingEventID: eventID,
            dayYMD: "2026-05-31",
            moodLabel: PetMoodLabel.wilted.rawValue,
            compositeScore: 45,
            createdAt: createdAt
        ))
        try? context.save()

        // Sanity: two snapshots exist pre-sync.
        let pre = (try? context.fetch(FetchDescriptor<LocalPetMoodSnapshot>(
            predicate: #Predicate { $0.plantingEventID == eventID }
        ))) ?? []
        #expect(pre.count == 2)

        // Stub the planting-events endpoint to return a tombstone for
        // this event. Everything else hits the empty-page envelope.
        let deletedAt = createdAt + 1
        let tombstoneBody = Data("""
        {
          "ok": true,
          "data": {
            "items": [
              {
                "id": "\(eventID)",
                "household_id": "\(Self.householdID)",
                "bed_id": null,
                "seed_id": null,
                "catalog_seed_id": null,
                "kind": "sowing",
                "planned_for": "2026-01-01",
                "completed_at": null,
                "notes": null,
                "x_feet": null,
                "y_feet": null,
                "created_at": \(createdAt),
                "updated_at": \(deletedAt),
                "deleted_at": \(deletedAt),
                "pet_seed": "seed_x",
                "pet_rarity": "common",
                "pet_creature_kind": "garden_worm",
                "pet_name": "Pip",
                "pet_personality": null,
                "pet_spawned_at": \(createdAt)
              }
            ],
            "cursor": \(deletedAt),
            "has_more": false
          }
        }
        """.utf8)
        let client = Self.makeRoutedClient(routes: [
            "/api/planting-events": tombstoneBody
        ])
        let engine = SyncEngine(client: client, container: container)

        await engine.syncAll(householdID: Self.householdID)

        // After sync: parent planting hard-deleted, snapshots gone.
        let postEvent = (try? context.fetch(FetchDescriptor<LocalPlantingEvent>(
            predicate: #Predicate { $0.id == eventID }
        ))) ?? []
        #expect(postEvent.isEmpty, "tombstone should have hard-deleted the local planting")
        let postSnaps = (try? context.fetch(FetchDescriptor<LocalPetMoodSnapshot>(
            predicate: #Predicate { $0.plantingEventID == eventID }
        ))) ?? []
        #expect(postSnaps.isEmpty, "mood snapshots should cascade-delete with the parent planting")
    }

    // MARK: - Test 4: Tombstone on departures feed

    @Test("departure tombstone via the delta feed hard-deletes the local row")
    func departureTombstoneHardDeletesLocalRow() async {
        let container = Self.makeContainer()
        let context = ModelContext(container)

        // Pre-seed a local departure that a sibling device later tombstones.
        let eventID = "pe_tombstone_dep"
        let now: Int64 = 1_717_500_000_000
        context.insert(LocalPetDeparture(
            plantingEventID: eventID,
            goodbyeNoteJSON: nil,
            reason: "wilted_too_long",
            fallback: true,
            createdAt: now,
            updatedAt: now,
            departedAt: now,
            deletedAt: nil
        ))
        try? context.save()

        let tombstoneAt = now + 1
        let routeBody = Data("""
        {
          "ok": true,
          "data": {
            "items": [
              {
                "planting_event_id": "\(eventID)",
                "household_id": "\(Self.householdID)",
                "goodbye_note": null,
                "reason": "wilted_too_long",
                "departed_at": \(now),
                "created_at": \(now),
                "updated_at": \(tombstoneAt),
                "deleted_at": \(tombstoneAt)
              }
            ],
            "cursor": \(tombstoneAt),
            "has_more": false
          }
        }
        """.utf8)
        let client = Self.makeRoutedClient(routes: [
            "/api/pets/departures": routeBody
        ])
        let engine = SyncEngine(client: client, container: container)

        await engine.syncAll(householdID: Self.householdID)

        let post = (try? context.fetch(FetchDescriptor<LocalPetDeparture>(
            predicate: #Predicate { $0.plantingEventID == eventID }
        ))) ?? []
        #expect(post.isEmpty, "tombstone payload should have hard-deleted the local departure")
    }
}

// MARK: - Path-aware URLProtocol stub
//
// Mirrors the `MockURLProtocol` shape from `PetStateEngineTests` but
// dispatches by request path instead of a single canned body. Tests
// register `/api/<path>` → response Data; unmatched paths fall back to
// the empty-page envelope so the rest of `syncAll`'s sweep doesn't blow
// up looking for endpoints we don't care about in the test.
final class RouterMockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var routes: [String: Data] = [:]
    nonisolated(unsafe) static var fallbackBody: Data = Data()
    nonisolated(unsafe) static var fallbackStatus: Int = 200
    nonisolated(unsafe) static var capturedRequests: [URLRequest] = []
    static let lock = NSLock()

    static func makeSession(
        routes: [String: Data],
        fallbackBody: Data,
        fallbackStatus: Int
    ) -> URLSession {
        lock.lock()
        defer { lock.unlock() }
        Self.routes = routes
        Self.fallbackBody = fallbackBody
        Self.fallbackStatus = fallbackStatus
        Self.capturedRequests = []
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RouterMockURLProtocol.self]
        return URLSession(configuration: config)
    }

    static func resetCapture() {
        lock.lock()
        defer { lock.unlock() }
        Self.capturedRequests = []
    }

    static func capturedPaths() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return Self.capturedRequests.compactMap { $0.url?.path }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.capturedRequests.append(request)
        let path = request.url?.path ?? ""
        let body = Self.routes[path] ?? Self.fallbackBody
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
