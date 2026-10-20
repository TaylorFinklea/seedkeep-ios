#if canImport(CloudKit)
import CloudKit
import Foundation
import SeedkeepCloudKit

// R1 live-engine wiring — the one-time per-household export EXECUTOR (AC3). The host-testable
// `HouseholdMigrationPlanner` produces the dependency-ordered `[CloudKitRecordValue]` (Household →
// … → receipt LAST); this executor encodes each through the codec and writes it via the engine.
//
// Idempotent + resumable (G12), mirroring SimmerSmith's HouseholdMigrationRunner:
//   - Skip entirely if the `migrated:<householdID>` receipt is already in the engine's store
//     (the coordinator runs a fetch first, so a receipt synced from another device is present).
//   - The receipt is the LAST record written, so a crash mid-import leaves no receipt → the next
//     run re-imports; PK-preserving recordNames make every re-write an upsert (no duplication).
//
// Engine-only (no ModelContext) so it unit-tests against a fake `HouseholdRecordSyncing`. The
// coordinator owns the live zone/household/share provisioning before calling this.
enum HouseholdMigrationExecutor {

    struct Result: Equatable {
        /// True when the receipt already existed → nothing was written.
        var alreadyMigrated: Bool
        /// Records staged this run (includes the receipt). 0 when alreadyMigrated.
        var written: Int
    }

    /// N1: `canSend` said no (CloudKit paused). Nothing new was sent; anything staged stays
    /// pending. If the graph was staged, its receipt is in the engine's store, so the next run
    /// reports `alreadyMigrated` and the coordinator's `pushDirty` drains what was staged.
    struct Paused: Error {}

    /// Write `plan` into `zoneID` through `engine`, gated by the `migrated:<householdID>` receipt.
    @discardableResult
    static func run(
        into engine: HouseholdRecordSyncing,
        zoneID: CKRecordZone.ID,
        householdID: String,
        plan: [CloudKitRecordValue],
        drain: Bool = true,
        prepareRecord: (CKRecord) throws -> CKRecord = { $0 },
        canSend: @MainActor () -> Bool = { true }
    ) async throws -> Result {
        let receiptID = CKRecord.ID(
            recordName: SeedkeepRecordNames.migrationReceipt(householdID), zoneID: zoneID)
        if engine.store.record(for: receiptID) != nil {
            return Result(alreadyMigrated: true, written: 0)
        }
        // Preflight the WHOLE graph before staging anything. A metadata-only photo is a valid
        // CloudKit save, so discovering missing bytes after earlier records reached engine.save
        // would leave a partial migration queued behind an invalid receipt-less graph.
        let prepared = try plan.map {
            try prepareRecord(SeedkeepRecordCodec.encode($0, zoneID: zoneID))
        }
        guard await canSend() else { throw Paused() }
        for record in prepared { engine.save(record) }
        if drain {
            guard await canSend() else { throw Paused() }
            try await engine.sendUntilDrained(maxPasses: 6)
        }
        return Result(alreadyMigrated: false, written: prepared.count)
    }
}
#endif
