import Foundation

/// Compile-time feature flags for surfaces that are shipped but intentionally
/// hidden. The server side of these features stays live so data keeps
/// accruing — flipping a flag back to `true` makes the UI re-appear without
/// any migration or backfill.
enum FeatureFlags {

    /// Phase 5.1 plant pets. Shipped end-to-end (server Fly v37, iOS
    /// TestFlight 38) but hidden in-app while other surfaces are locked in.
    /// Server-side spawn / personality / depart flows continue running;
    /// flipping this back to `true` re-surfaces every pet UI entry point
    /// (Today roll-call, Menagerie, BedDetail companions, Settings toggles,
    /// assistant `client_pet_state`).
    static let plantPetsEnabled = false

    /// R1 serverless rearchitecture — route HOUSEHOLD GARDEN DATA sync through the
    /// `SeedkeepCloudKit` `CKSyncEngine` shared zone (+ CKShare households) instead of the
    /// legacy server `SyncEngine` feeds. **OFF by default — additive, ships nothing.**
    ///
    /// Runtime-toggleable via UserDefaults (NOT a compile-time constant) so a TestFlight build can
    /// opt in ON-DEVICE (Settings ▸ Sync ▸ "CloudKit sync (beta)") without a new build, with an
    /// instant kill-switch, while the unit suite + production both run with the safe default (false).
    /// When ON, `SyncEngine.syncAll` skips the 7 household feeds + flushPending (else double-sync);
    /// `catalogCorrections` (R3) + `assistantThreads` (R5) stay on the server regardless. See the
    /// 2026-06-28 `r1-liveengine-wiring-spec.md`. Flipping it ON migrates local data into CloudKit
    /// (additive, reversible); flipping OFF returns to server sync.
    static let cloudKitHouseholdSyncKey = "seedkeep.flag.cloudKitHouseholdSync"
    static var cloudKitHouseholdSyncEnabled: Bool {
        UserDefaults.standard.bool(forKey: cloudKitHouseholdSyncKey)   // default false
    }
    static func setCloudKitHouseholdSync(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: cloudKitHouseholdSyncKey)
    }
}
