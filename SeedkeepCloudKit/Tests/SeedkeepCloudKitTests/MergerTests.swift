import Testing
import Foundation
import CloudKit
@testable import SeedkeepCloudKit

// Seedkeep CloudKit Phase-0 spike — merger + codec + manifest tests.
// All tests run on the host via `swift test` (no simulator, no iCloud account).
// CKRecord is available headlessly on macOS.
//
// IMPORTANT: Each merge test is designed so a naive whole-record LWW (pick the record
// with the higher updatedAt) would FAIL it. The comments call this out explicitly.

private let zoneID = CKRecordZone.ID(zoneName: "test-zone", ownerName: CKCurrentUserDefaultName)

// MARK: - Seed record helpers

private func seedRecord(
    name: String = "seed-A",
    packetCount: Int,
    updatedAt: Int,
    deletedAt: Int? = nil,
    tagIDsJSON: String = "[]"
) -> CKRecord {
    let recordID = CKRecord.ID(recordName: name, zoneID: zoneID)
    let record = CKRecord(recordType: "Seed", recordID: recordID)
    record["packetCount"] = packetCount as CKRecordValue
    record["updatedAt"]   = updatedAt as CKRecordValue
    if let d = deletedAt {
        record["deletedAt"] = d as CKRecordValue
    }
    record["tagIDs"] = tagIDsJSON as CKRecordValue
    return record
}

private func checklistRecord(
    name: String = "item-A",
    completed: Int,   // 0 or 1 (Bool→INT64, G3)
    updatedAt: Int
) -> CKRecord {
    let recordID = CKRecord.ID(recordName: name, zoneID: zoneID)
    let record = CKRecord(recordType: "JournalChecklistItem", recordID: recordID)
    record["completed"] = completed as CKRecordValue
    record["updatedAt"] = updatedAt as CKRecordValue
    return record
}

// MARK: - Photo helpers (Photos-on-CloudKit D5: create + delete only, never merged field-by-field)

/// A CKAsset backed by a real temp file — CKAsset requires a fileURL.
private func makeTestAsset(bytes: [UInt8] = [0x01, 0x02]) throws -> CKAsset {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try Data(bytes).write(to: url)
    return CKAsset(fileURL: url)
}

// MARK: - packetCount → min(local, remote)

@Test("packetCount: concurrent decrements both survive (min wins, not LWW)")
func packetCountMin() {
    // Scenario: start=10, device A decrements to 8 (t=100), device B decrements to 9 (t=200).
    // LWW would pick device B's record (newer updatedAt) → result=9. Loses A's decrement.
    // min() → result=8. Both decrements survive.
    let local  = seedRecord(name: "seed-X", packetCount: 8, updatedAt: 100)  // A: decremented first
    let remote = seedRecord(name: "seed-X", packetCount: 9, updatedAt: 200)  // B: decremented later

    let merger = SeedkeepRecordMerger()
    let result = merger.resolve(local: local, remote: remote)
    let merged = result.record as! CKRecord

    let mergedCount = merged["packetCount"] as! Int
    #expect(mergedCount == 8)                          // min(8, 9) — both decrements survive
    #expect(mergedCount != 9,                          // naive LWW would pick remote (updatedAt=200)
            "naive LWW would yield 9, dropping A's decrement")
}

@Test("packetCount: commutative — local/remote order does not matter")
func packetCountCommutative() {
    // FRESH records per resolve call: CKRecord is a reference type, so reusing the same objects
    // across both calls would let the first call's mutation leak into the second (the bug that
    // masked the aliasing defect). Each direction must start from pristine inputs.
    let merger = SeedkeepRecordMerger()
    let ab = (merger.resolve(
        local:  seedRecord(name: "seed-X", packetCount: 8, updatedAt: 100),
        remote: seedRecord(name: "seed-X", packetCount: 9, updatedAt: 200)
    ).record as! CKRecord)["packetCount"] as! Int
    let ba = (merger.resolve(
        local:  seedRecord(name: "seed-X", packetCount: 9, updatedAt: 200),
        remote: seedRecord(name: "seed-X", packetCount: 8, updatedAt: 100)
    ).record as! CKRecord)["packetCount"] as! Int
    #expect(ab == ba)  // min is symmetric
    #expect(ab == 8)
}

// MARK: - needsResave for the custom Seed merge path (regression guard for the aliasing bug)

@Test("needsResave: remote-newer concurrent decrement still pushes the min back")
func seedNeedsResaveRemoteNewerDecrement() {
    // Both devices decrement; REMOTE has the higher updatedAt. min() yields local's lower count,
    // which the server does not hold → the merge MUST flag needsResave so the min is pushed back.
    // (Before the aliasing fix this returned false → permanent divergence upward.)
    let local  = seedRecord(name: "seed-R", packetCount: 7, updatedAt: 100)  // older but lower
    let remote = seedRecord(name: "seed-R", packetCount: 9, updatedAt: 200)  // newer, higher
    let result = SeedkeepRecordMerger().resolve(local: local, remote: remote)
    #expect((result.record as! CKRecord)["packetCount"] as! Int == 7)
    #expect(result.needsResave == true, "min differs from the server's count → must resave")
}

@Test("needsResave: remote-newer tag add unions and pushes back")
func seedNeedsResaveRemoteNewerTagAdd() {
    let local  = seedRecord(name: "seed-RT", packetCount: 1, updatedAt: 100, tagIDsJSON: #"["a"]"#)
    let remote = seedRecord(name: "seed-RT", packetCount: 1, updatedAt: 200, tagIDsJSON: #"["b"]"#)
    let result = SeedkeepRecordMerger().resolve(local: local, remote: remote)
    let tags = Set(try! JSONDecoder().decode([String].self,
                   from: ((result.record as! CKRecord)["tagIDs"] as! String).data(using: .utf8)!))
    #expect(tags == ["a", "b"])
    #expect(result.needsResave == true, "union differs from the server's tags → must resave")
}

@Test("needsResave: local delete vs newer remote edit pushes the tombstone back")
func seedNeedsResaveStickyDelete() {
    let deletedLocal = seedRecord(name: "seed-SD", packetCount: 3, updatedAt: 50, deletedAt: 50)
    let editedRemote = seedRecord(name: "seed-SD", packetCount: 3, updatedAt: 200)  // no deletedAt
    let result = SeedkeepRecordMerger().resolve(local: deletedLocal, remote: editedRemote)
    #expect((result.record as! CKRecord)["deletedAt"] as? Int == 50)
    #expect(result.needsResave == true, "server lacks the tombstone → must resave")
}

@Test("needsResave: identical records (remote newer, no custom diff) → false")
func seedNeedsResaveNoChange() {
    let local  = seedRecord(name: "seed-NC", packetCount: 5, updatedAt: 100, tagIDsJSON: #"["x"]"#)
    let remote = seedRecord(name: "seed-NC", packetCount: 5, updatedAt: 200, tagIDsJSON: #"["x"]"#)
    let result = SeedkeepRecordMerger().resolve(local: local, remote: remote)
    #expect(result.needsResave == false, "nothing the server lacks → no resave")
}

@Test("needsResave: equal tag set in different JSON order does NOT trigger a spurious resave")
func seedNeedsResaveTagOrderStable() {
    // Server stores unsorted JSON (plausible post-migration); local holds the same set.
    let local  = seedRecord(name: "seed-TO", packetCount: 1, updatedAt: 100, tagIDsJSON: #"["a","b"]"#)
    let remote = seedRecord(name: "seed-TO", packetCount: 1, updatedAt: 200, tagIDsJSON: #"["b","a"]"#)
    let result = SeedkeepRecordMerger().resolve(local: local, remote: remote)
    #expect(result.needsResave == false, "same set, different order → compare by set, no resave")
}

// MARK: - tagIDs union is add-only (documents the locked CRDT limitation)

@Test("tagIDs union is ADD-ONLY: a removal racing a concurrent edit is reverted")
func tagRemovalIsAddOnly() {
    // Device A removed "tomato" (tagIDs now ["herb"]); device B still holds it and edits concurrently.
    // Union re-adds "tomato" — the removal does not converge. This is the spec's locked behavior
    // (never lose an add); the test pins it so the limitation is intentional, not accidental.
    let removedLocal = seedRecord(name: "seed-RM", packetCount: 1, updatedAt: 200, tagIDsJSON: #"["herb"]"#)
    let staleRemote  = seedRecord(name: "seed-RM", packetCount: 1, updatedAt: 100, tagIDsJSON: #"["herb","tomato"]"#)
    let merged = SeedkeepRecordMerger().resolve(local: removedLocal, remote: staleRemote).record as! CKRecord
    let tags = Set(try! JSONDecoder().decode([String].self, from: (merged["tagIDs"] as! String).data(using: .utf8)!))
    #expect(tags == ["herb", "tomato"], "union is add-only — the removed tag is reverted")
}

// MARK: - deletedAt → sticky (no resurrection)

@Test("deletedAt: deleted record cannot be resurrected by a concurrent edit with newer updatedAt")
func deletedAtSticky() {
    // Scenario: device A soft-deletes the record at t=50 (deletedAt=50).
    // Concurrently, device B edits a non-delete field at t=200 (newer updatedAt, no deletedAt).
    // LWW picks device B (newer updatedAt=200) → result has deletedAt=nil (resurrection!).
    // Sticky rule: any non-nil deletedAt wins regardless of updatedAt ordering.
    let deleted = seedRecord(name: "seed-D", packetCount: 3, updatedAt: 50,  deletedAt: 50)   // A deleted
    let edited  = seedRecord(name: "seed-D", packetCount: 3, updatedAt: 200, deletedAt: nil)  // B edited later

    let merger = SeedkeepRecordMerger()

    // deleted=local, edited=remote
    let r1 = merger.resolve(local: deleted, remote: edited).record as! CKRecord
    #expect(r1["deletedAt"] as? Int == 50, "deletion must survive when merged into the newer edit")

    // deleted=remote, edited=local — order-independent
    let r2 = merger.resolve(local: edited, remote: deleted).record as! CKRecord
    #expect(r2["deletedAt"] as? Int == 50, "deletion must survive regardless of argument order")
}

@Test("deletedAt: nil stays nil when neither side deleted")
func deletedAtNilPreserved() {
    let a = seedRecord(name: "seed-E", packetCount: 5, updatedAt: 10)
    let b = seedRecord(name: "seed-E", packetCount: 4, updatedAt: 20)

    let merger = SeedkeepRecordMerger()
    let merged = merger.resolve(local: a, remote: b).record as! CKRecord
    // deletedAt should be absent (nil) — no ghost tombstone
    #expect(merged["deletedAt"] == nil)
}

// MARK: - tagIDs → set union

@Test("tagIDs: concurrent independent adds from both writers are preserved")
func tagIDsSetUnion() {
    // Device A adds tag "a" and "b". Device B adds "b" and "c" (concurrent — no sync in between).
    // LWW picks the newer record whole — drops the other device's exclusive adds.
    // Set union → {a, b, c}.
    let local  = seedRecord(name: "seed-T", packetCount: 1, updatedAt: 100,
                            tagIDsJSON: #"["a","b"]"#)
    let remote = seedRecord(name: "seed-T", packetCount: 1, updatedAt: 200,
                            tagIDsJSON: #"["b","c"]"#)

    let merger = SeedkeepRecordMerger()
    let merged = merger.resolve(local: local, remote: remote).record as! CKRecord
    let tagJSON = merged["tagIDs"] as! String
    let tagData = tagJSON.data(using: .utf8)!
    let tags    = try! JSONDecoder().decode([String].self, from: tagData)
    let tagSet  = Set(tags)

    #expect(tagSet == ["a", "b", "c"])
    #expect(tagSet.count == 3, "naive LWW would lose either 'a' or 'c'")
}

@Test("tagIDs: disjoint sets union correctly")
func tagIDsDisjoint() {
    let local  = seedRecord(name: "seed-U", packetCount: 1, updatedAt: 50,  tagIDsJSON: #"["x"]"#)
    let remote = seedRecord(name: "seed-U", packetCount: 1, updatedAt: 150, tagIDsJSON: #"["y"]"#)

    let merger = SeedkeepRecordMerger()
    let merged = merger.resolve(local: local, remote: remote).record as! CKRecord
    let tags   = try! JSONDecoder().decode([String].self,
                    from: (merged["tagIDs"] as! String).data(using: .utf8)!)
    #expect(Set(tags) == ["x", "y"])
}

// MARK: - JournalChecklistItem: (completed, updatedAt) as a unit

@Test("checklist: completed=true@t2 beats completed=false@t1 (later wins as pair)")
func checklistCompletedAtLaterWins() {
    // Device A: completed=true at t=200 (later).
    // Device B: completed=false at t=100 (earlier).
    // Result: completed=true (the pair with the higher updatedAt wins whole).
    let completedLater    = checklistRecord(name: "item-1", completed: 1, updatedAt: 200)
    let uncompletedEarlier = checklistRecord(name: "item-1", completed: 0, updatedAt: 100)

    let merger = SeedkeepRecordMerger()
    let res1 = merger.resolve(local: completedLater, remote: uncompletedEarlier)
    #expect((res1.record as! CKRecord)["completed"] as! Int == 1)
    #expect(res1.needsResave == true, "local newer → push the merged pair back (G11)")

    let res2 = merger.resolve(local: uncompletedEarlier, remote: completedLater)
    #expect((res2.record as! CKRecord)["completed"] as! Int == 1)
    #expect(res2.needsResave == false, "remote newer → nothing to push")
}

@Test("checklist: completed=false@t3 beats completed=true@t1 (later uncheck wins as pair)")
func checklistUncheckLaterWins() {
    // Device A: unchecked=false at t=300 (latest, e.g. user unchecked after checking).
    // Device B: checked=true at t=100 (earlier).
    // Result: completed=false (the later updatedAt pair wins).
    let uncheckedLater = checklistRecord(name: "item-2", completed: 0, updatedAt: 300)
    let checkedEarlier = checklistRecord(name: "item-2", completed: 1, updatedAt: 100)

    let merger = SeedkeepRecordMerger()
    let res1 = merger.resolve(local: uncheckedLater, remote: checkedEarlier)
    #expect((res1.record as! CKRecord)["completed"] as! Int == 0)
    #expect((res1.record as! CKRecord)["updatedAt"] as! Int == 300)
    #expect(res1.needsResave == true, "local uncheck newer → push it back")

    let res2 = merger.resolve(local: checkedEarlier, remote: uncheckedLater)
    #expect((res2.record as! CKRecord)["completed"] as! Int == 0)
    #expect(res2.needsResave == false, "remote newer → nothing to push")
}

// MARK: - mergePhoto (Photos-on-CloudKit D5: create + delete only, remote always wins)

@Test("mergePhoto: SeedPhoto — remote wins verbatim and needsResave is false")
func mergePhotoSeedPhotoRemoteWins() throws {
    let asset = try makeTestAsset()
    let recordID = CKRecord.ID(recordName: "seedPhoto:1", zoneID: zoneID)

    let local = CKRecord(recordType: "SeedPhoto", recordID: recordID)
    local["r2Key"] = "local/key" as CKRecordValue

    let remote = CKRecord(recordType: "SeedPhoto", recordID: recordID)
    remote["r2Key"] = "remote/key" as CKRecordValue
    remote["asset"] = asset

    let result = SeedkeepRecordMerger().resolve(local: local, remote: remote)
    let merged = result.record as! CKRecord
    #expect(merged["r2Key"] as? String == "remote/key", "photos are create+delete only — remote always wins")
    #expect((merged["asset"] as? CKAsset)?.fileURL == asset.fileURL)
    #expect(result.needsResave == false)
    #expect(merged["deletedAt"] == nil, "mergePhoto must never write deletedAt")
}

@Test("mergePhoto: JournalEntryPhoto — remote wins even though it declares updatedAt and is older")
func mergePhotoJournalEntryPhotoRemoteWinsDespiteOlderUpdatedAt() throws {
    // JournalEntryPhoto is the one photo type with an `updatedAt` clock, which would let it take
    // mergeDefaultLWW's local-wins bulk copy if it were ever dispatched there. Exhaustive dispatch
    // routes it through mergePhoto instead, so a NEWER local updatedAt must still lose to remote.
    let asset = try makeTestAsset()
    let recordID = CKRecord.ID(recordName: "journalEntryPhoto:1", zoneID: zoneID)

    let local = CKRecord(recordType: "JournalEntryPhoto", recordID: recordID)
    local["updatedAt"] = 200 as CKRecordValue
    local["storageKey"] = "local/key" as CKRecordValue

    let remote = CKRecord(recordType: "JournalEntryPhoto", recordID: recordID)
    remote["updatedAt"] = 100 as CKRecordValue   // OLDER — a naive LWW would pick local
    remote["storageKey"] = "remote/key" as CKRecordValue
    remote["asset"] = asset

    let result = SeedkeepRecordMerger().resolve(local: local, remote: remote)
    let merged = result.record as! CKRecord
    #expect(merged["storageKey"] as? String == "remote/key",
            "naive LWW would pick local (updatedAt=200) — photos are exempt from LWW entirely")
    #expect(result.needsResave == false)
}

@Test("mergePhoto: unavailable remote asset preserves known-good local bytes and hash")
func mergePhotoUnavailableRemoteAssetPreservesLocalBytes() throws {
    let localAsset = try makeTestAsset()
    let recordID = CKRecord.ID(recordName: "seedPhoto:asset-fallback", zoneID: zoneID)

    let local = CKRecord(recordType: "SeedPhoto", recordID: recordID)
    local["r2Key"] = "local/key" as CKRecordValue
    local["asset"] = localAsset
    local["assetSHA256"] = "local-sha" as CKRecordValue

    let remote = CKRecord(recordType: "SeedPhoto", recordID: recordID)
    remote["r2Key"] = "remote/key" as CKRecordValue

    let result = SeedkeepRecordMerger().resolve(local: local, remote: remote)
    let merged = result.record as! CKRecord
    #expect(merged["r2Key"] as? String == "remote/key", "remote scalar metadata still wins")
    #expect((merged["asset"] as? CKAsset)?.fileURL == localAsset.fileURL)
    #expect(merged["assetSHA256"] as? String == "local-sha")
    #expect(result.needsResave == false, "fallback bytes are local materialization, not a mutation")
}

// MARK: - Bulk-copy asset guard (mergeDefaultLWW must never carry a manifest asset key)

@Test("bulk-copy guard: mergeDefaultLWW's local-wins copy never carries a manifest asset field")
func bulkCopyGuardSkipsAssetField() throws {
    // No manifest type routes through mergeDefaultLWW AND declares an asset field today (both
    // photo types go through mergePhoto) — this test exercises the guard directly so it is proven
    // even if a future asset-carrying type is mistakenly left off the exhaustive dispatch's photo
    // case (Photos-on-CloudKit D5's "one-line general guard").
    let asset = try makeTestAsset()
    let recordID = CKRecord.ID(recordName: "journalEntryPhoto:1", zoneID: zoneID)

    let local = CKRecord(recordType: "JournalEntryPhoto", recordID: recordID)
    local["updatedAt"] = 200 as CKRecordValue
    local["asset"] = asset

    let remote = CKRecord(recordType: "JournalEntryPhoto", recordID: recordID)
    remote["updatedAt"] = 100 as CKRecordValue   // local is newer → the bulk-copy path engages

    let result = SeedkeepRecordMerger().mergeDefaultLWW(local: local, remote: remote)
    let merged = result.record as! CKRecord
    #expect(merged["updatedAt"] as? Int == 200, "sanity: the local-wins bulk copy DID run")
    #expect(merged["asset"] == nil, "the asset key must never ride the local-wins bulk copy")
}

// MARK: - Codec round-trip

@Test("codec round-trip: Seed value preserves all fields including Bool→INT64")
func seedCodecRoundTrip() {
    let value = CloudKitRecordValue(
        type: .seed,
        recordName: "seed:abc-123",
        scalars: [
            "customName":    .string("Brandywine Tomato"),
            "customVariety": .string("Brandywine"),
            "customCompany": .string("Baker Creek"),
            "stateRaw":      .string("active"),
            "packetCount":   .int(3),
            "yearPacked":    .int(2024),
            "tagIDs":        .string(#"["heirloom","tomato"]"#),
            "deletedAt":     .int(0),
            "updatedAt":     .int(1_700_000_000),
        ],
        refs: ["locationID": "location:loc-1", "catalogID": "catalog-xyz"]
    )

    let record  = SeedkeepRecordCodec.encode(value, zoneID: zoneID)
    let decoded = SeedkeepRecordCodec.decode(record, as: .seed)

    #expect(decoded == value)
    #expect(record["packetCount"] as? Int == 3)
    #expect(record["updatedAt"]   as? Int == 1_700_000_000)
}

@Test("codec round-trip: JournalChecklistItem Bool field encodes as INT64")
func checklistCodecRoundTrip() {
    let value = CloudKitRecordValue(
        type: .journalChecklistItem,
        recordName: "journalChecklistItem:item-42",
        scalars: [
            "text":      .string("Water seedlings"),
            "completed": .bool(true),   // must encode as INT64 1 (G3)
            "sortOrder": .int(2),
            "updatedAt": .int(1_700_000_100),
        ],
        refs: ["entryID": "journalEntry:entry-7"]   // cascadeParent .deleteSelf → JournalEntry
    )

    let record = SeedkeepRecordCodec.encode(value, zoneID: zoneID)
    // G3: Bool → INT64. The value stored on the CKRecord must be the Int 1 (not a native Bool).
    // On macOS, NSNumber(1) bridges to both Int and Bool via CKRecordValue, so we verify the
    // Int representation is 1 (the CloudKit wire type) and that decoding round-trips correctly.
    #expect(record["completed"] as? Int == 1, "Bool true must encode as INT64 1 (G3)")

    let decoded = SeedkeepRecordCodec.decode(record, as: .journalChecklistItem)
    #expect(decoded == value)
}

// MARK: - recordName builders

@Test("recordName builders produce type-slug-prefixed names")
func recordNameBuilders() {
    #expect(SeedkeepRecordNames.household("hh-1") == "household:hh-1")
    #expect(SeedkeepRecordNames.seed("s-abc") == "seed:s-abc")
    #expect(SeedkeepRecordNames.journalChecklistItem("ci-7") == "journalChecklistItem:ci-7")
    #expect(SeedkeepRecordNames.migrationReceipt("hh-1") == "migrated:hh-1")
    #expect(SeedkeepRecordNames.zoneName(householdID: "hh-1") == "seedkeep-hh-1")
}

// MARK: - ckdsl() manifest generation (smoke)

@Test("ckdsl: Bool fields emit INT64, string fields emit STRING")
func ckdslBoolAsInt64() {
    let dsl = SeedkeepRecordType.seed.ckdsl()
    #expect(dsl.contains("RECORD TYPE Seed ("))
    // packetCount: .int → INT64
    #expect(dsl.contains("packetCount INT64"))
    // tagIDs: .string → STRING
    #expect(dsl.contains("tagIDs STRING"))
    // deletedAt: .int → INT64
    #expect(dsl.contains("deletedAt INT64"))
    // updatedAt: .int → INT64
    #expect(dsl.contains("updatedAt INT64"))
    // grant clauses
    #expect(dsl.contains("GRANT WRITE TO \"_creator\""))
}

@Test("ckdsl: JournalChecklistItem completed is INT64 (Bool→INT64)")
func ckdslChecklistCompleted() {
    let dsl = SeedkeepRecordType.journalChecklistItem.ckdsl()
    #expect(dsl.contains("RECORD TYPE JournalChecklistItem ("))
    #expect(dsl.contains("completed INT64"), "Bool must map to INT64 in CKDSL (G3)")
}

@Test("ckdsl: allCKDSL covers all spike record types")
func ckdslAllCases() {
    let all = SeedkeepRecordType.allCKDSL()
    for type_ in SeedkeepRecordType.allCases {
        #expect(all.contains("RECORD TYPE \(type_.recordTypeName) ("))
    }
    #expect(SeedkeepRecordType.allCases.count == 12)   // 11 garden types + MigrationReceipt
    #expect(all.contains("RECORD TYPE MigrationReceipt ("), "G12 receipt must be schema-deployable")
}

// MARK: - Manifest: namePolicy

@Test("all garden types use pk (preserve-id) recordName policy")
func namePolicyIsPreserveID() {
    // migrationReceipt is the lone .det record (deterministic key on householdID); see
    // FullRosterTests.recordNamePolicies for the full-roster assertion.
    for type_ in SeedkeepRecordType.allCases where type_ != .migrationReceipt {
        #expect(type_.namePolicy == .pk)
    }
}

// MARK: - tagIDs merge helper (unit)

@Test("mergeTagIDs helper: union of two JSON arrays")
func mergeTagIDsHelper() {
    let result = SeedkeepRecordMerger.mergeTagIDs(
        local:  #"["a","b"]"#,
        remote: #"["b","c"]"#
    )
    let tags = try! JSONDecoder().decode([String].self, from: result.data(using: .utf8)!)
    #expect(Set(tags) == ["a", "b", "c"])
}

@Test("mergeTagIDs helper: nil + non-nil")
func mergeTagIDsNil() {
    let result = SeedkeepRecordMerger.mergeTagIDs(local: nil, remote: #"["x"]"#)
    let tags = try! JSONDecoder().decode([String].self, from: result.data(using: .utf8)!)
    #expect(Set(tags) == ["x"])
}
