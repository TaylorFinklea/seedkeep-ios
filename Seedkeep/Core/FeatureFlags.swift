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
    /// Runtime-toggleable via UserDefaults (NOT a compile-time constant), with an instant
    /// kill-switch. As of the 2026-07-27 V1 plan there is no user-facing Settings control for
    /// this — it defaults ON in shipping builds and is flipped only as an internal recovery
    /// affordance (debug build or support gesture), since off drops the user to legacy server
    /// sync with no working escape hatch once Phase 2 lands. The test-only compilation
    /// condition used by the release gate lets the suite run both the legacy OFF lane and the
    /// shipping default-ON lane without changing release behavior.
    /// When ON, `SyncEngine.syncAll` skips the 7 household feeds + flushPending (else double-sync);
    /// `catalogCorrections` (R3) stays on the server; assistant threads are gated with Sprout while
    /// CloudKit is active. See the 2026-06-28 `r1-liveengine-wiring-spec.md`. Flipping it ON migrates local data into CloudKit
    /// (additive, reversible); flipping OFF returns to server sync.
    static let cloudKitHouseholdSyncKey = "seedkeep.flag.cloudKitHouseholdSync"
    /// DEFAULT ON (2026-06-29 cutover): CloudKit is now the default household-sync path. Resolution:
    ///   1. a value the user EXPLICITLY set (Settings toggle, on or off) is always honored — kill-switch;
    ///   2. under the explicitly test-scoped ON compilation condition, XCTest uses the shipping
    ///      default; otherwise XCTest keeps the legacy OFF default deterministic;
    ///   3. outside XCTest, the default is ON.
    static var cloudKitHouseholdSyncEnabled: Bool {
        if let explicit = UserDefaults.standard.object(forKey: cloudKitHouseholdSyncKey) as? Bool { return explicit }
        if isRunningUnitTests {
            #if SEEDKEEP_TEST_CLOUDKIT_ON
            return true
            #else
            return false
            #endif
        }
        return true
    }
    static func setCloudKitHouseholdSync(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: cloudKitHouseholdSyncKey)
    }

    /// Temporary R1 limit for server-backed photo bytes. CloudKit mirrors photo metadata and
    /// preserves the existing server objects, but the server photo APIs cannot address the active
    /// CloudKit household yet.
    static let cloudKitPhotoCapabilityMessage =
        "Photos are temporarily unavailable while your active garden uses CloudKit. Existing seed and journal photos are preserved; uploads, galleries, and deletes return when CloudKit photo support is ready."

    /// R1 retirement copy for legacy server household invitations (2026-07-13 "CKShare is the sole
    /// R1 invitation model" ADR). Unlike the CloudKit capability messages above, this is a
    /// **permanent retirement, not a temporary gate** — server invite links are not coming back;
    /// CKShare (Settings ▸ "Share garden via iCloud") is the sole sharing model going forward.
    static let legacyInviteRetirementMessage =
        "Household invite links are no longer supported. Share your garden from Settings via iCloud — tap “Share garden via iCloud” to invite someone."

    /// True when server-backed household features must not be exposed.
    static var serverGardenFeaturesRestricted: Bool {
        cloudKitHouseholdSyncEnabled
    }

    /// True when server-backed photo bytes must not be exposed.
    static var serverPhotoFeaturesRestricted: Bool {
        cloudKitHouseholdSyncEnabled
    }

    /// True when the app is hosting a unit-test bundle (XCTest is linked + loaded only then).
    private static let isRunningUnitTests = NSClassFromString("XCTestCase") != nil
}
