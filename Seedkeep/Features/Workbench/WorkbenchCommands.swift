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
            Button("Pick a Random Seed") { WorkbenchCommandAction.randomPick.perform(on: model) }
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
            ForEach(WorkbenchGoShortcut.routes, id: \.self) { route in
                routeButton(route)
            }
            // The Mac's Settings window owns ⌘, (see `WorkbenchNavigation`).
            if WorkbenchNavigation.goMenuShowsSettings(isMac: WorkbenchNavigation.isMacPlatform) {
                Divider()
                Button("Settings") { WorkbenchCommandAction.go(.settings).perform(on: model) }
                    .keyboardShortcut(",", modifiers: .command)
                    .disabled(!WorkbenchCommandAvailability.hasModel(model))
            }
        }
    }

    @ViewBuilder private func routeButton(_ route: WorkbenchRoute) -> some View {
        let button = Button(route.title) { WorkbenchCommandAction.go(route).perform(on: model) }
            .disabled(!WorkbenchCommandAvailability.hasModel(model))
        if let key = WorkbenchGoShortcut.key(for: route) {
            button.keyboardShortcut(KeyEquivalent(key), modifiers: .command)
        } else {
            button
        }
    }
}

/// The Go menu's numbered routes. Numbers stay with their routes, so Windows (added in R3) is ⌘5
/// though it is listed after Garden.
enum WorkbenchGoShortcut {
    static let routes: [WorkbenchRoute] = [.today, .seeds, .garden, .windows, .journal]

    static func key(for route: WorkbenchRoute) -> Character? {
        switch route {
        case .today: return "1"
        case .seeds: return "2"
        case .garden: return "3"
        case .journal: return "4"
        case .windows: return "5"
        case .settings: return nil
        }
    }
}

@MainActor
enum WorkbenchCommandAction {
    case newSeed, find, exportCSV, delete, undo, redo, togglePalette, randomPick
    case go(WorkbenchRoute)

    func perform(on model: WorkbenchModel?) {
        guard let model else { return }
        switch self {
        case .newSeed: model.request(.newSeed)
        case .find: model.request(.focusSearch)
        case .exportCSV: model.request(.exportCSV)
        case .randomPick: model.request(.randomPick)
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
