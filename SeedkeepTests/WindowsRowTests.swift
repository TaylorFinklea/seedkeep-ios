import Foundation
import Testing
@testable import Seedkeep

private func day(_ text: String) -> CalendarDay {
    CalendarDay.parse(text)!
}

private func windowSeed(
    _ id: String = "s1",
    name: String = "Basil",
    verdict: String = "plant_now",
    outdoor: (start: String, end: String)? = ("2026-05-18", "2026-07-01"),
    indoor: (start: String, end: String)? = nil,
    active: Bool = true
) -> WindowSeed {
    WindowSeed(id: id, name: name, isArchived: false, isActive: active, verdict: verdict,
               outdoorStart: outdoor?.start, outdoorEnd: outdoor?.end,
               indoorStart: indoor?.start, indoorEnd: indoor?.end)
}

@MainActor
struct WindowsRowTests {
    /// June 1, so Basil's outdoor window (ends July 1) has 30 days left.
    private let today = day("2026-06-01")

    @Test func labelHasEveryPartInContractOrder() {
        let row = WindowsRowFormat.row(
            seed: windowSeed(indoor: ("2026-03-15", "2026-04-20")),
            reason: nil,
            today: today,
            nextPlanned: .init(bedName: "Herb bed", plannedFor: day("2026-06-05"))
        )
        // Month names and the date come from the device language, so the expectation uses the same formatters.
        let label = WindowsRowFormat.accessibilityLabel(row)
        let parts = [
            "Basil", "Plant now",
            "outdoors \(FrostCheck.monthDayText(day("2026-05-18"))) to \(FrostCheck.monthDayText(day("2026-07-01")))",
            "indoors \(FrostCheck.monthDayText(day("2026-03-15"))) to \(FrostCheck.monthDayText(day("2026-04-20")))",
            "30 days left",
            "next planned Herb bed \(humanDate("2026-06-05"))",
        ]
        #expect(label == parts.joined(separator: ", "))
    }

    @Test func labelLeavesOutTheIndoorWindowWhenThereIsNone() {
        let row = WindowsRowFormat.row(seed: windowSeed(), reason: nil, today: today, nextPlanned: nil)
        #expect(row.indoor == nil)
        #expect(!WindowsRowFormat.accessibilityLabel(row).contains("indoors"))
    }

    @Test func labelLeavesOutTheNextPlannedPartWhenNothingIsPlanned() {
        let row = WindowsRowFormat.row(seed: windowSeed(), reason: nil, today: today, nextPlanned: nil)
        let outdoors = "outdoors \(FrostCheck.monthDayText(day("2026-05-18"))) "
            + "to \(FrostCheck.monthDayText(day("2026-07-01")))"
        #expect(WindowsRowFormat.accessibilityLabel(row) == "Basil, Plant now, \(outdoors), 30 days left")
    }

    @Test func labelNamesTheNoWindowReasonInPlaceOfOutdoorDates() {
        let row = WindowsRowFormat.row(
            seed: windowSeed(verdict: "unknown", outdoor: nil),
            reason: .missingMaturity,
            today: today,
            nextPlanned: nil
        )
        let label = WindowsRowFormat.accessibilityLabel(row)
        #expect(row.timing == nil)
        #expect(!label.contains("outdoors"))
        #expect(!label.contains("days left"))
        #expect(label == "Basil, Later, \(RecommendationPanel.noWindowNote(for: .missingMaturity))")
    }

    @Test func noOutdoorWindowWithoutAReasonSaysSo() {
        let row = WindowsRowFormat.row(
            seed: windowSeed(verdict: "unknown", outdoor: nil),
            reason: nil,
            today: today,
            nextPlanned: nil
        )
        #expect(WindowsRowFormat.accessibilityLabel(row) == "Basil, Later, No outdoor window computed")
    }

    @Test func anUnreadableOrInvertedOutdoorWindowIsNoWindow() {
        let unreadable = WindowsRowFormat.row(
            seed: windowSeed(outdoor: ("2026-02-30", "2026-07-01")),
            reason: .incompleteInfo,
            today: today,
            nextPlanned: nil
        )
        #expect(unreadable.outdoor == nil)
        #expect(unreadable.timing == nil)
        #expect(unreadable.noWindowReason != nil)

        let inverted = WindowsRowFormat.row(
            seed: windowSeed(outdoor: ("2026-07-01", "2026-05-18")),
            reason: nil,
            today: today,
            nextPlanned: nil
        )
        #expect(inverted.outdoor == nil)
    }

    @Test func aWindowedSeedHasNoReason() {
        let row = WindowsRowFormat.row(seed: windowSeed(), reason: .seasonTooShort, today: today, nextPlanned: nil)
        #expect(row.noWindowReason == nil)
    }

    @Test func rowsTakeTheirGroupAndVerdictFromTheSeed() {
        // The window opens June 4, three days after `today`.
        let early = WindowsRowFormat.row(
            seed: windowSeed(verdict: "too_early", outdoor: ("2026-06-04", "2026-07-01")),
            reason: nil,
            today: today,
            nextPlanned: nil
        )
        #expect(early.group == .later)
        #expect(early.verdict == "too_early")
        #expect(early.timing == "opens in 3 days")
        let inactive = WindowsRowFormat.row(seed: windowSeed(active: false), reason: nil, today: today,
                                            nextPlanned: nil)
        #expect(!inactive.isActive)
    }

    @Test func groupHeaderCarriesTheCount() {
        #expect(WindowsRowFormat.groupHeader(.plantNow, count: 3) == "Plant now (3)")
        #expect(WindowsRowFormat.groupHeader(.closingSoon, count: 1) == "Closing soon (1)")
        #expect(WindowsRowFormat.groupHeader(.later, count: 0) == "Later (0)")
    }

    @Test func windowTextUsesAnEnDashBetweenTheEnds() {
        // The month names come from the device language, so the expectation uses the same formatter.
        let start = FrostCheck.monthDayText(day("2026-05-18"))
        let end = FrostCheck.monthDayText(day("2026-07-01"))
        #expect(WindowsRowFormat.windowText(day("2026-05-18")...day("2026-07-01")) == "\(start) – \(end)")
    }

    @Test func nextPlannedTextNamesTheBedAndDay() {
        let next = WindowsRow.NextPlanned(bedName: "Herb bed", plannedFor: day("2026-06-05"))
        #expect(WindowsRowFormat.nextPlannedText(next) == "Next planned: Herb bed, \(humanDate("2026-06-05"))")
    }
}
