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
}
