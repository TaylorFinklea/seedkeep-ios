import Testing
import Foundation
import SwiftData
@testable import Seedkeep

/// Layer 4 — exercises the production `SwiftDataPlantingEventQuery` against
/// a real in-memory SwiftData container. The canonical predicate is
/// `deletedAt == nil && completedAt == nil` — two AND clauses, staying
/// under SwiftData's 3-AND macro limit. Adding a third invariant here would
/// regress that constraint, so the test serves both as a correctness
/// check AND as a structural guardrail.
///
/// Spec: `.docs/ai/specs/2026-06-07-phase-4c-native-warnings-design.md`
/// §11 (Layer 4 — SwiftDataPlantingEventQueryTests).
@MainActor
@Suite("SwiftDataPlantingEventQuery — Phase 4C predicate guardrail")
struct SwiftDataPlantingEventQueryTests {

    private static let householdID = "hh_pq_test"

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
            "swiftDataPlantingEventQueryTests-\(UUID().uuidString)",
            schema: schema,
            isStoredInMemoryOnly: true
        )
        return try! ModelContainer(for: schema, configurations: config)
    }

    private static func makeEvent(
        id: String,
        completedAt: Int64? = nil,
        deletedAt: Int64? = nil
    ) -> LocalPlantingEvent {
        LocalPlantingEvent(
            id: id,
            householdID: householdID,
            kindRaw: "sowing",
            plannedFor: "2026-07-01",
            completedAt: completedAt,
            createdAt: 1_700_000_000_000,
            updatedAt: 1_700_000_000_000,
            deletedAt: deletedAt
        )
    }

    // MARK: - Empty container

    @Test("empty container → activeCount == 0")
    func emptyContainerReturnsZero() async {
        let container = Self.makeContainer()
        let query = SwiftDataPlantingEventQuery(container: container)
        let count = await query.activeCount()
        #expect(count == 0)
    }

    // MARK: - Single active event

    @Test("single active event → activeCount == 1")
    func singleActiveEventReturnsOne() async {
        let container = Self.makeContainer()
        let context = ModelContext(container)
        context.insert(Self.makeEvent(id: "pe1"))
        try? context.save()
        let query = SwiftDataPlantingEventQuery(container: container)
        let count = await query.activeCount()
        #expect(count == 1)
    }

    // MARK: - Completed events excluded

    @Test("completed events are excluded")
    func completedEventsExcluded() async {
        let container = Self.makeContainer()
        let context = ModelContext(container)
        context.insert(Self.makeEvent(id: "pe_active"))
        context.insert(Self.makeEvent(id: "pe_completed", completedAt: 1_700_000_000_000))
        try? context.save()
        let query = SwiftDataPlantingEventQuery(container: container)
        let count = await query.activeCount()
        #expect(count == 1)
    }

    // MARK: - Deleted events excluded

    @Test("deleted events are excluded")
    func deletedEventsExcluded() async {
        let container = Self.makeContainer()
        let context = ModelContext(container)
        context.insert(Self.makeEvent(id: "pe_active"))
        context.insert(Self.makeEvent(id: "pe_deleted", deletedAt: 1_700_000_000_000))
        try? context.save()
        let query = SwiftDataPlantingEventQuery(container: container)
        let count = await query.activeCount()
        #expect(count == 1)
    }

    // MARK: - Mixed bag

    @Test("mixed bag: 3 active + 2 completed + 1 deleted → activeCount == 3")
    func mixedBagFiltersCorrectly() async {
        let container = Self.makeContainer()
        let context = ModelContext(container)
        for id in ["a1", "a2", "a3"] {
            context.insert(Self.makeEvent(id: id))
        }
        for id in ["c1", "c2"] {
            context.insert(Self.makeEvent(id: id, completedAt: 1_700_000_000_000))
        }
        context.insert(Self.makeEvent(id: "d1", deletedAt: 1_700_000_000_000))
        try? context.save()
        let query = SwiftDataPlantingEventQuery(container: container)
        let count = await query.activeCount()
        #expect(count == 3)
    }
}
