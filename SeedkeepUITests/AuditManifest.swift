// The R2d audit manifest: the four iPhone configurations and the destinations and checkpoints each
// one walks, in walk order. The contract in .docs/ai/plans/2026-10-20-r2-design-system.md ("R2d-2") is
// authoritative; change this list only with it.
import Foundation

/// One launch: appearance × text size.
enum AuditConfiguration: String, CaseIterable, Sendable {
    case lightDefault = "light-default"
    case darkDefault = "dark-default"
    case lightAXXXL = "light-axxxl"
    case darkAXXXL = "dark-axxxl"

    enum Appearance: String, Sendable {
        case light, dark
    }

    var appearance: Appearance {
        switch self {
        case .lightDefault, .lightAXXXL: .light
        case .darkDefault, .darkAXXXL: .dark
        }
    }

    var isAccessibilitySize: Bool {
        self == .lightAXXXL || self == .darkAXXXL
    }

    /// The `UIPreferredContentSizeCategoryName` value. Default is Large, the system's default size.
    var contentSizeCategory: String {
        isAccessibilitySize ? "UICTContentSizeCategoryAccessibilityXXXL" : "UICTContentSizeCategoryL"
    }

    var launchArguments: [String] {
        [
            "-SeedkeepFixture",
            "-SeedkeepAuditLaunch",
            "-SeedkeepAppearance", appearance.rawValue,
            "-UIPreferredContentSizeCategoryName", contentSizeCategory,
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
        ]
    }
}

/// The sample garden's fixed ids (`Seedkeep/App/FixtureSampleGarden.swift`: kind, then 1-based index).
enum AuditFixture {
    /// French Single Mix: the most recently updated active seed, so the first row of the Seeds list.
    /// Only the sample garden has this id, so finding its row proves the fixture and readiness.
    static let readinessSeedID = "00000000-0000-4000-8000-000100000012"
    /// Brandywine: the named seed whose detail is audited (it has full growing info).
    static let detailSeedID = "00000000-0000-4000-8000-000100000001"
    /// North bed.
    static let northBedID = "00000000-0000-4000-8000-000200000001"
    /// The "Dill is up" entry.
    static let journalEntryID = "00000000-0000-4000-8000-000600000001"
}

/// A screen the audit visits. The raw value is the `screen.<name>` suffix the app sets on its root.
enum AuditDestination: String, CaseIterable, Sendable {
    case today, seeds, garden, journal, settings
    case seedDetail, addSeed, randomPick
    case bedDetail, windows
    case journalEntry
    case locations, tags, homeLocation, notifications, aiProvider, apiKeys, whatsNew

    var screenIdentifier: String { "screen.\(rawValue)" }

    /// The tab whose root this destination is, or opens from.
    var tab: AuditTab {
        switch self {
        case .today: .today
        case .seeds, .seedDetail, .addSeed, .randomPick: .seeds
        case .garden, .bedDetail, .windows: .garden
        case .journal, .journalEntry: .journal
        case .settings, .locations, .tags, .homeLocation, .notifications, .aiProvider, .apiKeys, .whatsNew:
            .settings
        }
    }

    var isTabRoot: Bool { rawValue == tab.rawValue }
}

enum AuditTab: String, CaseIterable, Sendable {
    case today, seeds, garden, journal, settings

    var identifier: String { "tab.\(rawValue)" }
    /// The tab's visible label, used only if the identifier doesn't reach the tab button.
    var title: String { rawValue.capitalized }
}

/// Where on a destination an audit runs.
enum AuditCheckpointPlan: Sendable, Equatable {
    /// As the destination opens.
    case top
    /// One page below where the previous checkpoint left off.
    case scrolledOnce
    /// Every page down to the end, one audit per page (`page.1`, `page.2`, ...).
    case pagesToEnd
    /// Scrolled until a named part of the screen is in view.
    case anchor(AuditAnchor)
}

enum AuditAnchor: String, Sendable {
    /// Seed detail's "Planting window" section.
    case plantingPanel
    /// Bed detail's layout canvas, down to its footer.
    case canvas
}

struct AuditStop: Sendable {
    let destination: AuditDestination
    let checkpoints: [AuditCheckpointPlan]
}

enum AuditManifest {
    /// Walk order. Tab roots come first in each group; the screens after a root open from it and close
    /// back to it.
    static let stops: [AuditStop] = [
        AuditStop(destination: .today, checkpoints: [.top, .pagesToEnd]),

        AuditStop(destination: .seeds, checkpoints: [.top, .scrolledOnce]),
        AuditStop(destination: .seedDetail, checkpoints: [.top, .anchor(.plantingPanel)]),
        AuditStop(destination: .addSeed, checkpoints: [.top, .scrolledOnce]),
        AuditStop(destination: .randomPick, checkpoints: [.top]),

        AuditStop(destination: .garden, checkpoints: [.top]),
        AuditStop(destination: .bedDetail, checkpoints: [.top, .anchor(.canvas)]),
        AuditStop(destination: .windows, checkpoints: [.top]),

        AuditStop(destination: .journal, checkpoints: [.top]),
        AuditStop(destination: .journalEntry, checkpoints: [.top]),

        AuditStop(destination: .settings, checkpoints: [.top, .pagesToEnd]),
        AuditStop(destination: .locations, checkpoints: [.top]),
        AuditStop(destination: .tags, checkpoints: [.top]),
        AuditStop(destination: .homeLocation, checkpoints: [.top]),
        AuditStop(destination: .notifications, checkpoints: [.top]),
        AuditStop(destination: .aiProvider, checkpoints: [.top]),
        AuditStop(destination: .apiKeys, checkpoints: [.top]),
        AuditStop(destination: .whatsNew, checkpoints: [.top]),
    ]

    /// Elements the audit never activates (contract "never-touch list"). The walker only taps the
    /// identifiers and Close/Cancel/Done/back buttons it names, so this list is a guard: a tap on a
    /// matching label fails the test instead of happening.
    static let neverTouchLabels: [String] = [
        "Check iCloud account", "Sync now", "Share", "Leave", "Delete",
    ]
}
