import Testing
import Foundation
import UIKit
import SwiftData
@testable import Seedkeep
import SeedkeepKit

/// Integration-style tests for `CornerSuggestionsViewModel`.
/// All I/O is stubbed: the analyzer, seed-fetcher, and recommendation-fetcher
/// are injected as closures — no real camera, no network, no keychain.
@MainActor
@Suite("CornerSuggestionsViewModel", .serialized)
struct CornerSuggestionsViewModelTests {

    // MARK: - Fixture helpers

    private func makeImage() -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8), format: format).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
    }

    private func seed(
        id: String,
        displayName: String,
        catalogID: String? = nil,
        yearPacked: Int? = nil
    ) -> PlantSuggestionRanker.SeedInput {
        PlantSuggestionRanker.SeedInput(
            id: id,
            displayName: displayName,
            catalogID: catalogID,
            yearPacked: yearPacked,
            sunRequirement: nil,
            plantSpacingInches: nil
        )
    }

    private func rec(catalogID: String, verdict: String) -> PlantSuggestionRanker.RecommendationInput {
        PlantSuggestionRanker.RecommendationInput(
            catalogSeedID: catalogID,
            verdict: verdict,
            rangeStart: "2026-05-01",
            rangeEnd: "2026-07-01"
        )
    }

    // MARK: - Tests

    @Test("capture → analyze → rank populates suggestions in order")
    func captureFlowRanksSuggestions() async {
        let seeds = [
            seed(id: "s1", displayName: "Tomato", catalogID: "cat1"),
            seed(id: "s2", displayName: "Pepper", catalogID: "cat2"),
        ]
        let recs = [
            rec(catalogID: "cat1", verdict: "plant_now"),
            rec(catalogID: "cat2", verdict: "plant_soon"),
        ]
        let analyzeCues = CornerCues(exposure: .fullSun, openness: .open)

        let vm = CornerSuggestionsViewModel(
            analyze: { _ in analyzeCues },
            fetchSeeds: { seeds },
            fetchRecommendations: { _ in recs }
        )

        await vm.capture(image: makeImage())

        #expect(!vm.suggestions.isEmpty)
        // plant_now should rank first.
        #expect(vm.suggestions[0].verdict == "plant_now")
        #expect(vm.suggestions[1].verdict == "plant_soon")
        // Cues should be the stub result.
        #expect(vm.cues == analyzeCues)
    }

    @Test("edit cue re-ranks without re-fetching recommendations")
    func editCueReranks() async {
        let seeds = [
            seed(id: "sunny", displayName: "Sunflower", catalogID: "cat_sun"),
            seed(id: "shady", displayName: "Fern", catalogID: "cat_fern"),
        ]
        var seedsWithSun = seeds
        seedsWithSun[0] = PlantSuggestionRanker.SeedInput(
            id: "sunny", displayName: "Sunflower", catalogID: "cat_sun",
            yearPacked: nil, sunRequirement: "full", plantSpacingInches: nil
        )
        seedsWithSun[1] = PlantSuggestionRanker.SeedInput(
            id: "shady", displayName: "Fern", catalogID: "cat_fern",
            yearPacked: nil, sunRequirement: "shade", plantSpacingInches: nil
        )

        let recs = [
            rec(catalogID: "cat_sun", verdict: "plant_now"),
            rec(catalogID: "cat_fern", verdict: "plant_now"),
        ]
        var fetchCount = 0

        let vm = CornerSuggestionsViewModel(
            analyze: { _ in CornerCues(exposure: .unknown, openness: .unknown) },
            fetchSeeds: { seedsWithSun },
            fetchRecommendations: { _ in
                fetchCount += 1
                return recs
            }
        )

        await vm.capture(image: makeImage())

        let fetchCountAfterCapture = fetchCount

        // Change cue to fullSun — should re-rank without re-fetching.
        vm.cues = CornerCues(exposure: .fullSun, openness: .unknown)
        vm.cueChanged()

        // rerankOnly() is now synchronous (no Task), so results are immediately available.
        // Assert no additional fetch occurred.
        #expect(fetchCount == fetchCountAfterCapture)

        // With fullSun cue, Sunflower (sun_requirement="full") should now score +15 exposureFit.
        #expect(vm.suggestions[0].seedID == "sunny")
    }

    @Test("offline cached recs: empty recs still produces results using verdictScore=35")
    func offlineCachedRecsPath() async {
        let seeds = [
            seed(id: "s1", displayName: "Bean", catalogID: "cat1"),
        ]

        let vm = CornerSuggestionsViewModel(
            analyze: { _ in .unknown },
            fetchSeeds: { seeds },
            fetchRecommendations: { _ in [] } // offline → no recs returned
        )

        await vm.capture(image: makeImage())

        // Seed should still appear, with hasNoWindowData=true.
        #expect(vm.suggestions.count == 1)
        #expect(vm.suggestions[0].hasNoWindowData == true)
        #expect(vm.staleness == .staleRecs)
    }

    @Test("empty seed library → empty suggestions")
    func emptyLibraryState() async {
        let vm = CornerSuggestionsViewModel(
            analyze: { _ in .unknown },
            fetchSeeds: { [] },
            fetchRecommendations: { _ in [] }
        )

        await vm.capture(image: makeImage())

        #expect(vm.suggestions.isEmpty)
    }

    @Test("capturedImage is set after capture")
    func capturedImageSet() async {
        let img = makeImage()
        let vm = CornerSuggestionsViewModel(
            analyze: { _ in .unknown },
            fetchSeeds: { [] },
            fetchRecommendations: { _ in [] }
        )

        #expect(vm.capturedImage == nil)
        await vm.capture(image: img)
        #expect(vm.capturedImage != nil)
    }

    @Test("isLoading is false after capture completes")
    func isLoadingFalseAfterCapture() async {
        let vm = CornerSuggestionsViewModel(
            analyze: { _ in .unknown },
            fetchSeeds: { [] },
            fetchRecommendations: { _ in [] }
        )

        await vm.capture(image: makeImage())
        #expect(!vm.isLoading)
    }

    @Test("vision analysis failure (nil image) degrades to .unknown cues")
    func visionFailureDegrades() async {
        let vm = CornerSuggestionsViewModel(
            analyze: { _ in .unknown }, // simulates failure → unknown
            fetchSeeds: { [] },
            fetchRecommendations: { _ in [] }
        )

        await vm.capture(image: makeImage())

        #expect(vm.cues == .unknown)
        #expect(!vm.isLoading)
    }
}
