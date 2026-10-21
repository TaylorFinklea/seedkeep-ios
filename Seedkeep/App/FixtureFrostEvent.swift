// The sample garden's frost-flagged tender sowing (DEBUG builds only). Its day comes from the sample
// ZIP's real frost dates, so the garden's planting windows stay real. In spring and fall it is three
// days ahead, inside Today's 14-day banner. In mid-season it is the average first frost: still
// flagged on the grid, but outside the banner.
#if DEBUG
import Foundation

enum FixtureFrostEvent {
    /// Days from today for the flagged sowing, when that day is flagged.
    static let daysAhead = 3

    /// The sowing's day: three days ahead when `FrostCheck` flags it, otherwise the average first frost
    /// in `today`'s year, which is flagged. Falls back to three days ahead when the first frost can't
    /// be read.
    static func flaggedDay(today: CalendarDay, lastFrost: String, firstFrost: String) -> CalendarDay {
        let soon = today.adding(days: daysAhead)
        let outcome = FrostCheck.check(
            plannedFor: soon.ymd, kind: "sowing", isCompleted: false, frostTolerance: "tender",
            lastFrost: lastFrost, firstFrost: firstFrost)
        if outcome.isFlagged { return soon }
        return CalendarDay.parseMonthDay(firstFrost, year: today.year) ?? soon
    }
}
#endif
