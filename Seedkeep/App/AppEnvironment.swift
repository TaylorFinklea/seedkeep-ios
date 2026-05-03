import Foundation
import SwiftUI
import SwiftData
import SeedkeepKit

/// Reads launch-time configuration from `Info.plist`, wires the
/// `SeedkeepClient`, the SwiftData `ModelContainer`, the `SyncEngine`,
/// and the `AuthController`. SwiftUI views read this as an `@Environment`.
///
/// We resolve config eagerly at first access so a misconfigured xcconfig
/// crashes the app cleanly during development instead of failing later.
@MainActor
@Observable
public final class AppEnvironment {
    public let client: SeedkeepClient
    public let auth: AuthController
    public let container: ModelContainer
    public let sync: SyncEngine

    public static func live() -> AppEnvironment {
        let baseURL = Self.resolveBaseURL()
        let keychainService = Self.resolveKeychainService()
        let store = KeychainTokenStore(service: keychainService)
        let client = SeedkeepClient(configuration: .init(baseURL: baseURL))
        let auth = AuthController(client: client, tokenStore: store)
        let container = Self.makeModelContainer()
        let sync = SyncEngine(client: client, container: container)
        return AppEnvironment(client: client, auth: auth, container: container, sync: sync)
    }

    private init(client: SeedkeepClient, auth: AuthController, container: ModelContainer, sync: SyncEngine) {
        self.client = client
        self.auth = auth
        self.container = container
        self.sync = sync
    }

    /// Triggers a sync if the user is signed in. Safe to call repeatedly —
    /// `SyncEngine` debounces concurrent calls with `isSyncing`.
    public func syncIfPossible() async {
        if case .signedIn(_, let household) = auth.state {
            await sync.syncAll(householdID: household.id)
        }
    }

    private static func resolveBaseURL() -> URL {
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
        let schema = Schema([
            LocalLocation.self,
            LocalTag.self,
            LocalSeed.self,
            LocalSeedPhoto.self,
            LocalSyncCursor.self,
            LocalPendingWrite.self,
        ])
        let config = ModelConfiguration("seedkeep", schema: schema)
        do {
            return try ModelContainer(for: schema, configurations: config)
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }
}
