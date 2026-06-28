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
    /// legacy server `SyncEngine` feeds. **OFF by default — additive, ships nothing.** The
    /// coordinator/migration/account-wipe path is built + host/sim-tested + adversarially
    /// reviewed, but the live data path is only device-validatable; do NOT flip ON until a
    /// TestFlight cycle proves it on two real devices. When ON, the 7 household server feeds
    /// MUST be skipped the same turn (else data double-syncs) — see the 2026-06-28
    /// `r1-liveengine-wiring-spec.md` "Deferred (cutover)". `catalogCorrections` (R3) +
    /// `assistantThreads` (R5) stay on the server `SyncEngine` regardless of this flag.
    static let cloudKitHouseholdSyncEnabled = false
}
