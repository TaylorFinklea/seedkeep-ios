import Foundation
import Testing
@testable import Seedkeep

/// `GardenInteraction`: painting, idle and moving taps, opening and closing details, the cancel order,
/// and the accessibility Move actions (the R2c canvas guarantees: bounds, no-op, y up, untouched axis).
@Suite("Garden — interaction rules")
struct GardenInteractionTests {
    typealias S = GardenInteraction.State
    typealias P = GardenInteraction.Point

    static let bed = "bed1"
    static let size = GridSize(columns: 3, rows: 4)
    static let today = CalendarDay.make(year: 2026, month: 5, day: 1)!
    static let planDay = CalendarDay.make(year: 2026, month: 5, day: 10)!

    static func event(
        _ id: String, x: Double?, y: Double?, done: Bool = false, planned: String = "2026-05-01",
        seed: String? = "s1", bed: String = bed
    ) -> GridEvent {
        GridEvent(id: id, bedID: bed, seedID: seed, kind: "sowing", plannedFor: planned,
                  isCompleted: done, x: x, y: y, isFrostFlagged: false)
    }

    static func context(_ events: [GridEvent]) -> GardenInteraction.Context {
        GardenInteraction.Context(size: size, events: events, bedID: bed, planDate: planDay)
    }

    static func sq(_ column: Int, _ row: Int) -> GridSquare { GridSquare(column: column, rowFromTop: row) }

    // Square (0, rowFromTop 3) is the bottom-left; its centre is (0.5, 0.5).
    static let planted = event("e1", x: 0.5, y: 0.5)
    static let finished = event("e2", x: 1.5, y: 0.5, done: true)

    // MARK: - Painting

    @Test func paintingAnEmptySquareCreatesASowingAtItsCentreOnThePlanDate() {
        let state = S(mode: .painting, brushSeedID: "s9")
        let result = GardenInteraction.reduce(state, .activate(Self.sq(2, 0)), context: Self.context([Self.planted]))
        #expect(result.effects == [.createSowing(seedID: "s9", square: Self.sq(2, 0), position: P(x: 2.5, y: 3.5),
                                                 plannedFor: Self.planDay)])
        #expect(result.state.mode == .painting)
        #expect(result.state.brushSeedID == "s9")
        #expect(!result.state.detailsPresented)
    }

    @Test func paintingASquareOfOnlyCompletedEventsCreatesAnother() {
        let state = S(mode: .painting, brushSeedID: "s9")
        let result = GardenInteraction.reduce(state, .activate(Self.sq(1, 3)), context: Self.context([Self.finished]))
        #expect(result.effects.count == 1)
        if case .createSowing(_, let square, let position, _) = result.effects.first {
            #expect(square == Self.sq(1, 3))
            #expect(position == P(x: 1.5, y: 0.5))
        } else {
            Issue.record("expected a sowing")
        }
    }

    @Test func paintingABlockingSquareSelectsItsShownEventAndStaysPainting() {
        let state = S(mode: .painting, brushSeedID: "s9", selectedEventID: nil, detailsPresented: false)
        let result = GardenInteraction.reduce(state, .activate(Self.sq(0, 3)), context: Self.context([Self.planted]))
        #expect(result.effects.isEmpty)
        #expect(result.state == S(mode: .painting, brushSeedID: "s9", selectedEventID: "e1", detailsPresented: false))
    }

    // MARK: - Idle

    @Test func idleTapOnASquareWithEventsSelectsTheShownEventAndOpensDetails() {
        let result = GardenInteraction.reduce(S(), .activate(Self.sq(1, 3)), context: Self.context([Self.finished]))
        #expect(result.effects.isEmpty)
        #expect(result.state.selectedEventID == "e2")
        #expect(result.state.detailsPresented)
    }

    @Test func idleTapOnTheShownEventPrefersTheFirstIncomplete() {
        let old = Self.event("a", x: 0.5, y: 0.5, done: true, planned: "2026-04-01")
        let later = Self.event("b", x: 0.6, y: 0.4, planned: "2026-06-01")
        let result = GardenInteraction.reduce(S(), .activate(Self.sq(0, 3)), context: Self.context([old, later]))
        #expect(result.state.selectedEventID == "b")
    }

    @Test func idleTapOnAnEmptySquareClearsTheSelectionAndClosesDetails() {
        let state = S(selectedEventID: "e1", detailsPresented: true)
        let result = GardenInteraction.reduce(state, .activate(Self.sq(2, 2)), context: Self.context([Self.planted]))
        #expect(result.state == S())
        #expect(result.effects.isEmpty)
    }

    @Test func aSquareOutsideTheGridIsRefused() {
        let result = GardenInteraction.reduce(S(), .activate(Self.sq(3, 0)), context: Self.context([]))
        #expect(result.effects == [.refuse(GardenInteraction.outsideMessage)])
        #expect(result.state == S())
    }

    // MARK: - Moving

    @Test func movingToAFreeSquareSendsBothCoordinatesAndReturnsToIdle() {
        let state = S(mode: .moving(eventID: "e1"), selectedEventID: "e1")
        let result = GardenInteraction.reduce(state, .activate(Self.sq(2, 0)), context: Self.context([Self.planted]))
        #expect(result.effects == [.move(eventID: "e1", from: P(x: 0.5, y: 0.5), to: P(x: 2.5, y: 3.5),
                                         square: Self.sq(2, 0))])
        #expect(result.state == S(mode: .idle, selectedEventID: "e1", detailsPresented: false))
    }

    @Test func movingOntoABlockingSquareRefusesWithAMessageAndKeepsMoving() {
        let other = Self.event("e3", x: 2.5, y: 3.5)
        let state = S(mode: .moving(eventID: "e1"), selectedEventID: "e1")
        let result = GardenInteraction.reduce(state, .activate(Self.sq(2, 0)),
                                              context: Self.context([Self.planted, other]))
        #expect(result.effects == [.refuse("Row 1, square 3 already has a planting.")])
        #expect(result.state == state)
    }

    @Test func movingOntoASquareOfCompletedHistoryIsAllowed() {
        let state = S(mode: .moving(eventID: "e1"), selectedEventID: "e1")
        let result = GardenInteraction.reduce(state, .activate(Self.sq(1, 3)),
                                              context: Self.context([Self.planted, Self.finished]))
        #expect(result.effects == [.move(eventID: "e1", from: P(x: 0.5, y: 0.5), to: P(x: 1.5, y: 0.5),
                                         square: Self.sq(1, 3))])
    }

    @Test func movingOntoItsOwnSquareWritesNothing() {
        let state = S(mode: .moving(eventID: "e1"), selectedEventID: "e1")
        let result = GardenInteraction.reduce(state, .activate(Self.sq(0, 3)), context: Self.context([Self.planted]))
        #expect(result.effects.isEmpty)
        #expect(result.state.mode == .idle)
    }

    @Test func placingAnUnplacedEventHasNoPreviousPosition() {
        let unplaced = Self.event("u", x: nil, y: nil)
        let state = S(mode: .moving(eventID: "u"), selectedEventID: "u")
        let result = GardenInteraction.reduce(state, .activate(Self.sq(1, 1)), context: Self.context([unplaced]))
        #expect(result.effects == [.move(eventID: "u", from: nil, to: P(x: 1.5, y: 2.5), square: Self.sq(1, 1))])
    }

    @Test func movingAnEventThatIsGoneEndsTheMove() {
        let state = S(mode: .moving(eventID: "gone"), selectedEventID: "gone")
        let result = GardenInteraction.reduce(state, .activate(Self.sq(1, 1)), context: Self.context([]))
        #expect(result.effects.isEmpty)
        #expect(result.state.mode == .idle)
        #expect(result.state.selectedEventID == nil)
        #expect(!result.state.detailsPresented)
    }

    @Test func startMoveClearsTheBrushAndClosesDetails() {
        let state = S(mode: .painting, brushSeedID: "s9", selectedEventID: "e1", detailsPresented: true)
        let result = GardenInteraction.reduce(state, .startMove(eventID: "e1"), context: Self.context([Self.planted]))
        #expect(result.state == S(mode: .moving(eventID: "e1"), brushSeedID: nil, selectedEventID: "e1",
                                  detailsPresented: false))
    }

    // MARK: - Details

    @Test func selectingAnEventRowSelectsItAndOpensDetails() {
        let state = S(mode: .painting, brushSeedID: "s9")
        let result = GardenInteraction.reduce(state, .selectEventRow(eventID: "e1"), context: Self.context([]))
        #expect(result.state == S(mode: .painting, brushSeedID: "s9", selectedEventID: "e1", detailsPresented: true))
    }

    @Test func selectingAnotherEventRowWhileMovingEndsTheMove() {
        let state = S(mode: .moving(eventID: "a"), selectedEventID: "a")
        let result = GardenInteraction.reduce(state, .selectEventRow(eventID: "b"), context: Self.context([]))
        #expect(result.state == S(mode: .idle, selectedEventID: "b", detailsPresented: true))
        #expect(result.effects.isEmpty)
    }

    @Test func selectingTheMovingEventsRowKeepsTheMove() {
        let state = S(mode: .moving(eventID: "a"), selectedEventID: "a")
        let result = GardenInteraction.reduce(state, .selectEventRow(eventID: "a"), context: Self.context([]))
        #expect(result.state == state)
    }

    @Test @MainActor func sessionRowSelectionGoesThroughTheRules() {
        let session = GardenSession()
        session.startMove(eventID: "a")
        session.selectEventRow(eventID: "a")
        #expect(session.mode == .moving(eventID: "a"))
        session.selectEventRow(eventID: "b")
        #expect(session.mode == .idle)
        #expect(session.selectedEventID == "b")
        #expect(session.detailsPresented)
        // Painting keeps its brush.
        session.startPainting(seedID: "s9")
        session.selectEventRow(eventID: "c")
        #expect(session.mode == .painting && session.brushSeedID == "s9" && session.selectedEventID == "c")
    }

    @Test func theDetailsButtonOpensTheSelectedEventOnly() {
        let none = GardenInteraction.reduce(S(mode: .painting, brushSeedID: "s9"), .showDetails, context: Self.context([]))
        #expect(!none.state.detailsPresented)
        let some = GardenInteraction.reduce(S(mode: .painting, brushSeedID: "s9", selectedEventID: "e1"),
                                            .showDetails, context: Self.context([]))
        #expect(some.state.detailsPresented)
        #expect(some.state.mode == .painting)
    }

    @Test func closingDetailsKeepsTheSelection() {
        let result = GardenInteraction.reduce(S(selectedEventID: "e1", detailsPresented: true), .closeDetails,
                                              context: Self.context([]))
        #expect(result.state == S(selectedEventID: "e1", detailsPresented: false))
    }

    // MARK: - Cancel order

    @Test func cancelClosesDetailsThenMoveThenBrushThenSelection() {
        let context = Self.context([])
        var state = S(mode: .moving(eventID: "e1"), selectedEventID: "e1", detailsPresented: true)
        state = GardenInteraction.reduce(state, .cancel, context: context).state
        #expect(state == S(mode: .moving(eventID: "e1"), selectedEventID: "e1", detailsPresented: false))
        state = GardenInteraction.reduce(state, .cancel, context: context).state
        #expect(state == S(mode: .idle, selectedEventID: "e1"))
        state = GardenInteraction.reduce(state, .cancel, context: context).state
        #expect(state == S())

        var painting = S(mode: .painting, brushSeedID: "s9", selectedEventID: "e1", detailsPresented: true)
        painting = GardenInteraction.reduce(painting, .cancel, context: context).state
        #expect(painting == S(mode: .painting, brushSeedID: "s9", selectedEventID: "e1"))
        painting = GardenInteraction.reduce(painting, .cancel, context: context).state
        #expect(painting == S(mode: .idle, brushSeedID: nil, selectedEventID: "e1"))
        painting = GardenInteraction.reduce(painting, .cancel, context: context).state
        #expect(painting == S())
        #expect(GardenInteraction.reduce(painting, .cancel, context: context).state == S())
    }

    @Test @MainActor func sessionApplyMatchesTheReducerThroughTheCancelOrder() {
        let session = GardenSession()
        session.reconcile(.init(householdID: "h", isSignedIn: true, bedIDs: [Self.bed], gridBedIDs: [Self.bed],
                                eventIDs: ["e1"], activeSeedIDs: ["s9"]))
        let context = Self.context([Self.planted])
        _ = session.handle(.startMove(eventID: "e1"), context: context)
        #expect(session.mode == .moving(eventID: "e1"))
        session.startPainting(seedID: "s9")
        _ = session.handle(.activate(Self.sq(0, 3)), context: context)
        #expect(session.selectedEventID == "e1")
        #expect(session.mode == .painting)
        _ = session.handle(.showDetails, context: context)
        #expect(session.detailsPresented)
        _ = session.handle(.cancel, context: context)
        #expect(!session.detailsPresented && session.brushSeedID == "s9")
        _ = session.handle(.cancel, context: context)
        #expect(session.brushSeedID == nil && session.mode == .idle && session.selectedEventID == "e1")
        _ = session.handle(.cancel, context: context)
        #expect(session.selectedEventID == nil)
    }

    // MARK: - Accessibility moves (R2c canvas guarantees on the grid)

    @Test func moveActionsMoveOneSquareWithYUp() {
        let event = Self.event("e1", x: 1.5, y: 1.5) // column 1, rowFromTop 2
        let state = S(selectedEventID: "e1")
        let context = Self.context([event])
        let up = GardenInteraction.reduce(state, .moveSelected(.up), context: context).effects
        #expect(up == [.move(eventID: "e1", from: P(x: 1.5, y: 1.5), to: P(x: 1.5, y: 2.5), square: Self.sq(1, 1))])
        let down = GardenInteraction.reduce(state, .moveSelected(.down), context: context).effects
        #expect(down == [.move(eventID: "e1", from: P(x: 1.5, y: 1.5), to: P(x: 1.5, y: 0.5), square: Self.sq(1, 3))])
        let left = GardenInteraction.reduce(state, .moveSelected(.left), context: context).effects
        #expect(left == [.move(eventID: "e1", from: P(x: 1.5, y: 1.5), to: P(x: 0.5, y: 1.5), square: Self.sq(0, 2))])
        let right = GardenInteraction.reduce(state, .moveSelected(.right), context: context).effects
        #expect(right == [.move(eventID: "e1", from: P(x: 1.5, y: 1.5), to: P(x: 2.5, y: 1.5), square: Self.sq(2, 2))])
    }

    @Test func aOneAxisMoveKeepsTheUntouchedAxisValue() {
        // An off-centre legacy position: moving right changes x only; y keeps 1.2.
        let event = Self.event("e1", x: 0.3, y: 1.2)
        let effects = GardenInteraction.reduce(S(selectedEventID: "e1"), .moveSelected(.right),
                                               context: Self.context([event])).effects
        #expect(effects == [.move(eventID: "e1", from: P(x: 0.3, y: 1.2), to: P(x: 1.5, y: 1.2), square: Self.sq(1, 2))])
        let upEffects = GardenInteraction.reduce(S(selectedEventID: "e1"), .moveSelected(.up),
                                                 context: Self.context([event])).effects
        #expect(upEffects == [.move(eventID: "e1", from: P(x: 0.3, y: 1.2), to: P(x: 0.3, y: 2.5), square: Self.sq(0, 1))])
    }

    @Test func moveActionsRefuseOutsideTheBed() {
        let corner = Self.event("e1", x: 0.5, y: 0.5) // bottom-left
        let context = Self.context([corner])
        for direction in [GardenInteraction.Direction.left, .down] {
            let result = GardenInteraction.reduce(S(selectedEventID: "e1"), .moveSelected(direction), context: context)
            #expect(result.effects == [.refuse(GardenInteraction.outsideMessage)])
        }
        let farEdge = Self.event("e1", x: 3.0, y: 4.0) // exactly on the far edges: top-right square
        let farContext = Self.context([farEdge])
        for direction in [GardenInteraction.Direction.right, .up] {
            let result = GardenInteraction.reduce(S(selectedEventID: "e1"), .moveSelected(direction), context: farContext)
            #expect(result.effects == [.refuse(GardenInteraction.outsideMessage)])
        }
    }

    @Test func moveActionsRefuseAnOccupiedSquare() {
        let a = Self.event("a", x: 0.5, y: 0.5)
        let b = Self.event("b", x: 1.5, y: 0.5)
        let result = GardenInteraction.reduce(S(selectedEventID: "a"), .moveSelected(.right), context: Self.context([a, b]))
        #expect(result.effects == [.refuse("Row 4, square 2 already has a planting.")])
    }

    @Test func moveActionsDoNothingWithoutAPlacedSelection() {
        let unplaced = Self.event("u", x: nil, y: nil)
        #expect(GardenInteraction.reduce(S(selectedEventID: "u"), .moveSelected(.up),
                                         context: Self.context([unplaced])).effects.isEmpty)
        #expect(GardenInteraction.reduce(S(), .moveSelected(.up), context: Self.context([])).effects.isEmpty)
    }

    @Test func directionActionNames() {
        #expect(GardenInteraction.Direction.allCases.map(\.actionName) == ["Move left", "Move right", "Move up", "Move down"])
    }
}
