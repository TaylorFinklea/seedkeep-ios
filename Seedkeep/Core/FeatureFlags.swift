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
    /// `catalogCorrections` (R3) stays on the server; assistant threads are gated with Sprout while
    /// CloudKit is active. See the 2026-06-28 `r1-liveengine-wiring-spec.md`. Flipping it ON migrates local data into CloudKit
    /// (additive, reversible); flipping OFF returns to server sync.
    static let cloudKitHouseholdSyncKey = "seedkeep.flag.cloudKitHouseholdSync"
    /// DEFAULT ON (2026-06-29 cutover): CloudKit is now the default household-sync path. Resolution:
    ///   1. a value the user EXPLICITLY set (Settings toggle, on or off) is always honored — kill-switch;
    ///   2. else default ON in production, but OFF under the TEST host so the legacy-server-path suites
    ///      (which call `syncAll` and assert the household feeds) keep exercising that path until AC4
    ///      tears it down. A test can still opt into either via `setCloudKitHouseholdSync`.
    static var cloudKitHouseholdSyncEnabled: Bool {
        if let explicit = UserDefaults.standard.object(forKey: cloudKitHouseholdSyncKey) as? Bool { return explicit }
        return !isRunningUnitTests
    }
    static func setCloudKitHouseholdSync(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: cloudKitHouseholdSyncKey)
    }

    /// R1 capability copy for server-backed garden features that cannot yet
    /// address the active CloudKit household.
    static let cloudKitGardenCapabilityMessage =
        "Sprout and Claude/MCP connections are temporarily unavailable while CloudKit garden sync is active. Your shared garden stays on iCloud; these server-backed tools will return with a CloudKit-aware bridge."

    /// True when server-backed household features must not be exposed.
    static var serverGardenFeaturesRestricted: Bool {
        cloudKitHouseholdSyncEnabled
    }

    /// True when the app is hosting a unit-test bundle (XCTest is linked + loaded only then).
    private static let isRunningUnitTests = NSClassFromString("XCTestCase") != nil
}
