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

    init(bedID: String) {
        self.bedID = bedID
        let id = bedID
        _beds = Query(filter: #Predicate<LocalBed> { $0.id == id })
        _allEvents = Query(filter: #Predicate<LocalPlantingEvent> { $0.bedID == id && $0.deletedAt == nil })
    }

    var body: some View {
        Group {
            if let bed = beds.first {
                Form {
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
