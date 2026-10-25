import Testing
import Foundation
import CloudKit
@testable import SeedkeepCloudKit

// N2-E (G1): no engine path stages a zone save, and a restored one is stripped. A live
// `HouseholdSyncEngine` can't be built off-device, so the staging seam it uses is exercised with a
// recording double of `CKSyncEngine.State`.

private final class RecordingState: PendingChangeStaging {
    var pendingDatabaseChanges: [CKSyncEngine.PendingDatabaseChange]
    private(set) var addedDatabaseChanges: [CKSyncEngine.PendingDatabaseChange] = []
    private(set) var addedRecordChanges: [CKSyncEngine.PendingRecordZoneChange] = []

    init(restored: [CKSyncEngine.PendingDatabaseChange] = []) { pendingDatabaseChanges = restored }

    func add(pendingDatabaseChanges changes: [CKSyncEngine.PendingDatabaseChange]) {
        addedDatabaseChanges += changes
        pendingDatabaseChanges += changes
    }
    func remove(pendingDatabaseChanges changes: [CKSyncEngine.PendingDatabaseChange]) {
        pendingDatabaseChanges.removeAll { existing in changes.contains(existing) }
    }
    func add(pendingRecordZoneChanges changes: [CKSyncEngine.PendingRecordZoneChange]) {
        addedRecordChanges += changes
    }
}

private let zone = CKRecordZone.ID(zoneName: "seedkeep-hhr_x", ownerName: CKCurrentUserDefaultName)
private let recordID = CKRecord.ID(recordName: "seed:s1", zoneID: zone)

@Test("a first save stages the record and never a zone save")
func firstSaveStagesNoZone() {
    let state = RecordingState()
    PendingStateSanitizer.stageRecordSave(recordID, on: state)
    PendingStateSanitizer.stageRecordSave(recordID, on: state)
    #expect(state.addedDatabaseChanges.isEmpty)
    #expect(state.addedRecordChanges.count == 2)
}

@Test("a restored .saveZone is stripped from engine state")
func restoredSaveZoneIsStripped() {
    let state = RecordingState(restored: [.saveZone(CKRecordZone(zoneID: zone))])
    let removed = PendingStateSanitizer.stripDatabaseChanges(from: state)
    #expect(removed == 1)
    #expect(state.pendingDatabaseChanges.isEmpty)
    #expect(PendingStateSanitizer.stripDatabaseChanges(from: state) == 0)
}

@Test("a save into a missing zone stages nothing and reports the reason")
func zoneNotFoundSaveDoesNotRetryOrRecreate() {
    for (code, expected) in [(CKError.Code.zoneNotFound, ZoneUnavailableReason.zoneNotFound),
                             (.userDeletedZone, .userDeletedZone)] {
        let state = RecordingState()
        let reason = PendingStateSanitizer.dropSaveForMissingZone(recordID, error: CKError(code), on: state)
        #expect(reason == expected)
        #expect(state.addedDatabaseChanges.isEmpty)
        #expect(state.addedRecordChanges.isEmpty)
    }
}

@Test("only requests CloudKit never received keep a creation grant pending")
func undispatchedClassification() {
    #expect(GardenCreation.isUndispatched(code: .networkUnavailable))
    #expect(GardenCreation.isUndispatched(code: .notAuthenticated))
    #expect(GardenCreation.isUndispatched(code: .accountTemporarilyUnavailable))
    for code in [CKError.Code.networkFailure, .serverResponseLost, .zoneBusy, .serviceUnavailable,
                 .requestRateLimited, .quotaExceeded, .unknownItem, .internalError, .partialFailure] {
        #expect(!GardenCreation.isUndispatched(code: code))
    }
    #expect(!GardenCreation.isUndispatched(URLError(.notConnectedToInternet)))
}
