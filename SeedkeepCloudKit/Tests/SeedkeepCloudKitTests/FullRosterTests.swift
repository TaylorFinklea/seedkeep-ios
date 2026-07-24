import Testing
import Foundation
import CloudKit
@testable import SeedkeepCloudKit

// R1 full-roster tests — the 8 record types added beyond the 3-type spike, plus the
// default-LWW merge path, the reference graph (cascade / setNull / crossDB), client-side
// cascade detection, and manifest invariants. Host-only (`swift test`), no simulator.

private let zoneID = CKRecordZone.ID(zoneName: "test-zone", ownerName: CKCurrentUserDefaultName)

@Test("delete failure policy retries transient errors, accepts absence, and surfaces permanent failures")
func deleteFailurePolicy() {
    #expect(HouseholdSyncEngine.deleteFailureDisposition(for: .unknownItem) == .confirmedAbsent)
    #expect(HouseholdSyncEngine.deleteFailureDisposition(for: .zoneNotFound) == .confirmedAbsent)
    #expect(HouseholdSyncEngine.deleteFailureDisposition(for: .networkFailure) == .retry)
    #expect(HouseholdSyncEngine.deleteFailureDisposition(for: .batchRequestFailed) == .retry)
    #expect(HouseholdSyncEngine.deleteFailureDisposition(for: .permissionFailure) == .surface)
}

@Test("account lifecycle gate rejects work until explicitly reactivated")
func accountLifecycleGate() {
    let gate = HouseholdEngineLifecycleGate()
    var executions = 0

    #expect(gate.withActive { executions += 1 } != nil)
    #expect(gate.retireIfActive(when: { true }, perform: {}) == true)
    #expect(gate.withActive { executions += 1 } == nil)
    #expect(executions == 1)

    gate.activate()

    #expect(gate.withActive { executions += 1 } != nil)
    #expect(executions == 2)
}

// MARK: - Default LWW merge (all non-custom types)

private func record(_ type: String, name: String, updatedAt: Int?, displayName: String) -> CKRecord {
    let r = CKRecord(recordType: type, recordID: CKRecord.ID(recordName: name, zoneID: zoneID))
    if let updatedAt { r["updatedAt"] = updatedAt as CKRecordValue }
    r["name"] = displayName as CKRecordValue
    return r
}

@Test("default LWW: local strictly newer wins whole-record + needsResave")
func defaultLWWLocalNewer() {
    let local  = record("Bed", name: "bed:1", updatedAt: 200, displayName: "Raised North")
    let remote = record("Bed", name: "bed:1", updatedAt: 100, displayName: "Old Name")

    let merger = SeedkeepRecordMerger()
    let result = merger.resolve(local: local, remote: remote)
    let merged = result.record as! CKRecord
    #expect(merged["name"] as! String == "Raised North")
    #expect(result.needsResave == true)
}

@Test("default LWW: remote newer keeps remote, no resave")
func defaultLWWRemoteNewer() {
    let local  = record("Bed", name: "bed:2", updatedAt: 100, displayName: "Stale")
    let remote = record("Bed", name: "bed:2", updatedAt: 200, displayName: "Fresh")

    let merger = SeedkeepRecordMerger()
    let result = merger.resolve(local: local, remote: remote)
    let merged = result.record as! CKRecord
    #expect(merged["name"] as! String == "Fresh")
    #expect(result.needsResave == false)
}

@Test("default LWW: equal updatedAt keeps remote (deterministic tie-break)")
func defaultLWWTie() {
    let local  = record("Location", name: "location:1", updatedAt: 100, displayName: "Garage")
    let remote = record("Location", name: "location:1", updatedAt: 100, displayName: "Shed")

    let merger = SeedkeepRecordMerger()
    let result = merger.resolve(local: local, remote: remote)
    #expect((result.record as! CKRecord)["name"] as! String == "Shed")
    #expect(result.needsResave == false)
}

@Test("default LWW: type with no updatedAt (SeedPhoto) keeps remote on tie")
func defaultLWWNoClock() {
    let local  = record("SeedPhoto", name: "seedPhoto:1", updatedAt: nil, displayName: "local")
    let remote = record("SeedPhoto", name: "seedPhoto:1", updatedAt: nil, displayName: "remote")

    let merger = SeedkeepRecordMerger()
    let result = merger.resolve(local: local, remote: remote)
    #expect((result.record as! CKRecord)["name"] as! String == "remote")
    #expect(result.needsResave == false)
}

@Test("default LWW: PlantingEvent (pet identity fields) takes LWW, not Seed's custom rules")
func defaultLWWPlantingEvent() {
    let local  = record("PlantingEvent", name: "plantingEvent:1", updatedAt: 300, displayName: "n/a")
    local["petName"] = "Mossling" as CKRecordValue
    let remote = record("PlantingEvent", name: "plantingEvent:1", updatedAt: 200, displayName: "n/a")
    remote["petName"] = "OldName" as CKRecordValue

    let merger = SeedkeepRecordMerger()
    let merged = merger.resolve(local: local, remote: remote).record as! CKRecord
    #expect(merged["petName"] as! String == "Mossling")  // local newer → whole-record LWW
}

// MARK: - Reference round-trips (cascade / setNull / crossDB)

@Test("codec: SeedPhoto cascadeParent ref round-trips as .deleteSelf CKReference")
func seedPhotoCascadeRef() {
    let value = CloudKitRecordValue(
        type: .seedPhoto,
        recordName: "seedPhoto:p1",
        scalars: ["r2Key": .string("k/abc"), "roleRaw": .string("front"), "capturedAt": .int(1_700_000_000)],
        refs: ["seedID": "seed:s1"]
    )
    let record  = SeedkeepRecordCodec.encode(value, zoneID: zoneID)
    let ref     = record["seedID"] as? CKRecord.Reference
    #expect(ref?.action == .deleteSelf, "cascadeParent must encode .deleteSelf")
    #expect(ref?.recordID.recordName == "seed:s1")

    let decoded = SeedkeepRecordCodec.decode(record, as: .seedPhoto)
    #expect(decoded == value)
}

@Test("codec: PlantingEvent setNull refs encode .none; crossDB encodes STRING")
func plantingEventRefs() {
    let value = CloudKitRecordValue(
        type: .plantingEvent,
        recordName: "plantingEvent:1",
        scalars: ["kindRaw": .string("sowing"), "plannedFor": .string("2026-04-15"), "updatedAt": .int(10)],
        refs: ["bedID": "bed:b1", "seedID": "seed:s1", "catalogSeedID": "cat-42"]
    )
    let record = SeedkeepRecordCodec.encode(value, zoneID: zoneID)
    #expect((record["bedID"]  as? CKRecord.Reference)?.action == CKRecord.ReferenceAction.none)
    #expect((record["seedID"] as? CKRecord.Reference)?.action == CKRecord.ReferenceAction.none)
    #expect(record["catalogSeedID"] as? String == "cat-42", "crossDB ref must be a plain String, never a CKReference")
    #expect(record["catalogSeedID"] as? CKRecord.Reference == nil)

    let decoded = SeedkeepRecordCodec.decode(record, as: .plantingEvent)
    #expect(decoded == value)
}

@Test("codec: JournalEntry at-most-one-parent refs all round-trip as setNull")
func journalEntryRefs() {
    // Real entries carry at most one parent, but the codec must handle each independently.
    let value = CloudKitRecordValue(
        type: .journalEntry,
        recordName: "journalEntry:1",
        scalars: ["occurredOn": .string("2026-06-17"), "body": .string("Sprouted!"), "updatedAt": .int(5)],
        refs: ["seedID": "seed:s1"]
    )
    let record = SeedkeepRecordCodec.encode(value, zoneID: zoneID)
    #expect((record["seedID"] as? CKRecord.Reference)?.action == CKRecord.ReferenceAction.none)
    #expect(record["bedID"] == nil)             // absent ref → null on the record
    #expect(record["plantingEventID"] == nil)
    #expect(SeedkeepRecordCodec.decode(record, as: .journalEntry) == value)
}

@Test("codec: PetDeparture cascadeParent + fallback Bool→INT64 round-trip")
func petDepartureRoundTrip() {
    let value = CloudKitRecordValue(
        type: .petDeparture,
        recordName: "petDeparture:pe1",
        scalars: ["reason": .string("wilted_too_long"), "fallback": .bool(true),
                  "departedAt": .int(1_700_000_500), "updatedAt": .int(1_700_000_500)],
        refs: ["plantingEventID": "plantingEvent:pe1"]
    )
    let record = SeedkeepRecordCodec.encode(value, zoneID: zoneID)
    #expect(record["fallback"] as? Int == 1, "Bool true → INT64 1 (G3)")
    #expect((record["plantingEventID"] as? CKRecord.Reference)?.action == .deleteSelf)
    #expect(SeedkeepRecordCodec.decode(record, as: .petDeparture) == value)
}

// MARK: - Client-side cascade detection (G5)

@Test("recordIDsCascadingFrom finds .deleteSelf children of a parent")
func cascadeDetection() {
    let store = HouseholdLocalStore()
    let seedName = "seed:s1"

    let photo = CKRecord(recordType: "SeedPhoto",
                         recordID: CKRecord.ID(recordName: "seedPhoto:p1", zoneID: zoneID))
    photo["seedID"] = CKRecord.Reference(
        recordID: CKRecord.ID(recordName: seedName, zoneID: zoneID), action: .deleteSelf)
    store.setRecord(photo)

    // A setNull ref to the same seed must NOT be swept (only .deleteSelf cascades).
    let entry = CKRecord(recordType: "JournalEntry",
                         recordID: CKRecord.ID(recordName: "journalEntry:j1", zoneID: zoneID))
    entry["seedID"] = CKRecord.Reference(
        recordID: CKRecord.ID(recordName: seedName, zoneID: zoneID), action: .none)
    store.setRecord(entry)

    let cascading = store.recordIDsCascadingFrom(seedName).map(\.recordName)
    #expect(cascading == ["seedPhoto:p1"])
    #expect(!cascading.contains("journalEntry:j1"), "setNull (.none) ref must not cascade")
}

// MARK: - recordName builders (full roster)

@Test("recordName builders cover all 11 types and match recordName(for:id:)")
func recordNameBuildersFullRoster() {
    #expect(SeedkeepRecordNames.location("l1") == "location:l1")
    #expect(SeedkeepRecordNames.tag("t1") == "tag:t1")
    #expect(SeedkeepRecordNames.seedPhoto("sp1") == "seedPhoto:sp1")
    #expect(SeedkeepRecordNames.bed("b1") == "bed:b1")
    #expect(SeedkeepRecordNames.plantingEvent("pe1") == "plantingEvent:pe1")
    #expect(SeedkeepRecordNames.journalEntry("je1") == "journalEntry:je1")
    #expect(SeedkeepRecordNames.journalEntryPhoto("jp1") == "journalEntryPhoto:jp1")
    #expect(SeedkeepRecordNames.petDeparture("pe1") == "petDeparture:pe1")

    // The generic builder (migration's single entry point) must agree with each specific one.
    #expect(SeedkeepRecordNames.recordName(for: .seed, id: "x") == SeedkeepRecordNames.seed("x"))
    #expect(SeedkeepRecordNames.recordName(for: .petDeparture, id: "pe1") == SeedkeepRecordNames.petDeparture("pe1"))
    #expect(SeedkeepRecordNames.recordName(for: .journalEntryPhoto, id: "jp1") == "journalEntryPhoto:jp1")
}

// MARK: - ckdsl reference + scalar emission across the roster

@Test("ckdsl: cascade + setNull refs emit REFERENCE; crossDB emits STRING")
func ckdslReferenceEmission() {
    let seedPhoto = SeedkeepRecordType.seedPhoto.ckdsl()
    #expect(seedPhoto.contains("seedID REFERENCE"))      // cascadeParent

    let seed = SeedkeepRecordType.seed.ckdsl()
    #expect(seed.contains("locationID REFERENCE"))       // setNullInZone
    #expect(seed.contains("catalogID STRING"))           // crossDBString — NOT a reference
    #expect(!seed.contains("catalogID REFERENCE"))

    let pe = SeedkeepRecordType.plantingEvent.ckdsl()
    #expect(pe.contains("bedID REFERENCE"))
    #expect(pe.contains("seedID REFERENCE"))
    #expect(pe.contains("catalogSeedID STRING"))
}

@Test("ckdsl: allCKDSL emits an importable schema covering the full roster")
func ckdslCoversFullRoster() {
    let all = SeedkeepRecordType.allCKDSL()
    #expect(all.hasPrefix("DEFINE SCHEMA\n\n"))
    for t in SeedkeepRecordType.allCases {
        #expect(all.contains("RECORD TYPE \(t.recordTypeName) ("))
    }
}

// MARK: - Manifest invariants

@Test("type(forRecordTypeName:) resolves every type name back to its case; nil for unknowns")
func typeForRecordTypeName() {
    for t in SeedkeepRecordType.allCases {
        #expect(SeedkeepRecordType.type(forRecordTypeName: t.recordTypeName) == t)
    }
    #expect(SeedkeepRecordType.type(forRecordTypeName: "MigrationReceipt") == .migrationReceipt)  // slug ≠ rawValue
    #expect(SeedkeepRecordType.type(forRecordTypeName: "NotAType") == nil)
}

@Test("merger handles every manifest type and rejects unknowns")
func mergerHandlesAll() {
    let merger = SeedkeepRecordMerger()
    for t in SeedkeepRecordType.allCases {
        #expect(merger.handles(t.recordTypeName), "merger must handle \(t.recordTypeName)")
    }
    #expect(!merger.handles("NotARealType"))
}

@Test("no record carries householdID (the zone IS the household boundary)")
func noHouseholdIDField() {
    for t in SeedkeepRecordType.allCases {
        #expect(!t.fields.contains { $0.name == "householdID" }, "\(t.recordTypeName) must not have a householdID field")
        #expect(!t.refs.contains { $0.name == "householdID" })
    }
}

@Test("PlantingEvent syncs server-authored pet identity but excludes iOS-local streak fields")
func plantingEventPetFields() {
    let fields = Set(SeedkeepRecordType.plantingEvent.fields.map(\.name))
    // Server-of-record identity — synced:
    for f in ["petSeed", "petRarity", "petCreatureKind", "petName", "petPersonalityJSON", "petSpawnedAt"] {
        #expect(fields.contains(f), "synced pet identity field \(f) missing")
    }
    // iOS-local streak counters — NEVER sync:
    #expect(!fields.contains("petWiltedStreakDays"))
    #expect(!fields.contains("petLastMoodTickAt"))
}

@Test("garden types preserve-id; migrationReceipt is the lone deterministic-key record")
func recordNamePolicies() {
    for t in SeedkeepRecordType.allCases where t != .migrationReceipt {
        #expect(t.namePolicy == .pk, "\(t.recordTypeName) must preserve its id")
    }
    #expect(SeedkeepRecordType.migrationReceipt.namePolicy == .det)
    #expect(SeedkeepRecordType.allCases.count == 12)   // 11 garden types + MigrationReceipt
}

@Test("recordName(for:id:) agrees with the type-slug for every garden type, and migrated:<id> for the receipt")
func recordNameForAllTypes() {
    for t in SeedkeepRecordType.allCases where t != .migrationReceipt {
        #expect(SeedkeepRecordNames.recordName(for: t, id: "x") == "\(t.rawValue):x")
    }
    #expect(SeedkeepRecordNames.recordName(for: .migrationReceipt, id: "hh-1") == "migrated:hh-1")
    #expect(SeedkeepRecordNames.recordName(for: .migrationReceipt, id: "hh-1")
            == SeedkeepRecordNames.migrationReceipt("hh-1"))
}

// MARK: - Universal sticky tombstone (deletedAt is sticky for ALL soft-deletable types, not just Seed)

@Test("default LWW: a deleted Bed is NOT resurrected by a concurrent newer edit")
func universalStickyDeletedAt() {
    // Device A deletes a bed (deletedAt=50, updatedAt=50). Device B edits it concurrently
    // (updatedAt=200, no deletedAt). A naive LWW resurrects the bed. The universal sticky rule
    // keeps it deleted — and flags needsResave so the tombstone propagates back.
    let deleted = record("Bed", name: "bed:del", updatedAt: 50, displayName: "Doomed")
    deleted["deletedAt"] = 50 as CKRecordValue
    let edited = record("Bed", name: "bed:del", updatedAt: 200, displayName: "Renamed")

    let merger = SeedkeepRecordMerger()
    let r1 = merger.resolve(local: deleted, remote: edited)
    #expect((r1.record as! CKRecord)["deletedAt"] as? Int == 50, "delete must survive the newer edit")
    #expect(r1.needsResave == true, "server lacks the tombstone → must resave")

    // Order-independent: deleted as remote, edited as local.
    let r2 = merger.resolve(local: edited, remote: deleted)
    #expect((r2.record as! CKRecord)["deletedAt"] as? Int == 50, "sticky regardless of argument order")
}

@Test("default LWW: a Location with no tombstone on either side stays undeleted")
func universalStickyNoGhost() {
    let a = record("Location", name: "location:g", updatedAt: 10, displayName: "Garage")
    let b = record("Location", name: "location:g", updatedAt: 20, displayName: "Shed")
    let merged = SeedkeepRecordMerger().resolve(local: a, remote: b).record as! CKRecord
    #expect(merged["deletedAt"] == nil)
}

@Test("default LWW: the universal sticky-delete rule covers PlantingEvent + JournalEntry too, not just Bed")
func universalStickyMoreTypes() {
    let merger = SeedkeepRecordMerger()
    for typeName in ["PlantingEvent", "JournalEntry", "Tag", "Location"] {
        let deleted = record(typeName, name: "x:1", updatedAt: 50, displayName: "del")
        deleted["deletedAt"] = 50 as CKRecordValue
        let edited = record(typeName, name: "x:1", updatedAt: 200, displayName: "edit")   // newer, NOT deleted
        let r = merger.resolve(local: deleted, remote: edited)
        #expect((r.record as! CKRecord)["deletedAt"] as? Int == 50, "\(typeName): delete must survive a newer concurrent edit")
        #expect(r.needsResave == true, "\(typeName): the server lacks the tombstone → resave")
    }
}

@Test("default LWW: two concurrent tombstones converge on the max (commutative)")
func stickyDeletedAtBothSidesMax() {
    let merger = SeedkeepRecordMerger()
    let a = record("Bed", name: "bed:m", updatedAt: 10, displayName: "a"); a["deletedAt"] = 50 as CKRecordValue
    let b = record("Bed", name: "bed:m", updatedAt: 20, displayName: "b"); b["deletedAt"] = 100 as CKRecordValue
    #expect((merger.resolve(local: a, remote: b).record as! CKRecord)["deletedAt"] as? Int == 100)
    #expect((merger.resolve(local: b, remote: a).record as! CKRecord)["deletedAt"] as? Int == 100)
}

// MARK: - JournalChecklistItem has no createdAt (consistent with the model + DB)

@Test("JournalChecklistItem omits createdAt (matches the SwiftData model + DB schema)")
func checklistNoCreatedAt() {
    let fields = Set(SeedkeepRecordType.journalChecklistItem.fields.map(\.name))
    #expect(!fields.contains("createdAt"), "model + DB have no created_at on checklist items")
    #expect(fields.contains("updatedAt"))
}
