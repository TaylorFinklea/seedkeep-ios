import Foundation
import Testing
@testable import Seedkeep

private func day(_ text: String) -> CalendarDay {
    CalendarDay.parse(text)!
}

struct SeasonTimelineTests {
    @Test func rangesNeedBothReadableEndsInOrder() {
        #expect(SeasonTimeline.range(start: "2026-05-01", end: "2026-06-01") == day("2026-05-01")...day("2026-06-01"))
        #expect(SeasonTimeline.range(start: "2026-05-01", end: "2026-05-01") == day("2026-05-01")...day("2026-05-01"))
        #expect(SeasonTimeline.range(start: nil, end: "2026-06-01") == nil)
        #expect(SeasonTimeline.range(start: "2026-05-01", end: nil) == nil)
        #expect(SeasonTimeline.range(start: "2026-06-02", end: "2026-06-01") == nil)
        #expect(SeasonTimeline.range(start: "2026-02-30", end: "2026-06-01") == nil)
    }

    @Test func domainIsTheCalendarYearByDefault() {
        let domain = SeasonTimeline.domain(year: 2026, ranges: [], markers: [])
        #expect(domain.start == day("2026-01-01"))
        #expect(domain.end == day("2026-12-31"))
        #expect(domain.dayCount == 365)
        #expect(SeasonTimeline.domain(year: 2024, ranges: [], markers: []).dayCount == 366)
    }

    @Test func domainExtendsToEveryRangeAndMarkerInWholeMonths() {
        let ranges = [day("2025-11-20")...day("2026-02-10"), day("2026-12-15")...day("2027-01-05")]
        let markers = [SeasonTimeline.Marker(kind: .today, day: day("2026-06-01"))]
        let domain = SeasonTimeline.domain(year: 2026, ranges: ranges, markers: markers)
        #expect(domain.start == day("2025-11-01"))
        #expect(domain.end == day("2027-01-31"))

        let late = SeasonTimeline.domain(
            year: 2026, ranges: [],
            markers: [SeasonTimeline.Marker(kind: .firstFrost, day: day("2027-02-03"))])
        #expect(late.end == day("2027-02-28"))
    }

    @Test func markersUseTodaysYear() {
        let markers = SeasonTimeline.markers(today: day("2024-06-01"), lastFrost: "02-29", firstFrost: "10-15")
        #expect(markers == [
            SeasonTimeline.Marker(kind: .today, day: day("2024-06-01")),
            SeasonTimeline.Marker(kind: .lastFrost, day: day("2024-02-29")),
            SeasonTimeline.Marker(kind: .firstFrost, day: day("2024-10-15")),
        ])
        let unreadable = SeasonTimeline.markers(today: day("2026-06-01"), lastFrost: "5-4", firstFrost: nil)
        #expect(unreadable.map(\.kind) == [.today])
        // A last frost with no first frost is no season, so no marker.
        #expect(SeasonTimeline.markers(today: day("2026-06-01"), lastFrost: "02-29", firstFrost: nil).map(\.kind)
            == [.today])
        #expect(SeasonTimeline.markers(today: day("2026-06-01"), lastFrost: "02-29", firstFrost: "10-15")[1].day
            == day("2026-02-28"))
    }

    @Test func markersFollowTheFrostSeason() {
        let today = day("2026-06-01")
        // Zone 10a: a spring season and no fall one, so no first-frost marker.
        #expect(SeasonTimeline.markers(today: today, lastFrost: "01-20", firstFrost: "12-31").map(\.kind)
            == [.today, .lastFrost])
        // A last frost of 01-01 has no spring season, so no last-frost marker.
        #expect(SeasonTimeline.markers(today: today, lastFrost: "01-01", firstFrost: "11-01").map(\.kind)
            == [.today, .firstFrost])
        // Both sides at the calendar edges: no season at all.
        #expect(SeasonTimeline.markers(today: today, lastFrost: "01-01", firstFrost: "12-31").map(\.kind) == [.today])
        // An inverted or equal pair has no season.
        #expect(SeasonTimeline.markers(today: today, lastFrost: "10-01", firstFrost: "05-10").map(\.kind) == [.today])
        #expect(SeasonTimeline.markers(today: today, lastFrost: "05-10", firstFrost: "05-10").map(\.kind) == [.today])
    }

    @Test func barsAreInclusiveWithAMinimumWidth() {
        let domain = SeasonTimeline.domain(year: 2026, ranges: [], markers: [])
        let whole = SeasonTimeline.bar(for: domain.start...domain.end, in: domain, totalWidth: 730)
        #expect(whole == SeasonTimeline.Bar(x: 0, width: 730))
        let january = SeasonTimeline.bar(for: day("2026-01-01")...day("2026-01-31"), in: domain, totalWidth: 730)
        #expect(january.x == 0)
        #expect(abs(january.width - 62) < 1e-9)
        let single = SeasonTimeline.bar(for: day("2026-07-01")...day("2026-07-01"), in: domain, totalWidth: 730)
        #expect(single.width == SeasonTimeline.minimumBarWidth)
        #expect(abs(single.x - 181 * 2) < 1e-9)
        #expect(abs(SeasonTimeline.markerX(day("2026-01-01"), in: domain, totalWidth: 730) - 1) < 1e-9)
    }

    @Test func aBarOnTheLastDayShiftsLeftToStayInside() {
        let domain = SeasonTimeline.domain(year: 2026, ranges: [], markers: [])
        let last = SeasonTimeline.bar(for: day("2026-12-31")...day("2026-12-31"), in: domain, totalWidth: 730)
        #expect(last.width == SeasonTimeline.minimumBarWidth)
        #expect(abs(last.x - (730 - SeasonTimeline.minimumBarWidth)) < 1e-9)
        #expect(last.x + last.width <= 730)
    }

    @Test func monthLabelsCoverTheDomain() {
        let english = Locale(identifier: "en_US")
        let domain = SeasonTimeline.domain(
            year: 2024, ranges: [day("2023-12-10")...day("2024-03-01")], markers: [])
        let months = SeasonTimeline.months(in: domain, locale: english)
        #expect(months.count == 13)
        #expect(months.first?.label == "Dec")
        #expect(months.first?.year == 2023)
        #expect(months.map(\.label).dropFirst().first == "Jan")
        #expect(months.last?.label == "Dec")
        #expect(abs(months.map(\.width).reduce(0, +) - 1) < 1e-9)
        #expect(months[0].offset == 0)
        #expect(abs(months[2].offset - Double(31 + 31) / Double(domain.dayCount)) < 1e-9)
        // February of a leap year is 29 days.
        #expect(abs(months[2].width - 29 / Double(domain.dayCount)) < 1e-9)
    }
}
