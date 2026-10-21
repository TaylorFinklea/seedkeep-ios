import SwiftUI
import SwiftData
import SeedkeepKit

/// The selected event's details: the inspector's content on iPad and Mac, the sheet's on iPhone (the
/// container is the screen's). Lists every event in the selected event's square, edits the selected
/// one field by field through `GardenActions`, starts a move, and deletes with confirmation. Reads
/// the store live, so a remote change updates it, and a deleted event clears the selection. Notes go
/// through `NotesDraft`, so a commit only ever writes the draft's own event, and only after an edit.
struct SquareDetails: View {
    let bedID: String
    let session: GardenSession
    let actions: GardenActions
    let climate: HomeClimate?
    /// Opens a seed (the seed link).
    let onOpenSeed: (String) -> Void
    /// After a delete: the square the event was in, so the screen can return focus to it.
    let onDeleted: (GridSquare?) -> Void
    /// A refusal or failure to show; it is also announced to VoiceOver.
    let onMessage: (String) -> Void
    let onError: (Error) -> Void

    @Query private var beds: [LocalBed]
    @Query private var events: [LocalPlantingEvent]
    @Query private var seeds: [LocalSeed]

    @State private var notesDraft = NotesDraft()
    /// The event (and its square) the open delete confirmation is for, captured when it opens.
    @State private var confirmingDelete: PendingDelete?
    @FocusState private var notesFocused: Bool

    private struct PendingDelete: Equatable {
        let eventID: String
        let square: GridSquare?
    }

    static let deleteTitle = "Delete this planting?"
    static let deleteMessage = "Deletes this planting, with its notes and done state, for everyone in this garden. "
        + "Journal entries and other plantings in the square stay."

    init(
        bedID: String,
        session: GardenSession,
        actions: GardenActions,
        climate: HomeClimate?,
        onOpenSeed: @escaping (String) -> Void,
        onDeleted: @escaping (GridSquare?) -> Void,
        onMessage: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) {
        self.bedID = bedID
        self.session = session
        self.actions = actions
        self.climate = climate
        self.onOpenSeed = onOpenSeed
        self.onDeleted = onDeleted
        self.onMessage = onMessage
        self.onError = onError
        let id = bedID
        _beds = Query(filter: #Predicate<LocalBed> { $0.id == id && $0.deletedAt == nil })
        _events = Query(filter: #Predicate<LocalPlantingEvent> { $0.bedID == id && $0.deletedAt == nil })
        let household = actions.scope.householdID
        _seeds = Query(filter: #Predicate<LocalSeed> { $0.deletedAt == nil && $0.householdID == household })
    }

    var body: some View {
        // Built once per pass (it runs FrostCheck for every event) and passed down.
        let data = beds.first.map { GardenBedData(bed: $0, events: events, seeds: seeds, climate: climate) }
        Group {
            if let data, let event = data.event(session.selectedEventID) {
                form(data: data, event: event)
            } else {
                WBEmptyState(
                    title: "No planting selected",
                    message: "Select a square or a planting to see its details.",
                    systemImage: "square.grid.3x3"
                )
            }
        }
        .onChange(of: data?.event(session.selectedEventID) == nil) { _, isGone in
            // The selected event was deleted (here or remotely): close details.
            if isGone, session.selectedEventID != nil { session.clearSelection() }
        }
        .accessibilityIdentifier("garden.squareDetails")
    }

    @ViewBuilder
    private func form(data: GardenBedData, event: GridEvent) -> some View {
        let placement = GardenGrid.placement(of: event, in: data.size)
        let square: GridSquare? = { if case .square(let s) = placement { return s } else { return nil } }()
        let inSquare = square.flatMap { s in data.size.map { GardenGrid.contents(of: s, events: data.events, bedID: bedID, size: $0) } }
        let subject = GardenText.subject(seedName: data.seedName(event), kind: event.kind)
        Form {
            if let inSquare, inSquare.events.count > 1 {
                Section {
                    ForEach(inSquare.events) { item in
                        squareRow(item, data: data, selected: item.id == event.id)
                    }
                } header: {
                    WBSectionHeader("In this square")
                }
            }
            Section {
                seedLine(event: event, subject: subject, data: data)
                LabeledContent("Square", value: GardenText.positionLine(placement))
                if let spacing = event.seedID.flatMap({ data.spacingInches[$0] }).flatMap(GardenText.spacing(inches:)) {
                    Text(spacing)
                        .font(.wbFootnote)
                        .foregroundStyle(WBColor.muted)
                }
                Picker("Task", selection: kindBinding(event)) {
                    ForEach(GardenText.taskOptions(seedID: event.seedID, current: event.kind)) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                DatePicker("Date", selection: dateBinding(event), displayedComponents: .date)
                Toggle("Done", isOn: doneBinding(event))
                TextField("Notes", text: notesText, axis: .vertical)
                    .lineLimit(3...8)
                    .focused($notesFocused)
                    .onSubmit { commitNotes() }
                    .accessibilityIdentifier("garden.squareDetails.notes")
                if case .flagged = data.frost[event.id], let sentence = data.frost[event.id].flatMap({ FrostCheck.sentence(for: $0) }) {
                    frostLine(sentence)
                }
            } header: {
                WBSectionHeader(subject)
            }
            Section {
                if placement != .noGrid {
                    Button(square == nil ? "Place" : "Move") {
                        commitNotes()
                        session.startMove(eventID: event.id)
                    }
                    .accessibilityIdentifier("garden.squareDetails.move")
                }
                Button("Delete planting…", role: .destructive) {
                    confirmingDelete = PendingDelete(eventID: event.id, square: square)
                }
                .accessibilityIdentifier("garden.squareDetails.delete")
            }
        }
        .scrollContentBackground(.hidden)
        .background(WBColor.bg)
        // SwiftUI doesn't order these handlers, so none of them relies on another having run: the draft
        // carries its own event id, commits only to it and only after an edit, and ignores another
        // event's stored notes.
        .onAppear { loadNotes(eventID: event.id, stored: data.notes[event.id]) }
        .onChange(of: event.id) { _, newID in
            loadNotes(eventID: newID, stored: data.notes[newID])
        }
        .onChange(of: data.notes[event.id]) { _, stored in
            // A remote edit replaces the draft unless the user has edited it.
            notesDraft.remoteChanged(eventID: event.id, stored: stored)
        }
        .onChange(of: notesFocused) { _, focused in
            if !focused { commitNotes() }
        }
        .onDisappear { commitNotes() }
        .confirmationDialog(
            Self.deleteTitle,
            isPresented: Binding(
                get: { confirmingDelete != nil },
                set: { if !$0 { confirmingDelete = nil } }
            ),
            titleVisibility: .visible,
            presenting: confirmingDelete
        ) { pending in
            Button("Delete planting", role: .destructive) {
                delete(pending.eventID, square: pending.square)
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text(Self.deleteMessage)
        }
    }

    @ViewBuilder
    private func seedLine(event: GridEvent, subject: String, data: GardenBedData) -> some View {
        if let seedID = event.seedID, data.seedNames[seedID] != nil {
            Button {
                onOpenSeed(seedID)
            } label: {
                LabeledContent("Seed") {
                    Text(subject).foregroundStyle(WBColor.accent)
                }
            }
            .accessibilityHint("Opens the seed")
        } else {
            LabeledContent("Seed", value: subject)
        }
    }

    private func squareRow(_ item: GridEvent, data: GardenBedData, selected: Bool) -> some View {
        let subject = GardenText.subject(seedName: data.seedName(item), kind: item.kind)
        let detail = item.isCompleted ? "done" : GardenText.longDay(item.plannedFor)
        return Button {
            session.selectEventRow(eventID: item.id)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(subject).font(.wbBody).foregroundStyle(WBColor.ink)
                    Text("\(GardenText.kindName(item.kind)) · \(detail)")
                        .font(.wbFootnote)
                        .foregroundStyle(WBColor.muted)
                }
                Spacer()
                if selected {
                    Image(systemName: "checkmark").foregroundStyle(WBColor.accent).accessibilityHidden(true)
                }
            }
            .frame(minHeight: WBMetrics.minTouchTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(subject), \(GardenText.kindName(item.kind)), \(detail)")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private func frostLine(_ sentence: String) -> some View {
        HStack(alignment: .top, spacing: WBMetrics.gap) {
            Image(systemName: "snowflake")
                .foregroundStyle(WBColor.warn)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(sentence).font(.wbFootnote).foregroundStyle(WBColor.ink)
                Text(FrostCheck.estimateNote).font(.wbFootnote).foregroundStyle(WBColor.muted)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Bindings (each commits one field)

    private var notesText: Binding<String> {
        Binding(get: { notesDraft.text }, set: { notesDraft.edit($0) })
    }

    private func kindBinding(_ event: GridEvent) -> Binding<PlantingEventKind> {
        Binding(
            get: { PlantingEventKind(rawValue: event.kind) ?? .note },
            set: { kind in run { try actions.setKind(kind, eventID: event.id) } }
        )
    }

    private func dateBinding(_ event: GridEvent) -> Binding<Date> {
        Binding(
            get: { Self.localDate(event.plannedFor) },
            set: { date in run { try actions.setPlannedFor(CalendarDay.today(now: date), eventID: event.id) } }
        )
    }

    private func doneBinding(_ event: GridEvent) -> Binding<Bool> {
        Binding(
            get: { event.isCompleted },
            set: { done in run { try actions.setDone(done, eventID: event.id) } }
        )
    }

    /// Midnight of the planned day in the device's calendar, for the date picker.
    static func localDate(_ ymd: String, calendar: Calendar = .current) -> Date {
        guard let day = CalendarDay.parse(ymd) else { return Date() }
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        return gregorian.date(from: DateComponents(year: day.year, month: day.month, day: day.day)) ?? Date()
    }

    // MARK: - Writes

    /// Writes each edited draft to its own event. `setNotes` re-checks the event.
    private func commitNotes() {
        for pending in notesDraft.pendingWrites {
            do {
                let outcome = try actions.setNotes(pending.text, eventID: pending.eventID)
                if case .refused(let message) = outcome {
                    onMessage(message)
                    GardenAnnouncer.announce(message)
                }
                // Written, unchanged, or refused because the event or bed is gone: nothing to retry.
                notesDraft.markSaved(eventID: pending.eventID, text: pending.text)
            } catch {
                // Not saved: the edit stays pending (across a selection change too), so the next
                // blur, switch or close retries it.
                onError(error)
                return
            }
        }
    }

    /// Commits the current draft, then starts one for `eventID`.
    private func loadNotes(eventID: String, stored: String?) {
        guard notesDraft.eventID != eventID else { return }
        commitNotes()
        notesDraft.load(eventID: eventID, stored: stored)
    }

    private func delete(_ eventID: String, square: GridSquare?) {
        run {
            let outcome = try actions.delete(eventID: eventID)
            if outcome == .written {
                session.clearSelection()
                onDeleted(square)
            }
            return outcome
        }
    }

    private func run(_ write: () throws -> GardenActions.Outcome) {
        do {
            if case .refused(let message) = try write() {
                onMessage(message)
                GardenAnnouncer.announce(message)
            }
        } catch {
            onError(error)
        }
    }
}

/// The notes field's draft, pure. It belongs to one event: a commit writes only that event, and only
/// when the text was edited away from the stored notes it loaded (the baseline). A remote change
/// replaces an unedited draft and leaves an edited one alone; another event's notes never touch it.
struct NotesDraft: Equatable, Sendable {
    private(set) var eventID: String?
    /// The stored notes the draft was loaded from, or last committed.
    private(set) var baseline = ""
    private(set) var text = ""
    /// Edits whose save failed before the selection moved on, by event id. They are retried with
    /// every commit and come back when their event is shown again.
    private(set) var unsaved: [String: String] = [:]

    var isDirty: Bool { text != baseline }

    /// Starts a draft for `eventID` from its stored notes. Commit the old draft first; if it is still
    /// edited (its save failed), it is kept in `unsaved` rather than lost.
    mutating func load(eventID: String, stored: String?) {
        if let current = self.eventID, isDirty { unsaved[current] = text }
        self.eventID = eventID
        baseline = stored ?? ""
        text = unsaved.removeValue(forKey: eventID) ?? baseline
    }

    /// The user typed.
    mutating func edit(_ text: String) {
        self.text = text
    }

    /// The stored notes of `eventID` changed (a remote edit or this draft's own commit). They replace
    /// the draft only when it is this event's and unedited.
    mutating func remoteChanged(eventID: String, stored: String?) {
        guard eventID == self.eventID, !isDirty else { return }
        baseline = stored ?? ""
        text = baseline
    }

    /// The write to make, if the draft was edited: its event and text. It stays pending until
    /// `markSaved`, so a failed save is retried on the next commit.
    var pending: (eventID: String, text: String)? {
        guard let eventID, isDirty else { return nil }
        return (eventID, text)
    }

    /// Every write still owed: this draft's edit, then edits of other events whose save failed before
    /// the selection moved on, by event id.
    var pendingWrites: [(eventID: String, text: String)] {
        var writes = pending.map { [$0] } ?? []
        for (id, text) in unsaved.sorted(by: { $0.key < $1.key }) where id != eventID {
            writes.append((id, text))
        }
        return writes
    }

    /// The store took (or no longer needs) a write: its text becomes the baseline, so the same edit
    /// is never written twice.
    mutating func markSaved(eventID: String, text: String) {
        if unsaved[eventID] == text { unsaved[eventID] = nil }
        guard eventID == self.eventID else { return }
        baseline = text
    }
}
