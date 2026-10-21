import Foundation
import Testing
@testable import Seedkeep

@MainActor
struct GardenSessionTests {
    private let beds = [
        GardenSession.BedChoice(id: "nogrid", name: "A", sortOrder: 0, hasGrid: false),
        GardenSession.BedChoice(id: "herb", name: "Herb", sortOrder: 1, hasGrid: true),
        GardenSession.BedChoice(id: "north", name: "North", sortOrder: 1, hasGrid: true),
        GardenSession.BedChoice(id: "back", name: "Back", sortOrder: 2, hasGrid: true),
    ]

    private func snapshot(
        household: String? = "h1",
        signedIn: Bool = true,
        beds: Set<String> = ["herb", "north", "back"],
        grid: Set<String> = ["herb", "north", "back"],
        events: Set<String> = ["e1", "e2"],
        seeds: Set<String> = ["s1", "s2"]
    ) -> GardenSession.Snapshot {
        GardenSession.Snapshot(householdID: household, isSignedIn: signedIn, bedIDs: beds, gridBedIDs: grid,
                               eventIDs: events, activeSeedIDs: seeds)
    }

    /// A session already scoped to household h1.
    private func scopedSession() -> GardenSession {
        let session = GardenSession()
        session.reconcile(snapshot())
        return session
    }

    @Test func planPicksTheFirstGridBedBySortOrderThenName() {
        let session = scopedSession()
        session.select(eventID: "e1", presentDetails: true)
        let result = session.plan(seedID: "s1", isActive: true, beds: beds)
        #expect(result == .planned(bedID: "herb"))
        #expect(session.bedID == "herb")
        #expect(session.brushSeedID == "s1")
        #expect(session.mode == .painting)
        #expect(session.selectedEventID == nil)
        #expect(!session.detailsPresented)
        #expect(session.pendingPlan == GardenSession.PendingPlan(seedID: "s1", bedID: "herb"))
    }

    @Test func planKeepsTheLastViewedBedWhenItHasAGrid() {
        let session = scopedSession()
        session.showBed("back")
        #expect(session.plan(seedID: "s1", isActive: true, beds: beds) == .planned(bedID: "back"))
        // A last-viewed bed without a grid falls back to the first grid bed.
        session.showBed("nogrid")
        #expect(session.plan(seedID: "s2", isActive: true, beds: beds) == .planned(bedID: "herb"))
    }

    @Test func planClearsAMove() {
        let session = scopedSession()
        session.startMove(eventID: "e1")
        session.plan(seedID: "s1", isActive: true, beds: beds)
        #expect(session.mode == .painting)
        #expect(session.movingEventID == nil)
    }

    @Test func planWithNoGridBedsNeedsABed() {
        let session = scopedSession()
        let noGrid = [GardenSession.BedChoice(id: "nogrid", name: "A", sortOrder: 0, hasGrid: false)]
        #expect(session.plan(seedID: "s1", isActive: true, beds: noGrid) == .needsBed)
        #expect(session.plan(seedID: "s1", isActive: true, beds: []) == .needsBed)
        #expect(session.pendingPlan == nil)
        #expect(session.brushSeedID == "s1")
    }

    @Test func planRefusesInactiveSeedsWithoutChangingState() {
        let session = scopedSession()
        session.showBed("north")
        session.select(eventID: "e1")
        #expect(session.plan(seedID: "s9", isActive: false, beds: beds) == .notActive)
        #expect(session.brushSeedID == nil)
        #expect(session.selectedEventID == "e1")
        #expect(session.mode == .idle)
        #expect(session.pendingPlan == nil)
    }

    @Test func pendingPlanIsTakenOnce() {
        let session = scopedSession()
        session.plan(seedID: "s1", isActive: true, beds: beds)
        #expect(session.takePendingPlan() == GardenSession.PendingPlan(seedID: "s1", bedID: "herb"))
        #expect(session.takePendingPlan() == nil)
        // The brush stays after the screen takes the Plan.
        #expect(session.brushSeedID == "s1")
    }

    @Test func movingTakesPrecedenceOverPainting() {
        let session = scopedSession()
        session.startPainting(seedID: "s1")
        session.select(eventID: "e2", presentDetails: true)
        session.startMove(eventID: "e1")
        #expect(session.brushSeedID == nil)
        #expect(session.mode == .moving(eventID: "e1"))
        #expect(session.selectedEventID == "e1")
        #expect(!session.detailsPresented)
        session.endMove()
        #expect(session.mode == .idle)
        #expect(session.selectedEventID == "e1")
    }

    @Test func cancelClosesDetailsThenMoveThenBrushThenSelection() {
        let session = scopedSession()
        session.startMove(eventID: "e1")
        session.detailsPresented = true
        #expect(session.cancel())
        #expect(!session.detailsPresented && session.mode == .moving(eventID: "e1"))
        #expect(session.cancel())
        #expect(session.mode == .idle && session.selectedEventID == "e1")
        #expect(session.cancel())
        #expect(session.selectedEventID == nil)
        #expect(!session.cancel())

        session.startPainting(seedID: "s1")
        session.select(eventID: "e2", presentDetails: true)
        #expect(session.cancel())
        #expect(session.brushSeedID == "s1" && session.selectedEventID == "e2")
        #expect(session.cancel())
        #expect(session.brushSeedID == nil && session.mode == .idle && session.selectedEventID == "e2")
        #expect(session.cancel())
        #expect(session.selectedEventID == nil)
    }

    @Test func closingDetailsKeepsTheSelection() {
        let session = scopedSession()
        session.select(eventID: "e1", presentDetails: true)
        #expect(session.detailsPresented)
        session.closeDetails()
        #expect(!session.detailsPresented)
        #expect(session.selectedEventID == "e1")
        session.select(eventID: nil, presentDetails: true)
        #expect(!session.detailsPresented)
    }

    @Test func changingBedsClearsSelectionAndMoveButKeepsTheBrush() {
        let session = scopedSession()
        session.showBed("north")
        session.startPainting(seedID: "s1")
        session.select(eventID: "e1", presentDetails: true)
        session.showBed("herb")
        #expect(session.selectedEventID == nil && !session.detailsPresented)
        #expect(session.brushSeedID == "s1" && session.mode == .painting)
        session.startMove(eventID: "e2")
        session.showBed("north")
        #expect(session.mode == .idle)
    }

    @Test func householdChangeAndSignOutReset() {
        let session = scopedSession()
        session.plan(seedID: "s1", isActive: true, beds: beds)
        session.select(eventID: "e1", presentDetails: true)
        session.reconcile(snapshot(household: "h2"))
        #expect(session.bedID == nil && session.brushSeedID == nil && session.selectedEventID == nil)
        #expect(session.mode == .idle && !session.detailsPresented && session.pendingPlan == nil)

        session.plan(seedID: "s1", isActive: true, beds: beds)
        session.reconcile(snapshot(household: "h2", signedIn: false))
        #expect(session.bedID == nil && session.brushSeedID == nil && session.pendingPlan == nil)
        // Signing back in to the same garden starts clean too.
        session.reconcile(snapshot(household: "h2"))
        #expect(session.bedID == nil)
    }

    @Test func reconcileClearsWhatIsGone() {
        let session = scopedSession()
        session.plan(seedID: "s1", isActive: true, beds: beds)
        session.select(eventID: "e1", presentDetails: true)

        // A remote deletion of the selected event.
        session.reconcile(snapshot(events: ["e2"]))
        #expect(session.selectedEventID == nil && !session.detailsPresented)
        #expect(session.brushSeedID == "s1" && session.bedID == "herb")
        #expect(session.pendingPlan != nil)

        // The brush seed is archived (no longer active).
        session.reconcile(snapshot(events: ["e2"], seeds: ["s2"]))
        #expect(session.brushSeedID == nil && session.mode == .idle)
        #expect(session.pendingPlan == nil)

        // The bed is deleted.
        session.reconcile(snapshot(beds: ["north"], events: ["e2"], seeds: ["s2"]))
        #expect(session.bedID == nil)
    }

    @Test func reconcileEndsAMoveOfAGoneEvent() {
        let session = scopedSession()
        session.showBed("north")
        session.startMove(eventID: "e1")
        session.reconcile(snapshot(events: ["e2"]))
        #expect(session.mode == .idle)
        #expect(session.selectedEventID == nil)
        #expect(session.bedID == "north")
    }

    @Test func reconcileDropsAPendingPlanForAGoneBed() {
        let session = scopedSession()
        session.plan(seedID: "s1", isActive: true, beds: beds)
        session.reconcile(snapshot(beds: ["north", "back"]))
        #expect(session.pendingPlan == nil)
        #expect(session.bedID == nil)
        #expect(session.brushSeedID == "s1")
    }

    @Test func pendingPlanSurvivesAnUnchangedReconcile() {
        let session = scopedSession()
        session.plan(seedID: "s1", isActive: true, beds: beds)
        session.reconcile(snapshot())
        #expect(session.pendingPlan == GardenSession.PendingPlan(seedID: "s1", bedID: "herb"))
    }

    @Test func reconcileDropsAPendingPlanForABedThatLostItsGrid() {
        let session = scopedSession()
        session.plan(seedID: "s1", isActive: true, beds: beds)
        // The bed still exists, but its size was cleared.
        session.reconcile(snapshot(grid: ["north", "back"]))
        #expect(session.pendingPlan == nil)
        #expect(session.bedID == "herb")
        #expect(session.brushSeedID == "s1")
    }

    @Test func lastViewedBedSurvivesGoingBackToTheList() {
        let session = scopedSession()
        session.showBed("north")
        session.showBed(nil)
        #expect(session.bedID == nil)
        #expect(session.lastViewedBedID == "north")
        #expect(session.plan(seedID: "s1", isActive: true, beds: beds) == .planned(bedID: "north"))
        #expect(session.bedID == "north")
    }

    @Test func showingTheBedOnScreenStillRemembersIt() {
        let session = scopedSession()
        // A Plan puts the session on herb without the user viewing it.
        session.plan(seedID: "s1", isActive: true, beds: beds)
        #expect(session.lastViewedBedID == nil)
        session.showBed("herb")
        session.showBed(nil)
        #expect(session.lastViewedBedID == "herb")
    }

    @Test func deletingTheLastViewedBedFallsBackToTheFirstBed() {
        let session = scopedSession()
        session.showBed("north")
        session.showBed(nil)
        session.reconcile(snapshot(beds: ["herb", "back"], grid: ["herb", "back"]))
        #expect(session.lastViewedBedID == nil)
        let remaining = beds.filter { $0.id != "north" }
        #expect(session.plan(seedID: "s1", isActive: true, beds: remaining) == .planned(bedID: "herb"))
    }

    @Test func signingOutForgetsTheLastViewedBed() {
        let session = scopedSession()
        session.showBed("north")
        session.reconcile(snapshot(signedIn: false))
        #expect(session.lastViewedBedID == nil)
        #expect(session.plan(seedID: "s1", isActive: true, beds: beds) == .planned(bedID: "herb"))
    }
}
