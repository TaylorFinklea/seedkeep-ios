import Testing
import Foundation
import SwiftData
@preconcurrency import UserNotifications
@testable import Seedkeep

/// Layer 2 — service-integration tests for `WeatherWarningsService`. The
/// service is an `actor` (NOT `@MainActor`), so this suite is also NOT
/// `@MainActor`; tests `await` into the actor and into the `@MainActor`
/// init. Mocks live in `SeedkeepTests/Mocks/`.
///
/// Each test injects:
///   - `MockWeatherProvider` — canned forecast + observed fixtures
///   - `MockNotificationScheduler` — virtual pending set + recorders
///   - `StubPlantingEventQuery` — configurable active count
///   - `MockWateringStateClient` — recorded GET/PUT
///   - `FixedClock` — deterministic `now`
///
/// Spec: `.docs/ai/specs/2026-06-07-phase-4c-native-warnings-design.md`
/// §6 (Refresh model) + §11 (Layer 2 — WeatherWarningsServiceTests).
@Suite("WeatherWarningsService — Phase 4C service integration", .serialized)
struct WeatherWarningsServiceTests {

    // MARK: - Test environment

    private static let homeTimeZone = TimeZone(identifier: "America/Chicago")!
    private static let householdID = "hh_test_4c"

    /// Anchor `now` to 2026-07-15 03:00 home-TZ (well before the 8am
    /// watering fire window; also avoids the 2h staleness gate on
    /// `.foreground`).
    private static var anchorNow: Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = homeTimeZone
        let comps = DateComponents(
            calendar: cal, timeZone: homeTimeZone,
            year: 2026, month: 7, day: 15, hour: 3, minute: 0
        )
        return cal.date(from: comps) ?? Date()
    }

    @MainActor
    private static func makeContainer() -> ModelContainer {
        // Production model list — a test-only schema once masked the
        // LocalForecastSnapshot registration gap (see SeedkeepSchema).
        let schema = Schema(SeedkeepSchema.all)
        let config = ModelConfiguration(
            "weatherWarningsServiceTests-\(UUID().uuidString)",
            schema: schema,
            isStoredInMemoryOnly: true
        )
        return try! ModelContainer(for: schema, configurations: config)
    }

    /// Bundle of mocks + service under test. Avoids re-typing the
    /// `WeatherWarningsService` constructor in every test.
    struct Harness {
        let service: WeatherWarningsService
        let provider: MockWeatherProvider
        let scheduler: MockNotificationScheduler
        let planting: StubPlantingEventQuery
        let watering: MockWateringStateClient
        let container: ModelContainer
    }

    @MainActor
    private static func makeHarness(
        now: Date = anchorNow,
        coords: (lat: Double?, lon: Double?) = (39.0997, -94.5786),
        toggles: (frost: Bool, heat: Bool, water: Bool) = (true, true, true),
        householdID: String? = householdID,
        activeCount: Int = 1,
        /// Override for tests that mutate toggles mid-refresh; defaults
        /// to a constant closure over `toggles`.
        togglesProvider: (@MainActor () -> (frost: Bool, heat: Bool, water: Bool))? = nil
    ) -> Harness {
        let container = makeContainer()
        let provider = MockWeatherProvider()
        provider.setHomeTimeZone(homeTimeZone)
        let scheduler = MockNotificationScheduler()
        scheduler.setAuthorizationStatus(.authorized)
        let planting = StubPlantingEventQuery(activeCount: activeCount)
        let watering = MockWateringStateClient()
        let clock = FixedClock(now: now)
        let service = WeatherWarningsService(
            container: container,
            provider: provider,
            scheduler: scheduler,
            planting: planting,
            wateringState: watering,
            clock: clock,
            thresholds: .kc,
            householdIDProvider: { householdID },
            preferencesProvider: { coords },
            togglesProvider: togglesProvider ?? { toggles }
        )
        return Harness(
            service: service,
            provider: provider,
            scheduler: scheduler,
            planting: planting,
            watering: watering,
            container: container
        )
    }

    // MARK: - Forecast fixtures

    /// 10-day cold forecast — 28°F lows trigger frost. Centered at `now`.
    private static func coldForecast(start: Date) -> [DailyWeather] {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = homeTimeZone
        var forecast: [DailyWeather] = []
        for offset in 1...10 {
            guard let d = cal.date(byAdding: .day, value: offset, to: start) else {
                continue
            }
            forecast.append(DailyWeather(
                date: d,
                lowF: 28,
                highF: 50,
                precipMM: 0,
                rainMM: 0,
                apparentHighF: 50,
                precipitationChance: 0,
                humidity: 0,
                windMPH: 0
            ))
        }
        return forecast
    }

    /// Dry warm 10-day forecast — no triggers, but enough valid days that
    /// water-suppression doesn't kick in.
    private static func benignForecast(start: Date) -> [DailyWeather] {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = homeTimeZone
        var forecast: [DailyWeather] = []
        for offset in 1...10 {
            guard let d = cal.date(byAdding: .day, value: offset, to: start) else {
                continue
            }
            forecast.append(DailyWeather(
                date: d,
                lowF: 55,
                highF: 78,
                precipMM: 0,
                rainMM: 0,
                apparentHighF: 78,
                precipitationChance: 0,
                humidity: 0,
                windMPH: 0
            ))
        }
        return forecast
    }

    // MARK: - .successNoWarnings (all toggles off)

    @Test("all toggles off → successNoWarnings, no provider fetch")
    func allTogglesOff() async {
        let harness = await Self.makeHarness(toggles: (false, false, false))
        let outcome = await harness.service.refreshAll(reason: .test)
        if case .successNoWarnings = outcome {
            // OK
        } else {
            Issue.record("expected .successNoWarnings, got \(outcome)")
        }
        #expect(harness.provider.recordedFetchCount == 0)
    }

    // MARK: - .missingLocation clears prefixes

    @Test("missing coords → missingLocation; pending prefixes cleared")
    func missingLocationClears() async {
        let harness = await Self.makeHarness(coords: (nil, nil))
        // Seed a legacy frost notification so we can verify it gets cleared.
        let req = UNNotificationRequest(
            identifier: "seedkeep.notif.frost.2026-02-15",
            content: UNMutableNotificationContent(),
            trigger: nil
        )
        harness.scheduler.seedPending([req])
        let outcome = await harness.service.refreshAll(reason: .test)
        if case .missingLocation = outcome {
            // OK
        } else {
            Issue.record("expected .missingLocation, got \(outcome)")
        }
        #expect(harness.scheduler.pendingSnapshot.isEmpty)
    }

    // MARK: - .noActivePlantings

    @Test("zero active plantings → noActivePlantings, no provider fetch, prefixes cleared")
    func noActivePlantingsShortCircuits() async {
        let harness = await Self.makeHarness(activeCount: 0)
        let req = UNNotificationRequest(
            identifier: "seedkeep.notif.frost.2026-02-15",
            content: UNMutableNotificationContent(),
            trigger: nil
        )
        harness.scheduler.seedPending([req])
        let outcome = await harness.service.refreshAll(reason: .test)
        if case .noActivePlantings = outcome {
            // OK
        } else {
            Issue.record("expected .noActivePlantings, got \(outcome)")
        }
        #expect(harness.provider.recordedFetchCount == 0)
        #expect(harness.scheduler.pendingSnapshot.isEmpty)
    }

    // MARK: - .permissionDenied

    @Test("authorizationStatus == .denied → permissionDenied; prefixes cleared")
    func permissionDeniedClears() async {
        let harness = await Self.makeHarness()
        harness.scheduler.setAuthorizationStatus(.denied)
        let req = UNNotificationRequest(
            identifier: "seedkeep.notif.frost.2026-02-15",
            content: UNMutableNotificationContent(),
            trigger: nil
        )
        harness.scheduler.seedPending([req])
        let outcome = await harness.service.refreshAll(reason: .test)
        if case .permissionDenied = outcome {
            // OK
        } else {
            Issue.record("expected .permissionDenied, got \(outcome)")
        }
        #expect(harness.scheduler.pendingSnapshot.isEmpty)
    }

    // MARK: - .provisionalDelivery

    @Test("provisional auth + any toggle on → provisionalDelivery")
    func provisionalDelivery() async {
        let harness = await Self.makeHarness()
        harness.scheduler.setAuthorizationStatus(.provisional)
        // Forecast that triggers a frost so the success path reaches the
        // provisional re-classification step.
        harness.provider.setForecast(Self.coldForecast(start: Self.anchorNow))
        let outcome = await harness.service.refreshAll(reason: .test)
        if case .provisionalDelivery = outcome {
            // OK
        } else {
            Issue.record("expected .provisionalDelivery, got \(outcome)")
        }
    }

    // MARK: - .weatherKitFailed (provider failure, no cache)

    @Test("WeatherKit failure + no cache → weatherKitFailed; pending NOT cleared")
    func weatherKitFailedPreservesPending() async {
        let harness = await Self.makeHarness()
        harness.provider.setFetchResult(.failed(message: "network", isUnauthorized: false))
        let req = UNNotificationRequest(
            identifier: "seedkeep.notif.frost.2026-02-15",
            content: UNMutableNotificationContent(),
            trigger: nil
        )
        harness.scheduler.seedPending([req])
        let outcome = await harness.service.refreshAll(reason: .test)
        if case .weatherKitFailed = outcome {
            // OK
        } else {
            Issue.record("expected .weatherKitFailed, got \(outcome)")
        }
        // Pending must survive a failed fetch.
        #expect(harness.scheduler.pendingSnapshot.count == 1)
    }

    // MARK: - .weatherKitUnauthorized

    @Test("WeatherKit unauthorized is distinct from failed")
    func weatherKitUnauthorizedDistinct() async {
        let harness = await Self.makeHarness()
        harness.provider.setFetchResult(.failed(message: "WK auth", isUnauthorized: true))
        let outcome = await harness.service.refreshAll(reason: .test)
        if case .weatherKitUnauthorized = outcome {
            // OK
        } else {
            Issue.record("expected .weatherKitUnauthorized, got \(outcome)")
        }
    }

    // MARK: - .weatherKitFailedUsingStale

    @Test("WeatherKit failure + stale snapshot < 72h → weatherKitFailedUsingStale")
    func weatherKitFailedUsingStale() async {
        let harness = await Self.makeHarness()
        // Provider returns .stale directly — service treats it as a usable
        // fallback path.
        harness.provider.setFetchResult(.stale(
            forecast: Self.coldForecast(start: Self.anchorNow),
            observed: [],
            homeTimeZone: Self.homeTimeZone,
            ageSeconds: 4 * 3_600
        ))
        let outcome = await harness.service.refreshAll(reason: .test)
        if case .weatherKitFailedUsingStale = outcome {
            // OK
        } else {
            Issue.record("expected .weatherKitFailedUsingStale, got \(outcome)")
        }
    }

    // MARK: - Successful frost path schedules frost notif

    @Test("frost-trigger forecast schedules a frost notification with .timeSensitive content")
    func frostPathSchedulesTimeSensitive() async {
        let harness = await Self.makeHarness()
        harness.provider.setForecast(Self.coldForecast(start: Self.anchorNow))
        _ = await harness.service.refreshAll(reason: .test)
        let adds = harness.scheduler.recordedAdds
        let frostAdds = adds.filter { $0.identifier.hasPrefix("seedkeep.notif.frost.") }
        #expect(!frostAdds.isEmpty, "expected at least one frost notification scheduled")
        if let first = frostAdds.first {
            #expect(first.content.interruptionLevel == .timeSensitive)
        }
    }

    // MARK: - Legacy frost ids preserved on upgrade — THE regression test

    @Test("legacy seedkeep.notif.frost.YMD ids preserved on first refresh (upgrade scenario)")
    func legacyFrostIdsPreserved() async {
        // Set "now" to 2026-02-10; the cold forecast triggers frost on
        // every day 2026-02-11..2026-02-20. Seed a pending frost for
        // 2026-02-12 with the EXACT body the service will rebuild.
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = Self.homeTimeZone
        let comps = DateComponents(
            calendar: cal, timeZone: Self.homeTimeZone,
            year: 2026, month: 2, day: 10, hour: 3, minute: 0
        )
        guard let now = cal.date(from: comps) else {
            Issue.record("calendar.date failure"); return
        }
        let harness = await Self.makeHarness(now: now)
        harness.provider.setForecast(Self.coldForecast(start: now))

        // Pre-seed legacy pending notif at "seedkeep.notif.frost.2026-02-12".
        // Build content/trigger so it matches what the service plans —
        // the diff-keep path requires identical body + fireDate.
        let content = UNMutableNotificationContent()
        content.title = WarningCopy.frostTitle
        // The forecast day is 2026-02-12 (now + 2 days); fireDate is
        // 2026-02-11 08:00. The body uses weekday of the FROST day.
        let weekdayFormatter = DateFormatter()
        weekdayFormatter.dateFormat = "EEEE"
        weekdayFormatter.locale = Locale(identifier: "en_US_POSIX")
        weekdayFormatter.timeZone = Self.homeTimeZone
        weekdayFormatter.calendar = cal
        let frostDate = cal.date(byAdding: .day, value: 2, to: now)!
        let weekday = weekdayFormatter.string(from: frostDate)
        content.body = WarningCopy.frostBody(weekday: weekday, lowF: 28)
        // fireDate: 2026-02-11 08:00 home-TZ.
        let fireComps = DateComponents(
            calendar: cal, timeZone: Self.homeTimeZone,
            year: 2026, month: 2, day: 11, hour: 8, minute: 0
        )
        var trigComps = cal.dateComponents([.year, .month, .day, .hour, .minute], from: cal.date(from: fireComps)!)
        trigComps.timeZone = Self.homeTimeZone
        let trigger = UNCalendarNotificationTrigger(dateMatching: trigComps, repeats: false)
        let legacy = UNNotificationRequest(
            identifier: "seedkeep.notif.frost.2026-02-12",
            content: content,
            trigger: trigger
        )
        harness.scheduler.seedPending([legacy])

        _ = await harness.service.refreshAll(reason: .test)

        // After refresh, the legacy id should still be present in pending
        // (service should NOT remove + re-add a matching plan).
        let pending = harness.scheduler.pendingSnapshot
        #expect(pending.contains(where: { $0.identifier == "seedkeep.notif.frost.2026-02-12" }))
    }

    // MARK: - Coalesce — 100 concurrent calls → 1 provider fetch

    @Test("100 concurrent refreshAll callers coalesce to 1 provider fetch")
    func coalesce100ConcurrentToOneFetch() async {
        let harness = await Self.makeHarness()
        harness.provider.setForecast(Self.benignForecast(start: Self.anchorNow))
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<100 {
                group.addTask {
                    _ = await harness.service.refreshAll(reason: .test)
                }
            }
        }
        #expect(harness.provider.recordedFetchCount == 1)
    }

    // MARK: - clearKind only removes one prefix

    @Test("clearKind(.water) removes only water-prefix pending; frost preserved")
    func clearKindOnlyClearsOnePrefix() async {
        let harness = await Self.makeHarness()
        let frost = UNNotificationRequest(
            identifier: "seedkeep.notif.frost.2026-02-12",
            content: UNMutableNotificationContent(),
            trigger: nil
        )
        let water = UNNotificationRequest(
            identifier: "seedkeep.notif.water.2026-07-15",
            content: UNMutableNotificationContent(),
            trigger: nil
        )
        harness.scheduler.seedPending([frost, water])
        await harness.service.clearKind(.water)
        let ids = harness.scheduler.pendingSnapshot.map(\.identifier)
        #expect(ids.contains("seedkeep.notif.frost.2026-02-12"))
        #expect(!ids.contains("seedkeep.notif.water.2026-07-15"))
    }

    // MARK: - Server watering state threaded into evaluator

    @Test("server watering GET success threaded into evaluator")
    func serverWateringGetThreaded() async {
        let harness = await Self.makeHarness()
        // Forecast: dry warm 10 days. Observed: 5 dry warm days. Both pass
        // history + warmth checks. Server GET returns a 2-days-ago
        // timestamp → evaluator should dedup → no water notif.
        let dryWarm = Self.dryWarmForecast(start: Self.anchorNow)
        let observed = Self.dryWarmObservations(endingAtYesterdayOf: Self.anchorNow)
        harness.provider.setForecast(dryWarm)
        harness.provider.setObserved(observed)
        let serverTimestamp = Self.anchorNow.addingTimeInterval(-2 * 86_400)
        harness.watering.setGetResult(.success(serverTimestamp))

        _ = await harness.service.refreshAll(reason: .test)

        // Verify GET was called with the expected householdID.
        #expect(harness.watering.recordedGets == [Self.householdID])
        // No water notif should have been scheduled (server dedup).
        let waterAdds = harness.scheduler.recordedAdds
            .filter { $0.identifier.hasPrefix("seedkeep.notif.water.") }
        #expect(waterAdds.isEmpty)
    }

    @Test("server watering POST after successful water schedule")
    func serverWateringPostAfterSchedule() async {
        let harness = await Self.makeHarness()
        let dryWarm = Self.dryWarmForecast(start: Self.anchorNow)
        let observed = Self.dryWarmObservations(endingAtYesterdayOf: Self.anchorNow)
        harness.provider.setForecast(dryWarm)
        harness.provider.setObserved(observed)
        // Server returns nil (no prior watering). Evaluator should fire
        // .dryStretchStarting → service should POST after add.
        harness.watering.setGetResult(.success(nil))

        _ = await harness.service.refreshAll(reason: .test)

        let waterAdds = harness.scheduler.recordedAdds
            .filter { $0.identifier.hasPrefix("seedkeep.notif.water.") }
        #expect(!waterAdds.isEmpty, "expected a water notification to be scheduled")
        #expect(!harness.watering.recordedPuts.isEmpty, "expected a server PUT after scheduling")
        if let put = harness.watering.recordedPuts.first {
            #expect(put.householdID == Self.householdID)
        }
    }

    @Test("server watering GET failure falls back to local snapshot")
    func serverWateringGetFailureFallsBack() async {
        let harness = await Self.makeHarness()
        let dryWarm = Self.dryWarmForecast(start: Self.anchorNow)
        let observed = Self.dryWarmObservations(endingAtYesterdayOf: Self.anchorNow)
        harness.provider.setForecast(dryWarm)
        harness.provider.setObserved(observed)
        struct NetworkError: Error {}
        harness.watering.setGetResult(.failure(NetworkError()))

        let outcome = await harness.service.refreshAll(reason: .test)

        // GET should have been attempted.
        #expect(harness.watering.recordedGets == [Self.householdID])
        // Local snapshot has no prior fire → water should still schedule.
        let waterAdds = harness.scheduler.recordedAdds
            .filter { $0.identifier.hasPrefix("seedkeep.notif.water.") }
        #expect(!waterAdds.isEmpty, "fallback should still schedule water; outcome=\(outcome)")
    }

    // MARK: - Heat-dome cancel-before-fire pair (activated by schema fix)

    @Test("heat-dome warning survives a second refresh — schedule-time dedup must not cancel the pending notification")
    func heatDomePendingSurvivesSecondRefresh() async {
        let harness = await Self.makeHarness(toggles: (false, true, false))
        harness.provider.setForecast(Self.hotDomeForecast(start: Self.anchorNow))

        _ = await harness.service.refreshAll(reason: .test)
        let heatIDs = harness.scheduler.pendingSnapshot
            .map(\.identifier)
            .filter { $0.hasPrefix("seedkeep.notif.heat.") }
        #expect(!heatIDs.isEmpty, "first refresh must schedule a dome warning")

        // The schema fix activates this persistence — the dedup input
        // must round-trip through the (production) schema, which is
        // exactly what re-arms the masked cancel bug on refresh 2.
        let container = harness.container
        let persistedDomeFire = await MainActor.run { () -> Date? in
            let context = ModelContext(container)
            let descriptor = FetchDescriptor<LocalForecastSnapshot>()
            return (try? context.fetch(descriptor))?.first?.lastHeatDomeFireDate
        }
        #expect(persistedDomeFire != nil, "lastHeatDomeFireDate must persist after the scheduling refresh")

        // Second refresh, unchanged forecast. THE regression: the
        // evaluator used to drop the just-scheduled hit as "already
        // acknowledged" and the diff cancelled the pending notification.
        _ = await harness.service.refreshAll(reason: .test)
        let after = Set(
            harness.scheduler.pendingSnapshot
                .map(\.identifier)
                .filter { $0.hasPrefix("seedkeep.notif.heat.") }
        )
        for id in heatIDs {
            #expect(after.contains(id), "pending heat warning \(id) was cancelled by the follow-up refresh")
        }
    }

    @Test("weather-warning state persists through the production schema (LocalForecastSnapshot registered)")
    func snapshotPersistsThroughSharedSchema() async {
        let harness = await Self.makeHarness()
        harness.provider.setForecast(Self.benignForecast(start: Self.anchorNow))
        _ = await harness.service.refreshAll(reason: .test)
        let container = harness.container
        let row = await MainActor.run { () -> (tz: String?, clock: Date?, outcome: String?)? in
            let context = ModelContext(container)
            let descriptor = FetchDescriptor<LocalForecastSnapshot>()
            guard let row = (try? context.fetch(descriptor))?.first else { return nil }
            return (row.sawTimeZoneIdentifier, row.sawClockAt, row.outcomeRaw)
        }
        #expect(row != nil, "refresh must create the singleton LocalForecastSnapshot row")
        #expect(row?.clock != nil)
        #expect(row?.outcome != nil)
    }

    // MARK: - Watering cancel-before-fire pair (second refresh w/ pending)

    @Test("watering reminder survives a second refresh that reads back the future ledger timestamp")
    func waterPendingSurvivesSecondRefresh() async {
        let harness = await Self.makeHarness(toggles: (false, false, true))
        harness.provider.setForecast(Self.dryWarmForecast(start: Self.anchorNow))
        harness.provider.setObserved(Self.dryWarmObservations(endingAtYesterdayOf: Self.anchorNow))
        harness.watering.setGetResult(.success(nil))

        _ = await harness.service.refreshAll(reason: .test)
        let waterIDs = harness.scheduler.pendingSnapshot
            .map(\.identifier)
            .filter { $0.hasPrefix("seedkeep.notif.water.") }
        #expect(!waterIDs.isEmpty, "first refresh must schedule a watering reminder")
        guard let put = harness.watering.recordedPuts.first else {
            Issue.record("first refresh must PUT the scheduled fireDate to the ledger")
            return
        }

        // THE regression: the ledger now holds the FUTURE scheduledFor;
        // the next refresh's GET returns it, the evaluator dedup-skipped,
        // and the diff removed the still-pending reminder — so nobody in
        // the household ever got it.
        harness.watering.setGetResult(.success(put.scheduledFor))
        _ = await harness.service.refreshAll(reason: .activePlantingsChanged)

        let after = Set(
            harness.scheduler.pendingSnapshot
                .map(\.identifier)
                .filter { $0.hasPrefix("seedkeep.notif.water.") }
        )
        for id in waterIDs {
            #expect(after.contains(id), "pending watering reminder \(id) was cancelled by the follow-up refresh")
        }
    }

    @Test("dedup-window skip KEEPS an existing pending water reminder (sibling future timestamp)")
    func dedupSkipKeepsPendingWaterReminder() async {
        let harness = await Self.makeHarness(toggles: (false, false, true))
        harness.provider.setForecast(Self.dryWarmForecast(start: Self.anchorNow))
        harness.provider.setObserved(Self.dryWarmObservations(endingAtYesterdayOf: Self.anchorNow))
        // A FUTURE household timestamp that does NOT match our pending
        // request (a sibling device scheduled its own reminder) →
        // evaluator dedup-skips. The skip must keep our pending reminder
        // rather than removing it: removal is only correct on an
        // affirmative no-trigger decision.
        harness.watering.setGetResult(.success(Self.anchorNow.addingTimeInterval(2 * 86_400)))

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = Self.homeTimeZone
        guard let pendingFire = cal.date(
            bySettingHour: 8, minute: 0, second: 0,
            of: cal.startOfDay(for: Self.anchorNow),
            matchingPolicy: .nextTime,
            repeatedTimePolicy: .first,
            direction: .forward
        ) else {
            Issue.record("calendar.date failure")
            return
        }
        let identifier = "seedkeep.notif.water."
            + Identifier.isoDay(pendingFire, in: Self.homeTimeZone)
        var trigComps = cal.dateComponents([.year, .month, .day, .hour, .minute], from: pendingFire)
        trigComps.timeZone = Self.homeTimeZone
        let pendingRequest = UNNotificationRequest(
            identifier: identifier,
            content: UNMutableNotificationContent(),
            trigger: UNCalendarNotificationTrigger(dateMatching: trigComps, repeats: false)
        )
        harness.scheduler.seedPending([pendingRequest])

        _ = await harness.service.refreshAll(reason: .test)

        let after = harness.scheduler.pendingSnapshot.map(\.identifier)
        #expect(after.contains(identifier), "dedup-window skip must not cancel the pending water reminder")
    }

    // MARK: - Frost pre-fire-buffer refresh keeps pending warning

    @Test("refresh inside the 15-min pre-fire buffer keeps the pending frost warning")
    func preFireBufferRefreshKeepsFrostWarning() async {
        // Now = 07:50; the 08:00 frost warning (for tomorrow's frost) is
        // pending. The buffer guard used to drop the hit from `planned`,
        // and the diff cancelled it ten minutes before it fired.
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = Self.homeTimeZone
        let nowComps = DateComponents(
            calendar: cal, timeZone: Self.homeTimeZone,
            year: 2026, month: 7, day: 15, hour: 7, minute: 50
        )
        let fireComps = DateComponents(
            calendar: cal, timeZone: Self.homeTimeZone,
            year: 2026, month: 7, day: 15, hour: 8, minute: 0
        )
        guard let now = cal.date(from: nowComps),
              let pendingFire = cal.date(from: fireComps) else {
            Issue.record("calendar.date failure")
            return
        }
        let harness = await Self.makeHarness(now: now, toggles: (true, false, false))
        harness.provider.setForecast(Self.coldForecast(start: now))

        let identifier = "seedkeep.notif.frost.2026-07-16"
        var trigComps = cal.dateComponents([.year, .month, .day, .hour, .minute], from: pendingFire)
        trigComps.timeZone = Self.homeTimeZone
        let pendingRequest = UNNotificationRequest(
            identifier: identifier,
            content: UNMutableNotificationContent(),
            trigger: UNCalendarNotificationTrigger(dateMatching: trigComps, repeats: false)
        )
        harness.scheduler.seedPending([pendingRequest])

        _ = await harness.service.refreshAll(reason: .test)

        let after = harness.scheduler.pendingSnapshot.map(\.identifier)
        #expect(after.contains(identifier), "pre-fire-buffer refresh must not cancel the pending frost warning")
    }

    // MARK: - TZ-change clear deferred until a usable forecast (never clear on failure)

    /// Seed the singleton snapshot row so the next refresh detects a
    /// timezone change (persisted TZ ≠ device TZ). `sawClockAt` is set to
    /// `now` so the clock-skew detector stays quiet.
    @MainActor
    private static func seedSnapshotRow(
        in container: ModelContainer,
        sawTimeZoneIdentifier: String,
        sawClockAt: Date
    ) {
        let context = ModelContext(container)
        let row = LocalForecastSnapshot()
        row.sawTimeZoneIdentifier = sawTimeZoneIdentifier
        row.sawClockAt = sawClockAt
        context.insert(row)
        try? context.save()
    }

    @Test("TZ change + failed fetch leaves pending warnings untouched (clear only after success)")
    func tzChangeFailedFetchPreservesPending() async {
        let harness = await Self.makeHarness()
        await Self.seedSnapshotRow(
            in: harness.container,
            sawTimeZoneIdentifier: "Pacific/Honolulu",
            sawClockAt: Self.anchorNow
        )
        harness.provider.setFetchResult(.failed(message: "airplane mode", isUnauthorized: false))
        let req = UNNotificationRequest(
            identifier: "seedkeep.notif.frost.2026-07-20",
            content: UNMutableNotificationContent(),
            trigger: nil
        )
        harness.scheduler.seedPending([req])

        let outcome = await harness.service.refreshAll(reason: .timeZoneChange)

        if case .weatherKitFailed = outcome {
            // OK
        } else {
            Issue.record("expected .weatherKitFailed, got \(outcome)")
        }
        #expect(
            harness.scheduler.pendingSnapshot.count == 1,
            "TZ-change refresh must NOT clear pending warnings when the fetch fails"
        )
    }

    @Test("TZ change + successful fetch rebuilds: stale pending cleared, fresh warnings scheduled")
    func tzChangeSuccessfulFetchRebuilds() async {
        let harness = await Self.makeHarness()
        await Self.seedSnapshotRow(
            in: harness.container,
            sawTimeZoneIdentifier: "Pacific/Honolulu",
            sawClockAt: Self.anchorNow
        )
        harness.provider.setForecast(Self.coldForecast(start: Self.anchorNow))
        // A stale id the new plan won't contain — the rebuild must sweep it.
        let stale = UNNotificationRequest(
            identifier: "seedkeep.notif.frost.2026-02-15",
            content: UNMutableNotificationContent(),
            trigger: nil
        )
        harness.scheduler.seedPending([stale])

        _ = await harness.service.refreshAll(reason: .timeZoneChange)

        let ids = harness.scheduler.pendingSnapshot.map(\.identifier)
        #expect(!ids.contains("seedkeep.notif.frost.2026-02-15"), "stale pre-TZ-change id must be swept")
        #expect(ids.contains { $0.hasPrefix("seedkeep.notif.frost.") }, "fresh warnings must be scheduled")
    }

    @Test("stale-forecast path persists the DEVICE timezone, not the cached forecast's old TZ")
    func stalePathPersistsDeviceTZ() async {
        let harness = await Self.makeHarness()
        await Self.seedSnapshotRow(
            in: harness.container,
            sawTimeZoneIdentifier: "Pacific/Honolulu",
            sawClockAt: Self.anchorNow
        )
        // Cached snapshot still carries the OLD timezone. Persisting it
        // re-armed tzChanged on every refresh — each one clearing and
        // re-adding the pending set until a fresh fetch landed.
        harness.provider.setFetchResult(.stale(
            forecast: Self.benignForecast(start: Self.anchorNow),
            observed: [],
            homeTimeZone: TimeZone(identifier: "Pacific/Honolulu")!,
            ageSeconds: 4 * 3_600
        ))

        _ = await harness.service.refreshAll(reason: .timeZoneChange)

        let container = harness.container
        let persistedTZ = await MainActor.run { () -> String? in
            let context = ModelContext(container)
            let descriptor = FetchDescriptor<LocalForecastSnapshot>()
            return (try? context.fetch(descriptor))?.first?.sawTimeZoneIdentifier
        }
        #expect(
            persistedTZ == TimeZone.current.identifier,
            "persisted TZ must be the device's, else tzChanged re-arms every refresh"
        )
    }

    // MARK: - State-changing refresh reasons must not coalesce into stale in-flight refresh

    @MainActor
    private final class TogglesBox {
        var value: (frost: Bool, heat: Bool, water: Bool)
        init(_ value: (frost: Bool, heat: Bool, water: Bool)) {
            self.value = value
        }
    }

    @Test("toggle-enable refresh re-runs after the in-flight refresh instead of absorbing its stale result")
    func stateChangingReasonRerunsAfterInFlight() async {
        let box = await MainActor.run { TogglesBox((frost: false, heat: true, water: false)) }
        let harness = await Self.makeHarness(togglesProvider: { box.value })
        harness.provider.setForecast(Self.coldForecast(start: Self.anchorNow))
        harness.provider.setFetchDelay(nanoseconds: 300_000_000)

        // Refresh A starts with frost OFF and stalls in the fetch.
        let first = Task { await harness.service.refreshAll(reason: .test) }
        try? await Task.sleep(nanoseconds: 100_000_000)

        // User flips frost ON mid-flight; the toggle-enable refresh must
        // NOT return refresh A's outcome (computed with frost off).
        await MainActor.run { box.value = (frost: true, heat: true, water: false) }
        harness.provider.setFetchDelay(nanoseconds: 0)
        _ = await harness.service.refreshAll(reason: .toggleEnable(.frost))
        _ = await first.value

        #expect(harness.provider.recordedFetchCount == 2, "state-changing reason must run a fresh refresh")
        let frostAdds = harness.scheduler.recordedAdds
            .filter { $0.identifier.hasPrefix("seedkeep.notif.frost.") }
        #expect(!frostAdds.isEmpty, "the re-run refresh must see the newly enabled frost toggle")
    }

    // MARK: - Settings "weather watch" counts kept warnings (not just adds)

    @Test("keep-path refresh still reports .success — kept pending warnings count toward scheduledByKind")
    func keptWarningsCountedInOutcome() async {
        let harness = await Self.makeHarness(toggles: (true, false, false))
        harness.provider.setForecast(Self.coldForecast(start: Self.anchorNow))

        let first = await harness.service.refreshAll(reason: .test)
        guard case .success(let firstByKind, _) = first, (firstByKind[.frost] ?? 0) > 0 else {
            Issue.record("first refresh should report .success with frost warnings, got \(first)")
            return
        }

        // Second refresh, unchanged forecast: the diff keeps every pending
        // warning, toAdd is empty — Settings used to render "No frost in
        // the next 10 days." while a frost warning sat pending.
        let second = await harness.service.refreshAll(reason: .test)
        if case .success(let byKind, _) = second {
            #expect((byKind[.frost] ?? 0) > 0, "kept frost warnings must be counted")
        } else {
            Issue.record("keep-path refresh must report .success, got \(second)")
        }
    }

    // MARK: - Permission-regrant staleness bypass (producer)

    @Test("denied→granted transition bypasses the 2h staleness gate; steady-state stays gated")
    func permissionRegrantBypassesStalenessGate() async {
        let harness = await Self.makeHarness()
        harness.provider.setForecast(Self.benignForecast(start: Self.anchorNow))

        // 1. Successful refresh while authorized — sets lastSuccessAt and
        //    persists lastAuthStatusRaw = authorized.
        _ = await harness.service.refreshAll(reason: .test)
        #expect(harness.provider.recordedFetchCount == 1)

        // 2. User denies notifications in iOS Settings; a refresh records
        //    the denied status (and clears pending warnings).
        harness.scheduler.setAuthorizationStatus(.denied)
        let denied = await harness.service.refreshAll(reason: .manualRefresh)
        guard case .permissionDenied = denied else {
            Issue.record("expected .permissionDenied, got \(denied)")
            return
        }

        // 3. User re-grants. A .foreground refresh lands inside the 2h
        //    gate (FixedClock — zero seconds since lastSuccessAt); the
        //    denied→authorized transition must bypass it.
        harness.scheduler.setAuthorizationStatus(.authorized)
        let outcome = await harness.service.refreshAllIfStale(reason: .foreground)
        #expect(outcome != nil, "permission re-grant must bypass the staleness gate")
        #expect(harness.provider.recordedFetchCount == 2, "the bypass refresh must actually run")

        // 4. Steady state: persisted status is now authorized, so the
        //    next foreground refresh inside the gate is suppressed again.
        let suppressed = await harness.service.refreshAllIfStale(reason: .foreground)
        #expect(suppressed == nil, "no transition → the 2h gate applies as before")
        #expect(harness.provider.recordedFetchCount == 2)
    }

    /// 4-day dome (96°F) starting the day after `start`, then mild days.
    private static func hotDomeForecast(start: Date) -> [DailyWeather] {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = homeTimeZone
        var forecast: [DailyWeather] = []
        for offset in 1...10 {
            guard let d = cal.date(byAdding: .day, value: offset, to: start) else {
                continue
            }
            let hot = offset <= 4
            forecast.append(DailyWeather(
                date: d,
                lowF: hot ? 78 : 60,
                highF: hot ? 96 : 78,
                precipMM: 0,
                rainMM: 0,
                apparentHighF: hot ? 96 : 78,
                precipitationChance: 0,
                humidity: 0,
                windMPH: 0
            ))
        }
        return forecast
    }

    // MARK: - Dry warm fixtures (used by watering tests above)

    private static func dryWarmForecast(start: Date) -> [DailyWeather] {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = homeTimeZone
        var forecast: [DailyWeather] = []
        for offset in 0..<10 {
            guard let d = cal.date(byAdding: .day, value: offset, to: start) else {
                continue
            }
            forecast.append(DailyWeather(
                date: d,
                lowF: 65,
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

    private static func dryWarmObservations(endingAtYesterdayOf now: Date) -> [ObservedDay] {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = homeTimeZone
        guard let yesterday = cal.date(byAdding: .day, value: -1, to: now) else {
            return []
        }
        var days: [ObservedDay] = []
        for offset in 0..<5 {
            guard let d = cal.date(byAdding: .day, value: -offset, to: yesterday) else {
                continue
            }
            days.append(ObservedDay(
                date: d, rainMM: 0, highF: 90, humidity: 0, windMPH: 0
            ))
        }
        return days
    }
}
