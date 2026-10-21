import Foundation

/// Where the Windows screen is shown. Plan routes from the host shell, never from the sheet's size class.
enum WindowsHost: Equatable, Sendable {
    /// The workbench's Windows route. It is the window's root, so Plan never dismisses it.
    case workbenchRoute
    /// Garden's sheet over the regular-width workbench, where Garden is already the route.
    case workbenchGardenSheet
    /// Garden's sheet over the compact tab shell.
    case compactGardenSheet

    /// Plan closes the screen only when it is a sheet.
    var isSheet: Bool { self != .workbenchRoute }
}

/// Where a Plan from the Windows screen goes. Pure: the view applies the case it returns.
enum WindowsPlanRoute: Equatable, Sendable {
    /// The compact tab shell: `requestedTab = .garden`, and the Garden screen takes the session's `pendingPlan`.
    case gardenTab
    /// The regular-width workbench: its route switches to Garden.
    case gardenRoute
    /// No live bed has a grid: the add-a-bed prompt.
    case addBed
    /// The seed isn't active, so it can't be planned.
    case message(String)

    /// The route for a `GardenSession.plan` result, from the shell that hosts the screen.
    static func route(for result: GardenSession.PlanResult, seedName: String, host: WindowsHost) -> WindowsPlanRoute {
        switch result {
        case .planned:
            return host == .compactGardenSheet ? .gardenTab : .gardenRoute
        case .needsBed:
            return .addBed
        case .notActive:
            return .message("Move \(seedName) to Active to plan it.")
        }
    }
}

/// The Windows screen's layout. The timeline needs the regular-width workbench; iPad at accessibility sizes
/// and every compact layout use the grouped list.
enum WindowsLayout: Equatable, Sendable {
    case timeline
    case list

    static func choose(workbenchShell: Bool, isPad: Bool, accessibilitySize: Bool) -> WindowsLayout {
        guard workbenchShell else { return .list }
        return isPad && accessibilitySize ? .list : .timeline
    }
}

/// The timeline's geometry rules, pure. The drawing itself is in `WindowsView`.
enum WindowsTimeline {
    /// The chart is never narrower than this, and scrolls horizontally when the space is smaller.
    static let minimumChartWidth = 720.0

    /// Vertical distance between two marker-label tiers, in points, at the default text size. The view scales it
    /// with Dynamic Type.
    static let markerLabelSpacing = 72.0

    /// The gap between a marker's line and its label, in points.
    static let markerLabelGap = 4.0

    /// The chart's width for the space left beside the seed column: at least `minimumChartWidth`.
    static func chartWidth(available: Double) -> Double {
        guard available.isFinite else { return minimumChartWidth }
        return max(minimumChartWidth, available)
    }

    /// The date domain for the rows: the calendar year, extended to cover every row's windows and the markers,
    /// then padded to whole months.
    static func domain(year: Int, rows: [WindowsRow], markers: [SeasonTimeline.Marker]) -> SeasonTimeline.Domain {
        let ranges = rows.flatMap { [$0.outdoor, $0.indoor].compactMap { $0 } }
        return SeasonTimeline.domain(year: year, ranges: ranges, markers: markers)
    }

    /// The horizontal span a marker label takes: from its leading x across its width and the gap after it, and at
    /// least `spacing` wide. `spacing` scales with Dynamic Type, so a label keeps room even before its width is known.
    static func markerLabelSpan(leading: Double, width: Double, spacing: Double) -> ClosedRange<Double> {
        leading...(leading + max(width + markerLabelGap, spacing))
    }

    /// Assigns each marker label a tier (0 or 1) from its span, so labels whose spans overlap go on different tiers.
    /// The result follows the input order. A label that fits on neither tier takes the last one.
    static func labelTiers(_ spans: [ClosedRange<Double>], tiers: Int = 2) -> [Int] {
        guard tiers > 0 else { return spans.map { _ in 0 } }
        var result = Array(repeating: 0, count: spans.count)
        var lastEnd = Array(repeating: -Double.infinity, count: tiers)
        for index in spans.indices.sorted(by: { spans[$0].lowerBound < spans[$1].lowerBound }) {
            let span = spans[index]
            let tier = (0..<tiers).first { span.lowerBound >= lastEnd[$0] } ?? (tiers - 1)
            lastEnd[tier] = span.upperBound
            result[index] = tier
        }
        return result
    }

    /// The leading x of a marker label, so the label stays inside `0...chartWidth`. The label sits just right of
    /// its line. Near the right edge it ends just left of the line instead, and any remaining overflow is clamped.
    /// The line itself stays at `lineX`.
    static func markerLabelX(lineX: Double, labelWidth: Double, chartWidth: Double) -> Double {
        let widest = max(chartWidth - labelWidth, 0)
        let rightOfLine = lineX + markerLabelGap
        let leading = rightOfLine <= widest ? rightOfLine : lineX - markerLabelGap - labelWidth
        return min(max(leading, 0), widest)
    }
}
