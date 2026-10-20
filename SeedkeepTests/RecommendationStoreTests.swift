import Testing
import Foundation
import Observation
@testable import Seedkeep

// The store computes windows on read, from the seed's growing info and the home climate. Nothing here touches the
// network: the store has no client, and the WeatherKit path is covered by `WeatherKitRefinerTests`.

@MainActor
@Suite("RecommendationStore — on-device planting windows", .serialized)
struct RecommendationStoreTests {
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

    private func makeStore() -> (RecommendationStore, AppPreferences, UserDefaults, String) {
        let suiteName = "RecommendationStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let prefs = AppPreferences(defaults: defaults, bundleDefaultURL: URL(string: "https://example.invalid")!)
        return (RecommendationStore(preferences: prefs), prefs, defaults, suiteName)
    }

    private func seed(id: String = "seed-1", growingInfo: GrowingInfoSnapshot?) -> LocalSeed {
        LocalSeed(
            id: id,
            householdID: "garden",
            state: .active,
            packetCount: 1,
            source: .store,
            customName: "Test seed",
            growingInfo: growingInfo,
            createdAt: 1,
            updatedAt: 1
        )
    }

    // MARK: - Home location

    @Test("needsHomeLocation is true until a climate is cached, then false")
    func needsHomeLocationFollowsClimate() {
        let (store, prefs, defaults, suiteName) = makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        #expect(store.needsHomeLocation)

        prefs.saveHomeClimate(zone7b)
        #expect(!store.needsHomeLocation)
    }

    // MARK: - Window

    @Test("no home climate means no window")
    func noClimateNoWindow() {
        let (store, _, defaults, suiteName) = makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        #expect(store.recommendation(for: seed(growingInfo: tenderDirect)) == nil)
    }

    @Test("a seed without growing info has no window")
    func noGrowingInfoNoWindow() {
        let (store, prefs, defaults, suiteName) = makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        prefs.saveHomeClimate(zone7b)
        #expect(store.recommendation(for: seed(growingInfo: nil)) == nil)
    }

    @Test("growing info with no field the engine reads has no window")
    func noRuleInputNoWindow() {
        let (store, prefs, defaults, suiteName) = makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        prefs.saveHomeClimate(zone7b)
        let nameOnly = GrowingInfoSnapshot(scientific_name: "Solanum lycopersicum")
        #expect(store.recommendation(for: seed(growingInfo: nameOnly)) == nil)
    }

    @Test("a seed with growing info and a climate gets the engine's window for today")
    func windowMatchesEngine() throws {
        let (store, prefs, defaults, suiteName) = makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        prefs.saveHomeClimate(zone7b)

        let rec = try #require(store.recommendation(for: seed(growingInfo: tenderDirect)))
        let expected = PlantingEngine.recommend(
            growingInfo: tenderDirect, climate: zone7b, today: PlantingEngine.localToday()
        )
        #expect(rec == expected)
        // A tender crop opens on the zone's last frost, which is April 1 in this climate.
        #expect(rec.rangeStart?.hasSuffix("-04-01") == true)
        #expect(rec.source == "rule")
    }

    @Test("editing the seed's growing info recomputes its window")
    func growingInfoChangeRecomputes() throws {
        let (store, prefs, defaults, suiteName) = makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        prefs.saveHomeClimate(zone7b)
        let item = seed(growingInfo: tenderDirect)
        let first = try #require(store.recommendation(for: item))

        var hardy = tenderDirect
        hardy.frost_tolerance = "hardy"
        item.growingInfo = hardy
        let second = try #require(store.recommendation(for: item))

        #expect(first.rangeStart != second.rangeStart)
        #expect(second == PlantingEngine.recommend(growingInfo: hardy, climate: zone7b, today: PlantingEngine.localToday()))
    }

    @Test("changing the home climate recomputes the window")
    func climateChangeRecomputes() throws {
        let (store, prefs, defaults, suiteName) = makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        prefs.saveHomeClimate(zone7b)
        let item = seed(growingInfo: tenderDirect)
        let first = try #require(store.recommendation(for: item))

        let zone3 = HomeClimate(
            zip: "55001", latitude: 45.0, longitude: -92.9,
            usdaZone: "3b", avgLastFrost: "05-25", avgFirstFrost: "09-08"
        )
        prefs.saveHomeClimate(zone3)
        let second = try #require(store.recommendation(for: item))

        #expect(first.rangeStart != second.rangeStart)
        #expect(second == PlantingEngine.recommend(growingInfo: tenderDirect, climate: zone3, today: PlantingEngine.localToday()))
    }

    @Test("the fallback growing info is used only when the seed has none")
    func fallbackOnlyWhenSeedHasNone() {
        let own = GrowingInfoSnapshot(frost_tolerance: "hardy")
        let fallback = GrowingInfoSnapshot(frost_tolerance: "tender")

        #expect(RecommendationStore.effectiveGrowingInfo(for: seed(growingInfo: own), catalogFallback: fallback) == own)
        #expect(RecommendationStore.effectiveGrowingInfo(for: seed(growingInfo: nil), catalogFallback: fallback) == fallback)
        #expect(RecommendationStore.effectiveGrowingInfo(for: seed(growingInfo: nil)) == nil)
    }

    @Test("an empty snapshot counts as no growing info")
    func emptySnapshotIsNoGrowingInfo() {
        #expect(RecommendationStore.effectiveGrowingInfo(for: seed(growingInfo: GrowingInfoSnapshot())) == nil)
    }

    // MARK: - Rule input

    @Test("each field the engine reads counts as a rule input")
    func ruleInputFields() {
        #expect(!RecommendationStore.hasRuleInput(GrowingInfoSnapshot(scientific_name: "x")))
        #expect(RecommendationStore.hasRuleInput(GrowingInfoSnapshot(frost_tolerance: "hardy")))
        #expect(RecommendationStore.hasRuleInput(GrowingInfoSnapshot(sow_method: "direct")))
        #expect(RecommendationStore.hasRuleInput(GrowingInfoSnapshot(soil_temp_min_f: 60)))
        #expect(RecommendationStore.hasRuleInput(GrowingInfoSnapshot(days_to_maturity_min: 60)))
        #expect(RecommendationStore.hasRuleInput(GrowingInfoSnapshot(days_to_maturity_max: 80)))
        #expect(RecommendationStore.hasRuleInput(GrowingInfoSnapshot(hardiness_zone_min: 3)))
        #expect(RecommendationStore.hasRuleInput(GrowingInfoSnapshot(hardiness_zone_max: 11)))
    }

    // MARK: - Forecast key

    @Test("the forecast key rounds coordinates to two decimals")
    func forecastKeyRounds() {
        let today = (year: 2026, month: 5, day: 20)
        let a = RecommendationStore.forecastKey(latitude: 40.7512, longitude: -73.9949, today: today)
        let b = RecommendationStore.forecastKey(latitude: 40.7499, longitude: -73.9901, today: today)
        #expect(a == b)
        #expect(a.latitude == 40.75)
        #expect(a.longitude == -73.99)
    }

    @Test("a coordinate change or a new local day gives a different forecast key")
    func forecastKeyChanges() {
        let today = (year: 2026, month: 5, day: 20)
        let base = RecommendationStore.forecastKey(latitude: 40.75, longitude: -73.99, today: today)
        let moved = RecommendationStore.forecastKey(latitude: 40.80, longitude: -73.99, today: today)
        let nextDay = RecommendationStore.forecastKey(latitude: 40.75, longitude: -73.99, today: (2026, 5, 21))
        #expect(base != moved)
        #expect(base != nextDay)
    }

    // MARK: - Memo and day refresh (N2 review O10)

    @Test("a seed with nothing to plan from is memoized as no window, and gaining growing info recomputes")
    func emptyMemoRecomputesOnChange() throws {
        let (store, prefs, defaults, suiteName) = makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        prefs.saveHomeClimate(zone7b)
        let item = seed(growingInfo: nil)
        #expect(store.recommendation(for: item) == nil)
        #expect(store.recommendation(for: item) == nil)

        item.growingInfo = tenderDirect

        #expect(try #require(store.recommendation(for: item)).source == "rule")
    }

    @Test("refreshToday on the same local day changes nothing observable; a new day does")
    func refreshTodayOnlyOnChange() {
        let (store, _, defaults, suiteName) = makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let now = Date()

        let sameDay = ChangeFlag()
        withObservationTracking { _ = store.today } onChange: { sameDay.fired = true }
        store.refreshToday(now: now)
        #expect(!sameDay.fired)

        let nextDay = ChangeFlag()
        withObservationTracking { _ = store.today } onChange: { nextDay.fired = true }
        store.refreshToday(now: now.addingTimeInterval(3 * 24 * 60 * 60))
        #expect(nextDay.fired)
    }
}

/// Records an observation change from `withObservationTracking`'s Sendable callback.
private final class ChangeFlag: @unchecked Sendable {
    var fired = false
}
