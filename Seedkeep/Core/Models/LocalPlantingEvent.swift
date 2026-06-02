import Foundation
import SwiftData
import SeedkeepKit

/// SwiftData mirror of `PlantingEventDTO`. Phase 2 garden plan timeline.
///
/// Phase 5 — plant pets: this row also carries the six server-of-record
/// identity columns (`petSeed`, `petRarity`, `petCreatureKind`, `petName`,
/// `petPersonalityJSON`, `petSpawnedAt`) plus two iOS-local streak columns
/// (`petWiltedStreakDays`, `petLastMoodTickAt`) that **never sync**. The
/// `apply(to:)` mapping deliberately skips the streak columns so a sync
/// round doesn't zero departure progress that survived an app kill.
@Model
public final class LocalPlantingEvent {
    @Attribute(.unique) public var id: String
    public var householdID: String
    public var bedID: String?
    public var seedID: String?
    public var catalogSeedID: String?
    /// Raw `PlantingEventKind.rawValue` — "sowing", "transplant",
    /// "harvest", "note". Stored as string so SwiftData doesn't need
    /// to know about the SeedkeepKit-defined enum at compile time.
    public var kindRaw: String
    /// YYYY-MM-DD string, as the server stores it. Sortable
    /// lexicographically; clients convert to Date for display.
    public var plannedFor: String
    public var completedAt: Int64?
    public var notes: String?
    /// Position within the bed, in feet from origin (0,0 = bottom-left).
    /// Both nil until the user places the event in the layout.
    public var xFeet: Double?
    public var yFeet: Double?
    public var createdAt: Int64
    public var updatedAt: Int64
    public var deletedAt: Int64?

    // MARK: - Phase 5 plant-pet identity (server-of-record, synced)
    /// sha256 of `id` (64-char lowercase hex). Acts as the deterministic
    /// seed for the rarity roll + creature pick. Nil for pre-Phase-5
    /// legacy rows; iOS gates pet rendering on `petSeed != nil`.
    public var petSeed: String?
    /// Raw rarity tier from `PetRarity` (`common` / `uncommon` / `rare`
    /// / `legendary` / `mythical`). Decode via `PetRarity(rawValue:)`.
    public var petRarity: String?
    /// Bestiary identifier (e.g. `garden_worm`, `spirit_fox`). Open set
    /// — the catalog lives server-side; iOS dispatches via a substring
    /// router so unknown identifiers fall through to a generic glyph.
    public var petCreatureKind: String?
    /// Denormalized cache of `petPersonality.name`. Server invariant:
    /// `petName == decoded.name` whenever both are non-nil.
    public var petName: String?
    /// JSON-encoded `PetPersonality`. Mirrors how `LocalSeed` stores its
    /// `growingInfoJSON` snapshot — keeps SwiftData out of nested
    /// Codable territory. Use `petPersonality` for the decoded view.
    public var petPersonalityJSON: String?
    /// Epoch ms when the server stamped the pet identity. Used as the
    /// single clock for mood + age stars (per design decision #1: "pet
    /// is born when planting_event is created").
    public var petSpawnedAt: Int64?

    // MARK: - Phase 5 plant-pet streak counters (iOS-local, NEVER synced)
    /// Consecutive day-ticks at `PetMoodLabel.departingImminent`. Reset
    /// to 0 when the mood label improves to `quiet` or better, OR when
    /// the calendar day hasn't advanced. Drives the alive→departing→
    /// departed transition in `PetStateEngine` (wired in 5.1.1).
    public var petWiltedStreakDays: Int = 0
    /// Epoch ms of the last `PetStateEngine.tick` for this pet. Used to
    /// detect calendar-day advance via
    /// `Calendar.current.isDate(_:inSameDayAs:)`. Survives app kills so
    /// departure progress isn't lost.
    public var petLastMoodTickAt: Int64?

    public init(
        id: String,
        householdID: String,
        bedID: String? = nil,
        seedID: String? = nil,
        catalogSeedID: String? = nil,
        kindRaw: String,
        plannedFor: String,
        completedAt: Int64? = nil,
        notes: String? = nil,
        xFeet: Double? = nil,
        yFeet: Double? = nil,
        createdAt: Int64,
        updatedAt: Int64,
        deletedAt: Int64? = nil,
        petSeed: String? = nil,
        petRarity: String? = nil,
        petCreatureKind: String? = nil,
        petName: String? = nil,
        petPersonalityJSON: String? = nil,
        petSpawnedAt: Int64? = nil,
        petWiltedStreakDays: Int = 0,
        petLastMoodTickAt: Int64? = nil
    ) {
        self.id = id
        self.householdID = householdID
        self.bedID = bedID
        self.seedID = seedID
        self.catalogSeedID = catalogSeedID
        self.kindRaw = kindRaw
        self.plannedFor = plannedFor
        self.completedAt = completedAt
        self.notes = notes
        self.xFeet = xFeet
        self.yFeet = yFeet
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
        self.petSeed = petSeed
        self.petRarity = petRarity
        self.petCreatureKind = petCreatureKind
        self.petName = petName
        self.petPersonalityJSON = petPersonalityJSON
        self.petSpawnedAt = petSpawnedAt
        self.petWiltedStreakDays = petWiltedStreakDays
        self.petLastMoodTickAt = petLastMoodTickAt
    }
}

public extension LocalPlantingEvent {
    /// Has a plant-pet identity been stamped by the server? Phase 5
    /// gates every pet-rendering surface on this — legacy plantings
    /// must continue to function without companions.
    var hasPet: Bool { petSeed != nil }

    /// Typed view over the raw `petRarity` string. Returns nil for
    /// values outside the spec-locked enum (forward-compat).
    var petRarityValue: PetRarity? {
        petRarity.flatMap(PetRarity.init(rawValue:))
    }

    /// Decoded `PetPersonality` for the stored JSON blob. Nil for
    /// pre-Phase-5 rows and during the brief server-side INSERT→UPDATE
    /// window where the row exists but the Sprout call hasn't completed.
    var petPersonality: PetPersonality? {
        guard let json = petPersonalityJSON, !json.isEmpty else { return nil }
        return try? JSONDecoder().decode(PetPersonality.self, from: Data(json.utf8))
    }

    /// Current mood label. Reads the most recent
    /// `LocalPetMoodSnapshot` written by `PetStateEngine.tick`
    /// (snapshot lookup avoids re-running the SwiftData fetches +
    /// scoring on every view recompute). Falls back to live
    /// `PetMoodResolver` + `MoodEngine` evaluation if no snapshot
    /// exists yet, and finally to `.thriving` for unattached models
    /// (no `modelContext`) or query failures.
    @MainActor
    var petMoodLabel: PetMoodLabel {
        if let snapshot = latestMoodSnapshot(),
           let label = PetMoodLabel(rawValue: snapshot.moodLabel) {
            return label
        }
        if let context = modelContext {
            let inputs = PetMoodResolver.resolveInputs(
                event: self,
                now: Date(),
                context: context
            )
            return MoodEngine.compute(inputs).label
        }
        return .thriving
    }

    /// Most-recent `LocalPetMoodSnapshot` for this planting, looked up
    /// via the model's attached context. Returns nil for detached
    /// models or when no snapshot has been written yet.
    @MainActor
    private func latestMoodSnapshot() -> LocalPetMoodSnapshot? {
        guard let context = modelContext else { return nil }
        let eventID = id
        var descriptor = FetchDescriptor<LocalPetMoodSnapshot>(
            predicate: #Predicate { snap in snap.plantingEventID == eventID },
            sortBy: [SortDescriptor(\.dayYMD, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    /// Current lifecycle phase. Combines the four lifecycle signals the
    /// spec calls out (line 662–668): server-stamped terminal flags
    /// (`completedAt`, presence of a `LocalPetDeparture` row), the
    /// streak counter, and the most recent mood snapshot. Order matters
    /// — `departed` and `graduated` are terminal, so they win against
    /// any current mood reading.
    @MainActor
    var petLifecyclePhase: PetLifecyclePhase {
        if completedAt != nil { return .graduated }
        if hasDeparted { return .departed }
        let mood = petMoodLabel
        switch mood {
        case .thriving, .content, .quiet:
            return .alive
        case .wilted:
            return .wilted
        case .departingImminent:
            return .departing
        }
    }

    /// Has a `LocalPetDeparture` row been written for this planting?
    /// True iff the row exists with `deletedAt == nil`. Detached
    /// (context-less) models can't run the fetch and return false —
    /// this is the same conservative default `latestMoodSnapshot` uses.
    @MainActor
    private var hasDeparted: Bool {
        guard let context = modelContext else { return false }
        let eventID = id
        let descriptor = FetchDescriptor<LocalPetDeparture>(
            predicate: #Predicate { row in
                row.plantingEventID == eventID && row.deletedAt == nil
            }
        )
        return ((try? context.fetchCount(descriptor)) ?? 0) > 0
    }
}
