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

    /// Catalog metadata for the currently selected seed. Used to compute
    /// the frost warning. Cached by catalogID inside the view so changing
    /// the seed selection re-fetches lazily.
    @State private var catalogCache: [String: CatalogSeedDTO?] = [:]
    @State private var currentCatalog: CatalogSeedDTO?

    var body: some View {
        NavigationStack {
            Form {
                actionSection
                whereSection
                frostWarningSection
                notesSection
                errorSection
            }
            .navigationTitle("Plan event")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .onAppear {
                if selectedBedID == nil { selectedBedID = bedID }
                if selectedSeedID == nil { selectedSeedID = prefillSeedID }
                Task { await refreshCatalogForSelection() }
            }
            .onChange(of: selectedSeedID) { _, _ in
                Task { await refreshCatalogForSelection() }
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
    private var frostWarningSection: some View {
        if let warning = frostWarning {
            Section {
                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(warning.title)
                            .font(.subheadline.weight(.semibold))
                        Text(warning.detail)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "snowflake")
                        .foregroundStyle(.orange)
                }
                .padding(.vertical, 2)
            }
        } else if let lastFrost = appEnv.preferences.lastFrost {
            Section {
                Label {
                    Text("Last frost \(monthDayLabel(lastFrost))")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: "snowflake")
                        .foregroundStyle(.tint)
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

    // MARK: - Frost warning

    private struct FrostWarning {
        let title: String
        let detail: String
    }

    /// Returns a warning when the user is scheduling a *sow* (not transplant
    /// or harvest) before the last frost AND the catalog marks the plant
    /// as tender. Everything else just shows the no-op reference banner.
    private var frostWarning: FrostWarning? {
        guard kind == .sowing else { return nil }
        guard let lastFrost = appEnv.preferences.lastFrost else { return nil }
        guard let tolerance = currentCatalog?.frost_tolerance, tolerance == "tender" else { return nil }
        let cal = Calendar.current
        let year = cal.component(.year, from: plannedFor)
        guard let frostDate = lastFrost.date(inYear: year, calendar: cal) else { return nil }
        guard plannedFor < frostDate else { return nil }
        let label = monthDayLabel(lastFrost)
        let name = currentCatalog?.common_name ?? "this plant"
        return FrostWarning(
            title: "Before last frost",
            detail: "\(name) is tender — direct-sowing before your last frost (\(label)) risks losing the planting. Consider starting indoors and transplanting after \(label), or pick a later date."
        )
    }

    private func monthDayLabel(_ md: MonthDay) -> String {
        let cal = Calendar.current
        guard let date = md.date(inYear: cal.component(.year, from: Date())) else {
            return "\(md.month)/\(md.day)"
        }
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f.string(from: date)
    }

    @MainActor
    private func refreshCatalogForSelection() async {
        guard let seedID = selectedSeedID,
              let catalogID = seeds.first(where: { $0.id == seedID })?.catalogID else {
            currentCatalog = nil
            return
        }
        if let cached = catalogCache[catalogID] {
            currentCatalog = cached
            return
        }
        // Lookup miss — fetch and remember the result (including nil for
        // 404, so we don't re-fetch every time the user toggles seeds).
        let fetched = (try? await appEnv.client.catalogByID(catalogID)) ?? nil
        catalogCache[catalogID] = fetched
        currentCatalog = fetched
    }
}
