import Foundation

/// The Garden grid's interaction rules, pure: a reducer over the session's state and the squares'
/// contents. It returns the next state and the effects to perform; `GardenActions` performs them and
/// `GardenSession.apply(_:)` adopts the state.
enum GardenInteraction {
    /// The part of `GardenSession` the rules read and change.
    struct State: Equatable, Sendable {
        var mode: GardenSession.Mode = .idle
        var brushSeedID: String?
        var selectedEventID: String?
        var detailsPresented = false
    }

    /// One square step on the grid. Up is toward the top row (y grows up).
    enum Direction: String, CaseIterable, Sendable {
        case left, right, up, down

        /// "Move left", the accessibility action's name.
        var actionName: String { "Move \(rawValue)" }

        func step(_ square: GridSquare) -> GridSquare {
            switch self {
            case .left: return GridSquare(column: square.column - 1, rowFromTop: square.rowFromTop)
            case .right: return GridSquare(column: square.column + 1, rowFromTop: square.rowFromTop)
            case .up: return GridSquare(column: square.column, rowFromTop: square.rowFromTop - 1)
            case .down: return GridSquare(column: square.column, rowFromTop: square.rowFromTop + 1)
            }
        }
    }

    /// A position in feet from the bed's bottom-left corner.
    struct Point: Equatable, Hashable, Sendable {
        let x: Double
        let y: Double
    }

    enum Input: Equatable, Sendable {
        /// A tap, click, Space or Return on a square.
        case activate(GridSquare)
        /// A row in an events list.
        case selectEventRow(eventID: String)
        /// The Stop bar's Details button: opens the selected event.
        case showDetails
        case closeDetails
        /// Escape or Cancel.
        case cancel
        /// Details' Move, or a list row's Place: the next activated square receives the event.
        case startMove(eventID: String)
        /// An accessibility Move action on the selected event: one square in `direction`.
        case moveSelected(Direction)
    }

    enum Effect: Equatable, Sendable {
        /// Plan `seedID` as a sowing at `position` (the square's centre) on `plannedFor`.
        case createSowing(seedID: String, square: GridSquare, position: Point, plannedFor: CalendarDay)
        /// Move an event. `from` is the position the rules saw, so a write can check it is still current;
        /// both coordinates are always sent.
        case move(eventID: String, from: Point?, to: Point, square: GridSquare)
        /// Refused; tell the user (VoiceOver announcement and visible message).
        case refuse(String)
    }

    struct Result: Equatable, Sendable {
        var state: State
        var effects: [Effect] = []
    }

    /// What the rules read besides the state.
    struct Context: Sendable {
        let size: GridSize
        /// Every occupied square's contents (`GardenGrid.squares`). A missing square is empty.
        let squares: [GridSquare: SquareContents]
        /// The day a painted event gets (`GardenGrid.planDate` for the brush seed).
        let planDate: CalendarDay
        /// Every live event of the bed, on the grid or not, so a move can find its event.
        let events: [GridEvent]

        init(size: GridSize, events: [GridEvent], bedID: String, planDate: CalendarDay) {
            self.size = size
            self.events = events.filter { $0.bedID == bedID }
            self.squares = GardenGrid.squares(events: events, bedID: bedID, size: size)
            self.planDate = planDate
        }

        func contents(_ square: GridSquare) -> SquareContents { squares[square] ?? .empty }

        /// The square's contents without `eventID`, so an event never blocks itself.
        func contents(_ square: GridSquare, excluding eventID: String) -> SquareContents {
            SquareContents(events: contents(square).events.filter { $0.id != eventID })
        }

        func event(_ id: String) -> GridEvent? { events.first { $0.id == id } }
    }

    // MARK: - Messages

    static func occupiedMessage(_ square: GridSquare) -> String {
        "\(GardenGrid.label(square)) already has a planting."
    }

    static let outsideMessage = "That square is outside the bed."

    // MARK: - Reducer

    static func reduce(_ state: State, _ input: Input, context: Context) -> Result {
        var next = state
        switch input {
        case .activate(let square):
            return activate(square, state: state, context: context)

        case .selectEventRow(let eventID):
            return Result(state: selectEventRow(state, eventID: eventID))

        case .showDetails:
            next.detailsPresented = state.selectedEventID != nil
            return Result(state: next)

        case .closeDetails:
            next.detailsPresented = false
            return Result(state: next)

        case .cancel:
            // The details editor, then move mode, then the brush, then the selection.
            if state.detailsPresented {
                next.detailsPresented = false
            } else if case .moving = state.mode {
                next.mode = .idle
            } else if state.brushSeedID != nil {
                next.brushSeedID = nil
                if state.mode == .painting { next.mode = .idle }
            } else {
                next.selectedEventID = nil
            }
            return Result(state: next)

        case .startMove(let eventID):
            // Moving takes precedence over painting: the brush goes and details close.
            next.brushSeedID = nil
            next.selectedEventID = eventID
            next.detailsPresented = false
            next.mode = .moving(eventID: eventID)
            return Result(state: next)

        case .moveSelected(let direction):
            guard let eventID = state.selectedEventID, let event = context.event(eventID),
                  case .square(let from) = GardenGrid.placement(of: event, in: context.size) else {
                return Result(state: state)
            }
            let target = direction.step(from)
            guard GardenGrid.contains(target, in: context.size) else {
                return Result(state: state, effects: [.refuse(outsideMessage)])
            }
            guard !context.contents(target, excluding: eventID).blocksPainting else {
                return Result(state: state, effects: [.refuse(occupiedMessage(target))])
            }
            // Only the moving axis changes; the other keeps its stored value. Both are sent.
            let centre = GardenGrid.centre(of: target, in: context.size)
            let oldX = event.x ?? centre.x, oldY = event.y ?? centre.y
            let to: Point
            switch direction {
            case .left, .right: to = Point(x: centre.x, y: oldY)
            case .up, .down: to = Point(x: oldX, y: centre.y)
            }
            return Result(state: state, effects: [
                .move(eventID: eventID, from: Point(x: oldX, y: oldY), to: to, square: target),
            ])
        }
    }

    /// A row in an events list: selects its event and opens details. Selecting a different event while
    /// moving ends the move, so the selection never disagrees with the moving event; selecting the
    /// moving event itself keeps the move and leaves details closed, so a sheet never covers the grid
    /// mid-move. Reads no context, so list rows can run it without a grid.
    static func selectEventRow(_ state: State, eventID: String) -> State {
        var next = state
        if case .moving(let moving) = state.mode {
            if moving == eventID { return state }
            next.mode = .idle
        }
        next.selectedEventID = eventID
        next.detailsPresented = true
        return next
    }

    private static func activate(_ square: GridSquare, state: State, context: Context) -> Result {
        var next = state
        guard GardenGrid.contains(square, in: context.size) else {
            return Result(state: state, effects: [.refuse(outsideMessage)])
        }
        let contents = context.contents(square)
        switch state.mode {
        case .painting:
            if contents.blocksPainting {
                next.selectedEventID = contents.shownEvent?.id
                next.detailsPresented = false
                return Result(state: next)
            }
            guard let seedID = state.brushSeedID else { return Result(state: state) }
            let centre = GardenGrid.centre(of: square, in: context.size)
            next.detailsPresented = false
            return Result(state: next, effects: [
                .createSowing(seedID: seedID, square: square, position: Point(x: centre.x, y: centre.y),
                              plannedFor: context.planDate),
            ])

        case .idle:
            if let shown = contents.shownEvent {
                next.selectedEventID = shown.id
                next.detailsPresented = true
            } else {
                next.selectedEventID = nil
                next.detailsPresented = false
            }
            return Result(state: next)

        case .moving(let eventID):
            guard let event = context.event(eventID) else {
                // The event is gone: end the move and drop its selection.
                next.mode = .idle
                if next.selectedEventID == eventID {
                    next.selectedEventID = nil
                    next.detailsPresented = false
                }
                return Result(state: next)
            }
            let placement = GardenGrid.placement(of: event, in: context.size)
            if placement == .square(square) {
                // Its own square: nothing to move, nothing written.
                next.mode = .idle
                return Result(state: next)
            }
            guard !context.contents(square, excluding: eventID).blocksPainting else {
                return Result(state: state, effects: [.refuse(occupiedMessage(square))])
            }
            let centre = GardenGrid.centre(of: square, in: context.size)
            let from = event.x.flatMap { x in event.y.map { Point(x: x, y: $0) } }
            next.mode = .idle
            next.selectedEventID = eventID
            next.detailsPresented = false
            return Result(state: next, effects: [
                .move(eventID: eventID, from: from, to: Point(x: centre.x, y: centre.y), square: square),
            ])
        }
    }
}
