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
            _ = try appEnv.sync.enqueueCreateSeed(input, householdID: household.id)
            try? await appEnv.sync.flushPending()
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
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

private extension String {
    var trimmedNonEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
