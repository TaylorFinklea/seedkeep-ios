import Foundation
import SwiftData
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

    /// Build the export Input by fetching the household's full local graph from `context`.
    /// Single-household-per-user (R1 locked decision): the local store holds exactly one
    /// household's data, so this fetches all of each type. @MainActor — SwiftData's ModelContext
    /// is main-actor-bound in this app.
    @MainActor
    static func fetchInput(from context: ModelContext, householdID: String, householdName: String,
                           householdCreatedAt: Int64, householdUpdatedAt: Int64) -> Input {
        func fetch<T: PersistentModel>(_ d: FetchDescriptor<T>) -> [T] { (try? context.fetch(d)) ?? [] }
        let hid = householdID
        var input = Input(householdID: householdID, householdName: householdName,
                          householdCreatedAt: householdCreatedAt, householdUpdatedAt: householdUpdatedAt)
        // Filter household-scoped types by householdID — defensive against a stale record left by a
        // silently-failed sign-out wipe (AppEnvironment's best-effort eraser), which would otherwise
        // export a FORMER household's data into this household's zone.
        input.locations      = fetch(FetchDescriptor<LocalLocation>(predicate: #Predicate { $0.householdID == hid }))
        input.tags           = fetch(FetchDescriptor<LocalTag>(predicate: #Predicate { $0.householdID == hid }))
        input.seeds          = fetch(FetchDescriptor<LocalSeed>(predicate: #Predicate { $0.householdID == hid }))
        input.seedPhotos     = fetch(FetchDescriptor<LocalSeedPhoto>(predicate: #Predicate { $0.householdID == hid }))
        input.beds           = fetch(FetchDescriptor<LocalBed>(predicate: #Predicate { $0.householdID == hid }))
        input.plantingEvents = fetch(FetchDescriptor<LocalPlantingEvent>(predicate: #Predicate { $0.householdID == hid }))
        input.journalEntries = fetch(FetchDescriptor<LocalJournalEntry>(predicate: #Predicate { $0.householdID == hid }))
        // Journal children carry no householdID. Scope them through the active-garden parent set;
        // a participant also retains a parked solo household locally, so fetching every child would
        // export that parked graph into the adopted owner's CloudKit zone.
        let journalEntryIDs = Set(input.journalEntries.map(\.id))
        input.journalEntryPhotos = fetch(FetchDescriptor<LocalJournalEntryPhoto>())
            .filter { journalEntryIDs.contains($0.entryID) }
        input.checklistItems = fetch(FetchDescriptor<LocalJournalChecklistItem>())
            .filter { journalEntryIDs.contains($0.entryID) }
        // PetDeparture is likewise parent-scoped rather than household-bearing.
        let plantingEventIDs = Set(input.plantingEvents.map(\.id))
        input.petDepartures = fetch(FetchDescriptor<LocalPetDeparture>())
            .filter { plantingEventIDs.contains($0.plantingEventID) }
        return input
    }

    /// Expected record count (graph + Household + receipt) — a cheap post-write sanity check.
    /// Derived from `plan()` itself (pure, no side effects) so it can never drift from the plan
    /// when a new record type is added.
    static func expectedCount(_ input: Input) -> Int {
        plan(input, completedAt: 0).count
    }
}
