import Foundation
import SeedkeepCloudKit

// R1 — the one-time per-household export plan. Pure given a fetched model set: collects the
// household's local SwiftData graph into the dependency-ordered CloudKitRecordValues the migration
// writes (parents before cascade-children so every .deleteSelf reference target already exists),
// capped with the idempotency receipt (G12). The executor (live-CloudKit, added with the engine
// wiring) writes this plan + provisions the zone/share; this planner is the host-testable heart.
enum HouseholdMigrationPlanner {
    /// Bumped when the record shape changes; written into the receipt so a future device can tell
    /// whether it migrated under an older schema.
    static let schemaVersion = 1

    /// The household's full local graph, ready to plan. The caller fetches these from the
    /// ModelContext (filtered by household) and supplies the household identity.
    struct Input {
        var householdID: String
        var householdName: String
        var householdCreatedAt: Int64
        var householdUpdatedAt: Int64
        var locations: [LocalLocation] = []
        var tags: [LocalTag] = []
        var seeds: [LocalSeed] = []
        var seedPhotos: [LocalSeedPhoto] = []
        var beds: [LocalBed] = []
        var plantingEvents: [LocalPlantingEvent] = []
        var journalEntries: [LocalJournalEntry] = []
        var journalEntryPhotos: [LocalJournalEntryPhoto] = []
        var checklistItems: [LocalJournalChecklistItem] = []
        var petDepartures: [LocalPetDeparture] = []
    }

    /// The full ordered plan:
    ///   Household → Location/Tag → Seed → SeedPhoto → Bed → PlantingEvent
    ///   → JournalEntry → JournalEntryPhoto/JournalChecklistItem → PetDeparture → receipt.
    /// Order matters: a `.deleteSelf` child (SeedPhoto, Journal photo/checklist, PetDeparture) must
    /// be written after its parent so the reference resolves even across separate save batches.
    static func plan(_ input: Input, completedAt: Int64) -> [CloudKitRecordValue] {
        var out: [CloudKitRecordValue] = []
        out.append(SeedkeepRecordValues.household(
            id: input.householdID, name: input.householdName,
            createdAt: input.householdCreatedAt, updatedAt: input.householdUpdatedAt))
        out += input.locations.map(\.cloudKitValue)
        out += input.tags.map(\.cloudKitValue)
        out += input.seeds.map(\.cloudKitValue)
        out += input.seedPhotos.map(\.cloudKitValue)
        out += input.beds.map(\.cloudKitValue)
        out += input.plantingEvents.map(\.cloudKitValue)
        out += input.journalEntries.map(\.cloudKitValue)
        out += input.journalEntryPhotos.map(\.cloudKitValue)
        out += input.checklistItems.map(\.cloudKitValue)
        out += input.petDepartures.map(\.cloudKitValue)
        out.append(SeedkeepRecordValues.migrationReceipt(
            householdID: input.householdID, completedAt: completedAt, schemaVersion: schemaVersion))
        return out
    }

    /// Expected record count (graph + Household + receipt) — a cheap post-write sanity check.
    static func expectedCount(_ input: Input) -> Int {
        2 + input.locations.count + input.tags.count + input.seeds.count + input.seedPhotos.count
          + input.beds.count + input.plantingEvents.count + input.journalEntries.count
          + input.journalEntryPhotos.count + input.checklistItems.count + input.petDepartures.count
    }
}
