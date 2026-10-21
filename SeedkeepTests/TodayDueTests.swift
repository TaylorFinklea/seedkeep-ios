import SeedkeepKit
import Testing
@testable import Seedkeep

/// Tests for `TodayDue`: the Due queue, day offsets and labels, and the row text. Dates are
/// `yyyy-MM-dd` strings, as the models store them.
@MainActor
@Suite("Today — due helpers")
struct TodayDueTests {
    private static let today = "2026-10-20"

    private static func event(
        _ id: String,
        household: String = "garden",
        planned: String,
        completedAt: Int64? = nil,
        deletedAt: Int64? = nil
    ) -> LocalPlantingEvent {
        LocalPlantingEvent(
            id: id,
            householdID: household,
            kindRaw: "sowing",
            plannedFor: planned,
            completedAt: completedAt,
            createdAt: 0,
            updatedAt: 0,
            deletedAt: deletedAt
        )
    }

    // MARK: - Queue

    @Test func queueLeavesOutDeletedCompletedAndFutureEvents() {
        let rows = [
            Self.event("overdue", planned: "2026-10-18"),
            Self.event("today", planned: "2026-10-20"),
            Self.event("deleted", planned: "2026-10-19", deletedAt: 1),
            Self.event("completed", planned: "2026-10-19", completedAt: 1),
            Self.event("future", planned: "2026-10-21"),
        ]
        let queue = TodayDue.queue(rows, householdID: "garden", today: Self.today)
        #expect(queue.map(\.id) == ["overdue", "today"])
    }

    @Test func queueLeavesOutOtherHouseholdsBeforeCuttingToSix() {
        // Seven other-household rows come first. A cut before scoping would leave none of ours.
        var rows = (1...7).map { Self.event("other-\($0)", household: "other", planned: "2026-10-01") }
        rows += (1...3).map { Self.event("mine-\($0)", planned: "2026-10-19") }
        let queue = TodayDue.queue(rows, householdID: "garden", today: Self.today)
        #expect(queue.map(\.id) == ["mine-1", "mine-2", "mine-3"])
    }

    @Test func queueCutsToSixKeepingTheGivenOrder() {
        let rows = (1...8).map { Self.event("event-\($0)", planned: "2026-10-0\($0)") }
        let queue = TodayDue.queue(rows, householdID: "garden", today: Self.today)
        #expect(TodayDue.queueLimit == 6)
        #expect(queue.map(\.id) == ["event-1", "event-2", "event-3", "event-4", "event-5", "event-6"])
    }

    @Test func queueIsEmptyWhenNothingIsDue() {
        let rows = [Self.event("future", planned: "2026-10-30")]
        #expect(TodayDue.queue(rows, householdID: "garden", today: Self.today).isEmpty)
        #expect(TodayDue.queue([], householdID: "garden", today: Self.today).isEmpty)
    }

    // MARK: - Day offsets

    @Test func dayOffsetIsNegativeForPastDates() {
        #expect(TodayDue.dayOffset(plannedFor: "2026-10-17", today: Self.today) == -3)
    }

    @Test func dayOffsetIsZeroForToday() {
        #expect(TodayDue.dayOffset(plannedFor: Self.today, today: Self.today) == 0)
    }

    @Test func dayOffsetIsPositiveForFutureDates() {
        #expect(TodayDue.dayOffset(plannedFor: "2026-10-27", today: Self.today) == 7)
    }

    @Test func dayOffsetCountsAcrossAYearBoundary() {
        #expect(TodayDue.dayOffset(plannedFor: "2027-01-02", today: "2026-12-31") == 2)
    }

    @Test func dayOffsetReadsAnInvalidDateAsToday() {
        #expect(TodayDue.dayOffset(plannedFor: "", today: Self.today) == 0)
        #expect(TodayDue.dayOffset(plannedFor: "not a date", today: Self.today) == 0)
        #expect(TodayDue.dayOffset(plannedFor: "2026-02-30", today: Self.today) == 0)
        #expect(TodayDue.dayOffset(plannedFor: "2026-10-27", today: "garbage") == 0)
    }

    @Test func dayOffsetCountsWholeDaysAcrossSpringForward() {
        // US clocks change on 2026-03-08. Each step is still exactly one day.
        #expect(TodayDue.dayOffset(plannedFor: "2026-03-09", today: "2026-03-08") == 1)
        #expect(TodayDue.dayOffset(plannedFor: "2026-03-08", today: "2026-03-09") == -1)
    }

    @Test func dayOffsetCountsWholeDaysAcrossFallBack() {
        // US clocks change on 2026-11-01. Each step is still exactly one day.
        #expect(TodayDue.dayOffset(plannedFor: "2026-11-02", today: "2026-11-01") == 1)
        #expect(TodayDue.dayOffset(plannedFor: "2026-11-01", today: "2026-11-02") == -1)
    }

    // MARK: - Day labels

    @Test func dayLabelNamesOverdueDaysInSingularAndPlural() {
        #expect(TodayDue.dayLabel(offset: -1) == "1 day overdue")
        #expect(TodayDue.dayLabel(offset: -4) == "4 days overdue")
    }

    @Test func dayLabelSaysTodayForZero() {
        #expect(TodayDue.dayLabel(offset: 0) == "Today")
    }

    @Test func dayLabelNamesDaysLeftInSingularAndPlural() {
        #expect(TodayDue.dayLabel(offset: 1) == "1 day left")
        #expect(TodayDue.dayLabel(offset: 5) == "5 days left")
    }

    // MARK: - Kind labels

    @Test func kindLabelNamesEachKind() {
        #expect(TodayDue.kindLabel("sowing") == "Sow")
        #expect(TodayDue.kindLabel("transplant") == "Transplant")
        #expect(TodayDue.kindLabel("harvest") == "Harvest")
        #expect(TodayDue.kindLabel("note") == "Note")
    }

    @Test func kindLabelMatchesTheDisplayNameOfEveryKind() {
        for kind in PlantingEventKind.allCases {
            #expect(TodayDue.kindLabel(kind.rawValue) == kind.displayName)
        }
    }

    @Test func kindLabelFallsBackToEventForAnUnknownKind() {
        #expect(TodayDue.kindLabel("graft") == "Event")
        #expect(TodayDue.kindLabel("") == "Event")
    }

    // MARK: - Row text

    @Test func rowSubtitleJoinsKindAndType() {
        #expect(TodayDue.rowSubtitle(kind: "Sow", type: "Tomato") == "Sow · Tomato")
    }

    @Test func rowSubtitleSkipsAMissingOrBlankType() {
        #expect(TodayDue.rowSubtitle(kind: "Sow", type: nil) == "Sow")
        #expect(TodayDue.rowSubtitle(kind: "Sow", type: "   ") == "Sow")
    }

    @Test func rowAccessibilityLabelJoinsNameKindAndDayLabel() {
        let label = TodayDue.rowAccessibilityLabel(name: "Brandywine", kind: "Sow", dayLabel: "1 day overdue")
        #expect(label == "Brandywine, Sow, 1 day overdue")
    }

    @Test func rowAccessibilityLabelNamesAMissingSeedAsUntitled() {
        let label = TodayDue.rowAccessibilityLabel(name: "Untitled seed", kind: "Note", dayLabel: "Today")
        #expect(label == "Untitled seed, Note, Today")
    }
}
