import Foundation

/// Where this device's own preferences live: the appearance, the What's New baseline and the
/// notification toggles. They're per device and never synced. Sample-garden mode uses the fixture
/// suite and leaves the device's notifications alone, so a fixture session never reads or writes the
/// real app's preferences or notifications. Every other run uses `.standard`.
enum DevicePreferences {
    /// One instance for the whole process, so every reader and writer shares it. `UserDefaults` is
    /// thread-safe (Apple documents it so), though this SDK doesn't mark it `Sendable`.
    nonisolated(unsafe) static let store: UserDefaults = store(isFixture: isSampleGarden)

    /// True only in sample-garden mode (DEBUG, `-SeedkeepFixture`). Release builds have no fixture mode.
    static var isSampleGarden: Bool {
        #if DEBUG
        FixtureMode.isEnabled
        #else
        false
        #endif
    }

    /// The store for a session in the given mode. The fixture suite fails closed: if it can't be
    /// opened, the launch stops rather than falling back to `.standard`.
    static func store(isFixture: Bool) -> UserDefaults {
        #if DEBUG
        guard isFixture else { return .standard }
        guard let suite = UserDefaults(suiteName: FixtureMode.defaultsSuiteName) else {
            preconditionFailure("Sample-garden mode needs its own defaults suite (\(FixtureMode.defaultsSuiteName)); refusing to run without it")
        }
        return suite
        #else
        return .standard
        #endif
    }
}
