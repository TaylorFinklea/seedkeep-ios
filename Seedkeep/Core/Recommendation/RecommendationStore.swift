import Foundation

/// Computes each seed's planting window on the device, from its growing info and the home climate, and applies
/// `WeatherKitRefiner` for a locally refined window. Nothing here reaches the network except the best-effort
/// WeatherKit forecast.
///
/// A window is computed on read and memoized per seed. The memo key is the seed's growing info, the home
/// climate and the local date, so a change to any of them recomputes it.
@MainActor
@Observable
public final class RecommendationStore {
    private let preferences: AppPreferences

    /// The local calendar day the windows are computed for. It is observed, so a view that shows a window re-renders
    /// when the day or the time zone changes, instead of holding yesterday's advice.
    private(set) var today: (year: Int, month: Int, day: Int) = PlantingEngine.localToday()

    /// Day-change observers. They live as long as the store.
    @ObservationIgnored private var dayObservers: [NSObjectProtocol] = []

    // MARK: - In-memory caches (not observed; a view body may write them)

    /// The last computed window for each seed, with the inputs it was computed from.
    @ObservationIgnored private var memo: [String: Memo] = [:]

    /// The last forecast, the key it was fetched for, and when it was fetched.
    @ObservationIgnored private var cachedForecast: [ForecastDay] = []
    @ObservationIgnored private var forecastKey: ForecastKey?
    @ObservationIgnored private var forecastFetchedAt: Date?

    /// Six-hour TTL for the in-memory forecast.
    private static let forecastTTL: TimeInterval = 6 * 60 * 60

    // MARK: - Init

    public init(preferences: AppPreferences) {
        self.preferences = preferences
        // Midnight, a time-zone change, and returning to the app can each change the day.
        let names: [Notification.Name] = [
            .NSCalendarDayChanged,
            .NSSystemTimeZoneDidChange,
            PlatformLifecycle.willEnterForeground,
        ]
        for name in names {
            dayObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.refreshToday() }
            })
        }
    }

    /// Assigns only on a real change, so a foreground return on the same day does not re-render every window.
    func refreshToday(now: Date = Date(), timeZone: TimeZone = .current) {
        let current = PlantingEngine.localToday(now: now, timeZone: timeZone)
        guard current != today else { return }
        today = current
    }

    // MARK: - Home location

    /// True until a home ZIP has its climate cached.
    var needsHomeLocation: Bool {
        preferences.homeClimate == nil
    }

    // MARK: - Planting window

    /// The seed's planting window at the home location, as of today. nil when there is no home climate, or when the
    /// seed's growing info has none of the fields the engine reads.
    func recommendation(for seed: LocalSeed) -> PlantingRecommendation? {
        guard let climate = preferences.homeClimate else { return nil }

        // The memo is checked before the growing info is decoded, so a list of seeds re-renders without
        // re-decoding every seed's JSON.
        let day = today
        let inputs = MemoInputs(
            growingInfoJSON: seed.growingInfoJSON,
            climate: climate,
            day: "\(day.year)-\(day.month)-\(day.day)"
        )
        if let memo = memo[seed.id], memo.inputs == inputs {
            return memo.value
        }
        let value: PlantingRecommendation?
        if let info = Self.effectiveGrowingInfo(for: seed), Self.hasRuleInput(info) {
            value = PlantingEngine.recommend(growingInfo: info, climate: climate, today: day)
        } else {
            value = nil
        }
        memo[seed.id] = Memo(inputs: inputs, value: value)
        return value
    }

    /// The inputs a refined window depends on: the seed, its growing info, the whole home climate (so a launch
    /// backfill of the frost dates counts), and the day. A change to any of them recomputes the refinement.
    func refinementKey(for seed: LocalSeed) -> String {
        [
            seed.id,
            seed.growingInfoJSON ?? "",
            String(describing: preferences.homeClimate),
            "\(today.year)-\(today.month)-\(today.day)",
        ].joined(separator: "|")
    }

    /// The growing info the planting engine reads for a seed: the seed's own snapshot when it has data, else the
    /// fallback (a loaded catalog row, when there is one). nil when neither has data.
    static func effectiveGrowingInfo(for seed: LocalSeed, catalogFallback: GrowingInfoSnapshot? = nil) -> GrowingInfoSnapshot? {
        if let snap = seed.growingInfo, snap.hasAny { return snap }
        return catalogFallback
    }

    /// True when the growing info has a field the engine reads: the frost tolerance, sow method, soil temperature,
    /// maturity or hardiness zone. Without one there is nothing to plan from.
    static func hasRuleInput(_ info: GrowingInfoSnapshot) -> Bool {
        info.frost_tolerance != nil
            || info.sow_method != nil
            || info.soil_temp_min_f != nil
            || info.days_to_maturity_min != nil
            || info.days_to_maturity_max != nil
            || info.hardiness_zone_min != nil
            || info.hardiness_zone_max != nil
    }

    // MARK: - WeatherKit-refined window

    /// Blends `baseline` with a 10-day local WeatherKit forecast. Returns nil when the forecast was fetched for a
    /// location or day that is no longer current. Never throws: on a WeatherKit failure the unrefined baseline is
    /// used.
    func refinedRecommendation(
        baseline: PlantingRecommendation,
        householdLat: Double,
        householdLon: Double,
        frostTolerance: String?,
        soilTempMaxF: Int?
    ) async -> RefinedRecommendation? {
        let key = Self.forecastKey(latitude: householdLat, longitude: householdLon, today: today)
        guard let forecast = await ensureForecast(for: key) else { return nil }

        return WeatherKitRefiner.refine(
            verdict: baseline.verdict,
            scores: baseline.dailyScores,
            anchorDate: baseline.scoresAnchorDate,
            frostTolerance: frostTolerance,
            soilTempMaxF: soilTempMaxF,
            forecast: forecast
        )
    }

    /// The key that a forecast is cached under: the coordinates rounded to two decimals, and the local day.
    static func forecastKey(
        latitude: Double,
        longitude: Double,
        today: (year: Int, month: Int, day: Int)
    ) -> ForecastKey {
        ForecastKey(
            latitude: roundedCoordinate(latitude),
            longitude: roundedCoordinate(longitude),
            day: "\(today.year)-\(today.month)-\(today.day)"
        )
    }

    private static func roundedCoordinate(_ value: Double) -> Double {
        (value * 100).rounded() / 100
    }

    /// The key for the home location and today, or nil while the location is not cached.
    private func currentForecastKey() -> ForecastKey? {
        guard let latitude = preferences.cachedLatitude, let longitude = preferences.cachedLongitude else { return nil }
        return Self.forecastKey(latitude: latitude, longitude: longitude, today: today)
    }

    /// The forecast for `key`: the cached one while it is fresh and was fetched for the same key, else a new fetch.
    /// nil when the location or the day changed while the fetch was in flight, so that stale result is dropped.
    private func ensureForecast(for key: ForecastKey) async -> [ForecastDay]? {
        let now = Date()
        if forecastKey == key,
           let fetchedAt = forecastFetchedAt,
           now.timeIntervalSince(fetchedAt) < Self.forecastTTL,
           !cachedForecast.isEmpty {
            return cachedForecast
        }

        do {
            let fresh = try await WeatherKitRefiner.fetchForecast(latitude: key.latitude, longitude: key.longitude)
            guard currentForecastKey() == key else { return nil }
            cachedForecast = fresh
            forecastKey = key
            forecastFetchedAt = now
            return fresh
        } catch {
            print("[RecommendationStore] WeatherKit fetch error: \(error.localizedDescription)")
            // The location or day moved on while the fetch ran, so there is nothing current to fall back to.
            guard currentForecastKey() == key else { return nil }
            // An empty forecast leaves the baseline unchanged. The old forecast is kept only for the same key.
            return forecastKey == key ? cachedForecast : []
        }
    }

    // MARK: - Memo

    /// What a memoized window was computed from. Any difference recomputes it.
    private struct MemoInputs: Equatable {
        let growingInfoJSON: String?
        let climate: HomeClimate
        let day: String
    }

    private struct Memo {
        let inputs: MemoInputs
        /// nil when the growing info has nothing the engine reads.
        let value: PlantingRecommendation?
    }

    /// Keys a cached forecast: the coordinates to two decimals and the local day.
    struct ForecastKey: Equatable {
        let latitude: Double
        let longitude: Double
        let day: String
    }
}
