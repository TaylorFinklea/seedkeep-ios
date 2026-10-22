import Testing
import Foundation
import SwiftData
@testable import Seedkeep
import SeedkeepKit

/// Identity resolution at sign-in (M5).
///
/// N1: identity resolution is iCloud-only (`FakeCloudIdentityProvider` here). N3 removed the
/// server sync half these tests used to run after it; CloudKit sync is covered by the
/// coordinator and `AppEnvironment` suites.
@MainActor
@Suite("Sign-in + sync orchestration (M5)", .serialized)
struct SignInSyncOrchestrationTests {

    private static let householdID = "hh_orch"

    private static func makeDefaults(_ name: String) -> UserDefaults {
        let suite = "SignInSyncOrchestrationTests.\(name)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    @Test("restoreSession resolves the iCloud identity and its garden")
    func restoreSessionResolvesIdentity() async throws {
        let defaults = Self.makeDefaults("adoptTokenSync")
        let tokenStore = InMemoryTokenStore()

        // N1: the iCloud account resolves the identity; the fake provider lists one owned garden.
        let provider = FakeCloudIdentityProvider(
            recordName: "_u_orch", owned: [FakeCloudIdentityProvider.zone(Self.householdID)], shared: [])
        let auth = AuthController(identity: provider, tokenStore: tokenStore, defaults: defaults)

        await auth.restoreSession()

        guard case .signedIn(let user, let household) = auth.state else {
            Issue.record("expected signedIn after restoreSession, got \(String(describing: auth.state))")
            return
        }
        #expect(user.id == "_u_orch")
        #expect(household.id == Self.householdID)
    }
}
