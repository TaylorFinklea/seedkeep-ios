import Foundation
import Testing
@testable import Seedkeep

private func day(_ text: String) -> CalendarDay {
    CalendarDay.parse(text)!
}

/// Spans for labels of unknown width: each one takes `spacing` from its leading x.
private func spans(_ leadings: [Double], spacing: Double) -> [ClosedRange<Double>] {
    leadings.map { WindowsTimeline.markerLabelSpan(leading: $0, width: 0, spacing: spacing) }
}

@MainActor
struct WindowsPlanTests {
    // MARK: - Plan routing

    // The three entry points: the workbench's Windows route (the window's root), Garden's sheet over the
    // workbench, and Garden's sheet over the compact tab shell.

    @Test func aPlannedSeedFromTheCompactGardenSheetOpensTheGardenTab() {
        let route = WindowsPlanRoute.route(for: .planned(bedID: "herb"), seedName: "Basil", host: .compactGardenSheet)
        #expect(route == .gardenTab)
    }

    @Test func aPlannedSeedFromTheWorkbenchOpensTheGardenRouteNotTheTab() {
        // The workbench never sets `requestedTab`: a stale value would swallow a later real tab switch.
        for host in [WindowsHost.workbenchRoute, .workbenchGardenSheet] {
            #expect(WindowsPlanRoute.route(for: .planned(bedID: "herb"), seedName: "Basil", host: host) == .gardenRoute)
        }
    }

    @Test func onlyAGardenSheetIsDismissedAfterAPlan() {
        #expect(WindowsHost.workbenchRoute.isSheet == false)
        #expect(WindowsHost.workbenchGardenSheet.isSheet)
        #expect(WindowsHost.compactGardenSheet.isSheet)
    }

    @Test func noGridBedAsksForABedFromEveryEntryPoint() {
        for host in [WindowsHost.workbenchRoute, .workbenchGardenSheet, .compactGardenSheet] {
            #expect(WindowsPlanRoute.route(for: .needsBed, seedName: "Basil", host: host) == .addBed)
        }
    }

    @Test func aSeedThatIsNotActiveNamesWhatToDoFromEveryEntryPoint() {
        let expected = WindowsPlanRoute.message("Move Basil to Active to plan it.")
        for host in [WindowsHost.workbenchRoute, .workbenchGardenSheet, .compactGardenSheet] {
            #expect(WindowsPlanRoute.route(for: .notActive, seedName: "Basil", host: host) == expected)
        }
    }

    @Test func aPlanFromTheSessionRoutesByHost() {
        let session = GardenSession()
        session.reconcile(GardenSession.Snapshot(
            householdID: "h1", isSignedIn: true, bedIDs: ["herb"], gridBedIDs: ["herb"],
            eventIDs: [], activeSeedIDs: ["s1"]
        ))
        let beds = [GardenSession.BedChoice(id: "herb", name: "Herb", sortOrder: 0, hasGrid: true)]
        let result = session.plan(seedID: "s1", isActive: true, beds: beds)
        #expect(result == .planned(bedID: "herb"))
        #expect(session.pendingPlan == GardenSession.PendingPlan(seedID: "s1", bedID: "herb"))
        #expect(WindowsPlanRoute.route(for: result, seedName: "Basil", host: .compactGardenSheet) == .gardenTab)
        #expect(WindowsPlanRoute.route(for: result, seedName: "Basil", host: .workbenchRoute) == .gardenRoute)
        #expect(WindowsPlanRoute.route(for: result, seedName: "Basil", host: .workbenchGardenSheet) == .gardenRoute)
    }

    @Test func aPlanForAnInactiveSeedLeavesTheSessionAlone() {
        let session = GardenSession()
        session.reconcile(GardenSession.Snapshot(
            householdID: "h1", isSignedIn: true, bedIDs: ["herb"], gridBedIDs: ["herb"],
            eventIDs: [], activeSeedIDs: []
        ))
        let beds = [GardenSession.BedChoice(id: "herb", name: "Herb", sortOrder: 0, hasGrid: true)]
        let result = session.plan(seedID: "s9", isActive: false, beds: beds)
        #expect(result == .notActive)
        #expect(session.pendingPlan == nil)
        #expect(session.brushSeedID == nil)
        #expect(WindowsPlanRoute.route(for: result, seedName: "Okra", host: .compactGardenSheet)
            == .message("Move Okra to Active to plan it."))
    }

    // MARK: - Layout

    @Test func theTimelineNeedsTheWorkbenchAndTheListIsEverywhereElse() {
        // Compact iPhone and compact iPad: the list.
        #expect(WindowsLayout.choose(workbenchShell: false, isPad: false, accessibilitySize: false) == .list)
        #expect(WindowsLayout.choose(workbenchShell: false, isPad: true, accessibilitySize: false) == .list)
        // Mac and regular-width iPad: the timeline.
        #expect(WindowsLayout.choose(workbenchShell: true, isPad: false, accessibilitySize: false) == .timeline)
        #expect(WindowsLayout.choose(workbenchShell: true, isPad: true, accessibilitySize: false) == .timeline)
    }

    @Test func iPadAtAccessibilitySizesUsesTheList() {
        #expect(WindowsLayout.choose(workbenchShell: true, isPad: true, accessibilitySize: true) == .list)
        // The rule is for iPad: Mac keeps the timeline.
        #expect(WindowsLayout.choose(workbenchShell: true, isPad: false, accessibilitySize: true) == .timeline)
    }

    // MARK: - Timeline geometry

    @Test func theChartIsAtLeastSevenHundredTwentyPointsWide() {
        #expect(WindowsTimeline.minimumChartWidth == 720)
        #expect(WindowsTimeline.chartWidth(available: 500) == 720)
        #expect(WindowsTimeline.chartWidth(available: 720) == 720)
        #expect(WindowsTimeline.chartWidth(available: 900) == 900)
        #expect(WindowsTimeline.chartWidth(available: -40) == 720)
        #expect(WindowsTimeline.chartWidth(available: .nan) == 720)
        #expect(WindowsTimeline.chartWidth(available: .infinity) == 720)
    }

    @Test func markerLabelsCloseTogetherGoOnDifferentTiers() {
        // Today and last frost sit 20 points apart, so the second goes to the next tier; first frost is far off.
        #expect(WindowsTimeline.labelTiers(spans([100, 120, 400], spacing: 72)) == [0, 1, 0])
        // The result follows the input order, not the order of x.
        #expect(WindowsTimeline.labelTiers(spans([400, 120, 100], spacing: 72)) == [0, 1, 0])
        #expect(WindowsTimeline.labelTiers(spans([], spacing: 72)) == [])
        // Three crowded labels: the last tier takes the overflow.
        #expect(WindowsTimeline.labelTiers(spans([10, 20, 30], spacing: 72)) == [0, 1, 1])
    }

    @Test func aLargerLabelSpacingPushesMoreLabelsToTheOverflowTier() {
        // Dynamic Type scales the spacing. At 72 the third label clears the first tier; at 120 it doesn't.
        #expect(WindowsTimeline.labelTiers(spans([100, 150, 200], spacing: 72)) == [0, 1, 0])
        #expect(WindowsTimeline.labelTiers(spans([100, 150, 200], spacing: 120)) == [0, 1, 1])
        #expect(WindowsTimeline.markerLabelSpacing == 72)
    }

    @Test func aLabelSpanIsItsWidthAndGapOrTheSpacingWhicheverIsWider() {
        #expect(WindowsTimeline.markerLabelSpan(leading: 100, width: 60, spacing: 72) == 100...172)
        #expect(WindowsTimeline.markerLabelSpan(leading: 100, width: 120, spacing: 72) == 100...224)
    }

    @Test func aLabelFlippedLeftOfItsLineSharesNoTierWithTheLabelItOverlaps() {
        // Today's line is at 610 and first frost's at 689, about 79 points apart: the lines alone would share a tier.
        // Frost flips to end at its line, so it occupies 625...685 and overlaps Today's label.
        let today = WindowsTimeline.markerLabelX(lineX: 610, labelWidth: 35, chartWidth: 720)
        let frost = WindowsTimeline.markerLabelX(lineX: 689, labelWidth: 60, chartWidth: 720)
        #expect(frost == 625)
        let tiers = WindowsTimeline.labelTiers([
            WindowsTimeline.markerLabelSpan(leading: today, width: 35, spacing: 72),
            WindowsTimeline.markerLabelSpan(leading: frost, width: 60, spacing: 72),
        ])
        #expect(tiers == [0, 1])
    }

    @Test func markerLabelsSitJustRightOfTheirLineAtTheLeftEdge() {
        #expect(WindowsTimeline.markerLabelX(lineX: 0, labelWidth: 60, chartWidth: 720) == 4)
        #expect(WindowsTimeline.markerLabelX(lineX: 100, labelWidth: 60, chartWidth: 720) == 104)
    }

    @Test func markerLabelsEndJustLeftOfTheirLineAtTheRightEdge() {
        // 700 + 4 + 60 runs past 720, so the label ends at its line instead.
        #expect(WindowsTimeline.markerLabelX(lineX: 700, labelWidth: 60, chartWidth: 720) == 636)
        // A line on the very edge: the label's trailing edge lands on it.
        #expect(WindowsTimeline.markerLabelX(lineX: 720, labelWidth: 60, chartWidth: 720) == 656)
        // The last position that still fits to the right of its line keeps that placement.
        #expect(WindowsTimeline.markerLabelX(lineX: 656, labelWidth: 60, chartWidth: 720) == 660)
    }

    @Test func everyMarkerLabelStaysInsideTheChartAcrossTheWholeWidth() {
        let inside = (0...720).allSatisfy { step in
            let x = WindowsTimeline.markerLabelX(lineX: Double(step), labelWidth: 60, chartWidth: 720)
            return x >= 0 && x + 60 <= 720
        }
        #expect(inside)
        // A label wider than the chart can't fit anywhere: it is clamped to the leading edge.
        #expect(WindowsTimeline.markerLabelX(lineX: 10, labelWidth: 800, chartWidth: 720) == 0)
    }

    @Test func theDomainCoversTheCalendarYearAndEveryWindowAndMarker() {
        let plain = WindowsTimeline.domain(year: 2026, rows: [], markers: [])
        #expect(plain == SeasonTimeline.Domain(start: day("2026-01-01"), end: day("2026-12-31")))

        let today = day("2026-06-01")
        let row = WindowsRowFormat.row(
            seed: WindowSeed(id: "s1", name: "Leek", isArchived: false, isActive: true, verdict: "plant_soon",
                             outdoorStart: "2026-10-20", outdoorEnd: "2027-02-10",
                             indoorStart: nil, indoorEnd: nil),
            reason: nil,
            today: today,
            nextPlanned: nil
        )
        let markers = SeasonTimeline.markers(today: today, lastFrost: "05-04", firstFrost: "10-01")
        let domain = WindowsTimeline.domain(year: 2026, rows: [row], markers: markers)
        // The window runs into 2027, so the domain ends at the end of February 2027.
        #expect(domain.start == day("2026-01-01"))
        #expect(domain.end == day("2027-02-28"))
    }
}
