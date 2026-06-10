import Foundation
import SwiftUI
import SwiftData
import SeedkeepKit

/// Reads launch-time configuration from `Info.plist`, wires the
/// `SeedkeepClient`, the SwiftData `ModelContainer`, the `SyncEngine`,
/// and the `AuthController`. SwiftUI views read this as an `@Environment`.
///
/// Server URL resolution: the bundled xcconfig provides the *default*
/// (e.g. localhost in dev, official cloud host in release). Users can
/// override per-install via Settings → Server, which writes a URL into
/// `AppPreferences`. We honor the override on launch + when it changes.
@MainActor
@Observable
public final class AppEnvironment {
    public let client: SeedkeepClient
    public let auth: AuthController
    public let container: ModelContainer
    public let sync: SyncEngine
    public let recommendations: RecommendationStore
    let journal: JournalStore
    let assistant: AIAssistantCoordinator
    public let preferences: AppPreferences
    public let apiKeys: APIKeyStore
    public let subscriptions: SubscriptionManager
    /// Phase 4C — orchestrator for frost / heat / water weather warnings.
    /// Replaces the old `NotificationsCenter.refreshFrostWarnings` path.
    let weatherWarnings: WeatherWarningsService

    /// Lets feature views request a tab switch (e.g. TopBarSparkleButton →
    /// Assistant). MainTabView observes this and binds it to the TabView's
    /// selection. nil means leave whatever's current.
    public var requestedTab: AppTab?

    /// User-facing error banner string. Set via `surfaceError` from call
    /// sites that previously swallowed `try?`, or mirrored from
    /// `sync.lastError` after a sync completes. `nil` hides the banner.
    public var bannerError: String?

    /// Debounce state — the last string we surfaced + when. Repeated
    /// identical errors within 5 seconds are dropped so retry loops in
    /// `SyncEngine` don't strobe the banner.
    @ObservationIgnored private var lastBannerString: String?
    @ObservationIgnored private var lastBannerTime: Date?

    public enum AppTab: Hashable {
        case today, library, garden, journal, random, assistant, settings, you
    }

    public static func live() -> AppEnvironment {
        let bundleDefaultURL = Self.resolveBundleDefaultURL()
        let prefs = AppPreferences(bundleDefaultURL: bundleDefaultURL)
        let keychainService = Self.resolveKeychainService()
        let store = KeychainTokenStore(service: keychainService)
        let apiKeys = APIKeyStore(service: keychainService)
        let client = SeedkeepClient(configuration: .init(baseURL: prefs.effectiveServerURL))
        let auth = AuthController(client: client, tokenStore: store)
        let container = Self.makeModelContainer()
        let sync = SyncEngine(client: client, container: container)
        let recommendations = RecommendationStore(client: client, container: container)
        let journal = JournalStore(client: client, container: container)
        let assistant = AIAssistantCoordinator(client: client, container: container)
        assistant.wireSync(sync)
        let subscriptions = SubscriptionManager(client: client)
        // Phase 4C — weather warnings service. Replaces the legacy
        // `NotificationsCenter.refreshFrostWarnings` path with the
        // actor-orchestrated frost/heat/water flow. Providers are
        // wired here so tests can swap them out via a separate init.
        let weatherWarnings = WeatherWarningsService(
            container: container,
            provider: WeatherKitProvider(container: container),
            scheduler: SystemNotificationScheduler(),
            planting: SwiftDataPlantingEventQuery(container: container),
            wateringState: SystemWateringStateClient(client: client),
            clock: SystemClock(),
            thresholds: .kc,
            householdIDProvider: { @MainActor [weak auth] in
                guard case .signedIn(_, let household) = auth?.state else { return nil }
                return household.id
            },
            preferencesProvider: { @MainActor [weak prefs] in
                (lat: prefs?.cachedLatitude, lon: prefs?.cachedLongitude)
            },
            togglesProvider: { @MainActor in
                (
                    frost: UserDefaults.standard.bool(forKey: "seedkeep.notif.frost"),
                    heat: UserDefaults.standard.bool(forKey: "seedkeep.notif.heat"),
                    water: UserDefaults.standard.bool(forKey: "seedkeep.notif.water")
                )
            }
        )
        return AppEnvironment(
            client: client, auth: auth, container: container,
            sync: sync, recommendations: recommendations,
            journal: journal, assistant: assistant,
            preferences: prefs, apiKeys: apiKeys,
            subscriptions: subscriptions,
            weatherWarnings: weatherWarnings
        )
    }

    private init(
        client: SeedkeepClient,
        auth: AuthController,
        container: ModelContainer,
        sync: SyncEngine,
        recommendations: RecommendationStore,
        journal: JournalStore,
        assistant: AIAssistantCoordinator,
        preferences: AppPreferences,
        apiKeys: APIKeyStore,
        subscriptions: SubscriptionManager,
        weatherWarnings: WeatherWarningsService
    ) {
        self.client = client
        self.auth = auth
        self.container = container
        self.sync = sync
        self.recommendations = recommendations
        self.journal = journal
        self.assistant = assistant
        self.preferences = preferences
        self.apiKeys = apiKeys
        self.subscriptions = subscriptions
        self.weatherWarnings = weatherWarnings
        // Phase 4C — wire `NotificationCenter.default` observers
        // (active-plantings debounce + system-timezone-change). The
        // service is idempotent so a second start() is a no-op.
        Task { await weatherWarnings.start() }
        // Phase 4D — catalog-corrections orchestrator. Observes
        // `.catalogCorrectionsChanged` posted by `SyncEngine` and
        // schedules outcome pings (with cross-device dedup via the
        // server ledger). Idempotent — safe to call from tests too.
        CatalogCorrectionNotifier.shared.start(
            client: client,
            container: container
        )
        // Stabilization B3 — journal feed refresh failures were recorded
        // into JournalStore.lastError and never displayed. Route them
        // through the same banner mount every other surfaced error uses.
        journal.wireErrorSink { [weak self] error in
            self?.surfaceError(error)
        }
    }

    /// Surfaces an error to the user via `bannerError`. Replaces silent
    /// `try?` swallows at call sites where the user needs to know
    /// something went wrong (sync enqueue failures, assistant launch, etc).
    public func surfaceError(_ error: Error) {
        presentBanner(humanizeError(error))
    }

    /// Hides the banner. Wired to the banner's dismiss action and the
    /// auto-dismiss timer in `MainTabView`.
    public func dismissBannerError() {
        bannerError = nil
    }

    /// Pushes `message` into `bannerError`, applying a 5-second same-string
    /// debounce. Used by `surfaceError` and the post-sync mirror.
    private func presentBanner(_ message: String) {
        let now = Date()
        if let last = lastBannerString, last == message,
           let lastTime = lastBannerTime,
           now.timeIntervalSince(lastTime) < 5 {
            return
        }
        lastBannerString = message
        lastBannerTime = now
        bannerError = message
    }

    /// Triggers a sync if the user is signed in. Safe to call repeatedly —
    /// `SyncEngine` debounces concurrent calls with `isSyncing`.
    ///
    /// After a successful sync, runs `PetStateEngine.tickAll` on every
    /// alive pet in the household — this is the single canonical place
    /// where mood snapshots are materialized and lifecycle transitions
    /// are detected. Any `.departingToDeparted` transitions trigger a
    /// `requestPetDeparture` RPC via `performSideEffects`; the server
    /// is idempotent so re-tick after a transient failure is safe.
    /// Notification scheduling for the other transitions lands in
    /// Phase 5.1.4 (the side-effect helper has the hook points stubbed).
    public func syncIfPossible() async {
        if case .signedIn(_, let household) = auth.state {
            let ran = await sync.syncAll(householdID: household.id)
            // Skipped (another sync already in flight): lastError still
            // holds the PREVIOUS pass's outcome — re-presenting it here
            // shows a phantom banner — and the post-sync orchestration
            // below would run against a mid-sweep store. The in-flight
            // caller does all of it when its pass finishes.
            guard ran else { return }
            // Mirror the sync outcome into the user-facing banner.
            // SyncEngine isn't @Observable, so SwiftUI can't react to it
            // directly — we surface here instead, on the boundary that
            // every sync flows through. `lastHumanizedError` is the
            // humanizeError rendering (raw codes/statuses/body excerpts
            // stay in `lastError` for the Settings diagnostics row).
            // Debounce inside presentBanner keeps repeated identical
            // errors from strobing the UI.
            if let syncError = sync.lastHumanizedError {
                presentBanner(syncError)
            }
            let transitions = PetStateEngine.tickAll(
                householdID: household.id,
                container: container
            )
            await PetStateEngine.performSideEffects(
                for: transitions,
                client: client,
                container: container
            )
            // Phase 5.1.4: re-bake the weekly roundup body with the
            // current household snapshot. iOS preserves the next-fire
            // date when re-scheduling with the same identifier + same
            // DateComponents shape, so this is cheap to call every sync.
            await rescheduleWeeklyPetRoundup()
            // Phase 4C: refresh weather warnings if stale. Honors the
            // 2h staleness gate when called with `.foreground` so a
            // tab-back-in doesn't burn a WeatherKit fetch.
            _ = await weatherWarnings.refreshAllIfStale(reason: .foreground)
        }
    }

    /// Phase 5.1.4 — recompute the Sunday-8am pet roundup body from the
    /// current household snapshot. Gated server-side by the Settings
    /// toggle; this function is safe to call regardless.
    private func rescheduleWeeklyPetRoundup() async {
        let context = ModelContext(container)
        // 3-condition predicates trip the SwiftData macro type-checker;
        // gate the two cheap server-side flags here + filter petSeed in code.
        let descriptor = FetchDescriptor<LocalPlantingEvent>(
            predicate: #Predicate<LocalPlantingEvent> { event in
                event.deletedAt == nil && event.completedAt == nil
            }
        )
        guard let fetched = try? context.fetch(descriptor) else { return }
        let candidates = fetched.filter { $0.petSeed != nil }
        var thriving = 0
        var wilting = 0
        await MainActor.run {
            for event in candidates {
                switch event.petLifecyclePhase {
                case .alive: thriving += 1
                case .wilted, .departing: wilting += 1
                case .departed, .graduated: break
                }
            }
        }
        await NotificationsCenter.shared.schedulePetWeeklyRoundup(
            thrivingCount: thriving,
            wiltingCount: wilting
        )
    }

    /// Validates that `url` answers `/api/health` then mutates the live
    /// `SeedkeepClient` to point at it and persists the override.
    /// Returns `nil` on success or a human-readable error.
    public func setServerURL(_ url: URL) async -> String? {
        let probe = SeedkeepClient(configuration: .init(baseURL: url))
        do {
            _ = try await probe.health()
        } catch let err as SeedkeepError {
            return "\(err.code): \(err.message)"
        } catch {
            return "Could not reach \(url.absoluteString): \(error.localizedDescription)"
        }
        await client.setBaseURL(url)
        preferences.serverURLOverride = url == preferences.bundleDefault ? nil : url
        return nil
    }

    /// Resets to the bundle default URL.
    public func resetServerURLToDefault() async {
        await client.setBaseURL(preferences.bundleDefault)
        preferences.serverURLOverride = nil
    }

    /// Refreshes the cached tier by calling `/api/subscriptions/me`.
    /// Safe to call without a sign-in — returns silently on auth errors.
    public func refreshTier() async {
        do {
            let res = try await client.subscriptionMe()
            preferences.cachedTier = res.tier
        } catch {
            // Quietly ignore — UI continues to render the last cached tier.
        }
    }

    private static func resolveBundleDefaultURL() -> URL {
        let info = Bundle.main.infoDictionary ?? [:]
        let scheme = (info["SeedkeepAPIScheme"] as? String) ?? "http"
        let host = (info["SeedkeepAPIHost"] as? String) ?? "localhost:8787"
        guard let url = URL(string: "\(scheme)://\(host)") else {
            fatalError("Invalid SeedkeepAPIScheme/SeedkeepAPIHost — check AppConfig.xcconfig")
        }
        return url
    }

    private static func resolveKeychainService() -> String {
        let info = Bundle.main.infoDictionary ?? [:]
        return (info["KeychainService"] as? String) ?? "com.example.seedkeep"
    }

    private static func makeModelContainer() -> ModelContainer {
        // Shared model list — see `SeedkeepSchema`. Hand-typed lists here
        // and in test containers diverged once (LocalForecastSnapshot was
        // registered only in tests, silently breaking all weather-warning
        // persistence in production); the shared constant prevents a repeat.
        let schema = Schema(SeedkeepSchema.all)
        let config = ModelConfiguration("seedkeep", schema: schema)
        do {
            return try ModelContainer(for: schema, configurations: config)
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }
}
