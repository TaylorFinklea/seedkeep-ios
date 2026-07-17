import Testing
import Foundation
import SwiftData
@testable import Seedkeep
import SeedkeepKit

/// Bead seedkeep-27d.2 — while CloudKit household sync is active, the
/// legacy server write queue (`SyncEngine.flushPending`) must never
/// dispatch a network request: CloudKit is the only writer of household
/// garden data, and a second writer racing it would double-apply
/// mutations server-side. Enqueueing stays UNGATED
/// (`enqueueOrCoalesceUpdate` and friends still park rows) so a
/// flag-OFF rollback can drain the parked queue instead of silently
/// losing every ON-era mutation. See decisions.md.
@MainActor
@Suite("SyncEngine — flushPending gated behind CloudKit-OFF (seedkeep-27d.2)", .serialized)
struct FlushPendingCloudKitGateTests {

    private static let householdID = "hh_cloudkit_gate"

    // MARK: - Shared enqueue helper

    /// Drives all 15 optimistic-write entrypoints (5 entities × create /
    /// update via `enqueueOrCoalesceUpdate` / delete — SyncEngine.swift
    /// 648-1049) against `engine`, returning the created rows for
    /// building server-response stubs keyed by their (server-stable)
    /// client-supplied ids.
    private static func enqueueAllFifteen(on engine: SyncEngine) throws -> (
        location: LocalLocation, tag: LocalTag, seed: LocalSeed, bed: LocalBed, event: LocalPlantingEvent
    ) {
        let location = try engine.enqueueCreateLocation(name: "Shed", householdID: householdID)
        try engine.enqueueUpdateLocation(id: location.id, name: "Barn", sortOrder: nil)
        try engine.enqueueDeleteLocation(id: location.id)

        let tag = try engine.enqueueCreateTag(name: "Heirloom", color: nil, householdID: householdID)
        try engine.enqueueUpdateTag(id: tag.id, name: "Saved", color: nil)
        try engine.enqueueDeleteTag(id: tag.id)

        let seed = try engine.enqueueCreateSeed(
            .init(state: .active, custom_name: "Queued seed"),
            householdID: householdID
        )
        try engine.enqueueUpdateSeed(id: seed.id, .init(notes: "Water daily"))
        try engine.enqueueDeleteSeed(id: seed.id)

        let bed = try engine.enqueueCreateBed(.init(name: "North bed"), householdID: householdID)
        try engine.enqueueUpdateBed(id: bed.id, .init(name: "South bed"))
        try engine.enqueueDeleteBed(id: bed.id)

        let event = try engine.enqueueCreatePlantingEvent(
            .init(kind: .sowing, planned_for: "2026-07-15"),
            householdID: householdID
        )
        try engine.enqueueUpdatePlantingEvent(id: event.id, .init(notes: "Thinned"))
        try engine.enqueueDeletePlantingEvent(id: event.id)

        return (location, tag, seed, bed, event)
    }

    private static func emptySession() -> URLSession {
        CatalogRouterMockURLProtocol.makeSession(
            fallbackBody: Data(#"{"ok":true,"data":{"items":[],"cursor":0,"has_more":false}}"#.utf8),
            fallbackStatus: 200
        )
    }

    // MARK: - (a) Bead acceptance test

    @Test("CloudKit ON: flushPending is a silent no-op across all 15 entrypoints")
    func flushPendingNoOpsUnderCloudKitOn() async throws {
        let defaults = UserDefaults.standard
        let key = FeatureFlags.cloudKitHouseholdSyncKey
        let previous = defaults.object(forKey: key)
        defer {
            if let previous {
                defaults.set(previous, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
        FeatureFlags.setCloudKitHouseholdSync(true)

        let container = makeTestContainer(name: "flushGateAcceptance")
        let client = SeedkeepClient(
            configuration: .init(baseURL: URL(string: "https://test.local")!, session: Self.emptySession()),
            bearerToken: "test_token"
        )
        let engine = SyncEngine(client: client, container: container)
        var signalCount = 0
        engine.onLocalHouseholdMutation = { signalCount += 1 }

        _ = try Self.enqueueAllFifteen(on: engine)
        #expect(signalCount == 15, "every queue-backed mutation must still signal exactly once while parked")

        let context = ModelContext(container)
        let beforeFlush = try context.fetch(FetchDescriptor<LocalPendingWrite>())
        #expect(beforeFlush.count == 15, "all 15 entrypoints must enqueue a LocalPendingWrite even while CloudKit is active")

        // Simulates the 16 UI call sites, every one of which fires
        // `Task { try? await appEnv.sync.flushPending() }`.
        try await engine.flushPending()

        #expect(CatalogRouterMockURLProtocol.capturedMethodPaths().isEmpty,
                "flushPending must make zero server requests while CloudKit household sync is active")

        let afterFlush = try context.fetch(FetchDescriptor<LocalPendingWrite>())
        #expect(afterFlush.count == 15, "every parked row must survive a no-op flush — not deleted, not dead-lettered")
        #expect(afterFlush.allSatisfy { !$0.isDeadLettered },
                "a no-op flush must never dead-letter a parked row")
        #expect(signalCount == 15, "flushPending itself must not fire any additional mutation signal")
    }

    // MARK: - (b) Rollback-drain test

    @Test("CloudKit OFF after rollback: flushPending drains every row parked while ON")
    func flushPendingDrainsParkedRowsAfterRollback() async throws {
        let defaults = UserDefaults.standard
        let key = FeatureFlags.cloudKitHouseholdSyncKey
        let previous = defaults.object(forKey: key)
        defer {
            if let previous {
                defaults.set(previous, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
        FeatureFlags.setCloudKitHouseholdSync(true)

        let container = makeTestContainer(name: "flushGateRollbackDrain")
        let client = SeedkeepClient(
            configuration: .init(baseURL: URL(string: "https://test.local")!, session: Self.emptySession()),
            bearerToken: "test_token"
        )
        let engine = SyncEngine(client: client, container: container)

        let rows = try Self.enqueueAllFifteen(on: engine)

        // ON: flushPending is a no-op — the mutations stay parked.
        try await engine.flushPending()
        let parkedContext = ModelContext(container)
        #expect(try parkedContext.fetch(FetchDescriptor<LocalPendingWrite>()).count == 15)
        #expect(CatalogRouterMockURLProtocol.capturedMethodPaths().isEmpty)

        // Stub the 15 server routes the drained queue is about to dispatch to.
        CatalogRouterMockURLProtocol.routes["POST /api/locations"] = Data("""
        {"ok":true,"data":{"location":{"id":"\(rows.location.id)","household_id":"\(Self.householdID)","name":"Shed","sort_order":0,"created_at":1,"updated_at":1,"deleted_at":null}}}
        """.utf8)
        CatalogRouterMockURLProtocol.routes["PATCH /api/locations/\(rows.location.id)"] = Data("""
        {"ok":true,"data":{"location":{"id":"\(rows.location.id)","household_id":"\(Self.householdID)","name":"Barn","sort_order":0,"created_at":1,"updated_at":2,"deleted_at":null}}}
        """.utf8)
        CatalogRouterMockURLProtocol.routes["DELETE /api/locations/\(rows.location.id)"] = Data("""
        {"ok":true,"data":{"id":"\(rows.location.id)","deleted_at":3}}
        """.utf8)

        CatalogRouterMockURLProtocol.routes["POST /api/tags"] = Data("""
        {"ok":true,"data":{"tag":{"id":"\(rows.tag.id)","household_id":"\(Self.householdID)","name":"Heirloom","color":null,"created_at":1,"updated_at":1,"deleted_at":null}}}
        """.utf8)
        CatalogRouterMockURLProtocol.routes["PATCH /api/tags/\(rows.tag.id)"] = Data("""
        {"ok":true,"data":{"tag":{"id":"\(rows.tag.id)","household_id":"\(Self.householdID)","name":"Saved","color":null,"created_at":1,"updated_at":2,"deleted_at":null}}}
        """.utf8)
        CatalogRouterMockURLProtocol.routes["DELETE /api/tags/\(rows.tag.id)"] = Data("""
        {"ok":true,"data":{"id":"\(rows.tag.id)","deleted_at":3}}
        """.utf8)

        CatalogRouterMockURLProtocol.routes["POST /api/seeds"] = Data("""
        {"ok":true,"data":{"seed":{"id":"\(rows.seed.id)","household_id":"\(Self.householdID)","catalog_id":null,"state":"active","packet_count":1,"location_id":null,"year_packed":null,"source":"store","custom_name":"Queued seed","custom_variety":null,"custom_company":null,"notes":null,"created_at":1,"updated_at":1,"deleted_at":null,"tag_ids":[]}}}
        """.utf8)
        CatalogRouterMockURLProtocol.routes["PATCH /api/seeds/\(rows.seed.id)"] = Data("""
        {"ok":true,"data":{"seed":{"id":"\(rows.seed.id)","household_id":"\(Self.householdID)","catalog_id":null,"state":"active","packet_count":1,"location_id":null,"year_packed":null,"source":"store","custom_name":"Queued seed","custom_variety":null,"custom_company":null,"notes":"Water daily","created_at":1,"updated_at":2,"deleted_at":null,"tag_ids":[]}}}
        """.utf8)
        CatalogRouterMockURLProtocol.routes["DELETE /api/seeds/\(rows.seed.id)"] = Data("""
        {"ok":true,"data":{"id":"\(rows.seed.id)","deleted_at":3}}
        """.utf8)

        CatalogRouterMockURLProtocol.routes["POST /api/beds"] = Data("""
        {"ok":true,"data":{"bed":{"id":"\(rows.bed.id)","household_id":"\(Self.householdID)","name":"North bed","description":null,"width_feet":null,"length_feet":null,"sort_order":0,"created_at":1,"updated_at":1,"deleted_at":null}}}
        """.utf8)
        CatalogRouterMockURLProtocol.routes["PATCH /api/beds/\(rows.bed.id)"] = Data("""
        {"ok":true,"data":{"bed":{"id":"\(rows.bed.id)","household_id":"\(Self.householdID)","name":"South bed","description":null,"width_feet":null,"length_feet":null,"sort_order":0,"created_at":1,"updated_at":2,"deleted_at":null}}}
        """.utf8)
        CatalogRouterMockURLProtocol.routes["DELETE /api/beds/\(rows.bed.id)"] = Data("""
        {"ok":true,"data":{"id":"\(rows.bed.id)","deleted_at":3}}
        """.utf8)

        CatalogRouterMockURLProtocol.routes["POST /api/planting-events"] = Data("""
        {"ok":true,"data":{"planting_event":{"id":"\(rows.event.id)","household_id":"\(Self.householdID)","bed_id":null,"seed_id":null,"catalog_seed_id":null,"kind":"sowing","planned_for":"2026-07-15","completed_at":null,"notes":null,"x_feet":null,"y_feet":null,"created_at":1,"updated_at":1,"deleted_at":null,"pet_seed":null,"pet_rarity":null,"pet_creature_kind":null,"pet_name":null,"pet_personality":null,"pet_spawned_at":null}}}
        """.utf8)
        CatalogRouterMockURLProtocol.routes["PATCH /api/planting-events/\(rows.event.id)"] = Data("""
        {"ok":true,"data":{"planting_event":{"id":"\(rows.event.id)","household_id":"\(Self.householdID)","bed_id":null,"seed_id":null,"catalog_seed_id":null,"kind":"sowing","planned_for":"2026-07-15","completed_at":null,"notes":"Thinned","x_feet":null,"y_feet":null,"created_at":1,"updated_at":2,"deleted_at":null,"pet_seed":null,"pet_rarity":null,"pet_creature_kind":null,"pet_name":null,"pet_personality":null,"pet_spawned_at":null}}}
        """.utf8)
        CatalogRouterMockURLProtocol.routes["DELETE /api/planting-events/\(rows.event.id)"] = Data("""
        {"ok":true,"data":{"id":"\(rows.event.id)","deleted_at":3}}
        """.utf8)

        CatalogRouterMockURLProtocol.resetCapture()
        FeatureFlags.setCloudKitHouseholdSync(false)
        try await engine.flushPending()

        let drainedContext = ModelContext(container)
        #expect(try drainedContext.fetch(FetchDescriptor<LocalPendingWrite>()).isEmpty,
                "the rollback-drain flush must dispatch and clear every row parked while CloudKit was ON")
        let capturedMethodPaths = CatalogRouterMockURLProtocol.capturedMethodPaths()
        #expect(capturedMethodPaths.count == 15,
                "expected all 15 parked rows to dispatch to the recorded server stub, got \(capturedMethodPaths)")
    }
}
