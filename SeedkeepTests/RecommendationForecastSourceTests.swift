import Foundation
import Synchronization
import Testing
@testable import Seedkeep

// The forecast source is the store's only route to WeatherKit. These tests inject a counting fake, so no test
// reaches the network. They show the injected source is the one the store calls, and that the sample garden's
// empty source leaves each window at its baseline.

@MainActor
@Suite("RecommendationStore forecast source", .serialized)
struct RecommendationForecastSourceTests {
    private let zone7b = HomeClimate(
        zip: "10001", latitude: 40.75074, longitude: -73.99653,
        usdaZone: "7b", avgLastFrost: "04-01", avgFirstFrost: "11-08"
    )

    private let tenderDirect = GrowingInfoSnapshot(
        frost_tolerance: "tender",
        sow_method: "direct",
        days_to_maturity_min: 60,
        days_to_maturity_max: 80
    )

    private func makeStore(
        _ source: @escaping RecommendationStore.ForecastSource
    ) -> (RecommendationStore, AppPreferences, UserDefaults, String) {
        let suiteName = "RecommendationForecastSourceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let prefs = AppPreferences(defaults: defaults)
        return (RecommendationStore(preferences: prefs, forecastSource: source), prefs, defaults, suiteName)
    }

    private func seed() -> LocalSeed {
        LocalSeed(
            id: "seed-1",
            householdID: "garden",
            state: .active,
            packetCount: 1,
            source: .store,
            customName: "Test seed",
            growingInfo: tenderDirect,
            createdAt: 1,
            updatedAt: 1
        )
    }

    @Test("refining asks the injected source once, for the home coordinates")
    func injectedSourceIsCalledOnce() async throws {
        let latitudes = Mutex<[Double]>([])
        let (store, prefs, defaults, suiteName) = makeStore { latitude, _ in
            latitudes.withLock { $0.append(latitude) }
            return []
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        prefs.saveHomeClimate(zone7b)
        let baseline = try #require(store.recommendation(for: seed()))

        let refined = await store.refinedRecommendation(
            baseline: baseline,
            householdLat: zone7b.latitude,
            householdLon: zone7b.longitude,
            frostTolerance: "tender",
            soilTempMaxF: nil
        )

        #expect(latitudes.withLock { $0 } == [40.75])
        // An empty forecast leaves the baseline unchanged.
        #expect(refined?.verdict == baseline.verdict)
        #expect(refined?.dailyScores == baseline.dailyScores)
    }

    @Test("a failing source leaves the baseline window in place")
    func failingSourceKeepsBaseline() async throws {
        struct Offline: Error {}
        let (store, prefs, defaults, suiteName) = makeStore { _, _ in throw Offline() }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        prefs.saveHomeClimate(zone7b)
        let baseline = try #require(store.recommendation(for: seed()))

        let refined = await store.refinedRecommendation(
            baseline: baseline,
            householdLat: zone7b.latitude,
            householdLon: zone7b.longitude,
            frostTolerance: "tender",
            soilTempMaxF: nil
        )

        #expect(refined?.verdict == baseline.verdict)
        #expect(refined?.dailyScores == baseline.dailyScores)
    }

    #if DEBUG
    @Test("the sample garden's forecast is empty and immediate")
    func sampleGardenForecastIsEmpty() async throws {
        let days = try await FixtureMode.forecastSource(zone7b.latitude, zone7b.longitude)
        #expect(days.isEmpty)
    }

    @Test("with the sample garden's source, every window keeps its baseline")
    func sampleGardenWindowsStayAtBaseline() async throws {
        let (store, prefs, defaults, suiteName) = makeStore(FixtureMode.forecastSource)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        prefs.saveHomeClimate(zone7b)
        let baseline = try #require(store.recommendation(for: seed()))

        let refined = await store.refinedRecommendation(
            baseline: baseline,
            householdLat: zone7b.latitude,
            householdLon: zone7b.longitude,
            frostTolerance: "tender",
            soilTempMaxF: nil
        )

        #expect(refined?.verdict == baseline.verdict)
        #expect(refined?.dailyScores == baseline.dailyScores)
        #expect(refined?.weatherNote == nil)
    }
    #endif
}
