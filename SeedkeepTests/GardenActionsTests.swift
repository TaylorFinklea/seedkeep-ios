import Foundation
import SwiftData
import Testing
@testable import Seedkeep
import SeedkeepKit

/// `GardenActions` over the in-memory store and `SyncEngine`: paint, edit each field (only the changed
/// field is sent), move (both coordinates), a no-op move, delete, complete and uncomplete, several
/// events in one square, and the stale-state re-checks.
@MainActor
@Suite("Garden — actions over SyncEngine", .serialized)
struct GardenActionsTests {
    static let household = "hh_garden"
    static let bedID = "bed_g1"
    static let size = GridSize(columns: 4, rows: 8)
    static let day = CalendarDay.make(year: 2026, month: 5, day: 10)!

    @MainActor
    final class Harness {
        let container: ModelContainer
        let engine: SyncEngine
        var household: String? = GardenActionsTests.household
        var writes = 0

        init() {
            container = makeTestContainer(name: "gardenActionsTests")
            let client = SeedkeepClient(configuration: .init(baseURL: URL(string: "https://test.invalid")!))
            engine = SyncEngine(client: client, container: container)
        }

        @MainActor
        var actions: GardenActions {
            GardenActions(
                sync: engine,
                container: container,
                scope: .init(householdID: GardenActionsTests.household, bedID: GardenActionsTests.bedID),
                currentHouseholdID: { [unowned self] in self.household },
                didWrite: { [unowned self] in self.writes += 1 }
            )
        }

        func insert(_ models: [any PersistentModel]) throws {
            let context = ModelContext(container)
            for model in models { context.insert(model) }
            try context.save()
        }

        func event(_ id: String) throws -> LocalPlantingEvent? {
            try ModelContext(container).fetch(
                FetchDescriptor<LocalPlantingEvent>(predicate: #Predicate { $0.id == id })
            ).first
        }

        func liveEvents() throws -> [LocalPlantingEvent] {
            try ModelContext(container).fetch(
                FetchDescriptor<LocalPlantingEvent>(predicate: #Predicate { $0.deletedAt == nil })
            )
        }

        /// Pending writes in order, payloads decoded.
        func pending() throws -> [(op: String, id: String, payload: [String: Any])] {
            let rows = try ModelContext(container).fetch(FetchDescriptor<LocalPendingWrite>(
                sortBy: [SortDescriptor(\.createdAt, order: .forward)]
            ))
            return rows.map { row in
                let object = (try? JSONSerialization.jsonObject(with: Data(row.payloadJSON.utf8))) as? [String: Any]
                return (row.operation, row.entityID, object ?? [:])
            }
        }
    }

    static func bed(width: Double? = 4, length: Double? = 8) -> LocalBed {
        LocalBed(id: bedID, householdID: household, name: "North", widthFeet: width, lengthFeet: length,
                 createdAt: 1, updatedAt: 1)
    }

    static func seed(_ id: String = "seed_g1", state: SeedState = .active) -> LocalSeed {
        LocalSeed(id: id, householdID: household, state: state, packetCount: 1, source: .store,
                  customName: "Basil", createdAt: 1, updatedAt: 1)
    }

    static func event(
        _ id: String, x: Double? = 0.5, y: Double? = 0.5, done: Int64? = nil, kind: String = "sowing",
        planned: String = "2026-05-01", notes: String? = nil, bed: String = bedID
    ) -> LocalPlantingEvent {
        LocalPlantingEvent(id: id, householdID: household, bedID: bed, seedID: "seed_g1", kindRaw: kind,
                           plannedFor: planned, completedAt: done, notes: notes, xFeet: x, yFeet: y,
                           createdAt: 1, updatedAt: 1)
    }

    static func context(_ harness: Harness) throws -> GardenInteraction.Context {
        let events = try harness.liveEvents().map { GridEvent($0, isFrostFlagged: false) }
        return GardenInteraction.Context(size: size, events: events, bedID: bedID, planDate: day)
    }

    static func sq(_ column: Int, _ row: Int) -> GridSquare { GridSquare(column: column, rowFromTop: row) }

    // MARK: - Paint

    @Test func paintingCreatesOneSowingAtTheSquareCentre() throws {
        let h = Harness()
        try h.insert([Self.bed(), Self.seed()])
        let state = GardenInteraction.State(mode: .painting, brushSeedID: "seed_g1")
        let effects = GardenInteraction.reduce(state, .activate(Self.sq(2, 1)), context: try Self.context(h)).effects
        let outcome = try h.actions.perform(try #require(effects.first), size: Self.size)
        #expect(outcome == .written)
        #expect(h.writes == 1)
        let created = try #require(try h.liveEvents().first)
        #expect(created.bedID == Self.bedID)
        #expect(created.seedID == "seed_g1")
        #expect(created.kindRaw == "sowing")
        #expect(created.plannedFor == "2026-05-10")
        #expect(created.xFeet == 2.5)
        #expect(created.yFeet == 6.5)
        #expect(created.completedAt == nil)
        let write = try #require(try h.pending().first)
        #expect(write.op == "create")
        #expect(write.payload["x_feet"] as? Double == 2.5)
        #expect(write.payload["y_feet"] as? Double == 6.5)
    }

    @Test func paintingASquareThatFilledMeanwhileIsRefused() throws {
        let h = Harness()
        try h.insert([Self.bed(), Self.seed()])
        let state = GardenInteraction.State(mode: .painting, brushSeedID: "seed_g1")
        let effects = GardenInteraction.reduce(state, .activate(Self.sq(0, 7)), context: try Self.context(h)).effects
        // Another write lands in the square before this one is performed.
        try h.insert([Self.event("other", x: 0.4, y: 0.6)])
        let outcome = try h.actions.perform(try #require(effects.first), size: Self.size)
        #expect(outcome == .refused("Row 8, square 1 already has a planting."))
        #expect(try h.pending().isEmpty)
        #expect(h.writes == 0)
    }

    @Test func paintingOverCompletedHistoryKeepsIt() throws {
        let h = Harness()
        try h.insert([Self.bed(), Self.seed(), Self.event("old", done: 1_000)])
        let state = GardenInteraction.State(mode: .painting, brushSeedID: "seed_g1")
        let effects = GardenInteraction.reduce(state, .activate(Self.sq(0, 7)), context: try Self.context(h)).effects
        #expect(try h.actions.perform(try #require(effects.first), size: Self.size) == .written)
        let inSquare = GardenGrid.contents(of: Self.sq(0, 7), events: try h.liveEvents().map { GridEvent($0, isFrostFlagged: false) },
                                           bedID: Self.bedID, size: Self.size)
        #expect(inSquare.events.count == 2)
        #expect(inSquare.shownEvent?.id != "old")
        #expect(inSquare.blocksPainting)
    }

    // MARK: - Edits

    @Test func eachEditSendsOnlyItsField() throws {
        let h = Harness()
        try h.insert([Self.bed(), Self.event("e1", notes: "old")])
        let actions = h.actions
        #expect(try actions.setKind(.transplant, eventID: "e1") == .written)
        #expect(try actions.setPlannedFor(CalendarDay.make(year: 2026, month: 6, day: 2)!, eventID: "e1") == .written)
        #expect(try actions.setNotes("  thinned  ", eventID: "e1") == .written)
        // Coalesced into one pending update; each call added only its key.
        let payloads = try h.pending()
        #expect(payloads.count == 1)
        let keys = Set(try #require(payloads.first).payload.keys)
        #expect(keys == ["kind", "planned_for", "notes"])
        let stored = try #require(try h.event("e1"))
        #expect(stored.kindRaw == "transplant")
        #expect(stored.plannedFor == "2026-06-02")
        #expect(stored.notes == "thinned")
        #expect(stored.xFeet == 0.5 && stored.yFeet == 0.5)
        #expect(h.writes == 3)
    }

    @Test func aSingleEditCarriesNoOtherKeys() throws {
        let h = Harness()
        try h.insert([Self.bed(), Self.event("e1")])
        try h.actions.setPlannedFor(CalendarDay.make(year: 2026, month: 7, day: 1)!, eventID: "e1")
        #expect(Set(try #require(try h.pending().first).payload.keys) == ["planned_for"])
    }

    @Test func unchangedEditsWriteNothing() throws {
        let h = Harness()
        try h.insert([Self.bed(), Self.event("e1", notes: "keep")])
        let actions = h.actions
        #expect(try actions.setKind(.sowing, eventID: "e1") == .unchanged)
        #expect(try actions.setPlannedFor(CalendarDay.make(year: 2026, month: 5, day: 1)!, eventID: "e1") == .unchanged)
        #expect(try actions.setNotes(" keep\n", eventID: "e1") == .unchanged)
        #expect(try actions.setDone(false, eventID: "e1") == .unchanged)
        #expect(try h.pending().isEmpty)
        #expect(h.writes == 0)
    }

    @Test func clearingNotesSendsAnEmptyString() throws {
        let h = Harness()
        try h.insert([Self.bed(), Self.event("e1", notes: "thin to 4")])
        #expect(try h.actions.setNotes("  \n", eventID: "e1") == .written)
        let payload = try #require(try h.pending().first).payload
        #expect(Set(payload.keys) == ["notes"])
        #expect(payload["notes"] as? String == "")
    }

    @Test func completeThenUncompleteSendsSomeNil() throws {
        let h = Harness()
        try h.insert([Self.bed(), Self.event("e1")])
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        #expect(try h.actions.setDone(true, eventID: "e1", now: now) == .written)
        #expect(try h.event("e1")?.completedAt == 1_780_000_000_000)
        #expect(try h.pending().first?.payload["completed_at"] as? Int64 == 1_780_000_000_000)
        #expect(try h.actions.setDone(false, eventID: "e1") == .written)
        #expect(try h.event("e1")?.completedAt == nil)
        let payload = try #require(try h.pending().first).payload
        #expect(payload["completed_at"] is NSNull, "not done must be JSON null, not omitted or 0")
        #expect(Set(payload.keys) == ["completed_at"])
    }

    // MARK: - Move

    @Test func aMoveSendsBothCoordinates() throws {
        let h = Harness()
        try h.insert([Self.bed(), Self.event("e1", x: 0.5, y: 0.5)])
        let state = GardenInteraction.State(mode: .moving(eventID: "e1"), selectedEventID: "e1")
        let effects = GardenInteraction.reduce(state, .activate(Self.sq(3, 0)), context: try Self.context(h)).effects
        #expect(try h.actions.perform(try #require(effects.first), size: Self.size) == .written)
        let payload = try #require(try h.pending().first).payload
        #expect(Set(payload.keys) == ["x_feet", "y_feet"])
        #expect(payload["x_feet"] as? Double == 3.5)
        #expect(payload["y_feet"] as? Double == 7.5)
    }

    @Test func aOneAxisMoveSendsBothWithTheUntouchedValueUnchanged() throws {
        let h = Harness()
        try h.insert([Self.bed(), Self.event("e1", x: 0.3, y: 1.2)])
        let effects = GardenInteraction.reduce(GardenInteraction.State(selectedEventID: "e1"), .moveSelected(.right),
                                               context: try Self.context(h)).effects
        #expect(try h.actions.perform(try #require(effects.first), size: Self.size) == .written)
        let payload = try #require(try h.pending().first).payload
        #expect(payload["x_feet"] as? Double == 1.5)
        #expect(payload["y_feet"] as? Double == 1.2)
    }

    @Test func aNoOpMoveWritesNothing() throws {
        let h = Harness()
        try h.insert([Self.bed(), Self.event("e1", x: 0.5, y: 0.5)])
        let effect = GardenInteraction.Effect.move(eventID: "e1", from: .init(x: 0.5, y: 0.5), to: .init(x: 0.5, y: 0.5),
                                                   square: Self.sq(0, 7))
        #expect(try h.actions.perform(effect, size: Self.size) == .unchanged)
        // The reducer's own-square tap produces no effect at all.
        let state = GardenInteraction.State(mode: .moving(eventID: "e1"), selectedEventID: "e1")
        #expect(GardenInteraction.reduce(state, .activate(Self.sq(0, 7)), context: try Self.context(h)).effects.isEmpty)
        #expect(try h.pending().isEmpty)
        #expect(h.writes == 0)
    }

    @Test func aMoveOfAnEventThatMovedMeanwhileIsRefused() throws {
        let h = Harness()
        try h.insert([Self.bed(), Self.event("e1", x: 0.5, y: 0.5)])
        let state = GardenInteraction.State(mode: .moving(eventID: "e1"), selectedEventID: "e1")
        let effects = GardenInteraction.reduce(state, .activate(Self.sq(3, 0)), context: try Self.context(h)).effects
        let stored = try #require(try ModelContext(h.container).fetch(FetchDescriptor<LocalPlantingEvent>()).first)
        stored.xFeet = 2.5
        try stored.modelContext?.save()
        #expect(try h.actions.perform(try #require(effects.first), size: Self.size) == .refused(GardenActions.eventMovedMessage))
        #expect(try h.pending().isEmpty)
    }

    @Test func placingAnUnplacedEventSendsBothCoordinates() throws {
        let h = Harness()
        try h.insert([Self.bed(), Self.event("u", x: nil, y: nil)])
        let state = GardenInteraction.reduce(GardenInteraction.State(), .startMove(eventID: "u"),
                                             context: try Self.context(h)).state
        let effects = GardenInteraction.reduce(state, .activate(Self.sq(1, 1)), context: try Self.context(h)).effects
        #expect(try h.actions.perform(try #require(effects.first), size: Self.size) == .written)
        let stored = try #require(try h.event("u"))
        #expect(stored.xFeet == 1.5 && stored.yFeet == 6.5)
    }

    // MARK: - Delete

    @Test func deleteTombstonesOnlyThatEvent() throws {
        let h = Harness()
        try h.insert([Self.bed(), Self.event("a", done: 1_000), Self.event("b"), Self.event("c", x: 1.5)])
        #expect(try h.actions.delete(eventID: "b") == .written)
        #expect(try h.event("b")?.deletedAt != nil)
        #expect(Set(try h.liveEvents().map(\.id)) == ["a", "c"])
        let write = try #require(try h.pending().first)
        #expect(write.op == "delete" && write.id == "b")
        // The square keeps its completed history.
        let inSquare = GardenGrid.contents(of: Self.sq(0, 7), events: try h.liveEvents().map { GridEvent($0, isFrostFlagged: false) },
                                           bedID: Self.bedID, size: Self.size)
        #expect(inSquare.events.map(\.id) == ["a"])
        #expect(!inSquare.blocksPainting)
    }

    // MARK: - Several events in one square

    @Test func severalEventsInOneSquareWithCompletedHistory() throws {
        let h = Harness()
        try h.insert([
            Self.bed(),
            Self.event("old1", done: 1, planned: "2025-04-01"),
            Self.event("old2", done: 2, planned: "2025-09-01"),
            Self.event("now", planned: "2026-05-01", notes: "Second sowing"),
        ])
        let context = try Self.context(h)
        let contents = context.contents(Self.sq(0, 7))
        #expect(contents.events.map(\.id) == ["old1", "old2", "now"])
        #expect(contents.shownEvent?.id == "now")
        // Idle tap opens the shown event; uncompleting history leaves the others alone.
        let tapped = GardenInteraction.reduce(.init(), .activate(Self.sq(0, 7)), context: context)
        #expect(tapped.state.selectedEventID == "now" && tapped.state.detailsPresented)
        #expect(try h.actions.setDone(false, eventID: "old1") == .written)
        #expect(try h.event("old2")?.completedAt == 2)
        #expect(try h.event("now")?.notes == "Second sowing")
        #expect(try h.pending().map(\.id) == ["old1"])
    }

    // MARK: - Stale-state re-checks

    @Test func aHouseholdChangeRefusesEveryWrite() throws {
        let h = Harness()
        try h.insert([Self.bed(), Self.seed(), Self.event("e1")])
        h.household = "hh_other"
        let actions = h.actions
        #expect(try actions.setNotes("x", eventID: "e1") == .refused(GardenActions.scopeChangedMessage))
        #expect(try actions.delete(eventID: "e1") == .refused(GardenActions.scopeChangedMessage))
        let paint = GardenInteraction.Effect.createSowing(seedID: "seed_g1", square: Self.sq(1, 1),
                                                          position: .init(x: 1.5, y: 6.5), plannedFor: Self.day)
        #expect(try actions.perform(paint, size: Self.size) == .refused(GardenActions.scopeChangedMessage))
        #expect(try h.pending().isEmpty)
    }

    @Test func aDeletedOrResizedBedRefusesGridWrites() throws {
        let h = Harness()
        try h.insert([Self.bed(width: 3), Self.seed()])
        let paint = GardenInteraction.Effect.createSowing(seedID: "seed_g1", square: Self.sq(1, 1),
                                                          position: .init(x: 1.5, y: 6.5), plannedFor: Self.day)
        #expect(try h.actions.perform(paint, size: Self.size) == .refused(GardenActions.bedGoneMessage))
        #expect(try h.pending().isEmpty)
    }

    @Test func aDeletedBedRefusesEditsAndDeletes() throws {
        let h = Harness()
        try h.insert([Self.bed(), Self.event("e1", notes: "keep")])
        let bed = try #require(try ModelContext(h.container).fetch(FetchDescriptor<LocalBed>()).first)
        bed.deletedAt = 5
        try bed.modelContext?.save()
        let actions = h.actions
        #expect(try actions.setKind(.harvest, eventID: "e1") == .refused(GardenActions.bedGoneMessage))
        #expect(try actions.setPlannedFor(CalendarDay.make(year: 2026, month: 6, day: 1)!, eventID: "e1")
                == .refused(GardenActions.bedGoneMessage))
        #expect(try actions.setDone(true, eventID: "e1") == .refused(GardenActions.bedGoneMessage))
        #expect(try actions.setNotes("new", eventID: "e1") == .refused(GardenActions.bedGoneMessage))
        #expect(try actions.delete(eventID: "e1") == .refused(GardenActions.bedGoneMessage))
        #expect(try h.pending().isEmpty)
        #expect(h.writes == 0)
        let stored = try #require(try h.event("e1"))
        #expect(stored.deletedAt == nil && stored.notes == "keep" && stored.completedAt == nil)
    }

    @Test func aResizedBedStillAllowsEditsAndDeletes() throws {
        // Edits don't depend on the grid: only a live bed in the scope is required.
        let h = Harness()
        try h.insert([Self.bed(width: 2, length: 2), Self.event("e1"), Self.event("e2")])
        #expect(try h.actions.setDone(true, eventID: "e1") == .written)
        #expect(try h.actions.delete(eventID: "e2") == .written)
    }

    @Test func aRemotelyDeletedEventRefusesEdits() throws {
        let h = Harness()
        try h.insert([Self.bed(), Self.event("e1")])
        let stored = try #require(try ModelContext(h.container).fetch(FetchDescriptor<LocalPlantingEvent>()).first)
        stored.deletedAt = 5
        try stored.modelContext?.save()
        #expect(try h.actions.setDone(true, eventID: "e1") == .refused(GardenActions.eventGoneMessage))
        #expect(try h.actions.delete(eventID: "e1") == .refused(GardenActions.eventGoneMessage))
        #expect(try h.pending().isEmpty)
    }

    @Test func anEventInAnotherBedIsRefused() throws {
        let h = Harness()
        try h.insert([Self.bed(), Self.event("e1", bed: "bed_other")])
        #expect(try h.actions.setKind(.harvest, eventID: "e1") == .refused(GardenActions.eventGoneMessage))
    }

    @Test func anInactiveBrushSeedIsRefused() throws {
        let h = Harness()
        try h.insert([Self.bed(), Self.seed(state: .archived)])
        let paint = GardenInteraction.Effect.createSowing(seedID: "seed_g1", square: Self.sq(1, 1),
                                                          position: .init(x: 1.5, y: 6.5), plannedFor: Self.day)
        #expect(try h.actions.perform(paint, size: Self.size) == .refused(GardenActions.seedUnavailableMessage))
    }

    @Test func aRefuseEffectWritesNothing() throws {
        let h = Harness()
        #expect(try h.actions.perform(.refuse("No"), size: Self.size) == .refused("No"))
        #expect(try h.pending().isEmpty)
    }
}
