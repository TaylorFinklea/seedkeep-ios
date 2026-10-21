import SwiftUI
import SwiftData
import SeedkeepKit

/// A bed's screen on iPhone (R3 G2): the brush strip ("Paint with a seed"), the Stop or
/// move bar pinned above the content while painting or moving, the grid, the bed's events, its pet
/// companions and its journal. Planting details open as a sheet; when it closes, focus returns to the
/// square. A bed without a grid lists its events with "Set a size to plan on a grid" and Edit bed.
/// Edit bed also deletes the bed (confirmed).
struct BedDetailView: View {
    let bedID: String
    /// Opens a seed from planting details.
    let onOpenSeed: (String) -> Void

    @Environment(AppEnvironment.self) private var appEnv
    @Environment(GardenSession.self) private var session
    @Environment(\.dismiss) private var dismiss

    @Query private var beds: [LocalBed]
    @Query private var bedEvents: [LocalPlantingEvent]
    @Query(filter: #Predicate<LocalSeed> { $0.deletedAt == nil }) private var seeds: [LocalSeed]
    @Query(filter: #Predicate<LocalBed> { $0.deletedAt == nil }) private var allBeds: [LocalBed]

    @State private var showEditBed = false
    @State private var bedDeleted = false
    @State private var showNewBed = false
    /// The bed New bed created from the add-a-bed prompt, so Plan can resume when the sheet closes.
    @State private var createdBed: GardenSession.BedChoice?
    @State private var showAddEvent = false
    @State private var showLegend = false
    @State private var message: String?
    @State private var focusRequest: GridSquare?
    /// The square details opened on, so focus can return there when the sheet closes.
    @State private var detailsSquare: GridSquare?
    /// The square of a planting deleted in the sheet; focus returns there once the sheet has closed.
    @State private var deletedSquare: GridSquare?
    /// A seed to open once the details sheet has closed.
    @State private var seedToOpen: String?

    @ScaledMetric(relativeTo: .body) private var scaledCell: CGFloat = 56
    @ScaledMetric(relativeTo: .body) private var cellSpacing: CGFloat = 4
    /// The tallest the grid gets before it scrolls inside itself.
    private static let gridMaxHeight: CGFloat = 440

    init(bedID: String, onOpenSeed: @escaping (String) -> Void = { _ in }) {
        self.bedID = bedID
        self.onOpenSeed = onOpenSeed
        let id = bedID
        _beds = Query(filter: #Predicate<LocalBed> { $0.id == id && $0.deletedAt == nil })
        _bedEvents = Query(filter: #Predicate<LocalPlantingEvent> { $0.bedID == id && $0.deletedAt == nil })
    }

    var body: some View {
        let householdID = appEnv.activeGardenHouseholdID
        Group {
            if let bed = beds.first, let householdID, bed.householdID == householdID {
                let data = GardenBedData(bed: bed, events: bedEvents, seeds: seeds, climate: appEnv.preferences.homeClimate)
                let actions = GardenBedSupport.actions(appEnv: appEnv, householdID: householdID, bedID: bed.id)
                screen(bed: bed, data: data, actions: actions, householdID: householdID)
            } else {
                ZStack {
                    WBScreenBackground()
                    WBEmptyState(
                        title: "Bed unavailable",
                        message: "This bed may have been deleted on another device.",
                        systemImage: "tray.full"
                    )
                }
            }
        }
        .navigationTitle("")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        // On the Group, not the screen: once the bed is deleted the screen gives way to "Bed
        // unavailable", and a sheet hung on it would go with it before its onDismiss could pop.
        .sheet(isPresented: $showEditBed, onDismiss: { if bedDeleted { dismiss() } }) {
            AddBedView(editingBedID: bedID, onDeleted: { bedDeleted = true })
        }
        .onAppear { session.showBed(bedID) }
    }

    // MARK: - Screen

    private func screen(bed: LocalBed, data: GardenBedData, actions: GardenActions, householdID: String) -> some View {
        List {
            Section {
                header(bed)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 8, trailing: 20))
                    .listRowSeparator(.hidden)
            }
            if let size = data.size {
                Section {
                    GardenBrushList(
                        axis: .horizontal,
                        seeds: brushSeeds(householdID: householdID),
                        brushSeedID: session.brushSeedID,
                        isPainting: session.isPainting,
                        // The mode bar's Stop (with Details) is the one Stop while it shows.
                        showsStop: banner(data: data) != .modeBar,
                        onSelect: { session.startPainting(seedID: $0) },
                        onStop: { session.stopPainting() }
                    )
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                }
                Section {
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
                    .scrollBounceBehavior(.basedOnSize, axes: [.horizontal, .vertical])
                    .frame(height: gridHeight(size))
                    .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4))
                    .listRowBackground(WBColor.panel)
                } header: {
                    WBSectionHeader("Grid")
                } footer: {
                    Text(GardenLegend.scale)
                        .font(.wbFootnote)
                        .foregroundStyle(WBColor.muted)
                }
            } else {
                Section {
                    GardenGridlessNotice { showEditBed = true }
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                }
            }
            Section {
                if data.events.isEmpty {
                    Text("Nothing planned yet.")
                        .font(.wbCallout)
                        .foregroundStyle(WBColor.muted)
                } else {
                    // Without a grid every event is in the no-grid list, with no Place action.
                    BedEventsList(
                        bedID: bed.id,
                        rows: data.size == nil ? .offGrid : .all,
                        embedded: true,
                        session: session,
                        actions: actions,
                        climate: appEnv.preferences.homeClimate,
                        today: .today(),
                        onMessage: show,
                        onError: { appEnv.surfaceError($0) }
                    )
                }
            } header: {
                WBSectionHeader("Events")
            }
            GardenCompanionsSection(events: bedEvents)
            EntityScopedJournalSection(parent: .bed(bed.id))
        }
        .scrollContentBackground(.hidden)
        .background(WBScreenBackground())
        .safeAreaInset(edge: .top, spacing: 0) {
            topBar(data: data)
        }
        .toolbar {
            ToolbarItemGroup(placement: .platformTrailing) {
                Button { showLegend.toggle() } label: { Image(systemName: "info.circle") }
                    .accessibilityLabel("Legend")
                    .accessibilityIdentifier("garden.legend")
                    .popover(isPresented: $showLegend) {
                        GardenLegendView().presentationCompactAdaptation(.popover)
                    }
                Button { showEditBed = true } label: { Image(systemName: "pencil") }
                    .accessibilityLabel("Edit bed")
                    .accessibilityIdentifier("garden.editBed")
                Button { showAddEvent = true } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Add planting event")
                    .accessibilityIdentifier("garden.addPlanting")
            }
        }
        .sheet(isPresented: detailsBinding, onDismiss: detailsClosed) {
            NavigationStack {
                SquareDetails(
                    bedID: bed.id,
                    session: session,
                    actions: actions,
                    climate: appEnv.preferences.homeClimate,
                    onOpenSeed: { seedID in
                        seedToOpen = seedID
                        session.closeDetails()
                    },
                    // The sheet closes after a delete; focus returns from its onDismiss.
                    onDeleted: { deletedSquare = $0 },
                    onMessage: show,
                    onError: { appEnv.surfaceError($0) }
                )
                .navigationTitle("Planting")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { session.closeDetails() }
                            .accessibilityIdentifier("garden.squareDetails.done")
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showNewBed, onDismiss: resumePlan) {
            AddBedView(onCreated: { createdBed = $0 })
        }
        .sheet(isPresented: $showAddEvent) {
            AddPlantingEventView(bedID: bed.id, prefillSeedID: nil)
        }
        .onChange(of: session.detailsPresented) { _, presented in
            if presented { detailsSquare = GardenBedSupport.square(of: session.selectedEventID, in: data) }
        }
        .onKeyPress(.escape) {
            cancel(data: data) ? .handled : .ignored
        }
        .accessibilityIdentifier("screen.bedDetail")
    }

    private func header(_ bed: LocalBed) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Garden bed")
                .font(.wbSectionLabel)
                .tracking(0.6)
                .foregroundStyle(WBColor.muted)
                .textCase(.uppercase)
            Text(bed.name)
                .font(.wbTitle)
                .foregroundStyle(WBColor.ink)
                .accessibilityAddTraits(.isHeader)
            Text(GardenBedListRow.sizeText(widthFeet: bed.widthFeet, lengthFeet: bed.lengthFeet))
                .font(.wbFootnote)
                .foregroundStyle(WBColor.muted)
            if let description = bed.bedDescription, !description.isEmpty {
                Text(description)
                    .font(.wbCallout)
                    .foregroundStyle(WBColor.ink)
            }
        }
    }

    /// The Stop or move bar, or the add-a-bed prompt, and the latest refusal, pinned above the list.
    @ViewBuilder
    private func topBar(data: GardenBedData) -> some View {
        let banner = banner(data: data)
        if banner != .none || message != nil {
            VStack(spacing: WBMetrics.gap) {
                switch banner {
                case .none:
                    EmptyView()
                case .modeBar:
                    GardenModeBar(
                        mode: session.mode,
                        brushSeedName: brushName,
                        movingSeedName: GardenBedSupport.movingName(session: session, data: data),
                        hasSelection: session.selectedEventID != nil,
                        onDetails: { session.select(eventID: session.selectedEventID, presentDetails: true) },
                        onStop: {
                            if session.movingEventID != nil { session.endMove() } else { session.stopPainting() }
                        }
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
            .padding(.horizontal, 16)
            .padding(.vertical, WBMetrics.gap)
            .background(WBColor.bg)
        }
    }

    private func banner(data: GardenBedData) -> GardenBanner {
        let gridBedCount = allBeds.filter {
            $0.householdID == appEnv.activeGardenHouseholdID && GardenWorkbenchView.hasGrid($0)
        }.count
        return GardenBanner.choose(
            mode: session.mode, brushSeedID: session.brushSeedID, gridBedCount: gridBedCount
        )
    }

    // MARK: - Details sheet

    private var detailsBinding: Binding<Bool> {
        Binding(
            get: { session.detailsPresented && session.selectedEventID != nil },
            set: { if !$0 { session.closeDetails() } }
        )
    }

    /// The sheet has closed: return focus to the square (or the deleted planting's square), then open
    /// a seed the details asked for.
    private func detailsClosed() {
        focusRequest = deletedSquare ?? detailsSquare
        deletedSquare = nil
        if let seedID = seedToOpen {
            seedToOpen = nil
            onOpenSeed(seedID)
        }
    }

    // MARK: - Helpers

    /// After New bed from the add-a-bed prompt: plans the brush seed again; the Garden stack takes the
    /// Plan and opens the new bed.
    private func resumePlan() {
        defer { createdBed = nil }
        let householdID = appEnv.activeGardenHouseholdID
        GardenPlanHandoff.resume(
            session: session, created: createdBed,
            beds: allBeds.filter { $0.householdID == householdID }.map { GardenSession.BedChoice($0) }
        )
    }

    private func brushSeeds(householdID: String) -> [BrushSeed] {
        GardenBedSupport.brushSeeds(
            seeds: seeds, householdID: householdID,
            recommendation: { appEnv.recommendations.recommendation(for: $0) }
        )
    }

    private var brushName: String? {
        guard let id = session.brushSeedID else { return nil }
        return seeds.first { $0.id == id }?.displayName
    }

    private func gridHeight(_ size: GridSize) -> CGFloat {
        let cell = max(WBMetrics.touchTarget, scaledCell)
        let content = CGFloat(size.rows) * (cell + cellSpacing) + cellSpacing * 2
        return min(content, Self.gridMaxHeight)
    }

    private func show(_ text: String) {
        message = text
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

    /// Escape: closes details, then move mode, then the brush, then the selection.
    private func cancel(data: GardenBedData) -> Bool {
        guard let size = data.size else { return session.cancel() }
        let before = session.interactionState
        _ = session.handle(.cancel, context: .init(size: size, events: data.events, bedID: data.bedID, planDate: .today()))
        return session.interactionState != before
    }
}
