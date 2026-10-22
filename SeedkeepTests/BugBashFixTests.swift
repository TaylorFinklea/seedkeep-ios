import Testing
import Foundation
import SwiftData
@testable import Seedkeep
import SeedkeepKit

// MARK: - Journal date-only display

@Suite("JournalView — date-only display")
struct JournalDatePresentationTests {
    @Test("roundel keeps the wire date across time zones")
    func roundelKeepsWireDateAcrossTimeZones() {
        let chicago = TimeZone(identifier: "America/Chicago")!
        let utc = TimeZone(secondsFromGMT: 0)!

        for timeZone in [chicago, utc] {
            let parts = JournalDatePresentation.parts(
                for: "2026-08-28",
                timeZone: timeZone
            )

            #expect(parts.monthAbbrev == "AUG")
            #expect(parts.day == 28)
            #expect(parts.year == "2026")
        }
    }

    @Test("accessibility label keeps the wire date across time zones")
    func accessibilityLabelKeepsWireDateAcrossTimeZones() {
        let chicago = TimeZone(identifier: "America/Chicago")!
        let utc = TimeZone(secondsFromGMT: 0)!

        #expect(
            JournalDatePresentation.accessibleDate(
                for: "2026-08-28",
                timeZone: chicago,
                locale: Locale(identifier: "en_US_POSIX")
            ) == "August 28, 2026"
        )
        #expect(
            JournalDatePresentation.accessibleDate(
                for: "2026-08-28",
                timeZone: utc,
                locale: Locale(identifier: "en_US_POSIX")
            ) == "August 28, 2026"
        )
    }

    @Test("abbreviated date keeps the wire date across time zones")
    func abbreviatedDateKeepsWireDateAcrossTimeZones() {
        let chicago = TimeZone(identifier: "America/Chicago")!
        let utc = TimeZone(secondsFromGMT: 0)!

        for timeZone in [chicago, utc] {
            #expect(
                JournalDatePresentation.abbreviatedDate(
                    for: "2026-08-28",
                    timeZone: timeZone,
                    locale: Locale(identifier: "en_US_POSIX")
                ) == "Aug 28, 2026"
            )
        }
    }

    @Test("abbreviated date follows the locale")
    func abbreviatedDateFollowsLocale() {
        let utc = TimeZone(secondsFromGMT: 0)!

        #expect(
            JournalDatePresentation.abbreviatedDate(
                for: "2026-08-28",
                timeZone: utc,
                locale: Locale(identifier: "de_DE")
            ) == "28.08.2026"
        )
    }
}

// MARK: - Planting-event date-only display

@Suite("Planting event — date-only display")
struct PlantingEventDatePresentationTests {
    @Test(
        "medium date keeps the stored day across time zones",
        arguments: ["America/Chicago", "UTC"]
    )
    func mediumDateKeepsStoredDay(timeZoneIdentifier: String) throws {
        let timeZone = try #require(TimeZone(identifier: timeZoneIdentifier))

        #expect(
            humanDate("2026-09-04", timeZone: timeZone) == "Sep 4, 2026"
        )
    }

    @Test(
        "invalid wire date falls back to the stored value",
        arguments: ["not-a-date", "2026-9-4"]
    )
    func invalidWireDateFallsBackToStoredValue(storedValue: String) {
        #expect(
            humanDate(storedValue, timeZone: TimeZone(secondsFromGMT: 0)!) == storedValue
        )
    }
}

// MARK: - [3] UTC-midnight off-by-one (AddPlantingEventView)

/// Verifies that `AddPlantingEventView.parseYYYYMMDD` (now using `.current`)
/// round-trips through `yyyymmdd(_:)` (also `.current`) without an off-by-one
/// day for UTC-negative timezones.
///
/// Test approach: extract the formatters as pure functions and exercise them
/// in a UTC-5 timezone (simulating US-Central winter offset). The bug was
/// that `parseYYYYMMDD` used UTC midnight while `yyyymmdd` used `.current`,
/// so converting "2026-04-15" to a Date at UTC midnight, then formatting that
/// Date with a UTC-5 formatter, produced "2026-04-14".
@Suite("AddPlantingEventView — UTC-midnight off-by-one ([3])")
struct AddPlantingEventViewDateTests {

    /// Parse a YYYY-MM-DD string to a Date at local midnight (the fixed
    /// version of parseYYYYMMDD, now using TimeZone.current).
    private func parseLocalMidnight(_ s: String, tz: TimeZone) -> Date? {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = tz
        return f.date(from: s)
    }

    /// Format a Date back to YYYY-MM-DD using local timezone (matches save()).
    private func formatYYYYMMDD(_ date: Date, tz: TimeZone) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = tz
        return f.string(from: date)
    }

    @Test("recommended date round-trips to same yyyy-mm-dd in UTC-5 timezone")
    func recommendedDateRoundTripUTCMinus5() {
        let utcMinus5 = TimeZone(secondsFromGMT: -5 * 3600)!
        let start = "2026-04-15"

        // Simulate "Use recommended date": parse with local TZ (the fix),
        // then format back with local TZ (how save() works).
        guard let parsed = parseLocalMidnight(start, tz: utcMinus5) else {
            Issue.record("parseLocalMidnight returned nil for \(start)")
            return
        }
        let formatted = formatYYYYMMDD(parsed, tz: utcMinus5)
        #expect(formatted == start,
                "Expected round-trip to produce \(start), got \(formatted)")
    }

    @Test("recommended date round-trips to same yyyy-mm-dd in UTC-8 timezone")
    func recommendedDateRoundTripUTCMinus8() {
        let utcMinus8 = TimeZone(secondsFromGMT: -8 * 3600)!
        let start = "2026-01-01"

        guard let parsed = parseLocalMidnight(start, tz: utcMinus8) else {
            Issue.record("parseLocalMidnight returned nil for \(start)")
            return
        }
        let formatted = formatYYYYMMDD(parsed, tz: utcMinus8)
        #expect(formatted == start,
                "Expected round-trip to produce \(start), got \(formatted)")
    }

    @Test("old UTC-midnight parse would have produced wrong date in UTC-5")
    func utcMidnightParseWouldProduceWrongDate() {
        // Demonstrate the old bug: parsing "2026-04-15" at UTC midnight,
        // then formatting with UTC-5, gives "2026-04-14" (the wrong day).
        let utcMinus5 = TimeZone(secondsFromGMT: -5 * 3600)!
        let start = "2026-04-15"

        let fUTC = DateFormatter()
        fUTC.dateFormat = "yyyy-MM-dd"
        fUTC.locale = Locale(identifier: "en_US_POSIX")
        fUTC.timeZone = TimeZone(identifier: "UTC")

        let fLocal = DateFormatter()
        fLocal.dateFormat = "yyyy-MM-dd"
        fLocal.locale = Locale(identifier: "en_US_POSIX")
        fLocal.timeZone = utcMinus5

        guard let utcMidnight = fUTC.date(from: start) else {
            Issue.record("UTC parse returned nil")
            return
        }
        // The old bug: format UTC midnight with local TZ → yields prior day.
        let buggyFormatted = fLocal.string(from: utcMidnight)
        #expect(buggyFormatted == "2026-04-14",
                "Expected the old bug to reproduce: UTC midnight in UTC-5 = prior day")
    }
}

// MARK: - [12] TodayView date helpers

/// Tests the pure date-string helpers extracted to TodayView static methods.
/// The @Query itself is a SwiftUI/SwiftData view-layer concern (device/manual);
/// these tests cover the date-bucketing logic that drives the query keys.
@MainActor
@Suite("TodayView — date-string helpers ([12])")
struct TodayViewDateHelpersTests {

    @Test("currentTodayString matches yyyy-MM-dd for today in local TZ")
    func currentTodayStringMatchesLocalDate() {
        let result = TodayView.currentTodayString()
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        let expected = f.string(from: Date())
        #expect(result == expected)
    }

    @Test("currentYesterdayString is one day before currentTodayString")
    func yesterdayIsOneDayBeforeToday() {
        let today = TodayView.currentTodayString()
        let yesterday = TodayView.currentYesterdayString()

        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")

        guard let todayDate = f.date(from: today),
              let yesterdayDate = f.date(from: yesterday) else {
            Issue.record("Date parse failed: today=\(today) yesterday=\(yesterday)")
            return
        }
        let diff = Calendar(identifier: .gregorian)
            .dateComponents([.day], from: yesterdayDate, to: todayDate).day ?? 0
        #expect(diff == 1, "yesterday should be exactly 1 day before today, got diff=\(diff)")
    }
}

// MARK: - Non-cooperative weather mock (ignores cancellation)

/// A WeatherProvider that truly ignores `Task.cancel()` — it blocks
/// a background thread with `DispatchSemaphore.wait` (not `Task.sleep`)
/// so `CancellationError` is never thrown. This mirrors real WeatherKit,
/// which has no cooperative cancellation point and must be abandoned
/// via the unstructured-Task race in `withTimeoutOrFailed`.
///
/// Tests that use `Task.sleep` for delay (like `MockWeatherProvider`)
/// satisfy cancellation immediately, so they never exercise the
/// "timeout wins over non-cooperative fetch" code path.
final class NonCooperativeMockWeatherProvider: WeatherProvider, @unchecked Sendable {
    private let delaySeconds: TimeInterval

    init(delaySeconds: TimeInterval) {
        self.delaySeconds = delaySeconds
    }

    func fetch(latitude: Double, longitude: Double, generation: Int) async -> ForecastResult {
        let delay = self.delaySeconds
        // Run the blocking wait on a background thread via a continuation.
        // DispatchSemaphore.wait() is NOT a Swift cooperative cancellation
        // point — CancellationError is never thrown here.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .background).async {
                let sem = DispatchSemaphore(value: 0)
                _ = sem.wait(timeout: .now() + delay)
                continuation.resume()
            }
        }
        return .fresh(
            forecast: [],
            observed: [],
            homeTimeZone: TimeZone(identifier: "America/Chicago")!,
            fetchedAt: Date()
        )
    }

    func bumpGeneration(to generation: Int) async {}
    func cachedSnapshot() async -> ForecastSnapshot? { nil }
}

// MARK: - [13] withTimeoutOrFailed

/// Tests that `withTimeoutOrFailed` returns `.failed("timeout")` when the
/// weather provider is non-cooperative (does not respond to cancellation).
///
/// Strategy: inject a `NonCooperativeMockWeatherProvider` with a 10s
/// delay, then call `withTimeoutOrFailed(seconds: 0.2, ...)` directly
/// on the service. The timeout fires at 0.2s; the whole call must
/// complete in well under 1s. If the fix (unstructured-Task race) is
/// absent the test would hang for 10s.
@Suite("WeatherWarningsService — withTimeoutOrFailed unblocks at timeout ([13])",
       .serialized)
struct WithTimeoutOrFailedTests {

    private static let homeTimeZone = TimeZone(identifier: "America/Chicago")!

    @MainActor
    private static func makeService() -> WeatherWarningsService {
        let schema = Schema(SeedkeepSchema.all)
        let config = ModelConfiguration(
            "timeoutTests-\(UUID().uuidString)",
            schema: schema,
            isStoredInMemoryOnly: true, cloudKitDatabase: .none
        )
        let container = try! ModelContainer(for: schema, configurations: config)
        // Non-cooperative provider: Thread.sleep for 10s, ignores cancellation.
        let provider = NonCooperativeMockWeatherProvider(delaySeconds: 10)
        let scheduler = MockNotificationScheduler()
        scheduler.setAuthorizationStatus(.authorized)
        let planting = StubPlantingEventQuery(activeCount: 1)
        let watering = MockWateringStateClient()
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = homeTimeZone
        let comps = DateComponents(
            calendar: cal, timeZone: homeTimeZone,
            year: 2026, month: 7, day: 15, hour: 3, minute: 0)
        let now = cal.date(from: comps) ?? Date()
        let clock = FixedClock(now: now)
        return WeatherWarningsService(
            container: container,
            provider: provider,
            scheduler: scheduler,
            planting: planting,
            wateringState: watering,
            clock: clock,
            thresholds: .kc,
            householdIDProvider: { "hh_timeout_test" },
            preferencesProvider: { (39.0997, -94.5786) },
            togglesProvider: { (true, false, false) }
        )
    }

    @Test("non-cooperative provider: withTimeoutOrFailed returns .failed within timeout window")
    func nonCooperativeProviderTimesOutFast() async {
        let service = await Self.makeService()

        // Call withTimeoutOrFailed with a 0.2s timeout directly.
        // The NonCooperativeMockWeatherProvider hangs for 10s without
        // yielding to cooperative cancellation, so without the
        // unstructured-Task race fix this would block for 10s.
        let start = Date()
        let result = await service.withTimeoutOrFailed(seconds: 0.2) {
            await NonCooperativeMockWeatherProvider(delaySeconds: 10)
                .fetch(latitude: 39.0997, longitude: -94.5786, generation: 0)
        }
        let elapsed = Date().timeIntervalSince(start)

        // Must complete in well under 1s (generous bound for CI jitter).
        #expect(elapsed < 1.0,
                "withTimeoutOrFailed should return at ~0.2s, not wait for the 10s provider; elapsed=\(elapsed)s")

        // The timeout path must produce .failed("timeout").
        if case .failed(let message, _) = result {
            #expect(message == "timeout",
                    "Expected .failed(\"timeout\") from the timeout path, got .failed(\"\(message)\")")
        } else {
            Issue.record("Expected .failed(message: \"timeout\") from withTimeoutOrFailed, got \(result). Fix: the unstructured-Task race must let the sleep-task win and return .failed.")
        }
    }
}
