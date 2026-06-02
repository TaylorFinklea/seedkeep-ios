import Foundation
import SwiftData
import SeedkeepKit

/// SwiftData mirror of `PetDepartureDTO`. One row per departed pet,
/// 1:1 with the parent `LocalPlantingEvent` (no compound key needed —
/// `plantingEventID` is unique by construction).
///
/// Written by:
///   - `PetStateEngine` after `requestPetDeparture` succeeds (the
///     transition from `.departing` → `.departed` triggers the RPC,
///     which returns the inserted-or-idempotent row inline).
///   - `SyncEngine.upsertPetDepartures` for cross-device fan-out via
///     the `/api/pets/departures` delta-sync feed (lands in a later
///     5.1.x commit).
///
/// Hard-deleted (not soft-deleted) by
/// `cleanupPlantingEventChildren` when the parent planting is
/// tombstoned server-side. The parent's deletion cascades to
/// `pet_departures` via `ON DELETE CASCADE` on the server — the local
/// cleanup mirrors that.
///
/// The goodbye-note JSON stays as a string column for the same reason
/// `LocalPlantingEvent.petPersonalityJSON` does: SwiftData out of nested
/// Codable territory + lets server-side schema evolution land without
/// forcing a SwiftData migration on the client.
@Model
public final class LocalPetDeparture {
    /// 1:1 with the parent planting — `id == plantingEventID` by
    /// construction. Lets fetches by either column hit the unique index.
    @Attribute(.unique) public var plantingEventID: String
    /// JSON-encoded `PetGoodbyeNote`. Nil during the brief server-side
    /// retry window (rare in v1 — the route inserts the fallback before
    /// returning so this should always be populated). Decode via
    /// `goodbyeNote` for a typed view.
    public var goodbyeNoteJSON: String?
    /// One of `inactivity`, `wilted_too_long`, `user_dismissed`. v1 only
    /// writes `wilted_too_long`; the others are reserved.
    public var reason: String
    /// `false` when the goodbye note came from a successful Sprout call,
    /// `true` when the server fell back to `"I'll miss you. — <name>"`.
    /// Cached from the decoded JSON for cheap query filtering.
    public var fallback: Bool
    public var createdAt: Int64
    public var updatedAt: Int64
    /// Epoch ms — immutable after insert on the server side, mirrored
    /// here. Drives Menagerie's "departed N days ago" sort.
    public var departedAt: Int64
    /// Nil unless the server has tombstoned the row (e.g. a sibling
    /// device hard-deleted the parent planting and the cascade is still
    /// flowing through pull-sync).
    public var deletedAt: Int64?

    public init(
        plantingEventID: String,
        goodbyeNoteJSON: String? = nil,
        reason: String,
        fallback: Bool = false,
        createdAt: Int64,
        updatedAt: Int64,
        departedAt: Int64,
        deletedAt: Int64? = nil
    ) {
        self.plantingEventID = plantingEventID
        self.goodbyeNoteJSON = goodbyeNoteJSON
        self.reason = reason
        self.fallback = fallback
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.departedAt = departedAt
        self.deletedAt = deletedAt
    }
}

public extension LocalPetDeparture {
    /// Decoded `PetGoodbyeNote` for the stored JSON blob. Nil for rows
    /// whose `goodbyeNoteJSON` is absent or malformed. Mirrors the
    /// `LocalPlantingEvent.petPersonality` decode pattern.
    var goodbyeNote: PetGoodbyeNote? {
        guard let json = goodbyeNoteJSON, !json.isEmpty else { return nil }
        return try? JSONDecoder().decode(PetGoodbyeNote.self, from: Data(json.utf8))
    }
}
