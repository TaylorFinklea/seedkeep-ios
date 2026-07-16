import Foundation
import SwiftData
import Testing
@testable import Seedkeep
import SeedkeepKit
import SeedkeepCloudKit

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

    @Test("CloudKit photo capability blocks server photo operations with preservation copy")
    func cloudKitModeBlocksServerPhotoCapability() throws {
        let previous = UserDefaults.standard.object(forKey: FeatureFlags.cloudKitHouseholdSyncKey)
        defer { Self.restoreCloudKitFlag(previous) }
        FeatureFlags.setCloudKitHouseholdSync(true)

        #expect(PhotoFeatureGate.isRestricted)
        #expect(FeatureFlags.cloudKitPhotoCapabilityMessage.contains("temporarily unavailable"))
        #expect(FeatureFlags.cloudKitPhotoCapabilityMessage.contains("preserved"))
        do {
            try PhotoFeatureGate.requireAvailable()
            Issue.record("CloudKit photo operation unexpectedly allowed")
        } catch let error as SeedkeepError {
            #expect(error.code == "cloudkit_feature_unavailable")
            #expect(error.message == FeatureFlags.cloudKitPhotoCapabilityMessage)
        }
    }

    @Test("CloudKit mode blocks every photo byte operation before any server request")
    func cloudKitModeBlocksEveryPhotoByteOperationBeforeServerRequest() async throws {
        let previous = UserDefaults.standard.object(forKey: FeatureFlags.cloudKitHouseholdSyncKey)
        defer { Self.restoreCloudKitFlag(previous) }
        FeatureFlags.setCloudKitHouseholdSync(true)

        let session = CatalogRouterMockURLProtocol.makeSession(
            fallbackBody: Data(),
            fallbackStatus: 500
        )
        let client = SeedkeepClient(
            configuration: .init(baseURL: URL(string: "https://test.local")!, session: session),
            bearerToken: "test"
        )
        let engine = SyncEngine(
            client: client,
            container: makeTestContainer(name: "cloudKitPhotoOperationGate")
        )

        await Self.expectPhotoBlocked {
            try await engine.refreshSeedPhotos(seedID: "seed", householdID: "household")
        }
        await Self.expectPhotoBlocked {
            try await engine.uploadPhoto(
                seedID: "seed",
                role: .extra,
                jpegData: Data("jpeg".utf8),
                householdID: "household")
        }
        await Self.expectPhotoBlocked {
            _ = try await engine.fetchSeedPhotoData(photoID: "seed-photo")
        }
        await Self.expectPhotoBlocked {
            _ = try await engine.uploadJournalPhoto(
                entryId: "entry",
                jpegData: Data("jpeg".utf8),
                width: 10,
                height: 20)
        }
        await Self.expectPhotoBlocked {
            try await engine.deleteJournalPhoto("journal-photo")
        }
        await Self.expectPhotoBlocked {
            _ = try await engine.journalPhotoData(photoId: "journal-photo")
        }

        #expect(CatalogRouterMockURLProtocol.capturedPaths().isEmpty)
    }

    @Test("flag OFF preserves the server photo byte path")
    func flagOffPreservesServerPhotoBytePath() async throws {
        let previous = UserDefaults.standard.object(forKey: FeatureFlags.cloudKitHouseholdSyncKey)
        defer { Self.restoreCloudKitFlag(previous) }
        FeatureFlags.setCloudKitHouseholdSync(false)

        let bytes = Data("jpeg".utf8)
        let session = CatalogRouterMockURLProtocol.makeSession(
            fallbackBody: bytes,
            fallbackStatus: 200
        )
        let client = SeedkeepClient(
            configuration: .init(baseURL: URL(string: "https://test.local")!, session: session),
            bearerToken: "test"
        )
        let engine = SyncEngine(
            client: client,
            container: makeTestContainer(name: "flagOffPhotoBytePath")
        )

        #expect(!PhotoFeatureGate.isRestricted)
        try PhotoFeatureGate.requireAvailable()
        #expect(try await engine.fetchSeedPhotoData(photoID: "legacy-photo") == bytes)
        #expect(CatalogRouterMockURLProtocol.capturedPaths() == ["/api/photos/legacy-photo"])
    }

    @Test("photo capability follows owner, participant, and rollback garden modes")
    func photoCapabilityFollowsActiveGardenModes() {
        let previous = UserDefaults.standard.object(forKey: FeatureFlags.cloudKitHouseholdSyncKey)
        defer { Self.restoreCloudKitFlag(previous) }
        let modes: [(household: String, zone: String?, cloudKit: Bool, activeID: String, restricted: Bool)] = [
            ("owner-household", nil, true, "owner-household", true),
            ("participant-household", "seedkeep-owner-household", true, "owner-household", true),
            ("participant-household", "seedkeep-owner-household", false, "participant-household", false)
        ]

        for mode in modes {
            FeatureFlags.setCloudKitHouseholdSync(mode.cloudKit)
            let activeHouseholdID = ActiveGardenContext.householdID(
                signedInHouseholdID: mode.household,
                participantZoneName: mode.zone,
                cloudKitSyncEnabled: mode.cloudKit
            )
            #expect(activeHouseholdID == mode.activeID)
            #expect(PhotoFeatureGate.isRestricted == mode.restricted)
        }
    }

    @Test("CloudKit journal and checklist mutations stay local under the active garden")
    func cloudKitJournalAndChecklistMutationsStayLocal() async throws {
        let previous = UserDefaults.standard.object(forKey: FeatureFlags.cloudKitHouseholdSyncKey)
        defer { Self.restoreCloudKitFlag(previous) }
        FeatureFlags.setCloudKitHouseholdSync(true)

        let session = CatalogRouterMockURLProtocol.makeSession(
            fallbackBody: Data(),
            fallbackStatus: 500
        )
        let container = makeTestContainer(name: "cloudKitLocalJournalMutations")
        let store = JournalStore(
            client: SeedkeepClient(
                configuration: .init(baseURL: URL(string: "https://test.local")!, session: session),
                bearerToken: "test"
            ),
            container: container
        )
        var saveSignals = 0
        store.onLocalHouseholdMutation = { saveSignals += 1 }
        let activeGardenID = "owner-active-garden"
        let activeScopeID = HouseholdCloudCoordinator.ownerScopeID(householdID: activeGardenID)
        store.cloudKitScopeIDProvider = { activeScopeID }
        let previousYear = Calendar.current.component(.year, from: Date()) - 1

        await store.refresh()
        let entry = try await store.create(
            occurredOn: "\(previousYear)-07-15",
            body: "Created locally",
            householdID: activeGardenID
        )
        try await store.update(
            entry,
            occurredOn: "\(previousYear)-07-15",
            body: "Updated locally",
            seedID: nil,
            bedID: nil,
            plantingEventID: nil,
            householdID: activeGardenID
        )
        let checklist = try await store.addChecklistItem(
            entryID: entry.id,
            text: "Water",
            householdID: activeGardenID
        )
        try await store.updateChecklistItem(
            checklist,
            completed: true,
            householdID: activeGardenID
        )

        let retrospective = try await store.retrospective(on: "07-15", householdID: activeGardenID)
        #expect(retrospective.years.map(\.year) == [previousYear])
        #expect(retrospective.years.first?.entries.map(\.body) == ["Updated locally"])

        try await store.deleteChecklistItem(checklist, householdID: activeGardenID)
        try await store.softDelete(entry, householdID: activeGardenID)
        let retrospectiveAfterDelete = try await store.retrospective(
            on: "07-15",
            householdID: activeGardenID
        )

        let context = ModelContext(container)
        let entryID = entry.id
        let savedEntry = try #require(
            context.fetch(FetchDescriptor<LocalJournalEntry>(predicate: #Predicate { $0.id == entryID })).first
        )
        #expect(savedEntry.householdID == activeGardenID)
        #expect(savedEntry.deletedAt != nil)
        #expect(retrospectiveAfterDelete.years.isEmpty)
        #expect(try context.fetch(FetchDescriptor<LocalJournalChecklistItem>()).isEmpty)
        let deletionIntents = try context.fetch(FetchDescriptor<LocalCloudKitDeletion>())
        #expect(deletionIntents.count == 1)
        #expect(deletionIntents.first?.householdID == activeGardenID)
        #expect(deletionIntents.first?.scopeID == activeScopeID)
        #expect(deletionIntents.first?.recordName == SeedkeepRecordNames.journalChecklistItem(checklist.id))
        #expect(saveSignals == 6)
        #expect(CatalogRouterMockURLProtocol.capturedPaths().isEmpty,
                "CloudKit journal/checklist mutations and refreshes must not hit the legacy server")
    }

    @Test("journal creates use the active owner, participant, and rollback garden IDs")
    func journalCreateFollowsActiveGardenModes() async throws {
        let previous = UserDefaults.standard.object(forKey: FeatureFlags.cloudKitHouseholdSyncKey)
        defer { Self.restoreCloudKitFlag(previous) }
        let modes: [(signedIn: String, zone: String?, cloudKit: Bool, active: String)] = [
            ("owner-server-household", nil, true, "owner-server-household"),
            ("participant-server-household", "seedkeep-owner-shared-household", true, "owner-shared-household"),
            ("participant-server-household", "seedkeep-owner-shared-household", false, "participant-server-household")
        ]

        for (index, mode) in modes.enumerated() {
            FeatureFlags.setCloudKitHouseholdSync(mode.cloudKit)
            let active = ActiveGardenContext.householdID(
                signedInHouseholdID: mode.signedIn,
                participantZoneName: mode.zone,
                cloudKitSyncEnabled: mode.cloudKit
            )
            #expect(active == mode.active)
            let response = Data(#"{"ok":true,"data":{"entry":{"id":"server-entry","householdId":"participant-server-household","occurredOn":"2026-07-15","body":"Rollback","seedId":null,"bedId":null,"plantingEventId":null,"createdAt":1,"updatedAt":1,"deletedAt":null}}}"#.utf8)
            let session = CatalogRouterMockURLProtocol.makeSession(
                routes: ["POST /api/journal": response],
                fallbackBody: Data(),
                fallbackStatus: mode.cloudKit ? 500 : 200
            )
            let store = JournalStore(
                client: SeedkeepClient(
                    configuration: .init(baseURL: URL(string: "https://test.local")!, session: session),
                    bearerToken: "test"
                ),
                container: makeTestContainer(name: "journalActiveGardenMode-\(index)")
            )

            let entry = try await store.create(
                occurredOn: "2026-07-15",
                body: "Mode",
                householdID: active
            )

            #expect(entry.householdID == mode.active)
            #expect(CatalogRouterMockURLProtocol.capturedPaths().isEmpty == mode.cloudKit)
        }
    }

    @Test("CloudKit journal mutations reject parked-household rows")
    func cloudKitJournalMutationsRejectParkedRows() async throws {
        let previous = UserDefaults.standard.object(forKey: FeatureFlags.cloudKitHouseholdSyncKey)
        defer { Self.restoreCloudKitFlag(previous) }
        FeatureFlags.setCloudKitHouseholdSync(true)

        let container = makeTestContainer(name: "cloudKitJournalParkedRows")
        let context = ModelContext(container)
        let parked = LocalJournalEntry(
            id: "parked-entry", householdID: "parked-solo-household",
            occurredOn: "2026-07-15", body: "Parked",
            seedID: nil, bedID: nil, plantingEventID: nil,
            createdAt: 1, updatedAt: 2, deletedAt: nil
        )
        let parkedItem = LocalJournalChecklistItem(
            id: "parked-item", entryID: parked.id, text: "Parked",
            completed: false, sortOrder: 0, updatedAt: 2
        )
        context.insert(parked)
        context.insert(parkedItem)
        try context.save()

        let store = JournalStore(
            client: SeedkeepClient(
                configuration: .init(baseURL: URL(string: "https://test.local")!),
                bearerToken: "test"
            ),
            container: container
        )
        var mutationSignals = 0
        store.onLocalHouseholdMutation = { mutationSignals += 1 }

        await Self.expectInactiveGarden {
            try await store.update(
                parked,
                occurredOn: parked.occurredOn,
                body: "Wrong garden",
                seedID: nil,
                bedID: nil,
                plantingEventID: nil,
                householdID: "active-shared-household"
            )
        }
        await Self.expectInactiveGarden {
            try await store.deleteChecklistItem(
                parkedItem,
                householdID: "active-shared-household"
            )
        }

        #expect(mutationSignals == 0)
        #expect(try ModelContext(container).fetch(FetchDescriptor<LocalJournalChecklistItem>()).count == 1)
        #expect(try ModelContext(container).fetch(FetchDescriptor<LocalCloudKitDeletion>()).isEmpty)
    }

    @Test("flag OFF preserves every journal and checklist server mutation path")
    func flagOffPreservesJournalAndChecklistServerPaths() async throws {
        let previous = UserDefaults.standard.object(forKey: FeatureFlags.cloudKitHouseholdSyncKey)
        defer { Self.restoreCloudKitFlag(previous) }
        FeatureFlags.setCloudKitHouseholdSync(false)

        let entry = #"{"id":"entry-1","householdId":"server-household","occurredOn":"2025-07-15","body":"Server entry","seedId":null,"bedId":null,"plantingEventId":null,"createdAt":1,"updatedAt":2,"deletedAt":null}"#
        let updated = #"{"id":"entry-1","householdId":"server-household","occurredOn":"2025-07-15","body":"Updated","seedId":null,"bedId":null,"plantingEventId":null,"createdAt":1,"updatedAt":3,"deletedAt":null}"#
        let item = #"{"id":"item-1","entryId":"entry-1","text":"Water","completed":false,"sortOrder":0,"updatedAt":2}"#
        let completed = #"{"id":"item-1","entryId":"entry-1","text":"Water","completed":true,"sortOrder":0,"updatedAt":3}"#
        let routes: [String: Data] = [
            "POST /api/journal": Data("{\"ok\":true,\"data\":{\"entry\":\(entry)}}".utf8),
            "PATCH /api/journal/entry-1": Data("{\"ok\":true,\"data\":{\"entry\":\(updated)}}".utf8),
            "POST /api/journal/entry-1/checklist": Data("{\"ok\":true,\"data\":{\"item\":\(item)}}".utf8),
            "PATCH /api/journal/checklist/item-1": Data("{\"ok\":true,\"data\":{\"item\":\(completed)}}".utf8),
            "DELETE /api/journal/checklist/item-1": Data(#"{"ok":true,"data":{"id":"item-1"}}"#.utf8),
            "GET /api/journal/retrospective": Data("{\"ok\":true,\"data\":{\"anchor\":\"07-15\",\"years\":[{\"year\":2025,\"entries\":[\(updated)]}]}}".utf8),
            "DELETE /api/journal/entry-1": Data(#"{"ok":true,"data":{"id":"entry-1"}}"#.utf8)
        ]
        let session = CatalogRouterMockURLProtocol.makeSession(
            routes: routes,
            fallbackBody: Data(),
            fallbackStatus: 200
        )
        let container = makeTestContainer(name: "flagOffJournalPaths")
        let store = JournalStore(
            client: SeedkeepClient(
                configuration: .init(baseURL: URL(string: "https://test.local")!, session: session),
                bearerToken: "test"
            ),
            container: container
        )
        var localSignals = 0
        store.onLocalHouseholdMutation = { localSignals += 1 }

        let localEntry = try await store.create(
            occurredOn: "2025-07-15",
            body: "Server entry",
            householdID: "ignored-active-garden"
        )
        try await store.update(
            localEntry,
            occurredOn: "2025-07-15",
            body: "Updated",
            seedID: nil,
            bedID: nil,
            plantingEventID: nil,
            householdID: "ignored-active-garden"
        )
        let localItem = try await store.addChecklistItem(entryID: localEntry.id, text: "Water")
        try await store.updateChecklistItem(localItem, completed: true)
        let retrospective = try await store.retrospective(on: "07-15", householdID: "ignored-active-garden")
        try await store.deleteChecklistItem(localItem)
        try await store.softDelete(localEntry)

        #expect(retrospective.years.first?.entries.first?.body == "Updated")
        #expect(localSignals == 0)
        #expect(CatalogRouterMockURLProtocol.capturedPaths() == [
            "/api/journal",
            "/api/journal/entry-1",
            "/api/journal/entry-1/checklist",
            "/api/journal/checklist/item-1",
            "/api/journal/retrospective",
            "/api/journal/checklist/item-1",
            "/api/journal/entry-1"
        ])
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

    private static func expectPhotoBlocked(
        _ operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            Issue.record("CloudKit-gated photo operation unexpectedly succeeded")
        } catch let error as SeedkeepError {
            #expect(error.code == "cloudkit_feature_unavailable")
            #expect(error.message == FeatureFlags.cloudKitPhotoCapabilityMessage)
        } catch {
            Issue.record("Unexpected photo gate error: \(error)")
        }
    }

    private static func expectInactiveGarden(
        _ operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            Issue.record("Parked-household journal mutation unexpectedly succeeded")
        } catch let error as SeedkeepError {
            #expect(error.code == "inactive_garden_entry")
        } catch {
            Issue.record("Unexpected active-garden error: \(error)")
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
