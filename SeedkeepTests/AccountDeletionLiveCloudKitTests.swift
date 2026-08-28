import CloudKit
import Foundation
import Testing
@testable import Seedkeep

/// Pure-seam tests for the two CloudKit observations that gate irreversible
/// account deletion. None of these may require an iCloud account: a simulator
/// without one must still prove that partial reads and ambiguous shares fail
/// closed.
@Suite("Live account-deletion CloudKit")
struct AccountDeletionLiveCloudKitTests {

    private enum TestFailure: Error, Equatable {
        case record
        case zone
        case operation
    }

    private func zone(_ name: String, owner: String = "_owner") -> CKRecordZone.ID {
        CKRecordZone.ID(zoneName: name, ownerName: owner)
    }

    private func record(_ name: String, in zoneID: CKRecordZone.ID) -> CKRecord {
        CKRecord(
            recordType: "TestRecord",
            recordID: CKRecord.ID(recordName: name, zoneID: zoneID))
    }

    // MARK: - Zone-change reduction

    @Test("a zone failure rejects records even when the operation succeeds")
    func zoneFailureRejectsPartialPage() {
        let zoneID = zone("shared")
        var builder = ZoneChangePageBuilder()
        builder.recordChanged(.success(record("one", in: zoneID)))
        builder.zoneFinished(.failure(TestFailure.zone))
        builder.operationFinished(.success(()))

        #expect(throws: TestFailure.zone) { try builder.finish() }
    }

    @Test("one failed changed record rejects an otherwise successful page")
    func recordFailureRejectsPage() {
        var builder = ZoneChangePageBuilder()
        builder.recordChanged(.failure(TestFailure.record))
        builder.zoneFinished(.success((nil, nil, false)))
        builder.operationFinished(.success(()))

        #expect(throws: TestFailure.record) { try builder.finish() }
    }

    @Test("the zone error wins when both a record and its zone fail")
    func zoneFailureTakesPrecedence() {
        var builder = ZoneChangePageBuilder()
        builder.recordChanged(.failure(TestFailure.record))
        builder.zoneFinished(.failure(TestFailure.zone))
        builder.operationFinished(.failure(TestFailure.operation))

        #expect(throws: TestFailure.zone) { try builder.finish() }
    }

    @Test("an operation failure surfaces even when no zone callback arrives")
    func operationFailureWithoutZoneResult() {
        var builder = ZoneChangePageBuilder()
        builder.operationFinished(.failure(TestFailure.operation))

        #expect(throws: TestFailure.operation) { try builder.finish() }
    }

    @Test("all successful callbacks return every record and zone pagination state")
    func successfulCallbacksBuildPage() throws {
        let zoneID = zone("shared")
        let first = record("one", in: zoneID)
        let second = record("two", in: zoneID)
        var builder = ZoneChangePageBuilder()
        builder.recordChanged(.success(first))
        builder.recordChanged(.success(second))
        builder.zoneFinished(.success((nil, Data("client-state".utf8), true)))
        builder.operationFinished(.success(()))

        let page = try builder.finish()
        #expect(page.records.map(\.recordID) == [first.recordID, second.recordID])
        #expect(page.token == nil)
        #expect(page.moreComing)
    }

    @Test("an asset from an earlier page remains identifiable after the final page")
    func pageAccumulatorTracksAssetPage() throws {
        let zoneID = zone("paged-assets")
        let assetRecord = record("photo", in: zoneID)
        let laterRecord = record("later", in: zoneID)
        var accumulator = ZoneChangeFetchAccumulator()

        accumulator.append(.init(records: [assetRecord], token: nil, moreComing: true))
        accumulator.append(.init(records: [laterRecord], token: nil, moreComing: false))

        let snapshot = try accumulator.finish()
        #expect(snapshot.records.map(\.recordID) == [assetRecord.recordID, laterRecord.recordID])
        #expect(snapshot.pageCount == 2)
        #expect(snapshot.pageIndexByRecordID[assetRecord.recordID] == 0)
        #expect(snapshot.pageIndexByRecordID[laterRecord.recordID] == 1)
        #expect(
            try Gate0bAssetEvidence.requireLaterPage(
                after: assetRecord.recordID, in: snapshot) == 0)
    }

    @Test("Gate 0b rejects an asset delivered on the final page")
    func gate0bRequiresLaterPageAfterAsset() throws {
        let zoneID = zone("asset-final-page")
        let first = record("first", in: zoneID)
        let photo = record("photo", in: zoneID)
        var accumulator = ZoneChangeFetchAccumulator()
        accumulator.append(.init(records: [first], token: nil, moreComing: true))
        accumulator.append(.init(records: [photo], token: nil, moreComing: false))
        let snapshot = try accumulator.finish()

        #expect(throws: (any Error).self) {
            try Gate0bAssetEvidence.requireLaterPage(
                after: photo.recordID, in: snapshot)
        }
    }

    @Test("Gate 0b reads exact asset bytes instead of trusting the declared hash")
    func gate0bReadsExactAssetBytes() throws {
        let zoneID = zone("asset-proof")
        let photo = record("photo", in: zoneID)
        let bytes = Data("gate-0b-exact-bytes".utf8)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("gate0b-test-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: url) }
        try bytes.write(to: url, options: .atomic)
        photo["asset"] = CKAsset(fileURL: url)
        photo["assetSHA256"] = "deliberately-untrusted" as CKRecordValue

        let asset = try Gate0bAssetEvidence.requireExactAsset(
            in: photo, field: "asset", expectedBytes: bytes)

        #expect(asset.fileURL == url)
    }

    @Test("Gate 0b rejects a readable asset whose bytes differ")
    func gate0bRejectsWrongAssetBytes() throws {
        let zoneID = zone("asset-proof-wrong")
        let photo = record("photo", in: zoneID)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("gate0b-test-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("wrong".utf8).write(to: url, options: .atomic)
        photo["asset"] = CKAsset(fileURL: url)

        #expect(throws: (any Error).self) {
            try Gate0bAssetEvidence.requireExactAsset(
                in: photo, field: "asset", expectedBytes: Data("expected".utf8))
        }
    }

    @Test("Gate 0b requires genuinely different CloudKit accounts")
    func gate0bRequiresDifferentAccounts() throws {
        #expect(throws: (any Error).self) {
            try Gate0bTransferEvidence.requireDifferentAccounts(
                source: "same-account", successor: "same-account")
        }
        try Gate0bTransferEvidence.requireDifferentAccounts(
            source: "source-account", successor: "successor-account")
    }

    @Test("Gate 0b requires the successor-owned zone in sharedCloudDatabase")
    func gate0bRequiresSharedDestination() throws {
        let zoneName = "garden-gate0b"
        let shared = CKRecordZone.ID(zoneName: zoneName, ownerName: "successor-account")
        try Gate0bTransferEvidence.requireSharedDestination(
            shared, zoneName: zoneName, ownerRecordName: "successor-account")

        let privateZone = CKRecordZone.ID(
            zoneName: zoneName, ownerName: CKCurrentUserDefaultName)
        #expect(throws: (any Error).self) {
            try Gate0bTransferEvidence.requireSharedDestination(
                privateZone, zoneName: zoneName, ownerRecordName: "successor-account")
        }
    }

    @Test("Gate 0b binds a public handoff to its unique temporary zone")
    func gate0bBindsHandoffToTemporaryZone() throws {
        let runID = "abcd1234"
        let householdID = "spike-gate0b-destination-\(runID)"
        let zoneName = "seedkeep-\(householdID)"

        try Gate0bTransferEvidence.requireBoundHandoff(
            runID: runID,
            householdID: householdID,
            destinationZoneName: zoneName)
        #expect(throws: (any Error).self) {
            try Gate0bTransferEvidence.requireBoundHandoff(
                runID: "different",
                householdID: householdID,
                destinationZoneName: zoneName)
        }
        #expect(throws: (any Error).self) {
            try Gate0bTransferEvidence.requireBoundHandoff(
                runID: runID,
                householdID: householdID,
                destinationZoneName: "seedkeep-real-user-zone")
        }
    }

    // MARK: - Transfer save chunking

    @Test("scalar-only saves retain the 300-record chunk limit and input order")
    func scalarSaveChunksRetainExistingLimit() throws {
        let zoneID = zone("scalar-save-chunks")
        let records = (0..<301).map { record("scalar-\($0)", in: zoneID) }

        let chunks = try LiveAccountDeletionCloudKit.saveChunks(for: records)

        #expect(chunks.map(\.count) == [300, 1])
        #expect(chunks.flatMap { $0.map(\.recordID) } == records.map(\.recordID))
    }

    @Test("asset-bearing saves cap each operation at 25 records")
    func assetSaveChunksCapRecordCount() throws {
        let zoneID = zone("asset-save-chunks")
        let assetURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("account-deletion-chunk-\(UUID().uuidString).jpg")
        try Data("asset".utf8).write(to: assetURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: assetURL) }
        let records = (0..<26).map { index in
            let photo = CKRecord(
                recordType: "SeedPhoto",
                recordID: CKRecord.ID(recordName: "photo-\(index)", zoneID: zoneID))
            photo["asset"] = CKAsset(fileURL: assetURL)
            return photo
        }

        let chunks = try LiveAccountDeletionCloudKit.saveChunks(for: records)

        #expect(chunks.map(\.count) == [25, 1])
        #expect(chunks.flatMap { $0.map(\.recordID) } == records.map(\.recordID))
    }

    @Test("asset bytes split before a save operation exceeds 32 MiB")
    func assetSaveChunksRespectByteBudget() throws {
        let zoneID = zone("asset-byte-budget")
        let sizes = [20 * 1_024 * 1_024, 12 * 1_024 * 1_024, 1]
        var urls: [URL] = []
        defer { for url in urls { try? FileManager.default.removeItem(at: url) } }
        let records = try sizes.enumerated().map { index, size in
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("account-deletion-budget-\(UUID().uuidString).jpg")
            _ = FileManager.default.createFile(atPath: url.path, contents: nil)
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: UInt64(size))
            try handle.close()
            urls.append(url)

            let photo = CKRecord(
                recordType: "SeedPhoto",
                recordID: CKRecord.ID(recordName: "budget-photo-\(index)", zoneID: zoneID))
            photo["asset"] = CKAsset(fileURL: url)
            return photo
        }

        let chunks = try LiveAccountDeletionCloudKit.saveChunks(for: records)

        #expect(chunks.map(\.count) == [2, 1])
        #expect(chunks.flatMap { $0.map(\.recordID) } == records.map(\.recordID))
    }

    @Test("mixed saves use scalar capacity until an asset enters a chunk")
    func mixedSaveChunksUseDynamicLimits() throws {
        let zoneID = zone("mixed-save-chunks")
        let assetURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("account-deletion-mixed-\(UUID().uuidString).jpg")
        try Data("asset".utf8).write(to: assetURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: assetURL) }

        let leadingScalars = (0..<30).map { record("leading-scalar-\($0)", in: zoneID) }
        let photo = CKRecord(
            recordType: "SeedPhoto",
            recordID: CKRecord.ID(recordName: "mixed-photo", zoneID: zoneID))
        photo["asset"] = CKAsset(fileURL: assetURL)
        let trailingScalars = (0..<25).map { record("trailing-scalar-\($0)", in: zoneID) }
        let records = leadingScalars + [photo] + trailingScalars

        let chunks = try LiveAccountDeletionCloudKit.saveChunks(for: records)

        #expect(chunks.map(\.count) == [30, 25, 1])
        #expect(chunks.flatMap { $0.map(\.recordID) } == records.map(\.recordID))
    }

    @Test("asset sizing fails closed when its file is no longer readable")
    func assetSaveChunksFailClosedForUnreadableFile() throws {
        let zoneID = zone("unreadable-asset-save-chunk")
        let assetURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("account-deletion-unreadable-\(UUID().uuidString).jpg")
        try Data("gone".utf8).write(to: assetURL, options: .atomic)
        let photo = CKRecord(
            recordType: "SeedPhoto",
            recordID: CKRecord.ID(recordName: "unreadable-photo", zoneID: zoneID))
        photo["asset"] = CKAsset(fileURL: assetURL)
        try FileManager.default.removeItem(at: assetURL)

        #expect(throws: PhotoAssetSyncError.self) {
            try LiveAccountDeletionCloudKit.saveChunks(for: [photo])
        }
    }

    @Test("one asset larger than the save budget fails closed")
    func oversizedAssetSaveChunkFailsClosed() throws {
        let zoneID = zone("oversized-asset-save-chunk")
        let assetURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("account-deletion-oversized-\(UUID().uuidString).jpg")
        _ = FileManager.default.createFile(atPath: assetURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: assetURL)
        try handle.truncate(atOffset: UInt64(32 * 1_024 * 1_024 + 1))
        try handle.close()
        defer { try? FileManager.default.removeItem(at: assetURL) }
        let photo = CKRecord(
            recordType: "SeedPhoto",
            recordID: CKRecord.ID(recordName: "oversized-photo", zoneID: zoneID))
        photo["asset"] = CKAsset(fileURL: assetURL)

        #expect(throws: (any Error).self) {
            try LiveAccountDeletionCloudKit.saveChunks(for: [photo])
        }
    }

    // MARK: - Role resolution

    @Test("one accepted shared zone is a participant without a local marker")
    func oneSharedZoneDoesNotNeedMarker() throws {
        let shared = zone("shared")

        #expect(try LiveAccountDeletionCloudKit.resolveRole(
            sharedZoneIDs: [shared],
            ownedZoneExists: false,
            ownedZoneID: nil,
            acceptedShareParticipants: 0,
            markerZoneID: nil
        ) == .participant(sharedZoneID: shared))
    }

    @Test("a marker does NOT license abandoning the other accepted shares")
    func markerCannotResolveSeveralSharedZones() {
        // This device participates in both gardens. The participant flow
        // leaves exactly one, so honouring the marker here would delete the
        // account and quietly strand the user's membership of the other.
        let selected = zone("selected")

        #expect(throws: (any Error).self) {
            try LiveAccountDeletionCloudKit.resolveRole(
                sharedZoneIDs: [zone("other"), selected],
                ownedZoneExists: true,
                ownedZoneID: zone("owned", owner: CKCurrentUserDefaultName),
                acceptedShareParticipants: 1,
                markerZoneID: selected)
        }
    }

    @Test("several accepted shares without a marker fail closed")
    func ambiguousSharedZonesWithoutMarkerThrow() {
        #expect(throws: (any Error).self) {
            try LiveAccountDeletionCloudKit.resolveRole(
                sharedZoneIDs: [zone("one"), zone("two")],
                ownedZoneExists: false,
                ownedZoneID: nil,
                acceptedShareParticipants: 0,
                markerZoneID: nil)
        }
    }

    @Test("a stale marker cannot make several accepted shares look unambiguous")
    func ambiguousSharedZonesWithStaleMarkerThrow() {
        #expect(throws: (any Error).self) {
            try LiveAccountDeletionCloudKit.resolveRole(
                sharedZoneIDs: [zone("one"), zone("two")],
                ownedZoneExists: false,
                ownedZoneID: nil,
                acceptedShareParticipants: 0,
                markerZoneID: zone("stale"))
        }
    }

    @Test("the default shared zone is not an accepted garden")
    func defaultSharedZoneIsIgnored() throws {
        #expect(try LiveAccountDeletionCloudKit.resolveRole(
            sharedZoneIDs: [CKRecordZone.default().zoneID],
            ownedZoneExists: false,
            ownedZoneID: nil,
            acceptedShareParticipants: 0,
            markerZoneID: nil
        ) == .noGarden)
    }

    @Test("an owned zone with no accepted participants is a solo garden")
    func ownedZoneWithoutParticipantsIsSolo() throws {
        let owned = zone("owned", owner: CKCurrentUserDefaultName)

        #expect(try LiveAccountDeletionCloudKit.resolveRole(
            sharedZoneIDs: [],
            ownedZoneExists: true,
            ownedZoneID: owned,
            acceptedShareParticipants: 0,
            markerZoneID: nil
        ) == .soloOwner(zoneID: owned))
    }

    @Test("an owned zone with an accepted participant requires handoff")
    func ownedZoneWithParticipantsIsShared() throws {
        let owned = zone("owned", owner: CKCurrentUserDefaultName)

        #expect(try LiveAccountDeletionCloudKit.resolveRole(
            sharedZoneIDs: [],
            ownedZoneExists: true,
            ownedZoneID: owned,
            acceptedShareParticipants: 1,
            markerZoneID: nil
        ) == .sharedOwner(zoneID: owned))
    }

    @Test("no accepted share and no owned zone means no garden")
    func absentCloudKitStateMeansNoGarden() throws {
        #expect(try LiveAccountDeletionCloudKit.resolveRole(
            sharedZoneIDs: [],
            ownedZoneExists: false,
            ownedZoneID: nil,
            acceptedShareParticipants: 0,
            markerZoneID: nil
        ) == .noGarden)
    }
}
