import SwiftUI
import SwiftData
import SeedkeepKit

/// Manual-entry sheet for adding a new seed packet. Used both as the
/// "+" tap (no prefill) and as the post-scan confirmation screen
/// (prefilled from an on-device or BYOK extraction; see `Prefill`).
struct AddSeedView: View {
    /// Pre-fill source. `.localExtraction` populates the fields from an
    /// on-device (Free) or BYOK extraction. The scan's two photos are staged
    /// under `scanID` and attach to the seed when it saves (N2).
    enum Prefill: Equatable {
        case localExtraction(scanID: UUID, fields: WireResponses.ExtractionFields,
                             binding: ScanPhotoStaging.ScanBinding?)
    }

    let prefill: Prefill?

    init(prefill: Prefill? = nil) {
        self.prefill = prefill
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(AppEnvironment.self) private var appEnv

    @Query(filter: #Predicate<LocalLocation> { $0.deletedAt == nil },
           sort: \.sortOrder, order: .forward)
    private var locations: [LocalLocation]

    @Query(filter: #Predicate<LocalTag> { $0.deletedAt == nil },
           sort: \.name, order: .forward)
    private var tags: [LocalTag]

    @State private var state: SeedState = .active
    @State private var name: String = ""
    @State private var variety: String = ""
    @State private var company: String = ""
    @State private var packetCount: Int = 1
    @State private var locationID: String?
    @State private var selectedTagIDs: Set<String> = []
    @State private var yearPacked: Int?
    @State private var notes: String = ""
    @State private var source: SeedSource = .store

    /// Chooses the seed ID up front and creates the seed once, so a retry after a partial save
    /// finishes that seed and never creates a second one.
    @State private var saveSession = SeedSaveSession()
    /// Mirrors `saveSession.seedCreated` for the view (the session is not observed).
    @State private var seedCreated = false
    @State private var saving = false
    @State private var saveError: String?
    @State private var didApplyPrefill = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(prefill == nil ? "Lay a new packet" : "Confirm specimen")
                            .font(HerbFont.smallCaps(size: 10))
                            .tracking(2)
                            .foregroundStyle(HerbColor.sepia)
                            .textCase(.uppercase)
                        Text(prefill == nil ? "Add seed" : "Specimen review")
                            .font(HerbFont.display(size: 30))
                            .foregroundStyle(HerbColor.ink)
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 6, leading: 20, bottom: 6, trailing: 20))
                    .listRowSeparator(.hidden)
                }
                if prefill != nil {
                    Section { prefillBanner }
                }
                extractedGrowingInfoSection
                Section {
                    Picker("State", selection: $state) {
                        Text("Active").tag(SeedState.active)
                        Text("Wishlist").tag(SeedState.wishlist)
                        Text("Saved").tag(SeedState.saved)
                        Text("Archive").tag(SeedState.archived)
                    }
                } header: {
                    Rubric(text: "lifecycle")
                }

                Section {
                    TextField("Name (e.g. Cherokee Purple)", text: $name)
                        #if os(iOS)
                        .textInputAutocapitalization(.words)
                        #endif
                    TextField("Variety (optional)", text: $variety)
                        #if os(iOS)
                        .textInputAutocapitalization(.words)
                        #endif
                    TextField("Company (e.g. Baker Creek)", text: $company)
                        #if os(iOS)
                        .textInputAutocapitalization(.words)
                        #endif
                } header: {
                    Rubric(text: "identity")
                }

                if state != .wishlist {
                    Section {
                        Stepper("\(packetCount) packet\(packetCount == 1 ? "" : "s")", value: $packetCount, in: 0...100)
                    } header: {
                        Rubric(text: "quantity")
                    }
                }

                Section {
                    Picker("Location", selection: $locationID) {
                        Text("None").tag(String?.none)
                        ForEach(activeLocations) { loc in
                            Text(loc.name).tag(Optional(loc.id))
                        }
                    }
                    if !activeTags.isEmpty {
                        NavigationLink {
                            TagPickerView(tags: activeTags, selection: $selectedTagIDs)
                        } label: {
                            HStack {
                                Text("Tags")
                                Spacer()
                                Text(selectedTagIDs.isEmpty ? "None" : "\(selectedTagIDs.count) selected")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Rubric(text: "storage")
                }

                Section {
                    Picker("Source", selection: $source) {
                        Text("Store-bought").tag(SeedSource.store)
                        Text("Self-saved").tag(SeedSource.saved)
                        Text("Gift").tag(SeedSource.gift)
                        Text("Swap").tag(SeedSource.swap)
                    }
                    YearField(year: $yearPacked)
                } header: {
                    Rubric(text: "provenance")
                }

                Section {
                    TextField("Notes", text: $notes, axis: .vertical)
                        .lineLimit(3...6)
                } header: {
                    Rubric(text: "notes")
                }

                if let saveError {
                    Section {
                        Text(saveError)
                            .font(.footnote)
                            .foregroundStyle(HerbColor.rose)
                    }
                }
            }
            .vellumForm()
            // Once the seed exists, its details are fixed; only Retry (finish the save) remains.
            .disabled(seedCreated)
            .navigationTitle(prefill == nil ? "Add seed" : "Confirm seed")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .onAppear {
                // The save belongs to the account and garden the scan started under, or, for a
                // manual add, the one the sheet opens under (V1). A scan without a binding never
                // saves: the session reports a scope change.
                if case .localExtraction(_, _, let scanBinding)? = prefill {
                    saveSession.bind(scanBinding)
                } else {
                    saveSession.bind(appEnv.scanBinding)
                }
                applyPrefillIfNeeded()
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        // An unsaved scan's staged photos go with it. Once the seed exists they stay,
                        // so the photos can still attach at the next launch.
                        if !seedCreated, let scanID {
                            ScanPhotoStaging.discard(scanID: scanID)
                        }
                        dismiss()
                    }
                    .disabled(saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(seedCreated ? "Retry" : "Save") { Task { await save() } }
                        .disabled(saving || !canSave)
                }
            }
        }
    }

    private var activeLocations: [LocalLocation] {
        guard let householdID = appEnv.activeGardenHouseholdID else { return [] }
        return locations.filter { $0.householdID == householdID }
    }

    private var activeTags: [LocalTag] {
        guard let householdID = appEnv.activeGardenHouseholdID else { return [] }
        return tags.filter { $0.householdID == householdID }
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The scan whose photos attach to this seed, when the sheet was opened from a scan.
    private var scanID: UUID? {
        if case .localExtraction(let scanID, _, _)? = prefill { return scanID }
        return nil
    }

    /// Surfaces the horticultural data the extractor pulled out of the
    /// packet photos so the user can review it before they hit Save. It is
    /// saved with this seed as its growing info (N2).
    @ViewBuilder
    private var extractedGrowingInfoSection: some View {
        if let fields = extractedFields, Self.hasAnyExtracted(fields) {
            Section {
                if let sci = fields.scientific_name {
                    LabeledContent("Scientific name") { Text(sci).italic() }
                }
                if let life = Self.humanLifeCycle(fields.life_cycle) {
                    LabeledContent("Life cycle", value: life)
                }
                if let sun = Self.humanSun(fields.sun_requirement) {
                    LabeledContent("Sun", value: sun)
                }
                if let frost = Self.humanFrost(fields.frost_tolerance) {
                    LabeledContent("Frost tolerance", value: frost)
                }
                if let sow = Self.humanSow(fields.sow_method) {
                    LabeledContent("Sow method", value: sow)
                }
                if let depth = fields.seed_depth_inches {
                    LabeledContent("Seed depth", value: Self.formatInches(depth))
                }
                if let germ = Self.formatRange(min: fields.days_to_germinate_min, max: fields.days_to_germinate_max, unit: "days") {
                    LabeledContent("Sprouts in", value: germ)
                }
                if let mature = Self.formatRange(min: fields.days_to_maturity_min, max: fields.days_to_maturity_max, unit: "days") {
                    LabeledContent("Days to maturity", value: mature)
                }
                if let soil = Self.formatRange(min: fields.soil_temp_min_f, max: fields.soil_temp_max_f, unit: "°F") {
                    LabeledContent("Soil temperature", value: soil)
                }
                if let plant = fields.plant_spacing_inches {
                    LabeledContent("Plant spacing", value: "\(plant)\"")
                }
                if let row = fields.row_spacing_inches {
                    LabeledContent("Row spacing", value: "\(row)\"")
                }
                if let zones = Self.formatRange(min: fields.hardiness_zone_min, max: fields.hardiness_zone_max, unit: nil) {
                    LabeledContent("Hardiness zones", value: zones)
                }
            } header: {
                Rubric(text: "growing info (extracted)")
            } footer: {
                Text("Read from the packet photos. Saved with this seed.")
            }
        }
    }

    private var extractedFields: WireResponses.ExtractionFields? {
        switch prefill {
        case .localExtraction(_, let fields, _): return fields
        case .none: return nil
        }
    }

    private static func hasAnyExtracted(_ f: WireResponses.ExtractionFields) -> Bool {
        f.scientific_name != nil
            || f.life_cycle != nil
            || f.sun_requirement != nil
            || f.frost_tolerance != nil
            || f.sow_method != nil
            || f.seed_depth_inches != nil
            || f.days_to_germinate_min != nil || f.days_to_germinate_max != nil
            || f.days_to_maturity_min != nil || f.days_to_maturity_max != nil
            || f.soil_temp_min_f != nil || f.soil_temp_max_f != nil
            || f.plant_spacing_inches != nil
            || f.row_spacing_inches != nil
            || f.hardiness_zone_min != nil || f.hardiness_zone_max != nil
    }

    private static func humanLifeCycle(_ raw: String?) -> String? {
        switch raw {
        case "annual": return "Annual"
        case "biennial": return "Biennial"
        case "perennial": return "Perennial"
        default: return nil
        }
    }

    private static func humanSun(_ raw: String?) -> String? {
        switch raw {
        case "full": return "Full sun"
        case "partial": return "Partial sun"
        case "shade": return "Shade"
        default: return nil
        }
    }

    private static func humanFrost(_ raw: String?) -> String? {
        switch raw {
        case "tender": return "Tender (killed by frost)"
        case "half_hardy": return "Half-hardy (tolerates light frost)"
        case "hardy": return "Hardy (tolerates freezes)"
        default: return nil
        }
    }

    private static func humanSow(_ raw: String?) -> String? {
        switch raw {
        case "direct": return "Direct sow"
        case "transplant": return "Start indoors, transplant"
        case "either": return "Direct or transplant"
        default: return nil
        }
    }

    private static func formatInches(_ value: Double) -> String {
        let twentieths = (value * 20).rounded() / 20
        switch twentieths {
        case 0.25: return "1/4\""
        case 0.5: return "1/2\""
        case 0.75: return "3/4\""
        case 1: return "1\""
        default:
            let formatter = NumberFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.maximumFractionDigits = 2
            formatter.minimumFractionDigits = 0
            return "\(formatter.string(from: NSNumber(value: value)) ?? "\(value)")\""
        }
    }

    private static func formatRange(min: Int?, max: Int?, unit: String?) -> String? {
        let suffix = unit.map { " \($0)" } ?? ""
        switch (min, max) {
        case let (a?, b?) where a == b: return "\(a)\(suffix)"
        case let (a?, b?): return "\(a)–\(b)\(suffix)"
        case let (a?, nil): return "\(a)+\(suffix)"
        case let (nil, b?): return "≤\(b)\(suffix)"
        default: return nil
        }
    }

    @ViewBuilder
    private var prefillBanner: some View {
        switch prefill {
        case .localExtraction(_, let fields, _):
            HerbBanner(
                severity: .info,
                title: "Read from the packet",
                message: fields.self_confidence.map { "Please review. Self-confidence: \(String(format: "%.2f", $0))" }
                    ?? "Please review."
            )
        case .none:
            EmptyView()
        }
    }

    private func applyPrefillIfNeeded() {
        guard !didApplyPrefill, let prefill else { return }
        didApplyPrefill = true
        switch prefill {
        case .localExtraction(_, let fields, _):
            name = fields.common_name ?? ""
            variety = fields.variety ?? ""
            company = fields.company ?? ""
            notes = fields.instructions ?? ""
        }
    }

    private func save() async {
        saving = true
        saveError = nil
        defer { saving = false }

        guard case .signedIn = appEnv.auth.state else {
            saveError = "Not signed in."
            return
        }

        let input = SeedkeepClient.CreateSeedInput(
            state: state,
            packet_count: state == .wishlist ? 0 : packetCount,
            location_id: locationID,
            year_packed: yearPacked,
            source: source,
            custom_name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            custom_variety: variety.trimmedNonEmpty,
            custom_company: company.trimmedNonEmpty,
            notes: notes.trimmedNonEmpty,
            tag_ids: Array(selectedTagIDs)
        )

        do {
            // A retry after a partial save finishes the seed that exists. It never creates a second one.
            defer { seedCreated = saveSession.seedCreated }
            try await saveSession.save(
                input,
                scanID: scanID,
                snapshot: buildGrowingInfoSnapshot(),
                customType: inferredCustomType(),
                writer: appEnv.sync,
                current: { [appEnv] in appEnv.scanBinding }
            )
            // Dismiss immediately — the seed is in local SwiftData, the user
            // sees it in Library right away. The server push is retired (N2), so there is nothing to flush.
            if !ServerRetirement.isRetired {
                Task { try? await appEnv.sync.flushPending() }
            }
            dismiss()
        } catch is SeedSaveSession.ScopeChanged {
            // The account or garden changed under the sheet: its scan is discarded, and it closes.
            appEnv.surfaceMessage(ScanPhotoStaging.scopeChangedNotice)
            dismiss()
        } catch {
            saveError = !saveSession.seedCreated
                ? error.localizedDescription
                : "The seed is saved, but part of it is not: \(error.localizedDescription). Tap Retry to finish."
        }
    }

    /// Default type guess for a freshly-added seed. Pulls from the
    /// extraction's `common_name`, the canonical "what crop is this" value
    /// (e.g. "Pepper", "Tomato"). The user can always override it later in
    /// the detail view.
    private func inferredCustomType() -> String? {
        switch prefill {
        case .localExtraction(_, let fields, _):
            return fields.common_name?.trimmedNonEmpty
        case .none:
            return nil
        }
    }

    /// Builds the local snapshot from the extraction. Returns nil for manual entries.
    private func buildGrowingInfoSnapshot() -> GrowingInfoSnapshot? {
        switch prefill {
        case .localExtraction(_, let fields, _):
            return Self.snapshot(from: fields)
        case .none:
            return nil
        }
    }

    private static func snapshot(from f: WireResponses.ExtractionFields) -> GrowingInfoSnapshot {
        GrowingInfoSnapshot(
            scientific_name: f.scientific_name,
            life_cycle: f.life_cycle,
            sun_requirement: f.sun_requirement,
            frost_tolerance: f.frost_tolerance,
            sow_method: f.sow_method,
            seed_depth_inches: f.seed_depth_inches,
            days_to_germinate_min: f.days_to_germinate_min,
            days_to_germinate_max: f.days_to_germinate_max,
            days_to_maturity_min: f.days_to_maturity_min,
            days_to_maturity_max: f.days_to_maturity_max,
            soil_temp_min_f: f.soil_temp_min_f,
            soil_temp_max_f: f.soil_temp_max_f,
            plant_spacing_inches: f.plant_spacing_inches,
            row_spacing_inches: f.row_spacing_inches,
            hardiness_zone_min: f.hardiness_zone_min,
            hardiness_zone_max: f.hardiness_zone_max,
            instructions: f.instructions
        )
    }
}

private struct TagPickerView: View {
    let tags: [LocalTag]
    @Binding var selection: Set<String>

    var body: some View {
        List(tags) { tag in
            Button {
                if selection.contains(tag.id) {
                    selection.remove(tag.id)
                } else {
                    selection.insert(tag.id)
                }
            } label: {
                HStack {
                    Text(tag.name)
                    Spacer()
                    if selection.contains(tag.id) {
                        Image(systemName: "checkmark")
                            .foregroundStyle(.tint)
                    }
                }
            }
            .buttonStyle(.plain)
        }
        .navigationTitle("Tags")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

private struct YearField: View {
    @Binding var year: Int?
    private let currentYear = Calendar(identifier: .gregorian).component(.year, from: Date())

    var body: some View {
        Picker("Year packed", selection: $year) {
            Text("Unknown").tag(Int?.none)
            ForEach((currentYear - 8 ... currentYear + 1).reversed(), id: \.self) { y in
                Text(String(y)).tag(Optional(y))
            }
        }
    }
}

extension String {
    var trimmedNonEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
