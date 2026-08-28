import SwiftUI

/// One user-facing change in a release, tagged by category.
struct ChangelogChange {
    let category: ChangelogCategory
    let text: String
}

/// The three change categories, each carrying its own display title, SF Symbol,
/// and Herbarium tint — mirrors how `HerbBanner.Severity` owns its presentation.
enum ChangelogCategory: CaseIterable {
    case new, improved, fixed

    var title: String {
        switch self {
        case .new:      "New"
        case .improved: "Improved"
        case .fixed:    "Fixed"
        }
    }

    var symbolName: String {
        switch self {
        case .new:      "sparkles"
        case .improved: "wand.and.stars"
        case .fixed:    "ladybug"
        }
    }

    var tint: Color {
        switch self {
        case .new:      HerbColor.sage
        case .improved: HerbColor.ochre
        case .fixed:    HerbColor.rose
        }
    }
}

/// One shipped release. `build` (CFBundleVersion) is the ordering + detection
/// key; `version` (marketing) leads the display.
struct ChangelogRelease: Identifiable {
    var id: Int { build }
    let version: String
    let build: Int
    let date: String?
    let headline: String?
    let changes: [ChangelogChange]
}

/// The changelog itself — the source of truth, authored newest-first.
/// `release.sh` refuses to cut a build whose number has no entry here.
enum ChangelogData {
    static let releases: [ChangelogRelease] = [
        ChangelogRelease(
            version: "1.0.0",
            build: 53,
            date: nil,
            headline: "Photos and faster garden sync",
            changes: [
                ChangelogChange(category: .improved,
                    text: "Seed and journal photos are back in iCloud gardens, including shared gardens. If a photo needs attention, you can retry it directly."),
                ChangelogChange(category: .improved,
                    text: "Journal entries and checklist changes now sync sooner between your devices."),
                ChangelogChange(category: .fixed,
                    text: "Today in your garden now handles leap-day dates correctly."),
            ]
        ),
        ChangelogRelease(
            version: "0.4.0",
            build: 52,
            date: nil,
            headline: "Account deletion improvements",
            changes: [
                ChangelogChange(category: .new,
                    text: "Account deletion now works correctly for everyone, including shared gardens. When you delete your account as a shared garden owner, you can transfer ownership to someone else first."),
            ]
        ),
        ChangelogRelease(
            version: "0.4.0",
            build: 51,
            date: "Jul 21, 2026",
            headline: "See what's new",
            changes: [
                ChangelogChange(category: .new,
                    text: "A 'What's New' summary now appears when you open a fresh build, with New, Improved, and Fixed highlights. Browse past releases anytime from Settings → What's New."),
            ]
        ),
        ChangelogRelease(
            version: "0.4.0",
            build: 50,
            date: "Jul 17, 2026",
            headline: "Sharing & recovery polish",
            changes: [
                ChangelogChange(category: .new,
                    text: "Recover garden entries that didn't make it into a shared garden — Settings flags any that need your review."),
                ChangelogChange(category: .improved,
                    text: "Sharing is simpler — gardens are now shared entirely through iCloud."),
                ChangelogChange(category: .fixed,
                    text: "Old invite links now explain that sharing moved to iCloud instead of failing."),
            ]
        ),
    ]
}
