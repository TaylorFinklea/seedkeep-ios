import SwiftUI
import SwiftData
import SeedkeepKit

/// Form for creating a planting event. Can be invoked from a bed
/// (prefills bed_id) or from a seed (prefills seed_id and lets the
/// user pick a bed). At least one of bed_id or seed_id is typical;
/// neither is hard-required so a free-form bed note still works.
struct AddPlantingEventView: View {
    let bedID: String?
    let prefillSeedID: String?

    @Environment(AppEnvironment.self) private var appEnv
    @Environment(\.dismiss) private var dismiss

    @Query(filter: #Predicate<LocalBed> { $0.deletedAt == nil },
           sort: \.sortOrder, order: .forward)
    private var beds: [LocalBed]

    @Query(filter: #Predicate<LocalSeed> { $0.deletedAt == nil },
           sort: \.customName, order: .forward)
    private var seeds: [LocalSeed]

    @State private var kind: PlantingEventKind = .sowing
    @State private var plannedFor: Date = Date()
    @State private var selectedBedID: String?
    @State private var selectedSeedID: String?
    @State private var notes: String = ""
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                actionSection
                whereSection
                notesSection
                errorSection
            }
            .navigationTitle("Plan event")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .onAppear {
                if selectedBedID == nil { selectedBedID = bedID }
                if selectedSeedID == nil { selectedSeedID = prefillSeedID }
            }
        }
    }

    @ViewBuilder
    private var actionSection: some View {
        Section("Action") {
            Picker("Kind", selection: $kind) {
                ForEach(PlantingEventKind.allCases) { k in
                    Label(k.displayName, systemImage: k.systemImage).tag(k)
                }
            }
            DatePicker("Planned for", selection: $plannedFor, displayedComponents: .date)
        }
    }

    @ViewBuilder
    private var whereSection: some View {
        Section("Where + what") {
            Picker("Bed", selection: $selectedBedID) {
                Text("None").tag(String?.none)
                ForEach(beds) { bed in
                    Text(bed.name).tag(Optional(bed.id))
                }
            }
            Picker("Seed", selection: $selectedSeedID) {
                Text("None").tag(String?.none)
                ForEach(seeds) { seed in
                    Text(seed.customName ?? "Unnamed seed").tag(Optional(seed.id))
                }
            }
        }
    }

    @ViewBuilder
    private var notesSection: some View {
        Section("Notes") {
            TextField("Optional", text: $notes, axis: .vertical)
                .lineLimit(2...6)
        }
    }

    @ViewBuilder
    private var errorSection: some View {
        if let error {
            Section {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") { dismiss() }.disabled(saving)
        }
        ToolbarItem(placement: .confirmationAction) {
            Button("Save") { Task { await save() } }
                .disabled(saving)
        }
    }

    private func save() async {
        saving = true
        error = nil
        defer { saving = false }
        guard case .signedIn(_, let household) = appEnv.auth.state else {
            error = "Not signed in."
            return
        }
        let input = SeedkeepClient.CreatePlantingEventInput(
            bed_id: selectedBedID,
            seed_id: selectedSeedID,
            catalog_seed_id: nil,
            kind: kind,
            planned_for: Self.yyyymmdd(plannedFor),
            completed_at: nil,
            notes: notes.trimmedNonEmpty
        )
        do {
            _ = try appEnv.sync.enqueueCreatePlantingEvent(input, householdID: household.id)
            await appEnv.syncIfPossible()
            dismiss()
        } catch let err as SeedkeepError {
            error = "\(err.code): \(err.message)"
        } catch {
            self.error = error.localizedDescription
        }
    }

    private static func yyyymmdd(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        return f.string(from: date)
    }
}
