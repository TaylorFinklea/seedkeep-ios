import Foundation
import Testing
@testable import Seedkeep

@Suite("Workbench commands")
struct WorkbenchCommandsTests {
    @Test("New Seed, Find, Export, Delete, and Random Pick queue one request and route to Seeds")
    @MainActor
    func requestCommandsQueueTheirEffects() {
        let cases: [(WorkbenchCommandAction, SeedsRequest)] = [
            (.newSeed, .newSeed),
            (.find, .focusSearch),
            (.exportCSV, .exportCSV),
            (.delete, .deleteSelection),
            (.randomPick, .randomPick)
        ]

        for (action, request) in cases {
            let model = WorkbenchModel()
            model.route = .garden
            if request == .deleteSelection {
                model.route = .seeds
                model.selectedSeedIDs = ["seed-1"]
            }

            action.perform(on: model)

            #expect(model.route == .seeds)
            #expect(model.takeSeedsRequests() == [request])
            #expect(model.takeSeedsRequests().isEmpty)
        }
    }

    @Test("Go commands change the route without queueing Seeds requests")
    @MainActor
    func goCommandsChangeRoutes() {
        let cases: [(WorkbenchCommandAction, WorkbenchRoute)] = [
            (.go(.today), .today),
            (.go(.seeds), .seeds),
            (.go(.garden), .garden),
            (.go(.journal), .journal),
            (.go(.settings), .settings)
        ]

        for (action, route) in cases {
            let model = WorkbenchModel()
            model.route = route == .today ? .garden : .today
            action.perform(on: model)
            #expect(model.route == route)
            #expect(model.takeSeedsRequests().isEmpty)
        }
    }

    @Test("Command Palette toggles the model state")
    @MainActor
    func paletteCommandTogglesState() {
        let model = WorkbenchModel()
        #expect(!model.isPaletteOpen)
        WorkbenchCommandAction.togglePalette.perform(on: model)
        #expect(model.isPaletteOpen)
        WorkbenchCommandAction.togglePalette.perform(on: model)
        #expect(!model.isPaletteOpen)
    }

    @Test("commands without a model are unavailable and have no effect")
    @MainActor
    func commandsRequireModel() {
        #expect(!WorkbenchCommandAvailability.hasModel(nil))
        #expect(!WorkbenchCommandAvailability.canDelete(model: nil))
        WorkbenchCommandAction.find.perform(on: nil)
        WorkbenchCommandAction.togglePalette.perform(on: nil)
    }

    @Test("Delete is disabled without a selection")
    @MainActor
    func deleteRequiresSelection() {
        let model = WorkbenchModel()
        #expect(!WorkbenchCommandAvailability.canDelete(model: model))
        WorkbenchCommandAction.delete.perform(on: model)
        #expect(model.takeSeedsRequests().isEmpty)
    }

    @Test("Delete is unavailable outside Seeds even with a stale selection")
    @MainActor
    func deleteRequiresSeedsRoute() {
        let model = WorkbenchModel()
        model.route = .garden
        model.selectedSeedIDs = ["seed-1"]

        #expect(!WorkbenchCommandAvailability.canDelete(model: model))
        WorkbenchCommandAction.delete.perform(on: model)
        #expect(model.route == .garden)
        #expect(model.takeSeedsRequests().isEmpty)
    }

    @Test("Delete is disabled while editing text")
    @MainActor
    func deleteDisabledWhileEditingText() {
        let model = WorkbenchModel()
        model.selectedSeedIDs = ["seed-1"]
        model.isEditingText = true
        #expect(!WorkbenchCommandAvailability.canDelete(model: model))
        WorkbenchCommandAction.delete.perform(on: model)
        #expect(model.takeSeedsRequests().isEmpty)
    }

    @Test("Undo and redo availability tracks active manager history notifications")
    @MainActor
    func undoRedoUseActiveUndoManager() async {
        let model = WorkbenchModel()
        let undoManager = UndoManager()
        model.activeUndoManager = undoManager
        let availability = WorkbenchUndoAvailability()
        availability.observe(undoManager)
        #expect(!availability.canUndo)
        #expect(!availability.canRedo)

        let probe = UndoProbe(undoManager: undoManager)
        probe.value = 1
        undoManager.beginUndoGrouping()
        probe.registerUndo(to: 0)
        undoManager.endUndoGrouping()
        await Task.yield()

        #expect(availability.canUndo)
        WorkbenchCommandAction.undo.perform(on: model)
        await Task.yield()
        #expect(probe.value == 0)
        #expect(availability.canRedo)
        WorkbenchCommandAction.redo.perform(on: model)
        await Task.yield()
        #expect(probe.value == 1)
        #expect(availability.canUndo)
        availability.stopObserving()
    }

    @Test("scope reset clears selection, queued work, editing, and palette state")
    @MainActor
    func resetClearsScopeOwnedState() {
        let model = WorkbenchModel()
        model.selectedSeedIDs = ["seed-1", "seed-2"]
        model.request(.exportCSV)
        model.isEditingText = true
        model.isPaletteOpen = true
        model.revealedSeedID = "seed-2"
        let undoManager = UndoManager()
        model.activeUndoManager = undoManager
        let probe = UndoProbe(undoManager: undoManager)
        probe.value = 1
        undoManager.beginUndoGrouping()
        probe.registerUndo(to: 0)
        undoManager.endUndoGrouping()

        model.resetForScopeChange()

        #expect(model.selectedSeedIDs.isEmpty)
        #expect(model.takeSeedsRequests().isEmpty)
        #expect(!model.isEditingText)
        #expect(!model.isPaletteOpen)
        #expect(model.revealedSeedID == nil)
        #expect(!undoManager.canUndo)
    }
}

@MainActor
private final class UndoProbe: NSObject {
    let undoManager: UndoManager
    var value = 0

    init(undoManager: UndoManager) {
        self.undoManager = undoManager
    }

    func registerUndo(to value: Int) {
        let previousValue = self.value
        undoManager.registerUndo(withTarget: self) { probe in
            probe.value = value
            probe.registerUndo(to: previousValue)
        }
    }
}
