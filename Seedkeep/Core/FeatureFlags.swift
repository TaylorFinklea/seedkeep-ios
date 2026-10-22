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

    // N3 (T2): the CloudKit household-sync flag and its UserDefaults kill-switch are gone. CloudKit
    // is the only sync path, in every build and under XCTest. A device may still hold the old
    // stored flag value from earlier builds; nothing reads it.

    /// R1 retirement copy for legacy server household invitations (2026-07-13 "CKShare is the sole
    /// R1 invitation model" ADR). Unlike the CloudKit capability messages above, this is a
    /// **permanent retirement, not a temporary gate** — server invite links are not coming back;
    /// CKShare (Settings ▸ "Share garden via iCloud") is the sole sharing model going forward.
    static let legacyInviteRetirementMessage =
        "Household invite links are no longer supported. Share your garden from Settings via iCloud — tap “Share garden via iCloud” to invite someone."

    /// True when the app is hosting a unit-test bundle (XCTest is linked + loaded only then).
    static let isRunningUnitTests = NSClassFromString("XCTestCase") != nil
    static var canRunLiveAppStartup: Bool { !isRunningUnitTests }
}
