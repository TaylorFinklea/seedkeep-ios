import SwiftUI
import SwiftData
import SeedkeepKit

/// Manual-entry sheet for adding a new seed packet. Used both as the
/// "+" tap (no prefill) and as the post-scan confirmation screen
/// (prefilled from a catalog hit or AI extraction; see `Prefill`).
struct AddSeedView: View {
    /// Pre-fill source. `.catalog` populates fields from a confirmed
    /// catalog match; `.extraction` populates them from server-side AI
    /// vision (Hosted tier); `.preExtraction` populates them from
    /// on-device extraction (Free / BYOK tier). All three render a
    /// review banner so the user knows what they're spot-checking.
    enum Prefill: Equatable {
        case catalog(barcode: String?, CatalogSeedDTO)
        case extraction(WireResponses.ExtractionResult, barcode: String?)
        case preExtraction(WireResponses.PreExtractedResult, barcode: String?)
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

    @State private var catalogID: String?
    @State private var saving = false
    @State private var saveError: String?
    @State private var didApplyPrefill = false

    var body: some View {
        NavigationStack {
            Form {
                if prefill != nil {
                    Section { prefillBanner }
                }
                extractedGrowingInfoSection
                Section("Lifecycle") {
                    Picker("State", selection: $state) {
                        Text("Active").tag(SeedState.active)
                        Text("Wishlist").tag(SeedState.wishlist)
                        Text("Saved").tag(SeedState.saved)
                        Text("Archive").tag(SeedState.archived)
                    }
                }

                Section("Identity") {
                    TextField("Name (e.g. Cherokee Purple)", text: $name)
                        .textInputAutocapitalization(.words)
                    TextField("Variety (optional)", text: $variety)
                        .textInputAutocapitalization(.words)
                    TextField("Company (e.g. Baker Creek)", text: $company)
                        .textInputAutocapitalization(.words)
                }

                if state != .wishlist {
                    Section("Quantity") {
                        Stepper("\(packetCount) packet\(packetCount == 1 ? "" : "s")", value: $packetCount, in: 0...100)
                    }
                }

                Section("Storage") {
                    Picker("Location", selection: $locationID) {
                        Text("None").tag(String?.none)
                        ForEach(locations) { loc in
                            Text(loc.name).tag(Optional(loc.id))
                        }
                    }
                    if !tags.isEmpty {
                        NavigationLink {
                            TagPickerView(tags: tags, selection: $selectedTagIDs)
                        } label: {
                            HStack {
                                Text("Tags")
                                Spacer()
                                Text(selectedTagIDs.isEmpty ? "None" : "\(selectedTagIDs.count) selected")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Section("Provenance") {
                    Picker("Source", selection: $source) {
                        Text("Store-bought").tag(SeedSource.store)
                        Text("Self-saved").tag(SeedSource.saved)
                        Text("Gift").tag(SeedSource.gift)
                        Text("Swap").tag(SeedSource.swap)
                    }
                    YearField(year: $yearPacked)
                }

                Section("Notes") {
                    TextField("Notes", text: $notes, axis: .vertical)
                        .lineLimit(3...6)
                }

                if let saveError {
                    Section {
                        Text(saveError)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(prefill == nil ? "Add seed" : "Confirm seed")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { applyPrefillIfNeeded() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(saving || !canSave)
                }
            }
        }
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Surfaces the horticultural data the extractor pulled out of the
    /// packet photos so the user can review *what* will land in the
    /// global catalog before they hit Save. Read-only — these fields
    /// belong to the catalog entry, not the per-household seed, and
    /// editing the catalog is a Phase 2 moderation flow.
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
                Text("Growing info (extracted)")
            } footer: {
                Text("Surfaced from the packet. Will be added to the shared catalog so other households who scan the same packet get an instant match.")
            }
        }
    }

    private var extractedFields: WireResponses.ExtractionFields? {
        switch prefill {
        case .extraction(let result, _): return result.extraction
        case .preExtraction(let result, _): return result.extraction
        case .catalog, .none: return nil
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
        case .catalog:
            Label {
                Text("Pre-filled from catalog. Review and confirm.")
                    .font(.footnote)
            } icon: {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(.green)
            }
        case .extraction(let result, _):
            VStack(alignment: .leading, spacing: 4) {
                Label {
                    Text("AI-extracted from photos. Please review.")
                        .font(.footnote.weight(.medium))
                } icon: {
                    Image(systemName: "sparkles")
                        .foregroundStyle(.orange)
                }
                Text("Reviewer score: \(String(format: "%.2f", result.review.score)) — \(result.decision.status)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .preExtraction(let result, _):
            VStack(alignment: .leading, spacing: 4) {
                Label {
                    Text("Extracted on-device. Please review.")
                        .font(.footnote.weight(.medium))
                } icon: {
                    Image(systemName: "iphone.gen3")
                        .foregroundStyle(.blue)
                }
                Text("Self-confidence: \(String(format: "%.2f", result.review.score)) — \(result.decision.status)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .none:
            EmptyView()
        }
    }

    private func applyPrefillIfNeeded() {
        guard !didApplyPrefill, let prefill else { return }
        didApplyPrefill = true
        switch prefill {
        case .catalog(_, let cat):
            name = cat.common_name
            variety = cat.variety ?? ""
            company = cat.company ?? ""
            notes = cat.instructions ?? ""
            catalogID = cat.id
        case .extraction(let result, _):
            name = result.extraction.common_name ?? ""
            variety = result.extraction.variety ?? ""
            company = result.extraction.company ?? ""
            notes = result.extraction.instructions ?? ""
            catalogID = result.catalog_seed_id
        case .preExtraction(let result, _):
            name = result.extraction.common_name ?? ""
            variety = result.extraction.variety ?? ""
            company = result.extraction.company ?? ""
            notes = result.extraction.instructions ?? ""
            catalogID = result.catalog_seed_id
        }
    }

    private func save() async {
        saving = true
        saveError = nil
        defer { saving = false }

        guard case .signedIn(_, let household) = appEnv.auth.state else {
            saveError = "Not signed in."
            return
        }

        let input = SeedkeepClient.CreateSeedInput(
            catalog_id: catalogID,
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
            let local = try appEnv.sync.enqueueCreateSeed(input, householdID: household.id)
            if let snapshot = buildGrowingInfoSnapshot(), snapshot.hasAny {
                try? appEnv.sync.setLocalGrowingInfo(seedID: local.id, snapshot: snapshot)
            }
            if let inferredType = inferredCustomType() {
                try? appEnv.sync.setLocalCustomType(seedID: local.id, type: inferredType)
            }
            try? await appEnv.sync.flushPending()
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }

    /// Default type guess for a freshly-added seed. Pulls from the
    /// extraction or catalog `common_name` because that's the canonical
    /// "what crop is this" value (e.g. "Pepper", "Tomato"). The user can
    /// always override it later in the detail view.
    private func inferredCustomType() -> String? {
        switch prefill {
        case .catalog(_, let cat):
            return cat.common_name.trimmedNonEmpty
        case .extraction(let result, _):
            return result.extraction.common_name?.trimmedNonEmpty
        case .preExtraction(let result, _):
            return result.extraction.common_name?.trimmedNonEmpty
        case .none:
            return nil
        }
    }

    /// Builds the local snapshot from whichever prefill source we have.
    /// Returns nil for manual entries with no extraction or catalog data.
    private func buildGrowingInfoSnapshot() -> GrowingInfoSnapshot? {
        switch prefill {
        case .catalog(_, let cat):
            return GrowingInfoSnapshot(
                scientific_name: cat.scientific_name,
                life_cycle: cat.life_cycle,
                sun_requirement: cat.sun_requirement,
                frost_tolerance: cat.frost_tolerance,
                sow_method: cat.sow_method,
                seed_depth_inches: cat.seed_depth_inches,
                days_to_germinate_min: cat.days_to_germinate_min,
                days_to_germinate_max: cat.days_to_germinate_max,
                days_to_maturity_min: cat.days_to_maturity_min,
                days_to_maturity_max: cat.days_to_maturity_max,
                soil_temp_min_f: cat.soil_temp_min_f,
                soil_temp_max_f: cat.soil_temp_max_f,
                plant_spacing_inches: cat.plant_spacing_inches,
                row_spacing_inches: cat.row_spacing_inches,
                hardiness_zone_min: cat.hardiness_zone_min,
                hardiness_zone_max: cat.hardiness_zone_max,
                instructions: cat.instructions
            )
        case .extraction(let result, _):
            return Self.snapshot(from: result.extraction)
        case .preExtraction(let result, _):
            return Self.snapshot(from: result.extraction)
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
        .navigationBarTitleDisplayMode(.inline)
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
