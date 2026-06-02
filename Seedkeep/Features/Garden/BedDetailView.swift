import SwiftUI
import SwiftData
import SeedkeepKit

/// One bed's detail + its planting events timeline. Events are grouped
/// into "Upcoming" (no completion + planned in the future or today),
/// "Overdue" (no completion + planned in the past), and "Done"
/// (completed_at set), so the user's eye lands on what needs action.
struct BedDetailView: View {
    let bedID: String

    @Environment(AppEnvironment.self) private var appEnv
    @Environment(\.dismiss) private var dismiss

    @Query private var beds: [LocalBed]
    @Query private var allEvents: [LocalPlantingEvent]
    @Query(filter: #Predicate<LocalSeed> { $0.deletedAt == nil },
           sort: \.customName, order: .forward)
    private var seeds: [LocalSeed]

    @State private var showAddEvent = false
    @State private var showEditBed = false

    /// Catalog data keyed by catalog ID. Populated lazily on view appear:
    /// for each event in this bed that has a seed with a catalog ID, we
    /// fetch the catalog entry and cache it. Used to look up plant-spacing
    /// for the layout canvas's rings. nil = "not found / not yet fetched".
    @State private var catalogCache: [String: CatalogSeedDTO?] = [:]

    init(bedID: String) {
        self.bedID = bedID
        let id = bedID
        _beds = Query(filter: #Predicate<LocalBed> { $0.id == id })
        _allEvents = Query(filter: #Predicate<LocalPlantingEvent> { $0.bedID == id && $0.deletedAt == nil })
    }

    var body: some View {
        Group {
            if let bed = beds.first {
                ZStack {
                    VellumBackground()
                    Form {
                        Section {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Plot · the abbey grounds")
                                    .font(HerbFont.smallCaps(size: 10))
                                    .tracking(2)
                                    .foregroundStyle(HerbColor.sepia)
                                    .textCase(.uppercase)
                                Text(bed.name)
                                    .font(HerbFont.display(size: 30))
                                    .foregroundStyle(HerbColor.ink)
                                Text(formatDims(bed) ?? "—")
                                    .font(HerbFont.bodyItalic(size: 12))
                                    .foregroundStyle(HerbColor.inkSoft)
                            }
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 8, trailing: 20))
                            .listRowSeparator(.hidden)
                        }
                        layoutSection(bed)
                    Section("Bed") {
                        LabeledContent("Name", value: bed.name)
                        if let desc = bed.bedDescription, !desc.isEmpty {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Description").font(.caption).foregroundStyle(.secondary)
                                Text(desc)
                            }
                        }
                        if let dims = formatDims(bed) {
                            LabeledContent("Dimensions", value: dims)
                        }
                    }

                    eventSection(title: "Overdue", events: overdueEvents, defaultEmptyHidden: true)
                    eventSection(title: "Upcoming", events: upcomingEvents, defaultEmptyHidden: false)
                    eventSection(title: "Done", events: doneEvents, defaultEmptyHidden: true)

                    companionsSection

                    EntityScopedJournalSection(parent: .bed(bed.id))

                    Section {
                        Button(role: .destructive) {
                            Task { await deleteBed() }
                        } label: {
                            Label("Delete bed", systemImage: "trash")
                        }
                    } footer: {
                        Text("Deleting a bed unlinks its planting events; the events themselves stick around so harvest history isn't lost.")
                    }
                    }
                    .scrollContentBackground(.hidden)
                }
                .navigationTitle(bed.name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showAddEvent = true
                        } label: {
                            Image(systemName: "plus")
                        }
                        .accessibilityLabel("Add planting event")
                    }
                }
                .sheet(isPresented: $showAddEvent) {
                    AddPlantingEventView(bedID: bed.id, prefillSeedID: nil)
                }
                .task(id: allEvents.map(\.id)) {
                    await refreshCatalogsForEvents()
                }
            } else {
                ContentUnavailableView(
                    "Bed unavailable",
                    systemImage: "tray.full",
                    description: Text("This bed may have been deleted on another device.")
                )
            }
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private func layoutSection(_ bed: LocalBed) -> some View {
        if let width = bed.widthFeet, let length = bed.lengthFeet,
           width > 0, length > 0 {
            Section {
                BedLayoutCanvas(
                    widthFeet: width,
                    lengthFeet: length,
                    placements: placements(for: bed),
                    onMove: { id, newX, newY in
                        movePlacement(eventID: id, x: newX, y: newY)
                    }
                )
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            } header: {
                Text("Layout")
            } footer: {
                Text(placedCount(for: bed) == 0
                     ? "Add a position to a planting event to see it on the layout."
                     : "Drag a placed event to reposition it. Snaps to a half-foot grid.")
            }
        }
    }

    private func movePlacement(eventID: String, x: Double, y: Double) {
        try? appEnv.sync.enqueueUpdatePlantingEvent(
            id: eventID,
            SeedkeepClient.UpdatePlantingEventInput(x_feet: x, y_feet: y)
        )
        Task { await appEnv.syncIfPossible() }
    }

    private func placements(for bed: LocalBed) -> [BedLayoutCanvas.Placement] {
        allEvents.compactMap { event in
            guard let x = event.xFeet, let y = event.yFeet else { return nil }
            let kind = PlantingEventKind(rawValue: event.kindRaw)
            return BedLayoutCanvas.Placement(
                id: event.id,
                x: x,
                y: y,
                spacingFeet: spacingFeet(for: event),
                label: seedName(for: event) ?? (kind?.displayName ?? ""),
                isSowing: kind == .sowing
            )
        }
    }

    /// Look up the seed → catalog → plant_spacing_inches chain and
    /// convert to feet. Returns 0 when any link is missing — the canvas
    /// renders just a dot in that case (no ring).
    private func spacingFeet(for event: LocalPlantingEvent) -> Double {
        guard let seedID = event.seedID,
              let seed = seeds.first(where: { $0.id == seedID }),
              let catalogID = seed.catalogID,
              let catalog = catalogCache[catalogID] ?? nil,
              let inches = catalog.plant_spacing_inches,
              inches > 0
        else { return 0 }
        return Double(inches) / 12.0
    }

    /// Fetch + cache catalogs for every unique catalog-linked seed in
    /// this bed. Skips IDs we already have (the cache stays populated
    /// across multi-view appearances). Failed fetches store a `nil`
    /// sentinel so we don't keep retrying.
    @MainActor
    private func refreshCatalogsForEvents() async {
        var catalogIDs: Set<String> = []
        for event in allEvents {
            guard let seedID = event.seedID,
                  let seed = seeds.first(where: { $0.id == seedID }),
                  let catalogID = seed.catalogID else { continue }
            if catalogCache[catalogID] != nil { continue }
            catalogIDs.insert(catalogID)
        }
        for id in catalogIDs {
            let result = try? await appEnv.client.catalogByID(id)
            catalogCache[id] = result ?? nil
        }
    }

    private func placedCount(for bed: LocalBed) -> Int {
        allEvents.filter { $0.xFeet != nil && $0.yFeet != nil }.count
    }

    @ViewBuilder
    private var companionsSection: some View {
        let pets = allEvents
            .filter { $0.petCreatureKind != nil && $0.petSeed != nil && $0.completedAt == nil }
            .sorted(by: sortKey)
        if !pets.isEmpty {
            Section("Companions") {
                ForEach(pets) { pet in
                    PetCard(pet: pet, variant: .inline)
                }
            }
        }
    }

    @ViewBuilder
    private func eventSection(title: String, events: [LocalPlantingEvent], defaultEmptyHidden: Bool) -> some View {
        if !events.isEmpty {
            Section(title) {
                ForEach(events.sorted(by: sortKey)) { event in
                    EventRow(event: event, seedName: seedName(for: event))
                        .swipeActions {
                            if event.completedAt == nil {
                                Button("Done") {
                                    markCompleted(event)
                                }.tint(.green)
                            } else {
                                Button("Undo") {
                                    markIncomplete(event)
                                }.tint(.blue)
                            }
                            Button(role: .destructive) {
                                deleteEvent(event)
                            } label: {
                                Image(systemName: "trash")
                            }
                        }
                }
            }
        } else if !defaultEmptyHidden {
            Section(title) {
                Text("Nothing planned yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Event partitioning

    private var todayYMD: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        return f.string(from: Date())
    }

    private var overdueEvents: [LocalPlantingEvent] {
        let today = todayYMD
        return allEvents.filter { $0.completedAt == nil && $0.plannedFor < today }
    }

    private var upcomingEvents: [LocalPlantingEvent] {
        let today = todayYMD
        return allEvents.filter { $0.completedAt == nil && $0.plannedFor >= today }
    }

    private var doneEvents: [LocalPlantingEvent] {
        allEvents.filter { $0.completedAt != nil }
    }

    private func sortKey(_ a: LocalPlantingEvent, _ b: LocalPlantingEvent) -> Bool {
        a.plannedFor < b.plannedFor
    }

    // MARK: - Helpers

    private func seedName(for event: LocalPlantingEvent) -> String? {
        guard let seedID = event.seedID else { return nil }
        return seeds.first(where: { $0.id == seedID })?.customName
    }

    private func formatDims(_ bed: LocalBed) -> String? {
        switch (bed.widthFeet, bed.lengthFeet) {
        case let (w?, l?): return "\(fmt(w))′ × \(fmt(l))′"
        case let (w?, nil): return "\(fmt(w))′ wide"
        case let (nil, l?): return "\(fmt(l))′ long"
        default: return nil
        }
    }
    private func fmt(_ v: Double) -> String {
        v.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(v))" : String(format: "%.1f", v)
    }

    private func markCompleted(_ event: LocalPlantingEvent) {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        try? appEnv.sync.enqueueUpdatePlantingEvent(
            id: event.id,
            SeedkeepClient.UpdatePlantingEventInput(completed_at: now)
        )
        Task { await appEnv.syncIfPossible() }
    }

    private func markIncomplete(_ event: LocalPlantingEvent) {
        try? appEnv.sync.enqueueUpdatePlantingEvent(
            id: event.id,
            SeedkeepClient.UpdatePlantingEventInput(completed_at: 0)
        )
        Task { await appEnv.syncIfPossible() }
    }

    private func deleteEvent(_ event: LocalPlantingEvent) {
        try? appEnv.sync.enqueueDeletePlantingEvent(id: event.id)
        Task { await appEnv.syncIfPossible() }
    }

    private func deleteBed() async {
        try? appEnv.sync.enqueueDeleteBed(id: bedID)
        await appEnv.syncIfPossible()
        dismiss()
    }
}

private struct EventRow: View {
    let event: LocalPlantingEvent
    let seedName: String?

    var body: some View {
        let kind = PlantingEventKind(rawValue: event.kindRaw)
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: kind?.systemImage ?? "calendar")
                .foregroundStyle(event.completedAt == nil ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(kind?.displayName ?? event.kindRaw.capitalized)
                        .font(.body.weight(.medium))
                        .strikethrough(event.completedAt != nil)
                    if let name = seedName {
                        Text("·").foregroundStyle(.secondary)
                        Text(name)
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .strikethrough(event.completedAt != nil)
                    }
                }
                Text(humanDate(event.plannedFor))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let notes = event.notes, !notes.isEmpty {
                    Text(notes)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }
            }
        }
    }
}
