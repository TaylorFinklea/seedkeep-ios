import SwiftUI
import Testing
@testable import Seedkeep

@Suite("Seeds inspector starting state")
struct SeedsInspectorPolicyTests {
    // iPad table minimum (636) plus the inspector minimum (300).
    private let tableMin: CGFloat = 636
    private let inspectorMin: CGFloat = 300

    @Test("a detail column narrower than table plus inspector starts closed")
    func narrowColumnStartsClosed() {
        // iPad portrait (834 pt) with no sidebar.
        #expect(SeedsInspectorPolicy.startsOpen(
            availableWidth: 834, tableMinWidth: tableMin, inspectorMinWidth: inspectorMin, userToggledThisVisit: false
        ) == false)
    }

    @Test("the threshold is inclusive: exactly table plus inspector keeps the current state")
    func thresholdKeepsState() {
        #expect(SeedsInspectorPolicy.startsOpen(
            availableWidth: 936, tableMinWidth: tableMin, inspectorMinWidth: inspectorMin, userToggledThisVisit: false
        ) == nil)
        #expect(SeedsInspectorPolicy.startsOpen(
            availableWidth: 935.5, tableMinWidth: tableMin, inspectorMinWidth: inspectorMin, userToggledThisVisit: false
        ) == false)
    }

    @Test("a wide detail column keeps the inspector as the user left it")
    func wideColumnKeepsState() {
        // iPad 12.9-inch portrait (1024 pt).
        #expect(SeedsInspectorPolicy.startsOpen(
            availableWidth: 1024, tableMinWidth: tableMin, inspectorMinWidth: inspectorMin, userToggledThisVisit: false
        ) == nil)
    }

    @Test("a choice made during the visit holds at any width")
    func userChoiceHoldsAtAnyWidth() {
        for width: CGFloat in [500, 936, 1200] {
            #expect(SeedsInspectorPolicy.startsOpen(
                availableWidth: width, tableMinWidth: tableMin, inspectorMinWidth: inspectorMin, userToggledThisVisit: true
            ) == nil)
        }
    }
}

@Suite("Seeds inspector visits")
struct SeedsInspectorVisitTests {
    private let tableMin: CGFloat = 636
    private let inspectorMin: CGFloat = 300

    @MainActor
    private func decide(_ model: WorkbenchModel, width: CGFloat) {
        model.decideSeedsInspectorStart(
            availableWidth: width, tableMinWidth: tableMin, inspectorMinWidth: inspectorMin
        )
    }

    @Test("the decision waits for a known width, then applies once")
    @MainActor
    func decisionWaitsForWidth() {
        let model = WorkbenchModel()
        decide(model, width: 0)
        #expect(model.isInspectorOpen)
        #expect(model.isSeedsInspectorDecisionPending)

        decide(model, width: 834)
        #expect(!model.isInspectorOpen)
        #expect(!model.isSeedsInspectorDecisionPending)
    }

    @Test("resizing after the decision never toggles the inspector")
    @MainActor
    func resizingNeverToggles() {
        let narrow = WorkbenchModel()
        decide(narrow, width: 834)
        decide(narrow, width: 1200)
        #expect(!narrow.isInspectorOpen)

        let wide = WorkbenchModel()
        decide(wide, width: 1200)
        decide(wide, width: 500)
        #expect(wide.isInspectorOpen)
    }

    @Test("a toggle made before the decision wins over the narrow default")
    @MainActor
    func toggleBeforeDecisionWins() {
        let model = WorkbenchModel()
        model.setInspectorOpen(true)
        decide(model, width: 834)
        #expect(model.isInspectorOpen)
    }

    @Test("a toggle holds until the route is left, then the next visit decides again")
    @MainActor
    func toggleHoldsUntilRouteLeft() {
        let model = WorkbenchModel()
        decide(model, width: 834)
        model.setInspectorOpen(true)
        decide(model, width: 834)
        #expect(model.isInspectorOpen)

        model.route = .today
        model.route = .seeds
        #expect(!model.isInspectorChosenThisVisit)
        decide(model, width: 834)
        #expect(!model.isInspectorOpen)
    }

    @Test("reveal opens the inspector even when the narrow default would close it")
    @MainActor
    func revealOpensAgainstDefault() {
        let model = WorkbenchModel()
        model.route = .garden
        model.reveal(seedID: "seed-1")
        decide(model, width: 834)
        #expect(model.isInspectorOpen)
        #expect(model.revealedSeedID == "seed-1")
    }

    @Test("entering Seeds from another route decides with the width already known")
    @MainActor
    func enteringFromAnotherRouteDecides() {
        let model = WorkbenchModel()
        decide(model, width: 1200)
        model.route = .journal
        decide(model, width: 1200)
        #expect(!model.isSeedsInspectorDecisionPending)

        model.route = .seeds
        #expect(model.isSeedsInspectorDecisionPending)
        decide(model, width: 834)
        #expect(!model.isInspectorOpen)
    }

    @Test("in a wide layout, closing the inspector carries over to the next visit")
    @MainActor
    func wideCloseCarriesOver() {
        let model = WorkbenchModel()
        decide(model, width: 1200)
        model.setInspectorOpen(false)
        model.route = .garden
        model.route = .seeds
        decide(model, width: 1200)
        #expect(!model.isInspectorOpen)
    }

    @Test("leaving Seeds before the decision leaves the inspector alone")
    @MainActor
    func leavingBeforeDecisionDoesNothing() {
        let model = WorkbenchModel()
        model.route = .today
        decide(model, width: 834)
        #expect(model.isInspectorOpen)
    }
}
