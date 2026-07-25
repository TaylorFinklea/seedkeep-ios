import Testing
import Foundation
import CloudKit
@testable import SeedkeepCloudKit

// Canonical household-graph digest — the verification primitive both the deleting owner and the
// successor run over their own copy of the garden before the source zone may be deleted.
//
// The digest must be a pure function of the APPLICATION graph: identical for the same records in
// any order, in any zone, on either device; different the moment a scalar, a reference target, or
// a reference action moves. CloudKit's own bookkeeping (change tags, share records, parent
// pointers, undeclared keys) must never reach the hash, or the two devices would never agree.

private let sourceZone = CKRecordZone.ID(zoneName: "seedkeep-hh1", ownerName: CKCurrentUserDefaultName)
private let otherZone = CKRecordZone.ID(zoneName: "seedkeep-hh1", ownerName: "_successor")

private func makeRecord(
    _ type: SeedkeepRecordType,
    _ recordName: String,
    in zone: CKRecordZone.ID = sourceZone,
    scalars: [String: CKRecordValue] = [:],
    refs: [String: CKRecord.Reference] = [:]
) -> CKRecord {
    let record = CKRecord(recordType: type.recordTypeName,
                          recordID: CKRecord.ID(recordName: recordName, zoneID: zone))
    for (key, value) in scalars { record[key] = value }
    for (key, value) in refs { record[key] = value }
    return record
}

private func inZoneRef(_ name: String, _ action: CKRecord.ReferenceAction,
                       in zone: CKRecordZone.ID = sourceZone) -> CKRecord.Reference {
    CKRecord.Reference(recordID: CKRecord.ID(recordName: name, zoneID: zone), action: action)
}

/// A small but representative graph: two root types, a set-null child, a cascade child,
/// a cross-DB string ref, and a Bool field.
private func sampleGraph(in zone: CKRecordZone.ID = sourceZone) -> [CKRecord] {
    [
        makeRecord(.household, "household:hh1", in: zone,
                   scalars: ["name": "Finklea Garden" as CKRecordValue,
                             "createdAt": 1_700_000_000_000 as CKRecordValue,
                             "updatedAt": 1_700_000_000_500 as CKRecordValue]),
        makeRecord(.location, "location:l1", in: zone,
                   scalars: ["name": "Garage shelf" as CKRecordValue,
                             "sortOrder": 1 as CKRecordValue]),
        makeRecord(.seed, "seed:s1", in: zone,
                   scalars: ["customName": "Brandywine" as CKRecordValue,
                             "packetCount": 3 as CKRecordValue],
                   refs: ["locationID": inZoneRef("location:l1", .none, in: zone)]),
        makeRecord(.seedPhoto, "seedPhoto:p1", in: zone,
                   scalars: ["r2Key": "k/abc" as CKRecordValue,
                             "width": 800 as CKRecordValue],
                   refs: ["seedID": inZoneRef("seed:s1", .deleteSelf, in: zone)]),
        makeRecord(.journalEntry, "journalEntry:j1", in: zone,
                   scalars: ["occurredOn": "2026-04-15" as CKRecordValue]),
        makeRecord(.journalChecklistItem, "journalChecklistItem:c1", in: zone,
                   scalars: ["text": "Water" as CKRecordValue, "completed": 1 as CKRecordValue],
                   refs: ["entryID": inZoneRef("journalEntry:j1", .deleteSelf, in: zone)]),
    ]
}

// MARK: - Order independence

@Test("the digest is identical for any input record order")
func digestIgnoresRecordOrder() throws {
    let graph = sampleGraph()
    let forward = try HouseholdGraphDigester.digest(of: graph)
    let reversed = try HouseholdGraphDigester.digest(of: graph.reversed())
    let rotated = try HouseholdGraphDigester.digest(of: Array(graph[2...] + graph[..<2]))

    #expect(forward == reversed)
    #expect(forward == rotated)
    #expect(forward.sha256.count == 64, "SHA-256 must render as 64 lowercase hex characters")
    #expect(forward.sha256 == forward.sha256.lowercased())
}

@Test("the digest is identical regardless of the order fields were written onto the record")
func digestIgnoresFieldOrder() throws {
    let a = CKRecord(recordType: "Bed", recordID: CKRecord.ID(recordName: "bed:b1", zoneID: sourceZone))
    a["name"] = "North" as CKRecordValue
    a["sortOrder"] = 2 as CKRecordValue
    a["widthFeet"] = 4.5 as CKRecordValue

    let b = CKRecord(recordType: "Bed", recordID: CKRecord.ID(recordName: "bed:b1", zoneID: sourceZone))
    b["widthFeet"] = 4.5 as CKRecordValue
    b["name"] = "North" as CKRecordValue
    b["sortOrder"] = 2 as CKRecordValue

    #expect(try HouseholdGraphDigester.digest(of: [a]) == HouseholdGraphDigester.digest(of: [b]))
}

// MARK: - Zone independence (the owner/successor agreement)

@Test("the digest ignores zone identity on both record IDs and in-zone references")
func digestIgnoresZoneID() throws {
    let here = try HouseholdGraphDigester.digest(of: sampleGraph(in: sourceZone))
    let there = try HouseholdGraphDigester.digest(of: sampleGraph(in: otherZone))
    #expect(here == there, "owner and successor hash the same graph in differently-owned zones")
}

// MARK: - System / share exclusion

@Test("CKShare, unknown record types, and undeclared keys never reach the digest")
func digestExcludesShareAndSystemRecords() throws {
    let baseline = try HouseholdGraphDigester.digest(of: sampleGraph())

    var polluted = sampleGraph()
    polluted.append(CKShare(recordZoneID: sourceZone))
    polluted.append(CKRecord(recordType: "NotASeedkeepType",
                             recordID: CKRecord.ID(recordName: "junk:1", zoneID: sourceZone)))
    // An undeclared key on a manifest record is CloudKit debris, not application state.
    polluted[0]["someUndeclaredKey"] = "noise" as CKRecordValue

    let dirty = try HouseholdGraphDigester.digest(of: polluted)
    #expect(dirty == baseline)
    #expect(dirty.counts["cloudkit.share"] == nil)
    #expect(dirty.counts["NotASeedkeepType"] == nil)
}

@Test("a record's system parent pointer is framework metadata and is excluded")
func digestExcludesParentPointer() throws {
    let plain = sampleGraph()
    let parented = sampleGraph()
    parented[3].parent = CKRecord.Reference(
        recordID: CKRecord.ID(recordName: "seed:s1", zoneID: sourceZone), action: .none)

    #expect(try HouseholdGraphDigester.digest(of: plain) == HouseholdGraphDigester.digest(of: parented))
}

// MARK: - Per-type counts

@Test("per-type counts are exact and keyed by CloudKit record type name")
func digestCountsAreExact() throws {
    var graph = sampleGraph()
    graph.append(makeRecord(.seed, "seed:s2", scalars: ["customName": "Cherokee" as CKRecordValue]))
    graph.append(CKShare(recordZoneID: sourceZone))

    let digest = try HouseholdGraphDigester.digest(of: graph)
    #expect(digest.counts == [
        "Household": 1, "Location": 1, "Seed": 2, "SeedPhoto": 1,
        "JournalEntry": 1, "JournalChecklistItem": 1,
    ])
    #expect(digest.recordCount == 7)
}

@Test("an empty graph digests deterministically to zero records")
func digestOfEmptyGraph() throws {
    let empty = try HouseholdGraphDigester.digest(of: [])
    #expect(empty.counts.isEmpty)
    #expect(empty.recordCount == 0)
    #expect(try empty == HouseholdGraphDigester.digest(of: [CKShare(recordZoneID: sourceZone)]))
    #expect(empty.sha256.count == 64)
}

// MARK: - Content sensitivity

@Test("changing any scalar changes the digest")
func digestDetectsScalarChange() throws {
    let baseline = try HouseholdGraphDigester.digest(of: sampleGraph())

    let changed = sampleGraph()
    changed[2]["packetCount"] = 4 as CKRecordValue
    #expect(try HouseholdGraphDigester.digest(of: changed) != baseline)

    let renamed = sampleGraph()
    renamed[0]["name"] = "Finklea Garden " as CKRecordValue
    #expect(try HouseholdGraphDigester.digest(of: renamed) != baseline)
}

@Test("dropping a record or renaming one changes the digest")
func digestDetectsRosterChange() throws {
    let baseline = try HouseholdGraphDigester.digest(of: sampleGraph())

    var dropped = sampleGraph()
    dropped.removeLast()
    #expect(try HouseholdGraphDigester.digest(of: dropped) != baseline)

    var renamed = sampleGraph()
    renamed[4] = makeRecord(.journalEntry, "journalEntry:j2",
                            scalars: ["occurredOn": "2026-04-15" as CKRecordValue])
    #expect(try HouseholdGraphDigester.digest(of: renamed) != baseline)
}

@Test("changing a reference target changes the digest")
func digestDetectsReferenceTargetChange() throws {
    let baseline = try HouseholdGraphDigester.digest(of: sampleGraph())
    let repointed = sampleGraph()
    repointed[2]["locationID"] = inZoneRef("location:l2", .none)
    #expect(try HouseholdGraphDigester.digest(of: repointed) != baseline)
}

@Test("changing a reference ACTION changes the digest even when the target is identical")
func digestDetectsReferenceActionChange() throws {
    let baseline = try HouseholdGraphDigester.digest(of: sampleGraph())
    let hardened = sampleGraph()
    hardened[2]["locationID"] = inZoneRef("location:l1", .deleteSelf)
    #expect(try HouseholdGraphDigester.digest(of: hardened) != baseline,
            "a .none → .deleteSelf drift would silently change cascade behaviour after transfer")
}

@Test("an absent field is distinguishable from a present one")
func digestDistinguishesAbsentField() throws {
    let absent = makeRecord(.location, "location:l1", scalars: ["name": "Shelf" as CKRecordValue])
    let present = makeRecord(.location, "location:l1",
                             scalars: ["name": "Shelf" as CKRecordValue, "deletedAt": 0 as CKRecordValue])
    #expect(try HouseholdGraphDigester.digest(of: [absent]) != HouseholdGraphDigester.digest(of: [present]))
}

@Test("changing a cross-DB string reference changes the digest and it is never zone-qualified")
func digestDetectsCrossDBChange() throws {
    let a = makeRecord(.seed, "seed:s1", scalars: ["catalogID": "cat-1" as CKRecordValue])
    let b = makeRecord(.seed, "seed:s1", scalars: ["catalogID": "cat-2" as CKRecordValue])
    let aElsewhere = makeRecord(.seed, "seed:s1", in: otherZone,
                                scalars: ["catalogID": "cat-1" as CKRecordValue])

    #expect(try HouseholdGraphDigester.digest(of: [a]) != HouseholdGraphDigester.digest(of: [b]))
    #expect(try HouseholdGraphDigester.digest(of: [a]) == HouseholdGraphDigester.digest(of: [aElsewhere]))
}

@Test("bool fields canonicalize to true/false rather than their INT64 storage value")
func digestCanonicalizesBool() throws {
    func item(_ completed: Int) -> CKRecord {
        makeRecord(.journalChecklistItem, "journalChecklistItem:c1",
                   scalars: ["text": "Water" as CKRecordValue, "completed": completed as CKRecordValue])
    }
    #expect(try HouseholdGraphDigester.digest(of: [item(1)]) == HouseholdGraphDigester.digest(of: [item(2)]))
    #expect(try HouseholdGraphDigester.digest(of: [item(1)]) != HouseholdGraphDigester.digest(of: [item(0)]))
}

// MARK: - Canonical encoding is unambiguous

@Test("field values cannot forge extra canonical lines")
func digestEscapesSeparators() throws {
    // Without escaping, the smuggled newline+tab would reproduce the two-field document byte-for-byte.
    let smuggled = makeRecord(.location, "location:l1",
                              scalars: ["name": "Shelf\nF\tsortOrder\ti:5" as CKRecordValue])
    let honest = makeRecord(.location, "location:l1",
                            scalars: ["name": "Shelf" as CKRecordValue, "sortOrder": 5 as CKRecordValue])
    #expect(try HouseholdGraphDigester.digest(of: [smuggled]) != HouseholdGraphDigester.digest(of: [honest]))
}

@Test("the canonical document is versioned, sorted by type then record name, and field-sorted")
func digestCanonicalDocumentShape() throws {
    // seed:s1 mixes scalars and references so the field sort is proven to be by NAME, not by
    // manifest order (which would emit every scalar before every reference).
    let document = try HouseholdGraphDigester.canonicalDocument(of: [
        makeRecord(.seed, "seed:s2", scalars: ["packetCount": 2 as CKRecordValue,
                                               "customName": "B" as CKRecordValue]),
        makeRecord(.seed, "seed:s1", scalars: ["customName": "A" as CKRecordValue,
                                               "catalogID": "cat-9" as CKRecordValue],
                   refs: ["locationID": inZoneRef("location:l1", .none)]),
        makeRecord(.location, "location:l1", scalars: ["name": "Shelf" as CKRecordValue]),
    ])
    #expect(document == """
        \(HouseholdGraphDigester.formatVersion)
        R\tLocation\tlocation:l1
        F\tname\ts:Shelf
        R\tSeed\tseed:s1
        F\tcatalogID\tx:cat-9
        F\tcustomName\ts:A
        F\tlocationID\tr:none:location:l1
        R\tSeed\tseed:s2
        F\tcustomName\ts:B
        F\tpacketCount\ti:2

        """)
}

@Test("records sort by record TYPE first, then record name")
func digestSortsByTypeBeforeName() throws {
    // Seedkeep's real record names are slug-prefixed by type, so type-order and name-order agree
    // on production data. These synthetic names separate the two so the documented key is pinned.
    let document = try HouseholdGraphDigester.canonicalDocument(of: [
        makeRecord(.seed, "aaa:1", scalars: ["customName": "A" as CKRecordValue]),
        makeRecord(.bed, "zzz:1", scalars: ["name": "Z" as CKRecordValue]),
    ])
    #expect(document == """
        \(HouseholdGraphDigester.formatVersion)
        R\tBed\tzzz:1
        F\tname\ts:Z
        R\tSeed\taaa:1
        F\tcustomName\ts:A

        """)
}

// MARK: - Rejections

@Test("duplicate record names are rejected rather than silently collapsed")
func digestRejectsDuplicateRecordNames() throws {
    let graph = [
        makeRecord(.seed, "seed:s1", scalars: ["customName": "A" as CKRecordValue]),
        makeRecord(.seed, "seed:s1", scalars: ["customName": "B" as CKRecordValue]),
    ]
    #expect(throws: HouseholdGraphDigestError.duplicateRecordName("seed:s1")) {
        try HouseholdGraphDigester.digest(of: graph)
    }
}

@Test("a manifest field holding an unsupported value type is rejected")
func digestRejectsUnsupportedScalar() throws {
    let record = makeRecord(.seed, "seed:s1", scalars: ["packetCount": "three" as CKRecordValue])
    #expect(throws: HouseholdGraphDigestError.unsupportedValue(
        recordType: "Seed", recordName: "seed:s1", field: "packetCount")) {
        try HouseholdGraphDigester.digest(of: [record])
    }
}

@Test("an in-zone reference field holding a bare string is rejected")
func digestRejectsUnsupportedReference() throws {
    let record = makeRecord(.seed, "seed:s1", scalars: ["locationID": "location:l1" as CKRecordValue])
    #expect(throws: HouseholdGraphDigestError.unsupportedValue(
        recordType: "Seed", recordName: "seed:s1", field: "locationID")) {
        try HouseholdGraphDigester.digest(of: [record])
    }
}

@Test("a cross-DB reference field holding a CKReference is rejected")
func digestRejectsCrossDBReferenceValue() throws {
    let record = makeRecord(.seed, "seed:s1", refs: ["catalogID": inZoneRef("cat-1", .none)])
    #expect(throws: HouseholdGraphDigestError.unsupportedValue(
        recordType: "Seed", recordName: "seed:s1", field: "catalogID")) {
        try HouseholdGraphDigester.digest(of: [record])
    }
}

// MARK: - Scalar encoding (every manifest field type, including ones no type declares yet)

@Test("every CKFieldType has an injective canonical encoding")
func canonicalScalarEncoding() {
    #expect(CanonicalRecordEncoder.encodeScalar("a\tb" as NSString, as: .string) == #"s:a\tb"#)
    #expect(CanonicalRecordEncoder.encodeScalar(7 as NSNumber, as: .int) == "i:7")
    #expect(CanonicalRecordEncoder.encodeScalar(-7 as NSNumber, as: .int) == "i:-7")
    #expect(CanonicalRecordEncoder.encodeScalar(0.5 as NSNumber, as: .double) == "d:3fe0000000000000")
    #expect(CanonicalRecordEncoder.encodeScalar(0.0 as NSNumber, as: .double)
            != CanonicalRecordEncoder.encodeScalar(-0.0 as NSNumber, as: .double),
            "the double encoding is exact, not value-normalised")
    #expect(CanonicalRecordEncoder.encodeScalar(1 as NSNumber, as: .bool) == "b:1")
    #expect(CanonicalRecordEncoder.encodeScalar(0 as NSNumber, as: .bool) == "b:0")
    // Dates canonicalize to unix milliseconds so two devices agree despite sub-ms round-trip drift.
    #expect(CanonicalRecordEncoder.encodeScalar(Date(timeIntervalSince1970: 1.5) as NSDate, as: .date)
            == "t:1500")
    #expect(CanonicalRecordEncoder.encodeScalar(Date(timeIntervalSince1970: 1.0004) as NSDate, as: .date)
            == "t:1000")
    #expect(CanonicalRecordEncoder.encodeScalar("x" as NSString, as: .int) == nil)
    #expect(CanonicalRecordEncoder.encodeScalar(3 as NSNumber, as: .string) == nil)
}
