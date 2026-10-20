import SwiftUI
import SwiftData
import SeedkeepKit
import PhotosUI

/// "What to plant" view — lists the household's seeds with growing info, grouped by planting-window urgency: plant
/// now, plant soon, and a collapsed "Later & missed" group for the rest. Windows are computed on this device.
///
/// Each row shows the seed display name, the recommended outdoor window, and
/// how many days remain until the window closes (or opens, for too_early).
struct WhatToPlantView: View {
    @Environment(AppEnvironment.self) private var appEnv

    // Single-key sort to satisfy the project's @Query convention; secondary
    // grouping is done in code.
    @Query(
        filter: #Predicate<LocalSeed> { $0.deletedAt == nil },
        sort: \.customName, order: .forward
    )
    private var seeds: [LocalSeed]

    @State private var showLaterGroup = false
    @State private var cornerViewModel: CornerSuggestionsViewModel?
    @State private var showCornerSuggestions = false
    @State private var pickerItem: PhotosPickerItem?

    /// The seeds of the garden the app is showing, not every household in the local store.
    private var householdSeeds: [LocalSeed] {
        guard let householdID = appEnv.activeGardenHouseholdID else { return [] }
        return seeds.filter { $0.householdID == householdID }
    }

    var body: some View {
        List {
            if appEnv.recommendations.needsHomeLocation {
                Section {
                    RecommendationPanel.needsLocation
                }
            } else {
                let grouped = groupedSeeds()

                if !grouped.plantNow.isEmpty {
                    Section {
                        ForEach(grouped.plantNow, id: \.seed.id) { row in
                            plantRow(row)
                        }
                    } header: {
                        Rubric(text: "plant now")
                    }
                }

                if !grouped.plantSoon.isEmpty {
                    Section {
                        ForEach(grouped.plantSoon, id: \.seed.id) { row in
                            plantRow(row)
                        }
                    } header: {
                        Rubric(text: "plant soon")
                    }
                }

                if !grouped.laterAndMissed.isEmpty {
                    Section {
                        DisclosureGroup("Later & missed (\(grouped.laterAndMissed.count))",
                                        isExpanded: $showLaterGroup) {
                            ForEach(grouped.laterAndMissed, id: \.seed.id) { row in
                                plantRow(row)
                            }
                        }
                    }
                }

                if grouped.plantNow.isEmpty && grouped.plantSoon.isEmpty
                    && grouped.laterAndMissed.isEmpty {
                    if appEnv.sync.isSyncing {
                        VStack(spacing: 8) {
                            ProgressView()
                                .herbProgressStyle()
                                .controlSize(.small)
                            Text("turning the page…")
                                .font(HerbFont.bodyItalic(size: 12))
                                .foregroundStyle(HerbColor.inkSoft)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 48)
                    } else {
                        ContentUnavailableView(
                            "No recommendations yet",
                            systemImage: "leaf",
                            description: Text("Add growing info to a seed to see when to plant it.")
                        )
                    }
                }
            }
        }
        .navigationTitle("What to plant")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .platformTrailing) {
                PhotosPicker(
                    selection: $pickerItem,
                    matching: .images,
                    photoLibrary: .shared()
                ) {
                    HStack(spacing: 4) {
                        Image(systemName: "camera.viewfinder")
                        Text("Snap a corner")
                            .font(HerbFont.smallCaps(size: 10))
                            .tracking(1.2)
                    }
                    .foregroundStyle(HerbColor.sepia)
                }
            }
        }
        .onChange(of: pickerItem) { _, newItem in
            guard let newItem else { return }
            Task {
                if let data = try? await newItem.loadTransferable(type: Data.self),
                   let image = PlatformImageCoding.image(data: data) {
                    await launchCornerSuggestions(image: image)
                }
                pickerItem = nil
            }
        }
        .sheet(isPresented: $showCornerSuggestions) {
            if let vm = cornerViewModel {
                CornerSuggestionsView(viewModel: vm)
                    .environment(appEnv)
            }
        }
    }

    // MARK: - Corner suggestions launch

    private func launchCornerSuggestions(image: PlatformImage) async {
        let recommendations = appEnv.recommendations
        // Only active (non-deleted, non-archived) seeds reach the ranker (AC #1).
        let localSeeds = householdSeeds.filter { $0.stateRaw == "active" }

        let vm = CornerSuggestionsViewModel(
            analyze: { img in
                await CornerVisionAnalyzer().analyze(image: img)
            },
            fetchSeeds: {
                localSeeds.map { seed in
                    PlantSuggestionRanker.SeedInput(
                        id: seed.id,
                        displayName: seed.displayName,
                        catalogID: seed.catalogID,
                        yearPacked: seed.yearPacked,
                        sunRequirement: seed.growingInfo?.sun_requirement,
                        plantSpacingInches: seed.growingInfo?.plant_spacing_inches
                    )
                }
            },
            fetchRecommendations: { seedIDs in
                // Each requested seed contributes its on-device window, whether or not it has a catalog link.
                let requested = Set(seedIDs)
                return localSeeds.compactMap { seed -> PlantSuggestionRanker.RecommendationInput? in
                    guard requested.contains(seed.id),
                          let rec = recommendations.recommendation(for: seed) else { return nil }
                    return PlantSuggestionRanker.RecommendationInput(
                        seedID: seed.id,
                        verdict: rec.verdict,
                        rangeStart: rec.rangeStart,
                        rangeEnd: rec.rangeEnd
                    )
                }
            },
            hasHomeLocation: { !recommendations.needsHomeLocation }
        )
        cornerViewModel = vm
        showCornerSuggestions = true
        await vm.capture(image: image)
    }

    // MARK: - Row

    @ViewBuilder
    private func plantRow(_ row: PlantRow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(row.seed.displayName)
                .font(.body.weight(.semibold))
                .lineLimit(1)
            HStack(spacing: 6) {
                if let window = row.windowLabel {
                    Text(window)
                        .font(.caption)
                        .foregroundStyle(HerbColor.inkSoft)
                }
                if let days = row.daysLabel {
                    Text("·")
                        .font(.caption)
                        .foregroundStyle(HerbColor.inkFaint)
                    Text(days)
                        .font(.caption)
                        .foregroundStyle(HerbColor.inkSoft)
                }
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Data model

    private struct PlantRow {
        let seed: LocalSeed
        let recommendation: PlantingRecommendation
        let verdict: String

        /// Human-readable window range, e.g. "May 18 – Jul 1"
        var windowLabel: String? {
            guard let s = recommendation.rangeStart, let e = recommendation.rangeEnd else { return nil }
            let start = formatYYYYMMDD(s) ?? s
            let end   = formatYYYYMMDD(e) ?? e
            return "\(start) – \(end)"
        }

        /// The local calendar day the store computed the window for.
        let today: (year: Int, month: Int, day: Int)

        /// Days remaining label, e.g. "42 days left" or "opens in 10 days"
        var daysLabel: String? {
            PlantingWindowDays.label(
                verdict: verdict,
                rangeStart: recommendation.rangeStart,
                rangeEnd: recommendation.rangeEnd,
                today: today
            )
        }

        private func formatYYYYMMDD(_ s: String) -> String? {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(identifier: "UTC")
            guard let date = f.date(from: s) else { return nil }
            let out = DateFormatter()
            out.dateFormat = "MMM d"
            out.locale = .current
            out.timeZone = TimeZone(identifier: "UTC")
            return out.string(from: date)
        }
    }

    private struct GroupedSeeds {
        var plantNow: [PlantRow] = []
        var plantSoon: [PlantRow] = []
        var laterAndMissed: [PlantRow] = []
    }

    private func groupedSeeds() -> GroupedSeeds {
        var result = GroupedSeeds()
        let today = appEnv.recommendations.today
        for seed in householdSeeds {
            guard let rec = appEnv.recommendations.recommendation(for: seed) else { continue }
            let row = PlantRow(seed: seed, recommendation: rec, verdict: rec.verdict, today: today)
            switch rec.verdict {
            case "plant_now":
                result.plantNow.append(row)
            case "plant_soon":
                result.plantSoon.append(row)
            default:
                // too_early, late, too_late, unknown → later & missed group
                result.laterAndMissed.append(row)
            }
        }
        return result
    }
}

/// The "days left" and "opens in" wording for a window. It counts local calendar days: the window's
/// "YYYY-MM-DD" dates and the user's local today become day numbers, so a time zone west of UTC
/// never shifts the count by one.
enum PlantingWindowDays {
    static func label(
        verdict: String,
        rangeStart: String?,
        rangeEnd: String?,
        today: (year: Int, month: Int, day: Int)
    ) -> String? {
        let todayNumber = PlantingEngine.dayNumber(year: today.year, month: today.month, day: today.day)
        if verdict == "too_early", let rangeStart, let start = PlantingEngine.parseISODate(rangeStart) {
            let days = start - todayNumber
            return days > 0 ? "opens in \(days) day\(days == 1 ? "" : "s")" : nil
        }
        guard let rangeEnd, let end = PlantingEngine.parseISODate(rangeEnd) else { return nil }
        let days = end - todayNumber
        if days > 0 { return "\(days) day\(days == 1 ? "" : "s") left" }
        if days == 0 { return "closes today" }
        return "\(abs(days)) day\(abs(days) == 1 ? "" : "s") ago"
    }
}
