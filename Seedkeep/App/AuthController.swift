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
///   - A fresh device lists its gardens, binds the only one, mints a deterministic household
///     when there is none, and asks the user when there is more than one.
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

    /// Wipes the local SwiftData store, pending-write queue, cursors, scheduled notifications and
    /// CloudKit engine state. Wired by `AppEnvironment` (the controller is constructed before the
    /// `ModelContainer` exists). THROWS when the wipe did not complete: nothing binds over a
    /// store that still holds another account's data.
    @ObservationIgnored private var localDataEraser: (@MainActor () async throws -> Void)?

    /// Removes only this device's garden (household rows and their CloudKit sync state) for an
    /// explicit chooser discard. Unlike `localDataEraser` it keeps device-only data such as
    /// journal recovery items, forecasts and notifications: the iCloud user has not changed.
    /// THROWS when the wipe did not complete; the choice then binds nothing.
    @ObservationIgnored private var gardenSwitchEraser: (@MainActor () async throws -> Void)?

    /// Called before the participant marker is set to a DIFFERENT shared garden than the one
    /// recorded, with that garden's zone. `AppEnvironment` resets the zone's engine state so the
    /// participant coordinator re-fetches it in full, as `bootParticipant` does; a stale cursor
    /// from an earlier join would otherwise leave the garden partly empty. THROWS when the reset
    /// failed: the binding then stops in `.failed` with nothing written.
    @ObservationIgnored private var participantGardenAdopted: (@MainActor (_ zoneName: String, _ ownerName: String) throws -> Void)?

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
    }

    init(
        identity: any CloudIdentityProviding,
        tokenStore: any TokenStoring,
        defaults: UserDefaults = .standard
    ) {
        self.identity = identity
        self.tokenStore = tokenStore
        self.defaults = defaults
    }

    func wireLocalDataEraser(_ eraser: @escaping @MainActor () async throws -> Void) {
        localDataEraser = eraser
    }

    func wireGardenSwitchEraser(_ eraser: @escaping @MainActor () async throws -> Void) {
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
        // A choice that removes this device's garden needs the user's confirmation.
        if Self.choiceDiscardsDeviceData(choice, garden) && !discardingDeviceData { return }
        let gen = nextGeneration()
        if discardingDeviceData {
            guard await erase(gen, using: gardenSwitchEraser) else { return }
        }

        if garden.scope == .owned {
            // An owned choice sets the own household and leaves any shared garden.
            let own = ownHousehold(for: garden, pending: pending)
            if case .multipleOwnGardens = choice.reason {
                // Fresh device: the shared step still follows, with this own garden.
                resolveParticipant(recordName: pending.recordName, ownGarden: garden, own: own,
                                   ownsGarden: true, shared: pending.sharedZones, gen)
                return
            }
            bind(recordName: pending.recordName, household: own, participant: nil,
                 replacingLegacy: pending.deviceHousehold != nil, gen)
        } else {
            // A shared choice keeps the own household and records the shared garden.
            let own: HouseholdDTO
            if let deviceHousehold = pending.deviceHousehold {
                own = deviceHousehold
            } else if let ownGarden = choice.ownGarden {
                own = ownHousehold(for: ownGarden, pending: pending)
            } else {
                own = Self.household(from: Self.deterministicGarden(recordName: pending.recordName))
            }
            bind(recordName: pending.recordName, household: own, participant: garden,
                 replacingLegacy: pending.deviceHousehold != nil, gen)
        }
    }

    /// `.deviceGardenNotFound`: rebind to the household this device already holds. No wipe.
    func keepDeviceGarden() async {
        guard case .choosingGarden(let choice) = state, choice.canKeepDeviceGarden else { return }
        guard let pending = pendingChoice, pending.choice == choice else {
            // An account change withdrew this choice: resolve again rather than ignore the tap.
            return await restoreSession()
        }
        guard let deviceHousehold = pending.deviceHousehold else { return }
        let gen = nextGeneration()
        bind(recordName: pending.recordName, household: deviceHousehold, participant: nil,
             replacingLegacy: true, gen)
    }

    /// Called on `.CKAccountChanged`. The notification alone never wipes: only a confirmed
    /// different user record name does. CloudKit pauses at once (`isIdentityVerified = false`,
    /// before any await) and resumes only once the same user is confirmed or a resolution binds;
    /// any pending chooser choice is withdrawn.
    func revalidateAfterAccountChange() async {
        let gen = nextGeneration()
        pauseForAccountChange()
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
    }

    /// Kept for the account-deletion seam; no UI calls it in N1. Wipes BEFORE clearing the
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

    /// Adopts a household this device has proven membership in, keeping the signed-in user.
    /// Updates `state` and the cached identity together, so a later restore sees the same
    /// household and never mistakes it for an identity switch. A no-op when not signed in.
    func adoptHousehold(_ household: HouseholdDTO) {
        guard case .signedIn(let user, _) = state else { return }
        let identity = CachedIdentity(user: user, household: household)
        // Write the cache in use. An unrebound legacy identity must stay legacy: its server user
        // ID in the iCloud cache would read as a different iCloud user and wipe the store.
        if loadIdentity(forKey: Self.identityCacheKey) == nil,
           loadIdentity(forKey: Self.legacyIdentityCacheKey) != nil {
            saveIdentity(identity, forKey: Self.legacyIdentityCacheKey)
        } else {
            saveIdentity(identity, forKey: Self.identityCacheKey)
        }
        state = .signedIn(user: user, household: household)
    }

    /// True when choosing `garden` from `choice` removes this device's garden, so the chooser
    /// must confirm first and then pass `discardingDeviceData: true`. Keeping the device garden
    /// (`keepDeviceGarden`) never discards.
    static func choiceDiscardsDeviceData(_ choice: GardenChoice, _ garden: GardenZoneSummary) -> Bool {
        switch choice.reason {
        case .deviceGardenNotFound, .sharedGardenUnavailable: return true
        case .multipleOwnGardens, .multipleSharedGardens, .sharedOrOwnGarden: return false
        }
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

    private func resolve(recordName: String, _ gen: Int) async {
        if let cached = loadIdentity(forKey: Self.identityCacheKey) {
            if defaults.object(forKey: Self.legacyIdentityCacheKey) != nil {
                // A rebind was interrupted after writing the new cache: finish it.
                defaults.removeObject(forKey: Self.legacyIdentityCacheKey)
                tokenStore.clear()
            }
            if cached.user.id == recordName {
                pendingChoice = nil
                isIdentityVerified = true
                state = .signedIn(user: cached.user, household: cached.household)
                return
            }
            // A confirmed different iCloud user: wipe the previous user's store, then resolve
            // the new user as a fresh device.
            isIdentityVerified = false
            guard await erase(gen, using: localDataEraser) else { return }
            clearCachedIdentities()
            ActiveGardenContext.clearParticipant(in: defaults)
            await resolveFresh(recordName: recordName, gen)
            return
        }
        if let legacy = loadIdentity(forKey: Self.legacyIdentityCacheKey) {
            await resolveLegacy(legacy, recordName: recordName, gen)
            return
        }
        await resolveFresh(recordName: recordName, gen)
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

    /// Legacy server identity: find its garden in this iCloud account and rebind in place.
    private func resolveLegacy(_ legacy: CachedIdentity, recordName: String, _ gen: Int) async {
        let household = legacy.household
        if let marker = ActiveGardenContext.participant(in: defaults) {
            let isMarkerZone = { (zone: GardenZoneSummary) in
                zone.zoneName == marker.zoneName && zone.ownerName == marker.ownerName
            }
            let shared: [GardenZoneSummary]
            do {
                shared = try await identity.listGardenZones(.shared)
            } catch {
                guard isCurrent(gen) else { return }
                return enterLegacyUnconfirmed(legacy)
            }
            guard isCurrent(gen) else { return }
            if shared.contains(where: isMarkerZone) {
                return rebind(recordName: recordName, household: household)
            }
            // The shared garden is gone. Offer the own garden and any other shared gardens.
            let owned = try? await identity.listGardenZones(.owned)
            guard isCurrent(gen) else { return }
            let ownGarden = owned?.first { $0.householdID == household.id } ?? Self.summary(for: household)
            let choice = GardenChoice(reason: .sharedGardenUnavailable(zoneName: marker.zoneName),
                                      candidates: shared.filter { !isMarkerZone($0) },
                                      ownGarden: ownGarden)
            return offer(choice, recordName: recordName, deviceHousehold: household)
        }

        let ownZoneName = SeedkeepRecordNames.zoneName(householdID: household.id)
        let owned: [GardenZoneSummary]
        let shared: [GardenZoneSummary]
        do {
            owned = try await identity.listGardenZones(.owned)
            guard isCurrent(gen) else { return }
            if owned.contains(where: { $0.zoneName == ownZoneName }) {
                return rebind(recordName: recordName, household: household)
            }
            shared = try await identity.listGardenZones(.shared)
        } catch {
            guard isCurrent(gen) else { return }
            return enterLegacyUnconfirmed(legacy)
        }
        guard isCurrent(gen) else { return }
        let candidates = (owned + shared).filter { $0.householdID != household.id }
        if candidates.isEmpty {
            // Nothing else in this account: keep the device's garden. The owner coordinator
            // provisions its zone at first sync, as before.
            return rebind(recordName: recordName, household: household)
        }
        offer(GardenChoice(reason: .deviceGardenNotFound(householdID: household.id),
                           candidates: candidates, ownGarden: nil),
              recordName: recordName, deviceHousehold: household)
    }

    /// No cache: a fresh install or a new device. Never mints over a failed listing, and never
    /// erases: there is no cached owner.
    private func resolveFresh(recordName: String, _ gen: Int) async {
        let shared: [GardenZoneSummary]
        let owned: [GardenZoneSummary]
        do {
            shared = try await identity.listGardenZones(.shared)
            guard isCurrent(gen) else { return }
            owned = try await identity.listGardenZones(.owned)
        } catch {
            guard isCurrent(gen) else { return }
            return block(.couldNotVerify)
        }
        guard isCurrent(gen) else { return }

        let ownGarden: GardenZoneSummary
        switch owned.count {
        case 0: ownGarden = Self.deterministicGarden(recordName: recordName)
        case 1: ownGarden = owned[0]
        default:
            return offer(GardenChoice(reason: .multipleOwnGardens, candidates: owned, ownGarden: nil),
                         recordName: recordName, deviceHousehold: nil, sharedZones: shared)
        }
        resolveParticipant(recordName: recordName, ownGarden: ownGarden,
                           own: Self.household(from: ownGarden), ownsGarden: !owned.isEmpty,
                           shared: shared, gen)
    }

    /// The shared step of a fresh resolution, once the own garden is known. `ownsGarden` is true
    /// when that garden is an existing owned zone (not the deterministic one): a lone shared
    /// garden is then a choice, never joined automatically over the user's own.
    private func resolveParticipant(
        recordName: String, ownGarden: GardenZoneSummary, own: HouseholdDTO, ownsGarden: Bool,
        shared: [GardenZoneSummary], _ gen: Int
    ) {
        guard isCurrent(gen) else { return }
        switch shared.count {
        case 0:
            bind(recordName: recordName, household: own, participant: nil, replacingLegacy: false, gen)
        case 1 where !ownsGarden:
            bind(recordName: recordName, household: own, participant: shared[0], replacingLegacy: false, gen)
        case 1:
            offer(GardenChoice(reason: .sharedOrOwnGarden, candidates: shared, ownGarden: ownGarden),
                  recordName: recordName, deviceHousehold: nil)
        default:
            offer(GardenChoice(reason: .multipleSharedGardens, candidates: shared, ownGarden: ownGarden),
                  recordName: recordName, deviceHousehold: nil)
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
        sharedZones: [GardenZoneSummary] = []
    ) {
        pendingChoice = PendingChoice(recordName: recordName, deviceHousehold: deviceHousehold,
                                      sharedZones: sharedZones, choice: choice)
        state = .choosingGarden(choice)
    }

    /// Transient failure: enter from the cache as-is with CloudKit paused, or ask to retry.
    private func enterUnverified() {
        pendingChoice = nil
        if let cached = loadCachedIdentity() {
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

    /// Crash-safe rebind of a legacy identity to the iCloud user: the new cache is written
    /// before the legacy key is removed, and the bearer token is cleared only after both. The
    /// household ID, cursors, markers and pending writes are untouched; nothing is wiped.
    private func rebind(recordName: String, household: HouseholdDTO) {
        let user = Self.user(recordName: recordName)
        saveIdentity(CachedIdentity(user: user, household: household), forKey: Self.identityCacheKey)
        defaults.removeObject(forKey: Self.legacyIdentityCacheKey)
        tokenStore.clear()
        pendingChoice = nil
        isIdentityVerified = true
        state = .signedIn(user: user, household: household)
    }

    /// Binds a resolved or chosen garden: the participant marker first, then the cache, then
    /// state. `replacingLegacy` finishes a legacy identity's rebind.
    private func bind(
        recordName: String, household: HouseholdDTO, participant: GardenZoneSummary?,
        replacingLegacy: Bool, _ gen: Int
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
            ActiveGardenContext.recordParticipant(zoneName: participant.zoneName,
                                                  ownerName: participant.ownerName, in: defaults)
        } else {
            ActiveGardenContext.clearParticipant(in: defaults)
        }
        if replacingLegacy {
            return rebind(recordName: recordName, household: household)
        }
        let user = Self.user(recordName: recordName)
        saveIdentity(CachedIdentity(user: user, household: household), forKey: Self.identityCacheKey)
        pendingChoice = nil
        isIdentityVerified = true
        state = .signedIn(user: user, household: household)
    }

    /// Runs `eraser` (`localDataEraser` for a different user or sign-out, `gardenSwitchEraser`
    /// for a chooser discard). On failure enters `.failed` (with Retry) and returns false, keeping
    /// the caches so the next attempt still knows whose data is on disk. A stale pass returns
    /// false and publishes nothing.
    private func erase(_ gen: Int, using eraser: (@MainActor () async throws -> Void)?) async -> Bool {
        guard isCurrent(gen) else { return false }
        do {
            try await eraser?()
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

    /// The synthetic own garden of an account that has none: the deterministic household ID.
    static func deterministicGarden(recordName: String) -> GardenZoneSummary {
        let id = DeterministicHouseholdID.make(userRecordName: recordName)
        let now = nowMillis()
        return GardenZoneSummary(householdID: id, zoneName: SeedkeepRecordNames.zoneName(householdID: id),
                                 ownerName: CKCurrentUserDefaultName, scope: .owned,
                                 name: "My garden", createdAt: now, updatedAt: now)
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
