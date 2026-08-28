import Testing
import Foundation
import CloudKit
@testable import SeedkeepCloudKit

// Household graph copy planning and execution — the pure half of transfer-by-copy.
//
// The owner hands the planner every record fetched from the source zone plus the successor-owned
// destination zone ID and gets back save batches that reproduce the garden verbatim. The plan is
// pure, so a retry after a partial save overwrites exactly the same destination record IDs with
// exactly the same content, and the source records are never touched.
//
// Two things the plan alone cannot promise, and which are therefore executed and tested here
// against a fake destination that models CloudKit's optimistic concurrency:
//   - the successor's Household root ALREADY EXISTS before the copy starts (they created and
//     shared it), so a freshly built, change-tag-less record must still overwrite it;
//   - a resumed copy re-saves records the first attempt already landed.
// Both only work under an all-keys save policy, so that policy is part of the plan, not a comment.

private let copySource = CKRecordZone.ID(zoneName: "seedkeep-hh1", ownerName: CKCurrentUserDefaultName)
private let copyDestination = CKRecordZone.ID(zoneName: "seedkeep-hh1", ownerName: "_successor")
private let strayZone = CKRecordZone.ID(zoneName: "seedkeep-stray", ownerName: "_other")

private func sourceRecord(
    _ type: SeedkeepRecordType,
    _ recordName: String,
    in zone: CKRecordZone.ID = copySource,
    scalars: [String: CKRecordValue] = [:],
    refs: [String: CKRecord.Reference] = [:]
) -> CKRecord {
    let record = CKRecord(recordType: type.recordTypeName,
                          recordID: CKRecord.ID(recordName: recordName, zoneID: zone))
    for (key, value) in scalars { record[key] = value }
    for (key, value) in refs { record[key] = value }
    return record
}

private func ref(_ name: String, _ action: CKRecord.ReferenceAction,
                 in zone: CKRecordZone.ID = copySource) -> CKRecord.Reference {
    CKRecord.Reference(recordID: CKRecord.ID(recordName: name, zoneID: zone), action: action)
}

/// Two cascade families, a set-null child, a cross-DB scalar ref, and the MigrationReceipt.
private func transferGraph() -> [CKRecord] {
    [
        sourceRecord(.household, "household:hh1",
                     scalars: ["name": "Finklea Garden" as CKRecordValue, "updatedAt": 12 as CKRecordValue]),
        sourceRecord(.location, "location:l1", scalars: ["name": "Garage shelf" as CKRecordValue]),
        sourceRecord(.seed, "seed:s1",
                     scalars: ["customName": "Brandywine" as CKRecordValue,
                               "packetCount": 3 as CKRecordValue,
                               "catalogID": "cat-42" as CKRecordValue],
                     refs: ["locationID": ref("location:l1", .none)]),
        sourceRecord(.seedPhoto, "seedPhoto:p1",
                     scalars: ["r2Key": "k/abc" as CKRecordValue],
                     refs: ["seedID": ref("seed:s1", .deleteSelf)]),
        sourceRecord(.journalEntry, "journalEntry:j1",
                     scalars: ["occurredOn": "2026-04-15" as CKRecordValue]),
        sourceRecord(.journalChecklistItem, "journalChecklistItem:c1",
                     scalars: ["text": "Water" as CKRecordValue, "completed": 1 as CKRecordValue],
                     refs: ["entryID": ref("journalEntry:j1", .deleteSelf)]),
        sourceRecord(.journalEntryPhoto, "journalEntryPhoto:jp1",
                     scalars: ["storageKey": "k/xyz" as CKRecordValue],
                     refs: ["entryID": ref("journalEntry:j1", .deleteSelf)]),
        sourceRecord(.migrationReceipt, "migrated:hh1",
                     scalars: ["completedAt": 99 as CKRecordValue, "schemaVersion": 1 as CKRecordValue]),
    ]
}

private func plannedGraph() throws -> HouseholdGraphCopyPlan {
    try HouseholdGraphCopier.plan(transferGraph(), from: copySource, to: copyDestination)
}

private func planned(_ plan: HouseholdGraphCopyPlan, _ recordName: String) throws -> CKRecord {
    try #require(plan.records.first { $0.recordID.recordName == recordName })
}

// MARK: - Fake destination zone

private enum FakeSaveFailure: Error, Equatable {
    /// CloudKit's `serverRecordChanged`: a record with no change tag cannot overwrite an existing
    /// one under the default save policy.
    case conflict(String)
    /// An injected mid-copy interruption (network drop, app termination).
    case interrupted
}

/// In-memory stand-in for the successor's destination zone. Models the one CloudKit behaviour the
/// copy contract depends on: overwriting an existing record ID with a tag-less record requires
/// `.allKeys`.
private final class FakeDestinationZone {
    private(set) var stored: [String: CKRecord] = [:]
    private(set) var batchLog: [[String]] = []
    private var savesCompleted = 0
    /// Throw `.interrupted` once this many records have been written.
    var interruptAfter: Int?

    func seed(_ record: CKRecord) { stored[record.recordID.recordName] = record }

    var contents: [CKRecord] { Array(stored.values) }

    func save(_ records: [CKRecord],
              policy: CKModifyRecordsOperation.RecordSavePolicy) throws {
        batchLog.append(records.map(\.recordID.recordName))
        for record in records {
            let name = record.recordID.recordName
            if stored[name] != nil, policy != .allKeys {
                throw FakeSaveFailure.conflict(name)
            }
            if let limit = interruptAfter, savesCompleted == limit {
                throw FakeSaveFailure.interrupted
            }
            stored[name] = record
            savesCompleted += 1
        }
    }

    func saver() -> HouseholdGraphBatchSaver {
        { [unowned self] records, policy in try self.save(records, policy: policy) }
    }
}

private func destinationDigest(_ zone: FakeDestinationZone) throws -> HouseholdGraphDigest {
    try HouseholdGraphDigester.digest(of: zone.contents, in: copyDestination)
}

private func sourceDigest() throws -> HouseholdGraphDigest {
    try HouseholdGraphDigester.digest(of: transferGraph(), in: copySource)
}

// MARK: - Faithful reproduction

@Test("every copied record keeps its type, record name, and application fields in the new zone")
func copyPreservesIdentityAndFields() throws {
    let plan = try plannedGraph()
    #expect(plan.records.count == 8)
    #expect(plan.destinationZoneID == copyDestination)

    let seed = try planned(plan, "seed:s1")
    #expect(seed.recordType == "Seed")
    #expect(seed.recordID.zoneID == copyDestination)
    #expect(seed["customName"] as? String == "Brandywine")
    #expect(seed["packetCount"] as? Int == 3)
}

@Test("in-zone references are retargeted to the destination zone with their action preserved")
func copyRetargetsReferences() throws {
    let plan = try plannedGraph()

    let setNull = try #require(try planned(plan, "seed:s1")["locationID"] as? CKRecord.Reference)
    #expect(setNull.recordID == CKRecord.ID(recordName: "location:l1", zoneID: copyDestination))
    #expect(setNull.action == .none, "a soft parent link must not become a hard cascade")

    let cascade = try #require(try planned(plan, "seedPhoto:p1")["seedID"] as? CKRecord.Reference)
    #expect(cascade.recordID == CKRecord.ID(recordName: "seed:s1", zoneID: copyDestination))
    #expect(cascade.action == .deleteSelf)
}

@Test("cross-DB reference ids stay verbatim strings, never zone-qualified references")
func copyKeepsCrossDBIDs() throws {
    let seed = try planned(plannedGraph(), "seed:s1")
    #expect(seed["catalogID"] as? String == "cat-42")
    #expect(seed["catalogID"] as? CKRecord.Reference == nil)
}

@Test("the MigrationReceipt is copied so the successor never reruns the legacy import")
func copyIncludesMigrationReceipt() throws {
    let plan = try plannedGraph()
    let receipt = try planned(plan, "migrated:hh1")
    #expect(receipt.recordType == "MigrationReceipt")
    #expect(receipt.recordID.zoneID == copyDestination)
    #expect(receipt["completedAt"] as? Int == 99)
    #expect(receipt["schemaVersion"] as? Int == 1)
    #expect(plan.counts["MigrationReceipt"] == 1)
}

@Test("the copied graph digests identically to the source graph")
func copyMatchesSourceDigest() throws {
    let plan = try plannedGraph()
    #expect(try HouseholdGraphDigester.digest(of: plan.records, in: copyDestination) == sourceDigest())
}

@Test("plan counts agree with the digest counts the two devices compare")
func copyCountsMatchDigest() throws {
    let plan = try plannedGraph()
    #expect(plan.counts == (try HouseholdGraphDigester.digest(of: plan.records, in: copyDestination)).counts)
    #expect(plan.counts == ["Household": 1, "Location": 1, "Seed": 1, "SeedPhoto": 1,
                            "JournalEntry": 1, "JournalChecklistItem": 1, "JournalEntryPhoto": 1,
                            "MigrationReceipt": 1])
}

// MARK: - Ordering

@Test("cascade parents are batched strictly ahead of their children")
func copyOrdersParentsFirst() throws {
    let plan = try plannedGraph()
    #expect(plan.batches.count == 2)

    func index(_ name: String) throws -> Int {
        try #require(plan.records.firstIndex { $0.recordID.recordName == name })
    }
    #expect(try index("seed:s1") < index("seedPhoto:p1"))
    #expect(try index("journalEntry:j1") < index("journalChecklistItem:c1"))
    #expect(try index("journalEntry:j1") < index("journalEntryPhoto:jp1"))

    #expect(!plan.batches[0].map(\.recordID.recordName).contains("seedPhoto:p1"))
    #expect(Set(plan.batches[1].map(\.recordID.recordName))
            == ["seedPhoto:p1", "journalChecklistItem:c1", "journalEntryPhoto:jp1"])
}

@Test("a deeper cascade chain gets one batch per generation")
func copyOrdersMultiGenerationCascades() throws {
    // seedPhoto:p2 hangs off seedPhoto:p1 hangs off seed:s1 — three save generations.
    let graph = [
        sourceRecord(.seed, "seed:s1", scalars: ["customName": "A" as CKRecordValue]),
        sourceRecord(.seedPhoto, "seedPhoto:p1", refs: ["seedID": ref("seed:s1", .deleteSelf)]),
        sourceRecord(.seedPhoto, "seedPhoto:p2", refs: ["seedID": ref("seedPhoto:p1", .deleteSelf)]),
    ]
    let plan = try HouseholdGraphCopier.plan(graph, from: copySource, to: copyDestination)
    #expect(plan.batches.map { $0.map(\.recordID.recordName) }
            == [["seed:s1"], ["seedPhoto:p1"], ["seedPhoto:p2"]])
}

@Test("records within a batch are ordered by record type then record name")
func copyTieOrderIsDeterministic() throws {
    let plan = try plannedGraph()
    #expect(plan.batches[0].map(\.recordID.recordName)
            == ["household:hh1", "journalEntry:j1", "location:l1", "migrated:hh1", "seed:s1"])
    #expect(plan.batches[1].map(\.recordID.recordName)
            == ["journalChecklistItem:c1", "journalEntryPhoto:jp1", "seedPhoto:p1"])
}

// MARK: - Filtering vs. fail-closed

@Test("CKShare is a recognised system record and is never copied into the successor's zone")
func copySkipsShareRecords() throws {
    var graph = transferGraph()
    graph.append(CKShare(recordZoneID: copySource))

    let plan = try HouseholdGraphCopier.plan(graph, from: copySource, to: copyDestination)
    #expect(plan.records.count == 8)
    #expect(!plan.records.contains { $0.recordType == "cloudkit.share" })
}

@Test("an unrecognised record type FAILS the copy instead of being silently dropped")
func copyRejectsUnknownRecordType() throws {
    var graph = transferGraph()
    graph.append(CKRecord(recordType: "SoilReading",
                          recordID: CKRecord.ID(recordName: "soilReading:1", zoneID: copySource)))

    #expect(throws: HouseholdGraphCopyError.unknownRecordType(
        recordType: "SoilReading", recordName: "soilReading:1")) {
        try HouseholdGraphCopier.plan(graph, from: copySource, to: copyDestination)
    }
}

@Test("an undeclared key on a known record FAILS the copy instead of being silently dropped")
func copyRejectsUndeclaredField() throws {
    let graph = transferGraph()
    graph[2]["germinationRate"] = 0.9 as CKRecordValue

    #expect(throws: HouseholdGraphCopyError.undeclaredField(
        recordType: "Seed", recordName: "seed:s1", field: "germinationRate")) {
        try HouseholdGraphCopier.plan(graph, from: copySource, to: copyDestination)
    }
}

// MARK: - Idempotency and source preservation

@Test("re-planning after a partial save reproduces byte-identical destination records")
func copyRetryIsIdempotent() throws {
    let first = try plannedGraph()
    let second = try plannedGraph()

    #expect(first.batches.map { $0.map(\.recordID) } == second.batches.map { $0.map(\.recordID) })
    #expect(try HouseholdGraphDigester.canonicalDocument(of: first.records, in: copyDestination)
            == HouseholdGraphDigester.canonicalDocument(of: second.records, in: copyDestination))
    #expect(first.counts == second.counts)
}

@Test("planning never mutates the source records or their zone")
func copyLeavesSourceUntouched() throws {
    let source = transferGraph()
    let before = try HouseholdGraphDigester.canonicalDocument(of: source, in: copySource)

    _ = try HouseholdGraphCopier.plan(source, from: copySource, to: copyDestination)

    #expect(try HouseholdGraphDigester.canonicalDocument(of: source, in: copySource) == before)
    #expect(source.allSatisfy { $0.recordID.zoneID == copySource })
    let sourceRef = try #require(source[3]["seedID"] as? CKRecord.Reference)
    #expect(sourceRef.recordID.zoneID == copySource, "the source reference must still point in-zone")
}

@Test("planned records are distinct objects from the source records")
func copyProducesFreshRecords() throws {
    let source = transferGraph()
    let plan = try HouseholdGraphCopier.plan(source, from: copySource, to: copyDestination)
    for planned in plan.records {
        #expect(!source.contains { $0 === planned })
    }
}

@Test("an asset copy uses a fresh CKAsset wrapper around the observed file")
func copyProducesFreshAssetWrappers() throws {
    let fileURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("HouseholdGraphCopierAsset-\(UUID().uuidString).jpg")
    try Data("copied-asset-bytes".utf8).write(to: fileURL, options: .atomic)
    defer { try? FileManager.default.removeItem(at: fileURL) }

    let source = sourceRecord(.seedPhoto, "seedPhoto:p1")
    let sourceAsset = CKAsset(fileURL: fileURL)
    source["asset"] = sourceAsset
    let hashes = [AssetRef(recordName: "seedPhoto:p1", field: "asset"): "observed-sha256"]

    let plan = try HouseholdGraphCopier.plan(
        [source], from: copySource, to: copyDestination, assetHashes: hashes)
    let copied = try planned(plan, "seedPhoto:p1")
    let copiedAsset = try #require(copied["asset"] as? CKAsset)

    #expect(copiedAsset !== sourceAsset)
    #expect(copiedAsset.fileURL == fileURL)
}

// MARK: - Execution against a destination that already holds records

@Test("the plan demands an all-keys save policy")
func copyPlanRequiresAllKeysPolicy() throws {
    #expect(try plannedGraph().savePolicy == .allKeys)
}

@Test("batches are saved in plan order and reproduce the source graph in the destination")
func copyExecutesBatchesInOrder() async throws {
    let destination = FakeDestinationZone()
    let plan = try plannedGraph()

    try await HouseholdGraphCopier.execute(plan, saving: destination.saver())

    #expect(destination.batchLog == plan.batches.map { $0.map(\.recordID.recordName) })
    #expect(try destinationDigest(destination) == sourceDigest())
}

@Test("the successor's pre-existing shared Household root is overwritten, not rejected")
func copyOverwritesPreexistingRoot() async throws {
    // The successor MUST create and share the destination Household root before the owner copies,
    // so batch 0 always collides with an existing record ID.
    let destination = FakeDestinationZone()
    let existingRoot = CKRecord(
        recordType: "Household",
        recordID: CKRecord.ID(recordName: "household:hh1", zoneID: copyDestination))
    existingRoot["name"] = "Successor placeholder" as CKRecordValue
    destination.seed(existingRoot)

    try await HouseholdGraphCopier.execute(try plannedGraph(), saving: destination.saver())

    #expect(destination.stored["household:hh1"]?["name"] as? String == "Finklea Garden")
    #expect(try destinationDigest(destination) == sourceDigest())
}

@Test("a tag-less record cannot overwrite an existing one under the default save policy")
func copyDefaultPolicyConflictsOnExistingRecord() throws {
    // Pins WHY the plan carries .allKeys: with CloudKit's default policy the very first batch of
    // every real transfer would fail forever on the successor's pre-existing root.
    let destination = FakeDestinationZone()
    let root = try planned(plannedGraph(), "household:hh1")
    destination.seed(root)

    #expect(throws: FakeSaveFailure.conflict("household:hh1")) {
        try destination.save([root], policy: .ifServerRecordUnchanged)
    }
    #expect(throws: Never.self) {
        try destination.save([root], policy: .allKeys)
    }
}

@Test("a copy interrupted mid-batch resumes to a complete graph without duplicating records")
func copyResumesAfterInterruption() async throws {
    let destination = FakeDestinationZone()
    destination.interruptAfter = 3

    await #expect(throws: FakeSaveFailure.interrupted) {
        try await HouseholdGraphCopier.execute(try plannedGraph(), saving: destination.saver())
    }
    #expect(destination.stored.count == 3, "a partial copy leaves a partial destination")
    #expect(try destinationDigest(destination) != sourceDigest())

    // Resume: re-plan from the untouched source and re-save everything, overwriting what landed.
    destination.interruptAfter = nil
    try await HouseholdGraphCopier.execute(try plannedGraph(), saving: destination.saver())

    #expect(destination.stored.count == 8)
    #expect(try destinationDigest(destination) == sourceDigest())
}

// MARK: - Rejections

@Test("copying a zone onto itself is refused")
func copyRejectsIdenticalZones() throws {
    #expect(throws: HouseholdGraphCopyError.destinationIsSource(zoneName: "seedkeep-hh1")) {
        try HouseholdGraphCopier.plan(transferGraph(), from: copySource, to: copySource)
    }
}

@Test("a cascade child whose parent is absent from the source set is refused")
func copyRejectsMissingCascadeParent() throws {
    var graph = transferGraph()
    graph.removeAll { $0.recordID.recordName == "journalEntry:j1" }

    #expect(throws: HouseholdGraphCopyError.missingCascadeParent(
        recordName: "journalChecklistItem:c1", field: "entryID", parent: "journalEntry:j1")) {
        try HouseholdGraphCopier.plan(graph, from: copySource, to: copyDestination)
    }
}

@Test("a dangling set-null reference is copied as-is, not treated as a missing parent")
func copyAllowsDanglingSetNullReference() throws {
    var graph = transferGraph()
    graph.removeAll { $0.recordID.recordName == "location:l1" }

    let plan = try HouseholdGraphCopier.plan(graph, from: copySource, to: copyDestination)
    let dangling = try #require(try planned(plan, "seed:s1")["locationID"] as? CKRecord.Reference)
    #expect(dangling.recordID == CKRecord.ID(recordName: "location:l1", zoneID: copyDestination))
}

@Test("duplicate record IDs with conflicting content are refused")
func copyRejectsConflictingDuplicates() throws {
    var graph = transferGraph()
    graph.append(sourceRecord(.seed, "seed:s1", scalars: ["customName": "Cherokee" as CKRecordValue]))

    #expect(throws: HouseholdGraphCopyError.conflictingDuplicate(recordName: "seed:s1")) {
        try HouseholdGraphCopier.plan(graph, from: copySource, to: copyDestination)
    }
}

@Test("a record name reused under a different type is a conflicting duplicate")
func copyRejectsTypeCollision() throws {
    let graph = [
        sourceRecord(.seed, "shared:1", scalars: ["customName": "A" as CKRecordValue]),
        sourceRecord(.bed, "shared:1", scalars: ["name": "A" as CKRecordValue]),
    ]
    #expect(throws: HouseholdGraphCopyError.conflictingDuplicate(recordName: "shared:1")) {
        try HouseholdGraphCopier.plan(graph, from: copySource, to: copyDestination)
    }
}

@Test("an exact duplicate collapses to one destination record")
func copyDedupesIdenticalRecords() throws {
    var graph = transferGraph()
    graph.append(sourceRecord(.location, "location:l1", scalars: ["name": "Garage shelf" as CKRecordValue]))

    let plan = try HouseholdGraphCopier.plan(graph, from: copySource, to: copyDestination)
    #expect(plan.records.count == 8)
    #expect(plan.counts["Location"] == 1)
}

@Test("an application field holding an unsupported value type is refused")
func copyRejectsUnsupportedValue() throws {
    var graph = transferGraph()
    graph.append(sourceRecord(.bed, "bed:b1", scalars: ["sortOrder": "first" as CKRecordValue]))

    #expect(throws: HouseholdGraphCopyError.unsupportedValue(
        recordType: "Bed", recordName: "bed:b1", field: "sortOrder")) {
        try HouseholdGraphCopier.plan(graph, from: copySource, to: copyDestination)
    }
}

@Test("a record that does not live in the source zone is refused")
func copyRejectsForeignRecord() throws {
    var graph = transferGraph()
    graph.append(sourceRecord(.bed, "bed:b1", in: strayZone,
                              scalars: ["name": "Stray" as CKRecordValue]))

    #expect(throws: HouseholdGraphCopyError.recordOutsideSourceZone(
        recordName: "bed:b1", zoneName: "seedkeep-stray")) {
        try HouseholdGraphCopier.plan(graph, from: copySource, to: copyDestination)
    }
}

@Test("an in-zone reference pointing outside the source zone is refused")
func copyRejectsForeignReference() throws {
    var graph = transferGraph()
    graph.append(sourceRecord(.seed, "seed:s2",
                              scalars: ["customName": "Stray" as CKRecordValue],
                              refs: ["locationID": ref("location:l1", .none, in: strayZone)]))

    #expect(throws: HouseholdGraphCopyError.referenceOutsideSourceZone(
        recordName: "seed:s2", field: "locationID", zoneName: "seedkeep-stray")) {
        try HouseholdGraphCopier.plan(graph, from: copySource, to: copyDestination)
    }
}

@Test("a cascade cycle is refused instead of producing an unsavable ordering")
func copyRejectsCascadeCycle() throws {
    let graph = [
        sourceRecord(.seedPhoto, "seedPhoto:a", refs: ["seedID": ref("seedPhoto:b", .deleteSelf)]),
        sourceRecord(.seedPhoto, "seedPhoto:b", refs: ["seedID": ref("seedPhoto:a", .deleteSelf)]),
    ]
    #expect(throws: HouseholdGraphCopyError.cascadeCycle(["seedPhoto:a", "seedPhoto:b"])) {
        try HouseholdGraphCopier.plan(graph, from: copySource, to: copyDestination)
    }
}

@Test("an empty source graph plans no batches rather than failing")
func copyOfEmptyGraph() throws {
    let plan = try HouseholdGraphCopier.plan([], from: copySource, to: copyDestination)
    #expect(plan.batches.isEmpty)
    #expect(plan.records.isEmpty)
    #expect(plan.counts.isEmpty)
}
