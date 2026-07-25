import Foundation
import AuthenticationServices
import SeedkeepKit

/// Auth state machine for the iOS app. Owns the Bearer token, the cached
/// `UserDTO`, and household resolution.
///
/// Phase 1 flow:
///   1. View asks the controller to start sign-in (`signInWithApple`).
///   2. Controller invokes `ASAuthorizationController` (handled by the
///      `AppleSignInCoordinator` — tied to a SwiftUI `signInWithApple`
///      button helper).
///   3. On success, the controller exchanges the Apple identity token
///      against `/api/auth/sign-in/social/apple` (better-auth's path),
///      stores the returned Bearer token in the keychain, fetches
///      `/api/me`, and idempotently `POST /api/households` so the user
///      always lands inside a household.
///
/// Stabilization B3 — offline-first session restore + identity hygiene:
///
///   - The last confirmed identity (user + household) is cached in
///     `UserDefaults`. It records **who owns the local SwiftData store**.
///   - On restore, only a definitive `unauthorized` clears the keychain
///     token. Transport / 5xx / decode failures with a cached identity
///     enter `.signedIn` from the cache so the offline-first app stays
///     usable; sync retries when connectivity returns.
///   - Signing in as a different user (or into a different household)
///     than the cache wipes the local store + queue + cursors +
///     notifications BEFORE the first sync, so account B never sees —
///     or pushes — account A's data.
@MainActor
@Observable
public final class AuthController {
    public enum State: Equatable, Sendable {
        case signedOut
        case authenticating
        case signedIn(user: UserDTO, household: HouseholdDTO)
        case failed(message: String)
    }

    /// Last identity confirmed against the server — the owner of the
    /// local store. Persisted as JSON in `UserDefaults`.
    struct CachedIdentity: Codable, Equatable {
        let user: UserDTO
        let household: HouseholdDTO
    }

    static let identityCacheKey = "seedkeep.auth.lastIdentity"

    public private(set) var state: State = .signedOut

    private let client: SeedkeepClient
    private let tokenStore: any TokenStoring
    private let defaults: UserDefaults

    /// Wipes the local SwiftData store, pending-write queue, cursors,
    /// and scheduled notifications. Wired by `AppEnvironment` (the
    /// controller is constructed before the `ModelContainer` exists).
    @ObservationIgnored private var localDataEraser: (@MainActor () async -> Void)?

    public init(
        client: SeedkeepClient,
        tokenStore: any TokenStoring,
        defaults: UserDefaults = .standard
    ) {
        self.client = client
        self.tokenStore = tokenStore
        self.defaults = defaults
    }

    public func wireLocalDataEraser(_ eraser: @escaping @MainActor () async -> Void) {
        localDataEraser = eraser
    }

    /// Restores the token from keychain and refreshes user/household if
    /// possible. Idempotent — call from `Seedkeep` app `init` or `task`.
    /// Offline-first: a transport failure falls back to the cached
    /// identity instead of dumping the user at the sign-in screen.
    public func restoreSession() async {
        guard let token = tokenStore.load() else { return }
        await client.setBearerToken(token)
        await loadIdentity(allowCachedFallback: true)
    }

    /// Stores a freshly-minted Bearer token (e.g. after a successful
    /// `/api/auth/sign-in/social/apple` exchange) and resolves identity.
    /// No cached fallback here: the token's owner is unknown until the
    /// server confirms it, so entering `.signedIn` as the PREVIOUS
    /// cached identity could push that identity's queue under the new
    /// token.
    public func adoptBearerToken(_ token: String) async {
        tokenStore.save(token)
        await client.setBearerToken(token)
        await loadIdentity(allowCachedFallback: false)
    }

    /// Adopts a household this device has proven membership in through an
    /// EXACT lookup (`SeedkeepClient.household(id:)`), bypassing
    /// `loadIdentity`'s "current household" resolution entirely.
    ///
    /// For the account-deletion successor cutover: after a transfer
    /// re-homes ownership, this device briefly holds TWO memberships, and
    /// the caller already knows — from the transfer itself — exactly
    /// which one to adopt. `loadIdentity` cannot be trusted to land on it
    /// (it resolves via `POST /api/households`, itself now ordered by
    /// most-recent-join but still a heuristic, not the transfer's own
    /// authority).
    ///
    /// Updates BOTH `state` and the cached identity together so a LATER
    /// ordinary `restoreSession()` sees the SAME household this call just
    /// adopted — never mistakes it for an identity switch, and never
    /// wipes the very data this call exists to preserve.
    ///
    /// A no-op when nobody is signed in: adopting a household requires an
    /// authenticated user to adopt it AS, and the caller (the deletion
    /// coordinator's session seam) has no such user to hand it here.
    public func adoptHousehold(_ household: HouseholdDTO) {
        guard case .signedIn(let user, _) = state else { return }
        saveCachedIdentity(CachedIdentity(user: user, household: household))
        state = .signedIn(user: user, household: household)
    }

    public func signOut() async {
        tokenStore.clear()
        await client.setBearerToken(nil)
        // Erase BEFORE flipping state: the next account must never see
        // this account's library/journal, and the pending-write queue
        // must never flush into the next account's household.
        await localDataEraser?()
        clearCachedIdentity()
        state = .signedOut
    }

    /// Resolves which household this identity should enter `.signedIn`
    /// with — preferring an EXACT, re-validated answer over the
    /// ambiguous "current household" heuristic.
    ///
    /// A device that has already cached a household (from a normal
    /// sign-in, or from `adoptHousehold` after a successor cutover) asks
    /// the server whether it is STILL a member of exactly that one
    /// (`GET /api/households/:id`) before ever touching
    /// `POST /api/households`'s most-recently-joined resolution. That
    /// heuristic is a best-effort answer over a table this user can hold
    /// more than one row in — the exact-membership route is not a
    /// heuristic, it is the fact itself. Only when the cached household
    /// no longer holds (`not_a_member` — left, reassigned) does
    /// resolution fall through to it, exactly as a fresh sign-in already
    /// does with no cache at all.
    ///
    /// Any error OTHER than `not_a_member` propagates to `loadIdentity`'s
    /// existing catch blocks unchanged — a transport failure here must
    /// fall back to the cache the same way a transport failure from the
    /// generic route always has, not be silently reinterpreted.
    private func resolveHousehold(for userID: String) async throws -> HouseholdDTO {
        if let cached = loadCachedIdentity(), cached.user.id == userID {
            do {
                return try await client.household(id: cached.household.id).household
            } catch let err as SeedkeepError where err.code == "not_a_member" {
                // This device's own last-known household is gone. Fall
                // through to resolving a current one below.
            }
        }
        do {
            return try await client.createOrFetchHousehold().household
        } catch let err as SeedkeepError where err.code == "no_household" {
            return try await client.createOrFetchHousehold(name: "My household").household
        }
    }

    private func loadIdentity(allowCachedFallback: Bool) async {
        state = .authenticating
        do {
            let me = try await client.me()
            let house = try await resolveHousehold(for: me.user.id)
            // Identity switch: the store belongs to a different user or
            // household than the one the server just confirmed. Wipe it
            // before the first sync.
            if let cached = loadCachedIdentity(),
               cached.user.id != me.user.id || cached.household.id != house.id {
                await localDataEraser?()
            }
            saveCachedIdentity(CachedIdentity(user: me.user, household: house))
            state = .signedIn(user: me.user, household: house)
        } catch let err as SeedkeepError where err.code == "unauthorized" || err.httpStatus == 401 {
            // Definitive: the token is bad. Clear it; the user must sign
            // in again. The identity cache is KEPT — it records who owns
            // the local store, so a later different-user sign-in still
            // triggers the wipe.
            tokenStore.clear()
            await client.setBearerToken(nil)
            state = .failed(message: humanizeError(err))
        } catch {
            // Transport / 5xx / decode failure: the token may be fine
            // and the server merely unreachable (offline cold launch,
            // mid-deploy 502). Never destroy the session for this.
            if allowCachedFallback, let cached = loadCachedIdentity() {
                state = .signedIn(user: cached.user, household: cached.household)
            } else {
                state = .failed(message: humanizeError(error))
            }
        }
    }

    // MARK: - Identity cache

    func loadCachedIdentity() -> CachedIdentity? {
        guard let data = defaults.data(forKey: Self.identityCacheKey) else { return nil }
        return try? JSONDecoder().decode(CachedIdentity.self, from: data)
    }

    private func saveCachedIdentity(_ identity: CachedIdentity) {
        guard let data = try? JSONEncoder().encode(identity) else { return }
        defaults.set(data, forKey: Self.identityCacheKey)
    }

    private func clearCachedIdentity() {
        defaults.removeObject(forKey: Self.identityCacheKey)
    }
}
