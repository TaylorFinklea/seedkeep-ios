import Foundation
import Testing
@testable import Seedkeep

private func seed(
    _ id: String,
    _ name: String,
    verdict: String,
    start: String? = nil,
    archived: Bool = false,
    active: Bool = true
) -> WindowSeed {
    WindowSeed(id: id, name: name, isArchived: archived, isActive: active, verdict: verdict,
               outdoorStart: start, outdoorEnd: nil, indoorStart: nil, indoorEnd: nil)
}

struct WindowsGroupingTests {
    @Test func verdictsMapToGroups() {
        #expect(PlantingWindowGroup(verdict: "plant_now") == .plantNow)
        #expect(PlantingWindowGroup(verdict: "plant_soon") == .plantSoon)
        #expect(PlantingWindowGroup(verdict: "late") == .closingSoon)
        #expect(PlantingWindowGroup(verdict: "too_early") == .later)
        #expect(PlantingWindowGroup(verdict: "too_late") == .later)
        #expect(PlantingWindowGroup(verdict: "unknown") == .later)
        #expect(PlantingWindowGroup(verdict: "") == .later)
        #expect(PlantingWindowGroup.allCases.map(\.title) == ["Plant now", "Plant soon", "Closing soon", "Later"])
    }

    @Test func sectionsSkipArchivedAndEmptyGroups() {
        let sections = WindowsGrouping.sections([
            seed("1", "Kale", verdict: "too_late"),
            seed("2", "Beet", verdict: "plant_now", archived: true, active: false),
            seed("3", "Pea", verdict: "plant_now"),
            seed("4", "Bean", verdict: "unknown"),
            seed("5", "Dill", verdict: "late", active: false),
        ])
        #expect(sections.map(\.group) == [.plantNow, .closingSoon, .later])
        #expect(sections.map { $0.seeds.map(\.id) } == [["3"], ["5"], ["4", "1"]])
    }

    @Test func orderIsWindowStartThenNameThenIDWithNoWindowLast() {
        let ordered = WindowsGrouping.ordered([
            seed("a", "Zucchini", verdict: "plant_now"),
            seed("b", "Tomato", verdict: "plant_now", start: "2026-05-10"),
            seed("c", "Basil", verdict: "plant_now", start: "2026-05-10"),
            seed("d", "Basil", verdict: "plant_now", start: "2026-05-10"),
            seed("e", "Pepper", verdict: "plant_now", start: "2026-04-01"),
            seed("f", "Apple", verdict: "plant_now", start: "2026-02-30"),
            seed("g", "Apple", verdict: "plant_now"),
        ])
        // An unreadable start counts as no window.
        #expect(ordered.map(\.id) == ["e", "c", "d", "b", "f", "g", "a"])
    }

    @Test func nextPlannedIsTheFirstIncompleteEvent() {
        func event(_ id: String, seed: String?, on day: String, done: Bool = false, bed: String = "b1") -> GridEvent {
            GridEvent(id: id, bedID: bed, seedID: seed, kind: "sowing", plannedFor: day, isCompleted: done, x: nil, y: nil,
                      isFrostFlagged: false)
        }
        let events = [
            event("1", seed: "s", on: "2026-05-01", done: true),
            event("3", seed: "s", on: "2026-06-01", bed: "b2"),
            event("2", seed: "s", on: "2026-06-01", bed: "b3"),
            event("4", seed: "t", on: "2026-07-01"),
            event("5", seed: nil, on: "2026-01-01"),
        ]
        let next = WindowsGrouping.nextPlanned(seedID: "s", events: events)
        #expect(next?.id == "2")
        #expect(next?.bedID == "b3")
        #expect(next?.plannedFor == "2026-06-01")
        #expect(WindowsGrouping.nextPlanned(seedID: "none", events: events) == nil)
        let bySeed = WindowsGrouping.nextPlannedBySeed(events)
        #expect(bySeed.mapValues(\.id) == ["s": "2", "t": "4"])
    }

    /// A stored event for the scoped next-planned rule: its household, bed and seed, incomplete unless `done`.
    private func stored(
        _ id: String,
        household: String = "h1",
        seed: String? = "s",
        bed: String? = "b1",
        on day: String = "2026-06-01",
        done: Bool = false
    ) -> (householdID: String, event: GridEvent) {
        (householdID: household, event: GridEvent(id: id, bedID: bed, seedID: seed, kind: "sowing", plannedFor: day,
                                                  isCompleted: done, x: nil, y: nil, isFrostFlagged: false))
    }

    @Test func nextPlannedIsScopedToTheHouseholdLiveBedsAndIncompleteEvents() {
        let events = [
            stored("other-house", household: "h2", on: "2026-05-01"),
            stored("deleted-bed", bed: "gone", on: "2026-05-02"),
            stored("no-bed", bed: nil, on: "2026-05-03"),
            stored("done", on: "2026-05-04", done: true),
            stored("no-seed", seed: nil, on: "2026-05-05"),
            stored("kept", on: "2026-06-01"),
            stored("later", on: "2026-07-01"),
        ]
        let next = WindowsGrouping.nextPlannedBySeed(events, householdID: "h1", liveBedIDs: ["b1"])
        #expect(next.mapValues(\.id) == ["s": "kept"])
    }

    @Test func nextPlannedBreaksDateTiesByIDAcrossBeds() {
        let events = [
            stored("c", bed: "b2", on: "2026-06-01"),
            stored("a", bed: "b1", on: "2026-06-01"),
            stored("b", bed: "b1", on: "2026-06-10"),
        ]
        let next = WindowsGrouping.nextPlannedBySeed(events, householdID: "h1", liveBedIDs: ["b1", "b2"])
        #expect(next["s"]?.id == "a")
        #expect(next["s"]?.bedID == "b1")
    }

    @Test func nextPlannedKeepsEachSeedsOwnFirstEvent() {
        let events = [
            stored("s1", seed: "s", on: "2026-06-01"),
            stored("t1", seed: "t", on: "2026-05-01"),
            stored("t2", seed: "t", on: "2026-08-01"),
        ]
        let next = WindowsGrouping.nextPlannedBySeed(events, householdID: "h1", liveBedIDs: ["b1"])
        #expect(next.mapValues(\.id) == ["s": "s1", "t": "t1"])
    }

    @Test func nextPlannedWithNoHouseholdIsEmpty() {
        let events = [stored("1")]
        #expect(WindowsGrouping.nextPlannedBySeed(events, householdID: nil, liveBedIDs: ["b1"]).isEmpty)
    }
}
