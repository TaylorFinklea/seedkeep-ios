import SwiftUI
import Observation

private struct WorkbenchModelKey: FocusedValueKey {
    typealias Value = WorkbenchModel
}

private struct WorkbenchUndoAvailabilityKey: FocusedValueKey {
    typealias Value = WorkbenchUndoAvailability
}

extension FocusedValues {
    var workbenchModel: WorkbenchModel? {
        get { self[WorkbenchModelKey.self] }
        set { self[WorkbenchModelKey.self] = newValue }
    }

    var workbenchUndoAvailability: WorkbenchUndoAvailability? {
        get { self[WorkbenchUndoAvailabilityKey.self] }
        set { self[WorkbenchUndoAvailabilityKey.self] = newValue }
    }
}

@MainActor
@Observable
final class WorkbenchUndoAvailability {
    private(set) var canUndo = false
    private(set) var canRedo = false

    @ObservationIgnored private var undoManager: UndoManager?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    func observe(_ manager: UndoManager) {
        guard undoManager !== manager else {
            refresh()
            return
        }
        stopObserving()
        undoManager = manager
        // Reading canRedo emits a checkpoint notification, so observe closed
        // groups and completed undo/redo operations to avoid a refresh loop.
        let notifications: [Notification.Name] = [
            .NSUndoManagerDidCloseUndoGroup,
            .NSUndoManagerDidUndoChange,
            .NSUndoManagerDidRedoChange
        ]
        observers = notifications.map { name in
            NotificationCenter.default.addObserver(forName: name, object: manager, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.refresh() }
            }
        }
        refresh()
    }

    func stopObserving() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        undoManager = nil
        canUndo = false
        canRedo = false
    }

    func refresh() {
        canUndo = undoManager?.canUndo == true
        canRedo = undoManager?.canRedo == true
    }
}

struct WorkbenchCommands: Commands {
    @FocusedValue(\.workbenchModel) private var model
    @FocusedValue(\.workbenchUndoAvailability) private var undoAvailability
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Seed") { WorkbenchCommandAction.newSeed.perform(on: model) }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(!WorkbenchCommandAvailability.hasModel(model))
            #if os(macOS)
            Button("New Window") { openWindow(id: "main") }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            #endif
        }

        CommandMenu("Seeds") {
            Button("Find") { WorkbenchCommandAction.find.perform(on: model) }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(!WorkbenchCommandAvailability.hasModel(model))
            Button("Export CSV…") { WorkbenchCommandAction.exportCSV.perform(on: model) }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(!WorkbenchCommandAvailability.hasModel(model))
            Button("Delete Selected Seeds…") { WorkbenchCommandAction.delete.perform(on: model) }
                .disabled(!WorkbenchCommandAvailability.canDelete(model: model))
            #if os(iOS)
            Button("Undo") { WorkbenchCommandAction.undo.perform(on: model) }
                .disabled(undoAvailability?.canUndo != true)
            Button("Redo") { WorkbenchCommandAction.redo.perform(on: model) }
                .disabled(undoAvailability?.canRedo != true)
            #endif
            Button("Command Palette") { WorkbenchCommandAction.togglePalette.perform(on: model) }
                .keyboardShortcut("k", modifiers: .command)
                .disabled(!WorkbenchCommandAvailability.hasModel(model))
        }

        CommandMenu("Go") {
            routeButton("Today", route: .today, key: "1")
            routeButton("Seeds", route: .seeds, key: "2")
            routeButton("Garden", route: .garden, key: "3")
            routeButton("Journal", route: .journal, key: "4")
            Divider()
            Button("Settings") { WorkbenchCommandAction.go(.settings).perform(on: model) }
                .keyboardShortcut(",", modifiers: .command)
                .disabled(!WorkbenchCommandAvailability.hasModel(model))
        }
    }

    @ViewBuilder private func routeButton(_ title: String, route: WorkbenchRoute, key: KeyEquivalent) -> some View {
        Button(title) { WorkbenchCommandAction.go(route).perform(on: model) }
            .keyboardShortcut(key, modifiers: .command)
            .disabled(!WorkbenchCommandAvailability.hasModel(model))
    }
}

@MainActor
enum WorkbenchCommandAction {
    case newSeed, find, exportCSV, delete, undo, redo, togglePalette
    case go(WorkbenchRoute)

    func perform(on model: WorkbenchModel?) {
        guard let model else { return }
        switch self {
        case .newSeed: model.request(.newSeed)
        case .find: model.request(.focusSearch)
        case .exportCSV: model.request(.exportCSV)
        case .delete:
            guard WorkbenchCommandAvailability.canDelete(model: model) else { return }
            model.request(.deleteSelection)
        case .undo: model.activeUndoManager?.undo()
        case .redo: model.activeUndoManager?.redo()
        case .togglePalette: model.isPaletteOpen.toggle()
        case .go(let route): model.route = route
        }
    }
}

@MainActor
enum WorkbenchCommandAvailability {
    static func hasModel(_ model: WorkbenchModel?) -> Bool { model != nil }

    static func canDelete(model: WorkbenchModel?) -> Bool {
        guard let model else { return false }
        return model.route == .seeds && !model.selectedSeedIDs.isEmpty && !model.isEditingText
    }
}
