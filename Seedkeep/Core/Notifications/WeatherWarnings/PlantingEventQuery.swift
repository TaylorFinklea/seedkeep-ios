import Foundation
import SwiftData

/// Phase 4C — count of active planting events for the household. The
/// `WeatherWarningsService` short-circuits to `.noActivePlantings`
/// (skipping the WeatherKit fetch) whenever this returns 0.
///
/// Carved out as a protocol so tests don't need a live SwiftData
/// container — they inject `StubPlantingEventQuery(count:)`.
protocol PlantingEventQuery: Sendable {
    func activeCount() async -> Int
}

/// Production impl. Opens a fresh `ModelContext` on the main actor per
/// call (SwiftData contexts are not Sendable across isolation domains)
/// and runs a 2-condition `#Predicate` that stays under the SwiftData
/// macro's 3-AND limit. The canonical idiom mirrors
/// `Seedkeep/Features/Garden/GardenView.swift`'s `openEvents` query.
struct SwiftDataPlantingEventQuery: PlantingEventQuery {

    private let container: ModelContainer

    init(container: ModelContainer) {
        self.container = container
    }

    func activeCount() async -> Int {
        let container = self.container
        return await MainActor.run { () -> Int in
            let context = ModelContext(container)
            // 2-condition predicate — same shape as GardenView's
            // `openEvents` @Query, so the SwiftData macro path is
            // already exercised in production.
            let descriptor = FetchDescriptor<LocalPlantingEvent>(
                predicate: #Predicate<LocalPlantingEvent> { event in
                    event.deletedAt == nil && event.completedAt == nil
                }
            )
            return (try? context.fetchCount(descriptor)) ?? 0
        }
    }
}
