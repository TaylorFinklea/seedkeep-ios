import Foundation
import Testing
@testable import Seedkeep

/// Tests for R3 G4's frost on Today and Add Planting: `TodayFrost` (the banner's count, copy and Open Garden
/// route), the Due row's "frost risk" label, and Add Planting's sentence. Dates are `yyyy-MM-dd` strings, as the
/// models store them.
@MainActor
@Suite("Today — frost")
struct TodayFrostTests {
    private static let householdID = "garden"

    /// Fall in the test climate (first frost Oct 1), so every outdoor planting from here on is flagged. The
    /// window's edges therefore decide what counts.
    private static let today = CalendarDay.parse("2026-10-21")!

    private static let frostClimate = HomeClimate(
        zip: "60601", latitude: 41.88, longitude: -87.63, usdaZone: "6a",
        avgLastFrost: "05-04", avgFirstFrost: "10-01"
    )

    private static let english = Locale(identifier: "en_US")

    private static func seed(_ id: String = "seed_basil", tolerance: String? = "tender") -> LocalSeed {
        LocalSeed(
            id: id, householdID: householdID, state: .active, packetCount: 1, source: .store,
            customName: "Basil", growingInfo: GrowingInfoSnapshot(frost_tolerance: tolerance),
            createdAt: 1, updatedAt: 1
        )
    }

    /// A tender seed and a hardy one.
    private static var basilAndKale: [LocalSeed] {
        [seed(), seed("seed_kale", tolerance: "hardy")]
    }

    private static func event(
        _ id: String,
        seedID: String? = "seed_basil",
        household: String = householdID,
        kind: String = "sowing",
        planned: String,
        completedAt: Int64? = nil,
        deletedAt: Int64? = nil
    ) -> LocalPlantingEvent {
        LocalPlantingEvent(
            id: id, householdID: household, seedID: seedID, kindRaw: kind, plannedFor: planned,
            completedAt: completedAt, createdAt: 1, updatedAt: 1, deletedAt: deletedAt
        )
    }

    private static func count(
        _ events: [LocalPlantingEvent],
        seeds: [LocalSeed] = basilAndKale,
        climate: HomeClimate? = frostClimate
    ) -> Int {
        TodayFrost.warningCount(events: events, seeds: seeds, householdID: householdID, climate: climate, today: today)
    }

    // MARK: - Banner count

    @Test func countsFlaggedPlantingsFromTodayThroughThirteenDaysAhead() {
        let events = [
            Self.event("today", planned: "2026-10-21"),
            Self.event("thirteenAhead", planned: "2026-11-03"),
        ]
        #expect(Self.count(events) == 2)
    }

    @Test func leavesOutYesterdayAndFourteenDaysAhead() {
        // Both dates are flagged by the climate, so only the window keeps them out.
        let events = [
            Self.event("yesterday", planned: "2026-10-20"),
            Self.event("fourteenAhead", planned: "2026-11-04"),
        ]
        #expect(Self.count(events) == 0)
    }

    @Test func countsOnlyLiveIncompleteCheckedPlantingsOfTenderSeeds() {
        let events = [
            Self.event("sowing", planned: "2026-10-22"),
            Self.event("transplant", kind: "transplant", planned: "2026-10-22"),
            Self.event("completed", planned: "2026-10-22", completedAt: 1),
            Self.event("deleted", planned: "2026-10-22", deletedAt: 1),
            Self.event("harvest", kind: "harvest", planned: "2026-10-22"),
            Self.event("note", kind: "note", planned: "2026-10-22"),
            Self.event("hardy", seedID: "seed_kale", planned: "2026-10-22"),
            Self.event("seedless", seedID: nil, planned: "2026-10-22"),
        ]
        #expect(Self.count(events) == 2)
    }

    @Test func countsEventsNotSeeds() {
        // Two plantings of one seed are two warnings.
        let events = [
            Self.event("first", planned: "2026-10-22"),
            Self.event("second", planned: "2026-10-30"),
        ]
        #expect(Self.count(events) == 2)
    }

    @Test func otherHouseholdsDontCount() {
        let events = [
            Self.event("mine", planned: "2026-10-22"),
            Self.event("theirs", household: "other", planned: "2026-10-22"),
        ]
        #expect(Self.count(events) == 1)
    }

    @Test func onlyThisHouseholdsLiveSeedsAreConsulted() {
        let events = [Self.event("a", planned: "2026-10-22")]
        let theirs = LocalSeed(
            id: "seed_basil", householdID: "other", state: .active, packetCount: 1, source: .store,
            customName: "Basil", growingInfo: GrowingInfoSnapshot(frost_tolerance: "tender"),
            createdAt: 1, updatedAt: 1
        )
        let deleted = LocalSeed(
            id: "seed_basil", householdID: Self.householdID, state: .active, packetCount: 1, source: .store,
            customName: "Basil", growingInfo: GrowingInfoSnapshot(frost_tolerance: "tender"),
            createdAt: 1, updatedAt: 1, deletedAt: 2
        )
        #expect(Self.count(events, seeds: [theirs]) == 0)
        #expect(Self.count(events, seeds: [deleted]) == 0)
        #expect(Self.count(events, seeds: [Self.seed()]) == 1)
    }

    @Test func theWindowCrossesTheNewYear() {
        let newYearsWeek = CalendarDay.parse("2026-12-25")!
        let events = [
            Self.event("last-day", planned: "2027-01-07"),
            Self.event("too-far", planned: "2027-01-08"),
        ]
        let count = TodayFrost.warningCount(
            events: events, seeds: Self.basilAndKale, householdID: Self.householdID,
            climate: Self.frostClimate, today: newYearsWeek
        )
        #expect(count == 1)
    }

    @Test func unreadableDatesDontCount() {
        #expect(Self.count([Self.event("bad", planned: "2026-10-3")]) == 0)
    }

    @Test func zeroFlaggedPlantingsMeansNoCount() {
        #expect(Self.count([]) == 0)
        #expect(Self.count([Self.event("later", planned: "2026-12-20")]) == 0)
    }

    @Test func missingClimateMeansNoCount() {
        #expect(Self.count([Self.event("a", planned: "2026-10-22")], climate: nil) == 0)
    }

    // MARK: - Copy and routing

    @Test func bannerCopyIsSingularOrPlural() {
        #expect(TodayFrost.warningTitle(count: 1) == "1 planting may meet frost (zone estimate).")
        #expect(TodayFrost.warningTitle(count: 3) == "3 plantings may meet frost (zone estimate).")
        #expect(TodayFrost.openGardenLabel == "Open Garden")
    }

    @Test func openGardenRoutesFromEachHostShell() {
        #expect(TodayFrost.GardenRoute.route(for: .compactTab) == .gardenTab)
        #expect(TodayFrost.GardenRoute.route(for: .workbenchRoute) == .gardenRoute)
    }

    // MARK: - Due row

    @Test func frostRiskRowsSayFrostRiskToVoiceOver() {
        #expect(TodayDue.rowAccessibilityLabel(name: "Basil", kind: "Sow", dayLabel: "Today", frostRisk: true)
                == "Basil, Sow, Today, frost risk")
        #expect(TodayDue.rowAccessibilityLabel(name: "Basil", kind: "Sow", dayLabel: "Today")
                == "Basil, Sow, Today")
    }

    // MARK: - Add Planting

    @Test func addPlantingShowsTheSentenceWhenTheChoiceIsFlagged() {
        let basil = Self.seed()
        #expect(FrostCheck.sentence(plannedFor: "2026-10-21", kind: "sowing", seed: basil,
                                    climate: Self.frostClimate, locale: Self.english)
                == "Frost risk if planted outdoors: on or after the average first frost (Oct 1).")
        #expect(FrostCheck.sentence(plannedFor: "2026-05-03", kind: "transplant", seed: basil,
                                    climate: Self.frostClimate, locale: Self.english)
                == "Frost risk if planted outdoors: before the average last frost (May 4).")
    }

    @Test func addPlantingShowsNothingWhenTheChoiceIsNotFlagged() {
        let basil = Self.seed()
        let kale = Self.seed("seed_kale", tolerance: "hardy")
        let climate = Self.frostClimate
        #expect(FrostCheck.sentence(plannedFor: "2026-07-01", kind: "sowing", seed: basil, climate: climate) == nil)
        #expect(FrostCheck.sentence(plannedFor: "2026-10-21", kind: "sowing", seed: kale, climate: climate) == nil)
        #expect(FrostCheck.sentence(plannedFor: "2026-10-21", kind: "harvest", seed: basil, climate: climate) == nil)
        #expect(FrostCheck.sentence(plannedFor: "2026-10-21", kind: "sowing", seed: nil, climate: climate) == nil)
        #expect(FrostCheck.sentence(plannedFor: "2026-10-21", kind: "sowing", seed: basil, climate: nil) == nil)
        #expect(FrostCheck.sentence(plannedFor: "2026-02-30", kind: "sowing", seed: basil, climate: climate) == nil)
    }
}
