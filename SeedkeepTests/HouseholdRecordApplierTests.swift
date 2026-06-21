import Testing
import Foundation
import SwiftData
@testable import Seedkeep
import SeedkeepKit
import SeedkeepCloudKit

// R1 — the reverse applier (CloudKitRecordValue → Local*). Each test ROUND-TRIPS: build a real
// model → forward adapter (.cloudKitValue) → applier into a FRESH context → assert the rebuilt
// model matches the original. A lossless round-trip proves both directions agree (ref deprefix,
// type conversion, optional handling). Plus upsert-into-existing and the never-sync streak guard.
@MainActor
struct HouseholdRecordApplierTests {

    private func ctx(_ name: String) -> ModelContext {
        ModelContext(makeTestContainer(name: "applier-\(name)-\(UUID().uuidString)"))
    }
    private func fetchOne<T: PersistentModel>(_ c: ModelContext, _ d: FetchDescriptor<T>) throws -> T {
        try #require(try c.fetch(d).first)
    }

    @Test("rawID strips the slug prefix")
    func rawIDHelper() {
        #expect(SeedkeepRecordNames.rawID("seed:s1") == "s1")
        #expect(SeedkeepRecordNames.rawID("location:loc-1") == "loc-1")
        #expect(SeedkeepRecordNames.rawID("migrated:hh1") == "hh1")
        #expect(SeedkeepRecordNames.rawID("nocolon") == "nocolon")
    }

    @Test("Seed round-trips: refs deprefixed, cross-DB raw, all fields preserved")
    func seedRoundTrip() throws {
        let c = ctx("seed")
        let original = LocalSeed(id: "s1", householdID: "hh1", catalogID: "cat1", state: .saved, packetCount: 7,
                                 locationID: "loc1", yearPacked: 2024, source: .gift, customName: "Brandywine",
                                 customVariety: "BV", customCompany: "BC", customType: "Tomato", notes: "note",
                                 tagIDs: ["a", "b"], growingInfo: nil, createdAt: 100, updatedAt: 200, deletedAt: 300)
        HouseholdRecordApplier.apply(original.cloudKitValue, householdID: "hh1", into: c)
        try c.save()
        let m = try fetchOne(c, FetchDescriptor<LocalSeed>(predicate: #Predicate { $0.id == "s1" }))
        #expect(m.householdID == "hh1")
        #expect(m.stateRaw == "saved")
        #expect(m.sourceRaw == "gift")
        #expect(m.packetCount == 7)
        #expect(m.customName == "Brandywine")
        #expect(m.customType == "Tomato")
        #expect(m.yearPacked == 2024)
        #expect(m.tagIDsJSON == original.tagIDsJSON)
        #expect(m.locationID == "loc1")   // "location:loc1" deprefixed
        #expect(m.catalogID == "cat1")    // cross-DB, raw
        #expect(m.createdAt == 100)
        #expect(m.updatedAt == 200)
        #expect(m.deletedAt == 300)
    }

    @Test("PlantingEvent round-trips refs + pet identity; applier preserves the never-sync streak")
    func plantingEventRoundTripAndStreak() throws {
        let c = ctx("pe")
        // Pre-existing local model already carries a streak (NEVER synced) — apply must not zero it.
        let preexisting = LocalPlantingEvent(id: "pe1", householdID: "hh1", bedID: nil, seedID: nil, kindRaw: "sowing",
                                             plannedFor: "2026-01-01", createdAt: 1, updatedAt: 1,
                                             petWiltedStreakDays: 5, petLastMoodTickAt: 999)
        c.insert(preexisting)
        try c.save()

        let incoming = LocalPlantingEvent(id: "pe1", householdID: "hh1", bedID: "b1", seedID: "s1", catalogSeedID: "cat1",
                                          kindRaw: "transplant", plannedFor: "2026-04-15", createdAt: 1, updatedAt: 9,
                                          petSeed: "abc", petRarity: "rare", petCreatureKind: "spirit_fox",
                                          petName: "Mossling", petPersonalityJSON: "{}", petSpawnedAt: 7)
        HouseholdRecordApplier.apply(incoming.cloudKitValue, householdID: "hh1", into: c)
        try c.save()
        let m = try fetchOne(c, FetchDescriptor<LocalPlantingEvent>(predicate: #Predicate { $0.id == "pe1" }))
        #expect(m.bedID == "b1")              // deprefixed
        #expect(m.seedID == "s1")
        #expect(m.catalogSeedID == "cat1")    // cross-DB raw
        #expect(m.kindRaw == "transplant")
        #expect(m.petName == "Mossling")
        #expect(m.petSpawnedAt == 7)
        #expect(m.petWiltedStreakDays == 5)   // NEVER synced — preserved from the local model
        #expect(m.petLastMoodTickAt == 999)
    }

    @Test("PetDeparture round-trips (id == plantingEventID, Bool fallback)")
    func petDepartureRoundTrip() throws {
        let c = ctx("pd")
        let original = LocalPetDeparture(plantingEventID: "pe9", goodbyeNoteJSON: "{}", reason: "wilted_too_long",
                                         fallback: true, createdAt: 1, updatedAt: 2, departedAt: 3, deletedAt: nil)
        HouseholdRecordApplier.apply(original.cloudKitValue, householdID: "hh1", into: c)
        try c.save()
        let m = try fetchOne(c, FetchDescriptor<LocalPetDeparture>(predicate: #Predicate { $0.plantingEventID == "pe9" }))
        #expect(m.reason == "wilted_too_long")
        #expect(m.fallback == true)
        #expect(m.departedAt == 3)
        #expect(m.goodbyeNoteJSON == "{}")   // the primary payload — must not be dropped
        #expect(m.createdAt == 1)
        #expect(m.updatedAt == 2)
    }

    @Test("JournalEntry round-trips the present parent ref, leaves absent parents nil")
    func journalEntryRoundTrip() throws {
        let c = ctx("je")
        let original = LocalJournalEntry(id: "je1", householdID: "hh1", occurredOn: "2026-06-20", body: "Sprouted!",
                                         seedID: "s1", bedID: nil, plantingEventID: nil, createdAt: 1, updatedAt: 2, deletedAt: nil)
        HouseholdRecordApplier.apply(original.cloudKitValue, householdID: "hh1", into: c)
        try c.save()
        let m = try fetchOne(c, FetchDescriptor<LocalJournalEntry>(predicate: #Predicate { $0.id == "je1" }))
        #expect(m.body == "Sprouted!")
        #expect(m.seedID == "s1")     // deprefixed
        #expect(m.bedID == nil)
        #expect(m.plantingEventID == nil)
    }

    @Test("ChecklistItem round-trips Bool completed + deprefixed entry ref")
    func checklistRoundTrip() throws {
        let c = ctx("ci")
        let original = LocalJournalChecklistItem(id: "ci1", entryID: "je1", text: "Water", completed: true, sortOrder: 2, updatedAt: 7)
        HouseholdRecordApplier.apply(original.cloudKitValue, householdID: "hh1", into: c)
        try c.save()
        let m = try fetchOne(c, FetchDescriptor<LocalJournalChecklistItem>(predicate: #Predicate { $0.id == "ci1" }))
        #expect(m.entryID == "je1")
        #expect(m.completed == true)
        #expect(m.text == "Water")
    }

    @Test("Bed round-trips Double dims; nil dims clear")
    func bedRoundTrip() throws {
        let c = ctx("bed")
        let original = LocalBed(id: "b1", householdID: "hh1", name: "North", bedDescription: "raised",
                                widthFeet: 4.5, lengthFeet: nil, sortOrder: 3, createdAt: 1, updatedAt: 2, deletedAt: nil)
        HouseholdRecordApplier.apply(original.cloudKitValue, householdID: "hh1", into: c)
        try c.save()
        let m = try fetchOne(c, FetchDescriptor<LocalBed>(predicate: #Predicate { $0.id == "b1" }))
        #expect(m.name == "North")
        #expect(m.bedDescription == "raised")
        #expect(m.widthFeet == 4.5)
        #expect(m.lengthFeet == nil)
        #expect(m.sortOrder == 3)
    }

    @Test("SeedPhoto round-trips (cascade ref deprefixed, all immutable fields)")
    func seedPhotoRoundTrip() throws {
        let c = ctx("sp")
        let original = LocalSeedPhoto(id: "sp1", seedID: "s1", householdID: "hh1", r2Key: "k/front", role: .front,
                                      width: 1024, height: 768, byteSize: 4096, capturedAt: 42)
        HouseholdRecordApplier.apply(original.cloudKitValue, householdID: "hh1", into: c)
        try c.save()
        let m = try fetchOne(c, FetchDescriptor<LocalSeedPhoto>(predicate: #Predicate { $0.id == "sp1" }))
        #expect(m.seedID == "s1")          // "seed:s1" deprefixed
        #expect(m.r2Key == "k/front")
        #expect(m.roleRaw == "front")
        #expect(m.width == 1024)
        #expect(m.height == 768)
        #expect(m.byteSize == 4096)
        #expect(m.capturedAt == 42)
    }

    @Test("JournalEntryPhoto round-trips (cascade ref deprefixed, nil dim clears)")
    func journalEntryPhotoRoundTrip() throws {
        let c = ctx("jp")
        let original = LocalJournalEntryPhoto(id: "jp1", entryID: "je1", storageKey: "k/1", sortOrder: 2,
                                              width: 800, height: nil, createdAt: 1, updatedAt: 2)
        HouseholdRecordApplier.apply(original.cloudKitValue, householdID: "hh1", into: c)
        try c.save()
        let m = try fetchOne(c, FetchDescriptor<LocalJournalEntryPhoto>(predicate: #Predicate { $0.id == "jp1" }))
        #expect(m.entryID == "je1")        // "journalEntry:je1" deprefixed
        #expect(m.storageKey == "k/1")
        #expect(m.sortOrder == 2)
        #expect(m.width == 800)
        #expect(m.height == nil)
    }

    @Test("Tag round-trips (non-nil color + deletedAt)")
    func tagRoundTrip() throws {
        let c = ctx("tag")
        let original = LocalTag(id: "t1", householdID: "hh1", name: "Heirloom", color: "#A33", createdAt: 1, updatedAt: 2, deletedAt: 5)
        HouseholdRecordApplier.apply(original.cloudKitValue, householdID: "hh1", into: c)
        try c.save()
        let m = try fetchOne(c, FetchDescriptor<LocalTag>(predicate: #Predicate { $0.id == "t1" }))
        #expect(m.name == "Heirloom")
        #expect(m.color == "#A33")
        #expect(m.deletedAt == 5)
    }

    @Test("ChecklistItem uncheck: an incoming completed=false clears a pre-existing checked item")
    func checklistUncheckUpsert() throws {
        let c = ctx("uncheck")
        let pre = LocalJournalChecklistItem(id: "ci1", entryID: "je1", text: "Water", completed: true, sortOrder: 0, updatedAt: 1)
        c.insert(pre); try c.save()
        // Incoming record has completed=false (a remote uncheck). asBool must return false (not nil),
        // so the ?? fallback does NOT preserve the stale `true`.
        let incoming = LocalJournalChecklistItem(id: "ci1", entryID: "je1", text: "Water", completed: false, sortOrder: 0, updatedAt: 9)
        HouseholdRecordApplier.apply(incoming.cloudKitValue, householdID: "hh1", into: c)
        try c.save()
        let m = try fetchOne(c, FetchDescriptor<LocalJournalChecklistItem>(predicate: #Predicate { $0.id == "ci1" }))
        #expect(m.completed == false, "a remote uncheck must clear the local checked state")
        #expect(m.updatedAt == 9)
    }

    @Test("upsert: applying onto an existing model updates it in place (no duplicate)")
    func upsertExisting() throws {
        let c = ctx("upsert")
        let original = LocalLocation(id: "loc1", householdID: "hh1", name: "Garage", sortOrder: 0, createdAt: 1, updatedAt: 2, deletedAt: nil)
        c.insert(original); try c.save()
        var updated = original.cloudKitValue
        updated.scalars["name"] = .string("Shed")     // a remote edit
        updated.scalars["updatedAt"] = .int(99)
        HouseholdRecordApplier.apply(updated, householdID: "hh1", into: c)
        try c.save()
        let all = try c.fetch(FetchDescriptor<LocalLocation>(predicate: #Predicate { $0.id == "loc1" }))
        #expect(all.count == 1, "upsert must not duplicate")
        #expect(all.first?.name == "Shed")
        #expect(all.first?.updatedAt == 99)
    }
}
