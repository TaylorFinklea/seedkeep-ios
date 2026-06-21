import Testing
import Foundation
import SwiftData
@testable import Seedkeep
import SeedkeepKit
import SeedkeepCloudKit

// R1 — the forward migration adapters + planner, exercised against REAL SwiftData models (built
// directly, no container needed since the planner is pure over arrays). Proves each Local* model
// maps to the right CloudKitRecordValue (recordName, key scalars, ref prefix/raw, exclusions) and
// that the plan is dependency-ordered + capped with the receipt.

private func sampleInput() -> HouseholdMigrationPlanner.Input {
    var input = HouseholdMigrationPlanner.Input(
        householdID: "hh1", householdName: "The Garden", householdCreatedAt: 1, householdUpdatedAt: 2)
    input.locations = [LocalLocation(id: "loc1", householdID: "hh1", name: "Garage", sortOrder: 0, createdAt: 1, updatedAt: 2, deletedAt: nil)]
    input.tags = [LocalTag(id: "t1", householdID: "hh1", name: "Heirloom", color: nil, createdAt: 1, updatedAt: 2, deletedAt: nil)]
    input.seeds = [LocalSeed(id: "s1", householdID: "hh1", catalogID: "cat1", state: .active, packetCount: 7,
                             locationID: "loc1", yearPacked: 2024, source: .store, customName: "Brandywine",
                             customVariety: "Brandywine", customCompany: "Baker Creek", customType: "Tomato",
                             notes: nil, tagIDs: ["t1"], growingInfo: nil, createdAt: 1, updatedAt: 2, deletedAt: nil)]
    input.seedPhotos = [LocalSeedPhoto(id: "sp1", seedID: "s1", householdID: "hh1", r2Key: "k/front", role: .front,
                                       width: 1024, height: 768, byteSize: nil, capturedAt: 5)]
    input.beds = [LocalBed(id: "b1", householdID: "hh1", name: "North", bedDescription: nil, widthFeet: 4, lengthFeet: 8, sortOrder: 0, createdAt: 1, updatedAt: 2, deletedAt: nil)]
    input.plantingEvents = [LocalPlantingEvent(id: "pe1", householdID: "hh1", bedID: "b1", seedID: "s1",
                                               catalogSeedID: "cat1", kindRaw: "sowing", plannedFor: "2026-04-15",
                                               completedAt: nil, notes: nil, xFeet: nil, yFeet: nil,
                                               createdAt: 1, updatedAt: 2, deletedAt: nil,
                                               petSeed: "abc", petRarity: "rare", petCreatureKind: "spirit_fox",
                                               petName: "Mossling", petPersonalityJSON: "{}", petSpawnedAt: 9,
                                               petWiltedStreakDays: 3, petLastMoodTickAt: 12345)]
    input.journalEntries = [LocalJournalEntry(id: "je1", householdID: "hh1", occurredOn: "2026-06-17", body: "Sprouted!",
                                              seedID: "s1", bedID: nil, plantingEventID: nil, createdAt: 1, updatedAt: 2, deletedAt: nil)]
    input.journalEntryPhotos = [LocalJournalEntryPhoto(id: "jp1", entryID: "je1", storageKey: "k/1", sortOrder: 0, width: 800, height: nil, createdAt: 1, updatedAt: 2)]
    input.checklistItems = [LocalJournalChecklistItem(id: "ci1", entryID: "je1", text: "Water", completed: true, sortOrder: 0, updatedAt: 7)]
    input.petDepartures = [LocalPetDeparture(plantingEventID: "pe1", goodbyeNoteJSON: nil, reason: "wilted_too_long", fallback: true, createdAt: 1, updatedAt: 2, departedAt: 3, deletedAt: nil)]
    return input
}

private func value(_ plan: [CloudKitRecordValue], _ type: SeedkeepRecordType) -> CloudKitRecordValue? {
    plan.first { $0.type == type }
}
private func index(_ plan: [CloudKitRecordValue], _ type: SeedkeepRecordType) -> Int? {
    plan.firstIndex { $0.type == type }
}

struct HouseholdMigrationPlannerTests {

@Test("plan: count matches expectedCount, Household first, receipt last")
func planShape() {
    let input = sampleInput()
    let plan = HouseholdMigrationPlanner.plan(input, completedAt: 999)
    #expect(plan.count == HouseholdMigrationPlanner.expectedCount(input))
    #expect(plan.first?.type == .household)
    #expect(plan.first?.recordName == "household:hh1")
    #expect(plan.last?.type == .migrationReceipt)
    #expect(plan.last?.recordName == "migrated:hh1")
    #expect(plan.last?.scalars["completedAt"] == .int(999))
}

@Test("plan: cascade children are ordered AFTER their parents")
func planOrdering() {
    let plan = HouseholdMigrationPlanner.plan(sampleInput(), completedAt: 1)
    #expect(index(plan, .seed)! < index(plan, .seedPhoto)!)
    #expect(index(plan, .bed)! < index(plan, .plantingEvent)!)
    #expect(index(plan, .seed)! < index(plan, .plantingEvent)!)
    #expect(index(plan, .journalEntry)! < index(plan, .journalEntryPhoto)!)
    #expect(index(plan, .journalEntry)! < index(plan, .journalChecklistItem)!)
    #expect(index(plan, .plantingEvent)! < index(plan, .petDeparture)!)
}

@Test("adapter: LocalSeed maps fields + ref prefix/raw correctly")
func seedAdapter() {
    let plan = HouseholdMigrationPlanner.plan(sampleInput(), completedAt: 1)
    let seed = value(plan, .seed)!
    #expect(seed.recordName == "seed:s1")
    #expect(seed.scalars["packetCount"] == .int(7))
    #expect(seed.scalars["customType"] == .string("Tomato"))
    #expect(seed.scalars["tagIDs"] == .string(#"["t1"]"#))       // from tagIDsJSON
    #expect(seed.refs["locationID"] == "location:loc1")          // in-zone setNull → prefixed
    #expect(seed.refs["catalogID"] == "cat1")                    // cross-DB → raw
}

@Test("adapter: LocalPlantingEvent syncs pet identity but NOT the iOS-local streak fields")
func plantingEventAdapter() {
    let plan = HouseholdMigrationPlanner.plan(sampleInput(), completedAt: 1)
    let pe = value(plan, .plantingEvent)!
    #expect(pe.recordName == "plantingEvent:pe1")
    #expect(pe.refs["bedID"] == "bed:b1")
    #expect(pe.refs["seedID"] == "seed:s1")
    #expect(pe.refs["catalogSeedID"] == "cat1")
    #expect(pe.scalars["petName"] == .string("Mossling"))
    // The model carried petWiltedStreakDays=3 + petLastMoodTickAt=12345 — they must NOT sync:
    #expect(pe.scalars["petWiltedStreakDays"] == nil)
    #expect(pe.scalars["petLastMoodTickAt"] == nil)
}

@Test("adapter: PetDeparture id == plantingEventID, cascade ref to the parent planting")
func petDepartureAdapter() {
    let plan = HouseholdMigrationPlanner.plan(sampleInput(), completedAt: 1)
    let pd = value(plan, .petDeparture)!
    #expect(pd.recordName == "petDeparture:pe1")
    #expect(pd.refs["plantingEventID"] == "plantingEvent:pe1")
    #expect(pd.scalars["fallback"] == .bool(true))
}

@Test("adapter: JournalChecklistItem Bool completed + cascade ref")
func checklistAdapter() {
    let plan = HouseholdMigrationPlanner.plan(sampleInput(), completedAt: 1)
    let ci = value(plan, .journalChecklistItem)!
    #expect(ci.recordName == "journalChecklistItem:ci1")
    #expect(ci.refs["entryID"] == "journalEntry:je1")
    #expect(ci.scalars["completed"] == .bool(true))
}

@Test("plan: empty household still yields Household + receipt (count 2)")
func emptyHousehold() {
    let input = HouseholdMigrationPlanner.Input(householdID: "hh2", householdName: "Empty", householdCreatedAt: 1, householdUpdatedAt: 1)
    let plan = HouseholdMigrationPlanner.plan(input, completedAt: 1)
    #expect(plan.count == 2)
    #expect(plan.map(\.type) == [.household, .migrationReceipt])
}

@Test("fetchInput: pulls the household's full local graph from a ModelContext")
@MainActor
func fetchInputFromContext() throws {
    let container = makeTestContainer(name: "migPlannerFetch-\(UUID().uuidString)")
    let context = ModelContext(container)
    context.insert(LocalLocation(id: "loc1", householdID: "hh1", name: "Garage", sortOrder: 0, createdAt: 1, updatedAt: 2, deletedAt: nil))
    context.insert(LocalSeed(id: "s1", householdID: "hh1", state: .active, packetCount: 3, source: .store, customName: "X", createdAt: 1, updatedAt: 2))
    context.insert(LocalBed(id: "b1", householdID: "hh1", name: "North", createdAt: 1, updatedAt: 2))
    try context.save()

    let input = HouseholdMigrationPlanner.fetchInput(
        from: context, householdID: "hh1", householdName: "G", householdCreatedAt: 1, householdUpdatedAt: 2)
    #expect(input.seeds.count == 1)
    #expect(input.beds.count == 1)
    #expect(input.locations.count == 1)
    #expect(input.tags.isEmpty)
    #expect(input.plantingEvents.isEmpty)

    let plan = HouseholdMigrationPlanner.plan(input, completedAt: 1)
    #expect(plan.count == HouseholdMigrationPlanner.expectedCount(input))
    #expect(plan.contains { $0.recordName == "seed:s1" })
    #expect(plan.contains { $0.recordName == "bed:b1" })
    #expect(plan.contains { $0.recordName == "location:loc1" })
}

}
