import Foundation
import Testing
@testable import Seedkeep

private func event(
    _ id: String,
    bed: String? = "bed",
    seed: String? = "seed",
    kind: String = "sowing",
    on day: String = "2026-05-01",
    done: Bool = false,
    x: Double? = nil,
    y: Double? = nil,
    frost: Bool = false
) -> GridEvent {
    GridEvent(id: id, bedID: bed, seedID: seed, kind: kind, plannedFor: day, isCompleted: done,
              x: x, y: y, isFrostFlagged: frost)
}

private func day(_ text: String) -> CalendarDay {
    CalendarDay.parse(text)!
}

struct GardenGridTests {
    // MARK: Size

    @Test func sizeFloorsEachSide() {
        #expect(GardenGrid.size(widthFeet: 4, lengthFeet: 8) == GridSize(columns: 4, rows: 8))
        #expect(GardenGrid.size(widthFeet: 4.9, lengthFeet: 1.2) == GridSize(columns: 4, rows: 1))
        #expect(GardenGrid.size(widthFeet: 1, lengthFeet: 1) == GridSize(columns: 1, rows: 1))
        #expect(GardenGrid.size(widthFeet: 50, lengthFeet: 50) == GridSize(columns: 50, rows: 50))
    }

    @Test func invalidOrOversizedBedsHaveNoGrid() {
        let bad: [(Double?, Double?)] = [
            (nil, 8), (4, nil), (nil, nil), (0, 8), (4, 0), (0.5, 8), (4, 0.99), (-4, 8),
            (.nan, 8), (4, .infinity), (-.infinity, 8), (50.5, 8), (4, 51), (1e300, 1e300),
        ]
        for (width, length) in bad {
            #expect(GardenGrid.size(widthFeet: width, lengthFeet: length) == nil, "\(String(describing: width)) × \(String(describing: length))")
        }
        #expect(!GardenGrid.isValidDimension(nil))
        #expect(!GardenGrid.isValidDimension(.nan))
        #expect(GardenGrid.isValidDimension(1))
        #expect(GardenGrid.isValidDimension(60))
    }

    // MARK: Square ↔ position

    @Test func squareUsesNativeAxesWithRowsFromTheTop() {
        let size = GridSize(columns: 4, rows: 8)
        #expect(GardenGrid.square(x: 0, y: 0, in: size) == GridSquare(column: 0, rowFromTop: 7))
        #expect(GardenGrid.square(x: 0.5, y: 0.5, in: size) == GridSquare(column: 0, rowFromTop: 7))
        #expect(GardenGrid.square(x: 3.5, y: 7.5, in: size) == GridSquare(column: 3, rowFromTop: 0))
        #expect(GardenGrid.square(x: 1, y: 4, in: size) == GridSquare(column: 1, rowFromTop: 3))
    }

    @Test func farEdgeBelongsToTheLastWholeSquare() {
        let size = GridSize(columns: 4, rows: 8)
        #expect(GardenGrid.square(x: 4, y: 8, in: size) == GridSquare(column: 3, rowFromTop: 0))
        #expect(GardenGrid.square(x: 4, y: 0, in: size) == GridSquare(column: 3, rowFromTop: 7))
    }

    @Test func pointsOffTheGridAreOutside() {
        // A 4.5 × 8.5 bed draws 4 × 8 squares; the half-foot strips are outside.
        let size = GardenGrid.size(widthFeet: 4.5, lengthFeet: 8.5)!
        let outside: [(Double, Double)] = [
            (4.25, 1), (1, 8.25), (4.5, 8.5), (-0.01, 1), (1, -0.01), (100, 1), (1, 1e300),
            (.nan, 1), (1, .infinity), (-.infinity, 1),
        ]
        for (x, y) in outside {
            #expect(GardenGrid.square(x: x, y: y, in: size) == nil, "(\(x), \(y))")
        }
    }

    @Test func centreRoundTrips() {
        let size = GridSize(columns: 3, rows: 5)
        for column in 0..<3 {
            for row in 0..<5 {
                let square = GridSquare(column: column, rowFromTop: row)
                let centre = GardenGrid.centre(of: square, in: size)
                #expect(GardenGrid.square(x: centre.x, y: centre.y, in: size) == square)
            }
        }
        let centre = GardenGrid.centre(of: GridSquare(column: 0, rowFromTop: 0), in: size)
        #expect(centre.x == 0.5 && centre.y == 4.5)
    }

    @Test func labelsAreOneBased() {
        let square = GridSquare(column: 2, rowFromTop: 1)
        #expect(GardenGrid.label(square) == "Row 2, square 3")
        #expect(GardenGrid.shortLabel(square) == "R2 · S3")
        #expect(GardenGrid.contains(square, in: GridSize(columns: 3, rows: 2)))
        #expect(!GardenGrid.contains(square, in: GridSize(columns: 2, rows: 2)))
    }

    // MARK: Placement

    @Test func placementClassifiesUnplacedOutsideAndSquares() {
        let size = GridSize(columns: 4, rows: 8)
        #expect(GardenGrid.placement(of: event("a"), in: size) == .unplaced)
        #expect(GardenGrid.placement(of: event("b", x: 1), in: size) == .unplaced)
        #expect(GardenGrid.placement(of: event("c", x: 4.5, y: 2), in: size) == .outside)
        #expect(GardenGrid.placement(of: event("e", x: 1.5, y: 2.5), in: size)
            == .square(GridSquare(column: 1, rowFromTop: 5)))
    }

    @Test func aBedWithNoGridHasNoPlacement() {
        // Placed, unplaced and outside-looking events alike: none is outside a grid that isn't there.
        #expect(GardenGrid.placement(of: event("a"), in: nil) == .noGrid)
        #expect(GardenGrid.placement(of: event("b", x: 1, y: 1), in: nil) == .noGrid)
        #expect(GardenGrid.placement(of: event("c", x: -4, y: 1), in: nil) == .noGrid)
    }

    @Test func offGridListsAreSeparateAndOrdered() {
        let size = GridSize(columns: 4, rows: 8)
        let events = [
            event("u2", on: "2026-05-02"),
            event("u1", on: "2026-05-02"),
            event("o1", x: -1, y: 1),
            event("in", x: 1, y: 1),
            event("other", bed: "elsewhere"),
        ]
        let lists = GardenGrid.offGrid(events: events, bedID: "bed", size: size)
        #expect(lists.unplaced.map(\.id) == ["u1", "u2"])
        #expect(lists.outside.map(\.id) == ["o1"])
        #expect(lists.noGrid.isEmpty)
    }

    @Test func aBedWithNoGridListsAllItsEventsAsNoGrid() {
        let events = [
            event("u2", on: "2026-05-02"),
            event("u1", on: "2026-05-02"),
            event("o1", x: -1, y: 1),
            event("in", x: 1, y: 1),
            event("other", bed: "elsewhere"),
        ]
        // No "Place" actions: unplaced and outside are empty, and every event of the bed is listed in order.
        let lists = GardenGrid.offGrid(events: events, bedID: "bed", size: nil)
        #expect(lists.unplaced.isEmpty)
        #expect(lists.outside.isEmpty)
        #expect(lists.noGrid.map(\.id) == ["in", "o1", "u1", "u2"])
    }

    // MARK: Square contents

    @Test func contentsAreOrderedAndShowTheFirstIncompleteEvent() {
        let size = GridSize(columns: 4, rows: 8)
        let events = [
            event("late", on: "2026-06-01", x: 1.5, y: 1.5),
            event("doneEarly", on: "2026-04-01", done: true, x: 1.2, y: 1.8),
            event("b", on: "2026-05-01", x: 1.9, y: 1.1),
            event("a", on: "2026-05-01", x: 1.1, y: 1.9, frost: true),
            event("elsewhere", on: "2026-01-01", x: 3, y: 3),
            event("otherBed", bed: "x", on: "2026-01-01", x: 1.5, y: 1.5),
        ]
        let square = GridSquare(column: 1, rowFromTop: 6)
        let contents = GardenGrid.contents(of: square, events: events, bedID: "bed", size: size)
        #expect(contents.events.map(\.id) == ["doneEarly", "a", "b", "late"])
        #expect(contents.hasEvents)
        #expect(contents.blocksPainting)
        #expect(contents.shownEvent?.id == "a")
        #expect(contents.isFrostFlagged)
        #expect(!contents.isAllDone)
        #expect(GardenGrid.squares(events: events, bedID: "bed", size: size)[square] == contents)
    }

    @Test func completedHistoryDoesNotBlockPainting() {
        let size = GridSize(columns: 2, rows: 2)
        let events = [
            event("old", on: "2025-05-01", done: true, x: 0.5, y: 0.5, frost: true),
            event("newer", on: "2026-05-01", done: true, x: 0.5, y: 0.5),
        ]
        let contents = GardenGrid.contents(of: GridSquare(column: 0, rowFromTop: 1), events: events, bedID: "bed", size: size)
        #expect(contents.hasEvents)
        #expect(!contents.blocksPainting)
        #expect(contents.isAllDone)
        #expect(contents.shownEvent?.id == "newer")
        // Only incomplete events raise the frost flag.
        #expect(!contents.isFrostFlagged)
    }

    @Test func emptySquare() {
        let contents = GardenGrid.contents(of: GridSquare(column: 0, rowFromTop: 0), events: [], bedID: "bed",
                                           size: GridSize(columns: 1, rows: 1))
        #expect(contents == .empty)
        #expect(!contents.hasEvents && !contents.blocksPainting && contents.shownEvent == nil && !contents.isFrostFlagged)
    }

    // MARK: Plan date

    @Test func planDateUsesAFutureWindowStartUnlessTooLate() {
        let today = day("2026-04-10")
        #expect(GardenGrid.planDate(windowStart: "2026-05-01", verdict: "too_early", today: today) == day("2026-05-01"))
        #expect(GardenGrid.planDate(windowStart: "2026-05-01", verdict: nil, today: today) == day("2026-05-01"))
        #expect(GardenGrid.planDate(windowStart: "2026-05-01", verdict: "too_late", today: today) == today)
        #expect(GardenGrid.planDate(windowStart: "2026-04-10", verdict: "plant_now", today: today) == today)
        #expect(GardenGrid.planDate(windowStart: "2026-03-01", verdict: "plant_now", today: today) == today)
        #expect(GardenGrid.planDate(windowStart: nil, verdict: "plant_now", today: today) == today)
        #expect(GardenGrid.planDate(windowStart: "2026-02-30", verdict: "too_early", today: today) == today)
        #expect(GardenGrid.planDate(windowStart: "garbage", verdict: "too_early", today: today) == today)
    }

    // MARK: Brush order

    @Test func brushSeedsOrderByVerdictThenNameThenID() {
        let seeds = [
            BrushSeed(id: "9", name: "Zinnia", verdict: nil),
            BrushSeed(id: "8", name: "Unknown", verdict: "unknown"),
            BrushSeed(id: "7", name: "Carrot", verdict: "too_late"),
            BrushSeed(id: "6", name: "Bean", verdict: "too_early"),
            BrushSeed(id: "5", name: "Pea", verdict: "late"),
            BrushSeed(id: "4", name: "Kale", verdict: "plant_soon"),
            BrushSeed(id: "3", name: "Tomato", verdict: "plant_now"),
            BrushSeed(id: "2", name: "Basil", verdict: "plant_now"),
            BrushSeed(id: "1", name: "Basil", verdict: "plant_now"),
        ]
        #expect(GardenGrid.brushOrder(seeds).map(\.id) == ["1", "2", "3", "4", "5", "6", "7", "8", "9"])
    }
}
