import Foundation
import Testing
@testable import Seedkeep

struct CalendarDayTests {
    @Test func strictParsingRoundTrips() {
        #expect(CalendarDay.parse("2026-05-04") == CalendarDay.make(year: 2026, month: 5, day: 4))
        #expect(CalendarDay.parse("2024-02-29") != nil)
        let invalid = [
            "2026-02-29", "2026-02-30", "2026-04-31", "2026-13-01", "2026-00-10", "2026-01-00",
            "2026-1-01", "26-01-01", "2026-01-1", "2026/01/01", "2026-01-01T00:00", " 2026-01-01",
            "2026-01-01-", "", "abcd-ef-gh", "+202-01-01", "２０２６-01-01",
        ]
        for text in invalid {
            #expect(CalendarDay.parse(text) == nil, "\(text)")
        }
    }

    @Test func monthDayParsingFoldsLeapDayInCommonYears() {
        #expect(CalendarDay.parseMonthDay("02-29", year: 2026) == CalendarDay.parse("2026-02-28"))
        #expect(CalendarDay.parseMonthDay("02-29", year: 2024) == CalendarDay.parse("2024-02-29"))
        #expect(CalendarDay.parseMonthDay("05-04", year: 2026) == CalendarDay.parse("2026-05-04"))
        for text in ["02-30", "13-01", "5-04", "05-4", "05/04", "05-04-01", "", "MM-DD"] {
            #expect(CalendarDay.parseMonthDay(text, year: 2026) == nil, "\(text)")
        }
    }

    @Test func arithmeticAndFormatting() {
        let day = CalendarDay.parse("2024-12-30")!
        #expect(day.adding(days: 3).ymd == "2025-01-02")
        #expect(day.adding(days: -365).ymd == "2023-12-31")
        #expect(CalendarDay.parse("2024-03-01")!.adding(days: -1).ymd == "2024-02-29")
        #expect(day.days(to: CalendarDay.parse("2025-01-02")!) == 3)
        #expect(day.monthDay == "12-30")
        #expect(CalendarDay.parse("2024-02-10")!.lastOfMonth.ymd == "2024-02-29")
        #expect(CalendarDay.parse("2100-02-10")!.lastOfMonth.ymd == "2100-02-28")
        #expect(CalendarDay.parse("2000-02-10")!.lastOfMonth.ymd == "2000-02-29")
        #expect(CalendarDay.parse("2026-02-10")! < CalendarDay.parse("2026-02-11")!)
    }

    @Test func todayIsTheDeviceLocalDay() {
        // 2026-01-01 03:00 UTC is still Dec 31 in New York.
        let instant = Date(timeIntervalSince1970: 1_767_236_400)
        var newYork = Calendar(identifier: .gregorian)
        newYork.timeZone = TimeZone(identifier: "America/New_York")!
        var tokyo = Calendar(identifier: .gregorian)
        tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        #expect(CalendarDay.today(now: instant, calendar: newYork).ymd == "2025-12-31")
        #expect(CalendarDay.today(now: instant, calendar: tokyo).ymd == "2026-01-01")
    }

    @Test(arguments: [Calendar.Identifier.buddhist, .japanese, .hebrew, .islamicUmmAlQura])
    func todayIsGregorianWhateverTheDeviceCalendar(_ identifier: Calendar.Identifier) {
        // 2026-05-04 12:00 UTC.
        let instant = Date(timeIntervalSince1970: 1_777_896_000)
        var calendar = Calendar(identifier: identifier)
        calendar.timeZone = TimeZone(identifier: "America/Chicago")!
        #expect(CalendarDay.today(now: instant, calendar: calendar).ymd == "2026-05-04")
    }
}

struct FrostCheckTests {
    private func check(
        _ planned: String,
        kind: String = "sowing",
        done: Bool = false,
        tolerance: String? = "tender",
        last: String? = "05-04",
        first: String? = "10-01"
    ) -> FrostCheck.Outcome {
        FrostCheck.check(plannedFor: planned, kind: kind, isCompleted: done, frostTolerance: tolerance,
                         lastFrost: last, firstFrost: first)
    }

    @Test func springAndFallFlags() {
        #expect(check("2026-05-03") == .flagged(.spring, frostDate: CalendarDay.parse("2026-05-04")!))
        #expect(check("2026-05-04") == .notFlagged)
        #expect(check("2026-09-30") == .notFlagged)
        #expect(check("2026-10-01") == .flagged(.fall, frostDate: CalendarDay.parse("2026-10-01")!))
        #expect(check("2026-12-31").isFlagged)
        #expect(check("2027-01-01") == .flagged(.spring, frostDate: CalendarDay.parse("2027-05-04")!))
    }

    @Test func onlyIncompleteOutdoorPlantingsOfTenderSeeds() {
        #expect(check("2026-04-01", kind: "transplant").isFlagged)
        #expect(check("2026-04-01", kind: "harvest") == .notFlagged)
        #expect(check("2026-04-01", kind: "note") == .notFlagged)
        #expect(check("2026-04-01", done: true) == .notFlagged)
        #expect(check("2026-04-01", tolerance: "hardy") == .notFlagged)
        #expect(check("2026-04-01", tolerance: "half-hardy") == .notFlagged)
        #expect(check("2026-04-01", tolerance: nil) == .notFlagged)
        #expect(check("2026-04-01", tolerance: "Tender").isFlagged)
        #expect(check("2026-04-01", tolerance: " TENDER ").isFlagged)
    }

    @Test func unreadableOrMissingDatesAreUnavailable() {
        #expect(check("2026-02-30") == .unavailable)
        #expect(check("2026-4-01") == .unavailable)
        #expect(check("2026-04-01", last: nil) == .unavailable)
        #expect(check("2026-04-01", first: nil) == .unavailable)
        #expect(check("2026-04-01", last: "5-4") == .unavailable)
        #expect(check("2026-04-01", first: "10-32") == .unavailable)
    }

    @Test func inconsistentOrderingIsUnavailable() {
        #expect(check("2026-04-01", last: "10-01", first: "05-04") == .unavailable)
        #expect(check("2026-04-01", last: "05-04", first: "05-04") == .unavailable)
    }

    @Test func leapDayFrostDates() {
        // 02-29 becomes 02-28 in a common year.
        #expect(check("2026-02-27", last: "02-29", first: "11-01") == .flagged(.spring, frostDate: CalendarDay.parse("2026-02-28")!))
        #expect(check("2026-02-28", last: "02-29", first: "11-01") == .notFlagged)
        #expect(check("2024-02-28", last: "02-29", first: "11-01") == .flagged(.spring, frostDate: CalendarDay.parse("2024-02-29")!))
        #expect(check("2024-02-29", last: "02-29", first: "11-01") == .notFlagged)
    }

    @Test func calendarEdgesMeanNoFrostSeason() {
        // Zones 11–13: 01-01 and 12-31, so neither side flags.
        #expect(check("2026-12-31", last: "01-01", first: "12-31") == .unavailable)
        #expect(check("2026-01-01", last: "01-01", first: "12-31") == .unavailable)
        // Zone 10a: a spring season but no fall one.
        #expect(check("2026-01-10", last: "01-20", first: "12-31").isFlagged)
        #expect(check("2026-12-31", last: "01-20", first: "12-31") == .notFlagged)
        // A last frost of 01-01 alone turns off the spring flag only.
        #expect(check("2026-01-01", last: "01-01", first: "11-01") == .notFlagged)
        #expect(check("2026-11-01", last: "01-01", first: "11-01").isFlagged)
    }

    @Test func copy() {
        let english = Locale(identifier: "en_US")
        let spring = FrostCheck.sentence(side: .spring, frostDate: CalendarDay.parse("2026-05-04")!, locale: english)
        #expect(spring == "Frost risk if planted outdoors: before the average last frost (May 4).")
        let fall = FrostCheck.sentence(for: .flagged(.fall, frostDate: CalendarDay.parse("2026-10-01")!), locale: english)
        #expect(fall == "Frost risk if planted outdoors: on or after the average first frost (Oct 1).")
        #expect(FrostCheck.sentence(for: .notFlagged) == nil)
        #expect(FrostCheck.sentence(for: .unavailable) == nil)
        #expect(FrostCheck.estimateNote.contains("zone averages, not a forecast"))
    }

    @Test func seasonHasBothSidesOrOneAtAnEdge() {
        let zone5 = FrostCheck.season(lastFrost: "05-10", firstFrost: "10-01", year: 2026)
        #expect(zone5?.spring == CalendarDay.parse("2026-05-10"))
        #expect(zone5?.fall == CalendarDay.parse("2026-10-01"))
        // A first frost of 12-31 has no fall, and a last frost of 01-01 has no spring.
        let zone10 = FrostCheck.season(lastFrost: "01-20", firstFrost: "12-31", year: 2026)
        #expect(zone10?.spring == CalendarDay.parse("2026-01-20") && zone10?.fall == nil)
        let noSpring = FrostCheck.season(lastFrost: "01-01", firstFrost: "11-01", year: 2026)
        #expect(noSpring?.spring == nil && noSpring?.fall == CalendarDay.parse("2026-11-01"))
    }

    @Test func seasonIsNilWithoutReadableOrderedDatesOrAnyCalendarSide() {
        #expect(FrostCheck.season(lastFrost: "01-01", firstFrost: "12-31", year: 2026) == nil)
        #expect(FrostCheck.season(lastFrost: "10-01", firstFrost: "05-10", year: 2026) == nil)
        #expect(FrostCheck.season(lastFrost: "05-10", firstFrost: "05-10", year: 2026) == nil)
        #expect(FrostCheck.season(lastFrost: nil, firstFrost: "10-01", year: 2026) == nil)
        #expect(FrostCheck.season(lastFrost: "05-10", firstFrost: nil, year: 2026) == nil)
        #expect(FrostCheck.season(lastFrost: "5-10", firstFrost: "10-01", year: 2026) == nil)
    }
}
