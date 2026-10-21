import Foundation
import Testing
@testable import Seedkeep

/// A This week input for a seed with an outdoor window. `verdict` picks its group, as Windows reads it.
private func input(
    _ id: String,
    _ name: String = "Basil",
    verdict: String = "plant_now",
    start: String? = "2026-05-18",
    end: String? = "2026-07-01",
    archived: Bool = false,
    active: Bool = true,
    reason: PlantingRecommendation.Reason? = nil
) -> TodayWeek.Input {
    TodayWeek.Input(
        seed: WindowSeed(id: id, name: name, isArchived: archived, isActive: active, verdict: verdict,
                         outdoorStart: start, outdoorEnd: end, indoorStart: nil, indoorEnd: nil),
        reason: reason
    )
}

@MainActor
@Suite("Today — this week")
struct TodayWeekTests {
    /// June 1, so Basil's outdoor window (ends July 1) has 30 days left.
    private let today = CalendarDay.make(year: 2026, month: 6, day: 1)!

    // MARK: - Summary line

    @Test func summaryTextLeavesOutZeroParts() {
        #expect(TodayWeek.summaryText(nowCount: 3, soonCount: 2) == "3 to plant now · 2 soon")
        #expect(TodayWeek.summaryText(nowCount: 3, soonCount: 0) == "3 to plant now")
        #expect(TodayWeek.summaryText(nowCount: 0, soonCount: 2) == "2 soon")
        #expect(TodayWeek.summaryText(nowCount: 1, soonCount: 1) == "1 to plant now · 1 soon")
    }

    @Test func summaryTextIsNilWhenNothingIsNowOrSoon() {
        #expect(TodayWeek.summaryText(nowCount: 0, soonCount: 0) == nil)
    }

    @Test func statusShowsCountsEvenWhileSyncing() {
        #expect(TodayWeek.status(nowCount: 2, soonCount: 0, isLoading: true) == .counts("2 to plant now"))
        #expect(TodayWeek.status(nowCount: 0, soonCount: 1, isLoading: false) == .counts("1 soon"))
    }

    @Test func statusReadsLoadingNotNothingWhileSyncing() {
        #expect(TodayWeek.status(nowCount: 0, soonCount: 0, isLoading: true) == .loading)
    }

    @Test func statusSaysNothingOnceNotSyncing() {
        #expect(TodayWeek.status(nowCount: 0, soonCount: 0, isLoading: false) == .nothingThisWeek)
    }

    // MARK: - Eligibility matches Windows

    @Test func eligibleGroupsAreExactlyPlantNowAndPlantSoonLikeWindows() {
        let inputs = [
            input("now", verdict: "plant_now"),
            input("soon", verdict: "plant_soon"),
            input("closing", verdict: "late"),
            input("early", verdict: "too_early"),
            input("late", verdict: "too_late"),
            input("unknown", verdict: "unknown"),
        ]
        let content = TodayWeek.content(inputs, today: today)
        #expect(content.nowCount == 1)
        #expect(content.soonCount == 1)
        #expect(content.rows.map(\.id) == ["now", "soon"])

        // The same seeds, grouped by Windows, give the same two groups.
        let windowsSections = WindowsGrouping.sections(inputs.map(\.seed))
        let windowsNow = windowsSections.first { $0.group == .plantNow }?.seeds.map(\.id) ?? []
        let windowsSoon = windowsSections.first { $0.group == .plantSoon }?.seeds.map(\.id) ?? []
        #expect(windowsNow == ["now"])
        #expect(windowsSoon == ["soon"])
    }

    @Test func archivedSeedsAreLeftOut() {
        let content = TodayWeek.content([
            input("live"),
            input("archived", archived: true),
        ], today: today)
        #expect(content.nowCount == 1)
        #expect(content.rows.map(\.id) == ["live"])
    }

    @Test func wishlistAndSavedSeedsStayIn() {
        // A wishlist or saved seed is not active, so Plan can't paint with it, but This week still lists it, as Windows does.
        let content = TodayWeek.content([
            input("wishlist", active: false),
            input("saved", verdict: "plant_soon", active: false),
        ], today: today)
        #expect(content.nowCount == 1)
        #expect(content.soonCount == 1)
        #expect(content.rows.map(\.id) == ["wishlist", "saved"])
    }

    @Test func noEligibleSeedsGivesEmptyContent() {
        #expect(TodayWeek.content([], today: today) == .empty)
        #expect(TodayWeek.content([input("later", verdict: "too_early")], today: today) == .empty)
    }

    // MARK: - Ordering and the five-row cap

    @Test func rowsPutPlantNowBeforePlantSoon() {
        let content = TodayWeek.content([
            input("soon-a", verdict: "plant_soon", start: "2026-05-01"),
            input("now", verdict: "plant_now", start: "2026-06-10"),
            input("soon-b", verdict: "plant_soon", start: "2026-05-02"),
        ], today: today)
        #expect(content.rows.map(\.id) == ["now", "soon-a", "soon-b"])
        #expect(content.rows.map(\.group) == [.plantNow, .plantSoon, .plantSoon])
    }

    @Test func rowsKeepWindowsOrderWithinAGroup() {
        // Same window start: the name decides, as Windows orders its groups.
        let content = TodayWeek.content([
            input("basil", "Basil", start: "2026-05-18"),
            input("arugula", "Arugula", start: "2026-05-18"),
            input("dill", "Dill", start: "2026-05-01"),
        ], today: today)
        #expect(content.rows.map(\.id) == ["dill", "arugula", "basil"])
    }

    @Test func rowsAreCappedAtFiveWhileTheCountsAreNot() {
        // Seven now and four soon: the counts are the full eligible numbers, and the rows are the first five now.
        var inputs: [TodayWeek.Input] = (1...7).map { index in
            input("now-\(index)", "Seed \(index)", start: "2026-05-0\(index)")
        }
        inputs += (1...4).map { index in
            input("soon-\(index)", "Soon \(index)", verdict: "plant_soon", start: "2026-04-0\(index)")
        }
        let content = TodayWeek.content(inputs, today: today)
        #expect(TodayWeek.rowLimit == 5)
        #expect(content.nowCount == 7)
        #expect(content.soonCount == 4)
        #expect(content.rows.count == 5)
        #expect(content.rows.map(\.id) == ["now-1", "now-2", "now-3", "now-4", "now-5"])
    }

    @Test func rowsFillFromPlantSoonWhenPlantNowIsShort() {
        let inputs = [input("now", start: "2026-05-18")] + (1...5).map { index in
            input("soon-\(index)", "Soon \(index)", verdict: "plant_soon", start: "2026-05-0\(index)")
        }
        let content = TodayWeek.content(inputs, today: today)
        #expect(content.nowCount == 1)
        #expect(content.soonCount == 5)
        #expect(content.rows.map(\.id) == ["now", "soon-1", "soon-2", "soon-3", "soon-4"])
    }

    @Test func reasonReachesRowsWithoutAnOutdoorWindow() {
        let content = TodayWeek.content([
            input("no-window", verdict: "plant_now", start: nil, end: nil, reason: .missingMaturity),
        ], today: today)
        #expect(content.rows.first?.noWindowReason != nil)
        #expect(content.rows.first?.timing == nil)
    }

    // MARK: - Row text

    @Test func rowTextHasGroupAndTiming() {
        let content = TodayWeek.content([input("basil")], today: today)
        let row = content.rows[0]
        #expect(TodayWeek.rowSubtitle(row) == "Plant now · 30 days left")
        #expect(TodayWeek.rowAccessibilityLabel(row) == "Basil, Plant now, 30 days left")
    }

    @Test func rowAccessibilityLabelLeavesOutTimingWhenThereIsNone() {
        let content = TodayWeek.content([
            input("basil", start: nil, end: nil),
        ], today: today)
        let row = content.rows[0]
        #expect(row.timing == nil)
        #expect(TodayWeek.rowSubtitle(row) == "Plant now")
        #expect(TodayWeek.rowAccessibilityLabel(row) == "Basil, Plant now")
    }

    @Test func rowAccessibilityLabelNamesPlantSoonGroup() {
        let content = TodayWeek.content([
            input("leek", "Leek", verdict: "plant_soon", start: "2026-06-20", end: "2026-07-10"),
        ], today: today)
        #expect(TodayWeek.rowAccessibilityLabel(content.rows[0]) == "Leek, Plant soon, 39 days left")
    }

    // MARK: - Block order and frost placement

    @Test func frostBannerOpensTheBlockWhenItsCountIsAboveZero() {
        let parts = TodayWeek.parts(frostCount: 2, hasHomeLocation: true)
        #expect(parts.first == .frostBanner(count: 2))
        #expect(parts == [.frostBanner(count: 2), .summary, .rows, .seeAll])
    }

    @Test func frostBannerIsLeftOutAtZero() {
        let parts = TodayWeek.parts(frostCount: 0, hasHomeLocation: true)
        #expect(!parts.contains(.frostBanner(count: 0)))
        #expect(parts == [.summary, .rows, .seeAll])
    }

    @Test func withoutAHomeLocationTheBlockIsOnlyTheLine() {
        #expect(TodayWeek.parts(frostCount: 0, hasHomeLocation: false) == [.setHomeLocation])
        #expect(TodayWeek.parts(frostCount: 3, hasHomeLocation: false) == [.frostBanner(count: 3), .setHomeLocation])
    }

    // MARK: - See all in Windows

    @Test func seeAllOpensASheetOnCompactAndTheRouteOnTheWorkbench() {
        #expect(TodayWeek.SeeAllRoute.route(for: .compactTab) == .sheet)
        #expect(TodayWeek.SeeAllRoute.route(for: .workbenchRoute) == .route)
    }

    @Test func theCompactSheetClosesOnPlanLikeGardensSheet() {
        // Today's sheet is WindowsHost.compactGardenSheet, which Plan dismisses and routes to the tab.
        #expect(WindowsHost.compactGardenSheet.isSheet)
        #expect(WindowsPlanRoute.route(for: .planned(bedID: "b1"), seedName: "Basil", host: .compactGardenSheet) == .gardenTab)
    }

    @Test func theRowDestinationIsTheSeed() {
        #expect(TodaySeedDestination(seedID: "s1") == TodaySeedDestination(seedID: "s1"))
        #expect(TodaySeedDestination(seedID: "s1") != TodaySeedDestination(seedID: "s2"))
    }

    @Test func theNoHomeLocationLineMatchesTheContract() {
        #expect(TodayWeek.noHomeLocationText == "Set a home location to see planting windows")
    }
}
