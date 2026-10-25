import Foundation
import SwiftUI
import SwiftData
import SeedkeepKit
import SeedkeepCloudKit
import CloudKit

/// Reads launch-time configuration from `Info.plist` (the Keychain service), wires the SwiftData
/// `ModelContainer`, the `SyncEngine`, the `JournalStore`, the CloudKit coordinator and the
/// `AuthController`. SwiftUI views read this as an `@Environment`.
@MainActor
@Observable
public final class AppEnvironment {
    let auth: AuthController
    /// N2-E: the garden guard store (binding authority, creation grants, discovery record).
    let gardenGuard: GardenGuardStore
    /// N2-E seam: where the silent re-home (G3) runs.
    @ObservationIgnored let gardenRehomer: any GardenRehoming
    /// N2-E: the guard runner (one per app). It owns the guard transitions and the scope epoch;
    /// every window shares it through this environment.
    let gardenRunner: GardenGuardRunner
    /// N2-E: where garden-scoped notifications are scheduled and removed.
    @ObservationIgnored var ownerShares: any OwnerShareMaking = LiveOwnerShareMaker()
    @ObservationIgnored var notifier: any GardenNotifying = LiveGardenNotifier() {
        didSet { sync.notifier = notifier }
    }
    public let container: ModelContainer
    public let sync: SyncEngine
    public let recommendations: RecommendationStore
    let journal: JournalStore
    public let preferences: AppPreferences
    public let apiKeys: APIKeyStore
    /// Phase 4C — orchestrator for frost / heat / water weather warnings.
    /// Replaces the old `NotificationsCenter.refreshFrostWarnings` path.
    let weatherWarnings: WeatherWarningsService

    /// Lets feature views request a tab switch (e.g. Today → Garden).
    /// MainTabView observes this and binds it to the TabView's
    /// selection. nil means leave whatever's current.
    public var requestedTab: AppTab?

    /// User-facing error banner string. Set via `surfaceError` from call
    /// sites that previously swallowed `try?`, or mirrored from the
    /// CloudKit coordinator after a sync completes. `nil` hides the banner.
    public var bannerError: String?

    /// Debounce state — the last string we surfaced + when. Repeated
    /// identical errors within 5 seconds are dropped so retry loops in
    /// `SyncEngine` don't strobe the banner.
    @ObservationIgnored private var lastBannerString: String?
    @ObservationIgnored private var lastBannerTime: Date?

    /// The compact interface's tabs, in order. Settings replaced You in R2b.
    public enum AppTab: Hashable, CaseIterable {
        case today, seeds, garden, journal, settings

        var title: String {
            switch self {
            case .today: return "Today"
            case .seeds: return "Seeds"
            case .garden: return "Garden"
            case .journal: return "Journal"
            case .settings: return "Settings"
            }
        }

        var systemImage: String {
            switch self {
            case .today: return "sun.max"
            case .seeds: return "leaf"
            case .garden: return "square.grid.3x3.topleft.filled"
            case .journal: return "book"
            case .settings: return "gearshape"
            }
        }

        /// The tab's name in accessibility identifiers: `tab.<name>` on its tab button and `screen.<name>` on its root.
        var identifier: String {
            switch self {
            case .today: return "today"
            case .seeds: return "seeds"
            case .garden: return "garden"
            case .journal: return "journal"
            case .settings: return "settings"
            }
        }
    }

    public static func live() -> AppEnvironment {
        // Fail closed, in every build: an audit launch must be sample-garden mode. This runs before anything
        // live is built.
        if AuditLaunch.decision(arguments: CommandLine.arguments, sampleGarden: DevicePreferences.isSampleGarden) == .refuse {
            preconditionFailure("-SeedkeepAuditLaunch needs sample-garden mode (a DEBUG build with -SeedkeepFixture); refusing a live launch")
        }
        #if DEBUG
        if FixtureMode.isEnabled { return makeForFixture() }
        #endif
        // N3: delete the files the removed account deletion and transfer left behind, before any
        // identity resolution or CloudKit coordinator. Never in the unit-test host (it shares the
        // real app's data) or in sample-garden mode (returned above).
        LegacyAccountDeletionCleanup.removeLegacyFiles(enabled: FeatureFlags.canRunLiveAppStartup)
        let prefs = AppPreferences()
        let keychainService = Self.resolveKeychainService()
        let store = legacyTokenStore(service: keychainService)
        let apiKeys = APIKeyStore(service: keychainService)
        // N1: the iCloud account is the identity. The token store is kept only so a legacy
        // rebind can clear the old Sign in with Apple bearer token.
        let gardenGuard = GardenGuardStore.live()
        let rehomer = DeferredGardenRehomer()
        let gardenRunner = GardenGuardRunner(store: gardenGuard, rehomer: rehomer)
        let auth = AuthController(identity: LiveCloudIdentityProvider(), tokenStore: store,
                                  guardStore: gardenGuard, rehomer: rehomer)
        let container = Self.makeModelContainer()
        let sync = SyncEngine(container: container)
        // Stabilization B3 — sign-out / identity-switch wipe is wired in init() (below), where the
        // AppEnvironment instance exists so the wipe can ALSO tear down the CloudKit coordinator
        // (state token + per-record synced-state file + migration marker), not just SwiftData. See
        // wireSignOutEraser().
        let recommendations = RecommendationStore(preferences: prefs)
        let journal = JournalStore(container: container)
        // Phase 4C — weather warnings service. Replaces the legacy
        // `NotificationsCenter.refreshFrostWarnings` path with the
        // actor-orchestrated frost/heat/water flow. Providers are
        // wired here so tests can swap them out via a separate init.
        // The scope token the weather service schedules under: the active garden and the scope epoch,
        // nil while the garden is gone. It is wired to the environment once that exists (below).
        let scopeBox = WritableScopeBox()
        let weatherWarnings = WeatherWarningsService(
            container: container,
            provider: WeatherKitProvider(container: container),
            scheduler: SystemNotificationScheduler(),
            planting: SwiftDataPlantingEventQuery(container: container),
            wateringState: LocalWateringStateClient(),
            clock: SystemClock(),
            thresholds: .kc,
            householdIDProvider: { @MainActor [weak auth] in
                guard case .signedIn(_, let household) = auth?.state else { return nil }
                return ActiveGardenContext.householdID(
                    signedInHouseholdID: household.id,
                    participantZoneName: ActiveGardenContext.participantZoneName()
                )
            },
            scopeProvider: { @MainActor in scopeBox.token() },
            preferencesProvider: { @MainActor [weak prefs] in
                (lat: prefs?.cachedLatitude, lon: prefs?.cachedLongitude)
            },
            togglesProvider: { @MainActor in
                (
                    frost: DevicePreferences.store.bool(forKey: "seedkeep.notif.frost"),
                    heat: DevicePreferences.store.bool(forKey: "seedkeep.notif.heat"),
                    water: DevicePreferences.store.bool(forKey: "seedkeep.notif.water")
                )
            }
        )
        let env = AppEnvironment(
            auth: auth, container: container,
            sync: sync, recommendations: recommendations,
            journal: journal,
            preferences: prefs, apiKeys: apiKeys,
            weatherWarnings: weatherWarnings,
            gardenGuard: gardenGuard, gardenRehomer: rehomer, gardenRunner: gardenRunner
        )
        scopeBox.environment = env
        return env
    }

    /// N1 test seam: an environment over `container` and a fake identity provider, with every
    /// durable side effect pointed at the caller's `defaults` and `durableStateDirectory`, and
    /// without the background services `live()` starts (weather observers, notifier).
    /// `cloudCoordinators` builds every CloudKit coordinator it needs: tests pass one over a fake
    /// engine (N3 T2), so the shipping CloudKit path runs without CloudKit or the network.
    /// `cloudKitPermitted: false` is the sample-garden seam (`makeForFixture`): CloudKit is never
    /// used, whatever the identity says, so no coordinator is ever built.
    static func makeForTesting(
        identity: any CloudIdentityProviding,
        tokenStore: any TokenStoring,
        defaults: UserDefaults,
        container: ModelContainer,
        durableStateDirectory: URL,
        legacyCheckpointDirectory: URL? = nil,
        scanStagingRoot: URL? = nil,
        cloudKitPermitted: Bool = true,
        cloudCoordinators: CloudCoordinatorFactory,
        gardenGuard: GardenGuardStore = GardenGuardStore(directory: nil),
        gardenRehomer: any GardenRehoming = DeferredGardenRehomer(),
        gardenRunner: GardenGuardRunner? = nil,
        notifier: (any GardenNotifying)? = nil,
        ownerShares: (any OwnerShareMaking)? = nil,
        deferringBackgroundServices: Bool = false,
        backgroundServiceStarter: (() -> Void)? = nil,
        makeHouseholdID: @escaping () -> String = { GardenHouseholdID.make() },
        forecastSource: @escaping RecommendationStore.ForecastSource = WeatherKitRefiner.fetchForecast,
        apiKeys: APIKeyStore = APIKeyStore(service: "app.seedkeep.tests.\(UUID().uuidString)")
    ) -> AppEnvironment {
        let prefs = AppPreferences(defaults: defaults)
        let runner = gardenRunner ?? GardenGuardRunner(store: gardenGuard, rehomer: gardenRehomer)
        let auth = AuthController(identity: identity, tokenStore: tokenStore, defaults: defaults,
                                  guardStore: gardenGuard, rehomer: gardenRehomer,
                                  makeHouseholdID: makeHouseholdID)
        let sync = SyncEngine(container: container)
        let weatherWarnings = WeatherWarningsService(
            container: container,
            provider: WeatherKitProvider(container: container),
            scheduler: SystemNotificationScheduler(),
            planting: SwiftDataPlantingEventQuery(container: container),
            wateringState: LocalWateringStateClient(defaults: defaults),
            clock: SystemClock(),
            thresholds: .kc,
            householdIDProvider: { nil },
            preferencesProvider: { (lat: nil, lon: nil) },
            togglesProvider: { (frost: false, heat: false, water: false) }
        )
        let env = AppEnvironment(
            auth: auth, container: container,
            sync: sync,
            recommendations: RecommendationStore(preferences: prefs, forecastSource: forecastSource),
            journal: JournalStore(container: container),
            preferences: prefs, apiKeys: apiKeys,
            weatherWarnings: weatherWarnings,
            stateDefaults: defaults,
            durableStateDirectory: durableStateDirectory,
            scanStagingRoot: scanStagingRoot ?? FileManager.default.temporaryDirectory
                .appendingPathComponent("scan-staging-\(UUID().uuidString)", isDirectory: true),
            startsBackgroundServices: false,
            cloudKitPermitted: cloudKitPermitted,
            cloudCoordinators: cloudCoordinators,
            gardenGuard: gardenGuard, gardenRehomer: gardenRehomer, gardenRunner: runner
        )
        env.clearAppNotifications = {}
        env.notifier = notifier ?? NoopGardenNotifier()
        if let ownerShares { env.ownerShares = ownerShares }
        env.backgroundServiceStarter = backgroundServiceStarter
        if deferringBackgroundServices { env.deferringBackgroundServices = true }
        // N3 test seam: the live launch's legacy-file cleanup, over the caller's directories.
        if let legacyCheckpointDirectory {
            LegacyAccountDeletionCleanup.removeLegacyFiles(
                enabled: true, checkpointDirectory: legacyCheckpointDirectory,
                householdSyncDirectory: durableStateDirectory)
        }
        return env
    }

    #if DEBUG
    /// Sample-garden mode (DEBUG, `-SeedkeepFixture`): the test seam's wiring with CloudKit off.
    /// Background services stay off and every durable path points into a fixture directory. The
    /// defaults suite is cleared at each launch, so the identity cache, home ZIP and garden marker
    /// start empty. The store is in memory and seeded by `FixtureSampleGarden`. The identity is
    /// fixed. The iCloud account and the retired server are not reached.
    /// `temporaryRoot` holds the launch's scratch directory (tests pass their own). The notification
    /// override is process-wide, so it's installed only in a real sample-garden launch, never by tests.
    static func makeForFixture(
        temporaryRoot: URL = FileManager.default.temporaryDirectory,
        installsNotificationOverride: Bool = FixtureMode.isEnabled
    ) -> AppEnvironment {
        // Fail closed: without its own suite the fixture must not run, and must never fall back to
        // `.standard` (the real app's identity cache and preferences). Fixture mode is a debug tool,
        // so a missing suite stops the launch instead of starting the normal app.
        let suite = FixtureMode.defaultsSuiteName
        guard let defaults = UserDefaults(suiteName: suite) else {
            preconditionFailure("Sample-garden mode needs its own defaults suite (\(suite)); refusing to run without it")
        }
        defaults.removePersistentDomain(forName: suite)
        // The launch's appearance (`-SeedkeepAppearance`), written before any view exists.
        if let appearance = AuditLaunch.appearanceOverride(arguments: CommandLine.arguments) {
            defaults.set(appearance.rawValue, forKey: AppAppearance.storageKey)
        }
        // A fresh scratch directory per launch; older fixture directories are removed here.
        let root = FixtureMode.prepareLaunchRoot(in: temporaryRoot)
        // The fixture never reads the real authorization status: the Notifications screen reads this override.
        if installsNotificationOverride {
            NotificationsCenter.shared.authorizationStatusOverrideForTesting = FixtureMode.authorizationStatus
        }
        let container = makeModelContainer(inMemory: true)
        let env = makeForTesting(
            identity: FixtureCloudIdentityProvider(),
            tokenStore: FixtureTokenStore(),
            defaults: defaults,
            container: container,
            durableStateDirectory: root.appendingPathComponent("sync", isDirectory: true),
            scanStagingRoot: root.appendingPathComponent("scan-staging", isDirectory: true),
            cloudKitPermitted: false,
            // Never called: with `cloudKitPermitted` false no coordinator is built.
            cloudCoordinators: .live,
            forecastSource: FixtureMode.forecastSource,
            apiKeys: APIKeyStore(backend: InMemoryAPIKeyBackend())
        )
        do {
            try FixtureSampleGarden.seed(
                into: container.mainContext,
                householdID: FixtureCloudIdentityProvider.householdID,
                preferences: env.preferences
            )
        } catch {
            fatalError("Could not seed the sample garden: \(error)")
        }
        return env
    }
    #endif

    private init(
        auth: AuthController,
        container: ModelContainer,
        sync: SyncEngine,
        recommendations: RecommendationStore,
        journal: JournalStore,
        preferences: AppPreferences,
        apiKeys: APIKeyStore,
        weatherWarnings: WeatherWarningsService,
        stateDefaults: UserDefaults = .standard,
        durableStateDirectory: URL = HouseholdCloudCoordinator.householdSyncDirURL(),
        scanStagingRoot: URL = ScanPhotoStaging.rootURL(),
        startsBackgroundServices: Bool = true,
        cloudKitPermitted: Bool = true,
        cloudCoordinators: CloudCoordinatorFactory = .live,
        gardenGuard: GardenGuardStore,
        gardenRehomer: any GardenRehoming,
        gardenRunner: GardenGuardRunner
    ) {
        self.gardenGuard = gardenGuard
        self.gardenRehomer = gardenRehomer
        self.gardenRunner = gardenRunner
        self.cloudKitPermitted = cloudKitPermitted
        self.cloudCoordinators = cloudCoordinators
        self.auth = auth
        self.container = container
        self.sync = sync
        self.recommendations = recommendations
        self.journal = journal
        self.preferences = preferences
        self.apiKeys = apiKeys
        self.weatherWarnings = weatherWarnings
        self.stateDefaults = stateDefaults
        self.durableStateDirectory = durableStateDirectory
        self.scanStagingRoot = scanStagingRoot
        sync.onLocalHouseholdMutation = { [weak self] in self?.noteHouseholdMutation() }
        journal.onLocalHouseholdMutation = { [weak self] in self?.noteHouseholdMutation() }
        // N2-E: the write fence (contract §6) and its epoch. Every identity transition and binding
        // change bumps the scope epoch; the gone handling does too, and also cancels notifications.
        sync.writeFence = GardenWriteFence(current: { [weak self] in self?.writableGarden })
        journal.writeFence = GardenWriteFence(current: { [weak self] in self?.writableGarden })
        auth.onScopeChange = { [weak gardenRunner] in gardenRunner?.bumpScopeEpoch() }
        gardenRunner.onGardenLost = { [weak self] event in self?.gardenLost(event) }
        // N1: the scope ID is derived, never a coordinator, and not gated on `canUseCloudKit`, so a
        // local delete made while CloudKit is paused still records its deletion intent.
        sync.cloudKitScopeIDProvider = { [weak self] in
            guard let self, case .signedIn(_, let household) = self.auth.state else { return nil }
            return self.cloudKitScopeID(household: household)
        }
        sync.onCloudKitPhotoCacheMiss = { [weak self] recordName in
            guard let self, self.canUseCloudKit, self.writableGarden != nil,
                  case .signedIn(_, let household) = self.auth.state else { return nil }
            return try await self.ensureCloudCoordinator(household: household)
                .recoverPhotoAssetData(recordName: recordName)
        }
        journal.cloudKitScopeIDProvider = { [weak self] in
            guard let self, case .signedIn(_, let household) = self.auth.state else { return nil }
            return self.cloudKitScopeID(household: household)
        }
        // Phase 4C — wire `NotificationCenter.default` observers
        // (active-plantings debounce + system-timezone-change). The
        // service is idempotent so a second start() is a no-op.
        // N2-E: a launch that found a journal or a gone entry mutates nothing until `restoreSession`
        // has verified the owning account and the runner has resumed (`resumeGuardAfterLaunch`).
        if startsBackgroundServices {
            if gardenRunner.isLaunchResolved { startBackgroundServices() } else { deferringBackgroundServices = true }
        }
        // Stabilization B3 + R1 — sign-out / identity-switch wipe. Erases every model (generic over
        // SeedkeepSchema.all — includes legacy pending-write and sync-cursor rows), drops notifications,
        // AND tears down the CloudKit coordinator (engine state token + per-record synced-state file +
        // migration marker) and nils its reference so a re-sign-in to the SAME household rebuilds a
        // fresh coordinator that re-provisions + rehydrates rather than reusing a stale `started` one.
        // N1: THROWS when the wipe is incomplete, so AuthController binds nothing over a store that
        // still holds the previous account's data (it enters `.failed` with Retry instead).
        auth.wireLocalDataEraser { [weak self] in
            guard let self else { return }
            try self.sync.eraseAllLocalData()
            // N2: staged packet photos belong to the previous account. Open scan and save sheets stop
            // first (V1). Checked, like the rest.
            try self.purgeScanStaging()
            self.clearAppNotifications()
            // N1: every scope's CloudKit state, even with no coordinator built yet (launch).
            try self.resetHouseholdCloudState(wipingHouseholdRows: false)
            // The previous user's pending shares are not this user's to adopt (a share delivered
            // before any identity resolved stays). The epoch tells an adoption still awaiting
            // CloudKit to drop its share rather than put it back.
            PendingShareInbox.shared.removeResolvedDeposits()
            #if os(macOS)
            MacPendingShareQueue.shared.removeResolvedDeposits()
            #endif
            self.shareAccepts.removeAll()
            self.pendingShareEpoch += 1
            self.clearParticipantMarker()   // sign-out abandons any adopted shared household too
        }
        // N1: a chooser discard (same iCloud user, another garden) removes only this device's
        // garden and its CloudKit state. Device-only data (journal recovery items, forecasts, pet
        // snapshots, notifications) stays; the marker is rewritten by the binding that follows.
        auth.wireGardenSwitchEraser { [weak self] in
            guard let self else { return }
            try self.resetHouseholdCloudState(wipingHouseholdRows: true)
            // N2: staged packet photos belong to the discarded garden. Open scan and save sheets stop
            // first (V1).
            try self.purgeScanStaging()
        }
        // N1: a shared garden found or chosen at resolution gets the same fresh start as an
        // accepted share (`bootParticipant`): a full re-fetch, never a cursor from an earlier join.
        // THROWS on a failed reset, so the binding stops in `.failed` instead of joining over a
        // stale cursor.
        auth.wireParticipantGardenAdopted { [weak self] zoneName, ownerName in
            guard let self else { return }
            try HouseholdCloudCoordinator.resetStateToken(
                at: HouseholdCloudCoordinator.participantStateTokenURL(
                    ownerZoneID: CKRecordZone.ID(zoneName: zoneName, ownerName: ownerName)))
            self.cloudCoordinator = nil
            self.cloudCoordinatorKey = nil
        }
        // N1: an iCloud account change re-resolves the identity. The notification alone never
        // wipes; AuthController wipes only for a confirmed different user. Never in the unit-test
        // host, which must not make live CloudKit identity calls. Sample-garden mode has no CloudKit either.
        if FeatureFlags.canRunLiveAppStartup, cloudKitPermitted {
            accountChangeObserver = NotificationCenter.default.addObserver(
                forName: .CKAccountChanged, object: nil, queue: .main
            ) { [weak self] _ in
                // Pause CloudKit before returning (queue `.main`), then revalidate.
                MainActor.assumeIsolated { self?.auth.pauseForAccountChange() }
                Task { @MainActor in await self?.auth.revalidateAfterAccountChange() }
            }
        }
    }

    /// N2: where scan photos are staged (`ScanPhotoStaging.rootURL()` live; a temporary directory in
    /// tests). Every local-data eraser purges it.
    @ObservationIgnored let scanStagingRoot: URL
    @ObservationIgnored private var didResumeStagedScans = false

    /// N2 (V1): bumped by every local-data eraser before it purges scan staging. An open scan or save
    /// sheet bound to an older epoch stops and discards its scan.
    private(set) var scanSessionEpoch = 0

    /// What a scan or save sheet binds to when it starts: the signed-in user, the active garden and
    /// the scan epoch. nil while signed out, and nil while the garden is gone or awaiting a choice
    /// (N2-E: a save that started before then fails its scope check at the attach and discards its
    /// scan). The epoch combines the scan epoch with `gardenScopeEpoch`, so a binding change or a gone
    /// garden under an open sheet stops it.
    var scanBinding: ScanPhotoStaging.ScanBinding? {
        guard case .signedIn(let user, _) = auth.state, let householdID = activeGardenHouseholdID,
              let writable = writableGarden else { return nil }
        return ScanPhotoStaging.ScanBinding(
            scope: ScanPhotoStaging.Scope(userRecordName: user.id, householdID: householdID),
            epoch: scanSessionEpoch &+ writable.epoch
        )
    }

    // MARK: - Write fence (N2-E §6)

    /// `gardenScopeEpoch`: bumped on gone, on every binding change and on every account transition.
    var gardenScopeEpoch: Int { gardenRunner.scopeEpoch }

    /// The active garden plus the scope epoch; nil while the bound garden is gone, awaiting a choice
    /// or under a running journal. Signed out, no garden is active and nothing is gone, so the value
    /// carries no garden but the epoch still moves. Every writer captures it when it starts and
    /// re-checks it at its final mutation boundary.
    var writableGarden: WritableGarden? {
        let epoch = gardenRunner.scopeEpoch
        guard case .signedIn(let user, _) = auth.state else {
            return WritableGarden(householdID: nil, epoch: epoch)
        }
        guard let householdID = activeGardenHouseholdID else { return nil }
        let account = GardenGuardStore.accountKey(recordName: user.id)
        if gardenRunner.isBlocked(account: account, householdID: householdID) { return nil }
        return WritableGarden(householdID: householdID, epoch: epoch)
    }

    /// True while `captured` is still the current writable garden in the same epoch.
    func gardenWriteStillValid(_ captured: WritableGarden?) -> Bool {
        guard let captured else { return false }
        return writableGarden == captured
    }

    /// The active garden is gone and waits for the user's choice. Every window shows the placeholder.
    var isActiveGardenGone: Bool {
        guard case .signedIn(let user, _) = auth.state, let householdID = activeGardenHouseholdID else { return false }
        return gardenGuard.isGone(GardenGuardStore.accountKey(recordName: user.id), householdID)
            || gardenRunner.isMemoryFenced(account: GardenGuardStore.accountKey(recordName: user.id), householdID: householdID)
    }

    /// The scope token the weather service schedules under: the garden and the epoch, nil while the
    /// garden is gone.
    func writableScopeToken() -> String? {
        guard let writable = writableGarden else { return nil }
        return "\(writable.householdID ?? "-")#\(writable.epoch)"
    }

    /// The gone step's last part (contract §6, step 3): the pending shares belong to a scope that
    /// ended, and the garden's notifications are cancelled. The runner already bumped the scope epoch.
    fileprivate func gardenLost(_ event: GardenGoneEvent) {
        pendingShareEpoch += 1
        notifier.removeAll()
        scanSessionEpoch += 1   // an open scan or save sheet stops and discards its scan
    }

    // MARK: - Launch ordering (N2-E §6)

    /// True while a launch that found a journal or gone entry waits for `restoreSession` and the
    /// runner. Windows show progress instead of a garden, and no startup task runs.
    var isLaunchGuardPending: Bool { !gardenRunner.isLaunchResolved }

    @ObservationIgnored private var launchGuardResumed = false
    @ObservationIgnored var deferringBackgroundServices = false
    @ObservationIgnored var backgroundServiceStarter: (() -> Void)?
    @ObservationIgnored private(set) var backgroundServicesStarted = false

    /// Weather observers, the frost-date backfill and the retired-notification clean-up. Started at
    /// launch, or after the guard has resumed when it held a journal or gone entry.
    func startBackgroundServices() {
        guard !backgroundServicesStarted else { return }
        backgroundServicesStarted = true
        if let backgroundServiceStarter { backgroundServiceStarter(); return }
        Task { await weatherWarnings.start() }
        // N2 — a home ZIP saved before frost dates were cached gets them from the bundled table.
        // Live launches only: the unit-test host never writes the shared preferences.
        if FeatureFlags.canRunLiveAppStartup {
            Task { [weak self] in
                guard let self else { return }
                let captured = self.writableGarden
                await self.preferences.backfillFrostDates(isWritable: { [weak self] in
                    self?.gardenWriteStillValid(captured) ?? false
                })
            }
            // N3 — catalog correction outcomes came from the retired server; clear any left behind.
            Task { await NotificationsCenter.shared.clearRetiredCatalogNotifications() }
        }
    }

    /// Launch step after `restoreSession` (contract §6): the runner resumes for the account that
    /// resolution verified (another account's entries are left alone), then the background services
    /// that waited start, and windows may show a garden.
    func resumeGuardAfterLaunch() {
        // Only with a verified account (and a readable guard): otherwise the gate stays closed and
        // the deferred services wait, over a garden that may hold a journal. A later call, once
        // verification succeeds, does the resume.
        guard auth.isIdentityVerified, let account = auth.currentAccountKey, gardenGuard.isReadable else { return }
        gardenRunner.resume(accountKey: account)
        // A garden found gone in an earlier run has no notifications.
        if !launchGuardResumed, isActiveGardenGone { notifier.removeAll() }
        launchGuardResumed = true
        if deferringBackgroundServices {
            deferringBackgroundServices = false
            startBackgroundServices()
        }
    }

    /// Invalidates every open scan and save sheet, then deletes all staged scan photos. Throws when
    /// the staging cannot be removed.
    func purgeScanStaging() throws {
        scanSessionEpoch += 1
        try ScanPhotoStaging.purgeAll(root: scanStagingRoot)
    }

    /// N2: finishes any scan save that was cut short, and drops staging from scans that never saved
    /// or belong to another account or garden. Runs once per launch, only after the iCloud identity
    /// is confirmed (`.signedIn`, verified), so it is scoped to that user and the active garden.
    /// Local work only, so it needs no network. Never in the unit-test host.
    func resumeStagedScansIfNeeded() async {
        guard FeatureFlags.canRunLiveAppStartup, !didResumeStagedScans, auth.isIdentityVerified,
              case .signedIn(let user, _) = auth.state,
              let householdID = activeGardenHouseholdID else { return }
        didResumeStagedScans = true
        await ScanSave.resumeStagedScans(
            writer: sync,
            container: container,
            scope: ScanPhotoStaging.Scope(userRecordName: user.id, householdID: householdID),
            root: scanStagingRoot
        )
    }

    @ObservationIgnored private var accountChangeObserver: (any NSObjectProtocol)?
    /// False only in sample-garden mode, where CloudKit is never used (`canUseCloudKit` stays false).
    @ObservationIgnored private let cloudKitPermitted: Bool
    /// Holds the participant marker and migration markers (`.standard` live; a test suite in tests).
    @ObservationIgnored private let stateDefaults: UserDefaults
    /// `HouseholdCloudCoordinator.householdSyncDir()` live; a temporary directory in tests.
    @ObservationIgnored private let durableStateDirectory: URL

    /// Shared by both local-data erasers. Tears down the coordinator if one exists (throwing, and
    /// keeping it, when its cleanup must be retried); without one, `wipingHouseholdRows` removes
    /// the household rows and pending CloudKit deletions directly. Then removes every scope's
    /// durable CloudKit state, migration markers and photo bytes.
    private func resetHouseholdCloudState(wipingHouseholdRows: Bool) throws {
        if let coordinator = cloudCoordinator {
            coordinator.wipeAndClear()
            // Keep the coordinator: it holds what the retry has to finish.
            guard !coordinator.requiresWipeRetry else {
                throw LocalDataEraseError.cloudStateNeedsRetry(message: coordinator.lastHumanizedError)
            }
        }
        if wipingHouseholdRows {
            try HouseholdCloudCoordinator.wipeHouseholdSwiftData(container: container)
            // Deletions not yet pushed are unsynced changes of the discarded garden too.
            let context = ModelContext(container)
            for intent in try context.fetch(FetchDescriptor<LocalCloudKitDeletion>()) { context.delete(intent) }
            try context.save()
        }
        try HouseholdCloudCoordinator.resetAllDurableState(
            directory: durableStateDirectory, defaults: stateDefaults)
        cloudCoordinator = nil
        cloudCoordinatorKey = nil
    }

    /// The local-data eraser could not finish; the identity transition waits for a retry.
    enum LocalDataEraseError: Error, LocalizedError {
        case cloudStateNeedsRetry(message: String?)

        var errorDescription: String? {
            switch self {
            case .cloudStateNeedsRetry(let message):
                return message ?? "This device's iCloud garden state could not be cleared. Try again."
            }
        }
    }

    /// Surfaces an error to the user via `bannerError`. Replaces silent
    /// `try?` swallows at call sites where the user needs to know
    /// something went wrong (local write failures, sharing, etc).
    public func surfaceError(_ error: Error) {
        presentBanner(humanizeError(error))
    }

    /// Surfaces an already-worded message via `bannerError` (same banner and debounce as
    /// `surfaceError`). Used where the message is built by the caller, such as a Seeds-table
    /// write or undo report, so it shows in the window banner on every screen.
    public func surfaceMessage(_ message: String) {
        presentBanner(message)
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

    /// N2-E §5: shown to a participant whose `currentUserParticipant` permission is read-only.
    static let viewOnlyNotice = "You can view this shared garden but not change it."

    /// Triggers a CloudKit sync if the user is signed in. Safe to call repeatedly —
    /// overlapping passes are counted in `cloudSyncPassesInFlight`.
    ///
    /// After a sync, runs `PetStateEngine.tickAll` on every alive pet in the
    /// household — this is the single canonical place where mood snapshots
    /// are materialized and lifecycle transitions are detected.
    public func syncIfPossible(userInitiated: Bool = false) async {
        // N2-E: "Sync now" ends the wait that follows an abandoned garden creation.
        if userInitiated { gardenGuard.releaseCreationHolds() }
        if case .signedIn(_, let household) = auth.state {
            let activeGardenHouseholdID = self.activeGardenHouseholdID ?? household.id
            // Household garden data syncs through CloudKit, the only sync (N3 removed the server's
            // and the flag that selected it).
            // N1: CloudKit only on a confirmed identity. An unconfirmed one resolves first; a pass
            // that lands elsewhere (another garden, chooser) leaves this sync to the RootView task
            // its new state starts.
            if !auth.isIdentityVerified { await auth.restoreSession() }
            guard case .signedIn(_, let current) = auth.state, current == household,
                  self.activeGardenHouseholdID == activeGardenHouseholdID else { return }
            // N2-E: a gone garden (or one awaiting the user's choice) syncs nothing, runs no pet tick
            // and schedules no notification. The captured scope is re-checked after every await.
            guard let writable = writableGarden else { return }
            // N1: CloudKit paused (unconfirmed identity) or a share being adopted (its own sync
            // follows): skip only the CloudKit pass, with no banner. The local post-sync work below
            // still runs.
            if isAdoptingShare { syncSkippedForAdoption = true }
            let banner: String?
            if canUseCloudKit, !isAdoptingShare {
                // R1 27d.18 — participant stranded-row recovery. Only meaningful for a participant
                // (activeGardenHouseholdID resolves to the owner-zone ID, differing from the signed-in
                // ID); runs BEFORE the sync pass so re-homed rows are pushed by the pass that follows.
                if activeGardenHouseholdID != household.id {
                    let recovered = ParticipantRowRecovery.runIfNeeded(
                        container: container,
                        signedInHouseholdID: household.id,
                        ownerZoneHouseholdID: activeGardenHouseholdID,
                        isWritable: { [weak self] in self?.gardenWriteStillValid(writable) ?? false }
                    )
                    if recovered { noteHouseholdMutation() }
                }
                let coordinator = ensureCloudCoordinator(household: household)
                let ran = await runCloudSyncPass { await coordinator.sync() }
                guard ran else { return }
                // Only CloudKit errors can reach the sync banner. A pass that stopped (paused,
                // account changed) leaves an older error behind.
                // N2-E: a participant whose permission is confirmed read-only is told so once the pass
                // has fetched; sends stopped, fetching went on.
                banner = coordinator.isViewOnly
                    ? Self.viewOnlyNotice
                    : (coordinator.lastPassCompleted ? coordinator.lastHumanizedError : nil)
            } else {
                banner = nil
            }
            // Mirror the sync outcome into the user-facing banner, on the boundary that every
            // sync flows through. Debounce inside presentBanner keeps repeated identical errors
            // from strobing the UI.
            if let banner { presentBanner(banner) }
            PetStateEngine.tickAll(
                householdID: activeGardenHouseholdID,
                container: container,
                isWritable: { [weak self] in self?.gardenWriteStillValid(writable) ?? false }
            )
            // Phase 5.1.4: re-bake the weekly roundup body with the
            // current household snapshot. iOS preserves the next-fire
            // date when re-scheduling with the same identifier + same
            // DateComponents shape, so this is cheap to call every sync.
            await rescheduleWeeklyPetRoundup(householdID: activeGardenHouseholdID, captured: writable)
            // Phase 4C: refresh weather warnings if stale. Honors the
            // 2h staleness gate when called with `.foreground` so a
            // tab-back-in doesn't burn a WeatherKit fetch.
            _ = await weatherWarnings.refreshAllIfStale(reason: .foreground)
        }
    }

    private func noteHouseholdMutation() {
        // A share being adopted replaces this garden; its own sync pushes what remains.
        guard canUseCloudKit, !isAdoptingShare, writableGarden != nil,
              case .signedIn(_, let household) = auth.state else { return }
        let coordinator = ensureCloudCoordinator(household: household)
        Task { await coordinator.save() }
    }

    // R1 — the CloudKit household coordinator, built lazily on first use once a household is known
    // and CloudKit is allowed. The cache key is the complete CloudKit database/zone/owner scope so an
    // account switch or same-named share from another owner always rebuilds.
    @ObservationIgnored private var cloudCoordinator: HouseholdCloudCoordinator?
    @ObservationIgnored private var cloudCoordinatorKey: String?
    /// Builds the coordinators above: `.live` (CloudKit) in the app, a fake engine in tests.
    @ObservationIgnored private let cloudCoordinators: CloudCoordinatorFactory

    /// N1 (parent-owned seam): CloudKit use (coordinator creation, sync, saves, photo recovery,
    /// sharing) requires an iCloud identity confirmed this session. Sample-garden mode
    /// (`cloudKitPermitted` false) is never CloudKit-enabled. N3: account-deletion checkpoints no
    /// longer pause CloudKit; `LegacyAccountDeletionCleanup` deletes them at launch.
    var canUseCloudKit: Bool {
        // N2-E: an unreadable guard blocks every garden's CloudKit sends.
        cloudKitPermitted && auth.isIdentityVerified && gardenGuard.isReadable
    }

    /// CloudKit passes started through `runCloudSyncPass` that haven't finished. Observed, unlike
    /// the coordinator reference, so a loading state can appear when the first pass begins; a count
    /// so overlapping passes can't clear it early.
    private(set) var cloudSyncPassesInFlight = 0

    var isCloudSyncRunning: Bool { cloudSyncPassesInFlight > 0 }

    /// Whether a screen with no rows yet should show a loading state: a CloudKit pass is running.
    var isSyncingForDisplay: Bool {
        isCloudSyncRunning || (cloudKit?.isSyncing ?? false)
    }

    /// Runs one CloudKit pass counted in `cloudSyncPassesInFlight`.
    func runCloudSyncPass(_ pass: () async -> Bool) async -> Bool {
        cloudSyncPassesInFlight += 1
        defer { cloudSyncPassesInFlight -= 1 }
        return await pass()
    }

    /// Read-only access to the live CloudKit coordinator for the Settings diagnostics panel
    /// (nil until the first CloudKit sync, and while CloudKit is paused). Its
    /// @Observable state drives the UI.
    var cloudKit: HouseholdCloudCoordinator? { canUseCloudKit ? cloudCoordinator : nil }

    /// Why CloudKit is paused, for Settings; nil when it is allowed.
    var cloudKitPauseReason: String? {
        if !gardenGuard.isReadable { return "Seedkeep can't read its iCloud safety record" }
        if !auth.isIdentityVerified { return "your iCloud account isn't confirmed yet" }
        return nil
    }

    /// True while an iCloud identity is resolved (`.signedIn`). A share delivered then belongs to
    /// that user (`PendingShareInbox.deposit(_:underResolvedIdentity:)`).
    var isIdentityResolved: Bool {
        if case .signedIn = auth.state { return true }
        return false
    }

    /// Clears the app's scheduled and delivered notifications in the different-user eraser.
    /// `makeForTesting` replaces it with a no-op, so tests never clear the real app's.
    @ObservationIgnored var clearAppNotifications: @MainActor () -> Void = {
        NotificationsCenter.shared.removeAllAppNotifications()
    }

    /// Test probe: whether a CloudKit coordinator has been built.
    var hasCloudCoordinator: Bool { cloudCoordinator != nil }

    /// Share adoptions in flight (`bootParticipant`, the macOS queue drain), counted per
    /// `pendingShareEpoch`. While the current epoch has one, `syncIfPossible` starts no owner sync:
    /// the adopted garden replaces this one. An adoption left over from before a different-user
    /// wipe belongs to an older epoch, so it never holds up the new account's sync.
    @ObservationIgnored private var adoptionsInProgress: [Int: Int] = [:]
    /// Set when `syncIfPossible` skipped its CloudKit pass for an adoption; the adoption's end then
    /// runs that sync, adopted or not.
    @ObservationIgnored private var syncSkippedForAdoption = false

    var isAdoptingShare: Bool { adoptionsInProgress[pendingShareEpoch, default: 0] > 0 }

    /// Whether an adoption begun under `epoch` still belongs to the current user: false after a
    /// different-user wipe, when its share is dropped rather than put back.
    func adoptionIsCurrent(_ epoch: Int) -> Bool { pendingShareEpoch == epoch }

    func beginAdoption() -> Int {
        adoptionsInProgress[pendingShareEpoch, default: 0] += 1
        return pendingShareEpoch
    }

    /// Ends an adoption begun under `epoch`. Once the current epoch has none left, runs the sync
    /// that was held back (or the adopted garden's first sync).
    func endAdoption(_ epoch: Int, adopted: Bool) async {
        let remaining = adoptionsInProgress[epoch, default: 1] - 1
        adoptionsInProgress[epoch] = remaining > 0 ? remaining : nil
        guard !isAdoptingShare, adopted || syncSkippedForAdoption else { return }
        syncSkippedForAdoption = false
        await syncIfPossible()
    }

    /// Bumped when a different-user wipe clears the pending shares. An adoption that started under
    /// an earlier epoch belongs to the previous user: it drops its share instead of re-queuing it.
    @ObservationIgnored private var pendingShareEpoch = 0

    /// Household ID that scopes locally stored garden data. In a CloudKit shared
    /// garden, the owner's zone is authoritative; otherwise the signed-in household.
    var activeGardenHouseholdID: String? {
        // Read so views observing this property also update when the participant marker (kept in
        // unobserved UserDefaults) changes: adopting a share or leaving a shared garden.
        _ = participantMarkerRevision
        guard case .signedIn(_, let household) = auth.state else { return nil }
        return ActiveGardenContext.householdID(
            signedInHouseholdID: household.id,
            participantZoneName: loadParticipantMarker()?.zoneName
        )
    }

    /// The CloudKit scope ID `ensureCloudCoordinator` would use, derived without building a
    /// coordinator (so it works while CloudKit is paused). Participant marker first, as there.
    private func cloudKitScopeID(household: HouseholdDTO) -> String {
        if let marker = loadParticipantMarker() {
            return HouseholdCloudCoordinator.participantScopeID(ownerZoneID: marker.zoneID)
        }
        return HouseholdCloudCoordinator.ownerScopeID(householdID: household.id)
    }

    /// Owner (private DB) coordinator for the user's own household, OR — if this device has adopted a
    /// shared household (participant marker present) — a participant coordinator on the owner's shared
    /// zone. Participant-first: the marker is checked before the owner path so a relaunch re-boots as
    /// participant and never orphan-mints a solo zone.
    private func ensureCloudCoordinator(household: HouseholdDTO) -> HouseholdCloudCoordinator {
        func wire(_ coordinator: HouseholdCloudCoordinator) {
            coordinator.isCloudKitAllowed = { [weak self] in self?.canUseCloudKit ?? false }
            coordinator.purgeScanStaging = { [weak self] in try self?.purgeScanStaging() }
            coordinator.guardContext = GardenGuardContext(
                store: gardenGuard,
                accountKey: { [weak self] in self?.auth.currentAccountKey },
                rehomer: gardenRehomer, runner: gardenRunner)
            coordinator.onOwnedGardensListed = { [weak self] owned, account, householdID in
                self?.auth.considerDiscovery(owned: owned, accountKey: account, householdID: householdID)
            }
        }
        if let marker = loadParticipantMarker() {
            let key = HouseholdCloudCoordinator.participantScopeID(ownerZoneID: marker.zoneID)
            if let existing = cloudCoordinator, cloudCoordinatorKey == key { return existing }
            let coordinator = cloudCoordinators.participant(marker.zoneID, container)
            wire(coordinator)
            cloudCoordinator = coordinator
            cloudCoordinatorKey = key
            return coordinator
        }
        let key = HouseholdCloudCoordinator.ownerScopeID(householdID: household.id)
        if let existing = cloudCoordinator, cloudCoordinatorKey == key { return existing }
        let coordinator = cloudCoordinators.owner(household, container)
        wire(coordinator)
        cloudCoordinator = coordinator
        cloudCoordinatorKey = key
        return coordinator
    }

    // MARK: - CloudKit household sharing (participant cutover)

    #if os(macOS)
    @ObservationIgnored private var isProcessingPendingShares = false
    #endif

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
        let d = stateDefaults
        guard let zone = d.string(forKey: markerZoneKey), !zone.isEmpty,
              let owner = d.string(forKey: markerOwnerKey), !owner.isEmpty else { return nil }
        return ParticipantMarker(zoneName: zone, ownerName: owner)
    }
    /// Bumped whenever the participant marker is saved or cleared, so `activeGardenHouseholdID`'s
    /// observers (the Workbench scope reset, the Mac Settings window) see share adoption and leaving.
    private(set) var participantMarkerRevision = 0
    /// N2-E: every binding change writes the guard's latest binding first. `participant` is the
    /// shared garden about to be recorded (nil: leaving it). Throws when the guard can't be
    /// written; the caller then writes no marker.
    private func writeGuardBinding(participant: ParticipantMarker?) throws {
        guard case .signedIn(let user, let household) = auth.state else { return }
        let account = GardenGuardStore.accountKey(recordName: user.id)
        let binding = GardenGuardBinding(
            household: AuthController.bindingHousehold(household),
            participant: participant.map { GardenGuardBinding.Participant(zoneName: $0.zoneName, ownerName: $0.ownerName) })
        try gardenGuard.setBinding(account, binding)
    }

    private func saveParticipantMarker(_ m: ParticipantMarker) {
        stateDefaults.set(m.zoneName, forKey: markerZoneKey)
        stateDefaults.set(m.ownerName, forKey: markerOwnerKey)
        participantMarkerRevision &+= 1
        gardenRunner.bumpScopeEpoch()   // N2-E: a binding change ends the scope writers started in
    }
    private func clearParticipantMarker() {
        stateDefaults.removeObject(forKey: markerZoneKey)
        stateDefaults.removeObject(forKey: markerOwnerKey)
        participantMarkerRevision &+= 1
        gardenRunner.bumpScopeEpoch()
    }

    /// OWNER: create (or fetch) the household's zone-wide CKShare for `UICloudSharingController`.
    /// Returns nil if not signed in, already a participant, or on error (surfaced to the banner).
    func prepareOwnerShare() async -> (share: CKShare, container: CKContainer)? {
        guard let share = await makeOwnerShare() else { return nil }
        return (share, SeedkeepShareFlow().container)
    }

    /// The share itself. N2-E: sharing needs a garden this device has seen exist, never creates the
    /// zone, and checks the garden right before a new share is saved: the root is read, its generation
    /// compared, and the account and epoch re-checked after every await. A mismatch is gone, and
    /// nothing is saved.
    func makeOwnerShare() async -> CKShare? {
        guard canUseCloudKit, let writable = writableGarden, case .signedIn(let user, let household) = auth.state,
              !isViewingSharedHousehold else { return nil }
        guard gardenGuard.isSeen(GardenGuardStore.accountKey(recordName: user.id), household.id) else {
            presentBanner("Your garden isn't in iCloud yet, so it can't be shared. Sync first, then try again.")
            return nil
        }
        let coordinator = ensureCloudCoordinator(household: household)
        do {
            return try await ownerShares.makeOrFetch(householdID: household.id, title: household.name) { [weak self] in
                guard let self else { throw SyncEngineError.accountInvalidated }
                try await coordinator.confirmGardenForShare()
                try await MainActor.run {
                    guard self.gardenWriteStillValid(writable) else { throw GardenWriteFence.refusal }
                }
            }
        } catch SyncEngineError.gardenGone {
            return nil   // gone: the placeholder takes over, no banner
        } catch {
            surfaceError(error)
            return nil
        }
    }

    /// Pending shares are drained only with a resolved identity and CloudKit allowed.
    var canDrainPendingShares: Bool { isIdentityResolved && canUseCloudKit }

    /// Accepts in flight, by share. A timed-out accept keeps running; a retry of the same share
    /// awaits (or collects) it instead of starting an overlapping accept.
    @ObservationIgnored private let shareAccepts = InFlightOperations<CKRecordZone.ID>()

    /// `SeedkeepShareFlow.acceptZoneWideShare`, bounded: the caller is released after 30 s with
    /// `LiveCloudIdentityProvider.TimedOut`, a transient failure (the share waits), while the accept
    /// itself carries on for the next retry of that share to use.
    private func acceptZoneWideShareBounded(_ metadata: CKShare.Metadata) async throws -> CKRecordZone.ID {
        let box = UncheckedSendableBox(metadata)
        let shareID = metadata.share.recordID
        let key = "\(shareID.zoneID.ownerName)|\(shareID.zoneID.zoneName)|\(shareID.recordName)"
        return try await shareAccepts.run(key: key, epoch: pendingShareEpoch,
                                          timeoutNanoseconds: 30 * 1_000_000_000) {
            try await SeedkeepShareFlow().acceptZoneWideShare(box.value)
        }
    }

    /// Warm-tap entry from the scene delegate: drain a just-accepted share + adopt it.
    ///
    /// N1: only with a resolved iCloud identity (`.signedIn`) and CloudKit allowed. Otherwise the
    /// share stays pending (inbox or queue) for the next attempt; `.needsICloud`,
    /// `.choosingGarden` and an unconfirmed identity never drain it.
    func processPendingShare() async {
        guard canDrainPendingShares else { return }
        #if os(macOS)
        guard !isProcessingPendingShares else { return }
        isProcessingPendingShares = true
        let adoptionEpoch = beginAdoption()
        var adopted = false
        await MacPendingShareQueue.shared.drain(
            isSignedIn: { [weak self] in
                guard let self, self.canUseCloudKit, case .signedIn = self.auth.state else { return false }
                return true
            },
            accept: { [weak self] metadata in
                guard let self else { return }
                if try await self.acceptParticipantShare(metadata) { adopted = true }
            },
            onError: { [weak self] error in self?.surfaceError(error) }
        )
        isProcessingPendingShares = false
        // Only now, with no adoption in flight, may the sync start (as the participant).
        await endAdoption(adoptionEpoch, adopted: adopted)
        #else
        guard let metadata = PendingShareInbox.shared.take() else { return }
        await bootParticipant(accepting: metadata)
        #endif
    }

    /// Invite code forwarded from `ShareSceneDelegate`. The custom scene delegate REPLACES SwiftUI's,
    /// which can suppress `.onOpenURL`/`.onContinueUserActivity` — so the delegate forwards URL opens
    /// here and `SeedkeepApp` bridges this into the existing invite sheet. Observable so the bridge fires.
    var incomingInviteCode: String?

    /// Route an incoming URL (custom scheme or universal link) to whichever
    /// flow owns it.
    func routeIncomingURL(_ url: URL) {
        switch IncomingLink(url: url) {
        case .invite(let code): incomingInviteCode = code
        case nil: break
        }
    }

    /// Accept a zone-wide CKShare and adopt the owner's household: wipe this device's own local garden
    /// (clean swap — the participant's own data stays in their own CloudKit zone, restored on Leave),
    /// persist the participant marker, rebuild as a participant coordinator, and sync.
    func bootParticipant(accepting metadata: CKShare.Metadata) async {
        let adoptionEpoch = beginAdoption()
        var adopted = false
        #if os(macOS)
        do {
            adopted = try await acceptParticipantShare(metadata)
        } catch {
            if !HouseholdCloudCoordinator.isCancellation(error), !(error is PendingShareAuthChangedError) {
                surfaceError(error)
            }
        }
        #else
        adopted = await adoptParticipantShare(metadata)
        #endif
        // Only now, with no adoption in flight, may the sync start (as the participant).
        await endAdoption(adoptionEpoch, adopted: adopted)
    }

    /// The signed-in identity a share adoption started under. Adoption re-checks it after every
    /// await: an account change, a pause or another garden in between means the share waits.
    private struct AdoptionIdentity: Equatable {
        let userID: String
        let householdID: String
    }

    private var currentAdoptionIdentity: AdoptionIdentity? {
        guard canUseCloudKit, case .signedIn(let user, let household) = auth.state else { return nil }
        return AdoptionIdentity(userID: user.id, householdID: household.id)
    }

    #if !os(macOS)
    /// iOS adoption body: returns true once the share is adopted (the caller then syncs). On any
    /// failure, or an identity change mid-adoption, the share goes back in the inbox.
    private func adoptParticipantShare(_ metadata: CKShare.Metadata) async -> Bool {
        if metadata.participantRole == .owner { return false }   // owner tapped their own link — benign no-op
        guard metadata.containerIdentifier == "iCloud.app.seedkeep" else { return false }
        // N1: keep the share pending until the iCloud identity is resolved and confirmed.
        guard let identity = currentAdoptionIdentity else {
            PendingShareInbox.shared.deposit(metadata, underResolvedIdentity: canDrainPendingShares)
            return false
        }
        // N2-E: a gone garden awaits the user's choice; a share is not adopted over it. The share waits.
        guard let writable = writableGarden else {
            PendingShareInbox.shared.deposit(metadata, underResolvedIdentity: true)
            return false
        }
        let epoch = pendingShareEpoch
        do {
            let zoneID = try await acceptZoneWideShareBounded(metadata)
            // A different user's wipe cleared the pending shares meanwhile (even if the first
            // user is back by now): this share is dropped and nothing is wiped.
            guard adoptionIsCurrent(epoch) else { return false }
            // The identity may have changed while CloudKit answered: wipe nothing, keep the share.
            // N2-E: so may the garden scope (a gone garden, a binding or account change): the rebind
            // and the wipe below are the final mutation boundary, and the scope must still be the one
            // the adoption started in.
            guard currentAdoptionIdentity == identity, gardenWriteStillValid(writable) else {
                PendingShareInbox.shared.deposit(metadata, underResolvedIdentity: true)
                return false
            }
            let coordinator = cloudCoordinator ?? {
                guard case .signedIn(_, let household) = auth.state else { return nil }
                return ensureCloudCoordinator(household: household)
            }()
            if let coordinator {
                coordinator.wipeAndClear()
                guard !coordinator.requiresWipeRetry else {
                    if let message = coordinator.lastHumanizedError { presentBanner(message) }
                    PendingShareInbox.shared.deposit(metadata, underResolvedIdentity: true)
                    return false
                }
            } else {
                try HouseholdCloudCoordinator.wipeHouseholdSwiftData(container: container)
            }
            // Reset the shared-zone token so the rebuilt participant coordinator does a FULL re-fetch
            // (re-adopting a previously-left share would otherwise resume a stale cursor → empty store).
            try HouseholdCloudCoordinator.resetStateToken(
                at: HouseholdCloudCoordinator.participantStateTokenURL(ownerZoneID: zoneID)
            )
            let marker = ParticipantMarker(zoneName: zoneID.zoneName, ownerName: zoneID.ownerName)
            try writeGuardBinding(participant: marker)   // the guard first, then the marker
            saveParticipantMarker(marker)
            cloudCoordinator = nil; cloudCoordinatorKey = nil   // force rebuild as participant
            return true
        } catch {
            // Re-deposit so a foreground retry re-attempts the accept rather than falling through to
            // owner discovery (which would orphan-mint a solo zone). A permanently bad share just
            // keeps surfacing — never corrupts data. A share from before a different-user wipe
            // is dropped.
            guard adoptionIsCurrent(epoch) else { return false }
            PendingShareInbox.shared.deposit(metadata, underResolvedIdentity: true)
            // A cancelled accept is not a failure: the share just waits, quietly.
            if !HouseholdCloudCoordinator.isCancellation(error) { surfaceError(error) }
            return false
        }
    }
    #endif

    #if os(macOS)
    /// macOS adoption body: returns true once the share is adopted (the caller then syncs).
    /// Throws `PendingShareAuthChangedError` when the identity is not, or no longer, the one the
    /// adoption started under; the queue drain then keeps the share at its front.
    @discardableResult
    private func acceptParticipantShare(_ metadata: CKShare.Metadata) async throws -> Bool {
        if metadata.participantRole == .owner { return false }
        guard metadata.containerIdentifier == "iCloud.app.seedkeep" else { return false }
        guard let identity = currentAdoptionIdentity else { throw PendingShareAuthChangedError() }
        // N2-E: a gone garden awaits the user's choice; a share is not adopted over it. The share waits.
        guard let writable = writableGarden else { throw PendingShareAuthChangedError() }
        let epoch = pendingShareEpoch
        let zoneID: CKRecordZone.ID
        do {
            zoneID = try await acceptZoneWideShareBounded(metadata)
        } catch {
            // A share from before a different-user wipe is dropped, never retried.
            guard adoptionIsCurrent(epoch) else { return false }
            // A cancelled accept is not a failure: requeue it quietly at the front.
            if HouseholdCloudCoordinator.isCancellation(error) { throw PendingShareAuthChangedError() }
            throw error
        }
        // A different user's wipe cleared the queue meanwhile: returning drops this share too.
        guard adoptionIsCurrent(epoch) else { return false }
        guard currentAdoptionIdentity == identity, gardenWriteStillValid(writable) else {
            throw PendingShareAuthChangedError()
        }
        let coordinator = cloudCoordinator ?? {
            guard case .signedIn(_, let household) = auth.state else { return nil }
            return ensureCloudCoordinator(household: household)
        }()
        if let coordinator {
            coordinator.wipeAndClear()
            guard !coordinator.requiresWipeRetry else { throw PendingShareWipeRetryError() }
        } else {
            try HouseholdCloudCoordinator.wipeHouseholdSwiftData(container: container)
        }
        try HouseholdCloudCoordinator.resetStateToken(
            at: HouseholdCloudCoordinator.participantStateTokenURL(ownerZoneID: zoneID)
        )
        let marker = ParticipantMarker(zoneName: zoneID.zoneName, ownerName: zoneID.ownerName)
        try writeGuardBinding(participant: marker)   // the guard first, then the marker
        saveParticipantMarker(marker)
        cloudCoordinator = nil; cloudCoordinatorKey = nil
        return true
    }
    #endif

    /// Leave the shared household: clear the marker + wipe the shared local data + drop the participant
    /// coordinator so the next sync rebuilds the OWNER coordinator (the user's own zone re-syncs).
    ///
    /// THROWS, so a swallowed wipe or token-reset failure never reads as success. The Settings
    /// affordance surfaces errors via `leaveSharedHouseholdSurfacingErrors()`.
    func leaveSharedHousehold() async throws {
        // N1: leaving rebuilds the owner scope over CloudKit; refuse before touching anything
        // while CloudKit is paused.
        guard canUseCloudKit else { throw LeaveSharedHouseholdError.cloudKitPaused }
        let signedInHousehold: HouseholdDTO?
        if case .signedIn(_, let household) = auth.state { signedInHousehold = household }
        else { signedInHousehold = nil }
        let coordinator = cloudCoordinator ?? signedInHousehold.map { ensureCloudCoordinator(household: $0) }
        if let coordinator {
            coordinator.wipeAndClear()
            guard !coordinator.requiresWipeRetry else {
                throw LeaveSharedHouseholdError.wipeNeedsRetry(message: coordinator.lastHumanizedError)
            }
        } else {
            try HouseholdCloudCoordinator.wipeHouseholdSwiftData(container: container)
        }
        // Reset the OWNER token so the rebuilt owner coordinator does a FULL re-fetch — re-downloading
        // the user's own (parked, intact) CloudKit zone into the just-wiped SwiftData. Without this, the
        // resumed cursor sees no changes since adopt and the user's own garden would stay empty locally.
        if let household = signedInHousehold {
            try HouseholdCloudCoordinator.resetStateToken(
                at: HouseholdCloudCoordinator.ownerStateTokenURL(householdID: household.id))
        }
        try writeGuardBinding(participant: nil)   // the guard first, then the marker
        clearParticipantMarker()
        cloudCoordinator = nil; cloudCoordinatorKey = nil
        await syncIfPossible()
    }

    /// The SwiftData wipe reported that it has to be retried before the
    /// device can safely stop being a participant.
    enum LeaveSharedHouseholdError: Error, LocalizedError {
        case wipeNeedsRetry(message: String?)
        case cloudKitPaused

        var errorDescription: String? {
            switch self {
            case .wipeNeedsRetry(let message):
                return message ?? "The shared garden could not be cleared from this device. Try again."
            case .cloudKitPaused:
                return "iCloud isn't confirmed yet, so the shared garden can't be left right now. Try again shortly."
            }
        }
    }

    /// Settings' "Leave shared garden" button: same work, errors shown in
    /// the banner rather than thrown at a caller that has no user to tell.
    func leaveSharedHouseholdSurfacingErrors() async {
        do {
            try await leaveSharedHousehold()
        } catch {
            surfaceError(error)
        }
    }

    // MARK: - R1 27d.18 — participant journal recovery review inbox

    /// Scope key for the current participant's stranded-row registry (nil unless this device is
    /// currently viewing a shared household) — drives the Settings review-inbox row +
    /// its sheet's item filter.
    var participantRecoveryScopeKey: String? {
        guard case .signedIn(_, let household) = auth.state,
              let ownerID = activeGardenHouseholdID, ownerID != household.id else { return nil }
        return ParticipantRowRecovery.scopeKey(ownerZoneHouseholdID: ownerID, signedInHouseholdID: household.id)
    }

    /// Share to garden: re-home the live row in place if it still exists, else recreate it
    /// atomically from the registry item's snapshot via
    /// `ParticipantRowRecovery.recreateFromSnapshotAtomically` (R1 27d.18 hardening #1 — the entry,
    /// its checklist items, and the registry flip to `shared` land in ONE save, so a failure partway
    /// through can never leave a duplicate-creating retry target). The FK the entry once carried is
    /// intentionally NOT reattached on recreate — a quarantined entry's FK, by definition, never
    /// resolved into the owner-zone garden, so passing it through would only trip `JournalStore`'s
    /// parent-scope validation. `currentScopeKey` (hardening #2) is re-derived from live auth state on
    /// every call so a stale item captured across a garden switch is refused rather than acted on.
    func shareJournalRecoveryItem(_ item: LocalJournalRecoveryItem) async {
        guard case .signedIn(_, let household) = auth.state,
              let ownerID = activeGardenHouseholdID, ownerID != household.id,
              writableGarden != nil else { return }
        let itemID = item.id
        let scope = ParticipantRowRecovery.scopeKey(
            ownerZoneHouseholdID: ownerID, signedInHouseholdID: household.id)
        do {
            if try ParticipantRowRecovery.shareLiveEntryIfPresent(
                itemID: itemID, ownerZoneHouseholdID: ownerID, currentScopeKey: scope, container: container
            ) {
                noteHouseholdMutation()
                return
            }
            try ParticipantRowRecovery.recreateFromSnapshotAtomically(
                itemID: itemID, ownerZoneHouseholdID: ownerID, currentScopeKey: scope, container: container)
            noteHouseholdMutation()
        } catch {
            surfaceError(error)
        }
    }

    /// Keep private: mark the registry item `kept`. Nothing deleted anywhere. `currentScopeKey`
    /// (R1 27d.18 hardening #2) is re-derived from live auth state so a stale/foreign-scope item is
    /// refused rather than acted on.
    func keepJournalRecoveryItemPrivate(_ item: LocalJournalRecoveryItem) {
        guard case .signedIn(_, let household) = auth.state,
              let ownerID = activeGardenHouseholdID, ownerID != household.id,
              writableGarden != nil else { return }
        let scope = ParticipantRowRecovery.scopeKey(
            ownerZoneHouseholdID: ownerID, signedInHouseholdID: household.id)
        do {
            try ParticipantRowRecovery.keepPrivate(itemID: item.id, currentScopeKey: scope, container: container)
        } catch {
            surfaceError(error)
        }
    }

    /// Phase 5.1.4 — recompute the Sunday-8am pet roundup body from the
    /// current household snapshot. Gated server-side by the Settings
    /// toggle; this function is safe to call regardless.
    private func rescheduleWeeklyPetRoundup(householdID: String, captured: WritableGarden?) async {
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
        await notifier.schedulePetRoundup(thriving: thriving, wilting: wilting)
        // N2-E: scheduled just as the scope went stale (the garden is gone, or the binding or account
        // changed): take the notification back.
        if !gardenWriteStillValid(captured) { notifier.clearPetRoundup() }
    }

    /// The store the legacy rebind clears: exactly the retired bearer-token item in `service`.
    static func legacyTokenStore(service: String) -> KeychainTokenStore {
        KeychainTokenStore(service: service, account: KeychainTokenStore.legacyBearerTokenAccount)
    }

    private static func resolveKeychainService() -> String {
        let info = Bundle.main.infoDictionary ?? [:]
        return (info["KeychainService"] as? String) ?? "com.example.seedkeep"
    }

    private static func makeModelContainer(inMemory: Bool = FeatureFlags.isRunningUnitTests) -> ModelContainer {
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
        //
        // Under XCTest the hosting app keeps its store in memory. Hosted tests build their own
        // containers; the host's live environment must never touch a real store. On macOS the
        // unsigned test host is not sandboxed, so an on-disk store would land in the developer's
        // own ~/Library/Application Support. Outside tests this is false: the store is unchanged.
        let config = ModelConfiguration(
            "seedkeep",
            schema: schema,
            isStoredInMemoryOnly: inMemory,
            cloudKitDatabase: .none
        )
        do {
            return try ModelContainer(for: schema, configurations: config)
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }
}

/// Hands the weather service the environment's writable-garden scope once the environment exists
/// (the service is built first). Before then the token is a fixed placeholder.
@MainActor
final class WritableScopeBox {
    weak var environment: AppEnvironment?
    func token() -> String? {
        guard let environment else { return "unbound" }
        return environment.writableScopeToken()
    }
}

/// Carries a non-`Sendable` CloudKit value into a detached, bounded call.
private struct UncheckedSendableBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

/// Long-running operations by key, so a caller that gives up after a timeout does not abandon the
/// work: the next call with the same key awaits (or collects) the same operation instead of
/// starting an overlapping one. An entry goes once its result is handed out, when a call finds it
/// from an older `epoch` or older than `maxAge` (a call that never returns is not rejoined
/// forever), or on `removeAll()`.
@MainActor
final class InFlightOperations<Value: Sendable> {
    private var entries: [String: (epoch: Int, started: ContinuousClock.Instant, task: Task<Value, Error>)] = [:]
    private let maxAge: Duration
    private let clock = ContinuousClock()

    init(maxAge: Duration = .seconds(300)) { self.maxAge = maxAge }

    var count: Int { entries.count }

    func run(
        key: String, epoch: Int, timeoutNanoseconds: UInt64,
        _ start: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        if let existing = entries[key],
           existing.epoch != epoch || clock.now - existing.started > maxAge {
            entries[key] = nil
        }
        let task: Task<Value, Error>
        if let existing = entries[key] {
            task = existing.task
        } else {
            task = Task.detached { try await start() }
            entries[key] = (epoch, clock.now, task)
        }
        do {
            let value = try await LiveCloudIdentityProvider.bounded(nanoseconds: timeoutNanoseconds) {
                try await task.value
            }
            if entries[key]?.task == task { entries[key] = nil }
            return value
        } catch is LiveCloudIdentityProvider.TimedOut {
            throw LiveCloudIdentityProvider.TimedOut()   // keep the operation for the next call
        } catch {
            if entries[key]?.task == task { entries[key] = nil }
            throw error
        }
    }

    func removeAll() { entries.removeAll() }
}

/// How `AppEnvironment` builds its CloudKit household coordinators. The app uses `.live` (the
/// real `CKSyncEngine` on the private or shared database). Unit tests pass a factory over a fake
/// engine (N3 T2), so they exercise the shipping CloudKit path without CloudKit or the network.
@MainActor
struct CloudCoordinatorFactory {
    /// The owner coordinator for the signed-in household's own zone.
    var owner: (HouseholdDTO, ModelContainer) -> HouseholdCloudCoordinator
    /// A participant coordinator on the owner's shared zone.
    var participant: (CKRecordZone.ID, ModelContainer) -> HouseholdCloudCoordinator

    static var live: CloudCoordinatorFactory {
        CloudCoordinatorFactory(
            owner: { household, container in
                HouseholdCloudCoordinator.live(
                    householdID: household.id,
                    householdName: household.name,
                    householdCreatedAt: household.created_at,
                    householdUpdatedAt: household.updated_at,
                    container: container
                )
            },
            participant: { ownerZoneID, container in
                HouseholdCloudCoordinator.participant(ownerZoneID: ownerZoneID, container: container)
            }
        )
    }
}
