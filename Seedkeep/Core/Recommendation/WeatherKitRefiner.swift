import Foundation
import WeatherKit
import CoreLocation

// MARK: - Public types

struct RefinedRecommendation {
    var verdict: String
    var dailyScores: [Double]
    var scoresAnchorDate: String
    var weatherNote: String?
}

struct ForecastDay: Sendable {
    let date: Date
    let lowTempF: Double
    let highTempF: Double
    let precipitationInches: Double
}

// MARK: - WeatherKitRefiner

struct WeatherKitRefiner {

    // MARK: Thresholds (named constants)

    /// Temperature (°F) at which a tender plant risks frost damage.
    private static let FROST_LOW_F: Double = 32

    /// Daily precipitation (inches) considered heavy enough to delay planting.
    private static let HEAVY_RAIN_INCHES: Double = 0.5

    /// Consecutive days above `soilTempMaxF` that constitute a sustained heat event.
    private static let SUSTAINED_HEAT_DAYS: Int = 3

    // MARK: Verdict ordering (toward "wait" means moving right)
    // too_late ← late ← plant_now ← plant_soon ← too_early
    // Shifting "toward wait" means: plant_now → plant_soon, plant_soon → too_early
    private static let verdictOrder: [String] = [
        "too_late", "late", "plant_now", "plant_soon", "too_early"
    ]

    // MARK: - Public API

    /// Pure: combines server-computed baseline with a 10-day local forecast.
    /// No I/O. Returns the baseline unchanged when `forecast` is empty.
    static func refine(
        verdict: String,
        scores: [Double],
        anchorDate: String,
        frostTolerance: String?,
        soilTempMaxF: Int?,
        forecast: [ForecastDay]
    ) -> RefinedRecommendation {
        guard !forecast.isEmpty else {
            return RefinedRecommendation(
                verdict: verdict,
                dailyScores: scores,
                scoresAnchorDate: anchorDate,
                weatherNote: nil
            )
        }

        var currentVerdict = verdict
        var currentScores = scores
        var adverseEventFired = false

        let anchor = Self.parseAnchorDate(anchorDate)

        // -- Rule 1: Frost rule ---------------------------------------------------
        // Only applies to tender varieties (not hardy, semi-hardy, etc.)
        if frostTolerance == "tender" {
            if let firstFrostIndex = forecast.firstIndex(where: { $0.lowTempF < FROST_LOW_F }) {
                adverseEventFired = true
                // Shift verdict one step toward "wait"
                currentVerdict = Self.shiftVerdictTowardWait(currentVerdict)
                // Zero scores for all days at or before the frost day
                let frostDay = forecast[firstFrostIndex].date
                for i in currentScores.indices {
                    let dayDate = Self.dateForScoreIndex(i, anchor: anchor)
                    if dayDate <= frostDay {
                        currentScores[i] = 0.0
                    }
                }
            }
        }

        // -- Rule 2: Heavy rain rule -----------------------------------------------
        // For each day with precipitation >= HEAVY_RAIN_INCHES, zero that day +
        // the next 2 days in the scores array.
        for day in forecast where day.precipitationInches >= HEAVY_RAIN_INCHES {
            adverseEventFired = true
            let rainIndex = Self.scoreIndex(for: day.date, anchor: anchor)
            let start = max(0, rainIndex)
            let end = min(currentScores.count - 1, rainIndex + 2)
            // When the rain day is well before the anchor (rainIndex ≤ -3),
            // end can be less than start — guard prevents a range-trap crash.
            guard start <= end else { continue }
            guard start < currentScores.count else { continue }
            for i in start...end {
                currentScores[i] = 0.0
            }
        }

        // -- Rule 3: Sustained heat rule -------------------------------------------
        // 3+ consecutive forecast days with highTempF well above soilTempMaxF
        // → zero scores starting from the first day of the streak.
        if let maxTemp = soilTempMaxF {
            let hotDays = forecast.map { $0.highTempF > Double(maxTemp) }
            var streakStart: Int? = nil
            var streakLength = 0
            for (i, isHot) in hotDays.enumerated() {
                if isHot {
                    if streakLength == 0 { streakStart = i }
                    streakLength += 1
                    if streakLength >= SUSTAINED_HEAT_DAYS, let start = streakStart {
                        adverseEventFired = true
                        // Zero scores from the start of this heat streak onward
                        let scoreStart = Self.scoreIndex(for: forecast[start].date, anchor: anchor)
                        let clampedStart = max(0, scoreStart)
                        if clampedStart < currentScores.count {
                            for j in clampedStart..<currentScores.count {
                                currentScores[j] = 0.0
                            }
                        }
                        // Once we've applied the rule for a streak, stop scanning
                        break
                    }
                } else {
                    streakStart = nil
                    streakLength = 0
                }
            }
        }

        // -- Rule 4: Ideal-stretch rule --------------------------------------------
        // If no adverse event fired, the 10-day window is benign.
        let weatherNote: String? = adverseEventFired ? nil : "Next 10 days look ideal."

        return RefinedRecommendation(
            verdict: currentVerdict,
            dailyScores: currentScores,
            scoresAnchorDate: anchorDate,
            weatherNote: weatherNote
        )
    }

    /// Thin WeatherKit fetch — returns the daily forecast for a coordinate.
    static func fetchForecast(latitude: Double, longitude: Double) async throws -> [ForecastDay] {
        let weather = try await WeatherService.shared.weather(
            for: CLLocation(latitude: latitude, longitude: longitude))
        return weather.dailyForecast.forecast.prefix(10).map { day in
            ForecastDay(
                date: day.date,
                lowTempF: day.lowTemperature.converted(to: .fahrenheit).value,
                highTempF: day.highTemperature.converted(to: .fahrenheit).value,
                precipitationInches: day.precipitationAmount.converted(to: .inches).value
            )
        }
    }

    // MARK: - Private helpers

    /// Shift a verdict one step toward "wait" (toward `too_early` from `plant_now`).
    /// Returns the verdict unchanged if it is already at the extremes
    /// (`too_early`, `too_late`, `late`) or unknown.
    private static func shiftVerdictTowardWait(_ verdict: String) -> String {
        // Toward-wait direction: plant_now → plant_soon → too_early
        guard let idx = verdictOrder.firstIndex(of: verdict) else { return verdict }
        let nextIdx = idx + 1
        guard nextIdx < verdictOrder.count else { return verdict }
        return verdictOrder[nextIdx]
    }

    /// Parse "YYYY-MM-DD" anchor string into a UTC Date at midnight.
    private static func parseAnchorDate(_ anchor: String) -> Date {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withFullDate]
        fmt.timeZone = TimeZone(identifier: "UTC")!
        return fmt.date(from: anchor) ?? Date()
    }

    /// Return the Date for a given score-array index relative to the anchor.
    private static func dateForScoreIndex(_ index: Int, anchor: Date) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(byAdding: .day, value: index, to: anchor)!
    }

    /// Return the score-array index for a given forecast Date, measured in full
    /// days from the anchor.  May be negative or beyond the array end — callers
    /// must clamp before indexing.
    private static func scoreIndex(for date: Date, anchor: Date) -> Int {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        // Normalise both dates to UTC midnight to avoid fractional-day issues
        let anchorMidnight = cal.startOfDay(for: anchor)
        let dateMidnight = cal.startOfDay(for: date)
        return cal.dateComponents([.day], from: anchorMidnight, to: dateMidnight).day ?? 0
    }
}
