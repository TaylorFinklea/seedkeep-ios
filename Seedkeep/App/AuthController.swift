import Foundation
import CloudKit
import SeedkeepKit
import SeedkeepCloudKit

/// Identity state machine (N1, Apple-only). The iCloud account is the identity: there is no
/// Seedkeep server and no sign-in screen.
///
/// Resolution (`restoreSession` / `retry`) checks the iCloud account, fetches its user record
/// name, and lands the device in a garden:
///
///   - A cached iCloud identity for the same user enters directly.
///   - A cached identity for a DIFFERENT, confirmed user wipes the local store first. The eraser
///     throws on failure, and a failed wipe binds nothing.
///   - A legacy server identity is rebound in place to the iCloud user once its garden zone is
///     found: same household ID, rows, cursors, markers and pending writes. No wipe.
///   - A fresh device lists its gardens, binds the only one, mints a fresh random household (with
///     a creation grant) when there is none, and asks the user when there is more than one.
///
/// N2-E: the garden guard (`GardenGuardStore`) holds the account's latest binding. Every binding
/// change writes the guard first, then the identity cache and participant marker. Resolution runs
/// in this order: the iCloud account is verified, any different-account wipe finishes, the
/// defaults are reconciled from the guard's latest binding, and only then may a selection commit
/// a binding. A bound garden that does not exist yet is re-entered with its grant, never replaced.
///
/// Stabilization B3 still holds: the cached identity records **who owns the local SwiftData
/// store**. Transient iCloud failures enter from that cache with CloudKit paused
/// (`isIdentityVerified == false`) and never wipe; a failed zone listing never reads as "no
/// gardens". Every transition takes a new generation number, and a pass that resumes from an
/// `await` to find its generation stale publishes nothing and wipes nothing.
@MainActor
@Observable
final class AuthController {
    enum State: Equatable, Sendable {
        /// Not resolved yet (launch), or after `signOut()`.
        case signedOut
        /// Resolving.
        case authenticating
        case signedIn(user: UserDTO, household: HouseholdDTO)
        case needsICloud(CloudEntryBlock)
        case choosingGarden(GardenChoice)
        case failed(message: String)
    }

    /// The identity that owns the local store. Persisted as JSON in `UserDefaults`.
    struct CachedIdentity: Codable, Equatable {
        let user: UserDTO
        let household: HouseholdDTO
    }

    /// The iCloud identity: `user.id` is the iCloud user record name.
    static let identityCacheKey = "seedkeep.identity.icloud.v1"
    /// The server-era identity (`user.id` is the old server user ID). Read for migration only.
    static let legacyIdentityCacheKey = "seedkeep.auth.lastIdentity"

    private(set) var state: State = .signedOut

    /// N1 (parent-owned seam): false while `.signedIn` was entered from a cached identity that
    /// iCloud has not confirmed yet (offline or transient failure). Local use continues; CloudKit
    /// use waits (`AppEnvironment.canUseCloudKit`) until a later resolution confirms the account.
    private(set) var isIdentityVerified = true

    private let identity: any CloudIdentityProviding
    private let tokenStore: any TokenStoring
    private let defaults: UserDefaults
    /// N2-E: the account's latest binding, creation grants and discovery record.
    let guardStore: GardenGuardStore
    /// N2-E seam: where the silent re-home (G3) runs. G1 records the request in the guard.
    @ObservationIgnored private let rehomer: any GardenRehoming
    /// Fresh household IDs minted during the current resolution. A binding that commits one writes
    /// its `pending` creation grant in the same guard write.
    @ObservationIgnored private var mintedHouseholdIDs = Set<String>()
    @ObservationIgnored private let makeHouseholdID: () -> String

    /// Wipes the local SwiftData store, pending-write queue, cursors, scheduled notifications and
    /// CloudKit engine state. Wired by `AppEnvironment` (the controller is constructed before the
    /// `ModelContainer` exists). THROWS when the wipe did not complete: nothing binds over a
    /// store that still holds another account's data.
    @ObservationIgnored private var localDataEraser: (@MainActor (_ requireCurrent: @escaping @MainActor () throws -> Void) async throws -> Void)?

    /// Removes only this device's garden (household rows and their CloudKit sync state) for an
    /// explicit chooser discard. Unlike `localDataEraser` it keeps device-only data such as
    /// journal recovery items, forecasts and notifications: the iCloud user has not changed.
    /// THROWS when the wipe did not complete; the choice then binds nothing.
    @ObservationIgnored private var gardenSwitchEraser: (@MainActor (_ requireCurrent: @escaping @MainActor () throws -> Void) async throws -> Void)?

    /// Called before the participant marker is set to a DIFFERENT shared garden than the one
    /// recorded, with that garden's zone. `AppEnvironment` resets the zone's engine state so the
    /// participant coordinator re-fetches it in full, as `bootParticipant` does; a stale cursor
    /// from an earlier join would otherwise leave the garden partly empty. THROWS when the reset
    /// failed: the binding then stops in `.failed` with nothing written.
    @ObservationIgnored private var participantGardenAdopted: (@MainActor (_ zoneName: String, _ ownerName: String) throws -> Void)?

    /// N2-E: fired at every identity transition and binding change. `AppEnvironment` bumps
    /// `gardenScopeEpoch` here, so a writer that started before the transition does nothing after it.
    @ObservationIgnored var onScopeChange: (@MainActor () -> Void)?

    /// Bumped by every transition. A pass compares its own number after each `await`.
    @ObservationIgnored private var generation = 0
    /// The resolution pass in flight, so concurrent `restoreSession` calls (several iPad and Mac
    /// windows) await the same pass instead of starting their own.
    @ObservationIgnored private var inFlight: (generation: Int, task: Task<Void, Never>)?
    /// What `chooseGarden` / `keepDeviceGarden` bind against while `state` is `.choosingGarden`.
    @ObservationIgnored private var pendingChoice: PendingChoice?
    /// The user that was verified when `pauseForAccountChange` paused CloudKit; consumed by the
    /// revalidation that follows.
    @ObservationIgnored private var verifiedBeforeAccountChange: String?

    private struct PendingChoice {
        let recordName: String
        /// The household this device already holds (legacy cache); nil on a fresh device.
        let deviceHousehold: HouseholdDTO?
        /// Fresh device: the shared zones still to resolve after an own-garden choice.
        let sharedZones: [GardenZoneSummary]
        let choice: GardenChoice
        /// The owned gardens listed when the choice was made: all are acknowledged once it binds.
        var listedOwnedIDs: [String] = []
        /// The binding in force when discovery offered the choice; choosing to keep it re-enters it.
        var currentBinding: GardenGuardBinding?
        /// The device's own household whose zone the owned listing confirmed absent.
        var absentOwnHouseholdID: String?
    }

    init(
        identity: any CloudIdentityProviding,
        tokenStore: any TokenStoring,
        defaults: UserDefaults = .standard,
        guardStore: GardenGuardStore? = nil,
        rehomer: (any GardenRehoming)? = nil,
        makeHouseholdID: @escaping () -> String = { GardenHouseholdID.make() }
    ) {
        self.identity = identity
        self.tokenStore = tokenStore
        self.defaults = defaults
        self.guardStore = guardStore ?? GardenGuardStore(directory: nil)
        self.rehomer = rehomer ?? DeferredGardenRehomer()
        self.makeHouseholdID = makeHouseholdID
    }

    /// The guard's key for the signed-in iCloud account, nil when none is resolved.
    var currentAccountKey: String? {
        if case .signedIn(let user, _) = state { return GardenGuardStore.accountKey(recordName: user.id) }
        return nil
    }

    func wireLocalDataEraser(_ eraser: @escaping @MainActor (_ requireCurrent: @escaping @MainActor () throws -> Void) async throws -> Void) {
        localDataEraser = eraser
    }

    func wireGardenSwitchEraser(_ eraser: @escaping @MainActor (_ requireCurrent: @escaping @MainActor () throws -> Void) async throws -> Void) {
        gardenSwitchEraser = eraser
    }

    func wireParticipantGardenAdopted(_ hook: @escaping @MainActor (_ zoneName: String, _ ownerName: String) throws -> Void) {
        participantGardenAdopted = hook
    }

    // MARK: - Transitions

    /// Resolves the iCloud identity and garden. Single-flight: a call made while a pass is in
    /// flight awaits that pass instead of starting another, and every caller returns only once no
    /// pass is in flight (a superseding pass, such as an account change, is waited for too).
    func restoreSession() async {
        if inFlight == nil {
            let gen = nextGeneration()
            await run(gen) { await self.resolve(gen) }
        }
        while let current = inFlight {
            await current.task.value
            // `run` clears its own entry once it resumes; a newer entry is a superseding pass.
            if inFlight?.generation == current.generation { break }
        }
    }

    /// The same resolution, offered from `.needsICloud` and `.failed`.
    func retry() async {
        await restoreSession()
    }

    /// Binds a choice from `.choosingGarden`. `garden` is one of the choice's candidates or its
    /// `ownGarden`. `discardingDeviceData` runs the eraser first; the chooser sets it only after
    /// the user confirms (see `choiceDiscardsDeviceData`).
    func chooseGarden(_ garden: GardenZoneSummary, discardingDeviceData: Bool) async {
        guard case .choosingGarden(let choice) = state,
              choice.candidates.contains(garden) || choice.ownGarden == garden else { return }
        guard let pending = pendingChoice, pending.choice == choice else {
            // An account change withdrew this choice: resolve again rather than ignore the tap.
            return await restoreSession()
        }
        // A chooser can outlive the invitation state that produced it. In particular, an ID
        // retired by a completed keep/discard must not become writable again if it is re-shared.
        let account = GardenGuardStore.accountKey(recordName: pending.recordName)
        guard !guardStore.isRetired(account, garden.householdID) else {
            return await restoreSession()
        }
        // A choice that removes this device's garden needs the user's confirmation.
        if Self.choiceDiscardsDeviceData(choice, garden) && !discardingDeviceData { return }
        let gen = nextGeneration()
        if discardingDeviceData {
            guard await erase(gen, using: gardenSwitchEraser) else { return }
        }

        if case .discoveredOwnGardens = choice.reason, garden == choice.ownGarden,
           let current = pending.currentBinding {
            // Discovery: the user keeps the garden this device has. Every garden shown is acknowledged.
            bind(recordName: pending.recordName, household: Self.dto(current.household),
                 participant: current.participant, replacingLegacy: false,
                 acknowledging: pending.listedOwnedIDs, gen)
            return
        }
        if garden.scope == .owned {
            // An owned choice sets the own household and leaves any shared garden.
            var own = ownHousehold(for: garden, pending: pending)
            if pending.absentOwnHouseholdID == own.id {
                // The device's own zone is confirmed absent and its data was discarded: a new
                // garden, created through a grant.
                own = Self.household(from: mintGarden(name: own.name))
            }
            if case .multipleOwnGardens = choice.reason {
                // Fresh device: the shared step still follows, with this own garden.
                resolveParticipant(recordName: pending.recordName, ownGarden: garden, own: own,
                                   ownsGarden: true, shared: pending.sharedZones,
                                   listedOwned: pending.listedOwnedIDs, gen)
                return
            }
            bind(recordName: pending.recordName, household: own, participant: nil,
                 replacingLegacy: pending.deviceHousehold != nil,
                 acknowledging: pending.listedOwnedIDs, gen)
        } else {
            // A shared choice keeps the own household and records the shared garden.
            var own: HouseholdDTO
            if let deviceHousehold = pending.deviceHousehold {
                own = deviceHousehold
            } else if let ownGarden = choice.ownGarden {
                own = ownHousehold(for: ownGarden, pending: pending)
            } else {
                own = Self.household(from: mintGarden())
            }
            if pending.absentOwnHouseholdID == own.id {
                own = Self.household(from: mintGarden(name: own.name))
            }
            bind(recordName: pending.recordName, household: own, participant: Self.participantRef(garden),
                 replacingLegacy: pending.deviceHousehold != nil,
                 acknowledging: pending.listedOwnedIDs, gen)
        }
    }

    /// `.deviceGardenNotFound`: keep the household this device already holds. Its zone is absent
    /// from iCloud, so the rows move to a fresh garden ID with a `pending` creation grant (the
    /// silent re-home, G3). The device keeps the old household until that re-home runs.
    func keepDeviceGarden() async {
        guard case .choosingGarden(let choice) = state, choice.canKeepDeviceGarden else { return }
        guard let pending = pendingChoice, pending.choice == choice else {
            // An account change withdrew this choice: resolve again rather than ignore the tap.
            return await restoreSession()
        }
        guard let deviceHousehold = pending.deviceHousehold else { return }
        let gen = nextGeneration()
        // Only a zone the listings confirmed absent is re-homed; otherwise the garden is kept as is.
        let rehomeTo = pending.absentOwnHouseholdID == deviceHousehold.id ? mintHouseholdID() : nil
        bind(recordName: pending.recordName, household: deviceHousehold, participant: nil,
             replacingLegacy: true, rehomeTo: rehomeTo,
             acknowledging: pending.listedOwnedIDs, gen)
    }

    /// Called on `.CKAccountChanged`. The notification alone never wipes: only a confirmed
    /// different user record name does. CloudKit pauses at once (`isIdentityVerified = false`,
    /// before any await) and resumes only once the same user is confirmed or a resolution binds;
    /// any pending chooser choice is withdrawn.
    func revalidateAfterAccountChange() async {
        pauseForAccountChange()
        let gen = nextGeneration()
        let verifiedUser = verifiedBeforeAccountChange
        verifiedBeforeAccountChange = nil
        await run(gen) { await self.revalidate(gen, verifiedUser: verifiedUser) }
    }

    /// Pauses CloudKit synchronously the moment the account changes, before
    /// `revalidateAfterAccountChange` gets to run: the `.CKAccountChanged` observer calls this on
    /// the main queue first. Remembers which user was verified, so the revalidation can resume at
    /// once when iCloud confirms the same one. Withdraws any pending chooser choice.
    func pauseForAccountChange() {
        if isIdentityVerified, case .signedIn(let user, _) = state {
            verifiedBeforeAccountChange = user.id
        }
        isIdentityVerified = false
        pendingChoice = nil
        _ = nextGeneration()   // A paused account also withdraws any suspended eraser.
    }

    /// No UI calls it since N1. Wipes BEFORE clearing the
    /// caches: the cache records who owns the local store, so after a failed wipe it stays and
    /// the next account still triggers the wipe.
    func signOut() async {
        let gen = nextGeneration()
        pendingChoice = nil
        tokenStore.clear()
        guard await erase(gen, using: localDataEraser) else { return }
        clearCachedIdentities()
        ActiveGardenContext.clearParticipant(in: defaults)
        isIdentityVerified = false
        state = .signedOut
    }

    /// True when choosing `garden` from `choice` removes this device's garden, so the chooser
    /// must confirm first and then pass `discardingDeviceData: true`. Keeping the device garden
    /// (`keepDeviceGarden`) never discards.
    static func choiceDiscardsDeviceData(_ choice: GardenChoice, _ garden: GardenZoneSummary) -> Bool {
        switch choice.reason {
        case .deviceGardenNotFound, .sharedGardenUnavailable: return true
        case .multipleOwnGardens, .multipleSharedGardens, .sharedOrOwnGarden: return false
        // Keeping the garden this device has discards nothing; picking another replaces it.
        case .discoveredOwnGardens: return garden != choice.ownGarden
        }
    }

    // MARK: - Journals (N2-E G3)

    /// True once this process had to rewrite the identity cache or participant marker from the guard's
    /// latest binding. A journal is then not confirmed by this launch: the next one confirms it.
    @ObservationIgnored private(set) var defaultsRepairedThisProcess = false

    /// Whether the identity cache and participant marker match the guard's latest binding for the
    /// signed-in account, and this launch did not have to repair them. A journal is removed only after
    /// a later launch has confirmed this (contract §1).
    func launchDefaultsConfirmed(accountKey: String) -> Bool {
        guard case .signedIn(let user, _) = state, currentAccountKey == accountKey,
              !defaultsRepairedThisProcess else { return false }
        let cached = loadIdentity(forKey: Self.identityCacheKey)
        let marker = ActiveGardenContext.participant(in: defaults)
        guard let binding = guardStore.latestBinding(accountKey) else {
            return cached == nil && marker == nil && defaults.object(forKey: Self.legacyIdentityCacheKey) == nil
        }
        guard cached?.user.id == user.id, cached?.household.id == binding.household.id else { return false }
        return marker?.zoneName == binding.participant?.zoneName && marker?.ownerName == binding.participant?.ownerName
    }

    /// A keep or silent re-home wrote its new owned binding to the guard: derives the participant
    /// marker and identity cache from it, and publishes the new garden. Returns false when the
    /// signed-in account is not the journal's. Idempotent.
    @discardableResult
    func adoptLatestBinding(accountKey: String) -> Bool {
        guard case .signedIn(let user, _) = state, currentAccountKey == accountKey,
              let binding = guardStore.latestBinding(accountKey), binding.participant == nil else { return false }
        let household = Self.dto(binding.household)
        ActiveGardenContext.clearParticipant(in: defaults)
        saveIdentity(CachedIdentity(user: user, household: household), forKey: Self.identityCacheKey)
        state = .signedIn(user: user, household: household)
        onScopeChange?()
        return true
    }

    /// A discard cleared the binding in the guard: drops the discarded garden from
    /// view, and resolves the session again, which leads to another garden, the chooser, or a new
    /// garden (fresh ID, grant). Resolution only reads the guard's latest binding, so a successor it
    /// binds supersedes the discard journal and the journal is never replayed over it.
    @discardableResult
    func resolveAfterDiscard(accountKey: String) async -> Bool {
        guard case .signedIn = state, isIdentityVerified, currentAccountKey == accountKey,
              guardStore.latestBinding(accountKey) == nil else { return false }
        // Keep the previous cache as proof of local-store ownership until restoreSession verifies
        // the current iCloud recordName. It replaces this cache only at successor bind, or clears it after a complete account wipe.
        pendingChoice = nil
        state = .authenticating
        onScopeChange?()
        await restoreSession()
        return isIdentityVerified
    }

    // MARK: - Resolution

    private func run(_ gen: Int, _ pass: @escaping @MainActor @Sendable () async -> Void) async {
        let task = Task { @MainActor in await pass() }
        inFlight = (gen, task)
        await task.value
        if inFlight?.generation == gen { inFlight = nil }
    }

    private func nextGeneration() -> Int {
        generation += 1
        onScopeChange?()
        return generation
    }

    private func isCurrent(_ gen: Int) -> Bool { gen == generation }

    private func resolve(_ gen: Int) async {
        if case .signedIn = state {} else { state = .authenticating }
        let status = await identity.accountStatus()
        guard isCurrent(gen) else { return }
        switch status {
        case .noAccount: return block(.noAccount)
        case .restricted: return block(.restricted)
        case .unverified: return enterUnverified()
        case .available: break
        }
        let recordName: String
        do {
            recordName = try await identity.currentUserRecordName()
        } catch {
            guard isCurrent(gen) else { return }
            return enterUnverified()
        }
        guard isCurrent(gen) else { return }
        await resolve(recordName: recordName, gen)
    }

    /// Resolution order (N2-E): the iCloud account was verified by the caller. Then any
    /// different-account wipe finishes (the identity cache still names the local store's owner), then
    /// the defaults are reconciled from the guard's latest binding for this account, and only then may
    /// a selection (the fast path, the legacy rebind, `resolveFresh`, the chooser) commit a binding.
    private func resolve(recordName: String, _ gen: Int) async {
        let account = GardenGuardStore.accountKey(recordName: recordName)
        if let cached = loadIdentity(forKey: Self.identityCacheKey) {
            if defaults.object(forKey: Self.legacyIdentityCacheKey) != nil {
                // A rebind was interrupted after writing the new cache: finish it.
                defaults.removeObject(forKey: Self.legacyIdentityCacheKey)
                tokenStore.clear()
            }
            if cached.user.id != recordName {
                // A confirmed different iCloud user: wipe the previous user's store first.
                isIdentityVerified = false
                guard await erase(gen, using: localDataEraser) else { return }
                clearCachedIdentities()
                ActiveGardenContext.clearParticipant(in: defaults)
            }
        }
        guard reconcileDefaults(recordName: recordName, account: account) else { return }
        if guardStore.isBindingWritten(account), guardStore.latestBinding(account) == nil {
            // The cache still proves who owns retained rows; it is not a garden binding.
            await resolveFresh(recordName: recordName, gen)
            return
        }
        if let cached = loadIdentity(forKey: Self.identityCacheKey), cached.user.id == recordName {
            enterCachedGarden(cached, recordName: recordName, account: account, gen)
            return
        }
        if let legacy = loadIdentity(forKey: Self.legacyIdentityCacheKey) {
            await resolveLegacy(legacy, recordName: recordName, gen)
            return
        }
        await resolveFresh(recordName: recordName, gen)
    }

    /// Brings the identity cache and participant marker in line with the guard's latest binding for
    /// `account`. With no binding yet (an install from before N2-E), the guard is seeded from the
    /// defaults instead. Returns false after a failure (the state is `.failed`).
    private func reconcileDefaults(recordName: String, account: String) -> Bool {
        let cached = loadIdentity(forKey: Self.identityCacheKey)
        guard let binding = guardStore.latestBinding(account) else {
            if guardStore.isBindingWritten(account) {
                // The cleared guard is authoritative, but retained device-only/other-household rows
                // still belong to the cached user until a successor bind or complete wipe commits.
                if cached != nil || defaults.object(forKey: Self.legacyIdentityCacheKey) != nil
                    || ActiveGardenContext.participant(in: defaults) != nil {
                    ActiveGardenContext.clearParticipant(in: defaults)
                    defaultsRepairedThisProcess = true
                }
                return true
            }
            // Never written (an install from before N2-E): seed the guard from an existing
            // same-account identity.
            guard let cached, cached.user.id == recordName else { return true }
            let seeded = GardenGuardBinding(
                household: Self.bindingHousehold(cached.household),
                participant: ActiveGardenContext.participant(in: defaults).map {
                    GardenGuardBinding.Participant(zoneName: $0.zoneName, ownerName: $0.ownerName)
                })
            do { try guardStore.setBinding(account, seeded); return true } catch {
                fail(error, fallback: "Seedkeep couldn't save its iCloud safety record. Try again.")
                return false
            }
        }
        let recorded = ActiveGardenContext.participant(in: defaults)
        let markerMatches = recorded?.zoneName == binding.participant?.zoneName
            && recorded?.ownerName == binding.participant?.ownerName
        let cacheMatches = cached.map { $0.user.id == recordName && $0.household.id == binding.household.id } ?? false
        if markerMatches && cacheMatches { return true }
        defaultsRepairedThisProcess = true
        if !markerMatches, let participant = binding.participant {
            do { try participantGardenAdopted?(participant.zoneName, participant.ownerName) } catch {
                fail(error, fallback: "The shared garden couldn't be opened on this device. Try again.")
                return false
            }
        }
        // The guard is the authority: rewrite the participant marker, then the cache.
        if let participant = binding.participant {
            ActiveGardenContext.recordParticipant(zoneName: participant.zoneName,
                                                  ownerName: participant.ownerName, in: defaults)
        } else {
            ActiveGardenContext.clearParticipant(in: defaults)
        }
        if !cacheMatches {
            saveIdentity(CachedIdentity(user: Self.user(recordName: recordName),
                                        household: Self.dto(binding.household)),
                         forKey: Self.identityCacheKey)
            if defaults.object(forKey: Self.legacyIdentityCacheKey) != nil {
                defaults.removeObject(forKey: Self.legacyIdentityCacheKey)
                tokenStore.clear()
            }
        }
        return true
    }

    /// The same-account fast path: enters at once from the reconciled cache, with no network call.
    /// Discovery runs later, from the owner coordinator's start (`considerDiscovery`).
    private func enterCachedGarden(
        _ cached: CachedIdentity, recordName: String, account: String, _ gen: Int
    ) {
        pendingChoice = nil
        isIdentityVerified = true
        state = .signedIn(user: cached.user, household: cached.household)
        onScopeChange?()
    }

    /// Discovery after entry (N2-E §4). The owner coordinator's start passes the owned zones it
    /// listed. Best effort and silent: nothing is wiped or rebound. Only when an eligible garden
    /// is found does the existing chooser appear (`.discoveredOwnGardens`), once, in every window.
    /// Dropped when the account, the garden or the verification changed since the listing began,
    /// or when another pass or a chooser is in progress.
    func considerDiscovery(owned: [GardenZoneSummary], accountKey: String, householdID: String) {
        guard case .signedIn(let user, let household) = state, isIdentityVerified,
              inFlight == nil, pendingChoice == nil,
              GardenGuardStore.accountKey(recordName: user.id) == accountKey,
              household.id == householdID else { return }
        let cached = CachedIdentity(user: user, household: household)
        guard let choice = discoveryChoice(owned: owned, cached: cached, account: accountKey) else { return }
        _ = nextGeneration()   // withdraw anything keyed to the signed-in state
        offer(choice, recordName: user.id, deviceHousehold: nil,
              listedOwnedIDs: choice.candidates.map(\.householdID),   // everything shown is acknowledged on the answer
              currentBinding: guardStore.latestBinding(accountKey))
    }

    /// Discovery (N2-E §4). The first N2-E resolution of an account acknowledges the gardens with
    /// pre-N2-E IDs, so users who chose before are not asked again; random-format gardens are never
    /// auto-acknowledged. Eligible: complete (has a root), not retired, not seen, not acknowledged,
    /// and not the garden this device holds.
    private func discoveryChoice(
        owned: [GardenZoneSummary], cached: CachedIdentity, account: String
    ) -> GardenChoice? {
        let bound = cached.household.id
        if owned.contains(where: { $0.householdID == bound }) {
            try? guardStore.recordSeen(account, bound, generation: nil)
        }
        if !guardStore.account(account).discoveryInitialized {
            let preN2E = owned.map(\.householdID).filter { !GardenHouseholdID.isRandomFormat($0) }
            do {
                try guardStore.markDiscoveryInitialized(account, acknowledging: preN2E + [bound])
            } catch { return nil }
        }
        // The trigger is an eligible garden neither seen nor acknowledged; the chooser then offers
        // every eligible garden (complete, not retired), acknowledged ones included.
        let eligible = owned.filter {
            $0.hasRoot && $0.householdID != bound && !guardStore.isRetired(account, $0.householdID)
                && !guardStore.isGone(account, $0.householdID)
        }
        guard eligible.contains(where: {
            !guardStore.isSeen(account, $0.householdID) && !guardStore.isAcknowledged(account, $0.householdID)
        }) else { return nil }
        return GardenChoice(reason: .discoveredOwnGardens, candidates: eligible,
                            ownGarden: Self.summary(for: cached.household))
    }

    private func revalidate(_ gen: Int, verifiedUser: String?) async {
        let status = await identity.accountStatus()
        guard isCurrent(gen) else { return }
        switch status {
        case .noAccount: return block(.noAccount)
        case .restricted: return block(.restricted)
        case .unverified: return settleInterruptedPass()
        case .available: break
        }
        let recordName: String
        do {
            recordName = try await identity.currentUserRecordName()
        } catch {
            guard isCurrent(gen) else { return }
            return settleInterruptedPass()
        }
        guard isCurrent(gen) else { return }
        if let cached = loadIdentity(forKey: Self.identityCacheKey), cached.user.id == recordName,
           case .signedIn = state, verifiedUser == recordName {
            isIdentityVerified = true   // the same user, already confirmed: CloudKit resumes
            return
        }
        // A different user wipes (through the iCloud cache); anything unresolved resolves now.
        await resolve(recordName: recordName, gen)
    }

    /// Revalidation superseded a resolution that had not published yet, or withdrew a chooser's
    /// choice. Without this the app would sit on "Opening your garden…", or on a chooser whose
    /// buttons do nothing, with nothing left to finish it.
    private func settleInterruptedPass() {
        switch state {
        case .authenticating, .choosingGarden: enterUnverified()
        default: break
        }
    }

    /// The owned gardens resolution may select or offer: complete (a rootless zone is an interrupted
    /// creation, never adopted, offered or trusted) and not retired.
    ///
    /// A zone whose root status is unknown (a timeout, a network or batch failure) is never read as
    /// absent: the listing is treated as failed, so resolution takes its retry path and never mints,
    /// re-homes, offers or drops a garden on that basis.
    private func usable(_ owned: [GardenZoneSummary], recordName: String) throws -> [GardenZoneSummary] {
        let account = GardenGuardStore.accountKey(recordName: recordName)
        return try complete(owned).filter {
            !guardStore.isRetired(account, $0.householdID) && !guardStore.isGone(account, $0.householdID)
        }
    }

    /// Shared gardens resolution may select or offer: a gone garden (access lost, or recreated) is
    /// never chosen, even though the shared listing may still show a zone with that name.
    private func available(_ shared: [GardenZoneSummary], recordName: String) -> [GardenZoneSummary] {
        let account = GardenGuardStore.accountKey(recordName: recordName)
        return shared.filter {
            !guardStore.isGone(account, $0.householdID) && !guardStore.isRetired(account, $0.householdID)
        }
    }

    /// The complete zones of a listing (owned or shared): root present. Confirmed-rootless zones
    /// are dropped; an unknown root status fails the listing.
    private func complete(_ zones: [GardenZoneSummary]) throws -> [GardenZoneSummary] {
        if zones.contains(where: { $0.rootStatus == .unknown }) { throw RootStatusUnknown() }
        return zones.filter { $0.rootStatus == .present }
    }

    private struct RootStatusUnknown: Error {}

    /// What a binding or answered chooser acknowledges: on the account's first N2-E resolution the
    /// listed gardens with pre-N2-E IDs, plus the gardens actually `shown` in a chooser. Never a
    /// random-format garden the user was not shown (the bound garden is added by `bind`).
    private func acknowledgements(recordName: String, listed: [GardenZoneSummary], shown: [String] = []) -> [String] {
        let account = GardenGuardStore.accountKey(recordName: recordName)
        let firstLaunch = guardStore.account(account).discoveryInitialized
            ? [] : listed.map(\.householdID).filter { !GardenHouseholdID.isRandomFormat($0) }
        return firstLaunch + shown
    }

    /// Legacy server identity: find its garden in this iCloud account and rebind in place.
    private func resolveLegacy(_ legacy: CachedIdentity, recordName: String, _ gen: Int) async {
        let household = legacy.household
        if let marker = ActiveGardenContext.participant(in: defaults) {
            let isMarkerZone = { (zone: GardenZoneSummary) in
                zone.zoneName == marker.zoneName && zone.ownerName == marker.ownerName
            }
            let shared: [GardenZoneSummary]
            do {
                shared = available(try complete(try await identity.listGardenZones(.shared)), recordName: recordName)
            } catch {
                guard isCurrent(gen) else { return }
                return enterLegacyUnconfirmed(legacy)
            }
            guard isCurrent(gen) else { return }
            if shared.contains(where: isMarkerZone) {
                return bind(recordName: recordName, household: household,
                            participant: GardenGuardBinding.Participant(zoneName: marker.zoneName, ownerName: marker.ownerName),
                            replacingLegacy: true, gen)
            }
            // The shared garden is gone. Offer the own garden and any other shared gardens.
            let rawOwned = try? await identity.listGardenZones(.owned)
            guard isCurrent(gen) else { return }
            // A listing whose own root couldn't be read verifies nothing: enter unconfirmed rather
            // than offer (and possibly bind) a garden whose root wasn't confirmed.
            let owned: [GardenZoneSummary]?
            do { owned = try rawOwned.map { try usable($0, recordName: recordName) } } catch {
                return enterLegacyUnconfirmed(legacy)
            }
            let ownGarden = owned?.first { $0.householdID == household.id } ?? Self.summary(for: household)
            let choice = GardenChoice(reason: .sharedGardenUnavailable(zoneName: marker.zoneName),
                                      candidates: shared.filter { !isMarkerZone($0) },
                                      ownGarden: ownGarden)
            // A confirmed listing without the device's own zone: choosing the own garden makes a
            // new one through a grant instead of recreating that zone.
            let absentOwn = owned.flatMap { list in
                list.contains(where: { $0.householdID == household.id }) ? nil : household.id
            }
            return offer(choice, recordName: recordName, deviceHousehold: household,
                         listedOwnedIDs: owned.map { acknowledgements(recordName: recordName, listed: $0,
                                                                      shown: [household.id]) } ?? [],
                         absentOwnHouseholdID: absentOwn)
        }

        let ownZoneName = SeedkeepRecordNames.zoneName(householdID: household.id)
        let owned: [GardenZoneSummary]
        let shared: [GardenZoneSummary]
        do {
            owned = try usable(try await identity.listGardenZones(.owned), recordName: recordName)
            guard isCurrent(gen) else { return }
            if owned.contains(where: { $0.zoneName == ownZoneName }) {
                return bind(recordName: recordName, household: household, participant: nil,
                            replacingLegacy: true,
                            acknowledging: acknowledgements(recordName: recordName, listed: owned), gen)
            }
            shared = available(try complete(try await identity.listGardenZones(.shared)), recordName: recordName)
        } catch {
            guard isCurrent(gen) else { return }
            return enterLegacyUnconfirmed(legacy)
        }
        guard isCurrent(gen) else { return }
        let candidates = (owned + shared).filter { $0.householdID != household.id }
        if candidates.isEmpty {
            // Nothing else in this account, and the device's own zone is absent from iCloud: the
            // rows move to a fresh garden ID with a `pending` creation grant (the silent re-home,
            // G3). The device's zone is never recreated.
            return bind(recordName: recordName, household: household, participant: nil,
                        replacingLegacy: true, rehomeTo: mintHouseholdID(),
                        acknowledging: acknowledgements(recordName: recordName, listed: owned), gen)
        }
        offer(GardenChoice(reason: .deviceGardenNotFound(householdID: household.id),
                           candidates: candidates, ownGarden: nil),
              recordName: recordName, deviceHousehold: household,
              listedOwnedIDs: acknowledgements(recordName: recordName, listed: owned,
                                               shown: candidates.filter { $0.scope == .owned }.map(\.householdID)),
              absentOwnHouseholdID: household.id)
    }

    /// No cache: a fresh install or a new device. Never mints over a failed listing, and never
    /// erases: there is no cached owner.
    private func resolveFresh(recordName: String, _ gen: Int) async {
        let shared: [GardenZoneSummary]
        let owned: [GardenZoneSummary]
        do {
            shared = available(try complete(try await identity.listGardenZones(.shared)), recordName: recordName)
            guard isCurrent(gen) else { return }
            owned = try usable(try await identity.listGardenZones(.owned), recordName: recordName)
        } catch {
            guard isCurrent(gen) else { return }
            return block(.couldNotVerify)
        }
        guard isCurrent(gen) else { return }

        let ownGarden: GardenZoneSummary
        switch owned.count {
        case 0: ownGarden = mintGarden()   // a brand-new garden: fresh random ID, creation grant at bind
        case 1: ownGarden = owned[0]
        default:
            return offer(GardenChoice(reason: .multipleOwnGardens, candidates: owned, ownGarden: nil),
                         recordName: recordName, deviceHousehold: nil, sharedZones: shared,
                         listedOwnedIDs: acknowledgements(recordName: recordName, listed: owned,
                                                          shown: owned.map(\.householdID)))
        }
        resolveParticipant(recordName: recordName, ownGarden: ownGarden,
                           own: Self.household(from: ownGarden), ownsGarden: !owned.isEmpty,
                           shared: shared,
                           listedOwned: acknowledgements(recordName: recordName, listed: owned), gen)
    }

    /// The shared step of a fresh resolution, once the own garden is known. `ownsGarden` is true
    /// when that garden is an existing owned zone (not a newly minted one): a lone shared
    /// garden is then a choice, never joined automatically over the user's own.
    private func resolveParticipant(
        recordName: String, ownGarden: GardenZoneSummary, own: HouseholdDTO, ownsGarden: Bool,
        shared: [GardenZoneSummary], listedOwned: [String], _ gen: Int
    ) {
        guard isCurrent(gen) else { return }
        switch shared.count {
        case 0:
            bind(recordName: recordName, household: own, participant: nil, replacingLegacy: false,
                 acknowledging: listedOwned, gen)
        case 1 where !ownsGarden:
            bind(recordName: recordName, household: own, participant: Self.participantRef(shared[0]),
                 replacingLegacy: false, acknowledging: listedOwned, gen)
        case 1:
            offer(GardenChoice(reason: .sharedOrOwnGarden, candidates: shared, ownGarden: ownGarden),
                  recordName: recordName, deviceHousehold: nil, listedOwnedIDs: listedOwned)
        default:
            offer(GardenChoice(reason: .multipleSharedGardens, candidates: shared, ownGarden: ownGarden),
                  recordName: recordName, deviceHousehold: nil, listedOwnedIDs: listedOwned)
        }
    }

    // MARK: - Publishing

    private func block(_ reason: CloudEntryBlock) {
        pendingChoice = nil
        isIdentityVerified = false
        state = .needsICloud(reason)
    }

    private func offer(
        _ choice: GardenChoice, recordName: String, deviceHousehold: HouseholdDTO?,
        sharedZones: [GardenZoneSummary] = [], listedOwnedIDs: [String] = [],
        currentBinding: GardenGuardBinding? = nil, absentOwnHouseholdID: String? = nil
    ) {
        pendingChoice = PendingChoice(recordName: recordName, deviceHousehold: deviceHousehold,
                                      sharedZones: sharedZones, choice: choice,
                                      listedOwnedIDs: listedOwnedIDs, currentBinding: currentBinding,
                                      absentOwnHouseholdID: absentOwnHouseholdID)
        state = .choosingGarden(choice)
    }

    /// Transient failure: enter from the cache as-is with CloudKit paused, or ask to retry.
    private func enterUnverified() {
        pendingChoice = nil
        if let cached = loadCachedIdentity(),
           !(guardStore.isBindingWritten(GardenGuardStore.accountKey(recordName: cached.user.id))
             && guardStore.latestBinding(GardenGuardStore.accountKey(recordName: cached.user.id)) == nil) {
            isIdentityVerified = false
            state = .signedIn(user: cached.user, household: cached.household)
        } else {
            state = .needsICloud(.couldNotVerify)
        }
    }

    /// The account is confirmed but the legacy garden could not be checked (a listing failed).
    /// Enter as-is and unverified, so the next resolution retries the rebind.
    private func enterLegacyUnconfirmed(_ legacy: CachedIdentity) {
        pendingChoice = nil
        isIdentityVerified = false
        state = .signedIn(user: legacy.user, household: legacy.household)
    }

    /// Binds a resolved or chosen garden. The guard's latest binding is written FIRST (with the
    /// `pending` creation grant of a freshly minted garden, and the re-home journal when the device's
    /// garden is kept under a fresh ID, in the same write). Then the participant marker, then the
    /// identity cache, then state. `replacingLegacy` finishes a legacy identity's rebind: the new
    /// cache is written before the legacy key is removed, and the bearer token is cleared only after
    /// both. `acknowledging` (when the owned gardens were listed) marks them acknowledged.
    private func bind(
        recordName: String, household: HouseholdDTO, participant: GardenGuardBinding.Participant?,
        replacingLegacy: Bool, rehomeTo freshHouseholdID: String? = nil, acknowledging: [String]? = nil,
        _ gen: Int
    ) {
        guard isCurrent(gen) else { return }
        if let participant {
            let recorded = (zone: defaults.string(forKey: ActiveGardenContext.participantZoneNameDefaultsKey),
                            owner: defaults.string(forKey: ActiveGardenContext.participantOwnerNameDefaultsKey))
            if recorded.zone != participant.zoneName || recorded.owner != participant.ownerName {
                do {
                    try participantGardenAdopted?(participant.zoneName, participant.ownerName)
                } catch {
                    // The shared garden's sync state could not be reset: write no marker or cache.
                    return fail(error, fallback: "The shared garden couldn't be opened on this device. Try again.")
                }
            }
        }

        // The guard first.
        let account = GardenGuardStore.accountKey(recordName: recordName)
        var grants: [String] = []
        var journals: [String: GardenGoneRecord] = [:]
        if mintedHouseholdIDs.contains(household.id) { grants.append(household.id) }
        if let fresh = freshHouseholdID {
            grants.append(fresh)
            journals[household.id] = GardenGoneRecord(
                reason: .absentZone, action: .rehome, phase: .journaled,
                replacementID: fresh, createdAt: Date())
        }
        do {
            try guardStore.setBinding(
                account, GardenGuardBinding(household: Self.bindingHousehold(household), participant: participant),
                newGrants: grants, journals: journals,
                acknowledging: acknowledging ?? [], initializeDiscovery: acknowledging != nil)
        } catch {
            return fail(error, fallback: "Seedkeep couldn't save its iCloud safety record. Try again.")
        }
        mintedHouseholdIDs.subtract(grants)

        // Then the defaults.
        if let participant {
            ActiveGardenContext.recordParticipant(zoneName: participant.zoneName,
                                                  ownerName: participant.ownerName, in: defaults)
        } else {
            ActiveGardenContext.clearParticipant(in: defaults)
        }
        let user = Self.user(recordName: recordName)
        saveIdentity(CachedIdentity(user: user, household: household), forKey: Self.identityCacheKey)
        if replacingLegacy {
            defaults.removeObject(forKey: Self.legacyIdentityCacheKey)
            tokenStore.clear()
        }
        pendingChoice = nil
        isIdentityVerified = true
        state = .signedIn(user: user, household: household)
        onScopeChange?()   // N2-E: a binding change ends the scope writers started in
        if let fresh = freshHouseholdID {
            rehomer.rehomeRequested(GardenRehomeRequest(
                accountKey: account, fromHouseholdID: household.id, toHouseholdID: fresh, reason: .absentZone))
        }
    }

    /// Runs `eraser` (`localDataEraser` for a different user or sign-out, `gardenSwitchEraser`
    /// for a chooser discard). On failure enters `.failed` (with Retry) and returns false, keeping
    /// the caches so the next attempt still knows whose data is on disk. A stale pass returns
    /// false and publishes nothing.
    private func erase(_ gen: Int, using eraser: (@MainActor (_ requireCurrent: @escaping @MainActor () throws -> Void) async throws -> Void)?) async -> Bool {
        guard isCurrent(gen) else { return false }
        do {
            try await eraser? { [weak self] in
                guard self?.isCurrent(gen) == true else { throw CancellationError() }
                try Task.checkCancellation()
            }
        } catch {
            guard isCurrent(gen) else { return false }
            fail(error)
            return false
        }
        return isCurrent(gen)
    }

    /// `.failed` with Retry, showing the error's own description when it has one.
    private func fail(
        _ error: Error,
        fallback: String = "This device's garden couldn't be cleared, so nothing was changed. Try again."
    ) {
        pendingChoice = nil
        state = .failed(message: (error as? LocalizedError)?.errorDescription ?? fallback)
    }

    private func ownHousehold(for garden: GardenZoneSummary, pending: PendingChoice) -> HouseholdDTO {
        if let deviceHousehold = pending.deviceHousehold, deviceHousehold.id == garden.householdID {
            return deviceHousehold
        }
        return Self.household(from: garden)
    }

    // MARK: - Identity cache

    /// The iCloud identity, else the legacy server identity.
    func loadCachedIdentity() -> CachedIdentity? {
        loadIdentity(forKey: Self.identityCacheKey) ?? loadIdentity(forKey: Self.legacyIdentityCacheKey)
    }

    private func loadIdentity(forKey key: String) -> CachedIdentity? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(CachedIdentity.self, from: data)
    }

    private func saveIdentity(_ identity: CachedIdentity, forKey key: String) {
        guard let data = try? JSONEncoder().encode(identity) else { return }
        defaults.set(data, forKey: key)
    }

    private func clearCachedIdentities() {
        defaults.removeObject(forKey: Self.identityCacheKey)
        defaults.removeObject(forKey: Self.legacyIdentityCacheKey)
    }

    // MARK: - DTOs

    /// A brand-new own garden: a fresh random household ID. Its `pending` creation grant is written
    /// when a binding commits it (`bind`), never before.
    private func mintGarden(name: String = "My garden") -> GardenZoneSummary {
        let id = mintHouseholdID()
        let now = Self.nowMillis()
        return GardenZoneSummary(householdID: id, zoneName: SeedkeepRecordNames.zoneName(householdID: id),
                                 ownerName: CKCurrentUserDefaultName, scope: .owned,
                                 name: name, createdAt: now, updatedAt: now)
    }

    private func mintHouseholdID() -> String {
        let id = makeHouseholdID()
        mintedHouseholdIDs.insert(id)
        return id
    }

    static func participantRef(_ garden: GardenZoneSummary) -> GardenGuardBinding.Participant {
        GardenGuardBinding.Participant(zoneName: garden.zoneName, ownerName: garden.ownerName)
    }

    static func bindingHousehold(_ household: HouseholdDTO) -> GardenGuardBinding.Household {
        GardenGuardBinding.Household(id: household.id, name: household.name,
                                     createdAt: household.created_at, updatedAt: household.updated_at)
    }

    static func dto(_ household: GardenGuardBinding.Household) -> HouseholdDTO {
        makeDTO(DTOFields.Household(id: household.id, name: household.name,
                                    created_at: household.createdAt, updated_at: household.updatedAt))
    }

    private static func summary(for household: HouseholdDTO) -> GardenZoneSummary {
        GardenZoneSummary(householdID: household.id,
                          zoneName: SeedkeepRecordNames.zoneName(householdID: household.id),
                          ownerName: CKCurrentUserDefaultName, scope: .owned, name: household.name,
                          createdAt: household.created_at, updatedAt: household.updated_at)
    }

    static func household(from summary: GardenZoneSummary) -> HouseholdDTO {
        let now = nowMillis()
        return makeDTO(DTOFields.Household(id: summary.householdID, name: summary.name ?? "My garden",
                                           created_at: summary.createdAt ?? now,
                                           updated_at: summary.updatedAt ?? now))
    }

    static func user(recordName: String) -> UserDTO {
        makeDTO(DTOFields.User(id: recordName, name: nil, email: nil))
    }

    private static func nowMillis() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    /// The SeedkeepKit DTOs have no public memberwise init; round-trip a field-for-field mirror.
    private enum DTOFields {
        struct User: Encodable { let id: String; let name: String?; let email: String? }
        struct Household: Encodable { let id: String; let name: String; let created_at: Int64; let updated_at: Int64 }
    }

    private static func makeDTO<Fields: Encodable, DTO: Decodable>(_ fields: Fields) -> DTO {
        // Cannot fail: the mirror encodes exactly the DTO's keys and types.
        try! JSONDecoder().decode(DTO.self, from: JSONEncoder().encode(fields))
    }
}
