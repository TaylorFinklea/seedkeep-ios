import Testing
import Foundation
import CloudKit
@testable import SeedkeepCloudKit

// Per-type builder fidelity + codec round-trip for the full roster (Seed is covered in
// RecordValuesTests). Each test builds a fixture, asserts the recordName + key ref
// prefix/raw behaviour, and proves a build→encode→decode round-trip preserves everything.

private let zoneID = CKRecordZone.ID(zoneName: "test-zone", ownerName: CKCurrentUserDefaultName)

private func roundTrips(_ v: CloudKitRecordValue, as type: SeedkeepRecordType) -> Bool {
    SeedkeepRecordCodec.decode(SeedkeepRecordCodec.encode(v, zoneID: zoneID), as: type) == v
}

@Test("household builder: recordName + round-trip")
func householdBuilder() {
    let v = SeedkeepRecordValues.household(id: "hh1", name: "The Garden", createdAt: 1, updatedAt: 2)
    #expect(v.recordName == "household:hh1")
    #expect(v.scalars["name"] == .string("The Garden"))
    #expect(roundTrips(v, as: .household))
}

@Test("location builder: round-trip + deletedAt present")
func locationBuilder() {
    let v = SeedkeepRecordValues.location(id: "l1", name: "Garage", sortOrder: 3, createdAt: 1, updatedAt: 2, deletedAt: 9)
    #expect(v.recordName == "location:l1")
    #expect(v.scalars["sortOrder"] == .int(3))
    #expect(v.scalars["deletedAt"] == .int(9))
    #expect(roundTrips(v, as: .location))
}

@Test("tag builder: nil color omitted + round-trip")
func tagBuilder() {
    let v = SeedkeepRecordValues.tag(id: "t1", name: "Heirloom", color: nil, createdAt: 1, updatedAt: 2, deletedAt: nil)
    #expect(v.recordName == "tag:t1")
    #expect(v.scalars["color"] == nil)
    #expect(v.scalars["deletedAt"] == nil)
    #expect(roundTrips(v, as: .tag))
}

@Test("bed builder: Double fields + nil dims omitted + round-trip")
func bedBuilder() {
    let v = SeedkeepRecordValues.bed(id: "b1", name: "North", bedDescription: "raised", widthFeet: 4.5, lengthFeet: nil, sortOrder: 0, createdAt: 1, updatedAt: 2, deletedAt: nil)
    #expect(v.recordName == "bed:b1")
    #expect(v.scalars["widthFeet"] == .double(4.5))
    #expect(v.scalars["lengthFeet"] == nil)
    #expect(roundTrips(v, as: .bed))
}

@Test("plantingEvent builder: in-zone refs prefixed, cross-DB raw, pet fields, round-trip")
func plantingEventBuilder() {
    let v = SeedkeepRecordValues.plantingEvent(
        id: "pe1", bedID: "b1", seedID: "s1", catalogSeedID: "cat-1",
        kindRaw: "sowing", plannedFor: "2026-04-15", completedAt: nil, notes: "rows of 3",
        xFeet: 1.0, yFeet: nil, createdAt: 1, updatedAt: 2, deletedAt: nil,
        petSeed: "abc", petRarity: "rare", petCreatureKind: "spirit_fox", petName: "Mossling",
        petPersonalityJSON: "{}", petSpawnedAt: 5)
    #expect(v.recordName == "plantingEvent:pe1")
    #expect(v.refs["bedID"] == "bed:b1")          // in-zone setNull → prefixed
    #expect(v.refs["seedID"] == "seed:s1")
    #expect(v.refs["catalogSeedID"] == "cat-1")   // cross-DB → raw
    #expect(v.scalars["petName"] == .string("Mossling"))
    #expect(v.scalars["completedAt"] == nil)      // nil optional omitted
    #expect(v.scalars["yFeet"] == nil)
    // iOS-local streak fields are not even parameters — structurally cannot leak:
    #expect(v.scalars["petWiltedStreakDays"] == nil)
    #expect(roundTrips(v, as: .plantingEvent))
}

@Test("petDeparture builder: id == plantingEventID, ref → parent planting, round-trip")
func petDepartureBuilder() {
    let v = SeedkeepRecordValues.petDeparture(
        plantingEventID: "pe9", goodbyeNoteJSON: nil, reason: "wilted_too_long", fallback: true,
        createdAt: 1, updatedAt: 2, departedAt: 3, deletedAt: nil)
    #expect(v.recordName == "petDeparture:pe9")
    #expect(v.refs["plantingEventID"] == "plantingEvent:pe9")   // cascadeParent → prefixed parent
    #expect(v.scalars["fallback"] == .bool(true))
    #expect(roundTrips(v, as: .petDeparture))
}

@Test("journalEntry builder: present parent prefixed, absent parents omitted, round-trip")
func journalEntryBuilder() {
    let v = SeedkeepRecordValues.journalEntry(
        id: "je1", occurredOn: "2026-06-17", body: "Sprouted!", seedID: "s1", bedID: nil,
        plantingEventID: nil, createdAt: 1, updatedAt: 2, deletedAt: nil)
    #expect(v.recordName == "journalEntry:je1")
    #expect(v.refs["seedID"] == "seed:s1")
    #expect(v.refs["bedID"] == nil)               // absent ref omitted
    #expect(v.refs["plantingEventID"] == nil)
    #expect(roundTrips(v, as: .journalEntry))
}

@Test("journalEntryPhoto builder: cascade ref prefixed, nil dims omitted, round-trip")
func journalEntryPhotoBuilder() {
    let v = SeedkeepRecordValues.journalEntryPhoto(
        id: "jp1", entryID: "je1", storageKey: "k/1", sortOrder: 2, width: 800, height: nil,
        createdAt: 1, updatedAt: 2)
    #expect(v.recordName == "journalEntryPhoto:jp1")
    #expect(v.refs["entryID"] == "journalEntry:je1")
    #expect(v.scalars["width"] == .int(800))
    #expect(v.scalars["height"] == nil)
    #expect(roundTrips(v, as: .journalEntryPhoto))
}

@Test("seedPhoto builder: cascade ref prefixed, immutable fields, round-trip")
func seedPhotoBuilder() {
    let v = SeedkeepRecordValues.seedPhoto(
        id: "sp1", seedID: "s1", r2Key: "k/front", roleRaw: "front", width: 1024, height: 768,
        byteSize: nil, capturedAt: 42)
    #expect(v.recordName == "seedPhoto:sp1")
    #expect(v.refs["seedID"] == "seed:s1")
    #expect(v.scalars["byteSize"] == nil)
    #expect(v.scalars["capturedAt"] == .int(42))
    #expect(roundTrips(v, as: .seedPhoto))
}

@Test("journalChecklistItem builder: Bool→INT64 completed, cascade ref, round-trip")
func journalChecklistItemBuilder() {
    let v = SeedkeepRecordValues.journalChecklistItem(
        id: "ci1", entryID: "je1", text: "Water", completed: true, sortOrder: 0, updatedAt: 7)
    #expect(v.recordName == "journalChecklistItem:ci1")
    #expect(v.refs["entryID"] == "journalEntry:je1")
    #expect(v.scalars["completed"] == .bool(true))
    #expect(roundTrips(v, as: .journalChecklistItem))
}

@Test("migrationReceipt builder: deterministic migrated:<id> recordName + round-trip")
func migrationReceiptBuilder() {
    let v = SeedkeepRecordValues.migrationReceipt(householdID: "hh1", completedAt: 100, schemaVersion: 1)
    #expect(v.recordName == "migrated:hh1")   // NOT "migrationReceipt:hh1" — deterministic per G12
    #expect(v.scalars["completedAt"] == .int(100))
    #expect(v.scalars["schemaVersion"] == .int(1))
    #expect(roundTrips(v, as: .migrationReceipt))
}
