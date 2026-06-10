import Testing
import Foundation
@testable import Seedkeep

/// Parameterized cross-timezone tests. Each zone exercises:
///   - Frost fireDate = 8am local home-TZ on prior day
///   - Heat fireDate  = 7pm local home-TZ on prior day
///   - Watering fireDate = 8am local home-TZ
///   - Identifier YMD computed in homeTZ (not device TZ)
///
/// `Lord_Howe` is included specifically because it observes a 30-minute
/// DST jump — the only IANA zone with that quirk. London + Honolulu +
/// Phoenix + Chicago round out a full set of DST/no-DST behavior.
///
/// Spec: `.docs/ai/specs/2026-06-07-phase-4c-native-warnings-design.md`
/// §11 (Layer 3 — TimezoneAndDSTTests).
@Suite("TimezoneAndDST — Phase 4C parameterized DST")
struct TimezoneAndDSTTests {

    /// Identifiers covered by the parameterized loops below.
    static let zoneIdentifiers: [String] = [
        "America/Chicago",
        "America/Phoenix",
        "Pacific/Honolulu",
        "Australia/Lord_Howe",
        "Europe/London",
    ]

    // MARK: - Helpers

    private static func calendar(in tz: TimeZone) -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        return cal
    }

    private static func midnight(
        year: Int, month: Int, day: Int,
        in tz: TimeZone
    ) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        let comps = DateComponents(
            calendar: cal, timeZone: tz,
            year: year, month: month, day: day
        )
        return cal.date(from: comps) ?? Date()
    }

    // MARK: - Frost: 8am home-TZ prior day

    @Test("frost fireDate is 8am home-TZ on prior day", arguments: zoneIdentifiers)
    func frostFireDate8amPerZone(zoneID: String) {
        guard let tz = TimeZone(identifier: zoneID) else {
            Issue.record("invalid TZ: \(zoneID)")
            return
        }
        let cal = Self.calendar(in: tz)
        // Schedule the test "now" a week before a known frost day so the
        // future-only buffer is comfortably cleared.
        let now = Self.midnight(year: 2026, month: 2, day: 1, in: tz)
        let frostDate = Self.midnight(year: 2026, month: 2, day: 10, in: tz)
        let forecast = [
            DailyWeather(
                date: frostDate,
                lowF: 28,
                highF: 50,
                precipMM: 0,
                rainMM: 0,
                apparentHighF: 50,
                precipitationChance: 0,
                humidity: 0,
                windMPH: 0
            )
        ]
        let hits = FrostEvaluator.evaluate(
            forecast: forecast,
            thresholdF: 33.0,
            now: now,
            calendar: cal,
            homeTimeZone: tz
        )
        guard let hit = hits.first else {
            Issue.record("expected frost hit in \(zoneID)")
            return
        }
        let comps = cal.dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: hit.fireDate
        )
        #expect(comps.year == 2026)
        #expect(comps.month == 2)
        #expect(comps.day == 9, "prior day must be 9 in \(zoneID)")
        #expect(comps.hour == 8, "fire hour must be 8am in \(zoneID)")
        // Lord_Howe DST observes a 30-minute jump but Feb is outside DST;
        // every zone here lands at minute 0.
        #expect(comps.minute == 0)
    }

    // MARK: - Heat: 7pm home-TZ prior day

    @Test("heat fireDate is 7pm home-TZ on prior day", arguments: zoneIdentifiers)
    func heatFireDate7pmPerZone(zoneID: String) {
        guard let tz = TimeZone(identifier: zoneID) else {
            Issue.record("invalid TZ: \(zoneID)")
            return
        }
        let cal = Self.calendar(in: tz)
        let now = Self.midnight(year: 2026, month: 7, day: 1, in: tz)
        // Build a 4-day dome starting 2026-07-10.
        var forecast: [DailyWeather] = []
        for offset in 0..<4 {
            let d = Self.midnight(year: 2026, month: 7, day: 10 + offset, in: tz)
            forecast.append(DailyWeather(
                date: d,
                lowF: 75,
                highF: 96,
                precipMM: 0,
                rainMM: 0,
                apparentHighF: 96,
                precipitationChance: 0,
                humidity: 0,
                windMPH: 0
            ))
        }
        let hits = HeatEvaluator.evaluate(
            forecast: forecast,
            thresholds: .kc,
            lastHeatDomeFireDate: nil,
            lastHeatEventDate: now.addingTimeInterval(-3 * 86_400),
            now: now,
            calendar: cal,
            homeTimeZone: tz
        )
        guard let hit = hits.first else {
            Issue.record("expected heat hit in \(zoneID)")
            return
        }
        let comps = cal.dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: hit.fireDate
        )
        #expect(comps.year == 2026)
        #expect(comps.month == 7)
        #expect(comps.day == 9, "prior day must be 9 in \(zoneID)")
        #expect(comps.hour == 19, "fire hour must be 7pm in \(zoneID)")
    }

    // MARK: - Water: 8am home-TZ today (or tomorrow if past)

    @Test("water fireDate is 8am home-TZ", arguments: zoneIdentifiers)
    func waterFireDate8amPerZone(zoneID: String) {
        guard let tz = TimeZone(identifier: zoneID) else {
            Issue.record("invalid TZ: \(zoneID)")
            return
        }
        let cal = Self.calendar(in: tz)
        // Anchor at 03:00 home-TZ so 8am today is still in the future.
        let comps = DateComponents(
            calendar: cal, timeZone: tz,
            year: 2026, month: 7, day: 15, hour: 3, minute: 0
        )
        guard let now = cal.date(from: comps) else {
            Issue.record("calendar.date failure"); return
        }
        // Build 5 dry warm observations and a 3-day dry forecast.
        guard let yesterday = cal.date(byAdding: .day, value: -1, to: now) else {
            Issue.record("calendar.date failure"); return
        }
        var byYMD: [String: ObservedDay] = [:]
        for offset in 0..<5 {
            guard let d = cal.date(byAdding: .day, value: -offset, to: yesterday) else { continue }
            let ymd = Identifier.isoDay(d, in: tz)
            byYMD[ymd] = ObservedDay(date: d, rainMM: 0, highF: 90, humidity: 0, windMPH: 0)
        }
        let past = PastObservations(byYMD: byYMD, firstObservationYMD: nil)
        var forecast: [DailyWeather] = []
        for offset in 0..<3 {
            guard let d = cal.date(byAdding: .day, value: offset, to: now) else { continue }
            forecast.append(DailyWeather(
                date: d, lowF: 70, highF: 88, precipMM: 0, rainMM: 0,
                apparentHighF: 88, precipitationChance: 0, humidity: 0, windMPH: 0
            ))
        }
        let decision = WaterEvaluator.evaluate(
            forecast: forecast,
            past: past,
            thresholds: .kc,
            householdLastWaterAt: nil,
            lastLocalFireDate: nil,
            now: now,
            calendar: cal,
            homeTimeZone: tz
        )
        guard case .notify(let fireDate, _, _) = decision else {
            Issue.record("expected .notify in \(zoneID); got \(decision)")
            return
        }
        let fireComps = cal.dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: fireDate
        )
        #expect(fireComps.hour == 8, "water fire hour must be 8am in \(zoneID)")
        #expect(fireComps.minute == 0)
    }

    // MARK: - Planting-event reminder: 7am wall-clock, DST-safe

    @Test("planting-event reminder fires at 7am wall-clock, including DST transition days", arguments: zoneIdentifiers)
    func eventReminderSevenAMWallClock(zoneID: String) {
        guard let tz = TimeZone(identifier: zoneID) else {
            Issue.record("invalid TZ: \(zoneID)")
            return
        }
        let cal = Self.calendar(in: tz)
        // US spring-forward (Mar 8) + fall-back (Nov 1), the southern-
        // hemisphere transitions Lord Howe observes (Apr 5 / Oct 4 — its
        // quirky 30-minute jump), and a plain mid-June day. The old
        // `startOfDay + 7h` math fired at 8am / 6am (or :30 offsets on
        // Lord Howe) on the transition days.
        let days: [(Int, Int, Int)] = [
            (2026, 3, 8),
            (2026, 11, 1),
            (2026, 4, 5),
            (2026, 10, 4),
            (2026, 6, 15),
        ]
        for (year, month, day) in days {
            let date = Self.midnight(year: year, month: month, day: day, in: tz)
            guard let fire = NotificationsCenter.reminderFireDate(onDayOf: date, calendar: cal) else {
                Issue.record("no fire date for \(year)-\(month)-\(day) in \(zoneID)")
                continue
            }
            let comps = cal.dateComponents([.year, .month, .day, .hour, .minute], from: fire)
            #expect(comps.hour == 7, "reminder must fire 7am wall-clock on \(year)-\(month)-\(day) in \(zoneID), got \(comps.hour ?? -1)")
            #expect(comps.minute == 0, "minute must be 0 on \(year)-\(month)-\(day) in \(zoneID)")
            #expect(comps.day == day, "reminder must stay on the planned day in \(zoneID)")
        }
    }

    // MARK: - Identifier YMD is home-TZ-bound

    @Test("identifier YMD is computed in home-TZ (not device-TZ)", arguments: zoneIdentifiers)
    func identifierYMDInHomeTZ(zoneID: String) {
        guard let tz = TimeZone(identifier: zoneID) else {
            Issue.record("invalid TZ: \(zoneID)")
            return
        }
        let cal = Self.calendar(in: tz)
        let now = Self.midnight(year: 2026, month: 2, day: 1, in: tz)
        let frostDate = Self.midnight(year: 2026, month: 2, day: 10, in: tz)
        let forecast = [
            DailyWeather(
                date: frostDate, lowF: 28, highF: 50, precipMM: 0, rainMM: 0,
                apparentHighF: 50, precipitationChance: 0, humidity: 0, windMPH: 0
            )
        ]
        let hits = FrostEvaluator.evaluate(
            forecast: forecast,
            thresholdF: 33.0,
            now: now,
            calendar: cal,
            homeTimeZone: tz
        )
        // Identifier must reflect the home-TZ YMD for the frost day.
        let expected = "seedkeep.notif.frost." + Identifier.isoDay(frostDate, in: tz)
        #expect(hits.first?.identifier == expected)
    }
}
