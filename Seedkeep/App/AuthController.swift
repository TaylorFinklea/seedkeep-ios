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
@MainActor
@Observable
public final class AuthController {
    public enum State: Equatable, Sendable {
        case signedOut
        case authenticating
        case signedIn(user: UserDTO, household: HouseholdDTO)
        case failed(message: String)
    }

    public private(set) var state: State = .signedOut

    private let client: SeedkeepClient
    private let tokenStore: KeychainTokenStore

    public init(client: SeedkeepClient, tokenStore: KeychainTokenStore) {
        self.client = client
        self.tokenStore = tokenStore
    }

    /// Restores the token from keychain and refreshes user/household if
    /// possible. Idempotent — call from `Seedkeep` app `init` or `task`.
    public func restoreSession() async {
        guard let token = tokenStore.load() else { return }
        await client.setBearerToken(token)
        await loadIdentity()
    }

    /// Stores a freshly-minted Bearer token (e.g. after a successful
    /// `/api/auth/sign-in/social/apple` exchange) and resolves identity.
    public func adoptBearerToken(_ token: String) async {
        tokenStore.save(token)
        await client.setBearerToken(token)
        await loadIdentity()
    }

    public func signOut() async {
        tokenStore.clear()
        await client.setBearerToken(nil)
        state = .signedOut
    }

    private func loadIdentity() async {
        state = .authenticating
        do {
            let me = try await client.me()
            let house: HouseholdDTO
            do {
                let res = try await client.createOrFetchHousehold()
                house = res.household
            } catch let err as SeedkeepError where err.code == "no_household" {
                let res = try await client.createOrFetchHousehold(name: "My household")
                house = res.household
            }
            state = .signedIn(user: me.user, household: house)
        } catch let err as SeedkeepError {
            // Token is bad or server is down. Clear local state — user
            // is forced back to sign-in.
            tokenStore.clear()
            await client.setBearerToken(nil)
            state = .failed(message: "\(err.code): \(err.message)")
        } catch {
            state = .failed(message: error.localizedDescription)
        }
    }
}
