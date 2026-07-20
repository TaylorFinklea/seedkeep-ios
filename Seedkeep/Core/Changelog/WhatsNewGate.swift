import Foundation

/// Decides whether the "What's New" sheet auto-presents at launch, and
/// persists which build the user has already seen. Mirrors the `FeatureFlags`
/// static-over-UserDefaults idiom; the decision function is pure (inject the
/// build + last-seen) so it is host-testable with no bundle or defaults.
enum WhatsNewGate {
    static let lastSeenBuildKey = "seedkeep.whatsNew.lastSeenBuild"

    static func lastSeenBuild(defaults: UserDefaults = .standard) -> Int? {
        defaults.object(forKey: lastSeenBuildKey) as? Int
    }

    static func markSeen(build: Int, defaults: UserDefaults = .standard) {
        defaults.set(build, forKey: lastSeenBuildKey)
    }

    /// The single release to auto-present, or nil to present nothing.
    /// - Fresh install (`lastSeenBuild == nil`) → nil (caller baselines silently).
    /// - Downgrade (`currentBuild < lastSeenBuild`) → nil.
    /// - Otherwise the newest authored release whose build is present in this
    ///   binary (`build <= currentBuild`), but only if it's newer than
    ///   `lastSeenBuild`. Latest-only, even across skipped builds.
    static func releaseToAutoPresent(
        releases: [ChangelogRelease],
        lastSeenBuild: Int?,
        currentBuild: Int
    ) -> ChangelogRelease? {
        guard let seen = lastSeenBuild else { return nil }
        guard currentBuild >= seen else { return nil }
        guard let newest = releases
            .filter({ $0.build <= currentBuild })
            .max(by: { $0.build < $1.build })
        else { return nil }
        return newest.build > seen ? newest : nil
    }
}
