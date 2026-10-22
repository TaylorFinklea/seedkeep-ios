import SwiftUI
import SwiftData
import SeedkeepKit

/// The Garden route on iPad and Mac (R3 G2). The toolbar has the bed switcher (segmented up to five
/// beds, otherwise a menu), New bed, Edit bed, Stop or Cancel while painting or moving, and the legend.
/// The content has the brush list ("Paint with a seed"), the grid, and below it the unplaced and
/// outside list and the events table. The inspector shows the selected planting (`SquareDetails`).
struct GardenWorkbenchView: View {
    let workbench: WorkbenchModel

    @Environment(AppEnvironment.self) private var appEnv
    @Environment(GardenSession.self) private var session

    @Query(filter: #Predicate<LocalBed> { $0.deletedAt == nil }, sort: \.sortOrder, order: .forward)
    private var beds: [LocalBed]
    @Query(filter: #Predicate<LocalPlantingEvent> { $0.deletedAt == nil })
    private var events: [LocalPlantingEvent]
    @Query(filter: #Predicate<LocalSeed> { $0.deletedAt == nil })
    private var seeds: [LocalSeed]

    @State private var inspectorOpen = true
    @State private var showNewBed = false
    @State private var editingBedID: String?
    @State private var showWindows = false
    @State private var showLegend = false
    /// The bed the journal opened on; it may be deleted elsewhere while the sheet is open.
    @State private var journalBed: JournalBed?
    @State private var showAddPlanting = false
    @State private var message: String?
    @State private var focusRequest: GridSquare?
    /// The bed New bed created, so Plan can resume when the sheet closes.
    @State private var createdBed: GardenSession.BedChoice?

    @ScaledMetric(relativeTo: .body) private var scaledBrushColumnWidth: CGFloat = 240
    @ScaledMetric(relativeTo: .body) private var scaledOffGridHeight: CGFloat = 150
    @ScaledMetric(relativeTo: .body) private var scaledEventsHeight: CGFloat = 240

    // Capped, so at accessibility sizes the grid keeps usable space; the lists scroll inside.
    private var brushColumnWidth: CGFloat { min(scaledBrushColumnWidth, 320) }
    private var offGridHeight: CGFloat { min(scaledOffGridHeight, 200) }
    private var eventsHeight: CGFloat { min(scaledEventsHeight, 320) }

    var body: some View {
        let householdID = appEnv.activeGardenHouseholdID
        let householdBeds = Self.ordered(beds.filter { $0.householdID == householdID })
        let bed = householdBeds.first { $0.id == session.bedID }
        let data = bed.map { GardenBedData(bed: $0, events: events, seeds: seeds, climate: appEnv.preferences.homeClimate) }
        let gridBedIDs = Set(householdBeds.filter { Self.hasGrid($0) }.map(\.id))
        NavigationStack {
            VStack(spacing: 0) {
                bars(bed: bed, data: data, gridBedCount: gridBedIDs.count)
                content(householdBeds: householdBeds, bed: bed, data: data, householdID: householdID)
            }
            .background(WBColor.bg)
            .task {
                await appEnv.syncIfPossible()
            }
            .refreshable {
                await appEnv.syncIfPossible()
            }
            .navigationTitle(bed?.name ?? "Garden")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { toolbar(householdBeds: householdBeds, bed: bed) }
            .inspector(isPresented: inspectorBinding) {
                inspector(bed: bed, householdID: householdID)
                    .inspectorColumnWidth(min: 300, ideal: 340, max: 460)
            }
            .navigationDestination(for: MenagerieDestination.self) { _ in MenagerieView() }
            .navigationDestination(for: PetDetailDestination.self) { dest in
                PetDetailView(plantingEventID: dest.plantingEventID)
            }
        }
        .onKeyPress(.escape) {
            cancel(data: data) ? .handled : .ignored
        }
        .sheet(isPresented: $showNewBed, onDismiss: { resumePlan(householdBeds: householdBeds) }) {
            AddBedView(onCreated: { createdBed = $0 })
        }
        .sheet(item: editingBinding) { item in
            AddBedView(editingBedID: item.id, onDeleted: { session.showBed(nil) })
        }
        .sheet(isPresented: $showWindows) {
            NavigationStack {
                WindowsView(host: .workbenchGardenSheet, workbench: workbench)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { showWindows = false }
                        }
                    }
            }
        }
        .sheet(item: $journalBed) { opened in
            NavigationStack {
                Group {
                    if let bed = householdBeds.first(where: { $0.id == opened.id }) {
                        Form {
                            GardenCompanionsSection(events: events.filter { $0.bedID == bed.id })
                            EntityScopedJournalSection(parent: .bed(bed.id))
                        }
                        .wbForm()
                        .navigationTitle("\(bed.name) journal")
                    } else {
                        WBEmptyState(
                            title: "This bed was deleted",
                            message: "It may have been deleted on another device.",
                            systemImage: "tray.full"
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .navigationTitle("\(opened.name) journal")
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { journalBed = nil }
                    }
                }
            }
            .frame(minWidth: 420, minHeight: 420)
        }
        .sheet(isPresented: $showAddPlanting) {
            AddPlantingEventView(bedID: bed?.id, prefillSeedID: nil)
        }
        .onAppear {
            takePlan(gridBedIDs: gridBedIDs)
            ensureBed(householdBeds)
        }
        .onChange(of: session.pendingPlan) { _, _ in takePlan(gridBedIDs: gridBedIDs) }
        // A Plan for a bed the query didn't have yet waits for it.
        .onChange(of: gridBedIDs) { _, ids in takePlan(gridBedIDs: ids) }
        .onChange(of: householdBeds.map(\.id)) { _, _ in ensureBed(householdBeds) }
        // A reset (a garden change) or a deleted bed can leave no bed shown while beds exist.
        .onChange(of: session.bedID) { _, id in if id == nil { ensureBed(householdBeds) } }
        .onChange(of: session.detailsPresented) { _, presented in
            if presented { inspectorOpen = true }
        }
        .accessibilityIdentifier("screen.garden")
    }

    // MARK: - Bars

    @ViewBuilder
    private func bars(bed: LocalBed?, data: GardenBedData?, gridBedCount: Int) -> some View {
        let banner = GardenBanner.choose(
            mode: session.mode, brushSeedID: session.brushSeedID, gridBedCount: gridBedCount
        )
        VStack(spacing: WBMetrics.gap) {
            switch banner {
            case .none:
                EmptyView()
            case .modeBar:
                GardenModeBar(
                    mode: session.mode,
                    brushSeedName: brushName,
                    movingSeedName: data.flatMap { GardenBedSupport.movingName(session: session, data: $0) },
                    hasSelection: session.selectedEventID != nil,
                    onDetails: { session.select(eventID: session.selectedEventID, presentDetails: true) },
                    onStop: stopOrCancel
                )
            case .addBedPrompt:
                GardenAddBedPrompt(
                    brushSeedName: brushName,
                    onNewBed: { showNewBed = true },
                    onStop: { session.stopPainting() }
                )
            }
            if let message {
                GardenMessageBanner(message: message) { self.message = nil }
            }
        }
        .padding(.horizontal, WBMetrics.gapLarge)
        .padding(.vertical, banner == .none && message == nil ? 0 : WBMetrics.gap)
    }

    // MARK: - Content

    @ViewBuilder
    private func content(householdBeds: [LocalBed], bed: LocalBed?, data: GardenBedData?, householdID: String?) -> some View {
        if householdBeds.isEmpty {
            WBEmptyState(
                title: "No beds yet",
                message: "Beds are the spaces you plant in, such as 'Herb bed' or 'South wall'. Give one a size to plan it on a grid.",
                systemImage: "square.grid.3x3.topleft.filled",
                action: (label: "New bed", handler: { showNewBed = true })
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let bed, let data, let householdID {
            let actions = GardenBedSupport.actions(appEnv: appEnv, householdID: householdID, bedID: bed.id)
            if let size = data.size {
                HStack(alignment: .top, spacing: 0) {
                    GardenBrushList(
                        axis: .vertical,
                        seeds: brushSeeds,
                        brushSeedID: session.brushSeedID,
                        isPainting: session.isPainting,
                        onSelect: { session.startPainting(seedID: $0) },
                        onStop: { session.stopPainting() }
                    )
                    .frame(width: brushColumnWidth)
                    Divider()
                    VStack(spacing: 0) {
                        BedGridView(
                            size: size,
                            squares: data.squares,
                            mode: session.mode,
                            selectedEventID: session.selectedEventID,
                            brushSeedName: brushName,
                            movingSeedName: GardenBedSupport.movingName(session: session, data: data),
                            seedName: { data.seedName($0) },
                            onActivate: { run(.activate($0), data: data, actions: actions) },
                            onMoveSelected: { run(.moveSelected($0), data: data, actions: actions) },
                            focusRequest: $focusRequest
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        Divider()
                        lists(bed: bed, data: data, actions: actions)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: WBMetrics.gap) {
                    GardenGridlessNotice { editingBedID = bed.id }
                        .padding(.horizontal, WBMetrics.gapLarge)
                        .padding(.top, WBMetrics.gap)
                    eventsList(bed: bed, rows: .offGrid, actions: actions)
                }
            }
        } else {
            // Beds exist but none is shown (ensureBed normally picks one at once).
            WBEmptyState(
                title: "No bed shown",
                message: "Choose a bed in the toolbar.",
                systemImage: "square.grid.3x3",
                action: (label: "Show a bed", handler: { ensureBed(householdBeds) })
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func lists(bed: LocalBed, data: GardenBedData, actions: GardenActions) -> some View {
        let offGrid = GardenGrid.offGrid(events: data.events, bedID: bed.id, size: data.size)
        VStack(alignment: .leading, spacing: 0) {
            if !offGrid.unplaced.isEmpty || !offGrid.outside.isEmpty {
                WBSectionHeader("Not on the grid")
                    .padding(.horizontal, WBMetrics.gapLarge)
                    .padding(.top, WBMetrics.gap)
                eventsList(bed: bed, rows: .offGrid, actions: actions)
                    .frame(height: offGridHeight)
                Divider()
            }
            WBSectionHeader("Events")
                .padding(.horizontal, WBMetrics.gapLarge)
                .padding(.top, WBMetrics.gap)
            eventsList(bed: bed, rows: .all, actions: actions)
                .frame(minHeight: eventsHeight, idealHeight: eventsHeight)
        }
    }

    private func eventsList(bed: LocalBed, rows: BedEventsList.Rows, actions: GardenActions) -> some View {
        BedEventsList(
            bedID: bed.id,
            rows: rows,
            session: session,
            actions: actions,
            climate: appEnv.preferences.homeClimate,
            today: .today(),
            onMessage: { message = $0 },
            onError: { appEnv.surfaceError($0) }
        )
        .id("\(bed.id).\(rows)")
    }

    // MARK: - Inspector

    @ViewBuilder
    private func inspector(bed: LocalBed?, householdID: String?) -> some View {
        if let bed, let householdID {
            SquareDetails(
                bedID: bed.id,
                session: session,
                actions: GardenBedSupport.actions(appEnv: appEnv, householdID: householdID, bedID: bed.id),
                climate: appEnv.preferences.homeClimate,
                onOpenSeed: { workbench.reveal(seedID: $0) },
                // No sheet closes here, so focus can return at once.
                onDeleted: { square in if let square { focusRequest = square } },
                onMessage: { message = $0 },
                onError: { appEnv.surfaceError($0) }
            )
            .id(bed.id)
        } else {
            WBEmptyState(title: "No bed", message: "Choose or add a bed.", systemImage: "square.grid.3x3")
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private func toolbar(householdBeds: [LocalBed], bed: LocalBed?) -> some ToolbarContent {
        ToolbarItem(placement: .principal) {
            bedSwitcher(householdBeds)
        }
        ToolbarItemGroup(placement: .platformTrailing) {
            // Whenever a brush or move is active, on any bed, so it can always be stopped.
            if session.mode != .idle {
                Button(session.isPainting ? "Stop" : "Cancel", action: stopOrCancel)
                    .accessibilityIdentifier("garden.toolbar.stop")
            }
            Button { showNewBed = true } label: { Label("New bed", systemImage: "plus") }
                .accessibilityIdentifier("garden.newBed")
            Button { editingBedID = bed?.id } label: { Label("Edit bed", systemImage: "pencil") }
                .disabled(bed == nil)
                .accessibilityIdentifier("garden.editBed")
            Button { showAddPlanting = true } label: { Label("Add planting", systemImage: "calendar.badge.plus") }
                .disabled(bed == nil)
                .accessibilityIdentifier("garden.addPlanting")
            Button { showLegend.toggle() } label: { Label("Legend", systemImage: "info.circle") }
                .popover(isPresented: $showLegend) { GardenLegendView() }
                .accessibilityIdentifier("garden.legend")
            Button { journalBed = bed.map { JournalBed(id: $0.id, name: $0.name) } } label: {
                Label("Bed journal", systemImage: "book")
            }
                .disabled(bed == nil)
                .accessibilityIdentifier("garden.journal")
            Button { showWindows = true } label: { Label("Windows", systemImage: "calendar") }
                .accessibilityIdentifier("garden.windows")
            if FeatureFlags.plantPetsEnabled {
                NavigationLink(value: MenagerieDestination()) { Label("Menagerie", systemImage: "pawprint") }
            }
            Toggle(isOn: inspectorBinding) {
                Label("Inspector", systemImage: "sidebar.trailing")
            }
            .toggleStyle(.button)
            .accessibilityIdentifier("garden.inspector")
        }
    }

    @ViewBuilder
    private func bedSwitcher(_ householdBeds: [LocalBed]) -> some View {
        let selection = Binding<String?>(
            get: { session.bedID },
            set: { id in if let id { session.showBed(id) } }
        )
        switch BedSwitcherStyle.choose(bedCount: householdBeds.count) {
        case .none:
            EmptyView()
        case .segmented:
            Picker("Bed", selection: selection) {
                ForEach(householdBeds) { bed in
                    Text(bed.name).tag(Optional(bed.id))
                }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .accessibilityIdentifier("garden.bedSwitcher")
        case .menu:
            Picker("Bed", selection: selection) {
                ForEach(householdBeds) { bed in
                    Text(bed.name).tag(Optional(bed.id))
                }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("garden.bedSwitcher")
        }
    }

    // MARK: - State

    private struct EditingBed: Identifiable {
        let id: String
    }

    private struct JournalBed: Identifiable {
        let id: String
        let name: String
    }

    private var editingBinding: Binding<EditingBed?> {
        Binding(
            get: { editingBedID.map(EditingBed.init(id:)) },
            set: { editingBedID = $0?.id }
        )
    }

    /// The toolbar toggle and the inspector's own dismissal. Closing it closes details and keeps the selection.
    private var inspectorBinding: Binding<Bool> {
        Binding(
            get: { inspectorOpen },
            set: { open in
                inspectorOpen = open
                if !open { session.closeDetails() }
            }
        )
    }

    private var brushSeeds: [BrushSeed] {
        GardenBedSupport.brushSeeds(
            seeds: seeds, householdID: appEnv.activeGardenHouseholdID,
            recommendation: { appEnv.recommendations.recommendation(for: $0) }
        )
    }

    private var brushName: String? {
        guard let id = session.brushSeedID else { return nil }
        return seeds.first { $0.id == id }?.displayName
    }

    private func run(_ input: GardenInteraction.Input, data: GardenBedData, actions: GardenActions) {
        let planDate = GardenBedSupport.planDate(
            brushSeedID: session.brushSeedID, seeds: seeds,
            recommendation: { appEnv.recommendations.recommendation(for: $0) }
        )
        let outcome = GardenBedSupport.handle(
            input, session: session, data: data, planDate: planDate, actions: actions,
            onError: { appEnv.surfaceError($0) }
        )
        message = outcome.message
        if let focus = outcome.focus { focusRequest = focus }
    }

    private func stopOrCancel() {
        if session.movingEventID != nil {
            session.endMove()
        } else {
            session.stopPainting()
        }
    }

    /// Escape: closes details, then move mode, then the brush, then the selection. The inspector is
    /// the details editor here, so closing details closes it too (the selection stays).
    private func cancel(data: GardenBedData?) -> Bool {
        let detailsWereOpen = session.detailsPresented
        let handled: Bool
        if let data, let size = data.size {
            let before = session.interactionState
            _ = session.handle(.cancel, context: .init(size: size, events: data.events, bedID: data.bedID, planDate: .today()))
            handled = session.interactionState != before
        } else {
            handled = session.cancel()
        }
        if detailsWereOpen, !session.detailsPresented { inspectorOpen = false }
        return handled
    }

    /// Takes the waiting Plan: shows its bed and paints with its seed.
    private func takePlan(gridBedIDs: Set<String>) {
        if GardenPlanHandoff.take(from: session, gridBedIDs: gridBedIDs) != nil {
            message = nil
        }
    }

    /// Shows a bed when none (or a gone one) is on screen: the last viewed, otherwise the first.
    private func ensureBed(_ householdBeds: [LocalBed]) {
        guard !householdBeds.contains(where: { $0.id == session.bedID }) else { return }
        let next = householdBeds.first { $0.id == session.lastViewedBedID } ?? householdBeds.first
        session.showBed(next?.id)
    }

    /// After New bed: plans the brush seed again when the new bed has a grid.
    private func resumePlan(householdBeds: [LocalBed]) {
        defer { createdBed = nil }
        GardenPlanHandoff.resume(
            session: session, created: createdBed,
            beds: householdBeds.map { GardenSession.BedChoice($0) }
        )
    }

    static func hasGrid(_ bed: LocalBed) -> Bool {
        GardenGrid.size(widthFeet: bed.widthFeet, lengthFeet: bed.lengthFeet) != nil
    }

    /// By sort order, then name, then id.
    static func ordered(_ beds: [LocalBed]) -> [LocalBed] {
        beds.sorted { lhs, rhs in
            if lhs.sortOrder != rhs.sortOrder { return lhs.sortOrder < rhs.sortOrder }
            let byName = lhs.name.localizedStandardCompare(rhs.name)
            if byName != .orderedSame { return byName == .orderedAscending }
            return lhs.id < rhs.id
        }
    }
}

/// The bed's pet companions (behind the plant-pets flag), as the bed screen showed them.
struct GardenCompanionsSection: View {
    let events: [LocalPlantingEvent]

    var body: some View {
        if FeatureFlags.plantPetsEnabled {
            let pets = events
                .filter { $0.deletedAt == nil && $0.petCreatureKind != nil && $0.petSeed != nil && $0.completedAt == nil }
                .sorted { $0.plannedFor < $1.plannedFor }
            if !pets.isEmpty {
                Section("Companions") {
                    ForEach(pets) { pet in
                        PetCard(pet: pet, variant: .inline)
                    }
                }
            }
        }
    }
}
