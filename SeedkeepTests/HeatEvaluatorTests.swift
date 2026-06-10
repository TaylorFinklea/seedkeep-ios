import Testing
import Foundation
@testable import Seedkeep

/// Pure-evaluator tests for `HeatEvaluator.evaluate`.
///
/// Spec: `.docs/ai/specs/2026-06-07-phase-4c-native-warnings-design.md`
/// §5 (heat semantics) + §11 (Layer 1 — HeatEvaluatorTests).
@Suite("HeatEvaluator — Phase 4C pure-evaluator")
struct HeatEvaluatorTests {

    // MARK: - Test environment

    private static let homeTimeZone = TimeZone(identifier: "America/Chicago")!

    private static var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = homeTimeZone
        return cal
    }

    private static func midnight(_ ymd: String, in tz: TimeZone = homeTimeZone) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        let parts = ymd.split(separator: "-").map { Int($0) ?? 0 }
        guard parts.count == 3 else { return Date() }
        let comps = DateComponents(
            calendar: cal,
            timeZone: tz,
            year: parts[0],
            month: parts[1],
            day: parts[2]
        )
        return cal.date(from: comps) ?? Date()
    }

    private static func day(
        _ ymd: String,
        highF: Double,
        apparentHighF: Double? = nil,
        in tz: TimeZone = homeTimeZone
    ) -> DailyWeather {
        DailyWeather(
            date: midnight(ymd, in: tz),
            lowF: 70,
            highF: highF,
            precipMM: 0,
            rainMM: 0,
            apparentHighF: apparentHighF ?? highF,
            precipitationChance: 0,
            humidity: 0,
            windMPH: 0
        )
    }

    // MARK: - Heat-dome path

    @Test("4-day run at 95°F fires dome-starting")
    func fourDayRunFiresDome() {
        let now = FixedClock(now: Self.midnight("2026-07-01")).now
        // Start the dome a few days out so the 7pm prior-evening fire
        // stays in the future relative to `now`.
        let forecast = [
            Self.day("2026-07-05", highF: 95),
            Self.day("2026-07-06", highF: 96),
            Self.day("2026-07-07", highF: 97),
            Self.day("2026-07-08", highF: 98),
        ]
        let hits = HeatEvaluator.evaluate(
            forecast: forecast,
            thresholds: .kc,
            lastHeatDomeFireDate: nil,
            // Set a recent "last heat event" so first-of-season override
            // doesn't fire — we want to assert the heatDomeStarting variant.
            lastHeatEventDate: now.addingTimeInterval(-3 * 86_400),
            now: now,
            calendar: Self.calendar,
            homeTimeZone: Self.homeTimeZone
        )
        #expect(hits.count == 1)
        #expect(hits.first?.variant == .heatDomeStarting)
        #expect(hits.first?.highF == 95)
    }

    @Test("3-day run at 95°F does NOT fire dome (4 consecutive minimum)")
    func threeDayRunDoesNotFireDome() {
        let now = FixedClock(now: Self.midnight("2026-07-01")).now
        let forecast = [
            Self.day("2026-07-05", highF: 96),
            Self.day("2026-07-06", highF: 96),
            Self.day("2026-07-07", highF: 96),
            // gap: 78°F day breaks the run
            Self.day("2026-07-08", highF: 78),
        ]
        let hits = HeatEvaluator.evaluate(
            forecast: forecast,
            thresholds: .kc,
            lastHeatDomeFireDate: nil,
            lastHeatEventDate: now.addingTimeInterval(-3 * 86_400),
            now: now,
            calendar: Self.calendar,
            homeTimeZone: Self.homeTimeZone
        )
        #expect(hits.isEmpty)
    }

    // MARK: - Extreme apparent-temp path

    @Test("100°F apparent fires extreme")
    func extremeApparent100Fires() {
        let now = FixedClock(now: Self.midnight("2026-07-01")).now
        let forecast = [
            Self.day("2026-07-05", highF: 94, apparentHighF: 100),
        ]
        let hits = HeatEvaluator.evaluate(
            forecast: forecast,
            thresholds: .kc,
            lastHeatDomeFireDate: nil,
            lastHeatEventDate: now.addingTimeInterval(-3 * 86_400),
            now: now,
            calendar: Self.calendar,
            homeTimeZone: Self.homeTimeZone
        )
        #expect(hits.count == 1)
        #expect(hits.first?.variant == .extreme)
    }

    @Test("99°F apparent does NOT fire extreme (>= 100°F boundary)")
    func extremeApparent99DoesNotFire() {
        let now = FixedClock(now: Self.midnight("2026-07-01")).now
        let forecast = [
            Self.day("2026-07-05", highF: 94, apparentHighF: 99),
        ]
        let hits = HeatEvaluator.evaluate(
            forecast: forecast,
            thresholds: .kc,
            lastHeatDomeFireDate: nil,
            lastHeatEventDate: now.addingTimeInterval(-3 * 86_400),
            now: now,
            calendar: Self.calendar,
            homeTimeZone: Self.homeTimeZone
        )
        #expect(hits.isEmpty)
    }

    // MARK: - First-of-season override

    @Test("first-of-season override: nil lastHeatEventDate flips variant on first emitted hit")
    func firstOfSeasonNilLastHeat() {
        let now = FixedClock(now: Self.midnight("2026-06-01")).now
        let forecast = [
            Self.day("2026-06-05", highF: 95),
            Self.day("2026-06-06", highF: 95),
            Self.day("2026-06-07", highF: 95),
            Self.day("2026-06-08", highF: 95),
        ]
        let hits = HeatEvaluator.evaluate(
            forecast: forecast,
            thresholds: .kc,
            lastHeatDomeFireDate: nil,
            lastHeatEventDate: nil,           // never had heat
            now: now,
            calendar: Self.calendar,
            homeTimeZone: Self.homeTimeZone
        )
        #expect(hits.first?.variant == .firstOfSeason)
    }

    @Test("first-of-season override: > 30 days since last heat event flips variant")
    func firstOfSeasonAfter30Days() {
        let now = FixedClock(now: Self.midnight("2026-06-01")).now
        let forecast = [
            Self.day("2026-06-05", highF: 95),
            Self.day("2026-06-06", highF: 95),
            Self.day("2026-06-07", highF: 95),
            Self.day("2026-06-08", highF: 95),
        ]
        let lastHeatLongAgo = now.addingTimeInterval(-31 * 86_400)
        let hits = HeatEvaluator.evaluate(
            forecast: forecast,
            thresholds: .kc,
            lastHeatDomeFireDate: nil,
            lastHeatEventDate: lastHeatLongAgo,
            now: now,
            calendar: Self.calendar,
            homeTimeZone: Self.homeTimeZone
        )
        #expect(hits.first?.variant == .firstOfSeason)
    }

    // MARK: - Heat-dome dedup

    @Test("dome dedup: heatDate within 7 days of lastHeatDomeFireDate drops the hit")
    func domeDedupWithin7Days() {
        let now = FixedClock(now: Self.midnight("2026-07-01")).now
        let forecast = [
            Self.day("2026-07-05", highF: 96),
            Self.day("2026-07-06", highF: 96),
            Self.day("2026-07-07", highF: 96),
            Self.day("2026-07-08", highF: 96),
        ]
        // Last dome fire = 2026-07-03 (2 days before the heat date).
        let lastDome = Self.midnight("2026-07-03")
        let hits = HeatEvaluator.evaluate(
            forecast: forecast,
            thresholds: .kc,
            lastHeatDomeFireDate: lastDome,
            lastHeatEventDate: lastDome,
            now: now,
            calendar: Self.calendar,
            homeTimeZone: Self.homeTimeZone
        )
        #expect(hits.isEmpty)
    }

    @Test("dome dedup: a hit whose notification is still pending is exempt (cancel-before-fire guard)")
    func domeDedupExemptsPendingHit() {
        let now = FixedClock(now: Self.midnight("2026-07-01")).now
        let forecast = [
            Self.day("2026-07-05", highF: 96),
            Self.day("2026-07-06", highF: 96),
            Self.day("2026-07-07", highF: 96),
            Self.day("2026-07-08", highF: 96),
        ]
        // Schedule-time recording: lastHeatDomeFireDate == this very
        // hit's fire date (2026-07-04 19:00). Without the pending
        // exemption the evaluator drops its own just-scheduled hit and
        // the diff cancels the pending notification before delivery.
        guard let fire = Self.calendar.date(
            bySettingHour: 19, minute: 0, second: 0,
            of: Self.midnight("2026-07-04"),
            matchingPolicy: .nextTime,
            repeatedTimePolicy: .first,
            direction: .forward
        ) else {
            Issue.record("calendar.date failure")
            return
        }
        let identifier = "seedkeep.notif.heat.2026-07-05"
        let hits = HeatEvaluator.evaluate(
            forecast: forecast,
            thresholds: .kc,
            lastHeatDomeFireDate: fire,
            lastHeatEventDate: fire,
            now: now,
            calendar: Self.calendar,
            homeTimeZone: Self.homeTimeZone,
            pendingFireDates: [identifier: fire]
        )
        #expect(hits.count == 1, "pending hit must survive the dome dedup")
        #expect(hits.first?.identifier == identifier)
    }

    @Test("dome dedup: same state but NO pending notification → hit dropped (post-delivery dedup intact)")
    func domeDedupDropsWhenNotPending() {
        let now = FixedClock(now: Self.midnight("2026-07-01")).now
        let forecast = [
            Self.day("2026-07-05", highF: 96),
            Self.day("2026-07-06", highF: 96),
            Self.day("2026-07-07", highF: 96),
            Self.day("2026-07-08", highF: 96),
        ]
        guard let fire = Self.calendar.date(
            bySettingHour: 19, minute: 0, second: 0,
            of: Self.midnight("2026-07-04"),
            matchingPolicy: .nextTime,
            repeatedTimePolicy: .first,
            direction: .forward
        ) else {
            Issue.record("calendar.date failure")
            return
        }
        let hits = HeatEvaluator.evaluate(
            forecast: forecast,
            thresholds: .kc,
            lastHeatDomeFireDate: fire,
            lastHeatEventDate: fire,
            now: now,
            calendar: Self.calendar,
            homeTimeZone: Self.homeTimeZone,
            pendingFireDates: [:]
        )
        #expect(hits.isEmpty, "delivered (no-longer-pending) dome hit must stay deduped")
    }

    @Test("dome dedup compares fire dates, not heatDate-vs-fireDate with abs()")
    func domeDedupUsesFireDateDomain() {
        let now = FixedClock(now: Self.midnight("2026-07-01")).now
        let forecast = [
            Self.day("2026-07-05", highF: 96),
            Self.day("2026-07-06", highF: 96),
            Self.day("2026-07-07", highF: 96),
            Self.day("2026-07-08", highF: 96),
        ]
        // lastDome AFTER this hit's fire date. The old abs(heatDate −
        // lastDome) treated this as inside the window and dropped the
        // hit; a fire-date-domain compare keeps it (negative delta —
        // this hit fires BEFORE the recorded dome, so it can't be a
        // duplicate of it).
        let lastDome = Self.midnight("2026-07-09")
        let hits = HeatEvaluator.evaluate(
            forecast: forecast,
            thresholds: .kc,
            lastHeatDomeFireDate: lastDome,
            lastHeatEventDate: lastDome,
            now: now,
            calendar: Self.calendar,
            homeTimeZone: Self.homeTimeZone
        )
        #expect(hits.count == 1, "hit firing before the recorded dome fire must not dedup")
    }

    @Test("dome dedup: fire 7+ days after the last dome fire is kept")
    func domeDedupExpiresAfter7Days() {
        let now = FixedClock(now: Self.midnight("2026-07-01")).now
        let forecast = [
            Self.day("2026-07-05", highF: 96),
            Self.day("2026-07-06", highF: 96),
            Self.day("2026-07-07", highF: 96),
            Self.day("2026-07-08", highF: 96),
        ]
        // Hit fires 2026-07-04 19:00; last dome fire 8+ days earlier.
        let lastDome = Self.midnight("2026-06-26")
        let hits = HeatEvaluator.evaluate(
            forecast: forecast,
            thresholds: .kc,
            lastHeatDomeFireDate: lastDome,
            lastHeatEventDate: lastDome,
            now: now,
            calendar: Self.calendar,
            homeTimeZone: Self.homeTimeZone
        )
        #expect(hits.count == 1)
    }

    // MARK: - Fire time (7pm evening BEFORE)

    @Test("fire time is 7pm home-TZ on prior calendar day")
    func fireTime7pmPriorEvening() {
        let now = FixedClock(now: Self.midnight("2026-07-01")).now
        let forecast = [
            Self.day("2026-07-05", highF: 95),
            Self.day("2026-07-06", highF: 95),
            Self.day("2026-07-07", highF: 95),
            Self.day("2026-07-08", highF: 95),
        ]
        let hits = HeatEvaluator.evaluate(
            forecast: forecast,
            thresholds: .kc,
            lastHeatDomeFireDate: nil,
            lastHeatEventDate: now.addingTimeInterval(-3 * 86_400),
            now: now,
            calendar: Self.calendar,
            homeTimeZone: Self.homeTimeZone
        )
        guard let hit = hits.first else {
            Issue.record("expected one heat-dome hit")
            return
        }
        let comps = Self.calendar.dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: hit.fireDate
        )
        // Heat dome starts 2026-07-05; fire should land 2026-07-04 19:00.
        #expect(comps.year == 2026)
        #expect(comps.month == 7)
        #expect(comps.day == 4)
        #expect(comps.hour == 19)
        #expect(comps.minute == 0)
    }

    // MARK: - Humid 95°F apparent 110°F fires (dome OR extreme path)

    @Test("humid 95°F raw + 110°F apparent fires (dome path on 4-day run)")
    func humid95Apparent110Fires() {
        let now = FixedClock(now: Self.midnight("2026-07-01")).now
        // Real KC summer: 95°F + 70%RH → apparent 110°F. The 4-day run
        // alone fires the dome path; the higher apparent doesn't trigger
        // a second emission because dome coverage dedups the extreme path.
        let forecast = [
            Self.day("2026-07-05", highF: 95, apparentHighF: 110),
            Self.day("2026-07-06", highF: 95, apparentHighF: 110),
            Self.day("2026-07-07", highF: 95, apparentHighF: 110),
            Self.day("2026-07-08", highF: 95, apparentHighF: 110),
        ]
        let hits = HeatEvaluator.evaluate(
            forecast: forecast,
            thresholds: .kc,
            lastHeatDomeFireDate: nil,
            lastHeatEventDate: now.addingTimeInterval(-3 * 86_400),
            now: now,
            calendar: Self.calendar,
            homeTimeZone: Self.homeTimeZone
        )
        // Exactly one hit: the dome covers all 4 days so the extreme path
        // doesn't double-emit on the same day.
        #expect(hits.count == 1)
        #expect(hits.first?.variant == .heatDomeStarting)
    }

    // MARK: - Dry 95°F apparent 95°F does NOT fire (raw stays below dome floor on 1 day)

    @Test("dry 95°F raw + 95°F apparent does NOT fire (no dome, apparent < 100)")
    func dry95Apparent95DoesNotFire() {
        let now = FixedClock(now: Self.midnight("2026-07-01")).now
        let forecast = [
            Self.day("2026-07-05", highF: 95, apparentHighF: 95),
            // Only ONE 95°F day — no dome. Apparent 95 < 100 → no extreme.
            Self.day("2026-07-06", highF: 80, apparentHighF: 80),
            Self.day("2026-07-07", highF: 80, apparentHighF: 80),
        ]
        let hits = HeatEvaluator.evaluate(
            forecast: forecast,
            thresholds: .kc,
            lastHeatDomeFireDate: nil,
            lastHeatEventDate: now.addingTimeInterval(-3 * 86_400),
            now: now,
            calendar: Self.calendar,
            homeTimeZone: Self.homeTimeZone
        )
        #expect(hits.isEmpty)
    }
}
