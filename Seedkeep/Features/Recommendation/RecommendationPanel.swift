import SwiftUI
import SwiftData

// MARK: - RecommendationPanel

/// Renders a planting-window recommendation. Designed to embed naturally
/// inside a `Form` `Section` and as a standalone card — no opaque background
/// is forced, so it inherits the container's styling in both contexts.
///
/// Usage:
/// ```swift
/// // Full recommendation (refined overrides baseline when present)
/// RecommendationPanel(recommendation: rec, refined: refined, userDate: plannedFor)
///
/// // Nil (loading/unfetched) state
/// RecommendationPanel(recommendation: nil, refined: nil, userDate: nil)
///
/// // No-location state — show guidance to set garden location
/// RecommendationPanel.needsLocation
/// ```
struct RecommendationPanel: View {

    // MARK: Inputs

    let recommendation: LocalRecommendation?
    let refined: RefinedRecommendation?
    /// When non-nil and within the 60-day score span, a vertical "Your date"
    /// marker is drawn on the gradient bar.
    let userDate: Date?

    // MARK: Body

    var body: some View {
        if let rec = recommendation {
            filledPanel(rec)
        } else {
            loadingPlaceholder
        }
    }

    // MARK: - Filled panel

    @ViewBuilder
    private func filledPanel(_ rec: LocalRecommendation) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            verdictBadge(for: rec)
            windowDates(for: rec)
            gradientBar(for: rec)
            weatherNoteRow
            reasoningRow(for: rec)
        }
    }

    // MARK: - Verdict badge

    private func verdictBadge(for rec: LocalRecommendation) -> some View {
        let effectiveVerdict = refined?.verdict ?? rec.verdict
        let info = VerdictInfo(raw: effectiveVerdict)
        let herbColor = herbVerdictColor(for: effectiveVerdict)
        return HStack(spacing: 8) {
            Circle()
                .fill(herbColor)
                .frame(width: 9, height: 9)
            Text(info.label)
                .font(HerbFont.smallCaps(size: 11))
                .tracking(1.4)
                .foregroundStyle(HerbColor.ink)
                .textCase(.uppercase)
            Spacer()
            if rec.source == "ai" {
                HStack(spacing: 4) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 9))
                        .foregroundStyle(HerbColor.sepia)
                    Text("AI")
                        .font(HerbFont.smallCaps(size: 9))
                        .tracking(1.2)
                        .foregroundStyle(HerbColor.sepia)
                        .textCase(.uppercase)
                }
            }
        }
    }

    private func herbVerdictColor(for raw: String) -> Color {
        switch raw {
        case "plant_now":  return HerbColor.verdictNow
        case "plant_soon": return HerbColor.verdictSoon
        case "too_early":  return HerbColor.verdictEarly
        case "late":       return HerbColor.verdictClose
        case "too_late":   return HerbColor.verdictMiss
        default:           return HerbColor.inkFaint
        }
    }

    // MARK: - Window dates

    @ViewBuilder
    private func windowDates(for rec: LocalRecommendation) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            if let start = rec.rangeStart, let end = rec.rangeEnd {
                let startStr = formattedDate(start) ?? start
                let endStr = formattedDate(end) ?? end
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("OUTDOOR")
                        .font(HerbFont.smallCaps(size: 9))
                        .tracking(1.4)
                        .foregroundStyle(HerbColor.sepia)
                    Text("\(startStr) – \(endStr)")
                        .font(HerbFont.bodyItalic(size: 13))
                        .foregroundStyle(HerbColor.ink)
                }
            } else if rec.rangeStart == nil && rec.rangeEnd == nil {
                Text("No outdoor window computed")
                    .font(HerbFont.bodyItalic(size: 12))
                    .foregroundStyle(HerbColor.inkSoft)
            }

            if let iStart = rec.indoorStart, let iEnd = rec.indoorEnd {
                let iStartStr = formattedDate(iStart) ?? iStart
                let iEndStr = formattedDate(iEnd) ?? iEnd
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("INDOORS")
                        .font(HerbFont.smallCaps(size: 9))
                        .tracking(1.4)
                        .foregroundStyle(HerbColor.sepia)
                    Text("\(iStartStr) – \(iEndStr)")
                        .font(HerbFont.bodyItalic(size: 12))
                        .foregroundStyle(HerbColor.inkSoft)
                }
            }
        }
    }

    // MARK: - 60-day gradient bar

    @ViewBuilder
    private func gradientBar(for rec: LocalRecommendation) -> some View {
        let scores = refined?.dailyScores ?? rec.dailyScores
        let anchorStr = refined?.scoresAnchorDate ?? rec.scoresAnchorDate

        VStack(alignment: .leading, spacing: 4) {
            SuitabilityGradientBar(
                scores: scores,
                anchorDateString: anchorStr,
                userDate: userDate
            )
            .frame(height: 28)
            .clipShape(.rect(cornerRadius: 6))

            // Date axis labels
            HStack {
                Text(shortDate(anchorStr) ?? "Today")
                    .font(HerbFont.smallCaps(size: 8))
                    .tracking(1.2)
                    .foregroundStyle(HerbColor.sepia)
                Spacer()
                Text("+30D")
                    .font(HerbFont.smallCaps(size: 8))
                    .tracking(1.2)
                    .foregroundStyle(HerbColor.sepia)
                Spacer()
                Text("+60D")
                    .font(HerbFont.smallCaps(size: 8))
                    .tracking(1.2)
                    .foregroundStyle(HerbColor.sepia)
            }
        }
    }

    // MARK: - Weather note

    @ViewBuilder
    private var weatherNoteRow: some View {
        if let note = refined?.weatherNote {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "cloud.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(HerbColor.sepia)
                Text(note)
                    .font(HerbFont.bodyItalic(size: 12))
                    .foregroundStyle(HerbColor.inkSoft)
            }
        }
    }

    // MARK: - Reasoning

    @ViewBuilder
    private func reasoningRow(for rec: LocalRecommendation) -> some View {
        if let reasoning = rec.reasoning, !reasoning.isEmpty {
            Text(reasoning)
                .font(HerbFont.bodyItalic(size: 11))
                .foregroundStyle(HerbColor.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Loading placeholder

    private var loadingPlaceholder: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small).tint(HerbColor.sepia)
            Text("Reading the planting window…")
                .font(HerbFont.bodyItalic(size: 12))
                .foregroundStyle(HerbColor.inkSoft)
        }
    }

    // MARK: - Helpers

    /// Parses a "YYYY-MM-DD" string and returns a readable "May 18" string.
    private func formattedDate(_ yyyymmdd: String) -> String? {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        guard let date = f.date(from: yyyymmdd) else { return nil }
        let out = DateFormatter()
        out.dateFormat = "MMM d"
        out.locale = Locale(identifier: "en_US_POSIX")
        out.timeZone = TimeZone(identifier: "UTC")
        return out.string(from: date)
    }

    /// Short date label for the axis — just "MMM d".
    private func shortDate(_ yyyymmdd: String) -> String? {
        formattedDate(yyyymmdd)
    }

    // MARK: - No-location variant

    /// Lightweight static view: shown when `RecommendationStore.needsHomeLocation`
    /// is true. Callers pick which variant to display.
    static var needsLocation: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "nosign")
                .font(.system(size: 14))
                .foregroundStyle(HerbColor.ochre)
            VStack(alignment: .leading, spacing: 4) {
                Text("LOCATION REQUIRED")
                    .font(HerbFont.smallCaps(size: 10))
                    .tracking(1.5)
                    .foregroundStyle(HerbColor.ink)
                Text("Set your garden location in Settings → Home location to see planting windows.")
                    .font(HerbFont.bodyItalic(size: 12))
                    .foregroundStyle(HerbColor.inkSoft)
            }
        }
    }
}

// MARK: - VerdictInfo

private struct VerdictInfo {
    let raw: String

    var label: String {
        switch raw {
        case "plant_now":  return "Plant now"
        case "plant_soon": return "Plant soon"
        case "too_early":  return "Too early"
        case "late":       return "Window closing"
        case "too_late":   return "Missed this year"
        default:           return "Checking…"
        }
    }

    /// Delegates to `HerbColor` — shared source of truth with `SeedRow`.
    var foregroundColor: Color {
        HerbColor.verdictForegroundFallback(for: raw)
    }

    /// Delegates to `HerbColor`.
    var backgroundColor: Color {
        HerbColor.verdictBackground(for: raw)
    }
}

// MARK: - SuitabilityGradientBar

/// Draws the 60-day suitability gradient as a `Canvas` and overlays an
/// optional "Your date" marker when `userDate` falls within the span.
private struct SuitabilityGradientBar: View {
    let scores: [Double]
    let anchorDateString: String
    let userDate: Date?

    var body: some View {
        Canvas { context, size in
            guard !scores.isEmpty else {
                // No data — fill with a subtle grey band
                context.fill(
                    Path(CGRect(origin: .zero, size: size)),
                    with: .color(Color(.systemGray5))
                )
                return
            }

            let count = scores.count
            let segmentWidth = size.width / CGFloat(count)

            for (i, score) in scores.enumerated() {
                let clamped = min(max(score, 0), 1)
                let color = segmentColor(score: clamped)
                let rect = CGRect(
                    x: CGFloat(i) * segmentWidth,
                    y: 0,
                    width: segmentWidth + 0.5, // +0.5 avoids hairline gaps between segments
                    height: size.height
                )
                context.fill(Path(rect), with: .color(color))
            }

            // Draw "Your date" marker
            if let userDate, let anchorDate = parseDate(anchorDateString) {
                let cal = Calendar(identifier: .gregorian)
                var utcCal = cal
                utcCal.timeZone = TimeZone(identifier: "UTC")!
                let anchorMidnight = utcCal.startOfDay(for: anchorDate)
                let userMidnight = utcCal.startOfDay(for: userDate)
                let dayOffset = utcCal.dateComponents([.day], from: anchorMidnight, to: userMidnight).day ?? -1

                if dayOffset >= 0 && dayOffset < count {
                    let xCenter = (CGFloat(dayOffset) + 0.5) * segmentWidth
                    let markerRect = CGRect(x: xCenter - 1, y: 0, width: 2, height: size.height)
                    context.fill(Path(markerRect), with: .color(.white.opacity(0.9)))
                }
            }
        }
        .overlay(alignment: .topLeading) {
            // "Your date" label — rendered outside Canvas so it's a real SwiftUI Text
            if let label = userDateLabel {
                Text(label)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(.thinMaterial, in: .capsule)
                    .offset(x: userDateLabelOffset, y: 4)
            }
        }
    }

    // MARK: - Helpers

    /// Maps a score 0.0–1.0 to a gradient colour (grey → green).
    private func segmentColor(score: Double) -> Color {
        if score < 0.001 {
            return Color(.systemGray5)
        }
        // Blend from a muted amber (low) to bright green (high)
        let r = 0.60 - 0.50 * score
        let g = 0.50 + 0.46 * score
        let b = 0.20 - 0.15 * score
        return Color(red: r, green: g, blue: b)
    }

    private func parseDate(_ yyyymmdd: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate]
        f.timeZone = TimeZone(identifier: "UTC")!
        return f.date(from: yyyymmdd)
    }

    /// Fractional position (0–1) of the user date within the score span.
    private var userDateFraction: Double? {
        guard let userDate, let anchorDate = parseDate(anchorDateString) else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let anchorMidnight = cal.startOfDay(for: anchorDate)
        let userMidnight = cal.startOfDay(for: userDate)
        let dayOffset = cal.dateComponents([.day], from: anchorMidnight, to: userMidnight).day ?? -1
        let count = max(scores.count, 1)
        guard dayOffset >= 0 && dayOffset < count else { return nil }
        return (Double(dayOffset) + 0.5) / Double(count)
    }

    private var userDateLabel: String? {
        guard userDateFraction != nil else { return nil }
        return "Your date"
    }

    /// X offset for the label, clamped to avoid clipping at edges.
    private var userDateLabelOffset: CGFloat {
        // We don't have the view width here — approximate at 200pt, then
        // the label width ~60pt.  Clamp between 0 and 140.
        guard let fraction = userDateFraction else { return 0 }
        let approxWidth: CGFloat = 200
        let labelWidth: CGFloat = 60
        let raw = fraction * approxWidth - labelWidth / 2
        return min(max(raw, 0), approxWidth - labelWidth)
    }
}

// MARK: - Previews

#if DEBUG

private func makeSampleRecommendation(
    verdict: String,
    rangeStart: String? = nil,
    rangeEnd: String? = nil,
    indoorStart: String? = nil,
    indoorEnd: String? = nil,
    source: String = "ai",
    reasoning: String? = nil,
    scores: [Double]? = nil
) -> LocalRecommendation {
    let anchor = "2026-05-01"
    // Generate a plausible 60-day score curve when not specified
    let defaultScores: [Double] = (0..<60).map { i in
        // Bell-ish curve peaking around day 20–35
        let x = Double(i)
        let peak = 0.95 * exp(-pow(x - 27, 2) / 200)
        return min(max(peak, 0), 1)
    }
    let json = (try? String(data: JSONEncoder().encode(scores ?? defaultScores), encoding: .utf8)) ?? "[]"

    return LocalRecommendation(
        catalogSeedID: "preview-\(verdict)",
        locationSignature: "preview",
        computedAt: Int64(Date().timeIntervalSince1970 * 1000),
        source: source,
        confidence: 0.85,
        verdict: verdict,
        rangeStart: rangeStart,
        rangeEnd: rangeEnd,
        indoorStart: indoorStart,
        indoorEnd: indoorEnd,
        scoresAnchorDate: anchor,
        dailyScoresJSON: json,
        reasoning: reasoning,
        fetchedAt: Int64(Date().timeIntervalSince1970 * 1000)
    )
}

#Preview("Plant now — full window") {
    let rec = makeSampleRecommendation(
        verdict: "plant_now",
        rangeStart: "2026-05-18",
        rangeEnd: "2026-07-01",
        indoorStart: "2026-03-15",
        indoorEnd: "2026-04-15",
        source: "ai",
        reasoning: "Soil temperatures in your area typically reach optimal germination range by mid-May. The long season variety benefits from an early indoor start."
    )
    let refined = RefinedRecommendation(
        verdict: "plant_now",
        dailyScores: (0..<60).map { i in min(max(0.95 * exp(-pow(Double(i) - 25, 2) / 180), 0), 1) },
        scoresAnchorDate: "2026-05-01",
        weatherNote: "Next 10 days look ideal."
    )
    return Form {
        Section("Planting window") {
            RecommendationPanel(
                recommendation: rec,
                refined: refined,
                userDate: Calendar.current.date(byAdding: .day, value: 3, to: Date())
            )
        }
    }
}

#Preview("Unknown verdict") {
    let rec = makeSampleRecommendation(
        verdict: "unknown",
        source: "rule",
        scores: Array(repeating: 0.0, count: 60)
    )
    return Form {
        Section("Planting window") {
            RecommendationPanel(recommendation: rec, refined: nil, userDate: nil)
        }
    }
}

#Preview("Too early") {
    let rec = makeSampleRecommendation(
        verdict: "too_early",
        rangeStart: "2026-06-10",
        rangeEnd: "2026-08-01",
        source: "rule",
        reasoning: nil,
        scores: (0..<60).map { i in i < 30 ? 0.05 * Double(i) / 30.0 : 0.9 }
    )
    return Form {
        Section("Planting window") {
            RecommendationPanel(recommendation: rec, refined: nil, userDate: nil)
        }
    }
}

#Preview("Loading / nil") {
    Form {
        Section("Planting window") {
            RecommendationPanel(recommendation: nil, refined: nil, userDate: nil)
        }
    }
}

#Preview("Needs location") {
    Form {
        Section("Planting window") {
            RecommendationPanel.needsLocation
        }
    }
}

#Preview("Standalone card — plant soon") {
    let rec = makeSampleRecommendation(
        verdict: "plant_soon",
        rangeStart: "2026-06-01",
        rangeEnd: "2026-07-15",
        source: "rule"
    )
    return ScrollView {
        RecommendationPanel(recommendation: rec, refined: nil, userDate: nil)
            .padding()
            .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 12))
            .padding()
    }
}

#endif
