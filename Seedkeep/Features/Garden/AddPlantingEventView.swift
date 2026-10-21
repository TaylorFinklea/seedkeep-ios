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
    /// Optional prefill date for the planting event (e.g. from the corner suggestions rangeStart).
    /// When non-nil, `plannedFor` is set to this value in `.onAppear`.
    let prefillDate: Date?

    init(bedID: String?, prefillSeedID: String?, prefillDate: Date? = nil) {
        self.bedID = bedID
        self.prefillSeedID = prefillSeedID
        self.prefillDate = prefillDate
    }

    @Environment(AppEnvironment.self) private var appEnv
    @Environment(\.dismiss) private var dismiss

    @Query(filter: #Predicate<LocalBed> { $0.deletedAt == nil },
           sort: \.sortOrder, order: .forward)
    private var beds: [LocalBed]

    @Query(filter: #Predicate<LocalSeed> { $0.deletedAt == nil },
           sort: \.customName, order: .forward)
    private var seeds: [LocalSeed]

    @Query(filter: #Predicate<LocalPlantingEvent> { $0.deletedAt == nil })
    private var bedEvents: [LocalPlantingEvent]

    @State private var kind: PlantingEventKind = .sowing
    @State private var plannedFor: Date = Date()
    @State private var selectedBedID: String?
    @State private var selectedSeedID: String?
    @State private var notes: String = ""
    @State private var hasPosition: Bool = false
    /// The square picked on the bed's grid; the planting is placed at its centre.
    @State private var pickedSquare: GridSquare?
    @State private var saving = false
    @State private var error: String?

    /// WeatherKit-refined recommendation for the currently selected seed.
    @State private var refinedRecommendation: RefinedRecommendation?

    /// The planning window for the selected seed, computed on this device. Read on every render, so it follows the
    /// day, the seed's growing info and the home location.
    private var localRecommendation: PlantingRecommendation? {
        selectedSeed.flatMap { appEnv.recommendations.recommendation(for: $0) }
    }

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
            .wbForm()
            .navigationTitle("Plan event")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { toolbarContent }
            .onAppear {
                if selectedBedID == nil { selectedBedID = bedID }
                if selectedSeedID == nil { selectedSeedID = prefillSeedID }
                if let date = prefillDate { plannedFor = date }
            }
            .onChange(of: selectedBedID) { _, _ in pickedSquare = nil }
            .task(id: refinementKey) {
                await refreshRefinement()
            }
        }
    }

    @ViewBuilder
    private var actionSection: some View {
        Section {
            Picker("Kind", selection: $kind) {
                ForEach(PlantingEventKind.allCases) { k in
                    Label(k.displayName, systemImage: k.systemImage).tag(k)
                }
            }
            // Strict window check: when the chosen date sits outside the
            // recommendation's outdoor window we append a warning caption row
            // (the warn colour stays on its icon).  Information only — Save remains enabled
            // (a power-user planning a late succession shouldn't be blocked).
            DatePicker("Planned for", selection: $plannedFor, displayedComponents: .date)
                .tint(WBColor.accent)
                .foregroundStyle(WBColor.ink)
            if let msg = outOfWindowMessage {
                Label {
                    Text(msg)
                        .font(.wbCaption)
                        .foregroundStyle(WBColor.ink)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(WBColor.warn)
                        .font(.caption)
                }
            }
        } header: {
            WBSectionHeader("action")
        }
    }

    // MARK: - Out-of-window detection

    /// Caption to show under the DatePicker when `plannedFor` falls outside
    /// the recommendation's outdoor window. Returns `nil` when:
    ///   - there's no recommendation yet (still loading),
    ///   - the recommendation has no outdoor window (`rangeStart`/`rangeEnd` nil),
    ///   - or `plannedFor` is inside `[rangeStart, rangeEnd]` (strict, inclusive).
    ///
    /// `rangeStart`/`rangeEnd` are YYYY-MM-DD strings parsed to local midnight
    /// (matching `parseYYYYMMDD` and `yyyymmdd(_:)`); comparison is at local
    /// day granularity so the window check agrees with what the DatePicker saves.
    private var outOfWindowMessage: String? {
        guard let rec = localRecommendation,
              let startStr = rec.rangeStart,
              let endStr = rec.rangeEnd,
              let start = parseYYYYMMDD(startStr),
              let end = parseYYYYMMDD(endStr) else {
            return nil
        }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
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

    /// "Apr 15"-style formatter for date captions. Uses local timezone
    /// to match how `rangeStart`/`rangeEnd` are parsed by `parseYYYYMMDD`.
    private func formattedDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        f.locale = .current
        f.timeZone = .current
        return f.string(from: date)
    }

    @ViewBuilder
    private var whereSection: some View {
        Section {
            Picker("Bed", selection: $selectedBedID) {
                Text("None").tag(String?.none)
                ForEach(activeBeds) { bed in
                    Text(bed.name).tag(Optional(bed.id))
                }
            }
            Picker("Seed", selection: $selectedSeedID) {
                Text("None").tag(String?.none)
                ForEach(activeSeeds) { seed in
                    Text(seed.customName ?? "Unnamed seed").tag(Optional(seed.id))
                }
            }
        } header: {
            WBSectionHeader("where + what")
        }
    }

    /// Recommendation section. Shows `RecommendationPanel` (which conveys
    /// both the planting window and any frost-risk verdict) when a seed is
    /// selected. Includes a "Use recommended date" affordance that sets the
    /// DatePicker to the recommendation's `rangeStart`.
    ///
    /// The frost-warning concern from the old `frostWarningSection` is now
    /// communicated by the panel's verdict (e.g. `too_early` when the user
    /// is before the window, which is computed from the home ZIP's frost
    /// dates). No separate frost-date logic is needed client-side.
    @ViewBuilder
    private var recommendationSection: some View {
        if selectedSeed != nil {
            Section {
                if appEnv.recommendations.needsHomeLocation {
                    RecommendationPanel.needsLocation
                } else {
                    RecommendationPanel(
                        recommendation: localRecommendation,
                        refined: refinedRecommendation,
                        userDate: plannedFor,
                        hasGrowingInfo: selectedSeed?.growingInfo?.hasAny == true
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
                WBSectionHeader("planting window")
            } footer: {
                Text("Computed on this device from the seed's growing info and your home location.")
                    .font(.wbFootnote)
                    .foregroundStyle(WBColor.muted)
            }
        }
    }

    /// "Place in bed": a small grid of the selected bed. The planting is placed at the picked square's
    /// centre; without a pick it stays unplaced.
    @ViewBuilder
    private var positionSection: some View {
        if let bed = selectedBed,
           let size = GardenGrid.size(widthFeet: bed.widthFeet, lengthFeet: bed.lengthFeet) {
            Section {
                Toggle("Place in bed", isOn: $hasPosition)
                    .accessibilityIdentifier("addPlanting.placeInBed")
                if hasPosition {
                    BedSquarePicker(
                        size: size,
                        squares: squares(in: bed, size: size),
                        seedName: { event in event.seedID.flatMap { id in activeSeeds.first { $0.id == id }?.displayName } },
                        selection: $pickedSquare
                    )
                    .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4))
                    Text(pickedSquare.map { "Placed in \(GardenGrid.label($0))." } ?? "Tap a square to place it.")
                        .font(.wbFootnote)
                        .foregroundStyle(WBColor.muted)
                }
            } header: {
                WBSectionHeader("position")
            } footer: {
                Text(GardenLegend.scale)
                    .font(.wbFootnote)
                    .foregroundStyle(WBColor.muted)
            }
        }
    }

    /// What the bed's squares hold now, for the picker's faces.
    private func squares(in bed: LocalBed, size: GridSize) -> [GridSquare: SquareContents] {
        let events = bedEvents
            .filter { $0.bedID == bed.id && $0.householdID == bed.householdID }
            .map { GridEvent($0, isFrostFlagged: false) }
        return GardenGrid.squares(events: events, bedID: bed.id, size: size)
    }

    @ViewBuilder
    private var notesSection: some View {
        Section {
            TextField("Optional", text: $notes, axis: .vertical)
                .lineLimit(2...6)
        } header: {
            WBSectionHeader("notes")
        }
    }

    private var selectedBed: LocalBed? {
        guard let id = selectedBedID else { return nil }
        return activeBeds.first(where: { $0.id == id })
    }

    /// The currently selected seed, or nil if none.
    private var selectedSeed: LocalSeed? {
        guard let seedID = selectedSeedID else { return nil }
        return activeSeeds.first(where: { $0.id == seedID })
    }

    private var activeBeds: [LocalBed] {
        guard let householdID = appEnv.activeGardenHouseholdID else { return [] }
        return beds.filter { $0.householdID == householdID }
    }

    private var activeSeeds: [LocalSeed] {
        guard let householdID = appEnv.activeGardenHouseholdID else { return [] }
        return seeds.filter { $0.householdID == householdID }
    }

    @ViewBuilder
    private var errorSection: some View {
        if let error {
            Section {
                Label {
                    Text(error)
                        .font(.wbFootnote)
                        .foregroundStyle(WBColor.ink)
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(WBColor.warn)
                        .accessibilityHidden(true)
                }
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
        let activeGardenHouseholdID = appEnv.activeGardenHouseholdID ?? household.id
        let input = PlaceInBed.createInput(
            bedID: selectedBedID,
            seedID: selectedSeedID,
            kind: kind,
            plannedFor: Self.yyyymmdd(plannedFor),
            notes: notes.trimmedNonEmpty,
            square: hasPosition ? pickedSquare : nil,
            widthFeet: selectedBed?.widthFeet,
            lengthFeet: selectedBed?.lengthFeet
        )
        do {
            _ = try appEnv.sync.enqueueCreatePlantingEvent(input, householdID: activeGardenHouseholdID)
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

    /// The inputs the refined window depends on. A change to any of them restarts the refinement.
    private var refinementKey: String {
        selectedSeed.map { appEnv.recommendations.refinementKey(for: $0) } ?? ""
    }

    /// Applies WeatherKit refinement when coordinates are available. Growing-info fields come from the selected
    /// seed's own snapshot.
    @MainActor
    private func refreshRefinement() async {
        refinedRecommendation = nil
        guard let seed = selectedSeed,
              let baseline = localRecommendation,
              let lat = appEnv.preferences.cachedLatitude,
              let lon = appEnv.preferences.cachedLongitude else { return }
        let growingInfo = RecommendationStore.effectiveGrowingInfo(for: seed)
        let refined = await appEnv.recommendations.refinedRecommendation(
            baseline: baseline,
            householdLat: lat,
            householdLon: lon,
            frostTolerance: growingInfo?.frost_tolerance,
            soilTempMaxF: growingInfo?.soil_temp_max_f
        )
        // The inputs may have changed while the forecast loaded.
        guard !Task.isCancelled else { return }
        refinedRecommendation = refined
    }

    // MARK: - Date helpers

    /// Parses a "YYYY-MM-DD" string to a `Date` at local midnight.
    /// Uses `TimeZone.current` so the resulting `Date` round-trips through
    /// `yyyymmdd(_:)` (which also uses `.current`) without an off-by-one
    /// day for UTC-negative users.
    private func parseYYYYMMDD(_ s: String) -> Date? {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        return f.date(from: s)
    }
}
