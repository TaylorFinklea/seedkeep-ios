import Foundation
import SwiftUI
import SwiftData
import SeedkeepKit
import SeedkeepCloudKit
import CloudKit

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
        case today, library, garden, journal, you
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
        // Stabilization B3 — sign-out / identity-switch wipe is wired in init() (below), where the
        // AppEnvironment instance exists so the wipe can ALSO tear down the CloudKit coordinator
        // (state token + per-record synced-state file + migration marker), not just SwiftData. See
        // wireSignOutEraser().
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
                return ActiveGardenContext.householdID(
                    signedInHouseholdID: household.id,
                    participantZoneName: ActiveGardenContext.participantZoneName(),
                    cloudKitSyncEnabled: FeatureFlags.cloudKitHouseholdSyncEnabled
                )
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
        sync.onLocalHouseholdMutation = { [weak self] in self?.noteHouseholdMutation() }
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
        // Stabilization B3 + R1 — sign-out / identity-switch wipe. Erases every model (generic over
        // SeedkeepSchema.all — includes the pending-write queue + sync cursors), drops notifications,
        // AND tears down the CloudKit coordinator (engine state token + per-record synced-state file +
        // migration marker) and nils its reference so a re-sign-in to the SAME household rebuilds a
        // fresh coordinator that re-provisions + rehydrates rather than reusing a stale `started` one.
        auth.wireLocalDataEraser { [weak self] in
            guard let self else { return }
            do {
                try self.sync.eraseAllLocalData()
            } catch {
                // Best effort — a wipe failure must not block sign-out; the keychain token is gone.
            }
            NotificationsCenter.shared.removeAllAppNotifications()
            self.cloudCoordinator?.wipeAndClear()
            self.cloudCoordinator = nil
            self.cloudCoordinatorKey = nil
            self.clearParticipantMarker()   // sign-out abandons any adopted shared household too
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
            let activeGardenHouseholdID = self.activeGardenHouseholdID ?? household.id
            // R1: route HOUSEHOLD garden data through the CloudKit coordinator when the flag is on,
            // else the legacy server feeds. Both share the identical post-sync orchestration below.
            // Catalog corrections stay on the server as the R3 personal feed. Assistant threads are
            // gated while CloudKit is active because their server tools address the parked household.
            let banner: String?
            if FeatureFlags.cloudKitHouseholdSyncEnabled {
                let coordinator = ensureCloudCoordinator(household: household)
                let ran = await coordinator.sync()
                guard ran else { return }
                // Household data synced via CloudKit; still pull the catalog-corrections personal
                // feed. syncAll skips household feeds, assistant history, and flushPending when the
                // flag is ON. Only fold in the server error when this
                // syncAll actually RAN (a skipped in-flight pass leaves a stale lastHumanizedError —
                // surfacing it would be a phantom banner; same reasoning as the OFF branch's guard).
                // SOURCE-TAG the banner so a legacy-server-feed hiccup isn't misread as a CloudKit
                // failure (and vice-versa). The CloudKit copy is already iCloud-flavored.
                let serverRan = await sync.syncAll(householdID: household.id)
                if let ckError = coordinator.lastHumanizedError {
                    banner = ckError
                } else if serverRan, let serverError = sync.lastHumanizedError {
                    banner = "Server sync — \(serverError)"
                } else {
                    banner = nil
                }
            } else {
                let ran = await sync.syncAll(householdID: household.id)
                // Skipped (another sync already in flight): lastError still
                // holds the PREVIOUS pass's outcome — re-presenting it here
                // shows a phantom banner — and the post-sync orchestration
                // below would run against a mid-sweep store. The in-flight
                // caller does all of it when its pass finishes.
                guard ran else { return }
                banner = sync.lastHumanizedError
            }
            // Mirror the sync outcome into the user-facing banner.
            // SyncEngine isn't @Observable, so SwiftUI can't react to it
            // directly — we surface here instead, on the boundary that
            // every sync flows through. `lastHumanizedError` is the
            // humanizeError rendering (raw codes/statuses/body excerpts
            // stay in `lastError` for the Settings diagnostics row).
            // Debounce inside presentBanner keeps repeated identical
            // errors from strobing the UI.
            if let banner { presentBanner(banner) }
            let transitions = PetStateEngine.tickAll(
                householdID: activeGardenHouseholdID,
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
            await rescheduleWeeklyPetRoundup(householdID: activeGardenHouseholdID)
            // Phase 4C: refresh weather warnings if stale. Honors the
            // 2h staleness gate when called with `.foreground` so a
            // tab-back-in doesn't burn a WeatherKit fetch.
            _ = await weatherWarnings.refreshAllIfStale(reason: .foreground)
        }
    }

    private func noteHouseholdMutation() {
        guard FeatureFlags.cloudKitHouseholdSyncEnabled,
              case .signedIn(_, let household) = auth.state else { return }
        let coordinator = ensureCloudCoordinator(household: household)
        Task { await coordinator.save() }
    }

    // R1 — the CloudKit household coordinator, built lazily on first use when the flag is on and a
    // household is known. The cache key is the OWNER householdID, or for a participant the shared
    // zone name (so an account switch / share adopt rebuilds). nil/unused when the flag is off.
    @ObservationIgnored private var cloudCoordinator: HouseholdCloudCoordinator?
    @ObservationIgnored private var cloudCoordinatorKey: String?

    /// Read-only access to the live CloudKit coordinator for the Settings diagnostics panel
    /// (nil until the first sync after the flag is toggled on). Its @Observable state drives the UI.
    var cloudKit: HouseholdCloudCoordinator? { cloudCoordinator }

    /// Household ID that scopes locally stored garden data. In a CloudKit shared
    /// garden, the owner's zone is authoritative; server-only/rollback mode
    /// deliberately remains on the signed-in household.
    var activeGardenHouseholdID: String? {
        guard case .signedIn(_, let household) = auth.state else { return nil }
        return ActiveGardenContext.householdID(
            signedInHouseholdID: household.id,
            participantZoneName: loadParticipantMarker()?.zoneName,
            cloudKitSyncEnabled: FeatureFlags.cloudKitHouseholdSyncEnabled
        )
    }

    /// Owner (private DB) coordinator for the user's own household, OR — if this device has adopted a
    /// shared household (participant marker present) — a participant coordinator on the owner's shared
    /// zone. Participant-first: the marker is checked before the owner path so a relaunch re-boots as
    /// participant and never orphan-mints a solo zone.
    private func ensureCloudCoordinator(household: HouseholdDTO) -> HouseholdCloudCoordinator {
        if let marker = loadParticipantMarker() {
            if let existing = cloudCoordinator, cloudCoordinatorKey == marker.zoneName { return existing }
            let coordinator = HouseholdCloudCoordinator.participant(ownerZoneID: marker.zoneID, container: container)
            cloudCoordinator = coordinator
            cloudCoordinatorKey = marker.zoneName
            return coordinator
        }
        if let existing = cloudCoordinator, cloudCoordinatorKey == household.id { return existing }
        let coordinator = HouseholdCloudCoordinator.live(
            householdID: household.id,
            householdName: household.name,
            householdCreatedAt: household.created_at,
            householdUpdatedAt: household.updated_at,
            container: container
        )
        cloudCoordinator = coordinator
        cloudCoordinatorKey = household.id
        return coordinator
    }

    // MARK: - CloudKit household sharing (participant cutover)

    /// Whether this device is currently viewing a SHARED household (adopted via a CKShare) rather
    /// than its own. Drives the Settings "you're viewing a shared garden / Leave" affordance.
    var isViewingSharedHousehold: Bool { loadParticipantMarker() != nil }

    struct ParticipantMarker {
        let zoneName: String
        let ownerName: String
        var zoneID: CKRecordZone.ID { CKRecordZone.ID(zoneName: zoneName, ownerName: ownerName) }
    }
    @ObservationIgnored private let markerZoneKey = ActiveGardenContext.participantZoneNameDefaultsKey
    @ObservationIgnored private let markerOwnerKey = ActiveGardenContext.participantOwnerNameDefaultsKey

    func loadParticipantMarker() -> ParticipantMarker? {
        let d = UserDefaults.standard
        guard let zone = d.string(forKey: markerZoneKey), !zone.isEmpty,
              let owner = d.string(forKey: markerOwnerKey), !owner.isEmpty else { return nil }
        return ParticipantMarker(zoneName: zone, ownerName: owner)
    }
    private func saveParticipantMarker(_ m: ParticipantMarker) {
        UserDefaults.standard.set(m.zoneName, forKey: markerZoneKey)
        UserDefaults.standard.set(m.ownerName, forKey: markerOwnerKey)
    }
    private func clearParticipantMarker() {
        UserDefaults.standard.removeObject(forKey: markerZoneKey)
        UserDefaults.standard.removeObject(forKey: markerOwnerKey)
    }

    /// OWNER: create (or fetch) the household's zone-wide CKShare for `UICloudSharingController`.
    /// Returns nil if not signed in, already a participant, or on error (surfaced to the banner).
    func prepareOwnerShare() async -> (share: CKShare, container: CKContainer)? {
        guard case .signedIn(_, let household) = auth.state, !isViewingSharedHousehold else { return nil }
        do {
            let flow = SeedkeepShareFlow()
            let share = try await flow.makeOrFetchZoneWideShare(householdID: household.id, title: household.name)
            return (share, flow.container)
        } catch {
            surfaceError(error)
            return nil
        }
    }

    /// Warm-tap entry from the scene delegate: drain a just-accepted share + adopt it.
    func processPendingShare() async {
        guard let metadata = PendingShareInbox.shared.take() else { return }
        await bootParticipant(accepting: metadata)
    }

    /// Invite code forwarded from `ShareSceneDelegate`. The custom scene delegate REPLACES SwiftUI's,
    /// which can suppress `.onOpenURL`/`.onContinueUserActivity` — so the delegate forwards URL opens
    /// here and `SeedkeepApp` bridges this into the existing invite sheet. Observable so the bridge fires.
    var incomingInviteCode: String?
    /// Route an incoming URL (custom scheme or universal link) to the invite flow, if it is one.
    func routeIncomingURL(_ url: URL) {
        if let code = InviteURLRouter.invitationCode(from: url) { incomingInviteCode = code }
    }

    /// Accept a zone-wide CKShare and adopt the owner's household: wipe this device's own local garden
    /// (clean swap — the participant's own data stays in their own CloudKit zone, restored on Leave),
    /// persist the participant marker, rebuild as a participant coordinator, and sync.
    func bootParticipant(accepting metadata: CKShare.Metadata) async {
        if metadata.participantRole == .owner { return }   // owner tapped their own link — benign no-op
        guard metadata.containerIdentifier == "iCloud.app.seedkeep" else { return }
        do {
            let flow = SeedkeepShareFlow()
            let zoneID = try await flow.acceptZoneWideShare(metadata)
            HouseholdCloudCoordinator.wipeHouseholdSwiftData(container: container)
            // Reset the shared-zone token so the rebuilt participant coordinator does a FULL re-fetch
            // (re-adopting a previously-left share would otherwise resume a stale cursor → empty store).
            HouseholdCloudCoordinator.resetStateToken(at: HouseholdCloudCoordinator.participantStateTokenURL(zoneName: zoneID.zoneName))
            saveParticipantMarker(ParticipantMarker(zoneName: zoneID.zoneName, ownerName: zoneID.ownerName))
            cloudCoordinator = nil; cloudCoordinatorKey = nil   // force rebuild as participant
            await syncIfPossible()
        } catch {
            // Re-deposit so a foreground retry re-attempts the accept rather than falling through to
            // owner discovery (which would orphan-mint a solo zone). A permanently bad share just
            // keeps surfacing — never corrupts data.
            PendingShareInbox.shared.deposit(metadata)
            surfaceError(error)
        }
    }

    /// Leave the shared household: clear the marker + wipe the shared local data + drop the participant
    /// coordinator so the next sync rebuilds the OWNER coordinator (the user's own zone re-syncs).
    func leaveSharedHousehold() async {
        clearParticipantMarker()
        HouseholdCloudCoordinator.wipeHouseholdSwiftData(container: container)
        // Reset the OWNER token so the rebuilt owner coordinator does a FULL re-fetch — re-downloading
        // the user's own (parked, intact) CloudKit zone into the just-wiped SwiftData. Without this, the
        // resumed cursor sees no changes since adopt and the user's own garden would stay empty locally.
        if case .signedIn(_, let household) = auth.state {
            HouseholdCloudCoordinator.resetStateToken(at: HouseholdCloudCoordinator.ownerStateTokenURL(householdID: household.id))
        }
        cloudCoordinator = nil; cloudCoordinatorKey = nil
        await syncIfPossible()
    }

    /// Phase 5.1.4 — recompute the Sunday-8am pet roundup body from the
    /// current household snapshot. Gated server-side by the Settings
    /// toggle; this function is safe to call regardless.
    private func rescheduleWeeklyPetRoundup(householdID: String) async {
        let context = ModelContext(container)
        // 3-condition predicates trip the SwiftData macro type-checker;
        // gate the two cheap server-side flags here + filter petSeed in code.
        let descriptor = FetchDescriptor<LocalPlantingEvent>(
            predicate: #Predicate<LocalPlantingEvent> { event in
                event.deletedAt == nil && event.completedAt == nil
            }
        )
        guard let fetched = try? context.fetch(descriptor) else { return }
        let candidates = fetched.filter { $0.householdID == householdID && $0.petSeed != nil }
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
        // cloudKitDatabase: .none — keep the SwiftData store LOCAL-ONLY. Once the iCloud/CloudKit
        // capability is added, ModelConfiguration's default `.automatic` makes SwiftData try to
        // mirror to CloudKit, which validates the schema against CloudKit's rules and THROWS on our
        // `@Attribute(.unique) var id` models (CloudKit forbids unique constraints — spec gotcha G1).
        // Seedkeep does NOT use SwiftData/NSPersistentCloudKitContainer auto-mirroring: the shared
        // household zone is synced by our own CKSyncEngine stack (SeedkeepCloudKit). SwiftData is the
        // local source of truth only.
        let config = ModelConfiguration("seedkeep", schema: schema, cloudKitDatabase: .none)
        do {
            return try ModelContainer(for: schema, configurations: config)
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }
}
