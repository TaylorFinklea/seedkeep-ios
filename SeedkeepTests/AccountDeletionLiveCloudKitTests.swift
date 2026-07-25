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

    @Test("a marker selects its accepted share when several shared zones exist")
    func markerSelectsAmongSharedZones() throws {
        let selected = zone("selected")

        #expect(try LiveAccountDeletionCloudKit.resolveRole(
            sharedZoneIDs: [zone("other"), selected],
            ownedZoneExists: true,
            ownedZoneID: zone("owned", owner: CKCurrentUserDefaultName),
            acceptedShareParticipants: 1,
            markerZoneID: selected
        ) == .participant(sharedZoneID: selected))
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
