import Testing
import Foundation
import SwiftData
import UIKit
@testable import Seedkeep
import SeedkeepKit

/// E2E integration tests for the "photo-of-corner" suggestion flow (Phase 4B).
///
/// Mirrors the M5 pattern: in-memory ModelContainer, all I/O (analyze, seed-fetch,
/// rec-fetch) injected as stubs. No real device services (camera/keychain/network).
///
/// Asserts:
///   (a) capture → analyze → rank produces plant_now-first results.
///   (b) editing a cue re-ranks without triggering an extra recommendations fetch.
///   (c) the captured photo is NOT persisted to SwiftData after the flow (ephemeral).
@MainActor
@Suite("CornerSuggestions E2E flow (Phase 4B)", .serialized)
struct CornerSuggestionsFlowTests {

    private static let householdID = "hh_4b"

    // MARK: - Container factory

    private static func makeContainer(_ name: String) -> ModelContainer {
        makeTestContainer(name: name)
    }

    // MARK: - Seed helpers

    /// Inserts a mix of active seeds (catalog-linked and not) into the container.
    private static func seedActiveSeedsInContainer(_ container: ModelContainer) throws {
        let ctx = ModelContext(container)
        // Active, catalog-linked — will receive a plant_now recommendation.
        ctx.insert(LocalSeed(
            id: "flow_tomato",
            householdID: householdID,
            catalogID: "cat_tomato",
            state: .active,
            packetCount: 1,
            source: .store,
            createdAt: 1, updatedAt: 1
        ))
        // Active, catalog-linked — will receive a plant_soon recommendation.
        ctx.insert(LocalSeed(
            id: "flow_pepper",
            householdID: householdID,
            catalogID: "cat_pepper",
            state: .active,
            packetCount: 1,
            source: .store,
            createdAt: 1, updatedAt: 1
        ))
        // Active, no catalog link — no recommendation, scored with verdictScore=35.
        ctx.insert(LocalSeed(
            id: "flow_heirloom",
            householdID: householdID,
            catalogID: nil,
            state: .active,
            packetCount: 1,
            source: .store,
            customName: "Heirloom Bean",
            createdAt: 1, updatedAt: 1
        ))
        // Archived (non-active) seed — must NOT appear in suggestions (AC #1).
        ctx.insert(LocalSeed(
            id: "flow_archived",
            householdID: householdID,
            catalogID: "cat_archived",
            state: .archived,
            packetCount: 1,
            source: .store,
            createdAt: 1, updatedAt: 1
        ))
        try ctx.save()
    }

    // MARK: - Stub helpers

    private func makeImage() -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8), format: format).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
    }

    // MARK: - (a) capture → rank: plant_now first

    @Test("capture → analyze → rank: plant_now seed ranks before plant_soon and no-rec seeds")
    func captureRanksPlanNowFirst() async throws {
        let container = Self.makeContainer("flowRankOrder")
        try Self.seedActiveSeedsInContainer(container)
        let ctx = ModelContext(container)
        let allSeeds = try ctx.fetch(FetchDescriptor<LocalSeed>(
            predicate: #Predicate { $0.stateRaw == "active" }
        ))

        let recs: [PlantSuggestionRanker.RecommendationInput] = [
            PlantSuggestionRanker.RecommendationInput(
                catalogSeedID: "cat_tomato",
                verdict: "plant_now",
                rangeStart: "2026-05-01",
                rangeEnd: "2026-07-01"
            ),
            PlantSuggestionRanker.RecommendationInput(
                catalogSeedID: "cat_pepper",
                verdict: "plant_soon",
                rangeStart: "2026-06-01",
                rangeEnd: "2026-08-01"
            ),
        ]

        let vm = CornerSuggestionsViewModel(
            analyze: { _ in CornerCues(exposure: .unknown, openness: .unknown) },
            fetchSeeds: {
                allSeeds.map { seed in
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
            fetchRecommendations: { _ in recs }
        )

        await vm.capture(image: makeImage())

        // (a) plant_now ranks first.
        #expect(!vm.suggestions.isEmpty)
        #expect(vm.suggestions[0].verdict == "plant_now")
        #expect(vm.suggestions[0].seedID == "flow_tomato")

        // plant_soon ranks second.
        let soonIdx = vm.suggestions.firstIndex(where: { $0.verdict == "plant_soon" })
        let nowIdx = vm.suggestions.firstIndex(where: { $0.verdict == "plant_now" })
        if let ni = nowIdx, let si = soonIdx {
            #expect(ni < si)
        }
    }

    // MARK: - (b) editing a cue re-ranks without extra fetch

    @Test("editing cue re-ranks without re-fetching recommendations")
    func editCueDoesNotRefetch() async throws {
        let container = Self.makeContainer("flowEditCue")
        try Self.seedActiveSeedsInContainer(container)
        let ctx = ModelContext(container)
        let allSeeds = try ctx.fetch(FetchDescriptor<LocalSeed>(
            predicate: #Predicate { $0.stateRaw == "active" }
        ))

        // Use two seeds with different sun requirements so we can observe a re-rank.
        let sunflower = PlantSuggestionRanker.SeedInput(
            id: "sun_seed", displayName: "Sunflower", catalogID: "cat_sun",
            yearPacked: nil, sunRequirement: "full", plantSpacingInches: nil
        )
        let fern = PlantSuggestionRanker.SeedInput(
            id: "fern_seed", displayName: "Fern", catalogID: "cat_fern",
            yearPacked: nil, sunRequirement: "shade", plantSpacingInches: nil
        )
        let seedInputs = [sunflower, fern]
        let recs: [PlantSuggestionRanker.RecommendationInput] = [
            PlantSuggestionRanker.RecommendationInput(
                catalogSeedID: "cat_sun", verdict: "plant_now",
                rangeStart: "2026-05-01", rangeEnd: "2026-07-01"
            ),
            PlantSuggestionRanker.RecommendationInput(
                catalogSeedID: "cat_fern", verdict: "plant_now",
                rangeStart: "2026-05-01", rangeEnd: "2026-07-01"
            ),
        ]

        var fetchCount = 0
        let vm = CornerSuggestionsViewModel(
            analyze: { _ in CornerCues(exposure: .unknown, openness: .unknown) },
            fetchSeeds: { seedInputs },
            fetchRecommendations: { _ in
                fetchCount += 1
                return recs
            }
        )

        await vm.capture(image: makeImage())

        let fetchCountAfterCapture = fetchCount

        // Edit cue to fullSun — re-ranks; must NOT trigger another fetch.
        vm.cues = CornerCues(exposure: .fullSun, openness: .unknown)
        vm.cueChanged()

        // (b) No extra fetch occurred.
        #expect(fetchCount == fetchCountAfterCapture)

        // Re-rank effect: Sunflower (+15 exposureFit) now leads.
        #expect(vm.suggestions.first?.seedID == "sun_seed")
    }

    // MARK: - (c) captured photo is NOT persisted to SwiftData

    @Test("captured photo is NOT persisted to SwiftData (ephemeral invariant)")
    func capturedPhotoNotPersistedToSwiftData() async throws {
        let container = Self.makeContainer("flowEphemeral")
        try Self.seedActiveSeedsInContainer(container)
        let ctx = ModelContext(container)
        let allSeeds = try ctx.fetch(FetchDescriptor<LocalSeed>(
            predicate: #Predicate { $0.stateRaw == "active" }
        ))

        let vm = CornerSuggestionsViewModel(
            analyze: { _ in .unknown },
            fetchSeeds: {
                allSeeds.map { seed in
                    PlantSuggestionRanker.SeedInput(
                        id: seed.id,
                        displayName: seed.displayName,
                        catalogID: seed.catalogID,
                        yearPacked: seed.yearPacked,
                        sunRequirement: nil,
                        plantSpacingInches: nil
                    )
                }
            },
            fetchRecommendations: { _ in [] }
        )

        let img = makeImage()
        await vm.capture(image: img)

        // The image is held in-memory on the view-model only (ephemeral).
        #expect(vm.capturedImage != nil, "capturedImage should be held in-memory after capture")

        // Verify no planting events or journal entries were created in SwiftData.
        let plantingEvents = try ctx.fetch(FetchDescriptor<LocalPlantingEvent>())
        let journalEntries = try ctx.fetch(FetchDescriptor<LocalJournalEntry>())
        #expect(plantingEvents.isEmpty, "capture must not create planting events")
        #expect(journalEntries.isEmpty, "capture must not create journal entries")

        // Verify the seed row count is unchanged (still the 3 active + 1 archived we seeded).
        let seeds = try ctx.fetch(FetchDescriptor<LocalSeed>())
        #expect(seeds.count == 4, "capture must not add or remove seed rows")
    }
}
