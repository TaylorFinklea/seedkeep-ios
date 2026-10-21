import Foundation
import SwiftData
import SeedkeepKit

/// Performs the Garden's writes through the existing `SyncEngine` enqueue methods. Before each write it
/// re-checks against the store that the household scope, the bed, the event and the square's local
/// state are still what the screen saw; a stale write is refused, not sent. Edits send only the field
/// that changed, a move sends both coordinates, and marking not done sends `completed_at: .some(nil)`.
@MainActor
struct GardenActions {
    /// What the screen rendered: the garden and the bed.
    struct Scope: Equatable, Sendable {
        let householdID: String
        let bedID: String
    }

    enum Outcome: Equatable, Sendable {
        /// A write was enqueued.
        case written
        /// Nothing changed, so nothing was written.
        case unchanged
        /// Not written; the message says why.
        case refused(String)
    }

    static let scopeChangedMessage = "Your garden changed. Nothing was saved."
    static let bedGoneMessage = "This bed was deleted or resized. Nothing was saved."
    static let eventGoneMessage = "This planting was deleted. Nothing was saved."
    static let eventMovedMessage = "This planting moved on another device. Try again."
    static let seedUnavailableMessage = "That seed is no longer active in this garden."

    let sync: SyncEngine
    let container: ModelContainer
    let scope: Scope
    /// The live garden scope, read at write time (`AppEnvironment.activeGardenHouseholdID`).
    let currentHouseholdID: @MainActor () -> String?
    /// Called after each enqueued write, e.g. to start a sync.
    let didWrite: @MainActor () -> Void

    init(
        sync: SyncEngine,
        container: ModelContainer,
        scope: Scope,
        currentHouseholdID: @escaping @MainActor () -> String?,
        didWrite: @escaping @MainActor () -> Void = {}
    ) {
        self.sync = sync
        self.container = container
        self.scope = scope
        self.currentHouseholdID = currentHouseholdID
        self.didWrite = didWrite
    }

    // MARK: - Reducer effects

    /// Performs one of `GardenInteraction`'s effects. `size` is the grid the rules used. A refusal
    /// effect is returned as `.refused` without touching the store.
    @discardableResult
    func perform(_ effect: GardenInteraction.Effect, size: GridSize) throws -> Outcome {
        switch effect {
        case .refuse(let message):
            return .refused(message)

        case let .createSowing(seedID, square, position, plannedFor):
            let context = ModelContext(container)
            if let refusal = checkBed(size: size, in: context) { return refusal }
            guard let seed = fetchSeed(seedID, in: context), seed.deletedAt == nil,
                  seed.householdID == scope.householdID, seed.state == .active else {
                return .refused(Self.seedUnavailableMessage)
            }
            guard !squareContents(square, size: size, excluding: nil, in: context).blocksPainting else {
                return .refused(GardenInteraction.occupiedMessage(square))
            }
            let input = SeedkeepClient.CreatePlantingEventInput(
                bed_id: scope.bedID,
                seed_id: seedID,
                kind: .sowing,
                planned_for: plannedFor.ymd,
                x_feet: position.x,
                y_feet: position.y
            )
            _ = try sync.enqueueCreatePlantingEvent(input, householdID: scope.householdID)
            didWrite()
            return .written

        case let .move(eventID, from, to, square):
            let context = ModelContext(container)
            if let refusal = checkBed(size: size, in: context) { return refusal }
            let event: LocalPlantingEvent
            switch checkEvent(eventID, in: context) {
            case .failure(let refusal): return refusal.outcome
            case .success(let found): event = found
            }
            let current = event.xFeet.flatMap { x in event.yFeet.map { GardenInteraction.Point(x: x, y: $0) } }
            guard current == from else { return .refused(Self.eventMovedMessage) }
            // A no-op move writes nothing.
            if current == to { return .unchanged }
            guard GardenGrid.contains(square, in: size),
                  GardenGrid.square(x: to.x, y: to.y, in: size) == square else {
                return .refused(GardenInteraction.outsideMessage)
            }
            guard !squareContents(square, size: size, excluding: eventID, in: context).blocksPainting else {
                return .refused(GardenInteraction.occupiedMessage(square))
            }
            try sync.enqueueUpdatePlantingEvent(
                id: eventID,
                SeedkeepClient.UpdatePlantingEventInput(x_feet: to.x, y_feet: to.y)
            )
            didWrite()
            return .written
        }
    }

    // MARK: - Edits (one field each)

    @discardableResult
    func setKind(_ kind: PlantingEventKind, eventID: String) throws -> Outcome {
        try edit(eventID) { event in
            event.kindRaw == kind.rawValue ? nil : .init(kind: kind)
        }
    }

    @discardableResult
    func setPlannedFor(_ day: CalendarDay, eventID: String) throws -> Outcome {
        try edit(eventID) { event in
            event.plannedFor == day.ymd ? nil : .init(planned_for: day.ymd)
        }
    }

    /// Done on stamps `now`; done off sends `completed_at: .some(nil)`.
    @discardableResult
    func setDone(_ done: Bool, eventID: String, now: Date = Date()) throws -> Outcome {
        try edit(eventID) { event in
            if done == (event.completedAt != nil) { return nil }
            return done
                ? .init(completed_at: .some(Int64(now.timeIntervalSince1970 * 1000)))
                : .init(completed_at: .some(nil))
        }
    }

    /// Notes are saved on commit. Blank notes clear them (sent as an empty string, since the field has
    /// no explicit null); notes equal to the stored ones write nothing.
    @discardableResult
    func setNotes(_ notes: String, eventID: String) throws -> Outcome {
        let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        return try edit(eventID) { event in
            let stored = (event.notes ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return stored == trimmed ? nil : .init(notes: trimmed)
        }
    }

    /// Deletes one event: `enqueueDeletePlantingEvent` tombstones it and cancels its reminder.
    @discardableResult
    func delete(eventID: String) throws -> Outcome {
        let context = ModelContext(container)
        if let refusal = checkBed(in: context) { return refusal }
        if case .failure(let refusal) = checkEvent(eventID, in: context) { return refusal.outcome }
        try sync.enqueueDeletePlantingEvent(id: eventID)
        didWrite()
        return .written
    }

    // MARK: - Checks

    private struct Refusal: Error {
        let outcome: Outcome
    }

    private func edit(
        _ eventID: String,
        patch: (LocalPlantingEvent) -> SeedkeepClient.UpdatePlantingEventInput?
    ) throws -> Outcome {
        let context = ModelContext(container)
        if let refusal = checkBed(in: context) { return refusal }
        switch checkEvent(eventID, in: context) {
        case .failure(let refusal):
            return refusal.outcome
        case .success(let event):
            guard let input = patch(event) else { return .unchanged }
            try sync.enqueueUpdatePlantingEvent(id: eventID, input)
            didWrite()
            return .written
        }
    }

    private func checkScope() -> Outcome? {
        currentHouseholdID() == scope.householdID ? nil : .refused(Self.scopeChangedMessage)
    }

    /// The scope is current and the bed is live and in the scope. Edits and deletes check this; they
    /// don't depend on the grid, so a resize doesn't refuse them.
    private func checkBed(in context: ModelContext) -> Outcome? {
        if let refusal = checkScope() { return refusal }
        return liveBed(in: context) == nil ? .refused(Self.bedGoneMessage) : nil
    }

    /// The scope is current and the bed is live, in the scope, with the grid the rules used.
    private func checkBed(size: GridSize, in context: ModelContext) -> Outcome? {
        if let refusal = checkScope() { return refusal }
        guard let bed = liveBed(in: context),
              GardenGrid.size(widthFeet: bed.widthFeet, lengthFeet: bed.lengthFeet) == size else {
            return .refused(Self.bedGoneMessage)
        }
        return nil
    }

    private func liveBed(in context: ModelContext) -> LocalBed? {
        let bedID = scope.bedID
        let bed = try? context.fetch(FetchDescriptor<LocalBed>(predicate: #Predicate { $0.id == bedID })).first
        guard let bed, bed.deletedAt == nil, bed.householdID == scope.householdID else { return nil }
        return bed
    }

    /// The event is live, in the scope's garden and in the scope's bed.
    private func checkEvent(_ eventID: String, in context: ModelContext) -> Result<LocalPlantingEvent, Refusal> {
        let event = try? context.fetch(
            FetchDescriptor<LocalPlantingEvent>(predicate: #Predicate { $0.id == eventID })
        ).first
        guard let event, event.deletedAt == nil, event.householdID == scope.householdID,
              event.bedID == scope.bedID else {
            return .failure(Refusal(outcome: .refused(Self.eventGoneMessage)))
        }
        return .success(event)
    }

    private func fetchSeed(_ seedID: String, in context: ModelContext) -> LocalSeed? {
        try? context.fetch(FetchDescriptor<LocalSeed>(predicate: #Predicate { $0.id == seedID })).first
    }

    /// The square's contents as the store holds them now.
    private func squareContents(
        _ square: GridSquare,
        size: GridSize,
        excluding eventID: String?,
        in context: ModelContext
    ) -> SquareContents {
        let bedID = scope.bedID
        let live = (try? context.fetch(FetchDescriptor<LocalPlantingEvent>(
            predicate: #Predicate { $0.bedID == bedID && $0.deletedAt == nil }
        ))) ?? []
        let events = live
            .filter { $0.householdID == scope.householdID && $0.id != eventID }
            .map { GridEvent($0, isFrostFlagged: false) }
        return GardenGrid.contents(of: square, events: events, bedID: bedID, size: size)
    }
}

extension GardenSession {
    /// The state `GardenInteraction` reads.
    var interactionState: GardenInteraction.State {
        GardenInteraction.State(
            mode: mode,
            brushSeedID: brushSeedID,
            selectedEventID: selectedEventID,
            detailsPresented: detailsPresented
        )
    }

    /// Adopts a state the reducer returned, through the session's own transitions.
    func apply(_ state: GardenInteraction.State) {
        switch state.mode {
        case .moving(let eventID):
            if mode != state.mode { startMove(eventID: eventID) }
        case .painting:
            if let brush = state.brushSeedID, brush != brushSeedID || mode != .painting {
                startPainting(seedID: brush)
            }
        case .idle:
            endMove()
            if brushSeedID != nil { stopPainting() }
        }
        select(eventID: state.selectedEventID, presentDetails: state.detailsPresented)
    }

    /// Runs one input through the rules, adopts the new state and returns the effects to perform.
    func handle(_ input: GardenInteraction.Input, context: GardenInteraction.Context) -> [GardenInteraction.Effect] {
        let result = GardenInteraction.reduce(interactionState, input, context: context)
        apply(result.state)
        return result.effects
    }

    /// An events-list row, through the rules (`GardenInteraction.selectEventRow`); it needs no grid.
    func selectEventRow(eventID: String) {
        apply(GardenInteraction.selectEventRow(interactionState, eventID: eventID))
    }
}
