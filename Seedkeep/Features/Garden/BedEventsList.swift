import SwiftUI
import SwiftData
import SeedkeepKit

/// A bed's events: a `Table` on regular width (iPad and Mac), a `List` on compact. Columns are Done,
/// Date, Task, Seed, Square, Status and Notes; rows are ordered by date and then id. Selecting a row
/// selects its event and opens details. Unplaced and outside rows have "Place", which starts a move.
/// `embedded` renders the compact rows without their own `List`, for a parent `List` (the iPhone bed
/// screen), at any size class.
struct BedEventsList: View {
    enum Rows {
        /// Every live event of the bed.
        case all
        /// Only the unplaced and outside ones (and, for a bed without a grid, all of them).
        case offGrid
    }

    let bedID: String
    let rowsShown: Rows
    let embedded: Bool
    let session: GardenSession
    let actions: GardenActions
    let climate: HomeClimate?
    let today: CalendarDay
    let onMessage: (String) -> Void
    let onError: (Error) -> Void

    @Query private var beds: [LocalBed]
    @Query private var events: [LocalPlantingEvent]
    @Query private var seeds: [LocalSeed]
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    init(
        bedID: String,
        rows: Rows = .all,
        embedded: Bool = false,
        session: GardenSession,
        actions: GardenActions,
        climate: HomeClimate?,
        today: CalendarDay,
        onMessage: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) {
        self.bedID = bedID
        self.rowsShown = rows
        self.embedded = embedded
        self.session = session
        self.actions = actions
        self.climate = climate
        self.today = today
        self.onMessage = onMessage
        self.onError = onError
        let id = bedID
        _beds = Query(filter: #Predicate<LocalBed> { $0.id == id && $0.deletedAt == nil })
        _events = Query(filter: #Predicate<LocalPlantingEvent> { $0.bedID == id && $0.deletedAt == nil })
        let household = actions.scope.householdID
        _seeds = Query(filter: #Predicate<LocalSeed> { $0.deletedAt == nil && $0.householdID == household })
    }

    private var rows: [BedEventRow] {
        guard let bed = beds.first else { return [] }
        let all = GardenBedData(bed: bed, events: events, seeds: seeds, climate: climate).rows(today: today)
        switch rowsShown {
        case .all: return all
        case .offGrid: return all.filter { if case .square = $0.placement { return false } else { return true } }
        }
    }

    private var isRegular: Bool {
        #if os(iOS)
        return horizontalSizeClass == .regular
        #else
        return true
        #endif
    }

    var body: some View {
        let rows = rows
        if embedded {
            ForEach(rows) { row in
                listRow(row)
                    .listRowBackground(row.id == session.selectedEventID ? WBColor.selection : WBColor.panel)
            }
        } else {
            standalone(rows)
        }
    }

    private func standalone(_ rows: [BedEventRow]) -> some View {
        Group {
            if isRegular {
                table(rows)
            } else {
                list(rows)
            }
        }
        .accessibilityIdentifier(rowsShown == .all ? "garden.events" : "garden.offGridEvents")
    }

    // MARK: - Table

    private var selection: Binding<String?> {
        Binding(
            get: { session.selectedEventID },
            set: { id in
                guard let id else { return }
                session.selectEventRow(eventID: id)
            }
        )
    }

    private func table(_ rows: [BedEventRow]) -> some View {
        Table(rows, selection: selection) {
            TableColumn("Done") { row in
                doneToggle(row)
            }
            .width(min: WBMetrics.touchTarget, ideal: WBMetrics.touchTarget)
            TableColumn("Date") { row in
                Text(row.dateText).font(.wbMonoCaption).foregroundStyle(WBColor.ink)
            }
            TableColumn("Task") { row in
                Text(row.kindName).foregroundStyle(WBColor.ink)
            }
            TableColumn("Seed") { row in
                seedCell(row)
            }
            TableColumn("Square") { row in
                squareCell(row)
            }
            TableColumn("Status") { row in
                statusCell(row)
            }
            TableColumn("Notes") { row in
                Text(row.notesPreview ?? "")
                    .font(.wbFootnote)
                    .foregroundStyle(WBColor.muted)
                    .lineLimit(1)
            }
        }
        .scrollContentBackground(.hidden)
    }

    // MARK: - List

    private func list(_ rows: [BedEventRow]) -> some View {
        List {
            ForEach(rows) { row in
                listRow(row)
                    .listRowBackground(row.id == session.selectedEventID ? WBColor.selection : WBColor.panel)
            }
        }
        .scrollContentBackground(.hidden)
    }

    private func listRow(_ row: BedEventRow) -> some View {
        HStack(alignment: .top, spacing: WBMetrics.gap) {
            doneToggle(row)
            Button {
                session.selectEventRow(eventID: row.id)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    seedCell(row)
                    Text("\(row.kindName) · \(row.dateText) · \(row.squareText)")
                        .font(.wbFootnote)
                        .foregroundStyle(WBColor.muted)
                    statusCell(row)
                    if let notes = row.notesPreview {
                        Text(notes).font(.wbFootnote).foregroundStyle(WBColor.muted).lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: WBMetrics.minTouchTarget, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(row.accessibilityLabel)
            .accessibilityAddTraits(row.id == session.selectedEventID ? [.isButton, .isSelected] : .isButton)
            .accessibilityIdentifier("garden.events.select.\(row.id)")
            if row.canPlace {
                placeButton(row)
            }
        }
    }

    // MARK: - Cells

    private func doneToggle(_ row: BedEventRow) -> some View {
        Button {
            run { try actions.setDone(!row.isCompleted, eventID: row.id) }
        } label: {
            Image(systemName: row.isCompleted ? "checkmark.circle.fill" : "circle")
                .font(.wbBody)
                .foregroundStyle(row.isCompleted ? WBColor.accent : WBColor.muted)
                .frame(minWidth: WBMetrics.minTouchTarget, minHeight: WBMetrics.minTouchTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Done")
        .accessibilityValue(row.isCompleted ? "On" : "Off")
        .accessibilityHint("\(row.subject), \(row.dateText)")
        .accessibilityAddTraits(.isToggle)
    }

    private func seedCell(_ row: BedEventRow) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                if row.frostSentence != nil {
                    Image(systemName: "snowflake")
                        .foregroundStyle(WBColor.warn)
                        .accessibilityHidden(true)
                }
                Text(row.subject).font(.wbBody).foregroundStyle(WBColor.ink)
            }
            if let sentence = row.frostSentence {
                Text(sentence)
                    .font(.wbFootnote)
                    .foregroundStyle(WBColor.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func squareCell(_ row: BedEventRow) -> some View {
        HStack(spacing: WBMetrics.gap) {
            Text(row.squareText).font(.wbMonoCaption).foregroundStyle(WBColor.ink)
            if row.canPlace { placeButton(row) }
        }
    }

    private func statusCell(_ row: BedEventRow) -> some View {
        HStack(spacing: 4) {
            if row.status.isWarning {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(WBColor.warn)
                    .accessibilityHidden(true)
            }
            Text(row.status.text)
                .font(.wbFootnote)
                .foregroundStyle(row.status == .done ? WBColor.muted : WBColor.ink)
        }
        .accessibilityElement(children: .combine)
    }

    private func placeButton(_ row: BedEventRow) -> some View {
        Button {
            session.startMove(eventID: row.id)
        } label: {
            // The minimum frame and the hit shape sit inside the label, so the whole target grows.
            Text("Place")
                .frame(minHeight: WBMetrics.minTouchTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.bordered)
        .accessibilityLabel("Place \(row.subject)")
        .accessibilityIdentifier("garden.events.place.\(row.id)")
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
