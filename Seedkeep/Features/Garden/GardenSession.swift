import Foundation
import Observation

/// One window's Garden state: the bed on screen, the brush, the selected event, the mode and a Plan
/// waiting for a Garden screen. Owned at the window root above both shells, so a Plan survives a
/// size-class shell switch. Data stays in SwiftData; this holds only ids.
@MainActor
@Observable
final class GardenSession {
    enum Mode: Equatable, Sendable {
        case idle
        case painting
        case moving(eventID: String)
    }

    /// A Plan for a Garden screen to pick up: show `bedID` and paint with `seedID`.
    struct PendingPlan: Equatable, Sendable {
        let seedID: String
        let bedID: String
    }

    enum PlanResult: Equatable, Sendable {
        case planned(bedID: String)
        /// No live bed has a grid; the UI offers "Add a bed with a size to plan".
        case needsBed
        /// Only active seeds can be planned.
        case notActive
    }

    /// A bed Plan can choose, as plain values.
    struct BedChoice: Equatable, Sendable {
        let id: String
        let name: String
        let sortOrder: Int
        let hasGrid: Bool
    }

    /// The live ids reconcile checks the session against, all in the active garden.
    struct Snapshot: Equatable, Sendable {
        var householdID: String?
        var isSignedIn: Bool
        var bedIDs: Set<String>
        /// The live beds that have a grid (a valid size), a subset of `bedIDs`.
        var gridBedIDs: Set<String>
        var eventIDs: Set<String>
        var activeSeedIDs: Set<String>
    }

    /// The bed on screen, or nil on the bed list.
    private(set) var bedID: String?
    /// The bed last shown with a non-nil `showBed`. Plan prefers it, and it survives going back to the list.
    private(set) var lastViewedBedID: String?
    private(set) var brushSeedID: String?
    private(set) var selectedEventID: String?
    private(set) var mode: Mode = .idle
    var detailsPresented = false
    private(set) var pendingPlan: PendingPlan?

    /// The garden scope the state belongs to; a change resets everything.
    @ObservationIgnored private var scopeHouseholdID: String?

    var isPainting: Bool { mode == .painting }

    var movingEventID: String? {
        if case .moving(let id) = mode { return id }
        return nil
    }

    // MARK: - Bed

    /// Shows a bed. Changing beds clears the selection, details and any move; the brush stays.
    func showBed(_ id: String?) {
        if let id { lastViewedBedID = id }
        guard id != bedID else { return }
        bedID = id
        clearSelection()
        if movingEventID != nil { mode = .idle }
    }

    // MARK: - Brush

    /// Starts painting with a seed. Ends any move.
    func startPainting(seedID: String) {
        brushSeedID = seedID
        mode = .painting
    }

    /// Puts the brush down.
    func stopPainting() {
        brushSeedID = nil
        if mode == .painting { mode = .idle }
    }

    // MARK: - Selection and details

    func select(eventID: String?, presentDetails: Bool = false) {
        selectedEventID = eventID
        detailsPresented = eventID != nil && presentDetails
    }

    func clearSelection() {
        selectedEventID = nil
        detailsPresented = false
    }

    /// Closes details and keeps the selection.
    func closeDetails() {
        detailsPresented = false
    }

    // MARK: - Move

    /// Moving takes precedence over painting: it clears the brush and closes details.
    func startMove(eventID: String) {
        brushSeedID = nil
        selectedEventID = eventID
        detailsPresented = false
        mode = .moving(eventID: eventID)
    }

    func endMove() {
        guard movingEventID != nil else { return }
        mode = .idle
    }

    /// Escape and Cancel: closes the details editor, then move mode, then the brush, then the
    /// selection. Returns false when there was nothing to close.
    @discardableResult
    func cancel() -> Bool {
        if detailsPresented {
            detailsPresented = false
        } else if movingEventID != nil {
            mode = .idle
        } else if brushSeedID != nil {
            stopPainting()
        } else if selectedEventID != nil {
            selectedEventID = nil
        } else {
            return false
        }
        return true
    }

    // MARK: - Plan

    /// Plans a seed: clears the selection and any move, sets the brush, and picks the last-viewed
    /// bed when it is live with a grid, otherwise the first bed with a grid by sort order and then
    /// name. On success the Plan waits in `pendingPlan` for a Garden screen. With no bed that has a
    /// grid, the brush is still set so painting can start once a bed is added.
    @discardableResult
    func plan(seedID: String, isActive: Bool, beds: [BedChoice]) -> PlanResult {
        guard isActive else { return .notActive }
        clearSelection()
        startPainting(seedID: seedID)
        let gridBeds = beds.filter(\.hasGrid)
        let chosen = gridBeds.first { $0.id == lastViewedBedID } ?? gridBeds.min { lhs, rhs in
            if lhs.sortOrder != rhs.sortOrder { return lhs.sortOrder < rhs.sortOrder }
            let byName = lhs.name.localizedStandardCompare(rhs.name)
            if byName != .orderedSame { return byName == .orderedAscending }
            return lhs.id < rhs.id
        }
        guard let chosen else {
            pendingPlan = nil
            return .needsBed
        }
        bedID = chosen.id
        pendingPlan = PendingPlan(seedID: seedID, bedID: chosen.id)
        return .planned(bedID: chosen.id)
    }

    /// A Garden screen calls this when it appears: it returns the waiting Plan once, so the screen
    /// can open that bed. A shell switch before then keeps it waiting.
    func takePendingPlan() -> PendingPlan? {
        let plan = pendingPlan
        pendingPlan = nil
        return plan
    }

    // MARK: - Reconcile

    /// Clears everything: sign-out or a different garden.
    func reset() {
        bedID = nil
        lastViewedBedID = nil
        brushSeedID = nil
        selectedEventID = nil
        mode = .idle
        detailsPresented = false
        pendingPlan = nil
    }

    /// Resets on a household change or sign-out; otherwise clears a bed or event that is gone and a
    /// brush seed that is no longer active in this garden.
    func reconcile(_ snapshot: Snapshot) {
        guard snapshot.isSignedIn else {
            reset()
            scopeHouseholdID = nil
            return
        }
        if snapshot.householdID != scopeHouseholdID {
            reset()
            scopeHouseholdID = snapshot.householdID
            return
        }
        if let bedID, !snapshot.bedIDs.contains(bedID) {
            self.bedID = nil
            clearSelection()
            if movingEventID != nil { mode = .idle }
        }
        if let lastViewedBedID, !snapshot.bedIDs.contains(lastViewedBedID) {
            self.lastViewedBedID = nil
        }
        if let selectedEventID, !snapshot.eventIDs.contains(selectedEventID) {
            clearSelection()
        }
        if let moving = movingEventID, !snapshot.eventIDs.contains(moving) {
            mode = .idle
        }
        if let brushSeedID, !snapshot.activeSeedIDs.contains(brushSeedID) {
            stopPainting()
        }
        // A Plan is dropped when its seed is no longer active, or its bed is gone or no longer has a grid.
        if let plan = pendingPlan,
           !snapshot.activeSeedIDs.contains(plan.seedID)
            || !snapshot.bedIDs.contains(plan.bedID)
            || !snapshot.gridBedIDs.contains(plan.bedID) {
            pendingPlan = nil
        }
    }
}
