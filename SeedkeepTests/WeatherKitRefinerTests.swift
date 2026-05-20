import Testing
import Foundation
@testable import Seedkeep

// MARK: - Helpers

/// Build a Date that is `dayOffset` days from an anchor string "YYYY-MM-DD".
private func dateFromAnchor(_ anchor: String, offsetDays dayOffset: Int) -> Date {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    let fmt = ISO8601DateFormatter()
    fmt.formatOptions = [.withFullDate]
    fmt.timeZone = TimeZone(identifier: "UTC")!
    let base = fmt.date(from: anchor)!
    return cal.date(byAdding: .day, value: dayOffset, to: base)!
}

/// Build a neutral (non-adverse) ForecastDay for the given offset.
private func neutralDay(anchor: String, offset: Int) -> ForecastDay {
    ForecastDay(
        date: dateFromAnchor(anchor, offsetDays: offset),
        lowTempF: 50,
        highTempF: 72,
        precipitationInches: 0.0
    )
}

// MARK: - Frost rule

@Suite("WeatherKitRefiner — frost rule")
struct FrostRuleTests {
    let anchor = "2025-05-01"
    // 10-element score array; day-0..9 all start at 1.0
    let baseScores = Array(repeating: 1.0, count: 10)

    @Test("tender variety: frost on day 2 shifts plant_now → plant_soon")
    func frostShiftsPlantNowToPlantSoon() {
        var forecast = (0..<10).map { neutralDay(anchor: anchor, offset: $0) }
        // Frost on day 2 (lowTempF = 28 < 32)
        forecast[2] = ForecastDay(
            date: dateFromAnchor(anchor, offsetDays: 2),
            lowTempF: 28,
            highTempF: 55,
            precipitationInches: 0.0
        )
        let result = WeatherKitRefiner.refine(
            verdict: "plant_now",
            scores: baseScores,
            anchorDate: anchor,
            frostTolerance: "tender",
            soilTempMaxF: nil,
            forecast: forecast
        )
        #expect(result.verdict == "plant_soon")
        // Scores at/before frost day (indices 0..2) should be zeroed
        #expect(result.dailyScores[0] == 0.0)
        #expect(result.dailyScores[1] == 0.0)
        #expect(result.dailyScores[2] == 0.0)
        // Scores after the frost day should remain positive
        #expect(result.dailyScores[3] > 0.0)
    }

    @Test("tender variety: frost on day 1 shifts plant_soon → too_early")
    func frostShiftsPlantSoonToTooEarly() {
        var forecast = (0..<10).map { neutralDay(anchor: anchor, offset: $0) }
        forecast[1] = ForecastDay(
            date: dateFromAnchor(anchor, offsetDays: 1),
            lowTempF: 30,
            highTempF: 58,
            precipitationInches: 0.0
        )
        let result = WeatherKitRefiner.refine(
            verdict: "plant_soon",
            scores: baseScores,
            anchorDate: anchor,
            frostTolerance: "tender",
            soilTempMaxF: nil,
            forecast: forecast
        )
        #expect(result.verdict == "too_early")
        #expect(result.dailyScores[0] == 0.0)
        #expect(result.dailyScores[1] == 0.0)
    }

    @Test("hardy variety: forecast frost does NOT shift verdict or zero scores")
    func hardyVarietyIgnoresFrost() {
        var forecast = (0..<10).map { neutralDay(anchor: anchor, offset: $0) }
        forecast[0] = ForecastDay(
            date: dateFromAnchor(anchor, offsetDays: 0),
            lowTempF: 28,
            highTempF: 50,
            precipitationInches: 0.0
        )
        let result = WeatherKitRefiner.refine(
            verdict: "plant_now",
            scores: baseScores,
            anchorDate: anchor,
            frostTolerance: "hardy",
            soilTempMaxF: nil,
            forecast: forecast
        )
        #expect(result.verdict == "plant_now")
        // Scores should be untouched by the frost rule
        #expect(result.dailyScores[0] > 0.0)
    }

    @Test("frost on day 0: too_early stays too_early (no further shift past too_early)")
    func frostDoesNotShiftBeyondTooEarly() {
        var forecast = (0..<10).map { neutralDay(anchor: anchor, offset: $0) }
        forecast[0] = ForecastDay(
            date: dateFromAnchor(anchor, offsetDays: 0),
            lowTempF: 28,
            highTempF: 50,
            precipitationInches: 0.0
        )
        let result = WeatherKitRefiner.refine(
            verdict: "too_early",
            scores: baseScores,
            anchorDate: anchor,
            frostTolerance: "tender",
            soilTempMaxF: nil,
            forecast: forecast
        )
        // too_early cannot shift further toward wait
        #expect(result.verdict == "too_early")
    }
}

// MARK: - Heavy rain rule

@Suite("WeatherKitRefiner — heavy rain rule")
struct HeavyRainRuleTests {
    let anchor = "2025-05-01"
    let baseScores = Array(repeating: 1.0, count: 10)

    @Test("heavy rain on day 3 zeros scores for days 3, 4, 5")
    func heavyRainZerosThreeDayWindow() {
        var forecast = (0..<10).map { neutralDay(anchor: anchor, offset: $0) }
        // 0.6 inches > 0.5 threshold
        forecast[3] = ForecastDay(
            date: dateFromAnchor(anchor, offsetDays: 3),
            lowTempF: 50,
            highTempF: 68,
            precipitationInches: 0.6
        )
        let result = WeatherKitRefiner.refine(
            verdict: "plant_now",
            scores: baseScores,
            anchorDate: anchor,
            frostTolerance: nil,
            soilTempMaxF: nil,
            forecast: forecast
        )
        #expect(result.dailyScores[3] == 0.0)
        #expect(result.dailyScores[4] == 0.0)
        #expect(result.dailyScores[5] == 0.0)
        // Days before the rain event should be unaffected
        #expect(result.dailyScores[0] > 0.0)
        #expect(result.dailyScores[2] > 0.0)
        // Day 6 and beyond should be unaffected by this rain event
        #expect(result.dailyScores[6] > 0.0)
    }

    @Test("heavy rain on day 8 zeros days 8 and 9 only (clamps at array end)")
    func heavyRainNearEndClampsAtArrayBound() {
        var forecast = (0..<10).map { neutralDay(anchor: anchor, offset: $0) }
        forecast[8] = ForecastDay(
            date: dateFromAnchor(anchor, offsetDays: 8),
            lowTempF: 50,
            highTempF: 68,
            precipitationInches: 0.8
        )
        let result = WeatherKitRefiner.refine(
            verdict: "plant_now",
            scores: baseScores,
            anchorDate: anchor,
            frostTolerance: nil,
            soilTempMaxF: nil,
            forecast: forecast
        )
        #expect(result.dailyScores[8] == 0.0)
        #expect(result.dailyScores[9] == 0.0)
        // Earlier days untouched
        #expect(result.dailyScores[7] > 0.0)
    }

    @Test("light rain below threshold does not zero scores")
    func lightRainBelowThresholdUnchanged() {
        var forecast = (0..<10).map { neutralDay(anchor: anchor, offset: $0) }
        forecast[2] = ForecastDay(
            date: dateFromAnchor(anchor, offsetDays: 2),
            lowTempF: 50,
            highTempF: 68,
            precipitationInches: 0.3  // below 0.5 threshold
        )
        let result = WeatherKitRefiner.refine(
            verdict: "plant_now",
            scores: baseScores,
            anchorDate: anchor,
            frostTolerance: nil,
            soilTempMaxF: nil,
            forecast: forecast
        )
        // All scores should remain positive
        for score in result.dailyScores {
            #expect(score > 0.0)
        }
    }
}

// MARK: - Sustained heat rule

@Suite("WeatherKitRefiner — sustained heat rule")
struct SustainedHeatRuleTests {
    let anchor = "2025-05-01"
    let baseScores = Array(repeating: 1.0, count: 10)

    @Test("3 consecutive hot days trim late-window scores for cool-season variety")
    func sustainedHeatTrimsLateWindow() {
        // soilTempMaxF = 75; highTempF = 90 on days 7, 8, 9 (3 consecutive)
        var forecast = (0..<10).map { neutralDay(anchor: anchor, offset: $0) }
        for i in 7..<10 {
            forecast[i] = ForecastDay(
                date: dateFromAnchor(anchor, offsetDays: i),
                lowTempF: 65,
                highTempF: 90,  // well above soilTempMaxF = 75
                precipitationInches: 0.0
            )
        }
        let result = WeatherKitRefiner.refine(
            verdict: "plant_now",
            scores: baseScores,
            anchorDate: anchor,
            frostTolerance: nil,
            soilTempMaxF: 75,
            forecast: forecast
        )
        // The late-window scores (at/after the heat streak) should be zeroed/near-zero
        #expect(result.dailyScores[7] == 0.0)
        #expect(result.dailyScores[8] == 0.0)
        #expect(result.dailyScores[9] == 0.0)
        // Early scores unaffected
        #expect(result.dailyScores[0] > 0.0)
        #expect(result.dailyScores[6] > 0.0)
    }

    @Test("only 2 consecutive hot days does NOT trim scores")
    func twoHotDaysDoesNotTrim() {
        var forecast = (0..<10).map { neutralDay(anchor: anchor, offset: $0) }
        for i in 7..<9 {   // only days 7 and 8
            forecast[i] = ForecastDay(
                date: dateFromAnchor(anchor, offsetDays: i),
                lowTempF: 65,
                highTempF: 90,
                precipitationInches: 0.0
            )
        }
        let result = WeatherKitRefiner.refine(
            verdict: "plant_now",
            scores: baseScores,
            anchorDate: anchor,
            frostTolerance: nil,
            soilTempMaxF: 75,
            forecast: forecast
        )
        // With only 2 hot days (below the 3-day threshold), late scores untouched
        #expect(result.dailyScores[7] > 0.0)
        #expect(result.dailyScores[8] > 0.0)
    }

    @Test("no soilTempMaxF provided: sustained heat rule does not fire")
    func noSoilTempMaxSkipsHeatRule() {
        var forecast = (0..<10).map { neutralDay(anchor: anchor, offset: $0) }
        for i in 7..<10 {
            forecast[i] = ForecastDay(
                date: dateFromAnchor(anchor, offsetDays: i),
                lowTempF: 65,
                highTempF: 95,
                precipitationInches: 0.0
            )
        }
        let result = WeatherKitRefiner.refine(
            verdict: "plant_now",
            scores: baseScores,
            anchorDate: anchor,
            frostTolerance: nil,
            soilTempMaxF: nil,  // no limit provided
            forecast: forecast
        )
        // All scores should remain positive since soilTempMaxF is unknown
        #expect(result.dailyScores[7] > 0.0)
    }
}

// MARK: - Ideal stretch rule

@Suite("WeatherKitRefiner — ideal stretch rule")
struct IdealStretchRuleTests {
    let anchor = "2025-05-01"
    let baseScores = Array(repeating: 1.0, count: 10)

    @Test("benign 10-day forecast yields ideal weatherNote and unchanged verdict/scores")
    func benignForecastIdealNote() {
        // All neutral days: lowTempF=50, highTempF=72, precip=0 — no adverse signal
        let forecast = (0..<10).map { neutralDay(anchor: anchor, offset: $0) }
        let result = WeatherKitRefiner.refine(
            verdict: "plant_now",
            scores: baseScores,
            anchorDate: anchor,
            frostTolerance: "tender",
            soilTempMaxF: 85,
            forecast: forecast
        )
        #expect(result.weatherNote == "Next 10 days look ideal.")
        #expect(result.verdict == "plant_now")
        for score in result.dailyScores {
            #expect(score > 0.0)
        }
    }

    @Test("adverse forecast does NOT produce the ideal weatherNote")
    func adverseForecastNoIdealNote() {
        var forecast = (0..<10).map { neutralDay(anchor: anchor, offset: $0) }
        // Heavy rain on day 4
        forecast[4] = ForecastDay(
            date: dateFromAnchor(anchor, offsetDays: 4),
            lowTempF: 50,
            highTempF: 68,
            precipitationInches: 0.7
        )
        let result = WeatherKitRefiner.refine(
            verdict: "plant_now",
            scores: baseScores,
            anchorDate: anchor,
            frostTolerance: "tender",
            soilTempMaxF: 85,
            forecast: forecast
        )
        #expect(result.weatherNote != "Next 10 days look ideal.")
    }

    @Test("empty forecast returns baseline unchanged with nil weatherNote")
    func emptyForecastReturnsBaseline() {
        let result = WeatherKitRefiner.refine(
            verdict: "plant_now",
            scores: baseScores,
            anchorDate: anchor,
            frostTolerance: "tender",
            soilTempMaxF: 85,
            forecast: []
        )
        #expect(result.verdict == "plant_now")
        #expect(result.dailyScores == baseScores)
        #expect(result.weatherNote == nil)
    }
}
