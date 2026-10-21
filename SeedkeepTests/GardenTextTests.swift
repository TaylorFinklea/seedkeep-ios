import Foundation
import Testing
@testable import Seedkeep

/// The grid's and events list's text: cell labels and hints, abbreviations, status strings, the
/// Square column and row order.
@Suite("Garden — text")
struct GardenTextTests {
    static let locale = Locale(identifier: "en_US")
    static let today = CalendarDay.make(year: 2026, month: 5, day: 10)!

    static func event(
        _ id: String, kind: String = "sowing", planned: String = "2026-05-04", done: Bool = false,
        seed: String? = "s1", x: Double? = 0.5, y: Double? = 0.5, frost: Bool = false, bed: String = "b"
    ) -> GridEvent {
        GridEvent(id: id, bedID: bed, seedID: seed, kind: kind, plannedFor: planned, isCompleted: done,
                  x: x, y: y, isFrostFlagged: frost)
    }

    static let names: [String: String] = ["s1": "Cherokee Purple", "s2": "Basil"]
    static func name(_ event: GridEvent) -> String? { event.seedID.flatMap { names[$0] } }
    static let square = GridSquare(column: 1, rowFromTop: 0)

    // MARK: - Cell labels

    @Test func emptySquareLabel() {
        #expect(GardenText.cellLabel(square: Self.square, contents: .empty, seedName: Self.name, locale: Self.locale)
                == "Row 1, square 2, empty")
    }

    @Test func singleEventLabel() {
        let contents = SquareContents(events: [Self.event("a")])
        #expect(GardenText.cellLabel(square: Self.square, contents: contents, seedName: Self.name, locale: Self.locale)
                == "Row 1, square 2, Cherokee Purple, Sow, May 4, 2026")
    }

    @Test func countDoneAndFrostInTheLabel() {
        let contents = SquareContents(events: [
            Self.event("a", done: true),
            Self.event("b", kind: "transplant", planned: "2026-05-06", seed: "s2", frost: true),
        ])
        #expect(GardenText.cellLabel(square: Self.square, contents: contents, seedName: Self.name, locale: Self.locale)
                == "Row 1, square 2, 2 plantings, Basil, Transplant, May 6, 2026, frost risk")
        let allDone = SquareContents(events: [Self.event("a", done: true)])
        #expect(GardenText.cellLabel(square: Self.square, contents: allDone, seedName: Self.name, locale: Self.locale)
                == "Row 1, square 2, Cherokee Purple, Sow, done")
    }

    @Test func seedlessNoteSaysNoteOnce() {
        let contents = SquareContents(events: [Self.event("n", kind: "note", seed: nil)])
        #expect(GardenText.cellLabel(square: Self.square, contents: contents, seedName: Self.name, locale: Self.locale)
                == "Row 1, square 2, Note, May 4, 2026")
    }

    // MARK: - Hints

    @Test func hintsByMode() {
        let empty = SquareContents.empty
        let blocked = SquareContents(events: [Self.event("a")])
        #expect(GardenText.cellHint(mode: .idle, contents: empty, brushSeedName: "Basil", movingSeedName: nil) == nil)
        #expect(GardenText.cellHint(mode: .painting, contents: empty, brushSeedName: "Basil", movingSeedName: nil)
                == "Plans Basil here")
        #expect(GardenText.cellHint(mode: .painting, contents: blocked, brushSeedName: "Basil", movingSeedName: nil) == nil)
        #expect(GardenText.cellHint(mode: .moving(eventID: "x"), contents: empty, brushSeedName: nil,
                                    movingSeedName: "Basil") == "Moves Basil here")
        #expect(GardenText.cellHint(mode: .moving(eventID: "x"), contents: blocked, brushSeedName: nil,
                                    movingSeedName: "Basil") == nil)
        // Completed history doesn't block a move.
        let history = SquareContents(events: [Self.event("old", done: true)])
        #expect(GardenText.cellHint(mode: .moving(eventID: "x"), contents: history, brushSeedName: nil,
                                    movingSeedName: "Basil") == "Moves Basil here")
    }

    @Test func noMoveHintOnTheMovingEventsOwnSquare() {
        // Activating it ends the move and writes nothing, so it doesn't say "Moves … here".
        let own = SquareContents(events: [Self.event("a")])
        #expect(GardenText.cellHint(mode: .moving(eventID: "a"), contents: own, brushSeedName: nil,
                                    movingSeedName: "Basil") == nil)
        let ownWithHistory = SquareContents(events: [Self.event("old", done: true), Self.event("a")])
        #expect(GardenText.cellHint(mode: .moving(eventID: "a"), contents: ownWithHistory, brushSeedName: nil,
                                    movingSeedName: "Basil") == nil)
    }

    // MARK: - Task picker

    @Test func aSeedlessEventIsOfferedOnlyNote() {
        #expect(GardenText.taskOptions(seedID: nil, current: "note") == [.note])
        // A legacy seedless sowing keeps its kind visible but can only become a Note.
        #expect(GardenText.taskOptions(seedID: nil, current: "sowing") == [.sowing, .note])
        #expect(GardenText.taskOptions(seedID: nil, current: "mystery") == [.note])
        #expect(GardenText.taskOptions(seedID: "s1", current: "note") == [.sowing, .transplant, .harvest, .note])
    }

    @Test func moveBannerText() {
        #expect(GardenText.moveBanner(seedName: "Basil") == "Tap an empty square to move Basil")
    }

    // MARK: - Cell text

    @Test func abbreviations() {
        #expect(GardenText.abbreviation("Cherokee Purple") == "CP")
        #expect(GardenText.abbreviation("basil") == "Ba")
        #expect(GardenText.abbreviation("Note") == "No")
        #expect(GardenText.abbreviation("  ") == "")
        #expect(GardenText.abbreviation("X") == "X")
    }

    @Test func subjects() {
        #expect(GardenText.subject(seedName: "Basil", kind: "sowing") == "Basil")
        #expect(GardenText.subject(seedName: nil, kind: "note") == "Note")
        #expect(GardenText.subject(seedName: nil, kind: "harvest") == "No seed")
        #expect(GardenText.kindName("sowing") == "Sow")
        #expect(GardenText.kindName("harvest") == "Harvest")
    }

    @Test func cellBackgrounds() {
        // Kind colour, `panel2` when empty, `kindNote` when all done (tokens only).
        #expect(BedGridCell.background(for: .empty) == WBColor.panel2)
        #expect(BedGridCell.background(for: SquareContents(events: [Self.event("a")])) == WBColor.kindSowing)
        #expect(BedGridCell.background(for: SquareContents(events: [Self.event("a", kind: "harvest")])) == WBColor.kindHarvest)
        #expect(BedGridCell.background(for: SquareContents(events: [Self.event("a", done: true)])) == WBColor.kindNote)
    }

    // MARK: - Status

    @Test func statusStrings() {
        func status(_ planned: String, done: Bool = false) -> String {
            GardenText.status(plannedFor: planned, isCompleted: done, today: Self.today).text
        }
        #expect(status("2026-05-10") == "Today")
        #expect(status("2026-05-11") == "In 1 day")
        #expect(status("2026-05-20") == "In 10 days")
        #expect(status("2026-05-09") == "1 day overdue")
        #expect(status("2026-04-30") == "10 days overdue")
        #expect(status("2026-04-30", done: true) == "Done")
        #expect(status("not a date") == "No date")
        #expect(GardenText.status(plannedFor: "2026-05-01", isCompleted: false, today: Self.today).isWarning)
        #expect(!GardenText.status(plannedFor: "2026-05-11", isCompleted: false, today: Self.today).isWarning)
    }

    @Test func statusCrossesYearAndLeapDay() {
        let leapToday = CalendarDay.make(year: 2028, month: 3, day: 1)!
        #expect(GardenText.status(plannedFor: "2028-02-28", isCompleted: false, today: leapToday) == .overdue(days: 2))
        let newYear = CalendarDay.make(year: 2026, month: 12, day: 31)!
        #expect(GardenText.status(plannedFor: "2027-01-01", isCompleted: false, today: newYear) == .upcoming(days: 1))
    }

    // MARK: - Events list

    @Test func squareColumnText() {
        #expect(GardenText.squareColumn(.square(GridSquare(column: 2, rowFromTop: 1))) == "R2 · S3")
        #expect(GardenText.squareColumn(.unplaced) == "Unplaced")
        #expect(GardenText.squareColumn(.outside) == "Outside the grid")
        #expect(GardenText.squareColumn(.noGrid) == "No grid")
        #expect(GardenText.positionLine(.square(GridSquare(column: 2, rowFromTop: 1))) == "Row 2, square 3")
    }

    @Test func spacingAndNotesPreview() {
        #expect(GardenText.spacing(inches: 12) == "Spacing: 12 in")
        #expect(GardenText.spacing(inches: nil) == nil)
        #expect(GardenText.spacing(inches: 0) == nil)
        #expect(GardenText.notesPreview("\n  Thin to 4\"  \nsecond") == "Thin to 4\"")
        #expect(GardenText.notesPreview("  \n ") == nil)
        #expect(GardenText.notesPreview(nil) == nil)
    }

    @Test func rowsAreOrderedByDateThenIdWithPlacementsAndFrost() {
        let size = GridSize(columns: 2, rows: 2)
        let events = [
            Self.event("c", planned: "2026-05-04", x: 1.5, y: 1.5),
            Self.event("b", planned: "2026-05-04", x: nil, y: nil),
            Self.event("a", planned: "2026-06-01", x: 2.5, y: 0.5),
            Self.event("z", planned: "2026-04-01", seed: nil, x: 0.5, y: 0.5, bed: "other"),
            Self.event("n", kind: "note", planned: "2026-05-01", seed: nil, x: 0.5, y: 0.5),
        ]
        let frost: [String: FrostCheck.Outcome] = [
            "c": .flagged(.spring, frostDate: CalendarDay.make(year: 2026, month: 5, day: 15)!),
            "a": .notFlagged,
        ]
        let rows = BedEventRow.rows(events: events, bedID: "b", size: size, seedNames: Self.names,
                                    notes: ["n": "Mulch\nlater"], frost: frost, today: Self.today, locale: Self.locale)
        #expect(rows.map(\.id) == ["n", "b", "c", "a"])
        #expect(rows.map(\.squareText) == ["R2 · S1", "Unplaced", "R1 · S2", "Outside the grid"])
        #expect(rows.map(\.canPlace) == [false, true, false, true])
        #expect(rows[0].subject == "Note")
        #expect(rows[0].notesPreview == "Mulch")
        #expect(rows[0].status == .overdue(days: 9))
        #expect(rows[2].frostSentence == "Frost risk if planted outdoors: before the average last frost (May 15).")
        #expect(rows[2].accessibilityLabel.hasSuffix("Frost risk if planted outdoors: before the average last frost (May 15)."))
        #expect(rows[3].frostSentence == nil)

        let noGrid = BedEventRow.rows(events: events, bedID: "b", size: nil, seedNames: Self.names,
                                      notes: [:], frost: [:], today: Self.today, locale: Self.locale)
        #expect(noGrid.allSatisfy { $0.squareText == "No grid" && !$0.canPlace })
    }
}
