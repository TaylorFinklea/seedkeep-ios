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
    @State private var hasPosition: Bool = false
    @State private var xFeet: Double = 1
    @State private var yFeet: Double = 1
    @State private var saving = false
    @State private var error: String?

    /// Cached recommendation for the currently selected seed's catalog ID.
    @State private var localRecommendation: LocalRecommendation?

    /// WeatherKit-refined recommendation for the currently selected seed.
    @State private var refinedRecommendation: RefinedRecommendation?

    var body: some View {
        NavigationStack {
            Form {
                actionSection
                whereSection
                recommendationSection
                positionSection
                notesSection
                errorSection
            }
            .navigationTitle("Plan event")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .onAppear {
                if selectedBedID == nil { selectedBedID = bedID }
                if selectedSeedID == nil { selectedSeedID = prefillSeedID }
                Task { await refreshRecommendationForSelection() }
            }
            .onChange(of: selectedSeedID) { _, _ in
                Task { await refreshRecommendationForSelection() }
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
            // Strict window check: when the chosen date sits outside the
            // recommendation's outdoor window we tint the DatePicker and
            // append a caption row.  Information only — Save remains enabled
            // (a power-user planning a late succession shouldn't be blocked).
            DatePicker("Planned for", selection: $plannedFor, displayedComponents: .date)
                .tint(outOfWindowMessage != nil ? HerbColor.ochre : HerbColor.sepia)
                .foregroundStyle(outOfWindowMessage != nil ? HerbColor.ochre : Color.primary)
            if let msg = outOfWindowMessage {
                Label {
                    Text(msg)
                        .font(.caption)
                        .foregroundStyle(HerbColor.ochre)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(HerbColor.ochre)
                        .font(.caption)
                }
            }
        }
    }

    // MARK: - Out-of-window detection

    /// Caption to show under the DatePicker when `plannedFor` falls outside
    /// the recommendation's outdoor window. Returns `nil` when:
    ///   - there's no recommendation yet (still loading),
    ///   - the recommendation has no outdoor window (`rangeStart`/`rangeEnd` nil),
    ///   - or `plannedFor` is inside `[rangeStart, rangeEnd]` (strict, inclusive).
    ///
    /// `rangeStart`/`rangeEnd` are YYYY-MM-DD strings at UTC midnight; compare
    /// at day granularity in UTC so a date picker showing "Apr 15" matches
    /// rangeStart="2026-04-15" regardless of local timezone offset.
    private var outOfWindowMessage: String? {
        guard let rec = localRecommendation,
              let startStr = rec.rangeStart,
              let endStr = rec.rangeEnd,
              let start = parseYYYYMMDD(startStr),
              let end = parseYYYYMMDD(endStr) else {
            return nil
        }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let chosen = cal.startOfDay(for: plannedFor)
        let startDay = cal.startOfDay(for: start)
        let endDay = cal.startOfDay(for: end)
        if chosen >= startDay && chosen <= endDay { return nil }

        // Terse, factual, single-edge: the panel below already shows the full
        // "Apr 15 – Jul 25" window, so the caption just has to say which side
        // you're off and when the window flips. The icon carries the warning.
        if chosen < startDay {
            return "Window opens \(formattedDate(start))"
        }
        return "Window closed \(formattedDate(end))"
    }

    /// "Apr 15"-style formatter for date captions. Treats `date` as UTC midnight
    /// so it matches how `rangeStart`/`rangeEnd` were parsed.
    private func formattedDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        f.locale = .current
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: date)
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

    /// Recommendation section. Shows `RecommendationPanel` (which conveys
    /// both the planting window and any frost-risk verdict) when the selected
    /// seed has a catalog link. Includes a "Use recommended date" affordance
    /// that sets the DatePicker to the recommendation's `rangeStart`.
    ///
    /// The frost-warning concern from the old `frostWarningSection` is now
    /// communicated by the panel's verdict (e.g. `too_early` when the user
    /// is before the window, which the server derives from the home ZIP's
    /// frost dates). No separate frost-date logic is needed client-side.
    @ViewBuilder
    private var recommendationSection: some View {
        if selectedCatalogID != nil {
            Section {
                if appEnv.recommendations.needsHomeLocation {
                    RecommendationPanel.needsLocation
                } else {
                    RecommendationPanel(
                        recommendation: localRecommendation,
                        refined: refinedRecommendation,
                        userDate: plannedFor
                    )
                    if let start = localRecommendation?.rangeStart,
                       let date = parseYYYYMMDD(start) {
                        Button("Use recommended date") {
                            plannedFor = date
                        }
                        .font(.footnote)
                    }
                }
            } header: {
                Text("Planting window")
            } footer: {
                Text("Server-computed from this seed's catalog entry and your garden location.")
            }
        }
    }

    @ViewBuilder
    private var positionSection: some View {
        if let bed = selectedBed, let width = bed.widthFeet, let length = bed.lengthFeet,
           width > 0, length > 0 {
            Section {
                Toggle("Place in bed", isOn: $hasPosition)
                if hasPosition {
                    HStack {
                        Text("X")
                        Slider(value: $xFeet, in: 0...width, step: 0.5)
                        Text("\(formatFt(xFeet))′")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .frame(width: 36, alignment: .trailing)
                    }
                    HStack {
                        Text("Y")
                        Slider(value: $yFeet, in: 0...length, step: 0.5)
                        Text("\(formatFt(yFeet))′")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .frame(width: 36, alignment: .trailing)
                    }
                    BedLayoutCanvas(
                        widthFeet: width,
                        lengthFeet: length,
                        placements: [
                            BedLayoutCanvas.Placement(
                                id: "preview",
                                x: xFeet, y: yFeet,
                                spacingFeet: 0,
                                label: "",
                                isSowing: kind == .sowing
                            )
                        ]
                    )
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }
            } header: {
                Text("Position")
            } footer: {
                Text("Distance in feet from the bottom-left corner of the bed.")
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

    private var selectedBed: LocalBed? {
        guard let id = selectedBedID else { return nil }
        return beds.first(where: { $0.id == id })
    }

    /// The catalog ID of the currently selected seed, or nil if none.
    private var selectedCatalogID: String? {
        guard let seedID = selectedSeedID else { return nil }
        return seeds.first(where: { $0.id == seedID })?.catalogID
    }

    private func formatFt(_ v: Double) -> String {
        v.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(v))" : String(format: "%.1f", v)
    }

    @ViewBuilder
    private var errorSection: some View {
        if let error {
            Section {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(HerbColor.rose)
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
            notes: notes.trimmedNonEmpty,
            x_feet: hasPosition ? xFeet : nil,
            y_feet: hasPosition ? yFeet : nil
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

    // MARK: - Recommendation fetch

    @MainActor
    private func refreshRecommendationForSelection() async {
        guard let catalogID = selectedCatalogID else {
            localRecommendation = nil
            refinedRecommendation = nil
            return
        }
        await appEnv.recommendations.refresh(catalogSeedID: catalogID)
        localRecommendation = appEnv.recommendations.recommendation(for: catalogID)
        // Apply WeatherKit refinement when coordinates are available.
        // Growing-info fields come from the selected seed's local snapshot.
        if let lat = appEnv.preferences.cachedLatitude,
           let lon = appEnv.preferences.cachedLongitude {
            let growingInfo: GrowingInfoSnapshot? = seeds
                .first(where: { $0.id == selectedSeedID })
                .flatMap { $0.growingInfo }
            refinedRecommendation = await appEnv.recommendations.refinedRecommendation(
                for: catalogID,
                householdLat: lat,
                householdLon: lon,
                frostTolerance: growingInfo?.frost_tolerance,
                soilTempMaxF: growingInfo?.soil_temp_max_f
            )
        }
    }

    // MARK: - Date helpers

    /// Parses a "YYYY-MM-DD" string to a `Date` (UTC midnight), used for
    /// "Use recommended date" so the DatePicker gets set to the window start.
    private func parseYYYYMMDD(_ s: String) -> Date? {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        return f.date(from: s)
    }
}
