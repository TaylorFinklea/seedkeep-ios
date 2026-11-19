import Foundation

/// Compile-time feature flags for surfaces that are shipped but intentionally
/// hidden. Their local models stay in the store and in CloudKit sync, so
/// flipping a flag back to `true` makes the UI re-appear without any
/// migration or backfill.
enum FeatureFlags {

    /// Phase 5.1 plant pets, hidden in-app. The server that spawned pets is
    /// retired; existing pet fields on plantings and pet departures stay in the
    /// local store and sync through CloudKit, and moods are computed on device
    /// (`MoodEngine`). Flipping this back to `true` re-surfaces the remaining
    /// pet UI entry points (Today roll-call, Garden companions, the
    /// notification setting).
    static let plantPetsEnabled = false

    /// Starting an iCloud share as the garden owner (Settings ▸ "Share garden via iCloud"), hidden
    /// for 1.0 because the two-account flow has never been checked on devices (umbrella decision
    /// 2026-11-19). Only the owner's entry point is hidden: a device already in a shared garden
    /// still sees "Leave shared garden", and accepting a share link still works.
    static let iCloudSharingEnabled = false

    // N3 (T2): the CloudKit household-sync flag and its UserDefaults kill-switch are gone. CloudKit
    // is the only sync path, in every build and under XCTest. A device may still hold the old
    // stored flag value from earlier builds; nothing reads it.

    /// R1 retirement copy for legacy server household invitations (2026-07-13 "CKShare is the sole
    /// R1 invitation model" ADR). Unlike the CloudKit capability messages above, this is a
    /// **permanent retirement, not a temporary gate** — server invite links are not coming back;
    /// CKShare (Settings ▸ "Share garden via iCloud") is the sole sharing model going forward.
    static var legacyInviteRetirementMessage: String {
        iCloudSharingEnabled
            ? "Household invite links are no longer supported. Share your garden from Settings via iCloud — tap “Share garden via iCloud” to invite someone."
            : "Household invite links are no longer supported."
    }

    /// True when the app is hosting a unit-test bundle (XCTest is linked + loaded only then).
    static let isRunningUnitTests = NSClassFromString("XCTestCase") != nil
    static var canRunLiveAppStartup: Bool { !isRunningUnitTests }
}
