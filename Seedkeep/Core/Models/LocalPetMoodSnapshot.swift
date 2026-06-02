import Foundation
import SwiftData

/// Per-day materialized mood for a planting-event's pet. Written by
/// `PetStateEngine.tick` (lands in Phase 5.1.1) and the lazy
/// `LocalPlantingEvent.petMoodLabel` recompute path. Iframed by
/// `PetDetailView`'s 14-day mood sparkline (Phase 5.1.2).
///
/// Spec: never synced. Idempotent on the composite key
/// `"\(plantingEventID)::\(dayYMD)"`. `dayYMD` is the household-timezone
/// calendar day (`YYYY-MM-DD`) the snapshot represents. `composite` is
/// the raw 0-100 score the `label` was bucketed from — keeping both
/// lets the sparkline render exact values while UI branches on the
/// label vocabulary.
///
/// Deleted in `cleanupPlantingEventChildren(eventID:)` when the parent
/// planting is hard-deleted (Phase 5.1.1).
@Model
public final class LocalPetMoodSnapshot {
    /// Composite key `"\(plantingEventID)::\(dayYMD)"`. Lets writes be
    /// idempotent and lookups single-row.
    @Attribute(.unique) public var id: String
    public var plantingEventID: String
    /// Household-timezone calendar day in `YYYY-MM-DD`. Lexicographic
    /// sort matches chronological order — used by the 14-day query.
    public var dayYMD: String
    /// `PetMoodLabel.rawValue` — `thriving` / `content` / `quiet` /
    /// `wilted` / `departingImminent`. Stored as raw string so the
    /// SwiftData schema doesn't depend on SeedkeepKit's enum metadata.
    public var moodLabel: String
    /// Raw 0..100 score from `MoodEngine.compute` before bucketing.
    public var compositeScore: Int
    public var createdAt: Int64

    public init(
        plantingEventID: String,
        dayYMD: String,
        moodLabel: String,
        compositeScore: Int,
        createdAt: Int64
    ) {
        self.id = "\(plantingEventID)::\(dayYMD)"
        self.plantingEventID = plantingEventID
        self.dayYMD = dayYMD
        self.moodLabel = moodLabel
        self.compositeScore = compositeScore
        self.createdAt = createdAt
    }
}
