import Foundation

/// The "This week" block on Today (R4 T): the seeds to plant now or soon, their summary line, the frost banner
/// that opens the block, and the route to Windows. Pure, so the rules are tested without the view.
///
/// Its inputs are Windows' inputs, so the block and the Windows screen agree on every seed: the active garden's
/// live seeds with a recommendation, grouped by `WindowsGrouping` and drawn with `WindowsRowFormat`.
enum TodayWeek {
    /// The rows the block shows, Plant now first. The counts are taken before this cap.
    static let rowLimit = 5
    /// The block's only line when there is no home location.
    static let noHomeLocationText = "Set a home location to see planting windows"

    /// One seed the block can read: its window seed, and the recommendation's reason, which the row text needs when
    /// the seed has no outdoor window. The view builds these as `WindowsView` does.
    struct Input: Sendable {
        let seed: WindowSeed
        let reason: PlantingRecommendation.Reason?
    }

    /// What the block's counts and rows are built from.
    struct Content: Equatable, Sendable {
        /// Eligible seeds in Plant now, before the row cap.
        let nowCount: Int
        /// Eligible seeds in Plant soon, before the row cap.
        let soonCount: Int
        /// The first `rowLimit` eligible seeds: Plant now, then Plant soon, each in Windows' order.
        let rows: [WindowsRow]

        static let empty = Content(nowCount: 0, soonCount: 0, rows: [])
    }

    /// The block's content for `inputs`, as of `today`. Eligibility is Windows': an archived seed is left out, and
    /// wishlist and saved seeds stay in. Only the Plant now and Plant soon groups count; Closing soon and Later don't.
    @MainActor
    static func content(_ inputs: [Input], today: CalendarDay) -> Content {
        let sections = WindowsGrouping.sections(inputs.map(\.seed))
        let now = sections.first { $0.group == .plantNow }?.seeds ?? []
        let soon = sections.first { $0.group == .plantSoon }?.seeds ?? []
        let reasons = Dictionary(
            inputs.compactMap { input in input.reason.map { (input.seed.id, $0) } },
            uniquingKeysWith: { first, _ in first }
        )
        let rows = (now + soon).prefix(rowLimit).map { seed in
            WindowsRowFormat.row(seed: seed, reason: reasons[seed.id], today: today, nextPlanned: nil)
        }
        return Content(nowCount: now.count, soonCount: soon.count, rows: Array(rows))
    }

    /// The summary line's words: "<n> to plant now · <n> soon", leaving out a zero part. Nil when neither count is
    /// above zero.
    static func summaryText(nowCount: Int, soonCount: Int) -> String? {
        var parts: [String] = []
        if nowCount > 0 { parts.append("\(nowCount) to plant now") }
        if soonCount > 0 { parts.append("\(soonCount) soon") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// What the summary line shows.
    enum Status: Equatable {
        /// Nothing is eligible yet, and recommendations are still loading or syncing.
        case loading
        /// A home location is set, and nothing is to plant now or soon.
        case nothingThisWeek
        /// The counts, in `summaryText`'s words.
        case counts(String)
    }

    /// Counts win whenever there are any, even while syncing. Without counts, syncing reads as loading, never as
    /// "nothing".
    static func status(nowCount: Int, soonCount: Int, isLoading: Bool) -> Status {
        if let text = summaryText(nowCount: nowCount, soonCount: soonCount) {
            return .counts(text)
        }
        return isLoading ? .loading : .nothingThisWeek
    }

    /// One row's secondary line: its group, then its timing ("Plant now · 30 days left").
    static func rowSubtitle(_ row: WindowsRow) -> String {
        [row.group.title, row.timing].compactMap { $0 }.joined(separator: " · ")
    }

    /// One row's VoiceOver label: "<name>, <group>, <timing>". The timing is left out when there is none.
    static func rowAccessibilityLabel(_ row: WindowsRow) -> String {
        [row.name, row.group.title, row.timing].compactMap { $0 }.joined(separator: ", ")
    }

    /// The parts of the block, top to bottom, after its header. The frost banner comes first when its count is above
    /// zero. Without a home location the block is that banner and one line that opens the home-location screen; no
    /// recommendation is computed for it.
    enum Part: Hashable, Sendable {
        case frostBanner(count: Int)
        case setHomeLocation
        case summary
        case rows
        case seeAll
    }

    static func parts(frostCount: Int, hasHomeLocation: Bool) -> [Part] {
        var parts: [Part] = []
        if frostCount > 0 {
            parts.append(.frostBanner(count: frostCount))
        }
        if hasHomeLocation {
            parts += [.summary, .rows, .seeAll]
        } else {
            parts.append(.setHomeLocation)
        }
        return parts
    }

    /// Where "See all in Windows" goes, from the host shell. The view applies the case it returns.
    enum SeeAllRoute: Equatable, Sendable {
        /// The compact tab shell: Windows is presented as a sheet over Today, as `WindowsHost.compactGardenSheet`,
        /// with the window's Garden session.
        case sheet
        /// The workbench: its route switches to Windows.
        case route

        static func route(for host: TodayFrost.Host) -> SeeAllRoute {
            switch host {
            case .compactTab: return .sheet
            case .workbenchRoute: return .route
            }
        }
    }
}

/// Pushed when a seed in the This week block is tapped: that seed's detail.
struct TodaySeedDestination: Hashable {
    let seedID: String
}
