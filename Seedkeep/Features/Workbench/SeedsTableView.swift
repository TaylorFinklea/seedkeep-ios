// The Seeds screen (redesign R1, slice B): a spreadsheet-style table of the household's seeds, with
// the inspector beside it, inline edits, bulk actions, CSV export and undo.
//
// The shell owns the live feed (`rows`, `seedsByID`). Writes go through `SeedWriter`, which uses
// `SyncEngine` and registers undo on this window's `UndoManager`. `isEditingText` is set only from
// this view's own focus state (the inline drafts and the search field).
import SwiftUI
import SwiftData
import Combine
import UniformTypeIdentifiers
import SeedkeepKit

/// Holds the failure message the alert shows, for a forward edit, a delete, or an undo.
@MainActor
@Observable
final class SeedsIssueCenter {
    var message: String?

    func present(_ report: SeedWriteReport) {
        if let issue = report.issueMessage {
            message = issue
        }
    }
}

struct SeedsTableView: View {
    @Bindable var model: WorkbenchModel
    let rows: [SeedTableRow]
    let seedsByID: [String: LocalSeed]

    @Environment(AppEnvironment.self) private var appEnv
    @Environment(\.undoManager) private var environmentUndoManager: UndoManager?
    @Query(sort: \LocalLocation.sortOrder) private var allLocations: [LocalLocation]
    @Query(sort: \LocalTag.name) private var allTags: [LocalTag]

    @State private var fallbackUndoManager = UndoManager()
    /// Bumped whenever the undo stack changes, so the Undo and Redo buttons re-read `canUndo`.
    @State private var undoRevision = 0
    @State private var issues = SeedsIssueCenter()
    @State private var filter = SeedsFilter()
    @State private var sortOrder = SeedsTableModel.defaultSortOrder
    @State private var editing = SeedEditing()
    @State private var isSelecting = false
    @State private var showingAdd = false
    @State private var showingScan = false
    @State private var scanPrefill: AddSeedView.Prefill?
    @State private var showingExporter = false
    @State private var exportDocument: SeedCSVDocument?
    @State private var exportName = ""
    @State private var pendingDeletion: SeedDeletionRequest?
    @State private var notice: String?
    @FocusState private var focusedEdit: SeedDraftKey?
    @FocusState private var searchFocused: Bool

    private static let stateChoices: [SeedState] = [.active, .wishlist, .saved, .archived]

    init(model: WorkbenchModel, rows: [SeedTableRow], seedsByID: [String: LocalSeed]) {
        self.model = model
        self.rows = rows
        self.seedsByID = seedsByID
    }

    // MARK: - Body

    var body: some View {
        // Computed once per body: the selection, its rows, and the undo state. Cells never recompute them.
        let visible = visibleRows
        let rowIDs = Set(rows.map(\.id))
        let selection = model.selectedSeedIDs.intersection(rowIDs)
        let selectedRows = rows.filter { selection.contains($0.id) }
        let undoState = (undoRevision, undoTarget.canUndo, undoTarget.canRedo)

        VStack(spacing: 0) {
            SeedsToolbar(
                filter: $filter,
                counts: SeedsTableModel.counts(rows, filter: filter),
                typeOptions: SeedsTableModel.typeOptions(rows),
                searchFocus: $searchFocused,
                isSelecting: $isSelecting,
                isInspectorOpen: $model.isInspectorOpen,
                canUndo: undoState.1,
                canRedo: undoState.2,
                canExport: !rows.isEmpty,
                onUndo: { undoTarget.undo() },
                onRedo: { undoTarget.redo() },
                onExport: prepareExport,
                onNew: { showingAdd = true }
            )
            Divider()
            content(visible)
            if let notice {
                noticeBanner(notice)
            }
            if !selection.isEmpty {
                SeedsBulkBar(
                    selectedCount: selection.count,
                    locations: scopedLocations,
                    tags: scopedTags,
                    onStatus: { applyEdit(.status($0), to: Array(selection)) },
                    onMove: { applyEdit(.location($0), to: Array(selection)) },
                    onAddTag: { applyEdit(.addTag($0), to: Array(selection)) },
                    onDelete: { presentDeletion(Array(selection)) },
                    onClear: { model.selectedSeedIDs = [] }
                )
            }
        }
        .background(WBColor.bg)
        .inspector(isPresented: $model.isInspectorOpen) {
            SeedsInspector(
                selectedIDs: selection,
                selectedRows: selectedRows,
                seedsByID: seedsByID,
                householdID: appEnv.activeGardenHouseholdID
            )
        }
        .sheet(isPresented: $showingAdd) {
            AddSeedView()
        }
        #if os(iOS)
        // Packet scanning, as the Library offers it: the Seeds table replaces the Library on
        // regular-width iPad, so it must keep the scan-and-prefill entry.
        .toolbar {
            if PlatformCapabilities.supportsCameraScanning {
                ToolbarItem(placement: .platformTrailing) {
                    Button { showingScan = true } label: { Image(systemName: "viewfinder") }
                        .accessibilityLabel("Scan packet")
                }
            }
        }
        .fullScreenCover(isPresented: $showingScan) {
            ScanFlow { result in
                switch result {
                case .catalogHit(let barcode, let cat):
                    scanPrefill = .catalog(barcode: barcode, cat)
                case .extracted(let extraction, let barcode):
                    scanPrefill = .extraction(extraction, barcode: barcode)
                case .preExtracted(let pre, let barcode):
                    scanPrefill = .preExtraction(pre, barcode: barcode)
                }
            }
        }
        #endif
        .sheet(item: Binding(
            get: { scanPrefill.map { ScanPrefillBox(prefill: $0) } },
            set: { box in scanPrefill = box?.prefill }
        )) { box in
            AddSeedView(prefill: box.prefill)
        }
        .fileExporter(
            isPresented: $showingExporter,
            document: exportDocument,
            contentType: .commaSeparatedText,
            defaultFilename: exportName
        ) { result in
            if case .failure(let error) = result {
                issues.message = humanizeError(error)
            }
        }
        .confirmationDialog(
            deletionTitle,
            isPresented: deletionPresented,
            titleVisibility: .visible
        ) {
            Button(deletionButtonTitle, role: .destructive) { confirmDeletion() }
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
        } message: {
            Text("They're removed from this device and the household. This can't be undone.")
        }
        .alert("Some changes weren't saved", isPresented: issuePresented) {
            Button("OK", role: .cancel) { issues.message = nil }
        } message: {
            Text(issues.message ?? "")
        }
        .modifier(DoneToolbar(action: finishEditing))
        .onReceive(Publishers.MergeMany(
            UndoEvents.names.map { NotificationCenter.default.publisher(for: $0, object: undoTarget) }
        )) { _ in
            undoRevision += 1
        }
        .task(id: catalogKey) {
            await refreshVerdicts()
        }
        .onAppear {
            // The shell owns the window's undo manager; only fill it in when used without one.
            if model.activeUndoManager == nil { model.activeUndoManager = undoTarget }
            handleRequests()
            handleReveal()
            pruneSelection()
            discardMissingDrafts()
        }
        .onChange(of: model.pendingSeedsRequests) {
            handleRequests()
        }
        .onChange(of: model.revealedSeedID) {
            handleReveal()
        }
        .onChange(of: rows) {
            pruneSelection()
            discardMissingDrafts()
            handleReveal()
        }
        .onChange(of: appEnv.activeGardenHouseholdID) {
            scopeChanged()
        }
        .onChange(of: focusedEdit) { old, new in
            if let old, old != new, !editing.consumeSuppressedBlur(for: old) {
                commitDraft(old)
            }
            updateEditingFlag()
        }
        .onChange(of: searchFocused) {
            updateEditingFlag()
        }
        .onDisappear {
            model.isEditingText = false
        }
    }

    // MARK: - Data

    private var visibleRows: [SeedTableRow] {
        SeedsTableModel.sorted(SeedsTableModel.filtered(rows, filter), using: sortOrder)
    }

    private var scopedLocations: [LocalLocation] {
        let household = appEnv.activeGardenHouseholdID
        return allLocations.filter { $0.householdID == household && $0.deletedAt == nil }
    }

    private var scopedTags: [LocalTag] {
        let household = appEnv.activeGardenHouseholdID
        return allTags.filter { $0.householdID == household && $0.deletedAt == nil }
    }

    /// The manager every edit registers with: SwiftUI's when it provides one, otherwise the
    /// window shell's (published as `model.activeUndoManager`), so menus, the iPad toolbar and
    /// this screen share one per-window history. The local fallback is only for this view used
    /// outside the shell (tests, previews).
    private var undoTarget: UndoManager {
        environmentUndoManager ?? model.activeUndoManager ?? fallbackUndoManager
    }

    private var writer: SeedWriter {
        SeedWriter(
            sync: appEnv.sync,
            container: appEnv.container,
            undoManager: undoTarget,
            currentHouseholdID: { [appEnv] in appEnv.activeGardenHouseholdID },
            flush: { [appEnv] in
                Task { try? await appEnv.sync.flushPending() }
            },
            // Reports go to the window banner, not a view-local alert: an undo or redo can run
            // after Seeds has left the screen, and its failures must still be seen.
            presentIssues: { [appEnv] report in
                if let message = report.issueMessage { appEnv.surfaceMessage(message) }
            }
        )
    }

    private var catalogKey: String {
        rows.compactMap(\.catalogID).sorted().joined(separator: ",")
    }

    /// Fetches verdicts for every catalog seed in the household, 200 ids per request, the most
    /// `bulkRefresh` accepts in one call.
    private func refreshVerdicts() async {
        let ids = Array(Set(rows.compactMap(\.catalogID))).sorted()
        for start in stride(from: 0, to: ids.count, by: 200) {
            let chunk = Array(ids[start..<min(start + 200, ids.count)])
            await appEnv.recommendations.bulkRefresh(catalogSeedIDs: chunk)
        }
    }

    // MARK: - Content

    @ViewBuilder
    private func content(_ visible: [SeedTableRow]) -> some View {
        if rows.isEmpty {
            if appEnv.sync.isSyncing {
                ProgressView("Loading seeds…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                emptyLibrary
            }
        } else if visible.isEmpty {
            noMatches
        } else if PlatformCapabilities.isMac {
            macTable(visible)
        } else {
            iPadTable(visible)
        }
    }

    /// iPad (regular width): Name, Status, Pkts, Year, Stored in and Window. The rest is in the
    /// inspector.
    private func iPadTable(_ visible: [SeedTableRow]) -> some View {
        Table(visible, selection: $model.selectedSeedIDs, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name) { row in
                nameCell(row)
            }
            .width(min: 160, ideal: 220)
            TableColumn("Status", value: \.state) { row in
                statusCell(row)
            }
            .width(min: 110, ideal: 130)
            TableColumn("Pkts", value: \.packets) { row in
                packetsCell(row)
            }
            .width(min: 64, ideal: 72)
            TableColumn("Year", value: \.yearSortKey) { row in
                yearCell(row)
            }
            .width(min: 72, ideal: 84)
            TableColumn("Stored in", value: \.locationName) { row in
                locationCell(row)
            }
            .width(min: 110, ideal: 150)
            TableColumn("Window", value: \.verdictLabel) { row in
                windowCell(row)
            }
            .width(min: 120, ideal: 150)
        }
    }

    /// Mac: all ten columns. Delete is focus-scoped here: it fires only while the table has focus.
    private func macTable(_ visible: [SeedTableRow]) -> some View {
        Table(visible, selection: $model.selectedSeedIDs, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name) { row in
                nameCell(row)
            }
            .width(min: 160, ideal: 200)
            TableColumn("Variety", value: \.variety) { row in
                textCell(row.variety)
            }
            .width(min: 90, ideal: 120)
            TableColumn("Type", value: \.type) { row in
                textCell(row.type)
            }
            .width(min: 80, ideal: 100)
            TableColumn("Company", value: \.company) { row in
                textCell(row.company)
            }
            .width(min: 90, ideal: 120)
            TableColumn("Year", value: \.yearSortKey) { row in
                yearCell(row)
            }
            .width(min: 64, ideal: 72)
            TableColumn("Pkts", value: \.packets) { row in
                packetsCell(row)
            }
            .width(min: 56, ideal: 64)
            TableColumn("Status", value: \.state) { row in
                statusCell(row)
            }
            .width(min: 100, ideal: 110)
            TableColumn("Stored in", value: \.locationName) { row in
                locationCell(row)
            }
            .width(min: 100, ideal: 130)
            TableColumn("Tags", value: \.tagsText) { row in
                textCell(row.tagsText)
            }
            .width(min: 100, ideal: 160)
            TableColumn("Window", value: \.verdictLabel) { row in
                windowCell(row)
            }
            .width(min: 110, ideal: 140)
        }
        .modifier(DeleteKeyCommand { requestDeleteFromKeyboard() })
    }

    // MARK: - Cells

    /// The name. In touch selection mode the name is the toggle, since a tap on a Table row would
    /// replace the selection instead of adding to it.
    @ViewBuilder
    private func nameCell(_ row: SeedTableRow) -> some View {
        if isSelecting {
            let selected = model.selectedSeedIDs.contains(row.id)
            Button {
                toggleSelection(row.id)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected ? WBColor.accent : WBColor.faint)
                        .accessibilityHidden(true)
                    Text(row.name)
                        .font(.wbBody)
                        .lineLimit(1)
                }
                .frame(minHeight: SeedsLayout.controlMinHeight, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(row.name)
            .accessibilityValue(selected ? "Selected" : "Not selected")
            .accessibilityAddTraits(.isButton)
        } else {
            Text(row.name)
                .font(.wbBody)
                .lineLimit(1)
                .accessibilityLabel(row.name)
        }
    }

    private func textCell(_ value: String) -> some View {
        Group {
            if value.isEmpty {
                Text("—").foregroundStyle(WBColor.faint)
            } else {
                Text(value)
            }
        }
        .font(.wbBody)
        .lineLimit(1)
        .accessibilityLabel(value.isEmpty ? "Not set" : value)
    }

    private func statusCell(_ row: SeedTableRow) -> some View {
        Picker("Status", selection: Binding(
            get: { SeedState(rawValue: row.state) ?? .active },
            set: { state in applyEdit(.status(state), to: [row.id]) }
        )) {
            ForEach(Self.stateChoices, id: \.self) { state in
                Text(SeedsTableModel.stateLabel(state.rawValue)).tag(state)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(minHeight: SeedsLayout.controlMinHeight, alignment: .leading)
        .accessibilityLabel("Status for \(row.name)")
    }

    private func locationCell(_ row: SeedTableRow) -> some View {
        Picker("Stored in", selection: Binding(
            get: { row.locationID ?? "" },
            set: { id in applyEdit(.location(id.isEmpty ? nil : id), to: [row.id]) }
        )) {
            Text("None").tag("")
            ForEach(scopedLocations) { location in
                Text(location.name).tag(location.id)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(minHeight: SeedsLayout.controlMinHeight, alignment: .leading)
        .accessibilityLabel("Stored in, for \(row.name)")
    }

    private func packetsCell(_ row: SeedTableRow) -> some View {
        numberField(
            row,
            field: .packets,
            shown: "\(row.packets)",
            prompt: "Packets",
            label: "Packets for \(row.name)"
        )
    }

    private func yearCell(_ row: SeedTableRow) -> some View {
        numberField(
            row,
            field: .year,
            shown: row.year.map { String($0) } ?? "",
            prompt: "Year",
            label: "Year packed, for \(row.name)"
        )
    }

    /// A text draft. Return commits, Escape cancels (on Mac also through the field's exit command),
    /// and leaving the field commits. An invalid draft keeps its text and shows the error.
    private func numberField(
        _ row: SeedTableRow,
        field: SeedDraftField,
        shown: String,
        prompt: String,
        label: String
    ) -> some View {
        let key = SeedDraftKey(seedID: row.id, field: field)
        return VStack(alignment: .trailing, spacing: 2) {
            TextField(prompt, text: Binding(
                get: { editing.text(for: key, shown: shown) },
                set: { editing.setDraft($0, for: key) }
            ))
            .font(.wbMono)
            .multilineTextAlignment(.trailing)
            .numberKeyboard()
            .focused($focusedEdit, equals: key)
            .onSubmit { commitDraft(key) }
            .onKeyPress(.escape) {
                cancelDraft(key)
                return .handled
            }
            .modifier(CancelOnExit(action: { cancelDraft(key) }))
            .frame(minWidth: 48, minHeight: SeedsLayout.controlMinHeight, alignment: .trailing)
            .accessibilityLabel(label)
            .accessibilityHint("Press Return to save, or Escape to cancel")
            if let message = editing.errors[key] {
                Text(message)
                    .font(.wbCaption)
                    .foregroundStyle(WBColor.warn)
                    .multilineTextAlignment(.trailing)
                    .accessibilityLabel("Error: \(message)")
            }
        }
    }

    private func windowCell(_ row: SeedTableRow) -> some View {
        HStack(spacing: 6) {
            if let verdict = row.verdict {
                Circle()
                    .fill(WBColor.verdict(verdict))
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
            }
            Text(row.verdictLabel.isEmpty ? "—" : row.verdictLabel)
                .font(.wbBody)
                .foregroundStyle(row.verdictLabel.isEmpty ? WBColor.faint : WBColor.ink)
                .lineLimit(1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.verdictLabel.isEmpty ? "No planting window" : "Planting window, \(row.verdictLabel)")
    }

    // MARK: - Empty states

    private var emptyLibrary: some View {
        ContentUnavailableView {
            Label("No seeds yet", systemImage: "leaf")
        } description: {
            Text("Add a seed to start your list.")
        } actions: {
            Button("Add seed") { showingAdd = true }
                .buttonStyle(.borderedProminent)
                .tint(WBColor.accent)
        }
    }

    private var noMatches: some View {
        ContentUnavailableView {
            Label("No matches", systemImage: "magnifyingglass")
        } description: {
            Text("Try a different search or filter.")
        } actions: {
            Button("Clear search and filters") { filter = SeedsFilter() }
        }
    }

    private func noticeBanner(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(text)
                .font(.wbCaption)
                .foregroundStyle(WBColor.warn)
            Spacer(minLength: 8)
            Button("Dismiss") { notice = nil }
                .frame(minHeight: SeedsLayout.controlMinHeight)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(WBColor.warnSoft)
    }

    // MARK: - Editing

    private func commitDraft(_ key: SeedDraftKey) {
        guard let text = editing.draft(for: key) else { return }
        let year = Calendar.current.component(.year, from: Date())
        switch writer.commitDraft(key, text: text, currentYear: year) {
        case .failure(let error):
            editing.fail(key, message: error.message)
        case .success(let report) where !report.failures.isEmpty:
            // The write failed (the report is also shown in the banner): keep the draft so the
            // user's input isn't lost and they can retry.
            editing.fail(key, message: report.issueMessage ?? "Couldn't save this change.")
        case .success:
            editing.finish(key)
            model.selectedSeedIDs = SeedsTableModel.selectionAfterEdit(model.selectedSeedIDs, seedID: key.seedID)
        }
    }

    /// Escape: drop the draft and leave the field. The blur that follows does not commit.
    private func cancelDraft(_ key: SeedDraftKey) {
        editing.cancel(key)
        focusedEdit = nil
    }

    /// The iPad keyboard's Done: commit the active draft, then leave the field.
    private func finishEditing() {
        if let key = focusedEdit {
            commitDraft(key)
        }
        focusedEdit = nil
        searchFocused = false
    }

    private func applyEdit(_ edit: SeedFieldEdit, to seedIDs: [String]) {
        _ = writer.apply(edit, to: seedIDs)
        if seedIDs.count == 1, let seedID = seedIDs.first {
            model.selectedSeedIDs = SeedsTableModel.selectionAfterEdit(model.selectedSeedIDs, seedID: seedID)
        }
    }

    private func toggleSelection(_ id: String) {
        var selection = model.selectedSeedIDs
        if selection.contains(id) {
            selection.remove(id)
        } else {
            selection.insert(id)
        }
        model.selectedSeedIDs = selection
    }

    /// Text focus here (a draft or the search field) disables keyboard Delete.
    private func updateEditingFlag() {
        model.isEditingText = focusedEdit != nil || searchFocused
    }

    // MARK: - Delete

    /// Keyboard Delete (table focus on Mac, or the menu's request): only with a selection and outside
    /// text editing. Opens the same count confirmation as the bulk bar.
    private func requestDeleteFromKeyboard() {
        let ids = Array(model.selectedSeedIDs.intersection(rows.map(\.id)))
        guard SeedsTableModel.canRequestDelete(selectionCount: ids.count, isEditingText: model.isEditingText) else {
            return
        }
        presentDeletion(ids)
    }

    private func presentDeletion(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        pendingDeletion = writer.requestDeletion(ids)
    }

    private func confirmDeletion() {
        guard let request = pendingDeletion else { return }
        pendingDeletion = nil
        _ = writer.confirmDeletion(request)
    }

    private var deletionPresented: Binding<Bool> {
        Binding(
            get: { pendingDeletion != nil },
            set: { if !$0 { pendingDeletion = nil } }
        )
    }

    private var issuePresented: Binding<Bool> {
        Binding(
            get: { issues.message != nil },
            set: { if !$0 { issues.message = nil } }
        )
    }

    private var deletionTitle: String {
        (pendingDeletion?.count ?? 0) == 1 ? "Delete this seed?" : "Delete \(pendingDeletion?.count ?? 0) seeds?"
    }

    private var deletionButtonTitle: String {
        (pendingDeletion?.count ?? 0) == 1 ? "Delete seed" : "Delete \(pendingDeletion?.count ?? 0) seeds"
    }

    // MARK: - Requests, reveal, discards and scope

    /// Takes every queued request from the menus and the palette, exactly once.
    private func handleRequests() {
        for request in model.takeSeedsRequests() {
            switch request {
            case .newSeed:
                showingAdd = true
            case .exportCSV:
                prepareExport()
            case .focusSearch:
                searchFocused = true
            case .deleteSelection:
                requestDeleteFromKeyboard()
            }
        }
    }

    /// Applies a reveal: clears the filters that would hide the seed and keeps it selected. The request
    /// waits while no rows are loaded, and is dropped once the rows are loaded and the seed is not one of them.
    private func handleReveal() {
        guard let seedID = model.revealedSeedID else { return }
        switch SeedsTableModel.revealOutcome(for: seedID, in: rows) {
        case .pending:
            return
        case .missing:
            model.revealedSeedID = nil
        case .found(let row):
            model.revealedSeedID = nil
            filter = SeedsTableModel.revealing(row, from: filter)
            model.selectedSeedIDs = SeedsTableModel.selectionAfterEdit(model.selectedSeedIDs, seedID: row.id)
        }
    }

    private func pruneSelection() {
        let pruned = SeedsTableModel.pruned(model.selectedSeedIDs, liveIDs: Set(rows.map(\.id)))
        if pruned != model.selectedSeedIDs {
            model.selectedSeedIDs = pruned
        }
    }

    private func discardMissingDrafts() {
        let removed = editing.discardMissing(liveIDs: Set(rows.map(\.id)))
        guard !removed.isEmpty else { return }
        notice = removed.count == 1
            ? "A seed you were editing was removed. Its unsaved change was discarded."
            : "\(removed.count) seeds you were editing were removed. Their unsaved changes were discarded."
    }

    /// The garden changed. `resetForScopeChange` clears selection, requests, reveal and (through the
    /// window's undo manager) undo history; drafts and pending deletes belong here.
    private func scopeChanged() {
        model.resetForScopeChange()
        editing.discardAll()
        pendingDeletion = nil
        notice = nil
    }

    private func prepareExport() {
        let selection = model.selectedSeedIDs.intersection(rows.map(\.id))
        let exported = SeedsTableModel.exportRows(
            rows: rows,
            filter: filter,
            selection: selection,
            sortOrder: sortOrder
        )
        exportDocument = SeedCSVDocument(data: SeedCSV.data(for: exported))
        exportName = SeedCSV.baseFileName(on: Date())
        showingExporter = true
    }
}

// MARK: - Helpers

private extension View {
    /// Number pad on iPad; a plain keyboard on Mac.
    @ViewBuilder
    func numberKeyboard() -> some View {
        #if os(iOS)
        self.keyboardType(.numberPad)
        #else
        self
        #endif
    }
}

/// Escape on a Mac draft field: the field's exit command cancels the draft too. The Escape key
/// handler on the field may not see the key once the field editor has taken it.
private struct CancelOnExit: ViewModifier {
    let action: () -> Void

    func body(content: Content) -> some View {
        #if os(macOS)
        content.onExitCommand(perform: action)
        #else
        content
        #endif
    }
}

/// Keyboard Delete on the Mac table: it fires only while the table has focus.
private struct DeleteKeyCommand: ViewModifier {
    let action: () -> Void

    func body(content: Content) -> some View {
        #if os(macOS)
        content.onDeleteCommand(perform: action)
        #else
        content
        #endif
    }
}

/// A Done button above the iPad keyboard, which commits the active draft.
private struct DoneToolbar: ViewModifier {
    let action: () -> Void

    func body(content: Content) -> some View {
        #if os(iOS)
        content.toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done", action: action)
            }
        }
        #else
        content
        #endif
    }
}

/// Undo-stack notifications for the window's manager. Any of them can change Undo or Redo enablement.
private enum UndoEvents {
    static let names: [Notification.Name] = [
        Notification.Name("NSUndoManagerDidUndoChangeNotification"),
        Notification.Name("NSUndoManagerDidRedoChangeNotification"),
        Notification.Name("NSUndoManagerDidCloseUndoGroupNotification"),
    ]
}
