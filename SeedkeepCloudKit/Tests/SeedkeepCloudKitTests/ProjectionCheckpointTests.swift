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

@Test("lifecycle gate serializes engine-state mutation against a concurrent retire storm")
func lifecycleGateSerializesUnderConcurrentRetire() async {
    // The engine's `@unchecked Sendable` conformance claims every `syncEngine` / `zoneEnsured` touch
    // is serialized by this gate. Model that shared state as a deliberately race-prone counter+log
    // mutated ONLY inside gate bodies, then storm it from CKSyncEngine-delegate-like tasks.
    final class EngineState: @unchecked Sendable {
        var generation = 0
        var log: [Int] = []
    }
    let gate = HouseholdEngineLifecycleGate()
    let state = EngineState()
    let staged = Counter()
    let retirements = Counter()

    await withTaskGroup(of: Void.self) { group in
        for index in 0..<256 {
            group.addTask {
                if index % 16 == 0 {
                    let won = gate.retireIfActive(when: { true }, perform: {
                        state.generation += 1
                        state.log.append(-1)
                    })
                    if won { retirements.increment() }
                } else if gate.withActive({ () -> Bool in
                    state.generation += 1
                    state.log.append(index)
                    return true
                }) != nil {
                    staged.increment()
                }
            }
        }
    }

    #expect(retirements.value == 1, "exactly one account event may retire the engine")
    #expect(state.generation == staged.value + 1, "an unsynchronized mutation would lose an update")
    #expect(state.log.count == state.generation, "an unsynchronized append would lose an entry")
    #expect(gate.withActive({ () -> Bool in state.generation += 1; return true }) == nil,
            "a retired gate must fence every later delegate callback")

    gate.activate()
    #expect(gate.withActive({ () -> Bool in state.generation += 1; return true }) != nil,
            "the replacement account must be able to rearm the gate")
}
