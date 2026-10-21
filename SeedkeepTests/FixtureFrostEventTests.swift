import Foundation
import Testing
@testable import Seedkeep

#if DEBUG
struct FixtureFrostEventTests {
    private func day(_ text: String) -> CalendarDay {
        CalendarDay.parse(text)!
    }

    /// The sample ZIP's real frost dates, which the sample garden saves as they are.
    private func sampleDates() throws -> (last: String, first: String) {
        let climate = try #require(ClimateLookup.climate(forZip: FixtureSampleGarden.homeZip))
        return (climate.avgLastFrost, climate.avgFirstFrost)
    }

    private func flagged(_ planned: CalendarDay, _ dates: (last: String, first: String)) -> Bool {
        FrostCheck.check(
            plannedFor: planned.ymd, kind: "sowing", isCompleted: false, frostTolerance: "tender",
            lastFrost: dates.last, firstFrost: dates.first).isFlagged
    }

    /// Every day of `year` picks a flagged day on or after itself: today + 3 when that is flagged, and
    /// otherwise the year's first frost. Returns the number of days checked.
    private func sweep(_ year: Int, _ dates: (last: String, first: String)) throws -> Int {
        let firstFrost = try #require(CalendarDay.parseMonthDay(dates.first, year: year))
        var today = CalendarDay.firstDay(ofYear: year)
        var count = 0
        while today.year == year {
            let pick = FixtureFrostEvent.flaggedDay(today: today, lastFrost: dates.last, firstFrost: dates.first)
            let soon = today.adding(days: FixtureFrostEvent.daysAhead)
            #expect(pick >= today, "today \(today.ymd) picks \(pick.ymd)")
            #expect(flagged(pick, dates), "today \(today.ymd) picks \(pick.ymd)")
            if flagged(soon, dates) {
                #expect(pick == soon, "today \(today.ymd)")
            } else {
                #expect(pick == firstFrost, "today \(today.ymd)")
            }
            today = today.adding(days: 1)
            count += 1
        }
        return count
    }

    @Test func everyDayOfALeapAndACommonYearPicksAFlaggedDay() throws {
        let dates = try sampleDates()
        #expect(try sweep(2026, dates) == 365)
        #expect(try sweep(2028, dates) == 366)
    }

    @Test func aFlaggedDayThreeDaysAheadIsUsedWhenItIsFlagged() throws {
        let dates = try sampleDates()
        // Spring: before the last frost.
        #expect(FixtureFrostEvent.flaggedDay(today: day("2026-03-10"), lastFrost: dates.last, firstFrost: dates.first)
            == day("2026-03-13"))
        // Fall: on or after the first frost.
        #expect(FixtureFrostEvent.flaggedDay(today: day("2026-09-30"), lastFrost: dates.last, firstFrost: dates.first)
            == day("2026-10-03"))
        // Across the year end, the event is in the next year, before its last frost.
        #expect(FixtureFrostEvent.flaggedDay(today: day("2026-12-29"), lastFrost: dates.last, firstFrost: dates.first)
            == day("2027-01-01"))
    }

    @Test func midSeasonPicksThatYearsFirstFrost() throws {
        let dates = try sampleDates()
        #expect(FixtureFrostEvent.flaggedDay(today: day("2026-07-01"), lastFrost: dates.last, firstFrost: dates.first)
            == CalendarDay.parseMonthDay(dates.first, year: 2026))
        #expect(FixtureFrostEvent.flaggedDay(today: day("2028-07-15"), lastFrost: dates.last, firstFrost: dates.first)
            == CalendarDay.parseMonthDay(dates.first, year: 2028))
    }

    @Test func fallsBackToThreeDaysAheadWithoutAReadableFirstFrost() {
        #expect(FixtureFrostEvent.flaggedDay(today: day("2026-07-01"), lastFrost: "05-10", firstFrost: "10-32")
            == day("2026-07-04"))
    }

    @Test func theSampleZIPHasRealFrostDates() throws {
        let climate = try #require(ClimateLookup.climate(forZip: FixtureSampleGarden.homeZip))
        // Neither side is a calendar edge, so both seasons exist and the last frost comes first.
        #expect(climate.avgLastFrost != "01-01")
        #expect(climate.avgFirstFrost != "12-31")
        let last = try #require(CalendarDay.parseMonthDay(climate.avgLastFrost, year: 2026))
        let first = try #require(CalendarDay.parseMonthDay(climate.avgFirstFrost, year: 2026))
        #expect(last < first)
    }
}
#endif
