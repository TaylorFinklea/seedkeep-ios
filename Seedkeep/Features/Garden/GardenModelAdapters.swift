import Foundation
import SeedkeepKit

// Adapters from the SwiftData models to the pure Garden and Windows values.

extension GridEvent {
    init(_ local: LocalPlantingEvent, isFrostFlagged: Bool) {
        self.init(
            id: local.id,
            bedID: local.bedID,
            seedID: local.seedID,
            kind: local.kindRaw,
            plannedFor: local.plannedFor,
            isCompleted: local.completedAt != nil,
            x: local.xFeet,
            y: local.yFeet,
            isFrostFlagged: isFrostFlagged
        )
    }
}

extension FrostCheck {
    /// The frost outcome for a stored event, its seed and the home climate.
    static func check(_ event: LocalPlantingEvent, seed: LocalSeed?, climate: HomeClimate?) -> Outcome {
        check(
            plannedFor: event.plannedFor,
            kind: event.kindRaw,
            isCompleted: event.completedAt != nil,
            frostTolerance: seed?.growingInfo?.frost_tolerance,
            lastFrost: climate?.avgLastFrost,
            firstFrost: climate?.avgFirstFrost
        )
    }
}

extension BrushSeed {
    init(_ seed: LocalSeed, verdict: String?) {
        self.init(id: seed.id, name: seed.displayName, verdict: verdict)
    }
}

extension WindowSeed {
    init(_ seed: LocalSeed, recommendation: PlantingRecommendation) {
        self.init(
            id: seed.id,
            name: seed.displayName,
            isArchived: seed.state == .archived,
            isActive: seed.state == .active,
            verdict: recommendation.verdict,
            outdoorStart: recommendation.rangeStart,
            outdoorEnd: recommendation.rangeEnd,
            indoorStart: recommendation.indoorStart,
            indoorEnd: recommendation.indoorEnd
        )
    }
}

extension GardenSession.BedChoice {
    init(_ bed: LocalBed) {
        self.init(
            id: bed.id,
            name: bed.name,
            sortOrder: bed.sortOrder,
            hasGrid: GardenGrid.size(widthFeet: bed.widthFeet, lengthFeet: bed.lengthFeet) != nil
        )
    }
}
