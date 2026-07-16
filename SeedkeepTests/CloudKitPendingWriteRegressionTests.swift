import Foundation
import SwiftData
import Testing
@testable import Seedkeep
import SeedkeepKit

@MainActor
@Suite("CloudKit household sync pending writes", .serialized)
struct CloudKitPendingWriteRegressionTests {
    @Test("CloudKit household sync still queues an optimistic seed create")
    func cloudKitFlagDoesNotSuppressPendingWrite() throws {
        let defaults = UserDefaults.standard
        let key = FeatureFlags.cloudKitHouseholdSyncKey
        let previous = defaults.object(forKey: key)
        defer {
            if let previous {
                defaults.set(previous, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
        FeatureFlags.setCloudKitHouseholdSync(true)

        let container = makeTestContainer(name: "cloudKitPendingWriteRegressionTests")
        let client = SeedkeepClient(
            configuration: .init(baseURL: URL(string: "https://test.local")!),
            bearerToken: "test_token"
        )
        let engine = SyncEngine(client: client, container: container)

        _ = try engine.enqueueCreateSeed(
            .init(state: .active, custom_name: "Queued seed"),
            householdID: "household-cloudkit"
        )

        let context = ModelContext(container)
        let pending = try context.fetch(FetchDescriptor<LocalPendingWrite>())
        #expect(pending.count == 1)
        #expect(pending.first?.entityType == "seed")
        #expect(pending.first?.operation == "create")
    }

    @Test("every queue-backed household mutation signals exactly once")
    func everyQueueBackedMutationSignalsExactlyOnce() throws {
        let container = makeTestContainer(name: "queueBackedMutationSignalContract")
        let client = SeedkeepClient(
            configuration: .init(baseURL: URL(string: "https://test.local")!),
            bearerToken: "test_token"
        )
        let engine = SyncEngine(client: client, container: container)
        var signalCount = 0
        engine.onLocalHouseholdMutation = { signalCount += 1 }
        let householdID = "household-cloudkit"

        let location = try engine.enqueueCreateLocation(name: "Shed", householdID: householdID)
        try engine.enqueueUpdateLocation(id: location.id, name: "Barn", sortOrder: nil)
        try engine.enqueueDeleteLocation(id: location.id)
        #expect(signalCount == 3)

        let tag = try engine.enqueueCreateTag(name: "Heirloom", color: nil, householdID: householdID)
        try engine.enqueueUpdateTag(id: tag.id, name: "Saved", color: nil)
        try engine.enqueueDeleteTag(id: tag.id)
        #expect(signalCount == 6)

        let seed = try engine.enqueueCreateSeed(
            .init(state: .active, custom_name: "Queued seed"),
            householdID: householdID
        )
        try engine.enqueueUpdateSeed(id: seed.id, .init(notes: "Water daily"))
        try engine.enqueueDeleteSeed(id: seed.id)
        #expect(signalCount == 9)

        let bed = try engine.enqueueCreateBed(.init(name: "North bed"), householdID: householdID)
        try engine.enqueueUpdateBed(id: bed.id, .init(name: "South bed"))
        try engine.enqueueDeleteBed(id: bed.id)
        #expect(signalCount == 12)

        let event = try engine.enqueueCreatePlantingEvent(
            .init(kind: .sowing, planned_for: "2026-07-15"),
            householdID: householdID
        )
        try engine.enqueueUpdatePlantingEvent(id: event.id, .init(notes: "Thinned"))
        try engine.enqueueDeletePlantingEvent(id: event.id)
        #expect(signalCount == 15)
    }

    @Test("CloudKit mode makes no assistant key request")
    func cloudKitModeSkipsAssistantKeyRequest() async throws {
        let previous = UserDefaults.standard.object(forKey: FeatureFlags.cloudKitHouseholdSyncKey)
        defer { Self.restoreCloudKitFlag(previous) }
        FeatureFlags.setCloudKitHouseholdSync(true)

        let response = Data(#"{"ok":true,"data":{"providers":[{"provider":"anthropic","configured":true,"updated_at":1}]}}"#.utf8)
        let emptyFeed = Data(#"{"ok":true,"data":{"items":[],"cursor":0,"has_more":false}}"#.utf8)
        let session = CatalogRouterMockURLProtocol.makeSession(
            routes: ["GET /api/households/me/assistant_key": response],
            fallbackBody: emptyFeed,
            fallbackStatus: 200
        )
        let client = SeedkeepClient(
            configuration: .init(baseURL: URL(string: "https://test.local")!, session: session),
            bearerToken: "test"
        )
        let coordinator = AIAssistantCoordinator(
            client: client,
            container: makeTestContainer(name: "cloudKitAssistantKeyGate")
        )

        await coordinator.refreshKeyStatus()

        #expect(CatalogRouterMockURLProtocol.capturedPaths().isEmpty,
                "CloudKit mode must not ask the server for assistant capability")
        #expect(coordinator.keyConfigured == false)
        #expect(coordinator.keyCheckError == FeatureFlags.cloudKitGardenCapabilityMessage)
    }

    @Test("CloudKit mode skips the background assistant thread feed")
    func cloudKitModeSkipsAssistantThreadFeed() async {
        let previous = UserDefaults.standard.object(forKey: FeatureFlags.cloudKitHouseholdSyncKey)
        defer { Self.restoreCloudKitFlag(previous) }
        FeatureFlags.setCloudKitHouseholdSync(true)

        let emptyFeed = Data(#"{"ok":true,"data":{"items":[],"cursor":0,"has_more":false}}"#.utf8)
        let session = CatalogRouterMockURLProtocol.makeSession(
            routes: ["/api/assistant/threads": emptyFeed],
            fallbackBody: emptyFeed,
            fallbackStatus: 200
        )
        let client = SeedkeepClient(
            configuration: .init(baseURL: URL(string: "https://test.local")!, session: session),
            bearerToken: "test"
        )
        let engine = SyncEngine(
            client: client,
            container: makeTestContainer(name: "cloudKitAssistantFeedGate")
        )

        _ = await engine.syncAll(householdID: "household-cloudkit")

        #expect(!CatalogRouterMockURLProtocol.capturedPaths().contains("/api/assistant/threads"),
                "CloudKit mode must not pull server-backed assistant history")
    }

    @Test("CloudKit mode blocks every coordinator assistant operation")
    func cloudKitModeBlocksCoordinatorOperations() async throws {
        let previous = UserDefaults.standard.object(forKey: FeatureFlags.cloudKitHouseholdSyncKey)
        defer { Self.restoreCloudKitFlag(previous) }
        FeatureFlags.setCloudKitHouseholdSync(true)

        let emptyFeed = Data(#"{"ok":true,"data":{"items":[],"cursor":0,"has_more":false}}"#.utf8)
        let session = CatalogRouterMockURLProtocol.makeSession(
            fallbackBody: emptyFeed,
            fallbackStatus: 200
        )
        let client = SeedkeepClient(
            configuration: .init(baseURL: URL(string: "https://test.local")!, session: session),
            bearerToken: "test"
        )
        let container = makeTestContainer(name: "cloudKitAssistantOperationGate")
        let coordinator = AIAssistantCoordinator(client: client, container: container)
        let engine = SyncEngine(client: client, container: container)
        coordinator.wireSync(engine)

        await Self.expectCloudKitBlocked { _ = try await coordinator.createThread() }
        await Self.expectCloudKitBlocked { try await coordinator.deleteThread("thread") }
        await Self.expectCloudKitBlocked { try await coordinator.send(text: "hello") }
        await Self.expectCloudKitBlocked { try await coordinator.confirmToolCall("tool") }
        await Self.expectCloudKitBlocked { try await coordinator.cancelToolCall("tool") }
        try await engine.refreshAssistantThread("thread")

        #expect(CatalogRouterMockURLProtocol.capturedPaths().isEmpty,
                "CloudKit mode must block every coordinator and detail-refresh request")
    }

    @Test("flag OFF preserves assistant key refresh")
    func flagOffPreservesAssistantKeyRefresh() async throws {
        let previous = UserDefaults.standard.object(forKey: FeatureFlags.cloudKitHouseholdSyncKey)
        defer { Self.restoreCloudKitFlag(previous) }
        FeatureFlags.setCloudKitHouseholdSync(false)

        let response = Data(#"{"ok":true,"data":{"providers":[{"provider":"anthropic","configured":true,"updated_at":1}]}}"#.utf8)
        let emptyFeed = Data(#"{"ok":true,"data":{"items":[],"cursor":0,"has_more":false}}"#.utf8)
        let session = CatalogRouterMockURLProtocol.makeSession(
            routes: ["GET /api/households/me/assistant_key": response],
            fallbackBody: emptyFeed,
            fallbackStatus: 200
        )
        let client = SeedkeepClient(
            configuration: .init(baseURL: URL(string: "https://test.local")!, session: session),
            bearerToken: "test"
        )
        let coordinator = AIAssistantCoordinator(
            client: client,
            container: makeTestContainer(name: "flagOffAssistantKeyGate")
        )

        await coordinator.refreshKeyStatus()

        #expect(CatalogRouterMockURLProtocol.capturedPaths().contains("/api/households/me/assistant_key"))
        #expect(coordinator.keyConfigured)
    }

    private static func expectCloudKitBlocked(
        _ operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            Issue.record("CloudKit-gated assistant operation unexpectedly succeeded")
        } catch let error as SeedkeepError {
            #expect(error.code == "cloudkit_feature_unavailable")
            #expect(error.message == FeatureFlags.cloudKitGardenCapabilityMessage)
        } catch {
            Issue.record("Unexpected gate error: \(error)")
        }
    }

    private static func restoreCloudKitFlag(_ previous: Any?) {
        if let previous {
            UserDefaults.standard.set(previous, forKey: FeatureFlags.cloudKitHouseholdSyncKey)
        } else {
            UserDefaults.standard.removeObject(forKey: FeatureFlags.cloudKitHouseholdSyncKey)
        }
    }
}
