#if canImport(CloudKit)
import CloudKit
import Foundation

// N2-E (G2): the engine-side half of the deleted-garden guard. Everything here is pure or
// lock-guarded, so it is testable without a live `CKSyncEngine` (which needs a signed container):
//   - `GardenSignalClassifier`: the event-to-signal classification (contract §5);
//   - `GardenSendGate`: the fence, the hold and the batch-check admission the delegate's
//     `nextRecordZoneChangeBatch` runs for every batch (contract §3).

/// Why CloudKit reported a zone as deleted (`CKSyncEngine.Event.FetchedDatabaseChanges.Deletion.Reason`).
/// Every reason is a gone signal; `.other` covers a reason a later SDK adds.
public enum ZoneDeletionReason: Sendable, Equatable, CaseIterable {
    case deleted, purged, encryptedDataReset, other

    init(_ reason: CKDatabase.DatabaseChange.Deletion.Reason) {
        switch reason {
        case .deleted: self = .deleted
        case .purged: self = .purged
        case .encryptedDataReset: self = .encryptedDataReset
        @unknown default: self = .other
        }
    }
}

/// Why a garden is gone.
public enum GardenGoneCause: Sendable, Equatable {
    /// `.fetchedDatabaseChanges` deleted this garden's zone, for any reason.
    case zoneDeleted(ZoneDeletionReason)
    /// A zone fetch or a record save failed with `zoneNotFound`.
    case zoneNotFound
    /// A zone fetch or a record save failed with `userDeletedZone`.
    case userDeletedZone
    /// The zone exists and the `Household` root is confirmed missing.
    case rootMissing
    /// The root's `creationDate` differs from the recorded generation: the garden was recreated.
    case recreated
}

/// What the engine's events (or a check) say about this garden.
public enum GardenSignal: Sendable, Equatable {
    case none
    /// The garden is gone. Deletion outranks any other change in the same event batch.
    case gone(GardenGoneCause)
    /// `permissionFailure`. View only only when the share's `currentUserParticipant` permission is
    /// confirmed read-only; otherwise it is ambiguous. The coordinator decides.
    case permissionDenied
    /// Network, account or nested partial errors: sends stop for the pass and nothing is retired.
    case ambiguous
}

/// One thing the sync engine observed about the garden's zone.
public enum GardenZoneEvent: Sendable, Equatable {
    /// `.fetchedDatabaseChanges` reported a zone deletion.
    case zoneDeleted(CKRecordZone.ID, ZoneDeletionReason)
    /// `.didFetchRecordZoneChanges` carried an error for a zone.
    case zoneFetchFailed(CKRecordZone.ID, CKError.Code)
    /// A record save failed.
    case recordSaveFailed(CKRecordZone.ID, CKError.Code)
}

/// The pure event-to-signal classifier (contract §5), tested for every reason and code.
public enum GardenSignalClassifier {
    public static func classify(_ event: GardenZoneEvent, garden: CKRecordZone.ID) -> GardenSignal {
        switch event {
        case .zoneDeleted(let zoneID, let reason):
            return zoneID == garden ? .gone(.zoneDeleted(reason)) : .none
        case .zoneFetchFailed(let zoneID, let code), .recordSaveFailed(let zoneID, let code):
            return zoneID == garden ? classify(code: code) : .none
        }
    }

    /// The signal an error code carries for the garden's own zone.
    public static func classify(code: CKError.Code) -> GardenSignal {
        switch code {
        case .zoneNotFound:
            return .gone(.zoneNotFound)
        case .userDeletedZone:
            return .gone(.userDeletedZone)
        case .permissionFailure:
            return .permissionDenied
        case .networkUnavailable, .networkFailure, .notAuthenticated, .accountTemporarilyUnavailable,
             .partialFailure:
            return .ambiguous
        default:
            return .none
        }
    }
}

extension GardenSignal {
    /// Ambiguous or permission signals: the failure may be transient or may be a read-only share, so
    /// it is never treated as permanent.
    var isAmbiguousFailure: Bool { self == .ambiguous || self == .permissionDenied }
}

/// The result of the pre-send root read the coordinator supplies (contract §3, "Batch check").
public enum GardenCheckOutcome: Sendable, Equatable {
    /// The root is there and its generation matches (or none is recorded yet).
    case ok
    /// A mismatch, or a missing root or zone: the garden is gone.
    case gone(GardenGoneCause)
    /// Anything else: a timeout, a network or account error, a changed account or epoch. No batch is
    /// built; the pass ends and retries with today's backoff.
    case failed(GardenCheckFailure)
}

/// Why a batch check could not confirm the garden. Typed, so the drain loop returns it to the
/// coordinator instead of retrying.
public enum GardenCheckFailure: Sendable, Equatable {
    case timedOut
    /// The account or the coordinator's epoch moved while the root was being read.
    case superseded
    /// The garden's identity or guard could not be resolved.
    case unavailable
    /// A shared garden whose zone is not (yet) visible and was never seen.
    case notAvailableYet
    /// The root carries no server `creationDate`: it can't be compared or trusted on first use.
    case missingMetadata
    /// The first-use generation could not be written to the guard, so nothing is sent.
    case guardWriteFailed
    /// A CloudKit error code, as a raw value (network, account, service).
    case cloudKit(Int)
}

/// The fence, the hold and the batch-check admission for one engine. Thread-safe: the delegate's
/// tasks and the coordinator's drain loop both reach it.
///
/// - **Fence** (`latchGone`): permanent for this engine generation. After a gone signal, no batch is
///   built, so a signal fences with zero new sends. Fetched and sent record events are ignored.
/// - **Hold** (`hold`): stops sends for the current pass after an ambiguous or permission signal.
///   The coordinator lifts it at the start of the next pass (`release`).
/// - **Admission** (`admit`): runs the batch check for every batch the engine asks for.
public final class GardenSendGate: @unchecked Sendable {
    private let lock = NSLock()
    private var goneCause: GardenGoneCause?
    private var held: GardenSignal?
    private var checkFailure: GardenCheckFailure?
    private var checks = 0

    public init() {}

    public var isFenced: Bool { lock.withLock { goneCause != nil } }
    public var cause: GardenGoneCause? { lock.withLock { goneCause } }
    public var isHeld: Bool { lock.withLock { held != nil } }
    /// How many batch checks ran (the cost measure the tests report).
    public var checkCount: Int { lock.withLock { checks } }
    /// Fenced or held: nothing may be sent.
    public var blocksSends: Bool { lock.withLock { goneCause != nil || held != nil } }

    /// Latches the fence. Returns true for the first latch only.
    @discardableResult
    public func latchGone(_ cause: GardenGoneCause) -> Bool {
        lock.withLock {
            guard goneCause == nil else { return false }
            goneCause = cause
            return true
        }
    }

    public func hold(_ signal: GardenSignal) {
        lock.withLock { if held == nil { held = signal } }
    }

    /// Start of a pass: lifts a hold and forgets a stale check failure. A fence stays.
    public func release() {
        lock.withLock { held = nil; checkFailure = nil }
    }

    /// Lifts the fence for a participant whose gone signal the shared listing refuted, but keeps the
    /// pass stopped: the hold stays (it is set if there was none) until the next pass `release()`s
    /// it, so the batches still to come in the same drain are not built.
    public func clearFence() {
        lock.withLock {
            goneCause = nil
            if held == nil { held = .ambiguous }
        }
    }

    public func takeCheckFailure() -> GardenCheckFailure? {
        lock.withLock {
            defer { checkFailure = nil }
            return checkFailure
        }
    }

    /// Whether a batch may be built now. Runs the check (if there is one) every time it is asked,
    /// including the repeated calls within one `sendUntilDrained`. A gone outcome latches the fence and
    /// reports it through `emit`; any other failure is recorded for the drain loop. The fence is read
    /// again after the check, so a signal that arrived while it awaited still stops the batch.
    public func admit(
        check: (@Sendable () async -> GardenCheckOutcome)?,
        emit: (GardenSignal) -> Void
    ) async -> Bool {
        if blocksSends { return false }
        guard let check else { return true }
        lock.withLock { checks += 1 }
        let outcome = await check()
        switch outcome {
        case .ok:
            return !blocksSends
        case .gone(let cause):
            if latchGone(cause) { emit(.gone(cause)) }
            return false
        case .failed(let failure):
            lock.withLock { checkFailure = failure }
            return false
        }
    }

    /// Applies a signal from an event. Returns whether the engine should keep processing the event's
    /// record changes (false once fenced).
    @discardableResult
    public func apply(_ signal: GardenSignal, emit: (GardenSignal) -> Void) -> Bool {
        switch signal {
        case .none:
            return !isFenced
        case .gone(let cause):
            if latchGone(cause) { emit(signal) }
            return false
        case .permissionDenied, .ambiguous:
            hold(signal)
            emit(signal)
            return !isFenced
        }
    }
}

/// The engine's event handling for the garden, apart from `CKSyncEngine.Event` (whose cases can't be
/// built off-device): `handleCurrentEvent` calls these with the values it reads from the event, and
/// the tests call them with the same values.
public enum GardenEventHandling {
    /// `.fetchedDatabaseChanges`: a deletion of this garden's zone is gone, for any reason.
    public static func zoneDeletions(
        _ deletions: [(zoneID: CKRecordZone.ID, reason: ZoneDeletionReason)],
        garden: CKRecordZone.ID, gate: GardenSendGate, emit: (GardenSignal) -> Void
    ) {
        for deletion in deletions {
            let signal = GardenSignalClassifier.classify(.zoneDeleted(deletion.zoneID, deletion.reason), garden: garden)
            if signal != .none { gate.apply(signal, emit: emit) }
        }
    }

    /// `.didFetchRecordZoneChanges` with an error for a zone.
    public static func zoneFetchError(
        zoneID: CKRecordZone.ID, code: CKError.Code,
        garden: CKRecordZone.ID, gate: GardenSendGate, emit: (GardenSignal) -> Void
    ) {
        let signal = GardenSignalClassifier.classify(.zoneFetchFailed(zoneID, code), garden: garden)
        if signal != .none { gate.apply(signal, emit: emit) }
    }

    /// `.sentRecordZoneChanges` failed saves. Gone, permission and ambiguous (network, account,
    /// partial) all stop the sends: a deletion fences, the others hold the pass. The records stay
    /// queued (the engine's own re-enqueue keeps them) and the next pass tries again.
    public static func saveFailures(
        _ failures: [(zoneID: CKRecordZone.ID, code: CKError.Code)],
        garden: CKRecordZone.ID, gate: GardenSendGate, emit: (GardenSignal) -> Void
    ) {
        for failure in failures {
            let signal = GardenSignalClassifier.classify(.recordSaveFailed(failure.zoneID, failure.code), garden: garden)
            if signal != .none { gate.apply(signal, emit: emit) }
        }
    }

    /// Fetched and sent record changes land only while the garden is not fenced.
    public static func mayProcessRecordChanges(gate: GardenSendGate) -> Bool { !gate.isFenced }
}
#endif
