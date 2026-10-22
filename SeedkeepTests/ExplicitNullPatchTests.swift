import Testing
import Foundation
import SwiftData
@testable import Seedkeep
import SeedkeepKit

/// Stabilization B3 · contract decision 8 — enqueue local-applies must
/// distinguish "omitted" (leave alone) from "clear" (`.some(nil)` →
/// JSON null) now that `UpdateSeedInput`'s nullable fields and
/// `UpdatePlantingEventInput.completed_at` are double-optional.
///
/// These tests exercise `SyncEngine.enqueueUpdateSeed` /
/// `enqueueUpdatePlantingEvent` locally: the local apply, and that no
/// `LocalPendingWrite` row is queued (N3). The JSON-null encoding itself is
/// covered by SeedkeepKit's `StabilizationB3WireTests`.
@MainActor
@Suite("SyncEngine — explicit-null patches (Stabilization B3)", .serialized)
struct ExplicitNullPatchTests {

    private static let householdID = "hh_null_patch"

    private static func makeContainer() -> ModelContainer {
        makeTestContainer(name: "explicitNullPatchTests")
    }

    private static func makeEngine(container: ModelContainer) -> SyncEngine {
        SyncEngine(container: container)
    }

    private static func insertSeed(_ container: ModelContainer) throws -> LocalSeed {
        let context = ModelContext(container)
        let seed = LocalSeed(
            id: "seed_null_1",
            householdID: householdID,
            state: .active,
            packetCount: 1,
            locationID: "loc_1",
            yearPacked: 2024,
            source: .store,
            customName: "Cherokee Purple",
            notes: "old notes",
            createdAt: 1,
            updatedAt: 1
        )
        context.insert(seed)
        try context.save()
        return seed
    }

    private static func pendingPayloads(_ container: ModelContainer) -> [String] {
        let context = ModelContext(container)
        let rows = (try? context.fetch(FetchDescriptor<LocalPendingWrite>(
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]
        ))) ?? []
        return rows.map(\.payloadJSON)
    }

    @Test("clearing location/year/name/notes nulls the local row and queues nothing")
    func clearAppliesLocallyAndQueuesNull() async throws {
        let container = Self.makeContainer()
        let engine = Self.makeEngine(container: container)
        _ = try Self.insertSeed(container)

        try engine.enqueueUpdateSeed(id: "seed_null_1", .init(
            location_id: .some(nil),
            year_packed: .some(nil),
            custom_name: .some(nil),
            notes: .some(nil)
        ))

        let context = ModelContext(container)
        let seed = try #require(try context.fetch(
            FetchDescriptor<LocalSeed>(predicate: #Predicate { $0.id == "seed_null_1" })
        ).first)
        #expect(seed.locationID == nil, "clear must null the local locationID")
        #expect(seed.yearPacked == nil)
        #expect(seed.customName == nil)
        #expect(seed.notes == nil)
        #expect(Self.pendingPayloads(container).isEmpty, "N3: nothing is queued for a server")
    }

    @Test("omitted fields leave the local row untouched")
    func omittedFieldsLeaveLocalAlone() async throws {
        let container = Self.makeContainer()
        let engine = Self.makeEngine(container: container)
        _ = try Self.insertSeed(container)

        try engine.enqueueUpdateSeed(id: "seed_null_1", .init(packet_count: 7))

        let context = ModelContext(container)
        let seed = try #require(try context.fetch(
            FetchDescriptor<LocalSeed>(predicate: #Predicate { $0.id == "seed_null_1" })
        ).first)
        #expect(seed.packetCount == 7)
        #expect(seed.locationID == "loc_1", "omitted location must not be cleared")
        #expect(seed.customName == "Cherokee Purple")
        #expect(seed.notes == "old notes")
        #expect(Self.pendingPayloads(container).isEmpty)
    }

    @Test("mark incomplete clears completedAt locally and queues nothing")
    func markIncompleteClearsCompletedAt() async throws {
        let container = Self.makeContainer()
        let engine = Self.makeEngine(container: container)
        let context = ModelContext(container)
        context.insert(LocalPlantingEvent(
            id: "pe_null_1",
            householdID: Self.householdID,
            kindRaw: "sowing",
            plannedFor: "2026-06-01",
            completedAt: 1_750_000_000_000,
            createdAt: 1,
            updatedAt: 1
        ))
        try context.save()

        try engine.enqueueUpdatePlantingEvent(
            id: "pe_null_1",
            .init(completed_at: .some(nil))
        )

        let event = try #require(try context.fetch(
            FetchDescriptor<LocalPlantingEvent>(predicate: #Predicate { $0.id == "pe_null_1" })
        ).first)
        #expect(event.completedAt == nil,
                "mark incomplete must clear completedAt so Today/pets/weather see the event again")
        #expect(Self.pendingPayloads(container).isEmpty)
    }

    @Test("update without completed_at leaves completion state alone")
    func omittedCompletedAtUntouched() async throws {
        let container = Self.makeContainer()
        let engine = Self.makeEngine(container: container)
        let context = ModelContext(container)
        context.insert(LocalPlantingEvent(
            id: "pe_null_2",
            householdID: Self.householdID,
            kindRaw: "sowing",
            plannedFor: "2026-06-01",
            completedAt: 1_750_000_000_000,
            createdAt: 1,
            updatedAt: 1
        ))
        try context.save()

        try engine.enqueueUpdatePlantingEvent(id: "pe_null_2", .init(notes: "thinned"))

        let event = try #require(try context.fetch(
            FetchDescriptor<LocalPlantingEvent>(predicate: #Predicate { $0.id == "pe_null_2" })
        ).first)
        #expect(event.completedAt == 1_750_000_000_000)
        #expect(event.notes == "thinned")
    }
}
