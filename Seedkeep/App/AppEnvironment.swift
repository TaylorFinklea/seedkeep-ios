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
    let auth: AuthController
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
        let client = makeServerClient(baseURL: prefs.effectiveServerURL)
        // N1: the iCloud account is the identity. The token store is kept only so a legacy
        // rebind can clear the old Sign in with Apple bearer token.
        let auth = AuthController(identity: LiveCloudIdentityProvider(), tokenStore: store)
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
            wateringState: LocalWateringStateClient(),
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

    /// The Seedkeep server client. N1: its session refuses every request
    /// (`ServerRetirement.makeRefusingSession()`), so nothing reaches the retired server.
    static func makeServerClient(baseURL: URL) -> SeedkeepClient {
        SeedkeepClient(configuration: .init(
            baseURL: baseURL,
            session: ServerRetirement.makeRefusingSession()
        ))
    }

    /// N1 test seam: an environment over `container` and a fake identity provider, with every
    /// durable side effect pointed at the caller's `defaults` and `durableStateDirectory`, and
    /// without the background services `live()` starts (weather observers, notifier). It never
    /// builds a CloudKit coordinator by itself; tests must keep `canUseCloudKit` false wherever
    /// one would be built.
    static func makeForTesting(
        identity: any CloudIdentityProviding,
        tokenStore: any TokenStoring,
        defaults: UserDefaults,
        container: ModelContainer,
        durableStateDirectory: URL,
        checkpointStore: AccountDeletionCheckpointStore
    ) -> AppEnvironment {
        let prefs = AppPreferences(defaults: defaults, bundleDefaultURL: URL(string: "https://seedkeep.invalid")!)
        let client = makeServerClient(baseURL: prefs.bundleDefault)
        let auth = AuthController(identity: identity, tokenStore: tokenStore, defaults: defaults)
        let sync = SyncEngine(client: client, container: container)
        let assistant = AIAssistantCoordinator(client: client, container: container)
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
            client: client, auth: auth, container: container,
            sync: sync, recommendations: RecommendationStore(client: client, container: container),
            journal: JournalStore(client: client, container: container), assistant: assistant,
            preferences: prefs, apiKeys: APIKeyStore(service: "app.seedkeep.tests.\(UUID().uuidString)"),
            subscriptions: SubscriptionManager(client: client),
            weatherWarnings: weatherWarnings,
            stateDefaults: defaults,
            durableStateDirectory: durableStateDirectory,
            checkpointStore: checkpointStore,
            startsBackgroundServices: false
        )
        env.clearAppNotifications = {}
        return env
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
        weatherWarnings: WeatherWarningsService,
        stateDefaults: UserDefaults = .standard,
        durableStateDirectory: URL = HouseholdCloudCoordinator.householdSyncDirURL(),
        checkpointStore: AccountDeletionCheckpointStore = AccountDeletionCheckpointStore(),
        startsBackgroundServices: Bool = true
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
        self.stateDefaults = stateDefaults
        self.durableStateDirectory = durableStateDirectory
        self.checkpointStore = checkpointStore
        // N1 quarantine starts closed: count leftover deletion checkpoints now (a cheap file
        // count), so no task ordering can see CloudKit allowed before they are counted.
        self.pausedDeletionCheckpointCount = AccountDeletionQuarantine.pausedCheckpointCount(using: checkpointStore)
        sync.onLocalHouseholdMutation = { [weak self] in self?.noteHouseholdMutation() }
        journal.onLocalHouseholdMutation = { [weak self] in self?.noteHouseholdMutation() }
        // N1: the scope ID is derived, never a coordinator, and not gated on `canUseCloudKit`, so a
        // local delete made while CloudKit is paused still records its deletion intent.
        sync.cloudKitScopeIDProvider = { [weak self] in
            guard let self, case .signedIn(_, let household) = self.auth.state else { return nil }
            return self.cloudKitScopeID(household: household)
        }
        sync.onCloudKitPhotoCacheMiss = { [weak self] recordName in
            guard let self, self.canUseCloudKit,
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
        if startsBackgroundServices {
            Task { await weatherWarnings.start() }
        }
        // Phase 4D — catalog-corrections orchestrator. Observes
        // `.catalogCorrectionsChanged` posted by `SyncEngine` and
        // schedules outcome pings (with cross-device dedup via the
        // server ledger). Idempotent — safe to call from tests too.
        if startsBackgroundServices, !ServerRetirement.isRetired {
            CatalogCorrectionNotifier.shared.start(client: client, container: container)
        }
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
        // N1: THROWS when the wipe is incomplete, so AuthController binds nothing over a store that
        // still holds the previous account's data (it enters `.failed` with Retry instead).
        auth.wireLocalDataEraser { [weak self] in
            guard let self else { return }
            try self.sync.eraseAllLocalData()
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
        // host, which must not make live CloudKit identity calls.
        if FeatureFlags.canRunLiveAppStartup {
            accountChangeObserver = NotificationCenter.default.addObserver(
                forName: .CKAccountChanged, object: nil, queue: .main
            ) { [weak self] _ in
                // Pause CloudKit before returning (queue `.main`), then revalidate.
                MainActor.assumeIsolated { self?.auth.pauseForAccountChange() }
                Task { @MainActor in await self?.auth.revalidateAfterAccountChange() }
            }
        }
    }

    @ObservationIgnored private var accountChangeObserver: (any NSObjectProtocol)?
    /// Holds the participant marker and migration markers (`.standard` live; a test suite in tests).
    @ObservationIgnored private let stateDefaults: UserDefaults
    /// `HouseholdCloudCoordinator.householdSyncDir()` live; a temporary directory in tests.
    @ObservationIgnored private let durableStateDirectory: URL
    @ObservationIgnored private let checkpointStore: AccountDeletionCheckpointStore

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
        // Transfer bytes stay while deletion checkpoints are quarantined: N3 may still need them.
        try HouseholdCloudCoordinator.resetAllDurableState(
            directory: durableStateDirectory, defaults: stateDefaults,
            keepingTransferWorkspace: pausedDeletionCheckpointCount > 0)
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
    /// something went wrong (sync enqueue failures, assistant launch, etc).
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

    /// Triggers a sync if the user is signed in. Safe to call repeatedly —
    /// `SyncEngine` debounces concurrent calls with `isSyncing`.
    ///
    /// After a successful sync, runs `PetStateEngine.tickAll` on every
    /// alive pet in the household — this is the single canonical place
    /// where mood snapshots are materialized and lifecycle transitions
    /// are detected. Server departure side effects stay disabled while
    /// the Seedkeep server is retired.
    /// Notification scheduling for the other transitions lands in
    /// Phase 5.1.4 (the side-effect helper has the hook points stubbed).
    public func syncIfPossible() async {
        if case .signedIn(_, let household) = auth.state {
            let activeGardenHouseholdID = self.activeGardenHouseholdID ?? household.id
            // R1 routes household garden data through CloudKit. The legacy server
            // branch remains for XCTest coverage; live builds always use CloudKit.
            let banner: String?
            if isCloudKitSyncEnabled {
                // N1: CloudKit only on a confirmed identity. An unconfirmed one resolves first; a
                // pass that lands elsewhere (another garden, chooser) leaves this sync to the
                // RootView task its new state starts.
                if !auth.isIdentityVerified { await auth.restoreSession() }
                guard case .signedIn(_, let current) = auth.state, current == household,
                      self.activeGardenHouseholdID == activeGardenHouseholdID else { return }
                // N1: CloudKit paused (unconfirmed identity, deletion quarantine) or a share being
                // adopted (its own sync follows): skip only the CloudKit pass, with no banner. The
                // local post-sync work below still runs.
                if isAdoptingShare { syncSkippedForAdoption = true }
                if canUseCloudKit, !isAdoptingShare {
                    // R1 27d.18 — participant stranded-row recovery. Only meaningful for a participant
                    // (activeGardenHouseholdID resolves to the owner-zone ID, differing from the signed-in
                    // ID); runs BEFORE the sync pass so re-homed rows are pushed by the pass that follows.
                    if activeGardenHouseholdID != household.id {
                        let recovered = ParticipantRowRecovery.runIfNeeded(
                            container: container,
                            signedInHouseholdID: household.id,
                            ownerZoneHouseholdID: activeGardenHouseholdID
                        )
                        if recovered { noteHouseholdMutation() }
                    }
                    let coordinator = ensureCloudCoordinator(household: household)
                    let ran = await coordinator.sync()
                    guard ran else { return }
                    // Household data syncs through CloudKit. Server-backed personal feeds are retired,
                    // so only CloudKit errors can reach the sync banner.
                    // A pass that stopped (paused, account changed) leaves an older error behind.
                    banner = coordinator.lastPassCompleted ? coordinator.lastHumanizedError : nil
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
            if !ServerRetirement.isRetired {
                await PetStateEngine.performSideEffects(
                    for: transitions,
                    client: client,
                    container: container
                )
            }
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
        // A share being adopted replaces this garden; its own sync pushes what remains.
        guard FeatureFlags.cloudKitHouseholdSyncEnabled, canUseCloudKit, !isAdoptingShare,
              case .signedIn(_, let household) = auth.state else { return }
        let coordinator = ensureCloudCoordinator(household: household)
        Task { await coordinator.save() }
    }

    // R1 — the CloudKit household coordinator, built lazily on first use when the flag is on and a
    // household is known. The cache key is the complete CloudKit database/zone/owner scope so an
    // account switch or same-named share from another owner always rebuilds. nil/unused when off.
    @ObservationIgnored private var cloudCoordinator: HouseholdCloudCoordinator?
    @ObservationIgnored private var cloudCoordinatorKey: String?

    /// N1 (parent-owned seam): CloudKit use (coordinator creation, sync, saves, photo recovery,
    /// sharing) requires an iCloud identity confirmed this session and no paused account deletion.
    /// Slice A applies it at those call sites; slice B maintains `pausedDeletionCheckpointCount`.
    var canUseCloudKit: Bool {
        auth.isIdentityVerified && pausedDeletionCheckpointCount == 0
    }

    /// Account-deletion checkpoints left from before the server was retired. While any exist,
    /// CloudKit stays off so a deleted garden is never re-provisioned (N1 quarantine).
    private(set) var pausedDeletionCheckpointCount = 0

    /// Read-only access to the live CloudKit coordinator for the Settings diagnostics panel
    /// (nil until the first sync after the flag is toggled on, and while CloudKit is paused). Its
    /// @Observable state drives the UI.
    var cloudKit: HouseholdCloudCoordinator? { canUseCloudKit ? cloudCoordinator : nil }

    /// Why CloudKit is paused, for Settings; nil when it is allowed.
    var cloudKitPauseReason: String? {
        if pausedDeletionCheckpointCount > 0 { return "an earlier account deletion didn't finish" }
        if !auth.isIdentityVerified { return "your iCloud account isn't confirmed yet" }
        return nil
    }

    /// True while an iCloud identity is resolved (`.signedIn`). A share delivered then belongs to
    /// that user (`PendingShareInbox.deposit(_:underResolvedIdentity:)`).
    var isIdentityResolved: Bool {
        if case .signedIn = auth.state { return true }
        return false
    }

    #if DEBUG
    /// Test seam: picks `syncIfPossible`'s branch without the process-wide flag that parallel
    /// suites toggle. Always nil outside tests.
    @ObservationIgnored var cloudKitSyncOverrideForTesting: Bool?
    private var isCloudKitSyncEnabled: Bool {
        cloudKitSyncOverrideForTesting ?? FeatureFlags.cloudKitHouseholdSyncEnabled
    }
    #else
    private var isCloudKitSyncEnabled: Bool { FeatureFlags.cloudKitHouseholdSyncEnabled }
    #endif

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

    // MARK: - Resumable account deletion

    /// The role-aware, resumable account-deletion flow.
    ///
    /// Built lazily and kept for the lifetime of the environment: it holds
    /// the checkpoint lease and the in-memory handoff token, both of which
    /// must survive between calls within a session. Its seams read the
    /// live signed-in identity and participant marker on every call rather
    /// than capturing them, so a coordinator built before sign-in still
    /// sees the right account.
    @ObservationIgnored private var accountDeletionCoordinator: AccountDeletionCoordinator?

    var accountDeletion: AccountDeletionCoordinator {
        if let existing = accountDeletionCoordinator { return existing }
        let coordinator = AccountDeletionCoordinator(
            store: AccountDeletionCheckpointStore(),
            cloudKit: LiveAccountDeletionCloudKit(
                // NOTE: no feature-flag gate. Whether the app is currently
                // syncing to CloudKit says nothing about whether a zone or
                // an accepted share exists in the account — the kill switch,
                // a reinstall, or a second device all break that inference,
                // and getting it wrong deletes the account while the garden
                // lives on. Role inspection asks CloudKit itself.
                participantZoneID: { [weak self] in self?.loadParticipantMarker()?.zoneID },
                ownedHouseholdID: { [weak self] in
                    guard let self, case .signedIn(_, let household) = self.auth.state else { return nil }
                    return household.id
                },
                // Leaving the share is only half of a participant's exit;
                // the marker has to go and the user's own garden has to come
                // back. This THROWS on purpose: a rebuild that quietly
                // failed used to let the flow march on to account deletion
                // with the device still pointed at a zone it can no longer
                // read.
                rebuildOwnGardenScope: { [weak self] in try await self?.leaveSharedHousehold() }
            ),
            server: LiveAccountDeletionServer(client: client),
            session: AccountDeletionSession(
                identity: { [weak self] in
                    guard let self, case .signedIn(let user, let household) = self.auth.state else { return nil }
                    return .init(userID: user.id, householdID: household.id)
                },
                // The cached identity is the app's own record of who owns
                // the local SwiftData store, and it survives a session the
                // server has already destroyed — which is exactly the state
                // the launch sweep runs in.
                localStoreOwnerID: { [weak self] in self?.auth.loadCachedIdentity()?.user.id },
                signOut: { [weak self] in await self?.auth.signOut() },
                adoptTransferredGarden: { [weak self] householdID, transferID in
                    try await self?.adoptTransferredGarden(householdID: householdID, transferID: transferID)
                }
            )
        )
        accountDeletionCoordinator = coordinator
        return coordinator
    }

    /// The observable state behind the deletion progress sheet and the
    /// successor acceptance sheet.
    ///
    /// One instance for the same reason the coordinator is one instance:
    /// both surfaces drive the same durable flow, and a second model would
    /// mean a handoff link opened while the deletion sheet is up ends up
    /// talking to a coordinator that does not know about it.
    @ObservationIgnored private var accountDeletionFlowModel: AccountDeletionFlowModel?

    var accountDeletionFlow: AccountDeletionFlowModel {
        if let existing = accountDeletionFlowModel { return existing }
        let model = AccountDeletionFlowModel(coordinator: accountDeletion)
        accountDeletionFlowModel = model
        return model
    }

    /// Quarantines any deletion checkpoints before identity restore. A
    /// checkpoint keeps CloudKit paused until N3 can resolve its state.
    func recoverCommittedAccountDeletion() async {
        pausedDeletionCheckpointCount = AccountDeletionQuarantine.pausedCheckpointCount(using: checkpointStore)
    }

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
        if let marker = loadParticipantMarker() {
            let key = HouseholdCloudCoordinator.participantScopeID(ownerZoneID: marker.zoneID)
            if let existing = cloudCoordinator, cloudCoordinatorKey == key { return existing }
            let coordinator = HouseholdCloudCoordinator.participant(ownerZoneID: marker.zoneID, container: container)
            coordinator.isCloudKitAllowed = { [weak self] in self?.canUseCloudKit ?? false }
            cloudCoordinator = coordinator
            cloudCoordinatorKey = key
            return coordinator
        }
        let key = HouseholdCloudCoordinator.ownerScopeID(householdID: household.id)
        if let existing = cloudCoordinator, cloudCoordinatorKey == key { return existing }
        let coordinator = HouseholdCloudCoordinator.live(
            householdID: household.id,
            householdName: household.name,
            householdCreatedAt: household.created_at,
            householdUpdatedAt: household.updated_at,
            container: container
        )
        coordinator.isCloudKitAllowed = { [weak self] in self?.canUseCloudKit ?? false }
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
    private func saveParticipantMarker(_ m: ParticipantMarker) {
        stateDefaults.set(m.zoneName, forKey: markerZoneKey)
        stateDefaults.set(m.ownerName, forKey: markerOwnerKey)
    }
    private func clearParticipantMarker() {
        stateDefaults.removeObject(forKey: markerZoneKey)
        stateDefaults.removeObject(forKey: markerOwnerKey)
    }

    /// OWNER: create (or fetch) the household's zone-wide CKShare for `UICloudSharingController`.
    /// Returns nil if not signed in, already a participant, or on error (surfaced to the banner).
    func prepareOwnerShare() async -> (share: CKShare, container: CKContainer)? {
        guard canUseCloudKit, case .signedIn(_, let household) = auth.state,
              !isViewingSharedHousehold else { return nil }
        do {
            let flow = SeedkeepShareFlow()
            let share = try await flow.makeOrFetchZoneWideShare(householdID: household.id, title: household.name)
            return (share, flow.container)
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
    /// Shared-garden handoff forwarded the same way. Held here rather than
    /// acted on: taking over a garden requires an authenticated identity
    /// and a non-consuming inspection, both of which belong to
    /// `AccountDeletionFlowModel`, and the token must survive arriving
    /// while the app is signed out.
    var incomingHandoffLink: AccountDeletionHandoffLink?

    /// Route an incoming URL (custom scheme or universal link) to whichever
    /// flow owns it.
    func routeIncomingURL(_ url: URL) {
        switch IncomingLink(url: url) {
        case .invite(let code): incomingInviteCode = code
        case .gardenHandoff(let link): incomingHandoffLink = link
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
        let epoch = pendingShareEpoch
        do {
            let zoneID = try await acceptZoneWideShareBounded(metadata)
            // A different user's wipe cleared the pending shares meanwhile (even if the first
            // user is back by now): this share is dropped and nothing is wiped.
            guard adoptionIsCurrent(epoch) else { return false }
            // The identity may have changed while CloudKit answered: wipe nothing, keep the share.
            guard currentAdoptionIdentity == identity else {
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
            saveParticipantMarker(ParticipantMarker(zoneName: zoneID.zoneName, ownerName: zoneID.ownerName))
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
        guard currentAdoptionIdentity == identity else { throw PendingShareAuthChangedError() }
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
        saveParticipantMarker(ParticipantMarker(zoneName: zoneID.zoneName, ownerName: zoneID.ownerName))
        cloudCoordinator = nil; cloudCoordinatorKey = nil
        return true
    }
    #endif

    /// Cut this device over to a garden it has just received as a
    /// successor in an account-deletion handoff.
    ///
    /// Until this runs, the app is still a PARTICIPANT of the departing
    /// owner's shared zone — the marker, the CloudKit coordinator, and the
    /// active-garden scope all point there. The owner is about to delete
    /// that zone. So "the garden is yours" is not true when the digests
    /// match; it is true when this has happened:
    ///
    ///   1. Prove membership in the EXACT household the transfer names
    ///      (`GET /api/households/:id`), not whichever one the "current
    ///      household" heuristic resolves to. Verification UPSERTs a
    ///      second `memberships` row for this user, so asking "what is my
    ///      current household" is genuinely ambiguous the moment this
    ///      runs — the transfer itself already knows the answer.
    ///   2. Confirm that membership is `owner`, not merely `member` — the
    ///      only role verification actually promotes the successor to.
    ///   3. Re-read the TRANSFER itself and confirm it still authorizes
    ///      the claim. The departing owner may legally cancel a `verified`
    ///      transfer right up until the source-deletion lease is taken,
    ///      and a cancel that late reverts the very membership row step 1
    ///      just confirmed — so a membership check alone, made a moment
    ///      earlier, is not enough.
    ///   4. Adopt it into `AuthController` — state AND the cache together,
    ///      so a later ordinary restore does not mistake the correct
    ///      household for an identity switch and wipe it.
    ///   5. Stop being a participant. The destination zone lives in THIS
    ///      device's private database; keeping the marker would keep
    ///      pointing every read at the doomed shared zone.
    ///   6. Reset the owner state token, so the rebuilt owner coordinator
    ///      does a FULL fetch of the destination zone instead of resuming
    ///      a cursor that belongs to the source zone's change history.
    ///   7. Drop the cached coordinator and sync, which rebuilds it as the
    ///      owner of the destination.
    ///
    /// A MEMBER (not owner) never reaches step 4 — reporting completion
    /// over a role the server has not actually promoted would let this
    /// device claim a garden it does not own.
    ///
    /// Local SwiftData is deliberately NOT wiped: its rows are scoped to
    /// this same household id and are exactly the contents that were
    /// copied, so wiping would throw away a correct local garden and make
    /// the successor wait on a full re-download for nothing.
    ///
    /// THROWS, and the coordinator holds `.successorAdopting` until it
    /// returns, so a failure here is retried rather than papered over with
    /// a completion screen.
    func adoptTransferredGarden(householdID: String, transferID: String) async throws {
        guard !ServerRetirement.isRetired else {
            throw SeedkeepError(
                code: "server_retired",
                message: "Garden handoff links are no longer supported."
            )
        }
        let membership: WireResponses.CreateOrFetchHousehold
        do {
            membership = try await client.household(id: householdID)
        } catch {
            // `not_a_member` means the re-home has not landed yet — this
            // device is retried later by the coordinator's own drive
            // loop, not something to report as broken. Anything else
            // propagates unchanged.
            throw TransferredGardenCutover.classify(error) ?? error
        }
        try TransferredGardenCutover.verifyOwnership(role: membership.role)

        // Re-read at the LAST possible moment, not trusted from memory:
        // between the household lookup above and here, a second owner
        // device could still legally withdraw a `verified` transfer.
        let transfer = try await client.accountDeletionTransfer(id: transferID)
        try TransferredGardenCutover.verifyTransferAuthorizes(transfer.phase)

        auth.adoptHousehold(membership.household)
        guard case .signedIn(_, let household) = auth.state else {
            throw TransferredGardenCutover.Failure.sessionUnavailable
        }

        // Only now: the destination zone is in THIS device's private
        // database, so the participant marker — which points every read at
        // the departing owner's doomed shared zone — has to go.
        clearParticipantMarker()
        // Full fetch of the destination rather than resuming a cursor that
        // belongs to the source zone's change history.
        try HouseholdCloudCoordinator.resetStateToken(
            at: HouseholdCloudCoordinator.ownerStateTokenURL(householdID: householdID))
        cloudCoordinator = nil
        cloudCoordinatorKey = nil

        // And prove the owner scope actually came up. `syncIfPossible`
        // swallows its failures into a banner, which is right for a
        // background pass and wrong here: "the garden is yours" must not be
        // said over a scope that never loaded.
        guard FeatureFlags.cloudKitHouseholdSyncEnabled else {
            await syncIfPossible()
            return
        }
        let coordinator = ensureCloudCoordinator(household: household)
        guard await coordinator.sync() else {
            throw TransferredGardenCutover.Failure.destinationSyncIncomplete(
                message: coordinator.lastHumanizedError)
        }
        if let failure = coordinator.lastHumanizedError {
            throw TransferredGardenCutover.Failure.destinationSyncIncomplete(message: failure)
        }
        // Photos-on-CloudKit D6 — TransferWorkspace is durable through destination save AND
        // verification, then deleted. This device just confirmed the destination synced clean, so
        // any bytes staged here for THIS household (by a prior attempt, or by whichever device ran
        // the transfer copy) are no longer needed. Best-effort: a miss here is an orphaned
        // directory, not a correctness/privacy issue on its own. PendingUploads/PhotoCache are
        // deliberately left untouched — `householdID` is the SAME garden this device may already
        // have cached photos for as a participant, and those bytes remain valid under ownership.
        try? PhotoByteStore(lifetime: .transferWorkspace, householdID: householdID).removeAll()
    }

    /// Leave the shared household: clear the marker + wipe the shared local data + drop the participant
    /// coordinator so the next sync rebuilds the OWNER coordinator (the user's own zone re-syncs).
    ///
    /// THROWS. This used to surface a banner and return normally, which
    /// reads as success to any caller that is not a person looking at the
    /// screen — and account deletion is exactly such a caller. A swallowed
    /// wipe or token-reset failure would let the deletion flow advance to
    /// `DELETE /api/me` with this device still marked as a participant of a
    /// share it has already left. The Settings affordance keeps the old
    /// behaviour via `leaveSharedHouseholdSurfacingErrors()`.
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

    /// Scope key for the current participant's stranded-row registry (nil unless the flag is on and
    /// this device is currently viewing a shared household) — drives the Settings review-inbox row +
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
              let ownerID = activeGardenHouseholdID, ownerID != household.id else { return }
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
              let ownerID = activeGardenHouseholdID, ownerID != household.id else { return }
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
        // The probe below would run on `URLSession.shared`, outside the refusing session.
        guard !ServerRetirement.isRetired else { return "The Seedkeep server is retired." }
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
        guard !ServerRetirement.isRetired else { return }
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
        //
        // Under XCTest the hosting app keeps its store in memory. Hosted tests build their own
        // containers; the host's live environment must never touch a real store. On macOS the
        // unsigned test host is not sandboxed, so an on-disk store would land in the developer's
        // own ~/Library/Application Support. Outside tests this is false: the store is unchanged.
        let config = ModelConfiguration(
            "seedkeep",
            schema: schema,
            isStoredInMemoryOnly: FeatureFlags.isRunningUnitTests,
            cloudKitDatabase: .none
        )
        do {
            return try ModelContainer(for: schema, configurations: config)
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
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
