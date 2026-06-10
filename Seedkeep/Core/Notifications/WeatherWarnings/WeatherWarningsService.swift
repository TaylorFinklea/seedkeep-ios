import Foundation
import SwiftData
@preconcurrency import UserNotifications
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Cross-component notification name

extension Notification.Name {
    /// Posted by `SyncEngine` after every local create/update/delete of a
    /// planting event. The service's `start()` observer debounces these
    /// (300ms cancel-prior-Task) into a single `.activePlantingsChanged`
    /// refresh — a bulk-import of 100 events fans into one fetch.
    static let weatherWarningsActivePlantingsChanged =
        Notification.Name("WeatherWarningsActivePlantingsChanged")
}

// MARK: - Refresh reasons (eight trigger paths per spec §6)

/// Every refresh trigger carries a `RefreshReason` so the service can:
///   - decide whether to honor the 2h staleness gate (only `.foreground`),
///   - log telemetry per cause,
///   - and let tests assert which path produced a given outcome.
enum RefreshReason: Sendable, Equatable {
    case toggleEnable(WarningKind)
    case manualRefresh
    case foreground
    case activePlantingsChanged
    case locationChange
    case timeZoneChange
    case permissionRegranted
    case test
}

// MARK: - Refresh outcomes (thirteen cases per spec §4)

/// Discriminated outcome of a single refresh. Settings dispatches on this
/// to render an exact row (green ✓ / amber / rose). Outcome is also
/// persisted as a string on `LocalForecastSnapshot.outcomeRaw` to restore
/// the UI on cold-launch before the first refresh lands.
enum RefreshOutcome: Sendable, Equatable {
    case success(scheduledByKind: [WarningKind: Int], heldByBudget: Int)
    case successNoWarnings(perKindEmpty: [WarningKind: Bool])
    case noActivePlantings
    case missingLocation
    case permissionDenied(deepLinkURL: URL?)
    case provisionalDelivery
    case partialData(validDays: Int, droppedDays: Int, waterSuppressed: Bool)
    case clockSkew(jumpSeconds: TimeInterval)
    case weatherKitUnauthorized
    case weatherKitFailedUsingStale(ageSeconds: TimeInterval)
    case weatherKitFailed(message: String)
    case allSchedulingFailed(attempted: Int)
    case queueBudgetReachedWithDropped(scheduledByKind: [WarningKind: Int], droppedFurthestOut: Int)

    /// True for outcomes that should bump `Projection.lastSuccessAt`. A
    /// `.successNoWarnings` is still a success (the refresh ran cleanly;
    /// the forecast just had no triggers). `.provisionalDelivery` counts
    /// as success because warnings DID schedule — iOS just delivers
    /// them silently.
    var isSuccess: Bool {
        switch self {
        case .success, .successNoWarnings, .provisionalDelivery,
             .weatherKitFailedUsingStale, .queueBudgetReachedWithDropped:
            return true
        default:
            return false
        }
    }
}

// MARK: - Planned warning helper

/// One concrete notification the service intends to schedule. Built from
/// an evaluator `Hit` and carries everything the diff-against-pending
/// step needs — identifier, fireDate, body, and the pre-assembled
/// `UNNotificationContent`.
struct PlannedWarning: Sendable {
    let kind: WarningKind
    let fireDate: Date
    let identifier: String
    let body: String
    let content: UNNotificationContent
}

// MARK: - WeatherWarningsService

/// The orchestrator. Long-pole WeatherKit + server fetches run on this
/// actor's executor (NOT `@MainActor`) so a 30s WeatherKit timeout never
/// blocks the main thread. Two bounded `MainActor.run` hops per refresh:
///   1. Snapshot prerequisites (coords, toggles, active-event count, auth)
///   2. Publish the outcome to the `@Observable Projection`.
///
/// Spec: `.docs/ai/specs/2026-06-07-phase-4c-native-warnings-design.md`
/// §4 (Public API) + §6 (Refresh model) + §9 (Failure handling).
actor WeatherWarningsService {

    /// Notification-identifier prefixes. **`frost` is preserved
    /// CHAR-FOR-CHAR** from the shipped string so build-39 pending
    /// frost notifications survive the build-40 upgrade.
    enum IdPrefix {
        static let frost = "seedkeep.notif.frost."
        static let heat  = "seedkeep.notif.heat."
        static let water = "seedkeep.notif.water."
    }

    /// Main-actor-isolated, `@Observable` projection that Settings reads.
    /// The service publishes outcomes here via a single
    /// `MainActor.run { ... }` hop at the end of every refresh.
    @MainActor
    @Observable
    final class Projection {
        var lastRefreshOutcome: RefreshOutcome = .successNoWarnings(perKindEmpty: [:])
        var lastRefreshAt: Date? = nil
        var lastSuccessAt: Date? = nil
    }

    // MARK: - Stored dependencies

    let projection: Projection

    private let container: ModelContainer
    private let provider: any WeatherProvider
    private let scheduler: any NotificationScheduler
    private let planting: any PlantingEventQuery
    private let wateringState: any WateringStateClient
    private let clock: any Clock
    private let thresholds: WarningThresholds

    /// `@MainActor`-isolated closures used to snapshot live state at
    /// refresh time. These are escaping `() -> ...` (not async) because
    /// they read `@AppStorage` / preferences directly; the service hops
    /// to MainActor once per refresh to call them.
    private let householdIDProvider: @MainActor () -> String?
    private let preferencesProvider: @MainActor () -> (lat: Double?, lon: Double?)
    private let togglesProvider: @MainActor () -> (frost: Bool, heat: Bool, water: Bool)

    // MARK: - Actor-local state

    /// Coalesces concurrent callers — one Task per refresh, awaited by
    /// everyone else. Cleared (`nil`) when the in-flight refresh resolves.
    private var inFlight: Task<RefreshOutcome, Never>?

    /// Debounce slot for `.activePlantingsChanged`. Cancel-prior-then-replace.
    private var debounceTask: Task<Void, Never>?

    /// Lifetime-bound observer tokens for the two NotificationCenter
    /// subscriptions. Held so a second `start()` call doesn't double-wire.
    private var observerTokens: [NSObjectProtocol] = []
    private var started = false

    /// Per-day fetch tally — key is home-TZ YMD, value is the count of
    /// real WeatherKit calls burned today. When the value hits 6 the
    /// service forces `provider.cachedSnapshot()` instead of `fetch(...)`.
    private var fetchTallyByYMD: [String: Int] = [:]

    /// Coord generation, bumped by `invalidateLocation()`. Threaded into
    /// every `provider.fetch(...)` so the provider can drop a stale
    /// cache that crossed a location change.
    private var coordGeneration: Int = 0

    // MARK: - Init

    @MainActor
    init(
        container: ModelContainer,
        provider: any WeatherProvider,
        scheduler: any NotificationScheduler,
        planting: any PlantingEventQuery,
        wateringState: any WateringStateClient,
        clock: any Clock = SystemClock(),
        thresholds: WarningThresholds = .kc,
        householdIDProvider: @escaping @MainActor () -> String?,
        preferencesProvider: @escaping @MainActor () -> (lat: Double?, lon: Double?),
        togglesProvider: @escaping @MainActor () -> (frost: Bool, heat: Bool, water: Bool)
    ) {
        self.container = container
        self.provider = provider
        self.scheduler = scheduler
        self.planting = planting
        self.wateringState = wateringState
        self.clock = clock
        self.thresholds = thresholds
        self.householdIDProvider = householdIDProvider
        self.preferencesProvider = preferencesProvider
        self.togglesProvider = togglesProvider
        // `Projection` is `@MainActor`-isolated. The actor's init runs on
        // MainActor (annotated above) so we can construct it inline; the
        // actor instance itself remains its own isolation domain.
        self.projection = Projection()
    }

    // MARK: - Lifecycle

    /// Wire two `NotificationCenter.default` observers:
    ///   - `.weatherWarningsActivePlantingsChanged` → 300ms debounced
    ///     `refreshAll(.activePlantingsChanged)`. Cancel-prior-Task
    ///     debouncer: every fired post cancels the in-flight debounce
    ///     Task before scheduling a new one, so a bulk-insert of 100
    ///     events collapses to a single refresh.
    ///   - `NSSystemTimeZoneDidChange` → immediate `refreshAll(.timeZoneChange)`.
    ///
    /// Idempotent — a second `start()` is a no-op.
    func start() async {
        guard !started else { return }
        started = true

        let center = NotificationCenter.default

        // Observer 1 — active-plantings change (debounced).
        let plantingsToken = center.addObserver(
            forName: .weatherWarningsActivePlantingsChanged,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            Task { [weak self] in
                await self?.scheduleDebouncedActivePlantingsRefresh()
            }
        }
        observerTokens.append(plantingsToken)

        // Observer 2 — system timezone change (immediate).
        let tzToken = center.addObserver(
            forName: .NSSystemTimeZoneDidChange,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            Task { [weak self] in
                await self?.refreshAll(reason: .timeZoneChange)
            }
        }
        observerTokens.append(tzToken)
    }

    /// Internal — cancel any in-flight debounce Task and schedule a new
    /// one 300ms out. Must run on the actor so the cancel-then-replace
    /// is atomic.
    private func scheduleDebouncedActivePlantingsRefresh() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            // 300ms debounce window — bulk imports coalesce.
            try? await Task.sleep(nanoseconds: 300_000_000)
            if Task.isCancelled { return }
            await self?.refreshAll(reason: .activePlantingsChanged)
        }
    }

    // MARK: - Public surface

    /// Primary entry. Concurrent callers coalesce into the in-flight
    /// Task so exactly one WeatherKit fetch happens per refresh cycle.
    ///
    /// EXCEPT for state-changing reasons: a refresh kicked by a toggle
    /// flip / location change / TZ change / plantings change snapshots
    /// its prereqs at start, so absorbing such a caller into an OLDER
    /// in-flight refresh would silently discard the change (the toggle
    /// looks enabled but nothing scheduled until the next trigger).
    /// Those callers await the stale refresh, then run a fresh one.
    @discardableResult
    func refreshAll(reason: RefreshReason) async -> RefreshOutcome {
        // a. Coalesce — if a refresh is already in flight, wait for it.
        let stateChanging = Self.isStateChangingReason(reason)
        while let running = inFlight {
            let outcome = await running.value
            if !stateChanging {
                return outcome
            }
            // Let the creator's continuation clear `inFlight` before
            // re-checking, so this loop can't spin on a completed task.
            await Task.yield()
        }
        let task = Task<RefreshOutcome, Never> { [weak self] in
            guard let self else {
                return .weatherKitFailed(message: "service released")
            }
            return await self.performRefresh(reason: reason)
        }
        inFlight = task
        let outcome = await task.value
        // Clear before publishing — a follow-up call mid-publish must
        // see a fresh slot.
        inFlight = nil
        return outcome
    }

    /// Reasons that carry a state change the in-flight refresh cannot
    /// have seen (its prereq snapshot predates the change).
    private static func isStateChangingReason(_ reason: RefreshReason) -> Bool {
        switch reason {
        case .toggleEnable, .locationChange, .timeZoneChange,
             .activePlantingsChanged, .permissionRegranted:
            return true
        case .manualRefresh, .foreground, .test:
            return false
        }
    }

    /// Foreground-only staleness gate. Bypassed for every other reason.
    /// Returns nil if the gate suppressed the refresh.
    ///
    /// Permission-regrant bypass: warnings are cleared while UN
    /// authorization is denied, so when the persisted
    /// `lastAuthStatusRaw` says denied but the live status is granted
    /// (the user just re-enabled notifications in iOS Settings), the
    /// gate is bypassed and the refresh runs as `.permissionRegranted`
    /// — otherwise the user stares at zero warnings for up to 2h.
    @discardableResult
    func refreshAllIfStale(reason: RefreshReason) async -> RefreshOutcome? {
        if reason == .foreground {
            let current = await scheduler.authorizationStatus()
            let isGranted = current == .authorized
                || current == .provisional
                || current == .ephemeral
            if isGranted {
                let container = self.container
                let persistedRaw = await MainActor.run { () -> Int? in
                    let context = ModelContext(container)
                    let descriptor = FetchDescriptor<LocalForecastSnapshot>()
                    return (try? context.fetch(descriptor))?.first?.lastAuthStatusRaw
                }
                if persistedRaw == Int(UNAuthorizationStatus.denied.rawValue) {
                    return await refreshAll(reason: .permissionRegranted)
                }
            }
            let last = await MainActor.run { projection.lastSuccessAt }
            if let last,
               clock.now.timeIntervalSince(last) < 2 * 3_600 {
                return nil
            }
        }
        return await refreshAll(reason: reason)
    }

    /// `HomeLocationSettingsView` calls this after saving new coords.
    /// Bumps the generation counter, asks the provider to drop its
    /// cached snapshot, then kicks a `.locationChange` refresh.
    func invalidateLocation() async {
        coordGeneration += 1
        await provider.bumpGeneration(to: coordGeneration)
        _ = await refreshAll(reason: .locationChange)
    }

    /// Toggle-off path. Removes pending notifications for a single kind
    /// only. Does NOT clear `LocalForecastSnapshot.lastWaterFireDate` —
    /// preserves dedup integrity across rapid toggle-off-then-on cycles
    /// inside the 7-day watering window. The Settings caption documents
    /// this for the user.
    func clearKind(_ kind: WarningKind) async {
        await clearPendingForPrefix(prefix(for: kind))
    }

    /// Settings diagnostic — returns true if at least one pending
    /// notification matches the kind's prefix.
    func hasScheduled(_ kind: WarningKind) async -> Bool {
        let pending = await scheduler.pendingNotificationRequests()
        let p = prefix(for: kind)
        return pending.contains { $0.identifier.hasPrefix(p) }
    }

    // MARK: - Refresh — sequenced order a-t per spec §6

    private func performRefresh(reason: RefreshReason) async -> RefreshOutcome {
        // b. MainActor snapshot of all main-isolated prerequisites.
        struct Prereqs: Sendable {
            let coords: (lat: Double?, lon: Double?)
            let toggles: (frost: Bool, heat: Bool, water: Bool)
            let householdID: String?
        }
        let prereqs = await MainActor.run {
            Prereqs(
                coords: preferencesProvider(),
                toggles: togglesProvider(),
                householdID: householdIDProvider()
            )
        }
        // Capture the coord generation alongside the prereq snapshot —
        // reading the live actor value at fetch time let a mid-flight
        // `invalidateLocation()` bump tag an OLD location's forecast
        // with the NEW generation, defeating the stale-cache check.
        let generationAtSnapshot = coordGeneration
        let activeCount = await planting.activeCount()
        let authStatus = await scheduler.authorizationStatus()

        let anyToggleOn = prereqs.toggles.frost
            || prereqs.toggles.heat
            || prereqs.toggles.water

        // c. Early returns (order matters).
        if !anyToggleOn {
            let outcome = RefreshOutcome.successNoWarnings(perKindEmpty: [:])
            await persistAndPublish(outcome: outcome, authStatus: authStatus)
            return outcome
        }

        guard let lat = prereqs.coords.lat, let lon = prereqs.coords.lon else {
            await clearAllOurPrefixes()
            let outcome = RefreshOutcome.missingLocation
            await persistAndPublish(outcome: outcome, authStatus: authStatus)
            return outcome
        }

        if activeCount == 0 {
            await clearAllOurPrefixes()
            let outcome = RefreshOutcome.noActivePlantings
            await persistAndPublish(outcome: outcome, authStatus: authStatus)
            return outcome
        }

        if authStatus == .denied {
            await clearAllOurPrefixes()
            let outcome = RefreshOutcome.permissionDenied(
                deepLinkURL: notificationSettingsDeepLink()
            )
            await persistAndPublish(outcome: outcome, authStatus: authStatus)
            return outcome
        }

        let isProvisional = (authStatus == .provisional)

        // d, e. TZ-change + clock-skew detection. Read the snapshot
        //       once on MainActor.
        struct PriorState: Sendable {
            let sawTimeZoneIdentifier: String?
            let sawClockAt: Date?
            let lastWaterFireDate: Date?
            let lastHeatDomeFireDate: Date?
            let lastHeatEventDate: Date?
        }
        let priorState = await MainActor.run {
            let context = ModelContext(container)
            let descriptor = FetchDescriptor<LocalForecastSnapshot>()
            let row = (try? context.fetch(descriptor))?.first
            return PriorState(
                sawTimeZoneIdentifier: row?.sawTimeZoneIdentifier,
                sawClockAt: row?.sawClockAt,
                lastWaterFireDate: row?.lastWaterFireDate,
                lastHeatDomeFireDate: row?.lastHeatDomeFireDate,
                lastHeatEventDate: row?.lastHeatEventDate
            )
        }

        let currentTZID = TimeZone.current.identifier
        let tzChanged: Bool
        if let saw = priorState.sawTimeZoneIdentifier {
            tzChanged = (saw != currentTZID)
        } else {
            tzChanged = false
        }

        // Clock-skew: > 24h backward OR > 14d forward.
        let now = clock.now
        var clockSkewSeconds: TimeInterval?
        if let sawClockAt = priorState.sawClockAt {
            let delta = now.timeIntervalSince(sawClockAt)
            if delta < -24 * 3_600 || delta > 14 * 86_400 {
                clockSkewSeconds = delta
            }
        }

        // TZ-change / clock-skew rebuild is DEFERRED until a usable
        // forecast is in hand (below). Clearing here, before the fetch,
        // violated the "never clear pending on failure" rule: a failed
        // fetch returned early with zero warnings left — exactly the
        // airplane-mode-while-traveling case. The cleared notifications
        // carry home-TZ-anchored DateComponents and fire at the correct
        // wall-clock regardless, so holding them through a failed
        // refresh is safe.

        // f. Per-day fetch cap — home TZ YMD. We don't have the home TZ
        //    yet (provider returns it), so use TimeZone.current as the
        //    proxy bucket. This drifts at most once on the first refresh
        //    after a TZ change; subsequent refreshes use the same proxy.
        let todayYMD = Identifier.isoDay(now, in: TimeZone.current)
        let todayCount = fetchTallyByYMD[todayYMD] ?? 0
        let forceCachedOnly = (todayCount >= 6)

        // g. provider.fetch (30s timeout) — or cached-only if cap hit.
        let fetchOutcome: ForecastResult
        if forceCachedOnly {
            if let cached = await provider.cachedSnapshot(),
               let tz = TimeZone(identifier: cached.homeTimeZoneIdentifier) {
                let age = now.timeIntervalSince(cached.fetchedAt)
                fetchOutcome = .stale(
                    forecast: cached.forecast,
                    observed: cached.observed,
                    homeTimeZone: tz,
                    ageSeconds: age
                )
            } else {
                fetchOutcome = .failed(message: "per-day cap; no cache", isUnauthorized: false)
            }
        } else {
            fetchTallyByYMD[todayYMD] = todayCount + 1
            fetchOutcome = await withTimeoutOrFailed(seconds: 30) {
                await self.provider.fetch(
                    latitude: lat,
                    longitude: lon,
                    generation: generationAtSnapshot
                )
            }
        }

        switch fetchOutcome {
        case .failed(let message, let isUnauthorized):
            let outcome: RefreshOutcome = isUnauthorized
                ? .weatherKitUnauthorized
                : .weatherKitFailed(message: message)
            // Spec §6.g: do NOT clear pending on failure.
            await persistAndPublish(outcome: outcome, authStatus: authStatus)
            return outcome

        case .stale, .fresh:
            break
        }

        let forecast: [DailyWeather]
        let observed: [ObservedDay]
        let homeTimeZone: TimeZone
        var staleAgeSeconds: TimeInterval?
        let providerFetchedAt: Date
        switch fetchOutcome {
        case .fresh(let f, let o, let tz, let fetchedAt):
            forecast = f
            observed = o
            homeTimeZone = tz
            providerFetchedAt = fetchedAt
        case .stale(let f, let o, let tz, let age):
            forecast = f
            observed = o
            homeTimeZone = tz
            staleAgeSeconds = age
            providerFetchedAt = now.addingTimeInterval(-age)
        case .failed:
            // Already returned above; reach is unreachable but the
            // compiler requires the case.
            return .weatherKitFailed(message: "unreachable")
        }

        // h. Validate forecast — provider already dropped invalid days.
        let validDays = forecast.count
        let waterSuppressed = validDays < 3
        if validDays < 3 {
            // Frost + heat still try to emit; water is suppressed below.
            // We DON'T early-return here — frost/heat may still produce.
            _ = waterSuppressed
        }

        // i. homeTimeZone already sourced from provider.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = homeTimeZone

        // d/e (deferred): rebuild on TZ change or clock skew now that a
        // usable forecast arrived — everything re-plans below against an
        // empty pending set.
        if tzChanged || clockSkewSeconds != nil {
            await clearAllOurPrefixes()
        }

        // j. Server-coordinated watering ledger.
        let householdLastWaterAt: Date?
        if let hhid = prereqs.householdID {
            switch await wateringState.get(householdID: hhid) {
            case .success(let date):
                householdLastWaterAt = date
            case .failure:
                householdLastWaterAt = nil
            }
        } else {
            householdLastWaterAt = nil
        }

        // Read the pending set ONCE, before the evaluators run. The
        // evaluators consult it (a hit whose notification is still
        // pending must stay planned — see the cancel-before-fire
        // findings) and the diff below reuses the same snapshot.
        let pending = await scheduler.pendingNotificationRequests()
        let ourPrefixes = [IdPrefix.frost, IdPrefix.heat, IdPrefix.water]
        let ourPending: [UNNotificationRequest] = pending.filter { req in
            ourPrefixes.contains { req.identifier.hasPrefix($0) }
        }
        // Reconstruct each pending request's fire date from its trigger
        // components (NOT `nextTriggerDate()`, which consults the real
        // wall clock and returns nil for non-repeating past dates —
        // useless under the test suite's FixedClock).
        var pendingFireDates: [String: Date] = [:]
        for req in ourPending {
            guard let trigger = req.trigger as? UNCalendarNotificationTrigger,
                  let fire = Calendar.current.date(from: trigger.dateComponents)
            else { continue }
            pendingFireDates[req.identifier] = fire
        }

        // k. Run evaluators (pure, no I/O).
        let frostHits: [FrostEvaluator.Hit]
        if prereqs.toggles.frost {
            frostHits = FrostEvaluator.evaluate(
                forecast: forecast,
                thresholdF: thresholds.frostLowF,
                now: now,
                calendar: calendar,
                homeTimeZone: homeTimeZone,
                pendingFireDates: pendingFireDates
            )
        } else {
            frostHits = []
        }

        let heatHits: [HeatEvaluator.Hit]
        if prereqs.toggles.heat {
            heatHits = HeatEvaluator.evaluate(
                forecast: forecast,
                thresholds: thresholds,
                lastHeatDomeFireDate: priorState.lastHeatDomeFireDate,
                lastHeatEventDate: priorState.lastHeatEventDate,
                now: now,
                calendar: calendar,
                homeTimeZone: homeTimeZone,
                pendingFireDates: pendingFireDates
            )
        } else {
            heatHits = []
        }

        let waterDecision: WaterEvaluator.Decision?
        if prereqs.toggles.water && !waterSuppressed {
            let pastByYMD: [String: ObservedDay] = Dictionary(
                uniqueKeysWithValues: observed.map { day in
                    (Identifier.isoDay(day.date, in: homeTimeZone), day)
                }
            )
            let firstObservation = observed
                .map { $0.date }
                .min()
                .map { Identifier.isoDay($0, in: homeTimeZone) }
            let past = PastObservations(
                byYMD: pastByYMD,
                firstObservationYMD: firstObservation
            )
            waterDecision = WaterEvaluator.evaluate(
                forecast: forecast,
                past: past,
                thresholds: thresholds,
                householdLastWaterAt: householdLastWaterAt,
                lastLocalFireDate: priorState.lastWaterFireDate,
                now: now,
                calendar: calendar,
                homeTimeZone: homeTimeZone,
                pendingFireDates: pendingFireDates
            )
        } else {
            waterDecision = nil
        }

        // l. Build [PlannedWarning] filtered by per-kind toggle.
        var planned: [PlannedWarning] = []
        for hit in frostHits {
            planned.append(plannedFrost(hit: hit, calendar: calendar))
        }
        for hit in heatHits {
            planned.append(plannedHeat(hit: hit, calendar: calendar))
        }
        if case .notify(let fireDate, let identifier, let reason) = waterDecision {
            planned.append(plannedWater(
                fireDate: fireDate,
                identifier: identifier,
                reason: reason
            ))
        }
        planned.sort { $0.fireDate < $1.fireDate }

        // m. Budget enforcement. Sort ascending so the dropped tail is
        //    the furthest-out warnings.
        var droppedFurthestOut = 0
        if planned.count > thresholds.queueBudget {
            droppedFurthestOut = planned.count - thresholds.queueBudget
            planned = Array(planned.prefix(thresholds.queueBudget))
        }

        // n. Diff against pending (snapshot read above, pre-evaluators).
        let ourPendingByID = Dictionary(
            uniqueKeysWithValues: ourPending.map { ($0.identifier, $0) }
        )

        var toAdd: [PlannedWarning] = []
        var toReplaceIDs: [String] = []
        var keepIDs: Set<String> = []

        for warning in planned {
            if let existing = ourPendingByID[warning.identifier],
               matches(existing, warning) {
                keepIDs.insert(warning.identifier)
            } else if ourPendingByID[warning.identifier] != nil {
                toReplaceIDs.append(warning.identifier)
                toAdd.append(warning)
            } else {
                toAdd.append(warning)
            }
        }

        // A pending water reminder is only removed when the evaluator
        // AFFIRMATIVELY decided no-trigger (rain arrived, soil-dryness
        // gate failed, toggle off). A dedup-window skip means "a reminder
        // already covers this window" — for a future ledger timestamp
        // that reminder IS the pending one, so removing it would cancel
        // the household's only watering ping before it fires. The same
        // keep applies when water evaluation didn't run for lack of data
        // (suppressed forecast, insufficient history): no decision was
        // made, so the standing reminder stays.
        let keepPendingWater: Bool
        if !prereqs.toggles.water {
            keepPendingWater = false
        } else if waterSuppressed {
            keepPendingWater = true
        } else {
            switch waterDecision {
            case .skip(.dedupWindow), .skip(.insufficientHistory):
                keepPendingWater = true
            default:
                keepPendingWater = false
            }
        }

        let kept = keepIDs.union(Set(toReplaceIDs))
        let toRemove: [String] = ourPending
            .map(\.identifier)
            .filter { id in
                if kept.contains(id) { return false }
                if keepPendingWater && id.hasPrefix(IdPrefix.water) { return false }
                return true
            }

        // o. Apply removals first, then adds.
        let removeIDs = Array(Set(toRemove + toReplaceIDs))
        if !removeIDs.isEmpty {
            await scheduler.removePendingNotificationRequests(withIdentifiers: removeIDs)
        }

        var scheduledIDs: Set<String> = []
        for warning in toAdd {
            let request = makeRequest(from: warning, in: homeTimeZone, calendar: calendar)
            do {
                try await scheduler.add(request)
                scheduledIDs.insert(warning.identifier)
            } catch {
                // Per-id failure — other ids continue.
            }
        }

        // q. Post-schedule verification.
        let postAuthStatus = await scheduler.authorizationStatus()
        if postAuthStatus == .denied {
            await clearAllOurPrefixes()
            let outcome = RefreshOutcome.permissionDenied(
                deepLinkURL: notificationSettingsDeepLink()
            )
            await persistAndPublish(outcome: outcome, authStatus: postAuthStatus)
            return outcome
        }

        let attemptedAdds = toAdd.count
        let scheduledCount = scheduledIDs.count
        if attemptedAdds > 0, scheduledCount == 0 {
            let outcome = RefreshOutcome.allSchedulingFailed(attempted: attemptedAdds)
            await persistAndPublish(outcome: outcome, authStatus: postAuthStatus)
            return outcome
        }

        // p. Post-add pending re-read — confirm water id actually landed
        //    before persisting `lastWaterFireDate`.
        let postPending = await scheduler.pendingNotificationRequests()
        let postPendingIDs = Set(postPending.map(\.identifier))

        // Settings' "weather watch" must reflect what is PENDING — kept
        // AND added — not just this refresh's adds. A keep-path refresh
        // (identical plan 2h after scheduling) used to report
        // .successNoWarnings ("No frost in the next 10 days.") while a
        // frost warning sat pending for tomorrow.
        var watchedByKind: [WarningKind: Int] = [:]
        for id in postPendingIDs {
            if id.hasPrefix(IdPrefix.frost) {
                watchedByKind[.frost, default: 0] += 1
            } else if id.hasPrefix(IdPrefix.heat) {
                watchedByKind[.heat, default: 0] += 1
            } else if id.hasPrefix(IdPrefix.water) {
                watchedByKind[.water, default: 0] += 1
            }
        }

        var confirmedWaterFireDate: Date?
        var confirmedWaterHouseholdPOST: (id: String, fire: Date)?
        if case .notify(let fireDate, let identifier, _) = waterDecision,
           postPendingIDs.contains(identifier),
           let hhid = prereqs.householdID {
            confirmedWaterFireDate = fireDate
            confirmedWaterHouseholdPOST = (hhid, fireDate)
        } else if case .notify(let fireDate, let identifier, _) = waterDecision,
                  postPendingIDs.contains(identifier) {
            // No household — still update local fallback only.
            confirmedWaterFireDate = fireDate
        }

        // r. POST household watering state (best-effort; doesn't change
        //    the outcome). Mirrors the spec — POST is idempotent on
        //    server-side `GREATEST`.
        if let (hhid, fireDate) = confirmedWaterHouseholdPOST {
            _ = await wateringState.put(householdID: hhid, scheduledFor: fireDate)
        }

        // Update lastHeatDomeFireDate + lastHeatEventDate for the next
        // refresh's dedup/first-of-season inputs.
        var nextHeatDomeFireDate = priorState.lastHeatDomeFireDate
        var nextHeatEventDate = priorState.lastHeatEventDate
        for hit in heatHits where scheduledIDs.contains(hit.identifier) {
            if hit.variant == .heatDomeStarting || hit.variant == .firstOfSeason {
                if (nextHeatDomeFireDate ?? .distantPast) < hit.fireDate {
                    nextHeatDomeFireDate = hit.fireDate
                }
            }
            if (nextHeatEventDate ?? .distantPast) < hit.heatDate {
                nextHeatEventDate = hit.heatDate
            }
        }

        // ── Compose the final outcome ──────────────────────────────────
        let outcome: RefreshOutcome
        if let jump = clockSkewSeconds {
            outcome = .clockSkew(jumpSeconds: jump)
        } else if let age = staleAgeSeconds {
            outcome = .weatherKitFailedUsingStale(ageSeconds: age)
        } else if validDays < 3 {
            outcome = .partialData(
                validDays: validDays,
                droppedDays: 0,
                waterSuppressed: true
            )
        } else if droppedFurthestOut > 0 {
            outcome = .queueBudgetReachedWithDropped(
                scheduledByKind: watchedByKind,
                droppedFurthestOut: droppedFurthestOut
            )
        } else if isProvisional {
            outcome = .provisionalDelivery
        } else if watchedByKind.values.allSatisfy({ $0 == 0 }) {
            // Nothing pending and no errors — emit per-kind empties
            // for whichever toggles are on so Settings can render
            // "watching / nothing in sight" rows.
            var perKindEmpty: [WarningKind: Bool] = [:]
            if prereqs.toggles.frost { perKindEmpty[.frost] = true }
            if prereqs.toggles.heat { perKindEmpty[.heat] = true }
            if prereqs.toggles.water { perKindEmpty[.water] = true }
            outcome = .successNoWarnings(perKindEmpty: perKindEmpty)
        } else {
            outcome = .success(
                scheduledByKind: watchedByKind,
                heldByBudget: droppedFurthestOut
            )
        }

        // s. Persist snapshot (final fields the service owns).
        //    sawTimeZoneIdentifier records the DEVICE's current TZ, not
        //    the forecast's — a stale (cached) forecast carries the OLD
        //    TZ, and persisting that re-armed the TZ-change clear on
        //    every subsequent refresh until a fresh fetch landed.
        await persistSnapshot(
            outcome: outcome,
            authStatus: postAuthStatus,
            now: now,
            homeTimeZoneIdentifier: TimeZone.current.identifier,
            lastWaterFireDate: confirmedWaterFireDate ?? priorState.lastWaterFireDate,
            lastHeatDomeFireDate: nextHeatDomeFireDate,
            lastHeatEventDate: nextHeatEventDate,
            providerFetchedAt: providerFetchedAt
        )

        // t. Publish outcome.
        await publishOutcome(outcome, at: now)

        return outcome
    }

    // MARK: - PlannedWarning constructors

    private func plannedFrost(
        hit: FrostEvaluator.Hit,
        calendar: Calendar
    ) -> PlannedWarning {
        let weekday = weekdayString(from: hit.frostDate, calendar: calendar)
        let lowFInt = Int(hit.lowF.rounded(.awayFromZero))
        let body = WarningCopy.frostBody(weekday: weekday, lowF: lowFInt)
        let content = makeContent(title: WarningCopy.frostTitle, body: body)
        return PlannedWarning(
            kind: .frost,
            fireDate: hit.fireDate,
            identifier: hit.identifier,
            body: body,
            content: content
        )
    }

    private func plannedHeat(
        hit: HeatEvaluator.Hit,
        calendar: Calendar
    ) -> PlannedWarning {
        let weekday = weekdayString(from: hit.heatDate, calendar: calendar)
        let highFInt = Int(hit.highF.rounded(.awayFromZero))
        let body: String
        switch hit.variant {
        case .heatDomeStarting:
            body = WarningCopy.heatBodyDomeStarting(weekday: weekday, highF: highFInt)
        case .extreme:
            body = WarningCopy.heatBodyExtreme(weekday: weekday, highF: highFInt)
        case .firstOfSeason:
            body = WarningCopy.heatBodyFirstOfSeason(weekday: weekday, highF: highFInt)
        }
        let content = makeContent(title: WarningCopy.heatTitle, body: body)
        return PlannedWarning(
            kind: .heat,
            fireDate: hit.fireDate,
            identifier: hit.identifier,
            body: body,
            content: content
        )
    }

    private func plannedWater(
        fireDate: Date,
        identifier: String,
        reason: WaterEvaluator.FireReason
    ) -> PlannedWarning {
        let body: String
        switch reason {
        case .dryStretchStarting:
            body = WarningCopy.wateringBodyDryStretchStarting
        case .dryStretchContinuing:
            body = WarningCopy.wateringBodyDryStretchContinuing
        case .dryStretchExtended:
            body = WarningCopy.wateringBodyDryStretchExtended
        }
        let content = makeContent(title: WarningCopy.wateringTitle, body: body)
        return PlannedWarning(
            kind: .water,
            fireDate: fireDate,
            identifier: identifier,
            body: body,
            content: content
        )
    }

    // MARK: - Notification content + request

    private func makeContent(title: String, body: String) -> UNNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        // Spec §6.p — every weather warning is .timeSensitive. If the
        // entitlement isn't provisioned at runtime, iOS silently
        // downgrades to .active.
        content.interruptionLevel = .timeSensitive
        return content
    }

    private func makeRequest(
        from planned: PlannedWarning,
        in homeTimeZone: TimeZone,
        calendar: Calendar
    ) -> UNNotificationRequest {
        // DateComponents carry explicit timeZone = homeTimeZone so the
        // trigger fires in the home location's wall-clock regardless
        // of the device's current TZ.
        var components = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: planned.fireDate
        )
        components.timeZone = homeTimeZone
        let trigger = UNCalendarNotificationTrigger(
            dateMatching: components,
            repeats: false
        )
        return UNNotificationRequest(
            identifier: planned.identifier,
            content: planned.content,
            trigger: trigger
        )
    }

    /// True if the existing request's fireDate (extracted from its
    /// `UNCalendarNotificationTrigger`) and body match the planned
    /// warning byte-for-byte. Mismatches mean we need to replace.
    private func matches(
        _ existing: UNNotificationRequest,
        _ planned: PlannedWarning
    ) -> Bool {
        guard existing.identifier == planned.identifier else { return false }
        guard existing.content.body == planned.body else { return false }
        guard let trigger = existing.trigger as? UNCalendarNotificationTrigger,
              let nextFire = trigger.nextTriggerDate()
        else { return false }
        // Tolerance: same minute. UN trigger reconstruction drops seconds.
        return abs(nextFire.timeIntervalSince(planned.fireDate)) < 60
    }

    // MARK: - Persistence + publish

    private func persistAndPublish(
        outcome: RefreshOutcome,
        authStatus: UNAuthorizationStatus
    ) async {
        await persistSnapshot(
            outcome: outcome,
            authStatus: authStatus,
            now: clock.now,
            homeTimeZoneIdentifier: TimeZone.current.identifier,
            lastWaterFireDate: nil,
            lastHeatDomeFireDate: nil,
            lastHeatEventDate: nil,
            providerFetchedAt: nil,
            updateForecastFields: false
        )
        await publishOutcome(outcome, at: clock.now)
    }

    private func persistSnapshot(
        outcome: RefreshOutcome,
        authStatus: UNAuthorizationStatus,
        now: Date,
        homeTimeZoneIdentifier: String,
        lastWaterFireDate: Date?,
        lastHeatDomeFireDate: Date?,
        lastHeatEventDate: Date?,
        providerFetchedAt: Date?,
        updateForecastFields: Bool = true
    ) async {
        let outcomeRaw = encodeOutcome(outcome)
        let container = self.container
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
            row.sawClockAt = now
            if updateForecastFields {
                row.sawTimeZoneIdentifier = homeTimeZoneIdentifier
            }
            if let lastWaterFireDate {
                row.lastWaterFireDate = lastWaterFireDate
            }
            if let lastHeatDomeFireDate {
                row.lastHeatDomeFireDate = lastHeatDomeFireDate
            }
            if let lastHeatEventDate {
                row.lastHeatEventDate = lastHeatEventDate
            }
            row.lastAuthStatusRaw = Int(authStatus.rawValue)
            row.outcomeRaw = outcomeRaw
            _ = providerFetchedAt
            try? context.save()
        }
    }

    private func publishOutcome(_ outcome: RefreshOutcome, at date: Date) async {
        await MainActor.run {
            projection.lastRefreshOutcome = outcome
            projection.lastRefreshAt = date
            if outcome.isSuccess {
                projection.lastSuccessAt = date
            }
        }
    }

    // MARK: - Helpers

    private func clearAllOurPrefixes() async {
        let pending = await scheduler.pendingNotificationRequests()
        let ids = pending
            .map(\.identifier)
            .filter { id in
                id.hasPrefix(IdPrefix.frost)
                    || id.hasPrefix(IdPrefix.heat)
                    || id.hasPrefix(IdPrefix.water)
            }
        if !ids.isEmpty {
            await scheduler.removePendingNotificationRequests(withIdentifiers: ids)
        }
    }

    private func clearPendingForPrefix(_ prefix: String) async {
        let pending = await scheduler.pendingNotificationRequests()
        let ids = pending
            .map(\.identifier)
            .filter { $0.hasPrefix(prefix) }
        if !ids.isEmpty {
            await scheduler.removePendingNotificationRequests(withIdentifiers: ids)
        }
    }

    private func prefix(for kind: WarningKind) -> String {
        switch kind {
        case .frost: return IdPrefix.frost
        case .heat: return IdPrefix.heat
        case .water: return IdPrefix.water
        }
    }

    /// Build the user-visible weekday string for a given absolute date,
    /// formatted in the supplied home-TZ-bound calendar. en_US_POSIX
    /// locks the weekday name to English so the notification body matches
    /// the shipped frost-body byte-for-byte regardless of device locale.
    private func weekdayString(from date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.calendar = calendar
        return formatter.string(from: date)
    }

    private func notificationSettingsDeepLink() -> URL? {
        #if canImport(UIKit)
        if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
            return url
        }
        return URL(string: UIApplication.openSettingsURLString)
        #else
        return nil
        #endif
    }

    private func encodeOutcome(_ outcome: RefreshOutcome) -> String {
        // Compact discriminant + arg encoding — Settings doesn't need
        // to parse this; the in-memory `Projection` is the source of
        // truth post-launch. The persisted form is just enough for
        // a cold-launch UI to render the most recent state before
        // the first refresh lands.
        switch outcome {
        case .success(let by, let held):
            return "success:\(by.count):\(held)"
        case .successNoWarnings(let by):
            return "successNoWarnings:\(by.count)"
        case .noActivePlantings: return "noActivePlantings"
        case .missingLocation: return "missingLocation"
        case .permissionDenied: return "permissionDenied"
        case .provisionalDelivery: return "provisionalDelivery"
        case .partialData(let valid, let dropped, let ws):
            return "partialData:\(valid):\(dropped):\(ws)"
        case .clockSkew(let s): return "clockSkew:\(Int(s))"
        case .weatherKitUnauthorized: return "weatherKitUnauthorized"
        case .weatherKitFailedUsingStale(let age):
            return "weatherKitFailedUsingStale:\(Int(age))"
        case .weatherKitFailed(let m): return "weatherKitFailed:\(m)"
        case .allSchedulingFailed(let a):
            return "allSchedulingFailed:\(a)"
        case .queueBudgetReachedWithDropped(_, let d):
            return "queueBudgetReachedWithDropped:\(d)"
        }
    }

    /// Run `body` with a hard timeout. On timeout, return a synthetic
    /// `.failed(message: "timeout")` so the caller can unblock
    /// `inFlight` and Settings can render an actionable error.
    private func withTimeoutOrFailed(
        seconds: TimeInterval,
        _ body: @Sendable @escaping () async -> ForecastResult
    ) async -> ForecastResult {
        await withTaskGroup(of: ForecastResult.self) { group in
            group.addTask { await body() }
            group.addTask {
                let nanos = UInt64(seconds * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanos)
                return .failed(message: "timeout", isUnauthorized: false)
            }
            let first = await group.next() ?? .failed(message: "timeout", isUnauthorized: false)
            group.cancelAll()
            return first
        }
    }
}
