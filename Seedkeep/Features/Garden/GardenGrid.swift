import Foundation

/// A planting event as the grid reads it. Callers pass live (not deleted) events only.
struct GridEvent: Equatable, Hashable, Sendable, Identifiable {
    let id: String
    let bedID: String?
    let seedID: String?
    /// `PlantingEventKind` raw value: "sowing", "transplant", "harvest" or "note".
    let kind: String
    /// "yyyy-MM-dd".
    let plannedFor: String
    let isCompleted: Bool
    /// Feet from the bed's bottom-left corner. Both nil until the event is placed.
    let x: Double?
    let y: Double?
    /// The event's `FrostCheck` result, computed by the caller.
    let isFrostFlagged: Bool
}

/// A bed's whole-foot grid: one square per square foot.
struct GridSize: Equatable, Hashable, Sendable {
    let columns: Int
    let rows: Int
}

/// One square, 0-based. `rowFromTop` 0 is the row farthest from the bed's origin (y highest).
struct GridSquare: Hashable, Comparable, Sendable {
    let column: Int
    let rowFromTop: Int

    static func < (lhs: GridSquare, rhs: GridSquare) -> Bool {
        (lhs.rowFromTop, lhs.column) < (rhs.rowFromTop, rhs.column)
    }
}

/// What one square holds.
struct SquareContents: Equatable, Sendable {
    /// The square's events, ordered by `plannedFor` and then id.
    let events: [GridEvent]

    static let empty = SquareContents(events: [])

    /// Any placed live event, completed or not. In idle mode, tapping opens the square's list.
    var hasEvents: Bool { !events.isEmpty }

    /// An incomplete event blocks painting. A square of completed events can be painted again.
    var blocksPainting: Bool { events.contains { !$0.isCompleted } }

    /// The first incomplete event, otherwise the latest completed one.
    var shownEvent: GridEvent? { events.first { !$0.isCompleted } ?? events.last }

    /// True when any incomplete event is frost-flagged.
    var isFrostFlagged: Bool { events.contains { !$0.isCompleted && $0.isFrostFlagged } }

    /// True when every event is completed.
    var isAllDone: Bool { hasEvents && !blocksPainting }
}

/// Where an event sits relative to its bed's grid.
enum GridPlacement: Equatable, Sendable {
    case square(GridSquare)
    /// No coordinates yet.
    case unplaced
    /// Coordinates that fall outside the grid.
    case outside
    /// The bed has no grid, so the event is listed and editable but not placed on one.
    case noGrid
}

/// The bed's square-foot grid, pure. Native axes: x runs along the width, y up from the bottom.
enum GardenGrid {
    /// The largest size, in feet, that draws a grid.
    static let maxDimension = 50.0

    /// A size is valid when it is finite and at least 1.
    static func isValidDimension(_ feet: Double?) -> Bool {
        guard let feet else { return false }
        return feet.isFinite && feet >= 1
    }

    /// The bed's grid, or nil when either size is invalid or over the render limit.
    static func size(widthFeet: Double?, lengthFeet: Double?) -> GridSize? {
        guard isValidDimension(widthFeet), isValidDimension(lengthFeet),
              let width = widthFeet, let length = lengthFeet,
              width <= maxDimension, length <= maxDimension else { return nil }
        return GridSize(columns: Int(width.rounded(.down)), rows: Int(length.rounded(.down)))
    }

    /// The square holding (x, y), or nil when the point is outside the grid. A point exactly on the
    /// far edge of the last whole square belongs to that square; a fractional strip beyond the last
    /// whole square is outside.
    static func square(x: Double, y: Double, in size: GridSize) -> GridSquare? {
        guard x.isFinite, y.isFinite, size.columns > 0, size.rows > 0,
              x >= 0, y >= 0, x <= Double(size.columns), y <= Double(size.rows) else { return nil }
        let column = min(Int(x.rounded(.down)), size.columns - 1)
        let rowFromBottom = min(Int(y.rounded(.down)), size.rows - 1)
        return GridSquare(column: column, rowFromTop: size.rows - 1 - rowFromBottom)
    }

    /// The centre of a square in feet, which is where painting and moves place an event.
    static func centre(of square: GridSquare, in size: GridSize) -> (x: Double, y: Double) {
        (Double(square.column) + 0.5, Double(size.rows - 1 - square.rowFromTop) + 0.5)
    }

    /// True when the square lies inside the grid.
    static func contains(_ square: GridSquare, in size: GridSize) -> Bool {
        (0..<size.columns).contains(square.column) && (0..<size.rows).contains(square.rowFromTop)
    }

    /// "Row R, square S", 1-based.
    static func label(_ square: GridSquare) -> String {
        "Row \(square.rowFromTop + 1), square \(square.column + 1)"
    }

    /// "R2 · S3", for table columns.
    static func shortLabel(_ square: GridSquare) -> String {
        "R\(square.rowFromTop + 1) · S\(square.column + 1)"
    }

    static func placement(of event: GridEvent, in size: GridSize?) -> GridPlacement {
        guard let size else { return .noGrid }
        guard let x = event.x, let y = event.y else { return .unplaced }
        guard let square = square(x: x, y: y, in: size) else { return .outside }
        return .square(square)
    }

    /// Events ordered by `plannedFor` and then id.
    static func ordered(_ events: [GridEvent]) -> [GridEvent] {
        events.sorted { ($0.plannedFor, $0.id) < ($1.plannedFor, $1.id) }
    }

    /// The contents of every square that holds an event of `bedID`.
    static func squares(events: [GridEvent], bedID: String, size: GridSize) -> [GridSquare: SquareContents] {
        var grouped: [GridSquare: [GridEvent]] = [:]
        for event in events where event.bedID == bedID {
            if case .square(let square) = placement(of: event, in: size) {
                grouped[square, default: []].append(event)
            }
        }
        return grouped.mapValues { SquareContents(events: ordered($0)) }
    }

    /// The contents of one square.
    static func contents(of square: GridSquare, events: [GridEvent], bedID: String, size: GridSize) -> SquareContents {
        let inSquare = events.filter {
            $0.bedID == bedID && placement(of: $0, in: size) == .square(square)
        }
        return SquareContents(events: ordered(inSquare))
    }

    /// The bed's events that are not on the grid. Unplaced and outside events are listed with a "Place"
    /// action. A bed with no grid has no placing: all its events are `noGrid`.
    static func offGrid(
        events: [GridEvent],
        bedID: String,
        size: GridSize?
    ) -> (unplaced: [GridEvent], outside: [GridEvent], noGrid: [GridEvent]) {
        var unplaced: [GridEvent] = []
        var outside: [GridEvent] = []
        var noGrid: [GridEvent] = []
        for event in events where event.bedID == bedID {
            switch placement(of: event, in: size) {
            case .unplaced: unplaced.append(event)
            case .outside: outside.append(event)
            case .noGrid: noGrid.append(event)
            case .square: break
            }
        }
        return (ordered(unplaced), ordered(outside), ordered(noGrid))
    }

    /// The date a painted event gets: the outdoor window's start when it is after today and the
    /// verdict isn't `too_late`, otherwise today.
    static func planDate(windowStart: String?, verdict: String?, today: CalendarDay) -> CalendarDay {
        guard verdict != "too_late",
              let windowStart, let start = CalendarDay.parse(windowStart),
              start > today else { return today }
        return start
    }

    /// Verdict order for the brush list.
    static let brushVerdictOrder = ["plant_now", "plant_soon", "late", "too_early", "too_late"]

    /// Brush seeds ordered by verdict (plant_now, plant_soon, late, too_early, too_late, then none or
    /// unknown), then name, then id. Callers pass the active seeds of the active garden.
    static func brushOrder(_ seeds: [BrushSeed]) -> [BrushSeed] {
        func rank(_ verdict: String?) -> Int {
            verdict.flatMap { brushVerdictOrder.firstIndex(of: $0) } ?? brushVerdictOrder.count
        }
        return seeds.sorted { lhs, rhs in
            let left = rank(lhs.verdict), right = rank(rhs.verdict)
            if left != right { return left < right }
            let byName = lhs.name.localizedStandardCompare(rhs.name)
            if byName != .orderedSame { return byName == .orderedAscending }
            return lhs.id < rhs.id
        }
    }
}

/// A seed offered as a brush.
struct BrushSeed: Equatable, Hashable, Sendable, Identifiable {
    let id: String
    let name: String
    /// The planting window's verdict, or nil when the seed has none.
    let verdict: String?
}
