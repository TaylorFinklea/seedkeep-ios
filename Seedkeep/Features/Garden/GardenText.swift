import Foundation
import SeedkeepKit

/// The Garden grid's and events list's text, pure, so labels and status strings are tested.
enum GardenText {
    // MARK: - Names

    /// The kind's task name: "Sow", "Transplant", "Harvest" or "Note".
    static func kindName(_ kind: String) -> String {
        PlantingEventKind(rawValue: kind)?.displayName ?? kind.replacingOccurrences(of: "_", with: " ").capitalized
    }

    /// The event's subject: its seed's name, "Note" for a seedless note, otherwise "No seed".
    static func subject(seedName: String?, kind: String) -> String {
        if let seedName, !seedName.trimmingCharacters(in: .whitespaces).isEmpty { return seedName }
        return kind == PlantingEventKind.note.rawValue ? "Note" : "No seed"
    }

    /// A short mark for a cell: the initials of the first two words ("Cherokee Purple" → "CP"), or the
    /// first two letters of a one-word name ("Basil" → "Ba").
    static func abbreviation(_ name: String) -> String {
        let words = name.split(whereSeparator: { $0.isWhitespace || $0 == "-" }).filter { !$0.isEmpty }
        guard let first = words.first else { return "" }
        if words.count >= 2, let a = first.first, let b = words[1].first {
            return String(a).uppercased() + String(b).uppercased()
        }
        let letters = first.prefix(2)
        return letters.prefix(1).uppercased() + letters.dropFirst().lowercased()
    }

    // MARK: - Dates

    /// "May 4" in `locale`, or the raw text when it isn't a valid day.
    static func shortDay(_ ymd: String, locale: Locale = .current) -> String {
        format(ymd, template: "MMMd", locale: locale)
    }

    /// "May 4, 2026" in `locale`, or the raw text when it isn't a valid day.
    static func longDay(_ ymd: String, locale: Locale = .current) -> String {
        format(ymd, template: "yMMMd", locale: locale)
    }

    private static func format(_ ymd: String, template: String, locale: Locale) -> String {
        guard let day = CalendarDay.parse(ymd) else { return ymd }
        let formatter = DateFormatter()
        formatter.calendar = CalendarDay.utcCalendar
        formatter.timeZone = CalendarDay.utcCalendar.timeZone
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter.string(from: day.utcDate)
    }

    // MARK: - Status

    enum Status: Equatable, Sendable {
        case done
        case overdue(days: Int)
        case today
        case upcoming(days: Int)
        /// The planned date can't be read.
        case unknown

        var text: String {
            switch self {
            case .done: return "Done"
            case .overdue(let days): return days == 1 ? "1 day overdue" : "\(days) days overdue"
            case .today: return "Today"
            case .upcoming(let days): return days == 1 ? "In 1 day" : "In \(days) days"
            case .unknown: return "No date"
            }
        }

        /// Overdue rows carry a warn icon; the text says it too.
        var isWarning: Bool {
            if case .overdue = self { return true }
            return false
        }
    }

    static func status(plannedFor: String, isCompleted: Bool, today: CalendarDay) -> Status {
        if isCompleted { return .done }
        guard let day = CalendarDay.parse(plannedFor) else { return .unknown }
        let delta = today.days(to: day)
        if delta < 0 { return .overdue(days: -delta) }
        if delta == 0 { return .today }
        return .upcoming(days: delta)
    }

    // MARK: - Grid cells

    /// One cell's VoiceOver label: "Row R, square S", then the count when more than one, the shown
    /// event's subject, kind and date or "done", and "frost risk" when flagged. An empty square is
    /// "Row R, square S, empty".
    static func cellLabel(
        square: GridSquare,
        contents: SquareContents,
        seedName: (GridEvent) -> String?,
        locale: Locale = .current
    ) -> String {
        let position = GardenGrid.label(square)
        guard let shown = contents.shownEvent else { return "\(position), empty" }
        var parts = [position]
        if contents.events.count > 1 { parts.append("\(contents.events.count) plantings") }
        let name = seedName(shown)
        parts.append(subject(seedName: name, kind: shown.kind))
        // A seedless note already says "Note".
        if !(name == nil && shown.kind == PlantingEventKind.note.rawValue) {
            parts.append(kindName(shown.kind))
        }
        parts.append(shown.isCompleted ? "done" : longDay(shown.plannedFor, locale: locale))
        if contents.isFrostFlagged { parts.append(FrostCheck.accessibilityPhrase) }
        return parts.joined(separator: ", ")
    }

    /// The cell's hint: what activating it does in painting or moving mode. Nil when the square
    /// would only select (it blocks) or in idle mode.
    static func cellHint(
        mode: GardenSession.Mode,
        contents: SquareContents,
        brushSeedName: String?,
        movingSeedName: String?
    ) -> String? {
        switch mode {
        case .idle:
            return nil
        case .painting:
            guard !contents.blocksPainting, let brushSeedName else { return nil }
            return "Plans \(brushSeedName) here"
        case .moving(let eventID):
            // Activating the moving event's own square ends the move and writes nothing.
            guard !contents.events.contains(where: { $0.id == eventID }) else { return nil }
            let others = SquareContents(events: contents.events.filter { $0.id != eventID })
            guard !others.blocksPainting, let movingSeedName else { return nil }
            return "Moves \(movingSeedName) here"
        }
    }

    /// The Task picker's choices. A seedless event can only be a Note, so it is offered only Note (plus
    /// its current kind, so the picker can show it); an event with a seed is offered every kind.
    static func taskOptions(seedID: String?, current: String) -> [PlantingEventKind] {
        guard seedID == nil else { return PlantingEventKind.allCases }
        let currentKind = PlantingEventKind(rawValue: current)
        return PlantingEventKind.allCases.filter { $0 == .note || $0 == currentKind }
    }

    /// The move banner: "Tap an empty square to move <seed>".
    static func moveBanner(seedName: String) -> String {
        "Tap an empty square to move \(seedName)"
    }

    // MARK: - Events list

    /// The Square column: "R2 · S3", "Unplaced", "Outside the grid", or "No grid" for a bed without one.
    static func squareColumn(_ placement: GridPlacement) -> String {
        switch placement {
        case .square(let square): return GardenGrid.shortLabel(square)
        case .unplaced: return "Unplaced"
        case .outside: return "Outside the grid"
        case .noGrid: return "No grid"
        }
    }

    /// Details' position line: "Row R, square S", or the Square column's text off the grid.
    static func positionLine(_ placement: GridPlacement) -> String {
        if case .square(let square) = placement { return GardenGrid.label(square) }
        return squareColumn(placement)
    }

    /// "Spacing: 12 in", from the seed's own `plant_spacing_inches`; nil without one.
    static func spacing(inches: Int?) -> String? {
        guard let inches, inches > 0 else { return nil }
        return "Spacing: \(inches) in"
    }

    /// The first line of the notes, trimmed; nil when there are none.
    static func notesPreview(_ notes: String?) -> String? {
        guard let line = notes?
            .split(whereSeparator: \.isNewline)
            .map({ $0.trimmingCharacters(in: .whitespaces) })
            .first(where: { !$0.isEmpty }) else { return nil }
        return line
    }
}

/// One row of a bed's events list, as plain values.
struct BedEventRow: Identifiable, Equatable, Sendable {
    let id: String
    let plannedFor: String
    let kind: String
    let seedID: String?
    let isCompleted: Bool
    let subject: String
    let kindName: String
    let dateText: String
    let squareText: String
    let placement: GridPlacement
    let status: GardenText.Status
    let notesPreview: String?
    /// The frost sentence when the event is flagged.
    let frostSentence: String?

    /// Unplaced and outside rows can be placed. A bed with no grid has nothing to place on.
    var canPlace: Bool { placement == .unplaced || placement == .outside }

    /// VoiceOver for a whole row, frost sentence included.
    var accessibilityLabel: String {
        var parts = [subject, kindName, dateText, squareText, status.text]
        if let notesPreview { parts.append(notesPreview) }
        if let frostSentence { parts.append(frostSentence) }
        return parts.joined(separator: ", ")
    }

    /// Rows for a bed's live events, ordered by date and then id.
    static func rows(
        events: [GridEvent],
        bedID: String,
        size: GridSize?,
        seedNames: [String: String],
        notes: [String: String],
        frost: [String: FrostCheck.Outcome],
        today: CalendarDay,
        locale: Locale = .current
    ) -> [BedEventRow] {
        GardenGrid.ordered(events.filter { $0.bedID == bedID }).map { event in
            let placement = GardenGrid.placement(of: event, in: size)
            return BedEventRow(
                id: event.id,
                plannedFor: event.plannedFor,
                kind: event.kind,
                seedID: event.seedID,
                isCompleted: event.isCompleted,
                subject: GardenText.subject(seedName: event.seedID.flatMap { seedNames[$0] }, kind: event.kind),
                kindName: GardenText.kindName(event.kind),
                dateText: GardenText.longDay(event.plannedFor, locale: locale),
                squareText: GardenText.squareColumn(placement),
                placement: placement,
                status: GardenText.status(plannedFor: event.plannedFor, isCompleted: event.isCompleted, today: today),
                notesPreview: GardenText.notesPreview(notes[event.id]),
                frostSentence: frost[event.id].flatMap { FrostCheck.sentence(for: $0, locale: locale) }
            )
        }
    }
}
