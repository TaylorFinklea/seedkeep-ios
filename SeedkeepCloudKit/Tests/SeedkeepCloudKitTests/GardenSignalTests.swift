import Testing
import Foundation
import CloudKit
@testable import SeedkeepCloudKit

// N2-E (G2) §5 and §3: the pure event-to-signal classifier, tested for every reason and error code,
// and the send gate (fence, hold, batch-check admission) the delegate's batch hook runs. A live
// `HouseholdSyncEngine` and `CKSyncEngine` can't be built off-device (they need a signed container),
// so the delegate's own logic is exercised through `GardenSendGate`, the code `produceBatch` calls.

private let garden = CKRecordZone.ID(zoneName: "seedkeep-hhr_g", ownerName: CKCurrentUserDefaultName)
private let other = CKRecordZone.ID(zoneName: "seedkeep-hhr_other", ownerName: CKCurrentUserDefaultName)

// MARK: - Classifier

@Test("a deletion of the garden's zone is gone for every reason")
func zoneDeletionIsGoneForEveryReason() {
    for reason in ZoneDeletionReason.allCases {
        #expect(GardenSignalClassifier.classify(.zoneDeleted(garden, reason), garden: garden)
                == .gone(.zoneDeleted(reason)))
    }
}

@Test("a deletion of another zone says nothing about this garden")
func otherZoneDeletionIgnored() {
    for reason in ZoneDeletionReason.allCases {
        #expect(GardenSignalClassifier.classify(.zoneDeleted(other, reason), garden: garden) == .none)
    }
}

@Test("every error code classifies the same way for a zone fetch and a record save")
func errorCodesClassify() {
    let gone: [CKError.Code: GardenSignal] = [
        .zoneNotFound: .gone(.zoneNotFound),
        .userDeletedZone: .gone(.userDeletedZone),
    ]
    let ambiguous: [CKError.Code] = [
        .networkUnavailable, .networkFailure, .notAuthenticated, .accountTemporarilyUnavailable, .partialFailure,
    ]
    let ignored: [CKError.Code] = [
        .internalError, .serverRejectedRequest, .unknownItem, .invalidArguments, .serverRecordChanged,
        .batchRequestFailed, .zoneBusy, .serviceUnavailable, .requestRateLimited, .serverResponseLost,
        .quotaExceeded, .limitExceeded, .changeTokenExpired, .alreadyShared, .managedAccountRestricted,
        .operationCancelled, .incompatibleVersion, .constraintViolation, .badContainer, .missingEntitlement,
    ]
    for (code, expected) in gone {
        #expect(GardenSignalClassifier.classify(.zoneFetchFailed(garden, code), garden: garden) == expected)
        #expect(GardenSignalClassifier.classify(.recordSaveFailed(garden, code), garden: garden) == expected)
    }
    #expect(GardenSignalClassifier.classify(.zoneFetchFailed(garden, .permissionFailure), garden: garden) == .permissionDenied)
    #expect(GardenSignalClassifier.classify(.recordSaveFailed(garden, .permissionFailure), garden: garden) == .permissionDenied)
    for code in ambiguous {
        #expect(GardenSignalClassifier.classify(.zoneFetchFailed(garden, code), garden: garden) == .ambiguous)
        #expect(GardenSignalClassifier.classify(.recordSaveFailed(garden, code), garden: garden) == .ambiguous)
    }
    for code in ignored {
        #expect(GardenSignalClassifier.classify(.zoneFetchFailed(garden, code), garden: garden) == .none)
        #expect(GardenSignalClassifier.classify(.recordSaveFailed(garden, code), garden: garden) == .none)
    }
}

@Test("an error for another zone is not this garden's signal")
func otherZoneErrorIgnored() {
    for code in [CKError.Code.zoneNotFound, .userDeletedZone, .permissionFailure, .networkFailure] {
        #expect(GardenSignalClassifier.classify(.zoneFetchFailed(other, code), garden: garden) == .none)
        #expect(GardenSignalClassifier.classify(.recordSaveFailed(other, code), garden: garden) == .none)
    }
}

@Test("a root read classifies only unknownItem as a missing root and only zone codes as a missing zone")
func rootReadClassification() async {
    func read(_ error: Error) async -> GardenRootRead {
        await SeedkeepZoneProvisioner.readRoot(CKRecord.ID(recordName: "household:x", zoneID: garden)) { _ in throw error }
    }
    if case .rootMissing = await read(CKError(.unknownItem)) {} else { Issue.record("unknownItem should be rootMissing") }
    if case .zoneMissing = await read(CKError(.zoneNotFound)) {} else { Issue.record("zoneNotFound should be zoneMissing") }
    if case .zoneMissing = await read(CKError(.userDeletedZone)) {} else { Issue.record("userDeletedZone should be zoneMissing") }
    for code in [CKError.Code.networkUnavailable, .notAuthenticated, .serviceUnavailable, .permissionFailure, .partialFailure] {
        if case .failed(.cloudKit(let raw)) = await read(CKError(code)) { #expect(raw == code.rawValue) }
        else { Issue.record("\(code) should be a failure, never gone") }
    }
    if case .failed = await read(URLError(.timedOut)) {} else { Issue.record("a non-CloudKit error is a failure") }
}

@Test("ensureHousehold's replacement reads the root and never writes: a missing root stays missing")
func fetchRootNeverCreates() async {
    // The read has no save closure at all, so a confirmed-missing root cannot be recreated by it.
    let recordID = CKRecord.ID(recordName: "household:x", zoneID: garden)
    var fetches = 0
    let read = await SeedkeepZoneProvisioner.readRoot(recordID) { _ in
        fetches += 1
        throw CKError(.unknownItem)
    }
    if case .rootMissing = read {} else { Issue.record("expected rootMissing") }
    #expect(fetches == 1)
}

// MARK: - Send gate

private final class Emitted: @unchecked Sendable {
    private let lock = NSLock()
    private var signals: [GardenSignal] = []
    func add(_ signal: GardenSignal) { lock.withLock { signals.append(signal) } }
    var all: [GardenSignal] { lock.withLock { signals } }
}

private actor Counter {
    private(set) var count = 0
    func next() -> Int { count += 1; return count }
}

@Test("a gate with no check admits every batch")
func gateWithoutCheckAdmits() async {
    let gate = GardenSendGate()
    let emitted = Emitted()
    #expect(await gate.admit(check: nil, emit: emitted.add))
    #expect(gate.checkCount == 0)
}

@Test("the check runs for every batch, including a second call within one send")
func gateChecksEveryBatch() async {
    let gate = GardenSendGate()
    let emitted = Emitted()
    let counter = Counter()
    let check: @Sendable () async -> GardenCheckOutcome = {
        let n = await counter.next()
        return n == 2 ? .gone(.recreated) : .ok
    }
    #expect(await gate.admit(check: check, emit: emitted.add))
    #expect(await gate.admit(check: check, emit: emitted.add) == false)   // the mismatch is on the second batch
    #expect(gate.checkCount == 2)
    #expect(gate.isFenced)
    #expect(gate.cause == .recreated)
    #expect(emitted.all == [.gone(.recreated)])
    // A fenced gate builds no further batch and reads no further root.
    #expect(await gate.admit(check: check, emit: emitted.add) == false)
    #expect(gate.checkCount == 2)
}

@Test("a failed check builds no batch, records a typed failure once, and does not fence")
func gateFailedCheck() async {
    let gate = GardenSendGate()
    let emitted = Emitted()
    let check: @Sendable () async -> GardenCheckOutcome = { .failed(.timedOut) }
    #expect(await gate.admit(check: check, emit: emitted.add) == false)
    #expect(gate.takeCheckFailure() == .timedOut)
    #expect(gate.takeCheckFailure() == nil)
    #expect(!gate.isFenced)
    #expect(emitted.all.isEmpty)
    // The next pass may try again.
    gate.release()
    #expect(await gate.admit(check: { .ok }, emit: emitted.add))
}

@Test("a gone signal that arrives while the check awaits still stops the batch")
func gateFenceDuringCheck() async {
    let gate = GardenSendGate()
    let emitted = Emitted()
    let admitted = await gate.admit(check: {
        gate.apply(.gone(.zoneDeleted(.deleted)), emit: emitted.add)
        return .ok
    }, emit: emitted.add)
    #expect(!admitted)
    #expect(gate.cause == .zoneDeleted(.deleted))
}

@Test("a gone signal latches once, fences, and stops record processing")
func gateGoneLatchesOnce() {
    let gate = GardenSendGate()
    let emitted = Emitted()
    #expect(gate.apply(.none, emit: emitted.add))
    #expect(!gate.apply(.gone(.zoneDeleted(.purged)), emit: emitted.add))
    #expect(!gate.apply(.gone(.zoneNotFound), emit: emitted.add))   // a second signal changes nothing
    #expect(gate.cause == .zoneDeleted(.purged))
    #expect(emitted.all == [.gone(.zoneDeleted(.purged))])
    gate.release()
    #expect(gate.isFenced)   // a pass boundary lifts a hold, never the fence
}

@Test("an ambiguous or permission signal holds sends for the pass and release lifts it")
func gateHoldAndRelease() async {
    let gate = GardenSendGate()
    let emitted = Emitted()
    #expect(gate.apply(.ambiguous, emit: emitted.add))
    #expect(gate.isHeld)
    #expect(await gate.admit(check: { .ok }, emit: emitted.add) == false)
    #expect(gate.checkCount == 0)   // a held gate does not even read the root
    gate.release()
    #expect(!gate.isHeld)
    #expect(await gate.admit(check: { .ok }, emit: emitted.add))
    gate.apply(.permissionDenied, emit: emitted.add)
    #expect(gate.isHeld)
    #expect(emitted.all == [.ambiguous, .permissionDenied])
}

// MARK: - Fence lifted by a refuted signal keeps the pass stopped (review fix)

@Test("clearing a fence keeps the pass stopped until the next pass releases it")
func clearFenceKeepsHold() async {
    let gate = GardenSendGate()
    let emitted = Emitted()
    gate.apply(.gone(.zoneDeleted(.deleted)), emit: emitted.add)
    gate.clearFence()
    #expect(!gate.isFenced)
    #expect(gate.isHeld)
    #expect(await gate.admit(check: { .ok }, emit: emitted.add) == false)   // no more batches in this pass
    #expect(gate.checkCount == 0)
    gate.release()
    #expect(await gate.admit(check: { .ok }, emit: emitted.add))
}

// MARK: - The delegate's event handling and batch hook, called as the delegate calls them

@Test("the reason mapping from CloudKit's deletion reason covers every case")
func deletionReasonMapping() {
    #expect(ZoneDeletionReason(.deleted) == .deleted)
    #expect(ZoneDeletionReason(.purged) == .purged)
    #expect(ZoneDeletionReason(.encryptedDataReset) == .encryptedDataReset)
}

@Test("event handling: a deletion of this zone fences before anything else in the batch; another zone does not")
func eventHandlingDeletions() {
    let gate = GardenSendGate()
    let emitted = Emitted()
    GardenEventHandling.zoneDeletions([(other, .deleted)], garden: garden, gate: gate, emit: emitted.add)
    #expect(!gate.isFenced)
    GardenEventHandling.zoneDeletions([(other, .deleted), (garden, .purged)], garden: garden, gate: gate, emit: emitted.add)
    #expect(gate.cause == .zoneDeleted(.purged))
    #expect(emitted.all == [.gone(.zoneDeleted(.purged))])
    #expect(!GardenEventHandling.mayProcessRecordChanges(gate: gate))   // the coalesced modify is ignored
}

@Test("event handling: zone fetch errors and failed saves follow the classifier")
func eventHandlingErrors() {
    for (code, fenced, held) in [(CKError.Code.zoneNotFound, true, false), (.userDeletedZone, true, false),
                                 (.permissionFailure, false, true), (.networkFailure, false, true),
                                 (.notAuthenticated, false, true), (.partialFailure, false, true),
                                 (.serverRecordChanged, false, false), (.batchRequestFailed, false, false)] {
        let fetchGate = GardenSendGate()
        GardenEventHandling.zoneFetchError(zoneID: garden, code: code, garden: garden, gate: fetchGate, emit: { _ in })
        #expect(fetchGate.isFenced == fenced)
        #expect(fetchGate.isHeld == held)
        let saveGate = GardenSendGate()
        GardenEventHandling.saveFailures([(other, code), (garden, code)], garden: garden, gate: saveGate, emit: { _ in })
        #expect(saveGate.isFenced == fenced)
        #expect(saveGate.isHeld == held)   // ambiguous save failures hold the pass too
    }
}

private let pendingOne: [CKSyncEngine.PendingRecordZoneChange] = [
    .saveRecord(CKRecord.ID(recordName: "seed:1", zoneID: garden))
]

@Test("the batch hook builds batch after batch while checks pass, and checks each one")
func produceBatchChecksEach() async {
    let gate = GardenSendGate()
    let counter = Counter()
    let check: @Sendable () async -> GardenCheckOutcome = { _ = await counter.next(); return .ok }
    var built = 0
    for _ in 0..<3 {
        let batch = await HouseholdSyncEngine.produceBatch(
            pending: pendingOne, gate: gate, check: check, emit: { _ in }, isCurrent: { true },
            record: { CKRecord(recordType: "Seed", recordID: $0) })
        if batch != nil { built += 1 }
    }
    #expect(built == 3)
    #expect(await counter.count == 3)
}

@Test("the batch hook: a failing check on the second batch builds none and fences")
func produceBatchSecondFails() async {
    let gate = GardenSendGate()
    let emitted = Emitted()
    let counter = Counter()
    let check: @Sendable () async -> GardenCheckOutcome = {
        await counter.next() == 2 ? .gone(.recreated) : .ok
    }
    func make() async -> CKSyncEngine.RecordZoneChangeBatch? {
        await HouseholdSyncEngine.produceBatch(
            pending: pendingOne, gate: gate, check: check, emit: emitted.add, isCurrent: { true },
            record: { CKRecord(recordType: "Seed", recordID: $0) })
    }
    #expect(await make() != nil)
    #expect(await make() == nil)
    #expect(await make() == nil)
    #expect(await counter.count == 2)   // the fenced third call does not even read the root
    #expect(emitted.all == [.gone(.recreated)])

    let timeoutGate = GardenSendGate()
    let batch = await HouseholdSyncEngine.produceBatch(
        pending: pendingOne, gate: timeoutGate, check: { .failed(.timedOut) }, emit: { _ in },
        isCurrent: { true }, record: { CKRecord(recordType: "Seed", recordID: $0) })
    #expect(batch == nil)
    #expect(timeoutGate.takeCheckFailure() == .timedOut)
}

@Test("the batch hook: an engine generation that is no longer current after the await builds no batch")
func produceBatchGenerationChanges() async {
    let gate = GardenSendGate()
    final class Current: @unchecked Sendable { var value = true }
    let current = Current()
    let batch = await HouseholdSyncEngine.produceBatch(
        pending: pendingOne, gate: gate, check: { current.value = false; return .ok }, emit: { _ in },
        isCurrent: { current.value }, record: { CKRecord(recordType: "Seed", recordID: $0) })
    #expect(batch == nil)
}

// MARK: - Round 3

@Test("a gone or ambiguous signal that arrives while the batch is being built stops it")
func produceBatchSignalDuringConstruction() async {
    for signal in [GardenSignal.gone(.zoneDeleted(.deleted)), .ambiguous, .permissionDenied] {
        let gate = GardenSendGate()
        let batch = await HouseholdSyncEngine.produceBatch(
            pending: pendingOne, gate: gate, check: { .ok }, emit: { _ in }, isCurrent: { true },
            record: { id in
                gate.apply(signal, emit: { _ in })   // the engine's event handler, mid-construction
                return CKRecord(recordType: "Seed", recordID: id)
            })
        #expect(batch == nil)
        #expect(gate.blocksSends)
    }
}

@Test("the delegate's scope filter keeps only the changes inside the request's scope")
func pendingScopeFilter() {
    let inside = CKSyncEngine.PendingRecordZoneChange.saveRecord(CKRecord.ID(recordName: "a", zoneID: garden))
    let outside = CKSyncEngine.PendingRecordZoneChange.saveRecord(CKRecord.ID(recordName: "b", zoneID: other))
    func zone(of change: CKSyncEngine.PendingRecordZoneChange) -> CKRecordZone.ID? {
        if case .saveRecord(let id) = change { return id.zoneID }
        if case .deleteRecord(let id) = change { return id.zoneID }
        return nil
    }
    #expect(HouseholdSyncEngine.pendingChanges([inside, outside], inScope: { zone(of: $0) == garden }) == [inside])
    #expect(HouseholdSyncEngine.pendingChanges([inside, outside], inScope: { zone(of: $0) != garden }) == [outside])
}

@Test("ambiguous save-failure codes stay retriable; only the permanent ones can be recorded as permanent")
func saveFailureDispositions() {
    for code in [CKError.Code.notAuthenticated, .accountTemporarilyUnavailable, .partialFailure, .networkFailure,
                 .networkUnavailable, .zoneBusy, .serviceUnavailable, .requestRateLimited, .serverResponseLost,
                 .batchRequestFailed, .permissionFailure] {
        #expect(HouseholdSyncEngine.saveFailureDisposition(for: code) == .retry)
    }
    #expect(HouseholdSyncEngine.saveFailureDisposition(for: .serverRecordChanged) == .merge)
    #expect(HouseholdSyncEngine.saveFailureDisposition(for: .zoneNotFound) == .zoneGone)
    #expect(HouseholdSyncEngine.saveFailureDisposition(for: .userDeletedZone) == .zoneGone)
    #expect(HouseholdSyncEngine.saveFailureDisposition(for: .unknownItem) == .dropMissing)
    for code in [CKError.Code.quotaExceeded, .invalidArguments, .serverRejectedRequest] {
        #expect(HouseholdSyncEngine.saveFailureDisposition(for: code) == .permanent)
    }
}

@Test("a partial failure is classified per item from its partial errors")
func partialFailureClassifiedPerItem() {
    let id = CKRecord.ID(recordName: "seed:1", zoneID: garden)
    let otherID = CKRecord.ID(recordName: "seed:2", zoneID: garden)
    func partial(_ code: CKError.Code?) -> CKError {
        var info: [String: Any] = [:]
        if let code { info[CKPartialErrorsByItemIDKey] = [id: CKError(code)] }
        return CKError(.partialFailure, userInfo: info)
    }
    // The item's own error decides.
    #expect(HouseholdSyncEngine.effectiveSaveError(partial(.zoneNotFound), for: id).code == .zoneNotFound)
    #expect(HouseholdSyncEngine.effectiveSaveError(partial(.quotaExceeded), for: id).code == .quotaExceeded)
    #expect(HouseholdSyncEngine.saveFailureDisposition(for: HouseholdSyncEngine.effectiveSaveError(partial(.zoneNotFound), for: id).code) == .zoneGone)
    // Another item's error, or none, leaves the partial failure itself: ambiguous and retriable.
    #expect(HouseholdSyncEngine.effectiveSaveError(partial(.zoneNotFound), for: otherID).code == .partialFailure)
    #expect(HouseholdSyncEngine.effectiveSaveError(partial(nil), for: id).code == .partialFailure)
    // The signal follows the effective code.
    let gate = GardenSendGate()
    let effective = HouseholdSyncEngine.effectiveSaveError(partial(.zoneNotFound), for: id).code
    GardenEventHandling.saveFailures([(garden, effective)], garden: garden, gate: gate, emit: { _ in })
    #expect(gate.isFenced)
}

@Test("ambiguous failures are re-enqueued however often they repeat, so they never reach the permanent roster")
func ambiguousFailuresNeverGiveUp() {
    // `reEnqueue` gives up (surfacePermanentSave -> the coordinator's durable failed-photo roster) only
    // when this says no.
    let ambiguous: [CKError.Code] = [.networkFailure, .networkUnavailable, .notAuthenticated,
                                     .accountTemporarilyUnavailable, .partialFailure, .permissionFailure]
    for code in ambiguous {
        for attempt in [1, 5, 6, 50, 5_000] {
            #expect(HouseholdSyncEngine.shouldReEnqueue(attempt: attempt, code: code))
        }
    }
    // The other retriable codes keep the cap.
    for code in [CKError.Code.zoneBusy, .serviceUnavailable, .requestRateLimited, .batchRequestFailed, .serverResponseLost] {
        #expect(HouseholdSyncEngine.shouldReEnqueue(attempt: 5, code: code))
        #expect(!HouseholdSyncEngine.shouldReEnqueue(attempt: 6, code: code))
    }
    // A partial failure with an item error decides by that error.
    let id = CKRecord.ID(recordName: "seed:1", zoneID: garden)
    let partial = CKError(.partialFailure, userInfo: [CKPartialErrorsByItemIDKey: [id: CKError(.zoneBusy)]])
    #expect(!HouseholdSyncEngine.shouldReEnqueue(attempt: 6, code: HouseholdSyncEngine.effectiveSaveError(partial, for: id).code))
}
