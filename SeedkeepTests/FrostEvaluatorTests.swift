import Testing
import Foundation
@testable import Seedkeep

/// Pure-evaluator tests for `FrostEvaluator.evaluate`. Every assertion
/// pins a single deterministic input — `FixedClock` + an explicit
/// `homeTimeZone` parameter — so the test outcome doesn't depend on the
/// host's wall clock or locale. Calendar math everywhere is `gregorian`,
/// matching the production evaluator's contract.
///
/// Spec: `.docs/ai/specs/2026-06-07-phase-4c-native-warnings-design.md`
/// §5 (frost semantics) + §11 (Layer 1 — FrostEvaluatorTests).
@Suite("FrostEvaluator — Phase 4C pure-evaluator")
struct FrostEvaluatorTests {

    // MARK: - Test environment

    /// All tests run in `America/Chicago` unless the test explicitly opts
    /// into a different zone (DST tests carry their own helpers).
    private static let homeTimeZone = TimeZone(identifier: "America/Chicago")!

    private static var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = homeTimeZone
        return cal
    }

    /// Midnight in `homeTimeZone` for the supplied YMD. Uses `guard let`
    /// per the project rule against force-unwrapping calendar math.
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

    /// Build a benign `DailyWeather` at home-TZ midnight on `ymd` with the
    /// supplied low. Other fields default to non-triggering values for the
    /// heat/water evaluators (which read this same shape).
    private static func day(
        _ ymd: String,
        lowF: Double,
        highF: Double = 60,
        in tz: TimeZone = homeTimeZone
    ) -> DailyWeather {
        DailyWeather(
            date: midnight(ymd, in: tz),
            lowF: lowF,
            highF: highF,
            precipMM: 0,
            rainMM: 0,
            apparentHighF: highF,
            precipitationChance: 0,
            humidity: 0,
            windMPH: 0
        )
    }

    // MARK: - Strict-less-than boundary (32.9°F fires; 33.0°F doesn't)

    @Test("32.9°F fires (strict less than threshold)")
    func boundary32_9Fires() {
        let now = FixedClock(now: Self.midnight("2026-02-10")).now
        let forecast = [Self.day("2026-02-12", lowF: 32.9)]
        let hits = FrostEvaluator.evaluate(
            forecast: forecast,
            thresholdF: 33.0,
            now: now,
            calendar: Self.calendar,
            homeTimeZone: Self.homeTimeZone
        )
        #expect(hits.count == 1)
        #expect(hits.first?.lowF == 32.9)
    }

    @Test("33.0°F does NOT fire (boundary is strict <)")
    func boundary33_0DoesNotFire() {
        let now = FixedClock(now: Self.midnight("2026-02-10")).now
        let forecast = [Self.day("2026-02-12", lowF: 33.0)]
        let hits = FrostEvaluator.evaluate(
            forecast: forecast,
            thresholdF: 33.0,
            now: now,
            calendar: Self.calendar,
            homeTimeZone: Self.homeTimeZone
        )
        #expect(hits.isEmpty)
    }

    // MARK: - Spring-forward DST fireDate is 8am in home-TZ

    @Test("DST spring-forward: fireDate is 8am home-TZ on prior day")
    func springForwardFireDateIs8amHomeTZ() {
        // US DST 2026 spring-forward = 2026-03-08 02:00 → 03:00. A frost on
        // 2026-03-09 should still produce a fireDate at 8am home-TZ on the
        // 8th (i.e., post-jump 13:00 UTC, which is 8am Chicago CDT).
        let now = FixedClock(now: Self.midnight("2026-03-01")).now
        let frostDay = Self.day("2026-03-09", lowF: 28.0)
        let hits = FrostEvaluator.evaluate(
            forecast: [frostDay],
            thresholdF: 33.0,
            now: now,
            calendar: Self.calendar,
            homeTimeZone: Self.homeTimeZone
        )
        guard let hit = hits.first else {
            Issue.record("expected one hit for spring-forward frost test")
            return
        }
        // Re-derive 8am Chicago time on 2026-03-08 in the home-TZ calendar.
        let comps = Self.calendar.dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: hit.fireDate
        )
        #expect(comps.year == 2026)
        #expect(comps.month == 3)
        #expect(comps.day == 8)
        #expect(comps.hour == 8)
        #expect(comps.minute == 0)
    }

    // MARK: - Body byte-for-byte (frost-body lock)

    @Test("frost body matches shipped string byte-for-byte")
    func frostBodyShippedStringByteForByte() {
        // The shipped string was: "Saturday night drops to 30°F. Cover
        // tender plants or pull tender seedlings inside." — Phase 4C must
        // preserve this verbatim or pending build-39 notifications get
        // rebuilt unnecessarily.
        let body = WarningCopy.frostBody(weekday: "Saturday", lowF: 30)
        #expect(body == "Saturday night drops to 30°F. Cover tender plants or pull tender seedlings inside.")
    }

    // MARK: - Rounding (32.5°F → 33°F via .awayFromZero)

    @Test("body rounding: 32.5°F renders as 33°F (.awayFromZero)")
    func bodyRoundingAwayFromZero() {
        let rounded = Int((32.5).rounded(.awayFromZero))
        #expect(rounded == 33)
        let body = WarningCopy.frostBody(weekday: "Friday", lowF: rounded)
        #expect(body == "Friday night drops to 33°F. Cover tender plants or pull tender seedlings inside.")
    }

    // MARK: - Past-fireDate filter (15-min buffer)

    @Test("past fireDate is filtered (5h-ago frost emits no hit)")
    func pastFireDateFiltered() {
        // Now = 2026-02-12 13:00 home-TZ. Frost on 2026-02-12 (today) would
        // schedule for 2026-02-11 08:00 — well in the past.
        let cal = Self.calendar
        let comps = DateComponents(
            calendar: cal, timeZone: Self.homeTimeZone,
            year: 2026, month: 2, day: 12, hour: 13, minute: 0
        )
        guard let now = cal.date(from: comps) else {
            Issue.record("could not construct test now")
            return
        }
        let forecast = [Self.day("2026-02-12", lowF: 28.0)]
        let hits = FrostEvaluator.evaluate(
            forecast: forecast,
            thresholdF: 33.0,
            now: now,
            calendar: cal,
            homeTimeZone: Self.homeTimeZone
        )
        #expect(hits.isEmpty)
    }

    @Test("fireDate 59s past the buffer keeps the canonical 8am; inside the buffer falls back to ASAP")
    func fireBufferBoundary() {
        let cal = Self.calendar
        // Build "now" = 2026-02-11 07:44:01 home-TZ.
        // A frost on 2026-02-12 schedules at 2026-02-11 08:00:00.
        // earliestFire = now + 15*60 = 2026-02-11 07:59:01.
        // 08:00:00 > 07:59:01 → 59 seconds head-room → canonical fire.
        let beforeBuffer = DateComponents(
            calendar: cal, timeZone: Self.homeTimeZone,
            year: 2026, month: 2, day: 11, hour: 7, minute: 44, second: 1
        )
        guard let nowOutsideBuffer = cal.date(from: beforeBuffer) else {
            Issue.record("could not construct nowOutsideBuffer")
            return
        }
        // Opposite case: now = 2026-02-11 07:46:00 home-TZ (14 minutes
        // before 08:00); earliestFire = 08:01:00 — the canonical fire is
        // inside the buffer, the frost night is still ahead, and nothing
        // is pending → late-discovery ASAP fire at earliestFire.
        let withinBufferComps = DateComponents(
            calendar: cal, timeZone: Self.homeTimeZone,
            year: 2026, month: 2, day: 11, hour: 7, minute: 46, second: 0
        )
        guard let nowWithinBuffer = cal.date(from: withinBufferComps) else {
            Issue.record("could not construct nowWithinBuffer")
            return
        }
        let forecast = [Self.day("2026-02-12", lowF: 28.0)]
        let hitsInsideBuffer = FrostEvaluator.evaluate(
            forecast: forecast,
            thresholdF: 33.0,
            now: nowWithinBuffer,
            calendar: cal,
            homeTimeZone: Self.homeTimeZone
        )
        #expect(hitsInsideBuffer.count == 1)
        #expect(
            hitsInsideBuffer.first?.fireDate == nowWithinBuffer.addingTimeInterval(15 * 60),
            "late-discovered frost must fall back to an ASAP fire, not vanish"
        )

        let hitsOutsideBuffer = FrostEvaluator.evaluate(
            forecast: forecast,
            thresholdF: 33.0,
            now: nowOutsideBuffer,
            calendar: cal,
            homeTimeZone: Self.homeTimeZone
        )
        #expect(hitsOutsideBuffer.count == 1)
        let comps = cal.dateComponents([.hour, .minute], from: hitsOutsideBuffer.first?.fireDate ?? .distantPast)
        #expect(comps.hour == 8)
        #expect(comps.minute == 0)
    }

    // MARK: - Late discovery + pre-fire-buffer keep (cancel-before-fire fixes)

    @Test("frost first seen after the canonical fire time delivers ASAP while the frost night is ahead")
    func lateDiscoveryDeliversASAP() {
        // Now = 2026-02-11 14:00 home-TZ. Frost overnight into 2026-02-12;
        // the canonical fire (2026-02-11 08:00) already passed, but the
        // frost is ~10h away — "cover tender plants tonight" must still go
        // out instead of never warning at all.
        let cal = Self.calendar
        let comps = DateComponents(
            calendar: cal, timeZone: Self.homeTimeZone,
            year: 2026, month: 2, day: 11, hour: 14, minute: 0
        )
        guard let now = cal.date(from: comps) else {
            Issue.record("could not construct test now")
            return
        }
        let forecast = [Self.day("2026-02-12", lowF: 28.0)]
        let hits = FrostEvaluator.evaluate(
            forecast: forecast,
            thresholdF: 33.0,
            now: now,
            calendar: cal,
            homeTimeZone: Self.homeTimeZone
        )
        #expect(hits.count == 1)
        #expect(hits.first?.fireDate == now.addingTimeInterval(15 * 60))
        #expect(hits.first?.identifier == "seedkeep.notif.frost.2026-02-12")
    }

    @Test("refresh inside the pre-fire buffer keeps the already-pending fire date")
    func preFireBufferKeepsPendingFireDate() {
        // Now = 2026-02-11 07:50 home-TZ; the 08:00 warning is pending.
        // The evaluator must re-plan it with the PENDING fire date so the
        // diff keeps it — not drop it (cancel) or push it out to ASAP.
        let cal = Self.calendar
        let nowComps = DateComponents(
            calendar: cal, timeZone: Self.homeTimeZone,
            year: 2026, month: 2, day: 11, hour: 7, minute: 50
        )
        let fireComps = DateComponents(
            calendar: cal, timeZone: Self.homeTimeZone,
            year: 2026, month: 2, day: 11, hour: 8, minute: 0
        )
        guard let now = cal.date(from: nowComps),
              let pendingFire = cal.date(from: fireComps) else {
            Issue.record("could not construct dates")
            return
        }
        let identifier = "seedkeep.notif.frost.2026-02-12"
        let forecast = [Self.day("2026-02-12", lowF: 28.0)]
        let hits = FrostEvaluator.evaluate(
            forecast: forecast,
            thresholdF: 33.0,
            now: now,
            calendar: cal,
            homeTimeZone: Self.homeTimeZone,
            pendingFireDates: [identifier: pendingFire]
        )
        #expect(hits.count == 1)
        #expect(hits.first?.fireDate == pendingFire)
        #expect(hits.first?.identifier == identifier)
    }

    // MARK: - Identifier is home-TZ-bound

    @Test("identifier is seedkeep.notif.frost.<YMD-in-homeTZ>")
    func identifierShape() {
        let now = FixedClock(now: Self.midnight("2026-02-10")).now
        let forecast = [Self.day("2026-02-12", lowF: 28.0)]
        let hits = FrostEvaluator.evaluate(
            forecast: forecast,
            thresholdF: 33.0,
            now: now,
            calendar: Self.calendar,
            homeTimeZone: Self.homeTimeZone
        )
        #expect(hits.first?.identifier == "seedkeep.notif.frost.2026-02-12")
    }

    // MARK: - Non-gregorian calendar input: no crash

    @Test("Hebrew calendar input does not crash (guard let throughout)")
    func hebrewCalendarDoesNotCrash() {
        // Real production code injects gregorian + a home-TZ calendar. This
        // test confirms the evaluator's calendar-math guards survive a
        // non-Gregorian input — if any `Calendar.date(...)` ever returned
        // nil, the evaluator should `continue` rather than trap.
        var hebrew = Calendar(identifier: .hebrew)
        hebrew.timeZone = Self.homeTimeZone
        let now = FixedClock(now: Self.midnight("2026-02-10")).now
        let forecast = (0..<10).map {
            Self.day("2026-02-\(String(format: "%02d", 12 + $0))", lowF: 28.0)
        }
        // Must not crash.
        _ = FrostEvaluator.evaluate(
            forecast: forecast,
            thresholdF: 33.0,
            now: now,
            calendar: hebrew,
            homeTimeZone: Self.homeTimeZone
        )
    }

    // MARK: - DST-skipped hour: skipped, not crashed

    @Test("DST-skipped hour does not crash the evaluator")
    func dstSkippedHourGuard() {
        // 2026-03-08 02:00–03:00 doesn't exist in America/Chicago. The
        // evaluator schedules at 08:00, not 02:00 — so this test is
        // really a smoke test for the calendar-math guard against
        // pathological inputs (Lord_Howe's 30-minute DST jumps, for
        // instance, can yield surprising fire dates).
        var cal = Calendar(identifier: .gregorian)
        let lordHowe = TimeZone(identifier: "Australia/Lord_Howe")!
        cal.timeZone = lordHowe
        let now = FixedClock(now: Self.midnight("2026-04-01", in: lordHowe)).now
        let forecast = [Self.day("2026-04-05", lowF: 28.0, in: lordHowe)]
        // Must not crash even at the Lord_Howe boundary.
        let hits = FrostEvaluator.evaluate(
            forecast: forecast,
            thresholdF: 33.0,
            now: now,
            calendar: cal,
            homeTimeZone: lordHowe
        )
        // The evaluator either emits or skips — either way: no crash.
        #expect(hits.count <= 1)
    }
}
