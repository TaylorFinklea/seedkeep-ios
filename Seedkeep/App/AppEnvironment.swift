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
        journal.onLocalHouseholdMutation = { [weak self] in self?.noteHouseholdMutation() }
        journal.cloudKitScopeIDProvider = { [weak self] in
            guard let self, case .signedIn(_, let household) = self.auth.state else { return nil }
            return self.ensureCloudCoordinator(household: household).scopeID
        }
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
    // household is known. The cache key is the complete CloudKit database/zone/owner scope so an
    // account switch or same-named share from another owner always rebuilds. nil/unused when off.
    @ObservationIgnored private var cloudCoordinator: HouseholdCloudCoordinator?
    @ObservationIgnored private var cloudCoordinatorKey: String?

    /// Read-only access to the live CloudKit coordinator for the Settings diagnostics panel
    /// (nil until the first sync after the flag is toggled on). Its @Observable state drives the UI.
    var cloudKit: HouseholdCloudCoordinator? { cloudCoordinator }

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

    /// Launch sweep for an account deletion that committed server-side but
    /// whose response never got back. Runs before session restore and
    /// needs no credentials — see
    /// `AccountDeletionCoordinator.recoverCommittedDeletions`.
    ///
    /// Best effort: a lookup that cannot reach the server leaves the
    /// checkpoint untouched for the next launch, and must never keep the
    /// app from starting.
    func recoverCommittedAccountDeletion() async {
        // Cheap disk check first. Almost every launch has no checkpoint at
        // all, and this runs before anything else the app does — no reason
        // to build the coordinator or reach the network to learn that.
        guard !AccountDeletionCheckpointStore().allCheckpoints().isEmpty else { return }
        do {
            _ = try await accountDeletion.recoverCommittedDeletions()
        } catch {
            // Nothing was concluded, so nothing was changed.
        }
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

    /// Owner (private DB) coordinator for the user's own household, OR — if this device has adopted a
    /// shared household (participant marker present) — a participant coordinator on the owner's shared
    /// zone. Participant-first: the marker is checked before the owner path so a relaunch re-boots as
    /// participant and never orphan-mints a solo zone.
    private func ensureCloudCoordinator(household: HouseholdDTO) -> HouseholdCloudCoordinator {
        if let marker = loadParticipantMarker() {
            let key = HouseholdCloudCoordinator.participantScopeID(ownerZoneID: marker.zoneID)
            if let existing = cloudCoordinator, cloudCoordinatorKey == key { return existing }
            let coordinator = HouseholdCloudCoordinator.participant(ownerZoneID: marker.zoneID, container: container)
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
        cloudCoordinator = coordinator
        cloudCoordinatorKey = key
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
        if metadata.participantRole == .owner { return }   // owner tapped their own link — benign no-op
        guard metadata.containerIdentifier == "iCloud.app.seedkeep" else { return }
        do {
            let flow = SeedkeepShareFlow()
            let zoneID = try await flow.acceptZoneWideShare(metadata)
            let coordinator = cloudCoordinator ?? {
                guard case .signedIn(_, let household) = auth.state else { return nil }
                return ensureCloudCoordinator(household: household)
            }()
            if let coordinator {
                coordinator.wipeAndClear()
                guard !coordinator.requiresWipeRetry else {
                    if let message = coordinator.lastHumanizedError { presentBanner(message) }
                    PendingShareInbox.shared.deposit(metadata)
                    return
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
            await syncIfPossible()
        } catch {
            // Re-deposit so a foreground retry re-attempts the accept rather than falling through to
            // owner discovery (which would orphan-mint a solo zone). A permanently bad share just
            // keeps surfacing — never corrupts data.
            PendingShareInbox.shared.deposit(metadata)
            surfaceError(error)
        }
    }

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

        var errorDescription: String? {
            switch self {
            case .wipeNeedsRetry(let message):
                return message ?? "The shared garden could not be cleared from this device. Try again."
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
