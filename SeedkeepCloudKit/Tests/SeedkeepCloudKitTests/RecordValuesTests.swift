import Testing
import Foundation
import CloudKit
@testable import SeedkeepCloudKit

// Migration forward-mapping tests — the generic manifest-driven builder (the ref prefix/raw
// hazard + optional omission) and the Seed reference builder, plus a full codec round-trip.

private let zoneID = CKRecordZone.ID(zoneName: "test-zone", ownerName: CKCurrentUserDefaultName)

// MARK: - Generic core: ref prefix/raw hazard + optional omission

@Test("recordValue: in-zone refs get the prefixed target recordName; cross-DB refs stay raw")
func recordValueRefKinds() {
    // PlantingEvent: bedID/seedID are in-zone (setNull) → prefixed; catalogSeedID is cross-DB → raw.
    let value = SeedkeepRecordValues.recordValue(
        type: .plantingEvent,
        id: "pe1",
        scalars: ["kindRaw": .string("sowing"), "plannedFor": .string("2026-04-15"), "updatedAt": .int(10)],
        refIDs: ["bedID": "b1", "seedID": "s1", "catalogSeedID": "cat-42"])

    #expect(value.recordName == "plantingEvent:pe1")
    #expect(value.refs["bedID"] == "bed:b1", "in-zone setNull ref must be prefixed with the target slug")
    #expect(value.refs["seedID"] == "seed:s1")
    #expect(value.refs["catalogSeedID"] == "cat-42", "cross-DB ref must stay the RAW external id")
}

@Test("recordValue: a cascadeParent ref is prefixed with the parent's slug")
func recordValueCascadeRefPrefixed() {
    let value = SeedkeepRecordValues.recordValue(
        type: .seedPhoto, id: "p1",
        scalars: ["r2Key": .string("k/abc"), "roleRaw": .string("front"), "capturedAt": .int(1)],
        refIDs: ["seedID": "s1"])
    #expect(value.refs["seedID"] == "seed:s1")
}

@Test("scalars/refIDs helpers drop nil optionals")
func optionalsDropped() {
    let s = SeedkeepRecordValues.scalars(["a": .int(1), "b": nil, "c": .string("x")])
    #expect(Set(s.keys) == ["a", "c"])
    let r = SeedkeepRecordValues.refIDs(["x": "1", "y": nil])
    #expect(Set(r.keys) == ["x"])
}

@Test("inZoneRecordName resolves every in-zone target type to its slug")
func inZoneTargetResolution() {
    #expect(SeedkeepRecordValues.inZoneRecordName(targetType: "Location", id: "l1") == "location:l1")
    #expect(SeedkeepRecordValues.inZoneRecordName(targetType: "Bed", id: "b1") == "bed:b1")
    #expect(SeedkeepRecordValues.inZoneRecordName(targetType: "JournalEntry", id: "j1") == "journalEntry:j1")
    #expect(SeedkeepRecordValues.inZoneRecordName(targetType: "PlantingEvent", id: "pe1") == "plantingEvent:pe1")
}

// MARK: - Seed builder (reference pattern) — fidelity + round-trip

@Test("seed builder: full field fidelity, ref prefix/raw, optional omission")
func seedBuilderFidelity() {
    let v = SeedkeepRecordValues.seed(
        id: "abc-123",
        customName: "Brandywine Tomato",
        customVariety: "Brandywine",
        customCompany: "Baker Creek",
        customType: "Tomato",
        notes: nil,                       // omitted
        stateRaw: "active",
        sourceRaw: "store",
        packetCount: 3,
        yearPacked: nil,                  // omitted
        tagIDsJSON: #"["heirloom","tomato"]"#,
        growingInfoJSON: nil,             // omitted
        catalogID: "cat-xyz",
        locationID: "loc-1",
        createdAt: 1_700_000_000,
        updatedAt: 1_700_000_100,
        deletedAt: nil)

    #expect(v.recordName == "seed:abc-123")
    #expect(v.scalars["customName"] == .string("Brandywine Tomato"))
    #expect(v.scalars["customType"] == .string("Tomato"))
    #expect(v.scalars["packetCount"] == .int(3))
    #expect(v.scalars["tagIDs"] == .string(#"["heirloom","tomato"]"#))   // tagIDsJSON → "tagIDs"
    #expect(v.scalars["createdAt"] == .int(1_700_000_000))
    // Omitted optionals are absent:
    #expect(v.scalars["notes"] == nil)
    #expect(v.scalars["yearPacked"] == nil)
    #expect(v.scalars["growingInfoJSON"] == nil)
    #expect(v.scalars["deletedAt"] == nil)
    // Refs: locationID prefixed (in-zone), catalogID raw (cross-DB):
    #expect(v.refs["locationID"] == "location:loc-1")
    #expect(v.refs["catalogID"] == "cat-xyz")
}

@Test("seed builder: round-trips through the codec (build → encode → decode)")
func seedBuilderRoundTrip() {
    let v = SeedkeepRecordValues.seed(
        id: "rt-1", customName: "X", customVariety: nil, customCompany: nil, customType: nil,
        notes: "note", stateRaw: "active", sourceRaw: "gift", packetCount: 9, yearPacked: 2024,
        tagIDsJSON: "[]", growingInfoJSON: nil, catalogID: nil, locationID: "loc-9",
        createdAt: 1, updatedAt: 2, deletedAt: 5)
    let decoded = SeedkeepRecordCodec.decode(SeedkeepRecordCodec.encode(v, zoneID: zoneID), as: .seed)
    #expect(decoded == v)
    #expect(decoded.scalars["deletedAt"] == .int(5))
    #expect(decoded.refs["locationID"] == "location:loc-9")
}
