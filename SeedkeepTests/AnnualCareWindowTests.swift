import Foundation
import Testing
@testable import Seedkeep

private func testDate(_ value: String) -> Date {
    ISO8601DateFormatter().date(from: value)!
}

private func utcCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
}

@Test("ordinary window has inclusive due boundaries")
func ordinaryBoundaries() throws {
    let window = try AnnualCareWindow(startMonth: 4, startDay: 1, endMonth: 4, endDay: 30)
    let calendar = utcCalendar()
    let zone = calendar.timeZone
    #expect(try window.evaluation(on: testDate("2026-03-31T12:00:00Z"), calendar: calendar, timeZone: zone, completedGardenYears: []).state == .upcoming(daysUntilStart: 1))
    #expect(try window.evaluation(on: testDate("2026-04-01T12:00:00Z"), calendar: calendar, timeZone: zone, completedGardenYears: []).state == .due)
    #expect(try window.evaluation(on: testDate("2026-04-30T12:00:00Z"), calendar: calendar, timeZone: zone, completedGardenYears: []).state == .due)
}

@Test("uncompleted ordinary occurrence remains overdue until next start")
func ordinaryRollover() throws {
    let window = try AnnualCareWindow(startMonth: 4, startDay: 1, endMonth: 4, endDay: 30)
    let calendar = utcCalendar()
    let evaluation = try window.evaluation(
        on: testDate("2026-01-10T12:00:00Z"), calendar: calendar,
        timeZone: calendar.timeZone, completedGardenYears: [], firstGardenYear: 2025)
    #expect(evaluation.state == .overdue)
    #expect(evaluation.occurrence.gardenYear == 2025)
}

@Test("cross-year window keeps the prior occurrence overdue through the gap")
func crossYearGapAndJanuary() throws {
    let window = try AnnualCareWindow(startMonth: 11, startDay: 1, endMonth: 2, endDay: 15)
    let calendar = utcCalendar()
    let january = try window.evaluation(
        on: testDate("2027-01-10T12:00:00Z"), calendar: calendar,
        timeZone: calendar.timeZone, completedGardenYears: [])
    #expect(january.state == .due)
    #expect(january.occurrence.gardenYear == 2026)
    let gap = try window.evaluation(
        on: testDate("2027-08-01T12:00:00Z"), calendar: calendar,
        timeZone: calendar.timeZone, completedGardenYears: [])
    #expect(gap.state == .overdue)
    #expect(gap.occurrence.gardenYear == 2026)
}

@Test("creation year makes the first occurrence upcoming instead of inventing old overdue work")
func firstOccurrence() throws {
    let window = try AnnualCareWindow(startMonth: 11, startDay: 1, endMonth: 2, endDay: 15)
    let calendar = utcCalendar()
    let evaluation = try window.evaluation(
        on: testDate("2027-01-10T12:00:00Z"), calendar: calendar,
        timeZone: calendar.timeZone, completedGardenYears: [], firstGardenYear: 2027)
    #expect(evaluation.state == .upcoming(daysUntilStart: 295))
    #expect(evaluation.occurrence.gardenYear == 2027)
}

@Test("creation after a same-year window starts the next annual occurrence")
func creationAfterWindow() throws {
    let window = try AnnualCareWindow(startMonth: 4, startDay: 1, endMonth: 4, endDay: 30)
    let calendar = utcCalendar()
    let created = testDate("2026-05-01T12:00:00Z")
    let evaluation = try window.evaluation(
        on: created, calendar: calendar, timeZone: calendar.timeZone,
        completedGardenYears: [], firstGardenYear: 2026, firstOccurrenceDate: created)
    #expect(evaluation.state == .upcoming(daysUntilStart: 335))
    #expect(evaluation.occurrence.gardenYear == 2027)

    let endDayCreation = testDate("2026-04-30T23:00:00Z")
    let endDayEvaluation = try window.evaluation(
        on: endDayCreation, calendar: calendar, timeZone: calendar.timeZone,
        completedGardenYears: [], firstOccurrenceDate: endDayCreation)
    #expect(endDayEvaluation.state == .due)
    #expect(endDayEvaluation.occurrence.gardenYear == 2026)
}

@Test("cross-year creation derives the containing prior start year")
func crossYearCreationUsesContainingOccurrence() throws {
    let window = try AnnualCareWindow(startMonth: 11, startDay: 1, endMonth: 2, endDay: 15)
    let calendar = utcCalendar()
    let created = testDate("2027-01-10T12:00:00Z")
    let evaluation = try window.evaluation(
        on: created, calendar: calendar, timeZone: calendar.timeZone,
        completedGardenYears: [], firstOccurrenceDate: created)
    #expect(evaluation.state == .due)
    #expect(evaluation.occurrence.gardenYear == 2026)
}

@Test("first eligibility uses the supplied local time zone")
func creationDayUsesTimeZone() throws {
    let window = try AnnualCareWindow(startMonth: 4, startDay: 1, endMonth: 4, endDay: 30)
    let instant = testDate("2026-05-01T00:30:00Z")
    var calendar = Calendar(identifier: .gregorian)
    let chicago = try #require(TimeZone(identifier: "America/Chicago"))
    calendar.timeZone = chicago
    let local = try window.evaluation(
        on: instant, calendar: calendar, timeZone: chicago,
        completedGardenYears: [], firstOccurrenceDate: instant)
    #expect(local.occurrence.gardenYear == 2026)
    #expect(local.state == .due)

    let utc = TimeZone(secondsFromGMT: 0)!
    calendar.timeZone = utc
    let universal = try window.evaluation(
        on: instant, calendar: calendar, timeZone: utc,
        completedGardenYears: [], firstOccurrenceDate: instant)
    #expect(universal.occurrence.gardenYear == 2027)
    #expect(universal.state == .upcoming(daysUntilStart: 335))
}

@Test("next incomplete evaluation advances past a completed current year")
func nextIncompleteAfterCompletion() throws {
    let window = try AnnualCareWindow(startMonth: 1, startDay: 5, endMonth: 1, endDay: 10)
    let calendar = utcCalendar()
    let created = testDate("2026-01-01T12:00:00Z")
    let evaluation = try window.nextIncompleteEvaluation(
        on: testDate("2026-12-20T12:00:00Z"), calendar: calendar,
        timeZone: calendar.timeZone, completedGardenYears: [2026],
        firstOccurrenceDate: created)
    #expect(evaluation.occurrence.gardenYear == 2027)
    #expect(evaluation.state == .upcoming(daysUntilStart: 16))
}

@Test("February 29 resolves to February 28 outside leap years")
func leapDayResolution() throws {
    let window = try AnnualCareWindow(startMonth: 2, startDay: 29, endMonth: 3, endDay: 1)
    let calendar = utcCalendar()
    let occurrence = try window.occurrence(gardenYear: 2025, calendar: calendar, timeZone: calendar.timeZone)
    #expect(calendar.component(.month, from: occurrence.start) == 2)
    #expect(calendar.component(.day, from: occurrence.start) == 28)
}

@Test("invalid month and day pairs are rejected")
func validation() {
    #expect(throws: AnnualCareWindow.ValidationError.invalidMonth(13)) {
        try AnnualCareWindow(startMonth: 13, startDay: 1, endMonth: 1, endDay: 1)
    }
    #expect(throws: AnnualCareWindow.ValidationError.invalidDay(month: 4, day: 31)) {
        try AnnualCareWindow(startMonth: 4, startDay: 31, endMonth: 5, endDay: 1)
    }
}
