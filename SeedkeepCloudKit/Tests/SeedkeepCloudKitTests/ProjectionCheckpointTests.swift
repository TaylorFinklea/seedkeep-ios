import Testing
import Foundation
import CloudKit
@testable import SeedkeepCloudKit

// The durable-checkpoint policy `HouseholdSyncEngine` applies to BOTH the fetched and the sent
// batch, plus the lifecycle-gate invariant its `@unchecked Sendable` conformance rests on.
//
// `HouseholdSyncEngine` itself cannot be constructed here — it owns a live `CKContainer` database,
// which traps off-device — so the policy that must be provably identical on the fetch and the send
// path is exercised directly, and the app-target coordinator tests reuse the same type through
// their engine double.

private let checkpointZone = CKRecordZone.ID(zoneName: "checkpoint-zone", ownerName: CKCurrentUserDefaultName)

private func checkpointRecord(_ name: String) -> CKRecord {
    CKRecord(recordType: "Seed", recordID: CKRecord.ID(recordName: name, zoneID: checkpointZone))
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

@Test("a clean projection leaves the durable checkpoint enabled and never rolls back")
func checkpointCleanPass() async throws {
    let gate = ProjectionCheckpointGate()
    let projected = Counter()
    gate.beginPass()
    await gate.project([checkpointRecord("seed:1")], []) { _, _ in projected.increment() }
    #expect(gate.allowsDurableCheckpoint == true)

    var rolledBack = false
    try gate.finishPass { rolledBack = true }
    #expect(projected.value == 1)
    #expect(rolledBack == false, "a clean pass must not rewind the engine")
}

@Test("a failed projection suppresses the checkpoint, rolls back, and throws exactly once")
func checkpointFailedProjectionRollsBackOnce() async throws {
    let gate = ProjectionCheckpointGate()
    gate.beginPass()
    await gate.project([checkpointRecord("seed:1")], []) { _, _ in throw SyncEngineError.projectionFailed }

    #expect(gate.allowsDurableCheckpoint == false,
            "durable state must not advance past a batch SwiftData refused")

    var rollbacks = 0
    #expect(throws: SyncEngineError.projectionFailed) {
        try gate.finishPass { rollbacks += 1 }
    }
    #expect(rollbacks == 1)

    // The failure belongs to the pass that surfaced it: the next pass starts clean, and the
    // suppression is lifted only after the rollback ran.
    #expect(gate.allowsDurableCheckpoint == true)
    try gate.finishPass { rollbacks += 1 }
    #expect(rollbacks == 1, "a consumed failure must not roll back or throw a second time")
}

@Test("a projection failure latched by an earlier pass does not fail the next pass")
func checkpointBeginPassClearsStaleFailure() async throws {
    let gate = ProjectionCheckpointGate()
    await gate.project([checkpointRecord("seed:1")], []) { _, _ in throw SyncEngineError.projectionFailed }
    #expect(gate.allowsDurableCheckpoint == false)

    gate.beginPass()
    #expect(gate.allowsDurableCheckpoint == true)
    var rolledBack = false
    try gate.finishPass { rolledBack = true }
    #expect(rolledBack == false)
}

@Test("an empty batch is never handed to the coordinator")
func checkpointSkipsEmptyBatch() async throws {
    let gate = ProjectionCheckpointGate()
    let projected = Counter()
    gate.beginPass()
    await gate.project([], []) { _, _ in projected.increment() }
    #expect(projected.value == 0)
    try gate.finishPass { Issue.record("an empty batch must not fail a pass") }
}

@Test("concurrent projection failures collapse into a single rollback")
func checkpointConcurrentFailuresRollBackOnce() async throws {
    let gate = ProjectionCheckpointGate()
    gate.beginPass()
    await withTaskGroup(of: Void.self) { group in
        for index in 0..<64 {
            group.addTask {
                await gate.project([checkpointRecord("seed:\(index)")], []) { _, _ in
                    throw SyncEngineError.projectionFailed
                }
            }
        }
    }
    #expect(gate.allowsDurableCheckpoint == false)
    var rollbacks = 0
    #expect(throws: SyncEngineError.projectionFailed) {
        try gate.finishPass { rollbacks += 1 }
    }
    #expect(rollbacks == 1)
}

@Test("the pass driver reports a clean operation without rolling back")
func runPassCleanOperation() async throws {
    let gate = ProjectionCheckpointGate()
    var rollbacks = 0
    var validations = 0
    let error = try await gate.runPass(
        operation: { await gate.project([checkpointRecord("seed:1")], []) { _, _ in } },
        validate: { validations += 1 },
        rollback: { rollbacks += 1 })
    #expect(error == nil)
    #expect(validations == 1)
    #expect(rollbacks == 0)
}

@Test("the pass driver returns the CloudKit operation's error instead of throwing it")
func runPassReturnsOperationError() async throws {
    let gate = ProjectionCheckpointGate()
    var rollbacks = 0
    let error = try await gate.runPass(
        operation: { throw URLError(.networkConnectionLost) },
        rollback: { rollbacks += 1 })
    #expect((error as? URLError)?.code == .networkConnectionLost)
    #expect(rollbacks == 0, "an operation error alone must not rewind durable state")
}

@Test("a projection failure still rolls back and wins when the operation ALSO throws")
func runPassProjectionFailureBeatsOperationError() async throws {
    // The dangerous shape: an early page projects and is refused, a later page fails on the network.
    // Returning the network error would leave the latch to be cleared by the next `beginPass`, with
    // the engine still holding the advanced in-memory cursor.
    let gate = ProjectionCheckpointGate()
    var rollbacks = 0
    await #expect(throws: SyncEngineError.projectionFailed) {
        _ = try await gate.runPass(
            operation: {
                await gate.project([checkpointRecord("seed:1")], []) { _, _ in
                    throw SyncEngineError.projectionFailed
                }
                throw URLError(.networkConnectionLost)
            },
            rollback: { rollbacks += 1 })
    }
    #expect(rollbacks == 1, "the refused batch must be rewound even on an operation error")
    #expect(gate.allowsDurableCheckpoint == true, "and the latch is consumed by that pass")
}

@Test("a validation failure (retired engine) short-circuits the pass")
func runPassPropagatesValidationFailure() async throws {
    let gate = ProjectionCheckpointGate()
    var rollbacks = 0
    await #expect(throws: SyncEngineError.accountInvalidated) {
        _ = try await gate.runPass(
            operation: {},
            validate: { throw SyncEngineError.accountInvalidated },
            rollback: { rollbacks += 1 })
    }
    #expect(rollbacks == 0, "a retired generation is already replaced; nothing to rewind")
}

@Test("a durable checkpoint is written only while the pass is unpoisoned")
func persistCheckpointHonorsSuppression() async throws {
    let gate = ProjectionCheckpointGate()
    var writes = 0
    gate.beginPass()
    #expect(gate.persistCheckpoint { writes += 1 } == true)
    await gate.project([checkpointRecord("seed:1")], []) { _, _ in throw SyncEngineError.projectionFailed }
    #expect(gate.persistCheckpoint { writes += 1 } == false,
            "no cursor may be persisted once a batch was refused")
    #expect(writes == 1)
}

@Test("engine generation serializes every touch and survives a concurrent retire storm")
func engineGenerationSerializesUnderConcurrentRetire() async {
    // `HouseholdSyncEngine`'s `@unchecked Sendable` conformance rests on this holder: the live
    // CKSyncEngine and its `zoneStaged` bit are private to it and reachable ONLY inside its lock, so
    // there is no property left for a delegate task to read unsynchronized. Storm it the way
    // CKSyncEngine's delegate callbacks and an account event would.
    final class StandInEngine: @unchecked Sendable {
        var staged: [Int] = []
        var zoneSaves = 0
    }
    let first = StandInEngine()
    let generation = EngineGeneration(first)
    let replacement = StandInEngine()
    let stagedCount = Counter()
    let retirements = Counter()

    // Stage the zone once up front, so the storm's own zone-staging attempts can only ever be
    // rejected — the retire task order is not deterministic, and this keeps the "exactly once per
    // generation" assertion meaningful whichever task wins.
    #expect(generation.withLive({ (engine, zoneStaged) -> Bool in
        if !zoneStaged { engine.zoneSaves += 1; zoneStaged = true }
        engine.staged.append(-2)
        return true
    }) != nil)

    await withTaskGroup(of: Void.self) { group in
        for index in 0..<256 {
            group.addTask {
                if index % 16 == 0 {
                    let won = generation.replaceLive(
                        origin: nil, retire: true,
                        drain: { engine in engine.staged.append(-1) },
                        make: { replacement })
                    if won { retirements.increment() }
                } else if generation.withLive({ (engine, zoneStaged) -> Bool in
                    if !zoneStaged {
                        engine.zoneSaves += 1
                        zoneStaged = true
                    }
                    engine.staged.append(index)
                    return true
                }) != nil {
                    stagedCount.increment()
                }
            }
        }
    }

    #expect(retirements.value == 1, "exactly one account event may retire the live generation")
    #expect(first.zoneSaves == 1, "the zone save is staged exactly once per generation")
    #expect(first.staged.count == stagedCount.value + 2,
            "an unsynchronized append would lose an entry (+1 pre-storm, +1 retiring drain)")
    #expect(generation.withLive({ (engine, _) -> Bool in engine.staged.append(0); return true }) == nil,
            "a retired generation must fence every later delegate callback")
    #expect(generation.isCurrent(first) == false)

    generation.reactivate()
    #expect(generation.current() === replacement, "the replacement is live after rearming")
    #expect(generation.withLive({ (engine, zoneStaged) -> Bool in
        if !zoneStaged { engine.zoneSaves += 1; zoneStaged = true }
        return true
    }) != nil)
    #expect(replacement.zoneSaves == 1, "a replacement generation must re-stage its zone save")
}

@Test("engine generation only lets the CURRENT generation act")
func engineGenerationFencesStaleGenerations() {
    final class StandInEngine: @unchecked Sendable {}
    let stale = StandInEngine()
    let generation = EngineGeneration(stale)
    let fresh = StandInEngine()

    // A rollback (not a retirement) swaps the live generation but leaves the gate usable.
    #expect(generation.replaceLive(origin: stale, retire: false, drain: { _ in }, make: { fresh }) == true)
    #expect(generation.isCurrent(stale) == false)
    #expect(generation.isCurrent(fresh) == true)
    #expect(generation.withCurrent(stale) { _ in true } == nil,
            "a delegate event from the replaced generation must be inert")
    #expect(generation.withCurrent(fresh) { _ in true } == true)
    #expect(generation.replaceLive(origin: stale, retire: true, drain: { _ in }, make: { fresh }) == false,
            "a stale generation may not retire its successor")
}
