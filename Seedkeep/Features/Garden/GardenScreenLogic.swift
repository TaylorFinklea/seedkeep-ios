import Foundation
import SwiftData
import SeedkeepKit

// The Garden screens' rules, pure, so the screens stay thin and the rules are tested: the New and Edit
// bed form, the bed switcher, the iPhone bed-list row, the legend, the add-a-bed prompt, the Plan
// handoff and "Place in bed".

// MARK: - New bed and Edit bed

/// The New bed and Edit bed form. Sizes are decimal text fields. A size must be finite and from 1 to
/// 50; a blank size means no grid. An edit sends only the fields that changed, and a size field the
/// user didn't touch is kept as stored, even a decimal, missing or over-50 one.
struct BedForm: Equatable, Sendable {
    /// The bed as stored, for an edit. Nil for a new bed.
    struct Stored: Equatable, Sendable {
        let name: String
        let description: String?
        let widthFeet: Double?
        let lengthFeet: Double?
    }

    enum Field: Equatable, Sendable {
        case width, length
    }

    /// A size field's outcome.
    enum Size: Equatable, Sendable {
        /// Not edited: nothing is sent, and the stored value stays.
        case unchanged
        /// A valid size, or nil (blank) for no grid.
        case value(Double?)
        /// Not valid; the message says why.
        case invalid(String)
    }

    static let newWidth = "4"
    static let newLength = "8"
    static let sizeRangeMessage = "Enter a size from 1 to 50 feet, or leave it blank for no grid."
    static let sizeClearMessage = "A size can't be removed once set. Enter a size from 1 to 50 feet."
    static let nameMessage = "Give the bed a name."

    let stored: Stored?
    var name: String
    var description: String
    var width: String
    var length: String

    /// A new bed: 4 × 8 feet.
    static func new() -> BedForm {
        BedForm(stored: nil, name: "", description: "", width: newWidth, length: newLength)
    }

    /// An existing bed, its fields as stored.
    static func edit(_ stored: Stored) -> BedForm {
        BedForm(
            stored: stored,
            name: stored.name,
            description: stored.description ?? "",
            width: stored.widthFeet.map(format) ?? "",
            length: stored.lengthFeet.map(format) ?? ""
        )
    }

    var isNew: Bool { stored == nil }

    /// Feet as the field shows them: "4", "4.5". The text only needs to be stable, so an untouched
    /// field reads as unchanged.
    static func format(_ feet: Double) -> String {
        if feet.isFinite, feet == feet.rounded(), abs(feet) < 1e15 { return String(Int(feet)) }
        return String(feet)
    }

    /// Parses a size field: blank is nil, otherwise a finite size from 1 to 50 (a comma works as the
    /// decimal separator). Returns `.invalid` for anything else.
    static func parse(_ text: String) -> Size {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .value(nil) }
        guard let feet = Double(trimmed.replacingOccurrences(of: ",", with: ".")),
              feet.isFinite, feet >= 1, feet <= GardenGrid.maxDimension else {
            return .invalid(sizeRangeMessage)
        }
        return .value(feet)
    }

    func size(_ field: Field) -> Size {
        let text = field == .width ? width : length
        guard let stored else { return Self.parse(text) }
        let storedValue = field == .width ? stored.widthFeet : stored.lengthFeet
        let storedText = storedValue.map(Self.format) ?? ""
        // Untouched: kept as stored, whatever it is.
        if text.trimmingCharacters(in: .whitespacesAndNewlines) == storedText { return .unchanged }
        let parsed = Self.parse(text)
        // The bed's update has no explicit null, so a stored size can't be cleared.
        if case .value(nil) = parsed, storedValue != nil { return .invalid(Self.sizeClearMessage) }
        if case .value(let feet) = parsed, feet == storedValue { return .unchanged }
        return parsed
    }

    var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    var trimmedDescription: String { description.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The message for a field, or nil when it is fine.
    func message(_ field: Field) -> String? {
        if case .invalid(let message) = size(field) { return message }
        return nil
    }

    var canSave: Bool {
        !trimmedName.isEmpty && message(.width) == nil && message(.length) == nil
    }

    /// The create input for a new bed, or nil when the form can't be saved.
    var createInput: SeedkeepClient.CreateBedInput? {
        guard isNew, canSave,
              case .value(let width) = size(.width), case .value(let length) = size(.length) else { return nil }
        return SeedkeepClient.CreateBedInput(
            name: trimmedName,
            description: trimmedDescription.isEmpty ? nil : trimmedDescription,
            width_feet: width,
            length_feet: length
        )
    }

    /// The update for an edit with only the changed fields, or nil when nothing changed or the form
    /// can't be saved.
    var updateInput: SeedkeepClient.UpdateBedInput? {
        guard let stored, canSave else { return nil }
        var input = SeedkeepClient.UpdateBedInput()
        var changed = false
        if trimmedName != stored.name.trimmingCharacters(in: .whitespacesAndNewlines) {
            input.name = trimmedName
            changed = true
        }
        if trimmedDescription != (stored.description ?? "").trimmingCharacters(in: .whitespacesAndNewlines) {
            // Blank clears the description (the update has no explicit null).
            input.description = trimmedDescription
            changed = true
        }
        if case .value(let width?) = size(.width) {
            input.width_feet = width
            changed = true
        }
        if case .value(let length?) = size(.length) {
            input.length_feet = length
            changed = true
        }
        return changed ? input : nil
    }
}

/// Bed writes through the existing `SyncEngine` bed enqueue methods. Before an edit or a delete it
/// re-checks against the store that the garden is still the one the editor opened in and the bed is
/// still live in it; a stale write is refused, not sent.
@MainActor
enum BedFormWriter {
    static let bedDeletedMessage = "This bed was deleted. Nothing was saved."

    /// Creates the bed. Returns its choice for Plan, or nil when the form can't be saved.
    static func create(_ form: BedForm, sync: SyncEngine, householdID: String) throws -> GardenSession.BedChoice? {
        guard let input = form.createInput else { return nil }
        let bed = try sync.enqueueCreateBed(input, householdID: householdID)
        return GardenSession.BedChoice(bed)
    }

    /// Sends the changed fields. `scope` is the garden and bed the editor opened in;
    /// `currentHouseholdID` is the live garden scope. `.unchanged` when nothing changed.
    @discardableResult
    static func update(
        _ form: BedForm,
        scope: GardenActions.Scope,
        currentHouseholdID: String?,
        sync: SyncEngine,
        container: ModelContainer
    ) throws -> GardenActions.Outcome {
        if let refusal = check(scope: scope, currentHouseholdID: currentHouseholdID, container: container) {
            return refusal
        }
        guard let input = form.updateInput else { return .unchanged }
        try sync.enqueueUpdateBed(id: scope.bedID, input)
        return .written
    }

    /// Deletes the bed (a tombstone and a pending delete), after the same checks as an edit.
    @discardableResult
    static func delete(
        scope: GardenActions.Scope,
        currentHouseholdID: String?,
        sync: SyncEngine,
        container: ModelContainer
    ) throws -> GardenActions.Outcome {
        if let refusal = check(scope: scope, currentHouseholdID: currentHouseholdID, container: container) {
            return refusal
        }
        try sync.enqueueDeleteBed(id: scope.bedID)
        return .written
    }

    /// The garden is still the editor's, and the bed is live and in it (read from a fresh context).
    private static func check(
        scope: GardenActions.Scope,
        currentHouseholdID: String?,
        container: ModelContainer
    ) -> GardenActions.Outcome? {
        guard currentHouseholdID == scope.householdID else { return .refused(GardenActions.scopeChangedMessage) }
        let bedID = scope.bedID
        let bed = try? ModelContext(container).fetch(
            FetchDescriptor<LocalBed>(predicate: #Predicate { $0.id == bedID })
        ).first
        guard let bed, bed.deletedAt == nil, bed.householdID == scope.householdID else {
            return .refused(bedDeletedMessage)
        }
        return nil
    }
}

// MARK: - Bed switcher

/// The iPad and Mac bed switcher: segmented up to five beds, otherwise a menu.
enum BedSwitcherStyle: Equatable, Sendable {
    case none
    case segmented
    case menu

    static let segmentedLimit = 5

    static func choose(bedCount: Int) -> BedSwitcherStyle {
        if bedCount <= 0 { return .none }
        return bedCount <= segmentedLimit ? .segmented : .menu
    }
}

// MARK: - iPhone bed list

/// One row of the iPhone bed list: the name, the size, the next event and the frost count.
struct GardenBedListRow: Equatable, Sendable {
    let name: String
    let sizeText: String
    let nextEventText: String
    /// "1 frost risk" / "3 frost risks", or nil with none.
    let frostText: String?

    /// "4 × 8 ft", "4 ft wide", "8 ft long", or "No size".
    static func sizeText(widthFeet: Double?, lengthFeet: Double?) -> String {
        func valid(_ feet: Double?) -> Double? {
            guard let feet, feet.isFinite, feet > 0 else { return nil }
            return feet
        }
        switch (valid(widthFeet), valid(lengthFeet)) {
        case let (width?, length?): return "\(BedForm.format(width)) × \(BedForm.format(length)) ft"
        case let (width?, nil): return "\(BedForm.format(width)) ft wide"
        case let (nil, length?): return "\(BedForm.format(length)) ft long"
        default: return "No size"
        }
    }

    /// `events` are the bed's live events with their frost flags; `seedNames` by seed id.
    static func make(
        name: String,
        widthFeet: Double?,
        lengthFeet: Double?,
        events: [GridEvent],
        seedNames: [String: String],
        locale: Locale = .current
    ) -> GardenBedListRow {
        let open = GardenGrid.ordered(events.filter { !$0.isCompleted })
        let nextText: String
        if let next = open.first {
            let name = next.seedID.flatMap { seedNames[$0] }
            let subject = GardenText.subject(seedName: name, kind: next.kind)
            let kind = GardenText.kindName(next.kind)
            // A seedless note already says "Note".
            let what = subject == kind ? kind : "\(kind) \(subject)"
            nextText = "Next: \(what), \(GardenText.shortDay(next.plannedFor, locale: locale))"
        } else {
            nextText = "No upcoming events"
        }
        let frost = open.filter(\.isFrostFlagged).count
        return GardenBedListRow(
            name: name,
            sizeText: sizeText(widthFeet: widthFeet, lengthFeet: lengthFeet),
            nextEventText: nextText,
            frostText: frost == 0 ? nil : (frost == 1 ? "1 frost risk" : "\(frost) frost risks")
        )
    }

    var accessibilityLabel: String {
        [name, sizeText, nextEventText, frostText].compactMap { $0 }.joined(separator: ", ")
    }
}

// MARK: - Legend

enum GardenLegend {
    enum Mark: Equatable, Sendable {
        /// A square filled with a kind's colour (`PlantingEventKind` raw value; "note" also stands for done).
        case swatch(kind: String)
        /// The frost glyph.
        case frost
    }

    struct Item: Equatable, Sendable, Identifiable {
        let title: String
        let mark: Mark
        var id: String { title }
    }

    static let items: [Item] = [
        Item(title: "Sow", mark: .swatch(kind: PlantingEventKind.sowing.rawValue)),
        Item(title: "Transplant", mark: .swatch(kind: PlantingEventKind.transplant.rawValue)),
        Item(title: "Harvest", mark: .swatch(kind: PlantingEventKind.harvest.rawValue)),
        Item(title: "Done", mark: .swatch(kind: PlantingEventKind.note.rawValue)),
        Item(title: "Frost risk (estimate)", mark: .frost),
    ]

    static let scale = "1 square = 1 sq ft"
}

// MARK: - The bar above the grid

/// What shows above a Garden screen's content while a brush or move is active.
enum GardenBanner: Equatable, Sendable {
    case none
    /// The Stop or Cancel bar, whenever a brush or move is active and some bed has a grid: over any
    /// bed or the bed list, so Stop stays reachable after switching away from a grid bed.
    case modeBar
    /// "Add a bed with a size to plan" with New bed: a brush is set but no live bed has a grid.
    case addBedPrompt

    static let promptTitle = "Add a bed with a size to plan"

    /// With a brush and no bed with a grid, the add-a-bed prompt shows instead of the Stop bar.
    static func choose(
        mode: GardenSession.Mode,
        brushSeedID: String?,
        gridBedCount: Int
    ) -> GardenBanner {
        if brushSeedID != nil, gridBedCount == 0 { return .addBedPrompt }
        return mode == .idle ? .none : .modeBar
    }
}

// MARK: - Plan handoff

@MainActor
enum GardenPlanHandoff {
    /// A Garden screen takes the waiting Plan (on appear, whenever it changes, and whenever the grid
    /// beds change, in both shells). It returns the Plan to open once its bed is in `gridBedIDs`, and
    /// takes it then. A Plan whose bed isn't there (yet: a new bed may not be in the query) stays
    /// waiting; the reconciler drops a Plan whose bed is gone or has no grid. The brush is set to the
    /// Plan's seed.
    static func take(from session: GardenSession, gridBedIDs: Set<String>) -> GardenSession.PendingPlan? {
        guard let waiting = session.pendingPlan, gridBedIDs.contains(waiting.bedID),
              let plan = session.takePendingPlan() else { return nil }
        if session.brushSeedID != plan.seedID || !session.isPainting {
            session.startPainting(seedID: plan.seedID)
        }
        session.showBed(plan.bedID)
        return plan
    }

    /// After New bed from the add-a-bed prompt: the seed to plan again, when the brush is still set
    /// and the new bed has a grid. Nil otherwise.
    static func seedToResume(brushSeedID: String?, created: GardenSession.BedChoice?) -> String? {
        guard let brushSeedID, let created, created.hasGrid else { return nil }
        return brushSeedID
    }

    /// Plans the brush seed again with the new bed included (it may not be in the query yet).
    @discardableResult
    static func resume(
        session: GardenSession,
        created: GardenSession.BedChoice?,
        beds: [GardenSession.BedChoice]
    ) -> GardenSession.PlanResult? {
        guard let seedID = seedToResume(brushSeedID: session.brushSeedID, created: created),
              let created else { return nil }
        let all = beds.contains { $0.id == created.id } ? beds : beds + [created]
        return session.plan(seedID: seedID, isActive: true, beds: all)
    }
}

// MARK: - Place in bed

/// "Place in bed" in Add Planting: a square picked on the bed's grid is written as its centre.
enum PlaceInBed {
    /// The coordinates to write: the picked square's centre on the bed's grid, or nil when nothing is
    /// picked, the bed has no grid, or the square isn't on it.
    static func coordinates(square: GridSquare?, widthFeet: Double?, lengthFeet: Double?) -> (x: Double, y: Double)? {
        guard let square, let size = GardenGrid.size(widthFeet: widthFeet, lengthFeet: lengthFeet),
              GardenGrid.contains(square, in: size) else { return nil }
        return GardenGrid.centre(of: square, in: size)
    }

    /// The new planting's input: placed at the picked square's centre (`square` is nil when "Place in
    /// bed" is off), otherwise unplaced.
    static func createInput(
        bedID: String?,
        seedID: String?,
        kind: PlantingEventKind,
        plannedFor: String,
        notes: String?,
        square: GridSquare?,
        widthFeet: Double?,
        lengthFeet: Double?
    ) -> SeedkeepClient.CreatePlantingEventInput {
        let position = coordinates(square: square, widthFeet: widthFeet, lengthFeet: lengthFeet)
        return SeedkeepClient.CreatePlantingEventInput(
            bed_id: bedID,
            seed_id: seedID,
            catalog_seed_id: nil,
            kind: kind,
            planned_for: plannedFor,
            completed_at: nil,
            notes: notes,
            x_feet: position?.x,
            y_feet: position?.y
        )
    }
}
