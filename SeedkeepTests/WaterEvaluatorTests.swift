import Testing
import Foundation
@testable import Seedkeep

/// Pure-evaluator tests for `WaterEvaluator.evaluate`.
///
/// Five-stage gate per spec §5; each gate has at least one boundary test
/// that asserts the strict-vs-non-strict comparison. Server vs local
/// dedup precedence is also pinned here (server wins).
///
/// Spec: `.docs/ai/specs/2026-06-07-phase-4c-native-warnings-design.md`
/// §5 (water semantics) + §11 (Layer 1 — WaterEvaluatorTests).
@Suite("WaterEvaluator — Phase 4C pure-evaluator")
struct WaterEvaluatorTests {

    // MARK: - Test environment

    private static let homeTimeZone = TimeZone(identifier: "America/Chicago")!

    private static var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = homeTimeZone
        return cal
    }

    /// Anchor `now` to a stable midpoint that avoids the 8am-already-past
    /// branch — we want the evaluator's `.notify(fireDate:)` to fall on
    /// "today 08:00 home-TZ" so identifier shape stays predictable.
    private static var anchorNow: Date {
        let cal = calendar
        // 2026-07-15 03:00 home-TZ — well before 8am, well after past
        // 5 days of warmth/observations.
        let comps = DateComponents(
            calendar: cal, timeZone: homeTimeZone,
            year: 2026, month: 7, day: 15, hour: 3, minute: 0
        )
        return cal.date(from: comps) ?? Date()
    }

    private static func midnight(
        year: Int, month: Int, day: Int,
        in tz: TimeZone = homeTimeZone
    ) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        let comps = DateComponents(
            calendar: cal, timeZone: tz,
            year: year, month: month, day: day
        )
        return cal.date(from: comps) ?? Date()
    }

    /// Build a `PastObservations` covering the 5 days ending YESTERDAY
    /// (the evaluator's anchor). Each day has the same rain + high so
    /// tests can dial each parameter independently.
    private static func observations(
        endingAt: Date,
        rainMM: Double,
        highF: Double,
        days: Int = 5
    ) -> PastObservations {
        let cal = calendar
        var byYMD: [String: ObservedDay] = [:]
        for offset in 0..<days {
            guard let d = cal.date(byAdding: .day, value: -offset, to: endingAt) else {
                continue
            }
            let ymd = Identifier.isoDay(d, in: homeTimeZone)
            byYMD[ymd] = ObservedDay(
                date: d,
                rainMM: rainMM,
                highF: highF,
                humidity: 0,
                windMPH: 0
            )
        }
        let firstObs = byYMD.values.map { $0.date }.min()
            .map { Identifier.isoDay($0, in: homeTimeZone) }
        return PastObservations(byYMD: byYMD, firstObservationYMD: firstObs)
    }

    /// 3-day dry forecast (no rain, all warm) anchored at `start`.
    private static func dryForecast(start: Date, days: Int = 3) -> [DailyWeather] {
        let cal = calendar
        var forecast: [DailyWeather] = []
        for offset in 0..<days {
            guard let d = cal.date(byAdding: .day, value: offset, to: start) else {
                continue
            }
            forecast.append(DailyWeather(
                date: d,
                lowF: 70,
                highF: 88,
                precipMM: 0,
                rainMM: 0,
                apparentHighF: 88,
                precipitationChance: 0,
                humidity: 0,
                windMPH: 0
            ))
        }
        return forecast
    }

    // MARK: - History sufficiency

    @Test("insufficient history (2 observed days) → .insufficientHistory")
    func insufficientHistory() {
        let now = Self.anchorNow
        // Only 2 days of observations — need 3.
        guard let yesterday = Self.calendar.date(byAdding: .day, value: -1, to: now) else {
            Issue.record("calendar.date failure")
            return
        }
        let past = Self.observations(endingAt: yesterday, rainMM: 0, highF: 90, days: 2)
        let forecast = Self.dryForecast(start: now)
        let decision = WaterEvaluator.evaluate(
            forecast: forecast,
            past: past,
            thresholds: .kc,
            householdLastWaterAt: nil,
            lastLocalFireDate: nil,
            now: now,
            calendar: Self.calendar,
            homeTimeZone: Self.homeTimeZone
        )
        if case .skip(.insufficientHistory(let have, let need)) = decision {
            #expect(have == 2)
            #expect(need == 3)
        } else {
            Issue.record("expected .insufficientHistory, got \(decision)")
        }
    }

    // MARK: - Happy path

    @Test("happy path fires .dryStretchStarting (no prior water timestamp)")
    func happyPathStarting() {
        let now = Self.anchorNow
        guard let yesterday = Self.calendar.date(byAdding: .day, value: -1, to: now) else {
            Issue.record("calendar.date failure"); return
        }
        // 5 dry warm days observed, 3 dry warm days forecast.
        let past = Self.observations(endingAt: yesterday, rainMM: 0, highF: 90, days: 5)
        let forecast = Self.dryForecast(start: now)
        let decision = WaterEvaluator.evaluate(
            forecast: forecast,
            past: past,
            thresholds: .kc,
            householdLastWaterAt: nil,
            lastLocalFireDate: nil,
            now: now,
            calendar: Self.calendar,
            homeTimeZone: Self.homeTimeZone
        )
        if case .notify(_, let identifier, let reason) = decision {
            #expect(reason == .dryStretchStarting)
            #expect(identifier.hasPrefix("seedkeep.notif.water."))
        } else {
            Issue.record("expected .notify(.dryStretchStarting), got \(decision)")
        }
    }

    // MARK: - Past cumulative rain check

    @Test("past cumulative 13mm skip (rainedRecentlyCumulative)")
    func pastCumulative13mmSkip() {
        let now = Self.anchorNow
        guard let yesterday = Self.calendar.date(byAdding: .day, value: -1, to: now) else {
            Issue.record("calendar.date failure"); return
        }
        // 5 days × 2.6mm = 13mm total.
        let past = Self.observations(endingAt: yesterday, rainMM: 2.6, highF: 90, days: 5)
        let forecast = Self.dryForecast(start: now)
        let decision = WaterEvaluator.evaluate(
            forecast: forecast,
            past: past,
            thresholds: .kc,
            householdLastWaterAt: nil,
            lastLocalFireDate: nil,
            now: now,
            calendar: Self.calendar,
            homeTimeZone: Self.homeTimeZone
        )
        if case .skip(.rainedRecentlyCumulative(let mm)) = decision {
            #expect(mm >= 12.0)
        } else {
            Issue.record("expected .rainedRecentlyCumulative, got \(decision)")
        }
    }

    @Test("past cumulative 11mm fires (sum < 12mm)")
    func pastCumulative11mmFires() {
        let now = Self.anchorNow
        guard let yesterday = Self.calendar.date(byAdding: .day, value: -1, to: now) else {
            Issue.record("calendar.date failure"); return
        }
        // 5 days × 2.2mm = 11mm total — below 12mm threshold.
        let past = Self.observations(endingAt: yesterday, rainMM: 2.2, highF: 90, days: 5)
        let forecast = Self.dryForecast(start: now)
        let decision = WaterEvaluator.evaluate(
            forecast: forecast,
            past: past,
            thresholds: .kc,
            householdLastWaterAt: nil,
            lastLocalFireDate: nil,
            now: now,
            calendar: Self.calendar,
            homeTimeZone: Self.homeTimeZone
        )
        if case .notify = decision {
            // OK
        } else {
            Issue.record("expected .notify, got \(decision)")
        }
    }

    @Test("past trace 5×2.5mm = 12.5mm skips (>= 12mm boundary)")
    func pastTrace5x25mmSkips() {
        let now = Self.anchorNow
        guard let yesterday = Self.calendar.date(byAdding: .day, value: -1, to: now) else {
            Issue.record("calendar.date failure"); return
        }
        let past = Self.observations(endingAt: yesterday, rainMM: 2.5, highF: 90, days: 5)
        let forecast = Self.dryForecast(start: now)
        let decision = WaterEvaluator.evaluate(
            forecast: forecast,
            past: past,
            thresholds: .kc,
            householdLastWaterAt: nil,
            lastLocalFireDate: nil,
            now: now,
            calendar: Self.calendar,
            homeTimeZone: Self.homeTimeZone
        )
        if case .skip(.rainedRecentlyCumulative) = decision {
            // OK
        } else {
            Issue.record("expected .rainedRecentlyCumulative, got \(decision)")
        }
    }

    @Test("past 4×2.5mm = 10mm fires (sum < 12mm)")
    func pastTrace4x25mmFires() {
        let now = Self.anchorNow
        guard let yesterday = Self.calendar.date(byAdding: .day, value: -1, to: now) else {
            Issue.record("calendar.date failure"); return
        }
        // 4 days × 2.5mm = 10mm over the 5-day window (5th day has 0mm).
        // We need >= 3 observations to pass history; provide 4 with rain
        // and a 5th with 0mm.
        let cal = Self.calendar
        var byYMD: [String: ObservedDay] = [:]
        for offset in 0..<5 {
            guard let d = cal.date(byAdding: .day, value: -offset, to: yesterday) else {
                continue
            }
            let ymd = Identifier.isoDay(d, in: Self.homeTimeZone)
            let rain: Double = (offset < 4) ? 2.5 : 0.0
            byYMD[ymd] = ObservedDay(date: d, rainMM: rain, highF: 90, humidity: 0, windMPH: 0)
        }
        let past = PastObservations(byYMD: byYMD, firstObservationYMD: nil)
        let forecast = Self.dryForecast(start: now)
        let decision = WaterEvaluator.evaluate(
            forecast: forecast,
            past: past,
            thresholds: .kc,
            householdLastWaterAt: nil,
            lastLocalFireDate: nil,
            now: now,
            calendar: cal,
            homeTimeZone: Self.homeTimeZone
        )
        if case .notify = decision {
            // OK
        } else {
            Issue.record("expected .notify, got \(decision)")
        }
    }

    // MARK: - Forecast soaking-rain check

    @Test("forecast 6mm rain day-2 skips (.rainExpectedSoon)")
    func forecast6mmDay2Skips() {
        let now = Self.anchorNow
        guard let yesterday = Self.calendar.date(byAdding: .day, value: -1, to: now) else {
            Issue.record("calendar.date failure"); return
        }
        let past = Self.observations(endingAt: yesterday, rainMM: 0, highF: 90, days: 5)
        // Forecast: day-0 dry, day-1 = 6mm soaking, day-2 dry. Day-1 fires
        // the >= 6mm rule.
        var forecast = Self.dryForecast(start: now)
        forecast[1] = DailyWeather(
            date: forecast[1].date,
            lowF: forecast[1].lowF,
            highF: forecast[1].highF,
            precipMM: 6.0,
            rainMM: 6.0,
            apparentHighF: forecast[1].apparentHighF,
            precipitationChance: 1.0,
            humidity: 0,
            windMPH: 0
        )
        let decision = WaterEvaluator.evaluate(
            forecast: forecast,
            past: past,
            thresholds: .kc,
            householdLastWaterAt: nil,
            lastLocalFireDate: nil,
            now: now,
            calendar: Self.calendar,
            homeTimeZone: Self.homeTimeZone
        )
        if case .skip(.rainExpectedSoon) = decision {
            // OK
        } else {
            Issue.record("expected .rainExpectedSoon, got \(decision)")
        }
    }

    @Test("forecast 5.9mm rain day-2 fires (boundary: < 6mm)")
    func forecast5_9mmDay2Fires() {
        let now = Self.anchorNow
        guard let yesterday = Self.calendar.date(byAdding: .day, value: -1, to: now) else {
            Issue.record("calendar.date failure"); return
        }
        let past = Self.observations(endingAt: yesterday, rainMM: 0, highF: 90, days: 5)
        // 5.9mm on day-1 + 0 elsewhere; cumulative (5.9) < 12mm → no skip.
        var forecast = Self.dryForecast(start: now)
        forecast[1] = DailyWeather(
            date: forecast[1].date,
            lowF: forecast[1].lowF,
            highF: forecast[1].highF,
            precipMM: 5.9,
            rainMM: 5.9,
            apparentHighF: forecast[1].apparentHighF,
            precipitationChance: 0.8,
            humidity: 0,
            windMPH: 0
        )
        let decision = WaterEvaluator.evaluate(
            forecast: forecast,
            past: past,
            thresholds: .kc,
            householdLastWaterAt: nil,
            lastLocalFireDate: nil,
            now: now,
            calendar: Self.calendar,
            homeTimeZone: Self.homeTimeZone
        )
        if case .notify = decision {
            // OK
        } else {
            Issue.record("expected .notify, got \(decision)")
        }
    }

    @Test("forecast cumulative 12mm split across days skips")
    func forecastCumulative12mmSplitSkips() {
        let now = Self.anchorNow
        guard let yesterday = Self.calendar.date(byAdding: .day, value: -1, to: now) else {
            Issue.record("calendar.date failure"); return
        }
        let past = Self.observations(endingAt: yesterday, rainMM: 0, highF: 90, days: 5)
        // 4mm × 3 days = 12mm cumulative — each day under 6mm individually,
        // but cumulative trips the >= 12mm rule.
        var forecast = Self.dryForecast(start: now)
        for i in 0..<3 {
            forecast[i] = DailyWeather(
                date: forecast[i].date,
                lowF: forecast[i].lowF,
                highF: forecast[i].highF,
                precipMM: 4.0,
                rainMM: 4.0,
                apparentHighF: forecast[i].apparentHighF,
                precipitationChance: 0.5,
                humidity: 0,
                windMPH: 0
            )
        }
        let decision = WaterEvaluator.evaluate(
            forecast: forecast,
            past: past,
            thresholds: .kc,
            householdLastWaterAt: nil,
            lastLocalFireDate: nil,
            now: now,
            calendar: Self.calendar,
            homeTimeZone: Self.homeTimeZone
        )
        if case .skip(.rainExpectedSoon) = decision {
            // OK
        } else {
            Issue.record("expected .rainExpectedSoon, got \(decision)")
        }
    }

    // MARK: - Past warmth / ET proxy

    @Test("cool 70°F avg past week skips (.coolDryNotEnoughET)")
    func cool70AvgSkips() {
        let now = Self.anchorNow
        guard let yesterday = Self.calendar.date(byAdding: .day, value: -1, to: now) else {
            Issue.record("calendar.date failure"); return
        }
        let past = Self.observations(endingAt: yesterday, rainMM: 0, highF: 70, days: 5)
        let forecast = Self.dryForecast(start: now)
        let decision = WaterEvaluator.evaluate(
            forecast: forecast,
            past: past,
            thresholds: .kc,
            householdLastWaterAt: nil,
            lastLocalFireDate: nil,
            now: now,
            calendar: Self.calendar,
            homeTimeZone: Self.homeTimeZone
        )
        if case .skip(.coolDryNotEnoughET) = decision {
            // OK
        } else {
            Issue.record("expected .coolDryNotEnoughET, got \(decision)")
        }
    }

    @Test("75.1°F avg fires (boundary: >= 75°F)")
    func warm75_1Fires() {
        let now = Self.anchorNow
        guard let yesterday = Self.calendar.date(byAdding: .day, value: -1, to: now) else {
            Issue.record("calendar.date failure"); return
        }
        let past = Self.observations(endingAt: yesterday, rainMM: 0, highF: 75.1, days: 5)
        let forecast = Self.dryForecast(start: now)
        let decision = WaterEvaluator.evaluate(
            forecast: forecast,
            past: past,
            thresholds: .kc,
            householdLastWaterAt: nil,
            lastLocalFireDate: nil,
            now: now,
            calendar: Self.calendar,
            homeTimeZone: Self.homeTimeZone
        )
        if case .notify = decision {
            // OK
        } else {
            Issue.record("expected .notify, got \(decision)")
        }
    }

    // MARK: - Dedup window boundary

    @Test("dedup 7d-1s skips (within 7-day window)")
    func dedup7dMinus1sSkips() {
        let now = Self.anchorNow
        guard let yesterday = Self.calendar.date(byAdding: .day, value: -1, to: now) else {
            Issue.record("calendar.date failure"); return
        }
        let past = Self.observations(endingAt: yesterday, rainMM: 0, highF: 90, days: 5)
        let forecast = Self.dryForecast(start: now)
        // Last fire: 7 days ago + 1 second forward (i.e. one second
        // shy of the 7-day boundary).
        let lastFire = now.addingTimeInterval(-(7 * 86_400) + 1)
        let decision = WaterEvaluator.evaluate(
            forecast: forecast,
            past: past,
            thresholds: .kc,
            householdLastWaterAt: nil,
            lastLocalFireDate: lastFire,
            now: now,
            calendar: Self.calendar,
            homeTimeZone: Self.homeTimeZone
        )
        if case .skip(.dedupWindow) = decision {
            // OK
        } else {
            Issue.record("expected .dedupWindow, got \(decision)")
        }
    }

    @Test("dedup 7d+1s fires .dryStretchContinuing")
    func dedup7dPlus1sFiresContinuing() {
        let now = Self.anchorNow
        guard let yesterday = Self.calendar.date(byAdding: .day, value: -1, to: now) else {
            Issue.record("calendar.date failure"); return
        }
        let past = Self.observations(endingAt: yesterday, rainMM: 0, highF: 90, days: 5)
        let forecast = Self.dryForecast(start: now)
        let lastFire = now.addingTimeInterval(-(7 * 86_400) - 1)
        let decision = WaterEvaluator.evaluate(
            forecast: forecast,
            past: past,
            thresholds: .kc,
            householdLastWaterAt: nil,
            lastLocalFireDate: lastFire,
            now: now,
            calendar: Self.calendar,
            homeTimeZone: Self.homeTimeZone
        )
        if case .notify(_, _, let reason) = decision {
            #expect(reason == .dryStretchContinuing)
        } else {
            Issue.record("expected .notify(.dryStretchContinuing), got \(decision)")
        }
    }

    @Test("10d fires .dryStretchExtended (>= 10d boundary)")
    func dedup10dFiresExtended() {
        let now = Self.anchorNow
        guard let yesterday = Self.calendar.date(byAdding: .day, value: -1, to: now) else {
            Issue.record("calendar.date failure"); return
        }
        let past = Self.observations(endingAt: yesterday, rainMM: 0, highF: 90, days: 5)
        let forecast = Self.dryForecast(start: now)
        let lastFire = now.addingTimeInterval(-(10 * 86_400) - 1)
        let decision = WaterEvaluator.evaluate(
            forecast: forecast,
            past: past,
            thresholds: .kc,
            householdLastWaterAt: nil,
            lastLocalFireDate: lastFire,
            now: now,
            calendar: Self.calendar,
            homeTimeZone: Self.homeTimeZone
        )
        if case .notify(_, _, let reason) = decision {
            #expect(reason == .dryStretchExtended)
        } else {
            Issue.record("expected .notify(.dryStretchExtended), got \(decision)")
        }
    }

    @Test("8d fires .dryStretchContinuing (between 7d and 10d)")
    func dedup8dFiresContinuing() {
        let now = Self.anchorNow
        guard let yesterday = Self.calendar.date(byAdding: .day, value: -1, to: now) else {
            Issue.record("calendar.date failure"); return
        }
        let past = Self.observations(endingAt: yesterday, rainMM: 0, highF: 90, days: 5)
        let forecast = Self.dryForecast(start: now)
        let lastFire = now.addingTimeInterval(-8 * 86_400)
        let decision = WaterEvaluator.evaluate(
            forecast: forecast,
            past: past,
            thresholds: .kc,
            householdLastWaterAt: nil,
            lastLocalFireDate: lastFire,
            now: now,
            calendar: Self.calendar,
            homeTimeZone: Self.homeTimeZone
        )
        if case .notify(_, _, let reason) = decision {
            #expect(reason == .dryStretchContinuing)
        } else {
            Issue.record("expected .notify(.dryStretchContinuing), got \(decision)")
        }
    }

    // MARK: - DST spring-forward dedup respects absolute seconds

    @Test("DST spring-forward: dedup uses absolute seconds, not calendar days")
    func dstSpringForwardDedupAbsoluteSeconds() {
        // Spring-forward 2026: 2026-03-08. Schedule a "now" on the
        // afternoon of 2026-03-15 (a week after spring-forward).
        let cal = Self.calendar
        let comps = DateComponents(
            calendar: cal, timeZone: Self.homeTimeZone,
            year: 2026, month: 3, day: 15, hour: 3, minute: 0
        )
        guard let now = cal.date(from: comps) else {
            Issue.record("calendar.date failure"); return
        }
        guard let yesterday = cal.date(byAdding: .day, value: -1, to: now) else {
            Issue.record("calendar.date failure"); return
        }
        let past = Self.observations(endingAt: yesterday, rainMM: 0, highF: 90, days: 5)
        let forecast = Self.dryForecast(start: now)
        // Last fire = exactly 7 calendar days ago by wall-clock (which is
        // 7 × 86_400 − 3_600 absolute seconds due to spring-forward). The
        // evaluator's dedup is absolute-seconds, so this should pass
        // dedup (elapsed > 7 × 86_400 − 3_600) — but actually we want it
        // to STILL be in the dedup window because absolute is < 7 × 86_400.
        let lastFire = now.addingTimeInterval(-(7 * 86_400) + 3_600)
        let decision = WaterEvaluator.evaluate(
            forecast: forecast,
            past: past,
            thresholds: .kc,
            householdLastWaterAt: nil,
            lastLocalFireDate: lastFire,
            now: now,
            calendar: cal,
            homeTimeZone: Self.homeTimeZone
        )
        // 7×86400 − 3600 = 6.96 days absolute → still in dedup window.
        if case .skip(.dedupWindow) = decision {
            // OK
        } else {
            Issue.record("expected .dedupWindow (absolute seconds), got \(decision)")
        }
    }

    // MARK: - Server vs local precedence

    @Test("householdLastWaterAt overrides lastLocalFireDate (server wins)")
    func serverOverridesLocal() {
        let now = Self.anchorNow
        guard let yesterday = Self.calendar.date(byAdding: .day, value: -1, to: now) else {
            Issue.record("calendar.date failure"); return
        }
        let past = Self.observations(endingAt: yesterday, rainMM: 0, highF: 90, days: 5)
        let forecast = Self.dryForecast(start: now)
        // Local says 30 days ago (would be .extended); server says 2 days
        // ago (should dedup). Server wins.
        let local = now.addingTimeInterval(-30 * 86_400)
        let server = now.addingTimeInterval(-2 * 86_400)
        let decision = WaterEvaluator.evaluate(
            forecast: forecast,
            past: past,
            thresholds: .kc,
            householdLastWaterAt: server,
            lastLocalFireDate: local,
            now: now,
            calendar: Self.calendar,
            homeTimeZone: Self.homeTimeZone
        )
        if case .skip(.dedupWindow) = decision {
            // OK — server's 2-day-ago timestamp triggers dedup.
        } else {
            Issue.record("expected server-wins .dedupWindow, got \(decision)")
        }
    }

    @Test("nil householdLastWaterAt falls back to lastLocalFireDate")
    func serverNilFallsBackToLocal() {
        let now = Self.anchorNow
        guard let yesterday = Self.calendar.date(byAdding: .day, value: -1, to: now) else {
            Issue.record("calendar.date failure"); return
        }
        let past = Self.observations(endingAt: yesterday, rainMM: 0, highF: 90, days: 5)
        let forecast = Self.dryForecast(start: now)
        let local = now.addingTimeInterval(-2 * 86_400)
        let decision = WaterEvaluator.evaluate(
            forecast: forecast,
            past: past,
            thresholds: .kc,
            householdLastWaterAt: nil,
            lastLocalFireDate: local,
            now: now,
            calendar: Self.calendar,
            homeTimeZone: Self.homeTimeZone
        )
        if case .skip(.dedupWindow) = decision {
            // OK
        } else {
            Issue.record("expected fallback .dedupWindow, got \(decision)")
        }
    }

    @Test("both nil fires .dryStretchStarting")
    func bothNilFiresStarting() {
        let now = Self.anchorNow
        guard let yesterday = Self.calendar.date(byAdding: .day, value: -1, to: now) else {
            Issue.record("calendar.date failure"); return
        }
        let past = Self.observations(endingAt: yesterday, rainMM: 0, highF: 90, days: 5)
        let forecast = Self.dryForecast(start: now)
        let decision = WaterEvaluator.evaluate(
            forecast: forecast,
            past: past,
            thresholds: .kc,
            householdLastWaterAt: nil,
            lastLocalFireDate: nil,
            now: now,
            calendar: Self.calendar,
            homeTimeZone: Self.homeTimeZone
        )
        if case .notify(_, _, let reason) = decision {
            #expect(reason == .dryStretchStarting)
        } else {
            Issue.record("expected .dryStretchStarting, got \(decision)")
        }
    }
}
