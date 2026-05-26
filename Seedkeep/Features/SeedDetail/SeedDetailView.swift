import SwiftUI
import SwiftData
import PhotosUI
import SeedkeepKit

/// Detail + edit view. The view loads the matching `LocalSeed` via id so
/// it stays in sync with the local store; edits go through the SyncEngine
/// (optimistic local + queued push).
struct SeedDetailView: View {
    let seedID: String

    @Environment(AppEnvironment.self) private var appEnv
    @Environment(\.dismiss) private var dismiss
    @Query private var seedQuery: [LocalSeed]
    @Query private var photoQuery: [LocalSeedPhoto]

    @Query(filter: #Predicate<LocalLocation> { $0.deletedAt == nil },
           sort: \.sortOrder, order: .forward)
    private var locations: [LocalLocation]

    @Query(filter: #Predicate<LocalTag> { $0.deletedAt == nil },
           sort: \.name, order: .forward)
    private var tags: [LocalTag]

    @State private var pendingDelete = false
    @State private var pickedPhoto: PhotosPickerItem?
    @State private var uploadingPhoto = false
    @State private var uploadError: String?
    @State private var showPlanEvent = false

    /// Cached recommendation for this seed's catalog entry. Loaded
    /// asynchronously in the `.task(id:)` alongside the catalog fetch.
    @State private var localRecommendation: LocalRecommendation?

    /// WeatherKit-refined recommendation, computed after the baseline loads
    /// when the household's lat/lon are available.
    @State private var refinedRecommendation: RefinedRecommendation?

    /// Local edit buffers for the Identity section. Mirrored from the seed
    /// on appear so TextFields can bind to non-optional Strings; pushed back
    /// through the sync queue on each change, flushed on disappear (same
    /// throttle pattern as Notes).
    @State private var typeDraft: String = ""
    @State private var nameDraft: String = ""
    @State private var varietyDraft: String = ""
    @State private var companyDraft: String = ""
    @State private var identityHydrated = false

    /// Catalog metadata (scientific name, growing conditions, etc.) fetched
    /// when the view appears if the seed is linked to a catalog entry.
    /// Stays nil for manually-entered seeds or while loading.
    @State private var catalog: CatalogSeedDTO?

    /// True while the catalog-feedback sheet is presented (Phase 4 D).
    @State private var showCatalogFeedback = false

    init(seedID: String) {
        self.seedID = seedID
        let id = seedID
        _seedQuery = Query(filter: #Predicate<LocalSeed> { $0.id == id })
        _photoQuery = Query(
            filter: #Predicate<LocalSeedPhoto> { $0.seedID == id },
            sort: \.capturedAt,
            order: .forward
        )
    }

    var body: some View {
        Group {
            if let seed = seedQuery.first {
                ZStack {
                    VellumBackground()
                    Form {
                        Section {
                            herbariumHero(seed)
                                .listRowBackground(Color.clear)
                                .listRowInsets(EdgeInsets())
                                .listRowSeparator(.hidden)
                        }
                        identitySection(seed)
                        photosSection(seed)
                        growingInfoSection(seed)
                        lifecycleSection(seed)
                        if seed.state != .wishlist {
                            quantitySection(seed)
                        }
                        storageSection(seed)
                        provenanceSection(seed)
                        notesSection(seed)
                        plantSection(seed)
                        EntityScopedJournalSection(parent: .seed(seed.id))
                        deleteSection(seed)
                    }
                    .scrollContentBackground(.hidden)
                }
                .sheet(isPresented: $showPlanEvent) {
                    AddPlantingEventView(bedID: nil, prefillSeedID: seedID)
                }
                .navigationTitle(seed.customName ?? "Seed")
                .navigationBarTitleDisplayMode(.inline)
                .publishesAssistantContext(pageType: "seed", entityID: seed.id, label: seed.customName)
                .task(id: seed.id) {
                    // Refresh photos on first appearance so the grid is
                    // current even if the local store predates new uploads.
                    if case .signedIn(_, let household) = appEnv.auth.state {
                        try? await appEnv.sync.refreshSeedPhotos(seedID: seed.id, householdID: household.id)
                    }
                    // Fetch the catalog entry for the growing-info section.
                    // Used both as a display fallback and to backfill the
                    // local snapshot for seeds saved before snapshots
                    // existed. Failures are silent — the section falls back
                    // to the local snapshot (or hides entirely).
                    if let catalogID = seed.catalogID {
                        catalog = try? await appEnv.client.catalogByID(catalogID)
                        if seed.growingInfo == nil, let cat = catalog {
                            let snap = Self.snapshot(from: cat)
                            if snap.hasAny {
                                try? appEnv.sync.setLocalGrowingInfo(seedID: seed.id, snapshot: snap)
                            }
                        }
                        // Refresh the planting-window recommendation from the server
                        // and read back the cached result for the panel.
                        await appEnv.recommendations.refresh(catalogSeedID: catalogID)
                        localRecommendation = appEnv.recommendations.recommendation(for: catalogID)
                        // Apply WeatherKit refinement when coordinates are available.
                        if let lat = appEnv.preferences.cachedLatitude,
                           let lon = appEnv.preferences.cachedLongitude {
                            let growingInfo = effectiveGrowingInfo(seed)
                            refinedRecommendation = await appEnv.recommendations.refinedRecommendation(
                                for: catalogID,
                                householdLat: lat,
                                householdLon: lon,
                                frostTolerance: growingInfo?.frost_tolerance,
                                soilTempMaxF: growingInfo?.soil_temp_max_f
                            )
                        }
                    }
                }
            } else {
                ContentUnavailableView(
                    "Seed unavailable",
                    systemImage: "leaf.slash",
                    description: Text("This seed may have been deleted on another device.")
                )
            }
        }
    }

    // MARK: - Herbarium hero

    /// Top "specimen page" block — scholarly binomial + italic display
    /// name, central pressed-plant illustration with a hand-drawn ruler.
    /// Pulled into the Form as a section-less row with transparent
    /// background so it floats on the vellum.
    @ViewBuilder
    private func herbariumHero(_ seed: LocalSeed) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(scientificDisplay(seed))
                .font(HerbFont.bodyItalic(size: 14))
                .foregroundStyle(HerbColor.sepia)
            Text(seed.customName ?? "Untitled specimen")
                .font(HerbFont.display(size: 32))
                .foregroundStyle(HerbColor.ink)
                .lineSpacing(0)
            Text(familyLine(seed))
                .font(HerbFont.bodyItalic(size: 12))
                .foregroundStyle(HerbColor.inkSoft)
                .padding(.top, 2)
            ScholarRule(verticalMargin: 8)
            ZStack {
                PressedPlant(kind: PressedPlant.Kind.from(seed.customType), size: 200)
                    .frame(height: 200)
                HStack {
                    Spacer()
                    rulerColumn
                }
                .padding(.trailing, 12)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 6)
    }

    @ViewBuilder
    private var rulerColumn: some View {
        VStack(spacing: 0) {
            ForEach(0..<9) { i in
                HStack(spacing: 4) {
                    Text("\(i)")
                        .font(HerbFont.smallCaps(size: 7))
                        .foregroundStyle(HerbColor.sepia)
                    Rectangle()
                        .fill(HerbColor.sepia)
                        .frame(width: 10, height: 0.6)
                }
                if i < 8 {
                    Rectangle()
                        .fill(HerbColor.sepia)
                        .frame(width: 0.6, height: 20)
                }
            }
            Text("INCHES")
                .font(HerbFont.smallCaps(size: 7))
                .tracking(1)
                .foregroundStyle(HerbColor.sepia)
                .padding(.top, 4)
        }
    }

    private func scientificDisplay(_ seed: LocalSeed) -> String {
        if let snap = seed.growingInfo?.scientific_name, !snap.isEmpty { return snap }
        return seed.customType ?? "—"
    }

    private func familyLine(_ seed: LocalSeed) -> String {
        let variety = seed.customVariety.map { ", \($0)" } ?? ""
        return "cv. \((seed.customCompany ?? "—").lowercased())\(variety)"
    }

    // MARK: - Sections

    @ViewBuilder
    private func photosSection(_ seed: LocalSeed) -> some View {
        Section("Photos") {
            if photoQuery.isEmpty {
                Text("No photos yet")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(photoQuery, id: \.id) { photo in
                            AuthedImage(photoID: photo.id, contentMode: .fill)
                                .frame(width: 96, height: 96)
                                .clipped()
                                .clipShape(.rect(cornerRadius: 10))
                                .overlay(alignment: .bottomLeading) {
                                    Text(photo.role.rawValue)
                                        .font(.caption2.weight(.medium))
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1)
                                        .background(.black.opacity(0.6), in: .capsule)
                                        .foregroundStyle(.white)
                                        .padding(4)
                                }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            HStack {
                PhotosPicker(
                    selection: $pickedPhoto,
                    matching: .images,
                    photoLibrary: .shared()
                ) {
                    Label(uploadingPhoto ? "Uploading…" : "Add photo", systemImage: "photo.badge.plus")
                }
                .disabled(uploadingPhoto)
                if uploadingPhoto {
                    ProgressView().controlSize(.small)
                }
            }
            if let uploadError {
                Text(uploadError)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
        .onChange(of: pickedPhoto) { _, item in
            guard let item else { return }
            Task { await uploadPicked(item, seedID: seed.id) }
        }
    }

    private func uploadPicked(_ item: PhotosPickerItem, seedID: String) async {
        uploadingPhoto = true
        uploadError = nil
        defer { uploadingPhoto = false; pickedPhoto = nil }

        guard case .signedIn(_, let household) = appEnv.auth.state else {
            uploadError = "Not signed in."
            return
        }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                uploadError = "Couldn't read the selected photo."
                return
            }
            let jpeg = jpegEncode(originalData: data) ?? data
            try await appEnv.sync.uploadPhoto(
                seedID: seedID,
                role: .extra,
                jpegData: jpeg,
                householdID: household.id
            )
        } catch let err as SeedkeepError {
            uploadError = "\(err.code): \(err.message)"
        } catch {
            uploadError = error.localizedDescription
        }
    }

    /// Convert HEIC/PNG bytes from the photo picker into a reasonably-sized
    /// JPEG so the upload body stays manageable. ~75% quality balances
    /// quality vs. wire size for packet photos.
    private func jpegEncode(originalData: Data) -> Data? {
        guard let image = UIImage(data: originalData) else { return nil }
        return image.jpegData(compressionQuality: 0.75)
    }

    /// Growing information for the seed. Reads from the local snapshot
    /// captured at save time so it works offline, for manual entries, and
    /// before the catalog row has been populated. Falls back to the live
    /// catalog fetch when no snapshot exists yet. Hidden when neither has
    /// any data.
    @ViewBuilder
    private func growingInfoSection(_ seed: LocalSeed) -> some View {
        if let info = effectiveGrowingInfo(seed), info.hasAny {
            Section {
                if let sci = info.scientific_name {
                    LabeledContent("Scientific name") {
                        Text(sci).italic()
                    }
                }
                if let life = humanLifeCycle(info.life_cycle) {
                    LabeledContent("Life cycle", value: life)
                }
                if let sun = humanSun(info.sun_requirement) {
                    LabeledContent("Sun", value: sun)
                }
                if let frost = humanFrost(info.frost_tolerance) {
                    LabeledContent("Frost tolerance", value: frost)
                }
                if let sow = humanSow(info.sow_method) {
                    LabeledContent("Sow method", value: sow)
                }
                if let depth = info.seed_depth_inches {
                    LabeledContent("Seed depth", value: formatInches(depth))
                }
                if let germ = formatRange(min: info.days_to_germinate_min, max: info.days_to_germinate_max, unit: "days") {
                    LabeledContent("Days to germinate", value: germ)
                }
                if let mature = formatRange(min: info.days_to_maturity_min, max: info.days_to_maturity_max, unit: "days") {
                    LabeledContent("Days to maturity", value: mature)
                }
                if let soil = formatRange(min: info.soil_temp_min_f, max: info.soil_temp_max_f, unit: "°F") {
                    LabeledContent("Soil temperature", value: soil)
                }
                if let plant = info.plant_spacing_inches {
                    LabeledContent("Plant spacing", value: "\(plant)\"")
                }
                if let row = info.row_spacing_inches {
                    LabeledContent("Row spacing", value: "\(row)\"")
                }
                if let zones = formatRange(min: info.hardiness_zone_min, max: info.hardiness_zone_max, unit: nil) {
                    LabeledContent("Hardiness zones", value: zones)
                }
                if let inst = info.instructions, !inst.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Instructions")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                        Text(inst)
                            .font(.body)
                    }
                    .padding(.vertical, 4)
                }
                // Phase 4 D — let the user flag a correction. Only
                // surface for catalog-linked seeds, since the queue
                // submits a `catalog_seed_id`.
                if seed.catalogID != nil {
                    Button {
                        showCatalogFeedback = true
                    } label: {
                        HStack(spacing: 6) {
                            Text("◇")
                                .foregroundStyle(HerbColor.sepia)
                            Text("Suggest a correction")
                                .font(HerbFont.smallCaps(size: 10))
                                .tracking(1.4)
                                .foregroundStyle(HerbColor.sepia)
                                .textCase(.uppercase)
                        }
                    }
                }
            } header: {
                Text("Growing info")
            } footer: {
                Text(growingInfoFooter(seed))
            }
            .sheet(isPresented: $showCatalogFeedback) {
                if let catalogID = seed.catalogID {
                    CatalogFeedbackSheet(
                        catalogID: catalogID,
                        catalogName: catalog?.common_name ?? seed.customName
                    )
                }
            }
        }
    }

    /// Prefer the on-seed snapshot (offline-safe, survives catalog gaps)
    /// and fall back to the freshly-fetched catalog while it's loading or
    /// for legacy seeds without a snapshot.
    private func effectiveGrowingInfo(_ seed: LocalSeed) -> GrowingInfoSnapshot? {
        if let snap = seed.growingInfo, snap.hasAny { return snap }
        guard let catalog else { return nil }
        return Self.snapshot(from: catalog)
    }

    private func growingInfoFooter(_ seed: LocalSeed) -> String {
        if let catalog {
            let variety = catalog.variety.map { " — \($0)" } ?? ""
            return "From the catalog (\(catalog.common_name)\(variety)). Phase 2 will let you correct or annotate these."
        }
        return "Captured from the seed packet. Phase 2 will let you correct or annotate these."
    }

    fileprivate static func snapshot(from c: CatalogSeedDTO) -> GrowingInfoSnapshot {
        GrowingInfoSnapshot(
            scientific_name: c.scientific_name,
            life_cycle: c.life_cycle,
            sun_requirement: c.sun_requirement,
            frost_tolerance: c.frost_tolerance,
            sow_method: c.sow_method,
            seed_depth_inches: c.seed_depth_inches,
            days_to_germinate_min: c.days_to_germinate_min,
            days_to_germinate_max: c.days_to_germinate_max,
            days_to_maturity_min: c.days_to_maturity_min,
            days_to_maturity_max: c.days_to_maturity_max,
            soil_temp_min_f: c.soil_temp_min_f,
            soil_temp_max_f: c.soil_temp_max_f,
            plant_spacing_inches: c.plant_spacing_inches,
            row_spacing_inches: c.row_spacing_inches,
            hardiness_zone_min: c.hardiness_zone_min,
            hardiness_zone_max: c.hardiness_zone_max,
            instructions: c.instructions
        )
    }

    private func humanLifeCycle(_ raw: String?) -> String? {
        switch raw {
        case "annual": return "Annual"
        case "biennial": return "Biennial"
        case "perennial": return "Perennial"
        default: return nil
        }
    }

    private func humanSun(_ raw: String?) -> String? {
        switch raw {
        case "full": return "Full sun"
        case "partial": return "Partial sun"
        case "shade": return "Shade"
        default: return nil
        }
    }

    private func humanFrost(_ raw: String?) -> String? {
        switch raw {
        case "tender": return "Tender (killed by frost)"
        case "half_hardy": return "Half-hardy (tolerates light frost)"
        case "hardy": return "Hardy (tolerates freezes)"
        default: return nil
        }
    }

    private func humanSow(_ raw: String?) -> String? {
        switch raw {
        case "direct": return "Direct sow"
        case "transplant": return "Start indoors, transplant"
        case "either": return "Direct or transplant"
        default: return nil
        }
    }

    private func formatInches(_ value: Double) -> String {
        // Show common fractions for the most-printed depths.
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

    private func formatRange(min: Int?, max: Int?, unit: String?) -> String? {
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
    private func identitySection(_ seed: LocalSeed) -> some View {
        Section("Identity") {
            TextField("Type (e.g. Pepper)", text: $typeDraft)
                .textInputAutocapitalization(.words)
                .onChange(of: typeDraft) { _, new in
                    guard identityHydrated else { return }
                    // Local-only field — write straight through the sync
                    // engine's local helper rather than the server patch
                    // queue. Server sync lands in a Phase 2 follow-up.
                    try? appEnv.sync.setLocalCustomType(seedID: seed.id, type: new)
                }
            TextField("Name (e.g. Cherokee Purple)", text: $nameDraft)
                .textInputAutocapitalization(.words)
                .onChange(of: nameDraft) { _, new in
                    guard identityHydrated else { return }
                    let trimmed = new.trimmingCharacters(in: .whitespacesAndNewlines)
                    try? appEnv.sync.enqueueUpdateSeed(
                        id: seed.id,
                        .init(custom_name: trimmed.isEmpty ? nil : trimmed)
                    )
                }
            TextField("Variety (optional)", text: $varietyDraft)
                .textInputAutocapitalization(.words)
                .onChange(of: varietyDraft) { _, new in
                    guard identityHydrated else { return }
                    let trimmed = new.trimmingCharacters(in: .whitespacesAndNewlines)
                    try? appEnv.sync.enqueueUpdateSeed(
                        id: seed.id,
                        .init(custom_variety: trimmed.isEmpty ? nil : trimmed)
                    )
                }
            TextField("Company (e.g. Baker Creek)", text: $companyDraft)
                .textInputAutocapitalization(.words)
                .onChange(of: companyDraft) { _, new in
                    guard identityHydrated else { return }
                    let trimmed = new.trimmingCharacters(in: .whitespacesAndNewlines)
                    try? appEnv.sync.enqueueUpdateSeed(
                        id: seed.id,
                        .init(custom_company: trimmed.isEmpty ? nil : trimmed)
                    )
                }
        }
        .onAppear {
            if !identityHydrated {
                typeDraft = seed.customType ?? ""
                nameDraft = seed.customName ?? ""
                varietyDraft = seed.customVariety ?? ""
                companyDraft = seed.customCompany ?? ""
                identityHydrated = true
            }
        }
        .onDisappear {
            Task { try? await appEnv.sync.flushPending() }
        }
    }

    @ViewBuilder
    private func lifecycleSection(_ seed: LocalSeed) -> some View {
        Section("Lifecycle") {
            Picker(
                "State",
                selection: Binding(
                    get: { seed.state },
                    set: { newState in
                        try? appEnv.sync.enqueueUpdateSeed(id: seed.id, .init(state: newState))
                        Task { try? await appEnv.sync.flushPending() }
                    }
                )
            ) {
                Text("Active").tag(SeedState.active)
                Text("Wishlist").tag(SeedState.wishlist)
                Text("Saved").tag(SeedState.saved)
                Text("Archive").tag(SeedState.archived)
            }
        }
    }

    @ViewBuilder
    private func quantitySection(_ seed: LocalSeed) -> some View {
        Section("Quantity") {
            Stepper(
                "\(seed.packetCount) packet\(seed.packetCount == 1 ? "" : "s")",
                value: Binding(
                    get: { seed.packetCount },
                    set: { newCount in
                        try? appEnv.sync.enqueueUpdateSeed(id: seed.id, .init(packet_count: newCount))
                        Task { try? await appEnv.sync.flushPending() }
                    }
                ),
                in: 0...100
            )
        }
    }

    @ViewBuilder
    private func storageSection(_ seed: LocalSeed) -> some View {
        Section("Storage") {
            Picker(
                "Location",
                selection: Binding(
                    get: { seed.locationID },
                    set: { newID in
                        try? appEnv.sync.enqueueUpdateSeed(id: seed.id, .init(location_id: newID))
                        Task { try? await appEnv.sync.flushPending() }
                    }
                )
            ) {
                Text("None").tag(String?.none)
                ForEach(locations) { loc in
                    Text(loc.name).tag(Optional(loc.id))
                }
            }

            if !tags.isEmpty {
                let selection = Binding<Set<String>>(
                    get: { Set(seed.tagIDs) },
                    set: { newSet in
                        try? appEnv.sync.enqueueUpdateSeed(id: seed.id, .init(tag_ids: Array(newSet)))
                        Task { try? await appEnv.sync.flushPending() }
                    }
                )
                NavigationLink {
                    TagSelectionView(tags: tags, selection: selection)
                } label: {
                    HStack {
                        Text("Tags")
                        Spacer()
                        Text(selection.wrappedValue.isEmpty ? "None" : "\(selection.wrappedValue.count) selected")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func provenanceSection(_ seed: LocalSeed) -> some View {
        Section("Provenance") {
            Picker(
                "Source",
                selection: Binding(
                    get: { seed.source },
                    set: { newSource in
                        try? appEnv.sync.enqueueUpdateSeed(id: seed.id, .init(source: newSource))
                        Task { try? await appEnv.sync.flushPending() }
                    }
                )
            ) {
                Text("Store-bought").tag(SeedSource.store)
                Text("Self-saved").tag(SeedSource.saved)
                Text("Gift").tag(SeedSource.gift)
                Text("Swap").tag(SeedSource.swap)
            }

            YearPicker(
                year: Binding(
                    get: { seed.yearPacked },
                    set: { newYear in
                        try? appEnv.sync.enqueueUpdateSeed(id: seed.id, .init(year_packed: newYear))
                        Task { try? await appEnv.sync.flushPending() }
                    }
                )
            )
        }
    }

    @ViewBuilder
    private func notesSection(_ seed: LocalSeed) -> some View {
        Section("Notes") {
            TextField(
                "Notes",
                text: Binding(
                    get: { seed.notes ?? "" },
                    set: { newNotes in
                        try? appEnv.sync.enqueueUpdateSeed(
                            id: seed.id,
                            .init(notes: newNotes.isEmpty ? nil : newNotes)
                        )
                        // Throttle: don't push every keystroke. Push once when
                        // the user navigates away — handled by .onDisappear.
                    }
                ),
                axis: .vertical
            )
            .lineLimit(3...8)
        }
        .onDisappear {
            Task { try? await appEnv.sync.flushPending() }
        }
    }

    @ViewBuilder
    private func plantSection(_ seed: LocalSeed) -> some View {
        Section {
            Button {
                showPlanEvent = true
            } label: {
                Label("Plan to plant", systemImage: "calendar.badge.plus")
            }
        } footer: {
            Text("Add a sow, transplant, harvest, or note tied to this seed and (optionally) a bed.")
        }

        // Planting-window recommendation — only shown when the seed has a
        // catalog link (manually-entered seeds have no server recommendation).
        if seed.catalogID != nil {
            Section("Planting window") {
                if appEnv.recommendations.needsHomeLocation {
                    RecommendationPanel.needsLocation
                } else {
                    RecommendationPanel(
                        recommendation: localRecommendation,
                        refined: refinedRecommendation,
                        userDate: nil
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func deleteSection(_ seed: LocalSeed) -> some View {
        Section {
            Button("Delete seed", role: .destructive) {
                pendingDelete = true
            }
        }
        .confirmationDialog("Delete this seed?", isPresented: $pendingDelete) {
            Button("Delete", role: .destructive) {
                try? appEnv.sync.enqueueDeleteSeed(id: seed.id)
                Task { try? await appEnv.sync.flushPending() }
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will remove it from this device and the household.")
        }
    }
}

private struct TagSelectionView: View {
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
                        Image(systemName: "checkmark").foregroundStyle(.tint)
                    }
                }
            }
            .buttonStyle(.plain)
        }
        .navigationTitle("Tags")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct YearPicker: View {
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
