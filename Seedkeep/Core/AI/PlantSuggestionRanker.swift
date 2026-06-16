import Foundation

// MARK: - PlantSuggestion

/// A single ranked suggestion produced by `PlantSuggestionRanker`.
struct PlantSuggestion: Equatable {
    /// The id of the owned seed this suggestion refers to.
    let seedID: String
    /// Seed display name, carried through so the view never needs a second lookup.
    let displayName: String
    /// The catalog seed id, nil for seeds without a catalog link.
    let catalogID: String?
    /// The computed total score (higher is better).
    let score: Double
    /// Component scores for debugging / display.
    let verdictScore: Double
    let exposureFit: Double
    let packetAgeBoost: Double
    let opennessNudge: Double
    /// Resolved verdict from the recommendation. nil when no recommendation exists.
    let verdict: String?
    /// Outdoor planting window dates (YYYY-MM-DD). nil when no recommendation.
    let rangeStart: String?
    let rangeEnd: String?
    /// True when this seed has no catalog link or recommendation data.
    let hasNoWindowData: Bool
}

// MARK: - PlantSuggestionRanker

/// Pure, deterministic ranker. No I/O.
///
/// Spec-derived ranking formula (implement exactly):
///
///   score = verdictScore + exposureFit + packetAgeBoost + opennessNudge
///
/// Tie-break: verdict rank descending, then display name ascending.
enum PlantSuggestionRanker {

    // MARK: - Input types (lightweight structs the caller builds from SwiftData / LocalRecommendation)

    struct SeedInput: Equatable {
        let id: String
        let displayName: String
        let catalogID: String?
        /// From LocalSeed.yearPacked
        let yearPacked: Int?
        /// From LocalSeed.growingInfo?.sun_requirement ("full" | "partial" | "shade" | nil)
        let sunRequirement: String?
        /// From LocalSeed.growingInfo?.plant_spacing_inches
        let plantSpacingInches: Int?
    }

    struct RecommendationInput: Equatable {
        let catalogSeedID: String
        let verdict: String
        let rangeStart: String?
        let rangeEnd: String?
    }

    // MARK: - Entry point

    /// Ranks all `seeds` and returns a sorted `[PlantSuggestion]`.
    /// Seeds with no recommendation are included (verdictScore = 35).
    /// Empty input → empty output.
    static func rank(
        seeds: [SeedInput],
        recommendations: [RecommendationInput],
        cues: CornerCues,
        today: Date
    ) -> [PlantSuggestion] {
        guard !seeds.isEmpty else { return [] }

        let recMap: [String: RecommendationInput] = Dictionary(
            recommendations.map { ($0.catalogSeedID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let currentYear = Calendar.current.component(.year, from: today)

        let suggestions = seeds.map { seed in
            buildSuggestion(seed: seed, rec: seed.catalogID.flatMap { recMap[$0] },
                            cues: cues, currentYear: currentYear)
        }

        return suggestions.sorted { a, b in
            if a.score != b.score { return a.score > b.score }
            // Tie-break 1: verdict rank (plant_now > plant_soon > late > too_early > too_late > nil/other)
            let ra = verdictRank(a.verdict)
            let rb = verdictRank(b.verdict)
            if ra != rb { return ra > rb }
            // Tie-break 2: display name ascending (stable, deterministic)
            return a.displayName < b.displayName
        }
    }

    // MARK: - Per-seed computation

    private static func buildSuggestion(
        seed: SeedInput,
        rec: RecommendationInput?,
        cues: CornerCues,
        currentYear: Int
    ) -> PlantSuggestion {
        let verdictScore = computeVerdictScore(verdict: rec?.verdict)
        let exposureFit = computeExposureFit(sunRequirement: seed.sunRequirement, exposure: cues.exposure)
        let packetAgeBoost = computePacketAgeBoost(yearPacked: seed.yearPacked, currentYear: currentYear)
        let opennessNudge = computeOpennessNudge(
            plantSpacingInches: seed.plantSpacingInches, openness: cues.openness
        )
        let score = verdictScore + exposureFit + packetAgeBoost + opennessNudge

        return PlantSuggestion(
            seedID: seed.id,
            displayName: seed.displayName,
            catalogID: seed.catalogID,
            score: score,
            verdictScore: verdictScore,
            exposureFit: exposureFit,
            packetAgeBoost: packetAgeBoost,
            opennessNudge: opennessNudge,
            verdict: rec?.verdict,
            rangeStart: rec?.rangeStart,
            rangeEnd: rec?.rangeEnd,
            hasNoWindowData: rec == nil
        )
    }

    // MARK: - Score components

    /// Spec: plant_now → 100, plant_soon → 80, late → 55,
    /// too_early → 45, too_late → 15, none/unknown → 35.
    static func computeVerdictScore(verdict: String?) -> Double {
        switch verdict {
        case "plant_now":  return 100
        case "plant_soon": return 80
        case "late":       return 55
        case "too_early":  return 45
        case "too_late":   return 15
        default:           return 35
        }
    }

    /// Spec: match → +15, adjacent → +5, mismatch → -15, unknown on either → 0.
    /// sun_requirement values: "full" / "partial" / "shade"
    /// Exposure values:        .fullSun / .partialSun / .shade / .unknown
    static func computeExposureFit(sunRequirement: String?, exposure: Exposure) -> Double {
        guard let req = sunRequirement, exposure != .unknown else { return 0 }

        // Normalise catalog value to Exposure enum.
        let catalogExposure: Exposure
        switch req.lowercased() {
        case "full":    catalogExposure = .fullSun
        case "partial": catalogExposure = .partialSun
        case "shade":   catalogExposure = .shade
        default:        return 0
        }

        if catalogExposure == exposure { return 15 }
        if isAdjacent(catalogExposure, exposure) { return 5 }
        return -15
    }

    /// Adjacent pairs: fullSun↔partialSun, partialSun↔shade.
    private static func isAdjacent(_ a: Exposure, _ b: Exposure) -> Bool {
        let ordered: [Exposure] = [.fullSun, .partialSun, .shade]
        guard let ia = ordered.firstIndex(of: a), let ib = ordered.firstIndex(of: b) else { return false }
        return abs(ia - ib) == 1
    }

    /// Spec: min(12, 3 × max(1, currentYear − year_packed)) when set; 6 when null.
    static func computePacketAgeBoost(yearPacked: Int?, currentYear: Int) -> Double {
        guard let year = yearPacked else { return 6 }
        let age = max(1, currentYear - year)
        return min(12, Double(3 * age))
    }

    /// Spec: if openness == .crowded AND plant_spacing_inches > 18 → -5, else 0.
    /// "Large/spreading" threshold: spacing > 18 inches.
    static func computeOpennessNudge(plantSpacingInches: Int?, openness: Openness) -> Double {
        guard openness == .crowded, let spacing = plantSpacingInches, spacing > 18 else { return 0 }
        return -5
    }

    /// Higher number = better verdict. Used for tie-breaking.
    private static func verdictRank(_ verdict: String?) -> Int {
        switch verdict {
        case "plant_now":  return 6
        case "plant_soon": return 5
        case "late":       return 4
        case "too_early":  return 3
        case "too_late":   return 2
        default:           return 1
        }
    }
}
