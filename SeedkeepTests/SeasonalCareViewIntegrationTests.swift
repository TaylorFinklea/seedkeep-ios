import Foundation
import Testing
@testable import Seedkeep

@Suite("Seasonal-care view-state helpers")
struct SeasonalCareViewIntegrationTests {
    private let calendar: Calendar = {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }()

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }

    private func row(
        id: String,
        seedName: String,
        state: AnnualCareState,
        startMonth: Int = 4,
        startDay: Int = 1,
        endMonth: Int = 4,
        endDay: Int = 30
    ) -> SeasonalCareTaskViewState {
        let occurrence = AnnualCareOccurrence(
            gardenYear: 2027,
            start: date(2027, startMonth, startDay),
            end: date(2027, endMonth, endDay)
        )
        return SeasonalCareTaskViewState(
            id: id,
            seedID: "seed-\(id)",
            seedName: seedName,
            title: id,
            instructions: "Instructions",
            evaluation: AnnualCareEvaluation(occurrence: occurrence, state: state),
            notificationEnabled: false
        )
    }

    @Test("Today orders due, overdue, then upcoming within 30 days")
    func todayOrdering() {
        let rows = SeasonalCareViewHelpers.todayRows([
            row(id: "upcoming", seedName: "A", state: .upcoming(daysUntilStart: 30), startMonth: 5, startDay: 1, endMonth: 5, endDay: 10),
            row(id: "beyond", seedName: "B", state: .upcoming(daysUntilStart: 31), startMonth: 6, startDay: 1, endMonth: 6, endDay: 10),
            row(id: "overdue", seedName: "C", state: .overdue),
            row(id: "due", seedName: "D", state: .due),
            row(id: "completed", seedName: "E", state: .completed)
        ])

        #expect(rows.map(\.id) == ["due", "overdue", "upcoming"])
    }

    @Test("Seed Detail retains the current completion separately")
    func detailGroups() {
        let groups = SeasonalCareViewHelpers.seedDetailGroups([
            row(id: "active", seedName: "A", state: .due),
            row(id: "done", seedName: "B", state: .completed)
        ])
        #expect(groups.active.map(\.id) == ["active"])
        #expect(groups.completed.map(\.id) == ["done"])
    }

    @Test("state and attribution labels remain accessible")
    func labels() {
        let base = row(id: "task", seedName: "Strawberry", state: .upcoming(daysUntilStart: 1))
        let labeled = SeasonalCareTaskViewState(
            id: base.id,
            seedID: base.seedID,
            seedName: base.seedName,
            title: base.title,
            instructions: base.instructions,
            evaluation: base.evaluation,
            notificationEnabled: true,
            authorityName: "University of Minnesota Extension",
            sourceTitle: "Care guide"
        )
        #expect(labeled.stateLabel == "Starts tomorrow")
        #expect(labeled.attributionLabel == "Source: University of Minnesota Extension, Care guide")
    }

    @Test("completion history is retained across annual rollover")
    func completionHistory() {
        let completions = [
            SeasonalCareCompletionViewState(
                id: "strawberry:2026", taskID: "strawberry", title: "Mulch strawberries",
                seedName: "Strawberry", gardenYear: 2026, completedAt: 4),
            SeasonalCareCompletionViewState(
                id: "asparagus:2026", taskID: "asparagus", title: "Let asparagus ferns grow",
                seedName: "Asparagus", gardenYear: 2026, completedAt: 3),
            SeasonalCareCompletionViewState(
                id: "strawberry:2025", taskID: "strawberry", title: "Mulch strawberries",
                seedName: "Strawberry", gardenYear: 2025, completedAt: 2)
        ]
        let history = SeasonalCareViewHelpers.completionHistory(
            completions,
            currentOccurrenceByTask: ["strawberry": 2026])
        #expect(history.map(\.id) == ["asparagus:2026", "strawberry:2025"])
    }

    @Test("Today uses the next incomplete occurrence after a completed window")
    func nextIncompleteOccurrence() throws {
        let window = try AnnualCareWindow(startMonth: 1, startDay: 5, endMonth: 1, endDay: 10)
        let evaluation = try window.nextIncompleteEvaluation(
            on: date(2026, 12, 20),
            calendar: calendar,
            timeZone: calendar.timeZone,
            completedGardenYears: [2026],
            firstOccurrenceDate: date(2026, 1, 1))
        #expect(evaluation.occurrence.gardenYear == 2027)
        #expect(evaluation.state == .upcoming(daysUntilStart: 16))
        #expect(SeasonalCareViewHelpers.todayRows([
            row(id: "next", seedName: "Seed", state: evaluation.state)
        ]).map(\.id) == ["next"])
    }
}
