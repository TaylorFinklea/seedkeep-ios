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
/// // Nil state: the seed has no growing info to plan from
/// RecommendationPanel(recommendation: nil, refined: nil, userDate: nil)
///
/// // No-location state — show guidance to set garden location
/// RecommendationPanel.needsLocation
/// ```
struct RecommendationPanel: View {

    // MARK: Inputs

    let recommendation: PlantingRecommendation?
    let refined: RefinedRecommendation?
    /// When non-nil and within the 60-day score span, a vertical "Your date"
    /// marker is drawn on the gradient bar.
    let userDate: Date?
    /// True when the seed has growing info, even if none of it is a field the engine reads. Words the
    /// note shown when there is no recommendation.
    var hasGrowingInfo = false

    // MARK: Body

    var body: some View {
        if let rec = recommendation {
            filledPanel(rec)
        } else {
            noGrowingInfo
        }
    }

    // MARK: - Filled panel

    @ViewBuilder
    private func filledPanel(_ rec: PlantingRecommendation) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            verdictBadge(for: rec)
            confidenceRow(for: rec)
            windowDates(for: rec)
            gradientBar(for: rec)
            weatherNoteRow
            reasoningRow(for: rec)
        }
    }

    // MARK: - Verdict badge

    private func verdictBadge(for rec: PlantingRecommendation) -> some View {
        let effectiveVerdict = refined?.verdict ?? rec.verdict
        let info = VerdictInfo(raw: effectiveVerdict)
        return WBStatusChip(info.label, tone: .verdict(effectiveVerdict))
    }

    // MARK: - Window dates

    @ViewBuilder
    private func windowDates(for rec: PlantingRecommendation) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            if let start = rec.rangeStart, let end = rec.rangeEnd {
                let startStr = Self.formattedDate(start) ?? start
                let endStr = Self.formattedDate(end) ?? end
                windowRow("OUTDOOR", "\(startStr) – \(endStr)", datesColor: WBColor.ink)
            } else if rec.rangeStart == nil && rec.rangeEnd == nil {
                Text(Self.noWindowNote(for: rec.reason))
                    .font(.wbBody)
                    .foregroundStyle(WBColor.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let iStart = rec.indoorStart, let iEnd = rec.indoorEnd {
                let iStartStr = Self.formattedDate(iStart) ?? iStart
                let iEndStr = Self.formattedDate(iEnd) ?? iEnd
                windowRow("INDOORS", "\(iStartStr) – \(iEndStr)", datesColor: WBColor.muted)
            }
        }
    }

    /// A labelled date range: the label beside the dates, or above them when large text leaves no
    /// room on one line (side by side, the label would break mid-word).
    private func windowRow(_ label: String, _ dates: String, datesColor: Color) -> some View {
        let labelText = Text(label)
            .font(.wbCaption.weight(.semibold))
            .tracking(1.4)
            .foregroundStyle(WBColor.muted)
        let datesText = Text(dates)
            .font(.wbBody)
            .foregroundStyle(datesColor)
        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                labelText
                datesText
            }
            VStack(alignment: .leading, spacing: 2) {
                labelText
                datesText
            }
        }
    }

    // MARK: - 60-day gradient bar

    @ViewBuilder
    private func gradientBar(for rec: PlantingRecommendation) -> some View {
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
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Self.chartSummary(
                rangeStart: rec.rangeStart, rangeEnd: rec.rangeEnd,
                verdict: refined?.verdict ?? rec.verdict, userDate: userDate))

            // Date axis labels. At large text sizes the middle label goes first, then the two ends
            // stack, so no label is truncated.
            let start = axisLabel(shortDate(anchorStr) ?? "Today")
            let end = axisLabel("+60D")
            ViewThatFits(in: .horizontal) {
                HStack {
                    start
                    Spacer()
                    axisLabel("+30D")
                    Spacer()
                    end
                }
                HStack {
                    start
                    Spacer()
                    end
                }
                VStack(alignment: .leading, spacing: 2) {
                    start
                    end
                }
            }
        }
    }

    private func axisLabel(_ text: String) -> some View {
        Text(text)
            .font(.wbCaption.weight(.semibold))
            .tracking(1.2)
            .foregroundStyle(WBColor.muted)
    }

    /// What VoiceOver reads for the 60-day chart, which is drawn in a Canvas: the window, today's
    /// verdict and, when one is set, the date being planned.
    static func chartSummary(rangeStart: String?, rangeEnd: String?, verdict: String,
                             userDate: Date?, calendar: Calendar = .current) -> String {
        var parts: [String] = []
        if let start = rangeStart.flatMap(formattedDate), let end = rangeEnd.flatMap(formattedDate) {
            parts.append("Best from \(start) to \(end)")
        } else {
            parts.append("No planting window")
        }
        parts.append("today: \(VerdictInfo(raw: verdict).label.lowercased())")
        if let userDate {
            parts.append("your date: \(utcMonthDay(plannedDay(userDate, calendar: calendar)))")
        }
        return parts.joined(separator: "; ")
    }

    // MARK: - Weather note

    @ViewBuilder
    private var weatherNoteRow: some View {
        if let note = refined?.weatherNote {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "cloud.fill")
                    .font(.wbFootnote)
                    .foregroundStyle(WBColor.muted)
                Text(note)
                    .font(.wbBody)
                    .foregroundStyle(WBColor.muted)
            }
        }
    }

    // MARK: - Confidence

    /// A window the rule had little to go on for is still shown, with its confidence.
    @ViewBuilder
    private func confidenceRow(for rec: PlantingRecommendation) -> some View {
        if let note = Self.confidenceNote(for: rec) {
            Text(note)
                .font(.wbBody)
                .foregroundStyle(WBColor.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The low-confidence note, shown only when a window exists but growing info fields are
    /// missing. A missing window explains itself through `noWindowNote(for:)` instead.
    static func confidenceNote(for rec: PlantingRecommendation) -> String? {
        guard rec.reason == .incompleteInfo else { return nil }
        return "Low confidence (\(Int((rec.confidence * 100).rounded()))%): the growing info for this seed is incomplete."
    }

    /// Why the engine computed no outdoor window, worded from its reason.
    static func noWindowNote(for reason: PlantingRecommendation.Reason?) -> String {
        switch reason {
        case .seasonTooShort:
            return "No window: the season here is too short for this seed to mature before the first frost."
        case .missingMaturity:
            return "No window: this seed has no days to maturity, so there is no latest planting date."
        case .unreadableClimate:
            return "No window: the home location's frost dates couldn't be read."
        case .incompleteInfo, .none:
            return "No outdoor window computed"
        }
    }

    /// Why a seed has no recommendation (with a home location set): no growing info at all, or growing
    /// info with none of the fields the engine reads.
    static func noRecommendationNote(hasGrowingInfo: Bool) -> String {
        hasGrowingInfo
            ? "This seed's growing info doesn't include a frost tolerance, sowing method or days to maturity, so there's no planting window yet."
            : "No growing info for this seed."
    }

    /// The verdict's label. "unknown" is final on the device, so it reads "No window".
    static func verdictLabel(for raw: String) -> String {
        VerdictInfo(raw: raw).label
    }

    // MARK: - Reasoning

    @ViewBuilder
    private func reasoningRow(for rec: PlantingRecommendation) -> some View {
        if let reasoning = rec.reasoning, !reasoning.isEmpty {
            Text(reasoning)
                .font(.wbBody)
                .foregroundStyle(WBColor.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - No growing info

    private var noGrowingInfo: some View {
        Text(Self.noRecommendationNote(hasGrowingInfo: hasGrowingInfo))
            .font(.wbBody)
            .foregroundStyle(WBColor.muted)
    }

    // MARK: - Helpers

    /// Parses a "YYYY-MM-DD" string and returns a readable "May 18" string.
    private static func formattedDate(_ yyyymmdd: String) -> String? {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        guard let date = f.date(from: yyyymmdd) else { return nil }
        return utcMonthDay(date)
    }

    /// The day the user picked, as UTC midnight. The picker and the saved date use the local day,
    /// while the chart's anchor and labels are UTC days, so the local year, month and day are
    /// rebuilt in UTC before they're compared or formatted. Only `calendar`'s time zone is used:
    /// the day is always read in Gregorian, like the saved "yyyy-MM-dd", so a Buddhist or other
    /// system calendar can't shift the year.
    nonisolated static func plannedDay(_ date: Date, calendar: Calendar = .current) -> Date {
        var local = Calendar(identifier: .gregorian)
        local.timeZone = calendar.timeZone
        let parts = local.dateComponents([.year, .month, .day], from: date)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        return utc.date(from: parts) ?? date
    }

    /// A UTC day as "May 18".
    private static func utcMonthDay(_ date: Date) -> String {
        let out = DateFormatter()
        out.dateFormat = "MMM d"
        out.locale = Locale(identifier: "en_US_POSIX")
        out.timeZone = TimeZone(identifier: "UTC")
        return out.string(from: date)
    }

    /// Short date label for the axis — just "MMM d".
    private func shortDate(_ yyyymmdd: String) -> String? {
        Self.formattedDate(yyyymmdd)
    }

    // MARK: - No-location variant

    /// Lightweight static view: shown when `RecommendationStore.needsHomeLocation`
    /// is true. Callers pick which variant to display.
    static var needsLocation: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "nosign")
                .font(.wbFootnote)
                .foregroundStyle(WBColor.warn)
            VStack(alignment: .leading, spacing: 4) {
                Text("LOCATION REQUIRED")
                    .font(.wbCaption.weight(.semibold))
                    .tracking(1.5)
                    .foregroundStyle(WBColor.ink)
                Text("Set your garden location in Settings → Home location to see planting windows.")
                    .font(.wbBody)
                    .foregroundStyle(WBColor.muted)
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
        // The device computes every window at once, so "unknown" is final, not pending.
        default:           return "No window"
        }
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
                    with: .color(WBColor.line)
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
                let userMidnight = RecommendationPanel.plannedDay(userDate)
                let dayOffset = utcCal.dateComponents([.day], from: anchorMidnight, to: userMidnight).day ?? -1

                if dayOffset >= 0 && dayOffset < count {
                    let xCenter = (CGFloat(dayOffset) + 0.5) * segmentWidth
                    let markerRect = CGRect(x: xCenter - 1, y: 0, width: 2, height: size.height)
                    // `ink` stands out on every segment, including the empty `line` days.
                    context.fill(Path(markerRect), with: .color(WBColor.ink))
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

    /// Uses the plant-now verdict token, with opacity to show suitability strength. Days with no
    /// suitability are `line`.
    private func segmentColor(score: Double) -> Color {
        score < 0.001 ? WBColor.line : WBColor.verdictPlantNow.opacity(0.25 + score * 0.75)
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
        let userMidnight = RecommendationPanel.plannedDay(userDate)
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
    reasoning: String? = nil,
    scores: [Double]? = nil
) -> PlantingRecommendation {
    let anchor = "2026-05-01"
    // Generate a plausible 60-day score curve when not specified
    let defaultScores: [Double] = (0..<60).map { i in
        // Bell-ish curve peaking around day 20–35
        let x = Double(i)
        let peak = 0.95 * exp(-pow(x - 27, 2) / 200)
        return min(max(peak, 0), 1)
    }
    return PlantingRecommendation(
        source: "rule",
        confidence: 0.85,
        verdict: verdict,
        rangeStart: rangeStart,
        rangeEnd: rangeEnd,
        indoorStart: indoorStart,
        indoorEnd: indoorEnd,
        scoresAnchorDate: anchor,
        dailyScores: scores ?? defaultScores,
        reasoning: reasoning
    )
}

#Preview("Plant now — full window") {
    let rec = makeSampleRecommendation(
        verdict: "plant_now",
        rangeStart: "2026-05-18",
        rangeEnd: "2026-07-01",
        indoorStart: "2026-03-15",
        indoorEnd: "2026-04-15",
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
        rangeEnd: "2026-07-15"
    )
    return ScrollView {
        RecommendationPanel(recommendation: rec, refined: nil, userDate: nil)
            .padding()
            #if os(iOS)
            .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 12))
            #else
            .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 12))
            #endif
            .padding()
    }
}

#endif
