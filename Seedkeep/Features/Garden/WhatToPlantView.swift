import SwiftUI
import SwiftData
import SeedkeepKit

/// "What to plant" view — lists the household's catalog-linked seeds grouped
/// by recommendation urgency: plant now, plant soon, and a collapsed "Later &
/// missed" group for the rest.
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

    private let today = Calendar.current.startOfDay(for: Date())

    var body: some View {
        List {
            // Track updateEpoch so SwiftUI re-renders after each upsert batch.
            let _ = appEnv.recommendations.updateEpoch
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
                            description: Text("Pull to refresh, or add catalog-linked seeds to your library.")
                        )
                    }
                }
            }
        }
        .navigationTitle("What to plant")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            let ids = seeds.compactMap(\.catalogID)
            if !ids.isEmpty {
                await appEnv.recommendations.bulkRefresh(catalogSeedIDs: ids)
            }
        }
        .task {
            let ids = seeds.compactMap(\.catalogID)
            guard !ids.isEmpty else { return }
            await appEnv.recommendations.bulkRefresh(catalogSeedIDs: ids)
        }
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
        let recommendation: LocalRecommendation
        let verdict: String

        /// Human-readable window range, e.g. "May 18 – Jul 1"
        var windowLabel: String? {
            guard let s = recommendation.rangeStart, let e = recommendation.rangeEnd else { return nil }
            let start = formatYYYYMMDD(s) ?? s
            let end   = formatYYYYMMDD(e) ?? e
            return "\(start) – \(end)"
        }

        /// Days remaining label, e.g. "42 days left" or "opens in 10 days"
        var daysLabel: String? {
            let today = Calendar.current.startOfDay(for: Date())
            if verdict == "too_early", let start = recommendation.rangeStart,
               let startDate = parseYYYYMMDD(start) {
                let days = Calendar.current.dateComponents([.day], from: today, to: startDate).day ?? 0
                return days > 0 ? "opens in \(days) day\(days == 1 ? "" : "s")" : nil
            }
            guard let end = recommendation.rangeEnd, let endDate = parseYYYYMMDD(end) else { return nil }
            let days = Calendar.current.dateComponents([.day], from: today, to: endDate).day ?? 0
            if days > 0 { return "\(days) day\(days == 1 ? "" : "s") left" }
            if days == 0 { return "closes today" }
            return "\(abs(days)) day\(abs(days) == 1 ? "" : "s") ago"
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

        private func parseYYYYMMDD(_ s: String) -> Date? {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(identifier: "UTC")
            return f.date(from: s)
        }
    }

    private struct GroupedSeeds {
        var plantNow: [PlantRow] = []
        var plantSoon: [PlantRow] = []
        var laterAndMissed: [PlantRow] = []
    }

    private func groupedSeeds() -> GroupedSeeds {
        var result = GroupedSeeds()
        for seed in seeds {
            guard let catalogID = seed.catalogID,
                  let rec = appEnv.recommendations.recommendation(for: catalogID) else { continue }
            let row = PlantRow(seed: seed, recommendation: rec, verdict: rec.verdict)
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
