import Foundation
import SwiftUI
import SwiftData
import SeedkeepKit

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

    /// Lets feature views request a tab switch (e.g. TopBarSparkleButton →
    /// Assistant). MainTabView observes this and binds it to the TabView's
    /// selection. nil means leave whatever's current.
    public var requestedTab: AppTab?

    public enum AppTab: Hashable {
        case today, library, garden, journal, random, assistant, settings, you
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
        let recommendations = RecommendationStore(client: client, container: container)
        let journal = JournalStore(client: client, container: container)
        let assistant = AIAssistantCoordinator(client: client, container: container)
        assistant.wireSync(sync)
        let subscriptions = SubscriptionManager(client: client)
        return AppEnvironment(
            client: client, auth: auth, container: container,
            sync: sync, recommendations: recommendations,
            journal: journal, assistant: assistant,
            preferences: prefs, apiKeys: apiKeys,
            subscriptions: subscriptions
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
        subscriptions: SubscriptionManager
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
    }

    /// Triggers a sync if the user is signed in. Safe to call repeatedly —
    /// `SyncEngine` debounces concurrent calls with `isSyncing`.
    public func syncIfPossible() async {
        if case .signedIn(_, let household) = auth.state {
            await sync.syncAll(householdID: household.id)
        }
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
        let schema = Schema([
            LocalLocation.self,
            LocalTag.self,
            LocalSeed.self,
            LocalSeedPhoto.self,
            LocalBed.self,
            LocalPlantingEvent.self,
            LocalSyncCursor.self,
            LocalPendingWrite.self,
            LocalRecommendation.self,
            LocalJournalEntry.self,
            LocalJournalEntryPhoto.self,
            LocalJournalChecklistItem.self,
            LocalAssistantThread.self,
            LocalAssistantMessage.self,
            LocalAssistantToolCall.self,
            LocalAssistantKeyStatus.self,
            LocalPetMoodSnapshot.self,
        ])
        let config = ModelConfiguration("seedkeep", schema: schema)
        do {
            return try ModelContainer(for: schema, configurations: config)
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }
}
