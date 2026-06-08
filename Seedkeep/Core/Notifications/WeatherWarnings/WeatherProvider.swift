import Foundation
import SwiftData
import WeatherKit
import CoreLocation

/// Phase 4C — abstraction over WeatherKit fetch + cache + validation.
///
/// Production impl is `WeatherKitProvider` (actor below); tests inject a
/// `MockWeatherProvider`. Returns one of three discriminated results so
/// callers can render distinct UI states (fresh, stale-but-usable, failed).
protocol WeatherProvider: Sendable {
    /// Fetch a 10-day forecast + 8-day historical for `(latitude, longitude)`.
    /// `generation` is the coord generation captured at call time —
    /// providers compare it against their stored snapshot's generation
    /// before treating a cached snapshot as "still the same location."
    func fetch(latitude: Double, longitude: Double, generation: Int) async -> ForecastResult

    /// Bump the provider's stored coord generation. Called by the
    /// `WeatherWarningsService` on `.locationChange` so a stale-cache
    /// fallback after the bump can't accidentally re-use the old
    /// location's forecast.
    func bumpGeneration(to generation: Int) async

    /// The most recent persisted `ForecastSnapshot`, if any. Used when
    /// the per-day fetch cap is exceeded — service forces this path
    /// rather than burning a real WeatherKit call.
    func cachedSnapshot() async -> ForecastSnapshot?
}

/// Discriminated outcome of a single forecast fetch. `.fresh` is the
/// happy path; `.stale` is the "WeatherKit unavailable but a recent
/// cached snapshot survives at the same coords"; `.failed` is no usable
/// data — pending notifications must NOT be cleared on a `.failed`.
enum ForecastResult: Sendable {
    case fresh(
        forecast: [DailyWeather],
        observed: [ObservedDay],
        homeTimeZone: TimeZone,
        fetchedAt: Date
    )
    case stale(
        forecast: [DailyWeather],
        observed: [ObservedDay],
        homeTimeZone: TimeZone,
        ageSeconds: TimeInterval
    )
    case failed(message: String, isUnauthorized: Bool)
}

/// Plain value snapshot of a single forecast fetch. Persisted by
/// `LocalForecastSnapshot` (forecast/observed go to its
/// `forecastJSON` / `observedJSON` string columns) so a cold-launch
/// can return `.stale` without re-hitting WeatherKit.
struct ForecastSnapshot: Sendable {
    let coordGeneration: Int
    let latitude: Double
    let longitude: Double
    let homeTimeZoneIdentifier: String
    let fetchedAt: Date
    let forecast: [DailyWeather]
    let observed: [ObservedDay]
}

// MARK: - WeatherKitProvider

/// Real `WeatherProvider` backed by `WeatherService.shared`. One bundled
/// `weather(for:including:)` request fetches both the forecast (10 days
/// ahead) and the historical observed (8 days back) so we burn exactly
/// one WeatherKit quota credit per refresh.
///
/// Every `DayWeather` is validated at this boundary — NaN, negative
/// precip, dates outside `[now-1d, now+14d]`, and temperatures outside
/// `[-50°F, 130°F]` (a unit-conversion bug signature) are dropped before
/// they can reach the pure evaluators. Snow is stripped via the standard
/// 0.1 density factor so `rainMM` is liquid-rain-only — the
/// `WaterEvaluator` would otherwise treat a 50mm snowstorm as a deep
/// soaking rain.
actor WeatherKitProvider: WeatherProvider {

    private let container: ModelContainer
    private let weatherService: WeatherService

    init(container: ModelContainer) {
        self.container = container
        self.weatherService = WeatherService.shared
    }

    func bumpGeneration(to generation: Int) async {
        // Coord generation is persisted on `LocalForecastSnapshot` —
        // there's nothing actor-local to update. Clearing the cache
        // ensures a `.stale` fallback after the bump can't reuse the
        // prior location's forecast (the stale-window match would
        // mistakenly pass on a generation mismatch we'd no longer
        // detect post-bump).
        _ = generation
        await clearPersistedSnapshot()
    }

    func cachedSnapshot() async -> ForecastSnapshot? {
        await loadPersistedSnapshot()
    }

    func fetch(
        latitude: Double,
        longitude: Double,
        generation: Int
    ) async -> ForecastResult {
        let location = CLLocation(latitude: latitude, longitude: longitude)
        let now = Date()
        let historicalStart = now.addingTimeInterval(-8 * 86_400)
        let historicalEnd = now

        do {
            // One bundled request for forecast + historical.
            let (dailyForecast, dailyHistorical) = try await weatherService.weather(
                for: location,
                including: .daily,
                            .daily(startDate: historicalStart, endDate: historicalEnd)
            )

            // Spec §4: "homeTimeZone from forecast.metadata.timeZone
            // (when available; else default to TimeZone.current)".
            // `WeatherMetadata` does not currently surface a TimeZone —
            // the home-location coords land in the user's local TZ
            // anyway, so `TimeZone.current` is the right fallback.
            // Future WeatherKit revisions may add the field; the
            // service-level reconciliation can swap this in then.
            let homeTimeZone = TimeZone.current

            let validForecast = Self.validateForecast(
                dailyForecast.forecast,
                now: now
            )
            let validObserved = Self.validateObserved(
                dailyHistorical.forecast,
                now: now
            )

            let snapshot = ForecastSnapshot(
                coordGeneration: generation,
                latitude: latitude,
                longitude: longitude,
                homeTimeZoneIdentifier: homeTimeZone.identifier,
                fetchedAt: now,
                forecast: validForecast,
                observed: validObserved
            )
            await persistSnapshot(snapshot)

            return .fresh(
                forecast: validForecast,
                observed: validObserved,
                homeTimeZone: homeTimeZone,
                fetchedAt: now
            )
        } catch {
            // Try to fall back to a cached snapshot. The fallback is
            // only honored if the snapshot is younger than 72h AND
            // covers the same `coordGeneration` — otherwise the
            // cached data is for a stale location and would mislead.
            let isUnauthorized = Self.isPermissionDenied(error)
            if isUnauthorized {
                return .failed(message: Self.errorMessage(error), isUnauthorized: true)
            }
            guard let cached = await loadPersistedSnapshot() else {
                return .failed(message: Self.errorMessage(error), isUnauthorized: false)
            }
            let age = now.timeIntervalSince(cached.fetchedAt)
            let staleWindow: TimeInterval = 72 * 3_600
            guard age >= 0, age < staleWindow,
                  cached.coordGeneration == generation
            else {
                return .failed(message: Self.errorMessage(error), isUnauthorized: false)
            }
            guard let tz = TimeZone(identifier: cached.homeTimeZoneIdentifier) else {
                return .failed(message: Self.errorMessage(error), isUnauthorized: false)
            }
            return .stale(
                forecast: cached.forecast,
                observed: cached.observed,
                homeTimeZone: tz,
                ageSeconds: age
            )
        }
    }

    // MARK: - Validation

    /// Drop NaN / negative-precip / out-of-window / unit-conversion-bug
    /// days from the forecast at the boundary. Anything that passes
    /// here is safe for the pure evaluators to consume blindly.
    private static func validateForecast(
        _ days: [DayWeather],
        now: Date
    ) -> [DailyWeather] {
        let lowerBound = now.addingTimeInterval(-1 * 86_400)
        let upperBound = now.addingTimeInterval(14 * 86_400)
        return days.compactMap { (day: DayWeather) -> DailyWeather? in
            guard day.date >= lowerBound, day.date <= upperBound else { return nil }

            let lowF = day.lowTemperature.converted(to: .fahrenheit).value
            let highF = day.highTemperature.converted(to: .fahrenheit).value
            // WeatherKit's `DayWeather` does NOT surface an apparent
            // (feels-like) temperature — that lives on `HourWeather` /
            // `CurrentWeather` only. The spec's `apparentTemperature
            // .maximum` reference doesn't compile against the real API.
            // Phase 4C ships using the raw high as the apparent high;
            // the heat-dome path keys off `heatRawHighF` (95°F)
            // anyway, and the `.extreme` path (`heatApparentHighF`
            // 100°F) is a stricter trigger that still fires when
            // genuine danger arrives. A follow-up can roll up the
            // hourly forecast for a true apparent-high if KC humidity
            // proves too miscalibrated.
            let apparentHighF = highF
            let precipMM = day.precipitationAmount.converted(to: .millimeters).value
            let snowMM = day.snowfallAmount.converted(to: .millimeters).value
            // DayWeather doesn't surface a daily humidity scalar — that
            // lives on HourWeather. Persist 0.0 so the evaluators have
            // a deterministic value (none of them gate on humidity in
            // Phase 4C).
            let humidity = 0.0
            let windMPH = day.wind.speed
                .converted(to: .milesPerHour).value
            let precipChance = day.precipitationChance

            guard lowF.isFinite, highF.isFinite, apparentHighF.isFinite,
                  precipMM.isFinite, snowMM.isFinite,
                  humidity.isFinite, windMPH.isFinite, precipChance.isFinite
            else { return nil }
            guard precipMM >= 0, snowMM >= 0 else { return nil }
            guard lowF >= -50, lowF <= 130 else { return nil }
            guard highF >= -50, highF <= 130 else { return nil }
            guard apparentHighF >= -50, apparentHighF <= 130 else { return nil }

            // Strip melted-snow contribution from precip: 1mm snow ≈ 0.1mm water.
            let rainMM = max(0, precipMM - (snowMM * 0.1))

            return DailyWeather(
                date: day.date,
                lowF: lowF,
                highF: highF,
                precipMM: precipMM,
                rainMM: rainMM,
                apparentHighF: apparentHighF,
                precipitationChance: precipChance,
                humidity: humidity,
                windMPH: windMPH
            )
        }
    }

    /// Historical-observed boundary validation. Mirrors forecast rules
    /// but only emits the fields `WaterEvaluator.past` needs.
    private static func validateObserved(
        _ days: [DayWeather],
        now: Date
    ) -> [ObservedDay] {
        let lowerBound = now.addingTimeInterval(-30 * 86_400)
        let upperBound = now
        return days.compactMap { (day: DayWeather) -> ObservedDay? in
            guard day.date >= lowerBound, day.date <= upperBound else { return nil }

            let highF = day.highTemperature.converted(to: .fahrenheit).value
            let precipMM = day.precipitationAmount.converted(to: .millimeters).value
            let snowMM = day.snowfallAmount.converted(to: .millimeters).value
            // See `validateForecast` for why this is hardcoded; daily
            // humidity is not surfaced on `DayWeather`.
            let humidity = 0.0
            let windMPH = day.wind.speed
                .converted(to: .milesPerHour).value

            guard highF.isFinite, precipMM.isFinite, snowMM.isFinite,
                  windMPH.isFinite
            else { return nil }
            guard precipMM >= 0, snowMM >= 0 else { return nil }
            guard highF >= -50, highF <= 130 else { return nil }

            let rainMM = max(0, precipMM - (snowMM * 0.1))
            return ObservedDay(
                date: day.date,
                rainMM: rainMM,
                highF: highF,
                humidity: humidity,
                windMPH: windMPH
            )
        }
    }

    // MARK: - Error classification

    private static func isPermissionDenied(_ error: Error) -> Bool {
        guard let wkError = error as? WeatherError else { return false }
        if case .permissionDenied = wkError { return true }
        return false
    }

    private static func errorMessage(_ error: Error) -> String {
        if let wkError = error as? WeatherError {
            return String(describing: wkError)
        }
        return error.localizedDescription
    }

    // MARK: - Persistence (LocalForecastSnapshot singleton)

    /// Coords + extra-field side-channel persisted alongside the
    /// `LocalForecastSnapshot`'s JSON columns. The model file owns the
    /// canonical fields (forecastJSON, observedJSON, coordGeneration,
    /// sawClockAt, sawTimeZoneIdentifier); lat/lon/fetchedAt live here
    /// as an actor-local memo because the v1 model doesn't carry them
    /// yet. Lost on app kill — acceptable since a `.stale` fallback
    /// without lat/lon just falls through to `.failed`.
    private var lastFetchedAt: Date?
    private var lastLatitude: Double?
    private var lastLongitude: Double?

    /// Load the singleton `LocalForecastSnapshot` row and rebuild a
    /// `ForecastSnapshot` from its persisted JSON columns + actor-local
    /// memo for the fields the model doesn't yet carry. Returns nil on
    /// first launch (no row), empty JSON, missing memo data, or
    /// unparseable timezone identifier.
    private func loadPersistedSnapshot() async -> ForecastSnapshot? {
        struct PersistedFields: Sendable {
            let forecastJSON: String
            let observedJSON: String
            let coordGeneration: Int
            let homeTimeZoneIdentifier: String?
        }

        let container = self.container
        let fields = await MainActor.run { () -> PersistedFields? in
            let context = ModelContext(container)
            let descriptor = FetchDescriptor<LocalForecastSnapshot>()
            guard let row = (try? context.fetch(descriptor))?.first
            else { return nil }
            return PersistedFields(
                forecastJSON: row.forecastJSON,
                observedJSON: row.observedJSON,
                coordGeneration: row.coordGeneration,
                homeTimeZoneIdentifier: row.sawTimeZoneIdentifier
            )
        }
        guard let fields,
              !fields.forecastJSON.isEmpty,
              let tzID = fields.homeTimeZoneIdentifier,
              let fetchedAt = lastFetchedAt,
              let latitude = lastLatitude,
              let longitude = lastLongitude,
              let forecastData = fields.forecastJSON.data(using: .utf8),
              let observedData = fields.observedJSON.data(using: .utf8),
              let forecast = try? Self.jsonDecoder.decode(
                [DailyWeather].self, from: forecastData),
              let observed = try? Self.jsonDecoder.decode(
                [ObservedDay].self, from: observedData)
        else { return nil }
        return ForecastSnapshot(
            coordGeneration: fields.coordGeneration,
            latitude: latitude,
            longitude: longitude,
            homeTimeZoneIdentifier: tzID,
            fetchedAt: fetchedAt,
            forecast: forecast,
            observed: observed
        )
    }

    /// Write the snapshot to the singleton `LocalForecastSnapshot`
    /// row, creating it if necessary. Only touches the columns this
    /// provider owns (forecastJSON, observedJSON, coordGeneration,
    /// sawClockAt, sawTimeZoneIdentifier) — the `WeatherWarningsService`
    /// updates last*FireDate, lastAuthStatusRaw, outcomeRaw on its own
    /// MainActor hop without racing this one.
    private func persistSnapshot(_ snapshot: ForecastSnapshot) async {
        // Memo the fields the v1 model doesn't carry.
        lastFetchedAt = snapshot.fetchedAt
        lastLatitude = snapshot.latitude
        lastLongitude = snapshot.longitude

        // Encoding can fail if a Codable conformance is missing —
        // fall through silently rather than crashing, the next refresh
        // will retry.
        guard let forecastData = try? Self.jsonEncoder.encode(snapshot.forecast),
              let observedData = try? Self.jsonEncoder.encode(snapshot.observed),
              let forecastJSON = String(data: forecastData, encoding: .utf8),
              let observedJSON = String(data: observedData, encoding: .utf8)
        else { return }

        let container = self.container
        let coordGeneration = snapshot.coordGeneration
        let tzID = snapshot.homeTimeZoneIdentifier
        let sawClockAt = snapshot.fetchedAt

        await MainActor.run {
            let context = ModelContext(container)
            let descriptor = FetchDescriptor<LocalForecastSnapshot>()
            let row: LocalForecastSnapshot
            if let existing = (try? context.fetch(descriptor))?.first {
                row = existing
            } else {
                row = LocalForecastSnapshot()
                context.insert(row)
            }
            row.forecastJSON = forecastJSON
            row.observedJSON = observedJSON
            row.coordGeneration = coordGeneration
            row.sawTimeZoneIdentifier = tzID
            row.sawClockAt = sawClockAt
            try? context.save()
        }
    }

    private func clearPersistedSnapshot() async {
        lastFetchedAt = nil
        lastLatitude = nil
        lastLongitude = nil
        let container = self.container
        await MainActor.run {
            let context = ModelContext(container)
            let descriptor = FetchDescriptor<LocalForecastSnapshot>()
            if let row = (try? context.fetch(descriptor))?.first {
                row.forecastJSON = ""
                row.observedJSON = ""
                try? context.save()
            }
        }
    }

    // MARK: - JSON coders

    private static let jsonEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let jsonDecoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

// MARK: - Codable conformance for evaluator inputs

// `LocalForecastSnapshot` stores forecast/observed as JSON-encoded
// strings (per its model file's documentation), which requires
// `DailyWeather` + `ObservedDay` to round-trip through Codable.
// Evaluators.swift declares them as `Sendable, Equatable` only and
// Swift's synthesized Codable only works in the type's defining file —
// hence these manual implementations. Field order matches the
// declarations in Evaluators.swift; keep them in sync if either side
// gains a column.
extension DailyWeather: Codable {
    private enum CodingKeys: String, CodingKey {
        case date, lowF, highF, precipMM, rainMM,
             apparentHighF, precipitationChance, humidity, windMPH
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            date: try c.decode(Date.self, forKey: .date),
            lowF: try c.decode(Double.self, forKey: .lowF),
            highF: try c.decode(Double.self, forKey: .highF),
            precipMM: try c.decode(Double.self, forKey: .precipMM),
            rainMM: try c.decode(Double.self, forKey: .rainMM),
            apparentHighF: try c.decode(Double.self, forKey: .apparentHighF),
            precipitationChance: try c.decode(Double.self, forKey: .precipitationChance),
            humidity: try c.decode(Double.self, forKey: .humidity),
            windMPH: try c.decode(Double.self, forKey: .windMPH)
        )
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(date, forKey: .date)
        try c.encode(lowF, forKey: .lowF)
        try c.encode(highF, forKey: .highF)
        try c.encode(precipMM, forKey: .precipMM)
        try c.encode(rainMM, forKey: .rainMM)
        try c.encode(apparentHighF, forKey: .apparentHighF)
        try c.encode(precipitationChance, forKey: .precipitationChance)
        try c.encode(humidity, forKey: .humidity)
        try c.encode(windMPH, forKey: .windMPH)
    }
}

extension ObservedDay: Codable {
    private enum CodingKeys: String, CodingKey {
        case date, rainMM, highF, humidity, windMPH
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            date: try c.decode(Date.self, forKey: .date),
            rainMM: try c.decode(Double.self, forKey: .rainMM),
            highF: try c.decode(Double.self, forKey: .highF),
            humidity: try c.decode(Double.self, forKey: .humidity),
            windMPH: try c.decode(Double.self, forKey: .windMPH)
        )
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(date, forKey: .date)
        try c.encode(rainMM, forKey: .rainMM)
        try c.encode(highF, forKey: .highF)
        try c.encode(humidity, forKey: .humidity)
        try c.encode(windMPH, forKey: .windMPH)
    }
}
