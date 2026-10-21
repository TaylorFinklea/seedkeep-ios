// Shared Workbench state (redesign R1). PARENT-OWNED contract: workers use these types and
// do not change their shape; ask the parent for additions.
//
// Slice A (shell, commands, palette) and slice B (Seeds table) talk only through this model:
// menus and the palette set routes, selection and queued requests; the Seeds screen takes the
// requests and fulfils them. The shell owns the live data feed (see `SeedTableRow.rows`).
import Foundation
import Observation

enum SeedsRequest: Equatable, Sendable {
    case newSeed, exportCSV, focusSearch, deleteSelection
    /// N2: opens the random pick in a sheet, so it is reachable on the Mac and regular-width iPad.
    case randomPick
}

enum WorkbenchRoute: String, CaseIterable, Identifiable, Sendable {
    case today, seeds, garden, windows, journal, settings
    var id: String { rawValue }

    var title: String {
        switch self {
        case .today: return "Today"
        case .seeds: return "Seeds"
        case .garden: return "Garden"
        case .windows: return "Windows"
        case .journal: return "Journal"
        case .settings: return "Settings"
        }
    }

    /// SF Symbol for the sidebar.
    var symbol: String {
        switch self {
        case .today: return "sun.max"
        case .seeds: return "leaf"
        case .garden: return "square.grid.3x3"
        case .windows: return "calendar"
        case .journal: return "book"
        case .settings: return "gearshape"
        }
    }
}

/// One Workbench window's state. Each window owns its own instance: selection, routes and
/// drafts are per window, while data and sync stay app-wide in `AppEnvironment`.
@MainActor
@Observable
final class WorkbenchModel {
    var route: WorkbenchRoute = .seeds {
        didSet {
            guard route != oldValue else { return }
            // Each visit to Seeds decides the inspector's starting state again, and a choice made
            // during the last visit doesn't carry over.
            isSeedsInspectorDecisionPending = route == .seeds
            isInspectorChosenThisVisit = false
        }
    }
    /// Selected seed ids in the Seeds table (stable across sorting and remote updates).
    var selectedSeedIDs: Set<String> = []
    var isPaletteOpen = false
    var isInspectorOpen = true

    /// True from entering Seeds until its inspector's starting state is decided. The window opens on
    /// Seeds, so it starts true.
    private(set) var isSeedsInspectorDecisionPending = true
    /// True once the user, or `reveal(seedID:)`, has set the inspector during this visit to Seeds.
    private(set) var isInspectorChosenThisVisit = false
    /// Width of the detail column that holds the routes, reported by the shell. The Seeds screen
    /// reads it to decide the inspector's starting state.
    var detailColumnWidth: CGFloat = 0

    /// True while one of the Seeds screen's own drafts or its search field has focus in this
    /// window. Set only from this window's focus state (never from process-wide notifications).
    var isEditingText = false

    /// The undo manager the Seeds screen registers edits with in this window (the environment's
    /// when SwiftUI provides one, otherwise a per-window fallback). Menus and the iPad toolbar
    /// undo and redo through it, so the fallback is always reachable.
    var activeUndoManager: UndoManager?

    /// Requests from menus and the palette, queued until the Seeds screen takes them. A queue
    /// (not a counter) means a request sent before Seeds is on screen is still delivered once
    /// it appears, and is never replayed afterwards.
    private(set) var pendingSeedsRequests: [SeedsRequest] = []

    func request(_ request: SeedsRequest) {
        route = .seeds
        pendingSeedsRequests.append(request)
    }

    /// The Seeds screen calls this when it appears and whenever the queue changes.
    func takeSeedsRequests() -> [SeedsRequest] {
        let taken = pendingSeedsRequests
        pendingSeedsRequests.removeAll()
        return taken
    }

    /// Call when the signed-in garden scope changes (sign-out, or adopting a shared garden):
    /// selection, queued requests and editing state belong to the old scope.
    func resetForScopeChange() {
        selectedSeedIDs = []
        pendingSeedsRequests = []
        isEditingText = false
        isPaletteOpen = false
        revealedSeedID = nil
        // Undo actions belong to the old garden scope; clear them even if Seeds is off screen.
        activeUndoManager?.removeAllActions()
    }

    /// Jumps to one seed: shows Seeds, selects it, and opens the inspector. The Seeds screen
    /// clears any filter or search that would hide it (see `revealedSeedID`).
    func reveal(seedID: String) {
        route = .seeds
        selectedSeedIDs = [seedID]
        setInspectorOpen(true)
        revealedSeedID = seedID
    }

    /// The user's inspector choice: the toolbar toggle, or the inspector's own dismissal. It holds
    /// until the route is left, so the narrow-layout default doesn't override it.
    func setInspectorOpen(_ open: Bool) {
        isInspectorChosenThisVisit = true
        isInspectorOpen = open
    }

    /// Applies the Seeds inspector's starting state, once per visit and only after the detail width is
    /// known. A choice made during the visit keeps the current state. Resizing never reaches here.
    func decideSeedsInspectorStart(availableWidth: CGFloat, tableMinWidth: CGFloat, inspectorMinWidth: CGFloat) {
        guard isSeedsInspectorDecisionPending, availableWidth > 0 else { return }
        isSeedsInspectorDecisionPending = false
        if let open = SeedsInspectorPolicy.startsOpen(
            availableWidth: availableWidth,
            tableMinWidth: tableMinWidth,
            inspectorMinWidth: inspectorMinWidth,
            userToggledThisVisit: isInspectorChosenThisVisit
        ) {
            isInspectorOpen = open
        }
    }

    /// Set by `reveal`; the Seeds screen clears hiding filters, scrolls to it, then sets nil.
    var revealedSeedID: String?
}
