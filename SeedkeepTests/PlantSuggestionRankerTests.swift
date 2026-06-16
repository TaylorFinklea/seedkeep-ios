import Testing
import Foundation
@testable import Seedkeep

/// Tests for the pure `PlantSuggestionRanker` function.
/// No device services; no SwiftData; no async — just deterministic
/// score computation and ordering.
@Suite("PlantSuggestionRanker", .serialized)
struct PlantSuggestionRankerTests {

    // MARK: - Helpers

    private func seed(
        id: String = "s1",
        displayName: String = "Tomato",
        catalogID: String? = "cat1",
        yearPacked: Int? = nil,
        sunRequirement: String? = nil,
        plantSpacingInches: Int? = nil
    ) -> PlantSuggestionRanker.SeedInput {
        PlantSuggestionRanker.SeedInput(
            id: id,
            displayName: displayName,
            catalogID: catalogID,
            yearPacked: yearPacked,
            sunRequirement: sunRequirement,
            plantSpacingInches: plantSpacingInches
        )
    }

    private func rec(
        catalogID: String = "cat1",
        verdict: String,
        rangeStart: String? = "2026-05-01",
        rangeEnd: String? = "2026-07-01"
    ) -> PlantSuggestionRanker.RecommendationInput {
        PlantSuggestionRanker.RecommendationInput(
            catalogSeedID: catalogID,
            verdict: verdict,
            rangeStart: rangeStart,
            rangeEnd: rangeEnd
        )
    }

    private let today = Calendar.current.startOfDay(for: Date())
    private let unknownCues = CornerCues(exposure: .unknown, openness: .unknown)

    // MARK: - Empty input

    @Test("empty seeds → empty result")
    func emptySeeds() {
        let result = PlantSuggestionRanker.rank(seeds: [], recommendations: [], cues: unknownCues, today: today)
        #expect(result.isEmpty)
    }

    // MARK: - Verdict ordering

    @Test("plant_now ranks before plant_soon")
    func verdictOrderNowBeforeSoon() {
        let seeds = [
            seed(id: "s1", displayName: "A", catalogID: "cat1"),
            seed(id: "s2", displayName: "B", catalogID: "cat2"),
        ]
        let recs = [
            rec(catalogID: "cat1", verdict: "plant_soon"),
            rec(catalogID: "cat2", verdict: "plant_now"),
        ]
        let result = PlantSuggestionRanker.rank(seeds: seeds, recommendations: recs, cues: unknownCues, today: today)
        #expect(result.first?.seedID == "s2")
        #expect(result.last?.seedID == "s1")
    }

    @Test("full verdict ordering: plant_now > plant_soon > late > too_early > no-rec > too_late")
    func verdictFullOrdering() {
        let allVerdicts = ["too_late", "too_early", "late", "plant_soon", "plant_now"]
        let seeds = allVerdicts.enumerated().map { idx, v in
            seed(id: "s\(idx)", displayName: "Seed \(idx)", catalogID: "cat\(idx)")
        }
        // Plus one seed with no catalog/rec. verdictScore=35 > too_late=15 → ranks above too_late.
        let noCatalogSeed = seed(id: "sno", displayName: "No catalog", catalogID: nil)
        var allSeeds = seeds
        allSeeds.append(noCatalogSeed)

        let recs = allVerdicts.enumerated().map { idx, v in
            rec(catalogID: "cat\(idx)", verdict: v)
        }

        let result = PlantSuggestionRanker.rank(seeds: allSeeds, recommendations: recs, cues: unknownCues, today: today)

        // All seeds have no yearPacked → packetAgeBoost=6 each. Scores:
        //   plant_now=100+0+6=106, plant_soon=80+0+6=86, late=55+0+6=61,
        //   too_early=45+0+6=51, no-rec=35+0+6=41, too_late=15+0+6=21
        // Expect full sorted verdict order.
        #expect(result.map(\.verdict) == ["plant_now", "plant_soon", "late", "too_early", nil, "too_late"])
    }

    // MARK: - computeVerdictScore direct coverage

    @Test("computeVerdictScore: plant_now → 100")
    func verdictScorePlantNow() {
        #expect(PlantSuggestionRanker.computeVerdictScore(verdict: "plant_now") == 100)
    }

    @Test("computeVerdictScore: plant_soon → 80")
    func verdictScorePlantSoon() {
        #expect(PlantSuggestionRanker.computeVerdictScore(verdict: "plant_soon") == 80)
    }

    @Test("computeVerdictScore: late → 55")
    func verdictScoreLate() {
        #expect(PlantSuggestionRanker.computeVerdictScore(verdict: "late") == 55)
    }

    @Test("computeVerdictScore: too_early → 45")
    func verdictScoreTooEarly() {
        #expect(PlantSuggestionRanker.computeVerdictScore(verdict: "too_early") == 45)
    }

    @Test("computeVerdictScore: too_late → 15")
    func verdictScoreTooLate() {
        #expect(PlantSuggestionRanker.computeVerdictScore(verdict: "too_late") == 15)
    }

    @Test("computeVerdictScore: nil/unknown → 35")
    func verdictScoreNone() {
        #expect(PlantSuggestionRanker.computeVerdictScore(verdict: nil) == 35)
        #expect(PlantSuggestionRanker.computeVerdictScore(verdict: "unknown") == 35)
    }

    // MARK: - exposureFit

    @Test("match → +15")
    func exposureFitMatch() {
        let score = PlantSuggestionRanker.computeExposureFit(sunRequirement: "full", exposure: .fullSun)
        #expect(score == 15)
    }

    @Test("adjacent → +5")
    func exposureFitAdjacent() {
        let score = PlantSuggestionRanker.computeExposureFit(sunRequirement: "full", exposure: .partialSun)
        #expect(score == 5)
    }

    @Test("mismatch → -15")
    func exposureFitMismatch() {
        let score = PlantSuggestionRanker.computeExposureFit(sunRequirement: "full", exposure: .shade)
        #expect(score == -15)
    }

    @Test("partial adjacent to shade → +5")
    func exposureFitPartialShadeAdjacent() {
        let score = PlantSuggestionRanker.computeExposureFit(sunRequirement: "partial", exposure: .shade)
        #expect(score == 5)
    }

    @Test("shade match → +15")
    func exposureFitShadeMatch() {
        let score = PlantSuggestionRanker.computeExposureFit(sunRequirement: "shade", exposure: .shade)
        #expect(score == 15)
    }

    @Test("unknown exposure → 0")
    func exposureFitUnknownExposure() {
        let score = PlantSuggestionRanker.computeExposureFit(sunRequirement: "full", exposure: .unknown)
        #expect(score == 0)
    }

    @Test("nil sun_requirement → 0")
    func exposureFitNilRequirement() {
        let score = PlantSuggestionRanker.computeExposureFit(sunRequirement: nil, exposure: .fullSun)
        #expect(score == 0)
    }

    @Test("unknown catalog value → 0")
    func exposureFitUnknownCatalogValue() {
        let score = PlantSuggestionRanker.computeExposureFit(sunRequirement: "dappled", exposure: .fullSun)
        #expect(score == 0)
    }

    // MARK: - packetAgeBoost

    @Test("null yearPacked → 6")
    func packetAgeBoostNull() {
        let currentYear = 2026
        let boost = PlantSuggestionRanker.computePacketAgeBoost(yearPacked: nil, currentYear: currentYear)
        #expect(boost == 6)
    }

    @Test("packed same year → min(12, 3*1) = 3")
    func packetAgeBoostSameYear() {
        let boost = PlantSuggestionRanker.computePacketAgeBoost(yearPacked: 2026, currentYear: 2026)
        #expect(boost == 3)
    }

    @Test("packed 1 year ago → 3")
    func packetAgeBoostOneYear() {
        let boost = PlantSuggestionRanker.computePacketAgeBoost(yearPacked: 2025, currentYear: 2026)
        #expect(boost == 3)
    }

    @Test("packed 2 years ago → 6")
    func packetAgeBoostTwoYears() {
        let boost = PlantSuggestionRanker.computePacketAgeBoost(yearPacked: 2024, currentYear: 2026)
        #expect(boost == 6)
    }

    @Test("packed 3 years ago → 9")
    func packetAgeBoostThreeYears() {
        let currentYear = Calendar.current.component(.year, from: Date())
        let boost = PlantSuggestionRanker.computePacketAgeBoost(yearPacked: currentYear - 3, currentYear: currentYear)
        #expect(boost == 9)
    }

    @Test("packed 4 years ago → 12 (capped)")
    func packetAgeBoostCapped() {
        let boost = PlantSuggestionRanker.computePacketAgeBoost(yearPacked: 2022, currentYear: 2026)
        #expect(boost == 12)
    }

    @Test("very old packet → still 12 (cap)")
    func packetAgeBoostVeryOld() {
        let boost = PlantSuggestionRanker.computePacketAgeBoost(yearPacked: 2010, currentYear: 2026)
        #expect(boost == 12)
    }

    // MARK: - opennessNudge

    @Test("crowded + large spacing (>18) → -5")
    func opennessNudgeCrowded() {
        let nudge = PlantSuggestionRanker.computeOpennessNudge(plantSpacingInches: 24, openness: .crowded)
        #expect(nudge == -5)
    }

    @Test("crowded + nil spacing → 0")
    func opennessNudgeCrowdedNoSpacing() {
        let nudge = PlantSuggestionRanker.computeOpennessNudge(plantSpacingInches: nil, openness: .crowded)
        #expect(nudge == 0)
    }

    @Test("crowded + small spacing (≤18) → 0")
    func opennessNudgeCrowdedSmallSpacing() {
        let nudge = PlantSuggestionRanker.computeOpennessNudge(plantSpacingInches: 12, openness: .crowded)
        #expect(nudge == 0)
    }

    @Test("open + large spacing → 0")
    func opennessNudgeNotCrowded() {
        let nudge = PlantSuggestionRanker.computeOpennessNudge(plantSpacingInches: 36, openness: .open)
        #expect(nudge == 0)
    }

    @Test("partial openness → 0")
    func opennessNudgePartial() {
        let nudge = PlantSuggestionRanker.computeOpennessNudge(plantSpacingInches: 24, openness: .partial)
        #expect(nudge == 0)
    }

    // MARK: - Seeds with no catalog / no recommendation

    @Test("seed without catalog included with verdictScore=35")
    func noCatalogSeedIncluded() {
        let noCatalogSeed = seed(id: "sno", displayName: "Heirloom", catalogID: nil)
        let result = PlantSuggestionRanker.rank(seeds: [noCatalogSeed], recommendations: [], cues: unknownCues, today: today)
        #expect(result.count == 1)
        #expect(result[0].hasNoWindowData == true)
        #expect(result[0].verdictScore == 35)
    }

    @Test("seed with catalog but no recommendation included with verdictScore=35")
    func withCatalogNoRec() {
        let s = seed(id: "s1", displayName: "Pepper", catalogID: "cat_missing")
        let result = PlantSuggestionRanker.rank(seeds: [s], recommendations: [], cues: unknownCues, today: today)
        #expect(result.count == 1)
        #expect(result[0].hasNoWindowData == true)
        #expect(result[0].verdictScore == 35)
    }

    // MARK: - Deterministic tie-break

    @Test("same score → tie-break by display name ascending")
    func tieBreakByName() {
        // Two seeds, both no-rec → verdictScore=35 + packetAge=6 = 41 each.
        let seeds = [
            seed(id: "s1", displayName: "Zucchini", catalogID: nil),
            seed(id: "s2", displayName: "Artichoke", catalogID: nil),
        ]
        let result = PlantSuggestionRanker.rank(seeds: seeds, recommendations: [], cues: unknownCues, today: today)
        #expect(result[0].displayName == "Artichoke")
        #expect(result[1].displayName == "Zucchini")
    }

    @Test("same score same verdict → tie-break by name is deterministic across calls")
    func tieBreakDeterministic() {
        let seeds = (1...5).map { i in
            seed(id: "s\(i)", displayName: "Seed \(i)", catalogID: "cat\(i)")
        }
        let recs = (1...5).map { i in
            rec(catalogID: "cat\(i)", verdict: "plant_soon")
        }
        let r1 = PlantSuggestionRanker.rank(seeds: seeds, recommendations: recs, cues: unknownCues, today: today)
        let r2 = PlantSuggestionRanker.rank(seeds: seeds, recommendations: recs, cues: unknownCues, today: today)
        #expect(r1.map(\.seedID) == r2.map(\.seedID))
    }

    // MARK: - Integration: full ranking with cues

    @Test("full_sun seed in full_sun corner scores higher than shade seed")
    func integrationExposureBoost() {
        let fullSunSeed = seed(id: "sunny", displayName: "Sunflower", catalogID: "cat_sun", sunRequirement: "full")
        let shadeSeed = seed(id: "shady", displayName: "Fern", catalogID: "cat_fern", sunRequirement: "shade")

        let recs = [
            rec(catalogID: "cat_sun", verdict: "plant_now"),
            rec(catalogID: "cat_fern", verdict: "plant_now"),
        ]
        let cues = CornerCues(exposure: .fullSun, openness: .unknown)
        let result = PlantSuggestionRanker.rank(seeds: [fullSunSeed, shadeSeed], recommendations: recs, cues: cues, today: today)

        // Both plant_now: sunflower gets +15 exposureFit, fern gets -15.
        #expect(result[0].seedID == "sunny")
    }

    @Test("crowded corner penalises large-spacing seed")
    func integrationOpennessNudge() {
        let largeSeed = seed(id: "large", displayName: "Pumpkin", catalogID: "cat_large", plantSpacingInches: 36)
        let smallSeed = seed(id: "small", displayName: "Carrot", catalogID: "cat_small", plantSpacingInches: 6)

        let recs = [
            rec(catalogID: "cat_large", verdict: "plant_now"),
            rec(catalogID: "cat_small", verdict: "plant_now"),
        ]
        let cues = CornerCues(exposure: .unknown, openness: .crowded)
        let result = PlantSuggestionRanker.rank(seeds: [largeSeed, smallSeed], recommendations: recs, cues: cues, today: today)

        // Pumpkin gets -5 openness nudge, carrot gets 0.
        #expect(result[0].seedID == "small")
    }
}
