import SwiftUI
import SwiftData
import SeedkeepKit

/// The Garden screen. On iPad and Mac the workbench hosts `GardenWorkbenchView`; the compact tab shell
/// shows the bed list (name, size, next event, frost count), which opens a bed's screen
/// (`BedDetailView`). Both take a waiting Plan from the window's `GardenSession` on appear, whenever
/// it changes, and whenever the beds with a grid change (a new bed may reach the query late).
struct GardenView: View {
    /// The regular-width workbench's model when the workbench hosts this screen. Nil in the compact tab shell.
    private let workbench: WorkbenchModel?

    init(workbench: WorkbenchModel? = nil) {
        self.workbench = workbench
    }

    var body: some View {
        if let workbench {
            GardenWorkbenchView(workbench: workbench)
        } else {
            GardenCompactView()
        }
    }
}

/// A bed's screen on the compact Garden stack.
struct GardenBedDestination: Hashable {
    let bedID: String
}

/// A seed opened from a bed's planting details on the compact Garden stack.
struct GardenSeedDestination: Hashable {
    let seedID: String
}

/// The compact (iPhone) Garden: the bed list and the add-a-bed prompt. A Plan opens its bed's screen.
private struct GardenCompactView: View {
    @Environment(AppEnvironment.self) private var appEnv
    @Environment(GardenSession.self) private var session

    @Query(filter: #Predicate<LocalBed> { $0.deletedAt == nil },
           sort: \.sortOrder, order: .forward)
    private var beds: [LocalBed]

    @Query(filter: #Predicate<LocalPlantingEvent> { $0.deletedAt == nil })
    private var events: [LocalPlantingEvent]

    @Query(filter: #Predicate<LocalSeed> { $0.deletedAt == nil })
    private var seeds: [LocalSeed]

    @State private var path = NavigationPath()
    @State private var showAddBed = false
    @State private var showWindows = false
    /// The bed New bed created, so Plan can resume when the sheet closes.
    @State private var createdBed: GardenSession.BedChoice?

    var body: some View {
        let activeBeds = self.activeBeds
        let gridBedIDs = Set(activeBeds.filter(GardenWorkbenchView.hasGrid).map(\.id))
        NavigationStack(path: $path) {
            ZStack {
                WBScreenBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        WBScreenTitle(
                            "Garden",
                            subtitle: "\(activeBeds.count) \(activeBeds.count == 1 ? "bed" : "beds") in the household garden"
                        )
                        .padding(.top, WBMetrics.gapLarge)
                        .padding(.bottom, WBMetrics.gapLarge)
                        switch GardenBanner.choose(
                            mode: session.mode, brushSeedID: session.brushSeedID, gridBedCount: gridBedIDs.count
                        ) {
                        case .none:
                            EmptyView()
                        case .modeBar:
                            // Stop stays reachable on the list while a brush or move is active.
                            GardenModeBar(
                                mode: session.mode,
                                brushSeedName: brushName,
                                movingSeedName: nil,
                                hasSelection: session.selectedEventID != nil,
                                onDetails: { session.select(eventID: session.selectedEventID, presentDetails: true) },
                                onStop: {
                                    if session.movingEventID != nil { session.endMove() } else { session.stopPainting() }
                                }
                            )
                            .padding(.horizontal, WBMetrics.screenGutter)
                            .padding(.bottom, WBMetrics.gapLarge)
                        case .addBedPrompt:
                            GardenAddBedPrompt(
                                brushSeedName: brushName,
                                onNewBed: { showAddBed = true },
                                onStop: { session.stopPainting() }
                            )
                            .padding(.horizontal, WBMetrics.screenGutter)
                            .padding(.bottom, WBMetrics.gapLarge)
                        }
                        if FeatureFlags.plantPetsEnabled {
                            NavigationLink(value: MenagerieDestination()) {
                                HStack {
                                    Image(systemName: "pawprint")
                                        .foregroundStyle(WBColor.muted)
                                    Text("Menagerie")
                                        .font(.wbCallout.weight(.semibold))
                                        .foregroundStyle(WBColor.ink)
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.caption)
                                        .foregroundStyle(WBColor.faint)
                                }
                                .padding(.horizontal, WBMetrics.screenGutter)
                                .padding(.vertical, 12)
                            }
                            .buttonStyle(.plain)
                        }
                        if activeBeds.isEmpty {
                            emptyState
                        } else {
                            VStack(spacing: 0) {
                                ForEach(activeBeds, id: \.id) { bed in
                                    NavigationLink(value: GardenBedDestination(bedID: bed.id)) {
                                        BedRow(row: row(for: bed))
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityIdentifier("garden.bed.\(bed.id)")
                                }
                            }
                            .padding(.horizontal, WBMetrics.screenGutter)
                            .padding(.bottom, HerbSpace.fabClearance)
                        }
                    }
                }
            }
            .onAppear {
                takePlan(gridBedIDs: gridBedIDs)
                // Back on the list: no bed is on screen. The brush stays.
                if path.isEmpty { session.showBed(nil) }
            }
            .navigationTitle("")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .publishesAssistantContext(pageType: "garden")
            .navigationDestination(for: GardenBedDestination.self) { destination in
                BedDetailView(bedID: destination.bedID, onOpenSeed: { seedID in
                    path.append(GardenSeedDestination(seedID: seedID))
                })
            }
            .navigationDestination(for: GardenSeedDestination.self) { destination in
                SeedDetailView(seedID: destination.seedID)
            }
            .navigationDestination(for: MenagerieDestination.self) { _ in
                MenagerieView()
            }
            .navigationDestination(for: PetDetailDestination.self) { dest in
                PetDetailView(plantingEventID: dest.plantingEventID)
            }
            .toolbar {
                ToolbarItem(placement: .platformLeading) {
                    Button {
                        showWindows = true
                    } label: {
                        Image(systemName: "calendar")
                    }
                    .accessibilityLabel("Windows")
                    .accessibilityIdentifier("garden.windows")
                }
                ToolbarItem(placement: .platformTrailing) {
                    Button {
                        showAddBed = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("New bed")
                    .accessibilityIdentifier("garden.newBed")
                }
            }
            .sheet(isPresented: $showAddBed, onDismiss: { resumePlan(activeBeds) }) {
                AddBedView(onCreated: { createdBed = $0 })
            }
            .sheet(isPresented: $showWindows) {
                NavigationStack {
                    WindowsView(host: .compactGardenSheet, workbench: nil)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Done") { showWindows = false }
                            }
                        }
                }
            }
            .refreshable {
                await appEnv.syncIfPossible()
            }
        }
        .onChange(of: session.pendingPlan) { _, _ in takePlan(gridBedIDs: gridBedIDs) }
        // A Plan for a bed the query didn't have yet waits for it.
        .onChange(of: gridBedIDs) { _, ids in takePlan(gridBedIDs: ids) }
    }

    private var activeBeds: [LocalBed] {
        guard let householdID = appEnv.activeGardenHouseholdID else { return [] }
        return GardenWorkbenchView.ordered(beds.filter { $0.householdID == householdID })
    }

    private var brushName: String? {
        guard let id = session.brushSeedID else { return nil }
        return seeds.first { $0.id == id }?.displayName
    }

    private func row(for bed: LocalBed) -> GardenBedListRow {
        let data = GardenBedData(bed: bed, events: events, seeds: seeds, climate: appEnv.preferences.homeClimate)
        return GardenBedListRow.make(
            name: bed.name, widthFeet: bed.widthFeet, lengthFeet: bed.lengthFeet,
            events: data.events, seedNames: data.seedNames
        )
    }

    /// Takes the waiting Plan and opens its bed's screen, painting with its seed.
    private func takePlan(gridBedIDs: Set<String>) {
        guard let plan = GardenPlanHandoff.take(from: session, gridBedIDs: gridBedIDs) else { return }
        var next = NavigationPath()
        next.append(GardenBedDestination(bedID: plan.bedID))
        path = next
    }

    /// After New bed from the add-a-bed prompt: plans the brush seed again when the new bed has a grid.
    private func resumePlan(_ activeBeds: [LocalBed]) {
        defer { createdBed = nil }
        GardenPlanHandoff.resume(
            session: session, created: createdBed,
            beds: activeBeds.map { GardenSession.BedChoice($0) }
        )
    }

    @ViewBuilder
    private var emptyState: some View {
        WBEmptyState(
            title: "No beds yet",
            message: "Beds are the spaces you plant in, such as 'Herb bed' or 'South wall'. Give one a size to plan it on a grid.",
            systemImage: "square.grid.3x3.topleft.filled",
            action: (label: "Add your first bed", handler: { showAddBed = true })
        )
    }
}

private struct BedRow: View {
    let row: GardenBedListRow

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name)
                    .font(.wbHeadline)
                    .foregroundStyle(WBColor.ink)
                Text(row.sizeText)
                    .font(.wbCaption)
                    .foregroundStyle(WBColor.muted)
                Text(row.nextEventText)
                    .font(.wbCaption)
                    .foregroundStyle(WBColor.muted)
                if let frost = row.frostText {
                    HStack(spacing: 4) {
                        Image(systemName: "snowflake")
                            .foregroundStyle(WBColor.warn)
                        Text(frost)
                            .font(.wbCaption)
                            .foregroundStyle(WBColor.ink)
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(WBColor.faint)
        }
        .padding(.vertical, 10)
        .frame(minHeight: WBMetrics.minTouchTarget)
        .contentShape(Rectangle())
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(WBColor.line)
                .frame(height: 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.accessibilityLabel)
        .accessibilityAddTraits(.isButton)
    }
}

func humanDate(_ ymd: String, timeZone: TimeZone = .current) -> String {
    guard ymd.range(
        of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}$"#,
        options: .regularExpression
    ) != nil else { return ymd }

    let parser = DateFormatter()
    parser.dateFormat = "yyyy-MM-dd"
    parser.locale = Locale(identifier: "en_US_POSIX")
    parser.timeZone = timeZone
    guard let date = parser.date(from: ymd) else { return ymd }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = timeZone
    formatter.dateStyle = .medium
    formatter.timeStyle = .none
    return formatter.string(from: date)
}

// MARK: - Navigation destinations (Phase 5.1.2)

/// Marker value used to push `MenagerieView` onto the Garden navigation
/// stack. Hashable so SwiftUI's typed navigation accepts it.
struct MenagerieDestination: Hashable {}

/// Push value for `PetDetailView`. Hashable because SwiftUI's typed
/// navigation depends on `==`/`hash` for state restoration + back-stack.
struct PetDetailDestination: Hashable {
    let plantingEventID: String
}
