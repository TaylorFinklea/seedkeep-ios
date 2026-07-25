#if canImport(CloudKit)
import CloudKit
import Foundation

/// Durable-checkpoint policy for one driven sync pass (`fetchChanges()` / `sendChanges()` /
/// `sendUntilDrained(maxPasses:)`).
///
/// CKSyncEngine hands FETCHED and SENT record batches to the delegate and then, separately, offers a
/// `.stateUpdate` whose serialization durably advances the change cursor. If the SwiftData projection
/// of a batch fails, persisting that serialization strands the batch permanently: a fetched batch is
/// never re-delivered once the cursor moves, and a SENT batch — the merged result of a
/// `serverRecordChanged` conflict — is never re-fetched at all, because this device authored the last
/// write. So a failed projection must
///
///   1. latch, so every later `.stateUpdate` in the pass is dropped (`allowsDurableCheckpoint`),
///   2. roll the engine back to the last on-disk serialization (`finishPass(rollback:)`), and
///   3. throw `SyncEngineError.projectionFailed` out of the driving call — exactly once —
///      so the caller does not record the batch as synced.
///
/// This policy lives outside `HouseholdSyncEngine` because that class owns a live `CKContainer`
/// database and cannot be constructed off-device, while this — the part that must be provably
/// identical on the fetch and the send path — is exactly what needs proving. It is unit-tested
/// directly and reused verbatim by the coordinator tests' engine double.
public final class ProjectionCheckpointGate: @unchecked Sendable {
    private let lock = NSLock()
    private var failed = false

    public init() {}

    /// Start of a driven pass. A latched failure belongs to the pass that observes it, so a pass that
    /// never got the chance to surface one starts clean instead of throwing for its predecessor.
    public func beginPass() {
        lock.lock(); failed = false; lock.unlock()
    }

    /// False once a projection in this pass failed — the engine drops `.stateUpdate` while it is false.
    public var allowsDurableCheckpoint: Bool {
        lock.lock(); defer { lock.unlock() }
        return !failed
    }

    /// Hand one reconciled batch to the coordinator. A throw is LATCHED, not propagated: the caller is
    /// CloudKit's delegate task, which discards errors, so the pass boundary (`finishPass`) is the only
    /// place a projection failure can reach the code that drove the pass.
    public func project(
        _ records: [CKRecord],
        _ deletions: [CKRecord.ID],
        via callback: (@Sendable ([CKRecord], [CKRecord.ID]) async throws -> Void)?
    ) async {
        guard let callback, !records.isEmpty || !deletions.isEmpty else { return }
        do {
            try await callback(records, deletions)
        } catch {
            lock.withLock { failed = true }
        }
    }

    /// End of a driven pass. On a latched failure: run `rollback` (restoring the engine to the last
    /// durable serialization) FIRST — so no `.stateUpdate` can slip through between the clear and the
    /// rollback — then clear and throw. A clean pass is a no-op and never invokes `rollback`.
    public func finishPass(rollback: () -> Void) throws {
        lock.lock()
        let hadFailure = failed
        lock.unlock()
        guard hadFailure else { return }
        rollback()
        lock.lock(); failed = false; lock.unlock()
        throw SyncEngineError.projectionFailed
    }
}
#endif
