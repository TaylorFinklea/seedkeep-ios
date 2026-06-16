import SwiftUI
import SwiftData
import UIKit
import SeedkeepKit
import PhotosUI

// MARK: - CornerSuggestionsViewModel

/// View-model for the "corner suggestions" feature.
/// Holds the captured image in memory only (ephemeral) and drives
/// the full capture → analyze → rank → edit-cue flow.
@MainActor
@Observable
final class CornerSuggestionsViewModel {
    // MARK: - State

    /// Captured thumbnail (ephemeral — discarded on dismiss).
    private(set) var capturedImage: UIImage?

    /// Cues computed from the image. Editable by the user.
    var cues: CornerCues = .unknown

    /// Ranked suggestions. Updated when seeds, recommendations, or cues change.
    private(set) var suggestions: [PlantSuggestion] = []

    /// True while initial analysis + recommendation fetch is running.
    private(set) var isLoading: Bool = false

    /// Surface a non-fatal warning (stale recs, no location, etc.).
    private(set) var staleness: StalenessNote = .none

    /// Cached recommendations from the last `refreshSuggestions()` call.
    /// Re-used by `rerankOnly()` so editing a cue never triggers a re-fetch.
    private var cachedRecs: [PlantSuggestionRanker.RecommendationInput] = []

    // MARK: - Dependencies (injected for testability)

    var analyze: (UIImage) async -> CornerCues
    var fetchSeeds: () -> [PlantSuggestionRanker.SeedInput]
    var fetchRecommendations: ([String]) async -> [PlantSuggestionRanker.RecommendationInput]
    var today: () -> Date

    enum StalenessNote: Equatable {
        case none
        case staleRecs
        case noLocation
    }

    // MARK: - Init

    init(
        analyze: @escaping (UIImage) async -> CornerCues,
        fetchSeeds: @escaping () -> [PlantSuggestionRanker.SeedInput],
        fetchRecommendations: @escaping ([String]) async -> [PlantSuggestionRanker.RecommendationInput],
        today: @escaping () -> Date = { Date() }
    ) {
        self.analyze = analyze
        self.fetchSeeds = fetchSeeds
        self.fetchRecommendations = fetchRecommendations
        self.today = today
    }

    // MARK: - Actions

    /// Called when the user picks or captures a photo.
    func capture(image: UIImage) async {
        capturedImage = image
        isLoading = true
        defer { isLoading = false }

        // Step 1: on-device Vision analysis.
        let detectedCues = await analyze(image)
        cues = detectedCues

        // Step 2: gather seeds + fetch/refresh recommendations.
        await refreshSuggestions()
    }

    /// Re-runs the ranker when the user edits a cue chip.
    /// Does NOT re-capture or re-fetch recommendations.
    func cueChanged() {
        rerankOnly()
    }

    // MARK: - Private

    private func refreshSuggestions() async {
        let seeds = fetchSeeds()
        let catalogIDs = seeds.compactMap(\.catalogID)
        let recs = await fetchRecommendations(catalogIDs)
        cachedRecs = recs
        if recs.isEmpty && !catalogIDs.isEmpty {
            staleness = .staleRecs
        }
        suggestions = PlantSuggestionRanker.rank(seeds: seeds, recommendations: recs, cues: cues, today: today())
    }

    private func rerankOnly() {
        // Use cached recommendations from the initial fetch — no re-fetch, no Task.
        let seeds = fetchSeeds()
        suggestions = PlantSuggestionRanker.rank(seeds: seeds, recommendations: cachedRecs, cues: cues, today: today())
    }
}

// MARK: - CornerSuggestionsView

/// Results screen for the "Snap a corner" feature.
///
/// - Thumbnail of the captured image (ephemeral)
/// - Two editable cue chips (exposure + openness) — editing re-ranks instantly
/// - Ranked seed suggestion cards (verdict badge + window, RecommendationPanel styling)
/// - Tap a card → Add Planting Event prefilled with seed + suggested date
struct CornerSuggestionsView: View {
    @Environment(AppEnvironment.self) private var appEnv

    @State var viewModel: CornerSuggestionsViewModel
    @State private var addPlantingEventSeedID: String?
    @State private var addPlantingEventDate: Date = Date()
    @State private var showAddPlantingEvent = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    thumbnailSection
                    cueChipsSection
                    suggestionsSection
                }
                .padding(.horizontal, HerbSpace.gutter)
                .padding(.bottom, 32)
            }
            .background(VellumBackground())
            .navigationTitle("Corner suggestions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showAddPlantingEvent) {
                AddPlantingEventView(bedID: nil, prefillSeedID: addPlantingEventSeedID, prefillDate: addPlantingEventDate)
            }
            .overlay {
                if viewModel.isLoading {
                    loadingOverlay
                }
            }
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var thumbnailSection: some View {
        if let img = viewModel.capturedImage {
            Image(uiImage: img)
                .resizable()
                .scaledToFill()
                .frame(height: 180)
                .clipShape(.rect(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(HerbColor.vellumDk, lineWidth: 0.5)
                )
                .padding(.top, 8)
        }
    }

    @ViewBuilder
    private var cueChipsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("DETECTED CONDITIONS")
                .font(HerbFont.smallCaps(size: 9))
                .tracking(1.6)
                .foregroundStyle(HerbColor.sepia)

            HStack(spacing: 8) {
                ExposureChip(selection: Binding(
                    get: { viewModel.cues.exposure },
                    set: { newVal in
                        viewModel.cues = CornerCues(exposure: newVal, openness: viewModel.cues.openness)
                        viewModel.cueChanged()
                    }
                ))
                OpennessChip(selection: Binding(
                    get: { viewModel.cues.openness },
                    set: { newVal in
                        viewModel.cues = CornerCues(exposure: viewModel.cues.exposure, openness: newVal)
                        viewModel.cueChanged()
                    }
                ))
                Spacer()
            }

            if viewModel.staleness == .staleRecs {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.circle")
                        .font(.caption)
                        .foregroundStyle(HerbColor.ochre)
                    Text("Planting windows may be stale — ranking on season + library.")
                        .font(HerbFont.bodyItalic(size: 11))
                        .foregroundStyle(HerbColor.inkSoft)
                }
            }
        }
        .padding(.top, 4)
    }

    @ViewBuilder
    private var suggestionsSection: some View {
        if viewModel.suggestions.isEmpty && !viewModel.isLoading {
            emptyState
        } else {
            VStack(spacing: 0) {
                ForEach(viewModel.suggestions, id: \.seedID) { suggestion in
                    SuggestionCard(suggestion: suggestion) {
                        openAddPlanting(for: suggestion)
                    }
                    .padding(.bottom, 8)
                }
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "leaf")
                .font(.system(size: 32))
                .foregroundStyle(HerbColor.sepia.opacity(0.6))
            Text("No active seeds")
                .font(HerbFont.display(size: 20))
                .foregroundStyle(HerbColor.ink)
            Text("Add seeds to your library to get ranked suggestions here.")
                .font(HerbFont.bodyItalic(size: 12))
                .foregroundStyle(HerbColor.inkSoft)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }

    private var loadingOverlay: some View {
        VStack(spacing: 12) {
            ProgressView()
                .progressViewStyle(.circular)
                .controlSize(.large)
                .tint(HerbColor.sepia)
            Text("Reading the corner…")
                .font(HerbFont.bodyItalic(size: 13))
                .foregroundStyle(HerbColor.inkSoft)
        }
        .padding(24)
        .background(.regularMaterial, in: .rect(cornerRadius: 12))
    }

    // MARK: - Actions

    private func openAddPlanting(for suggestion: PlantSuggestion) {
        addPlantingEventSeedID = suggestion.seedID
        // Prefill with rangeStart date if available, else today.
        if let start = suggestion.rangeStart {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(identifier: "UTC")
            addPlantingEventDate = f.date(from: start) ?? Date()
        } else {
            addPlantingEventDate = Date()
        }
        showAddPlantingEvent = true
    }
}

// MARK: - SuggestionCard

private struct SuggestionCard: View {
    let suggestion: PlantSuggestion
    let onPlant: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                verdictDot
                Text(suggestion.displayName)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(HerbColor.ink)
                    .lineLimit(1)
                Spacer()
                Button {
                    onPlant()
                } label: {
                    Text("Plant")
                        .font(HerbFont.smallCaps(size: 10))
                        .tracking(1.4)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(HerbColor.sepia, in: .capsule)
                }
                .buttonStyle(.plain)
            }

            if suggestion.hasNoWindowData {
                Text("No window data — ranked on packet age")
                    .font(HerbFont.bodyItalic(size: 11))
                    .foregroundStyle(HerbColor.inkSoft)
            } else if let rangeStart = suggestion.rangeStart, let rangeEnd = suggestion.rangeEnd {
                HStack(spacing: 6) {
                    verdictBadge
                    Text("·")
                        .font(.caption)
                        .foregroundStyle(HerbColor.inkFaint)
                    Text("\(formatDate(rangeStart)) – \(formatDate(rangeEnd))")
                        .font(.caption)
                        .foregroundStyle(HerbColor.inkSoft)
                }
            } else {
                verdictBadge
            }
        }
        .padding(12)
        .background(HerbColor.vellumHi, in: .rect(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(HerbColor.vellumDk, lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private var verdictDot: some View {
        if let verdict = suggestion.verdict {
            Circle()
                .fill(verdictColor(verdict))
                .frame(width: 9, height: 9)
        }
    }

    @ViewBuilder
    private var verdictBadge: some View {
        if let verdict = suggestion.verdict {
            Text(verdictLabel(verdict))
                .font(HerbFont.smallCaps(size: 9))
                .tracking(1.2)
                .foregroundStyle(verdictColor(verdict))
        }
    }

    private func verdictColor(_ verdict: String) -> Color {
        switch verdict {
        case "plant_now":  return HerbColor.verdictNow
        case "plant_soon": return HerbColor.verdictSoon
        case "too_early":  return HerbColor.verdictEarly
        case "late":       return HerbColor.verdictClose
        case "too_late":   return HerbColor.verdictMiss
        default:           return HerbColor.inkFaint
        }
    }

    private func verdictLabel(_ verdict: String) -> String {
        switch verdict {
        case "plant_now":  return "Plant now"
        case "plant_soon": return "Plant soon"
        case "too_early":  return "Too early"
        case "late":       return "Window closing"
        case "too_late":   return "Missed this year"
        default:           return "Checking…"
        }
    }

    private func formatDate(_ yyyymmdd: String) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        guard let date = f.date(from: yyyymmdd) else { return yyyymmdd }
        let out = DateFormatter()
        out.dateFormat = "MMM d"
        out.locale = .current
        out.timeZone = TimeZone(identifier: "UTC")
        return out.string(from: date)
    }
}

// MARK: - Cue chip pickers

private struct ExposureChip: View {
    @Binding var selection: Exposure

    var body: some View {
        Menu {
            ForEach(Exposure.allCases, id: \.self) { value in
                Button {
                    selection = value
                } label: {
                    if value == selection {
                        Label(value.displayLabel, systemImage: "checkmark")
                    } else {
                        Text(value.displayLabel)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "sun.max")
                    .font(.caption)
                Text(selection.displayLabel)
                    .font(HerbFont.smallCaps(size: 10))
                    .tracking(1.2)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9))
            }
            .foregroundStyle(HerbColor.ink)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(HerbColor.vellumDk.opacity(0.3), in: .capsule)
            .overlay(Capsule().strokeBorder(HerbColor.vellumDk, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }
}

private struct OpennessChip: View {
    @Binding var selection: Openness

    var body: some View {
        Menu {
            ForEach(Openness.allCases, id: \.self) { value in
                Button {
                    selection = value
                } label: {
                    if value == selection {
                        Label(value.displayLabel, systemImage: "checkmark")
                    } else {
                        Text(value.displayLabel)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "leaf")
                    .font(.caption)
                Text(selection.displayLabel)
                    .font(HerbFont.smallCaps(size: 10))
                    .tracking(1.2)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9))
            }
            .foregroundStyle(HerbColor.ink)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(HerbColor.vellumDk.opacity(0.3), in: .capsule)
            .overlay(Capsule().strokeBorder(HerbColor.vellumDk, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }
}
