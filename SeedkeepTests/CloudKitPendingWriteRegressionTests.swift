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

    @Test("growing-info edits advance the merge clock and schedule a CloudKit save")
    func growingInfoEditSignalsCloudKitMutation() throws {
        let seedID = "seed-growing-info"
        let originalUpdatedAt: Int64 = 9_000_000_000_000
        let (container, engine) = try Self.makeSeedMutationFixture(
            name: "growingInfoMutationSignal",
            seedID: seedID,
            updatedAt: originalUpdatedAt
        )
        var signalCount = 0
        engine.onLocalHouseholdMutation = { signalCount += 1 }
        let snapshot = GrowingInfoSnapshot(scientific_name: "Capsicum annuum")

        try engine.setLocalGrowingInfo(seedID: seedID, snapshot: snapshot)

        let context = ModelContext(container)
        let stored = try #require(
            context.fetch(FetchDescriptor<LocalSeed>(predicate: #Predicate { $0.id == seedID })).first
        )
        #expect(stored.growingInfo == snapshot)
        #expect(stored.updatedAt == originalUpdatedAt + 1)
        #expect(signalCount == 1)
    }

    @Test("custom-type edits advance the merge clock and schedule a CloudKit save")
    func customTypeEditSignalsCloudKitMutation() throws {
        let seedID = "seed-custom-type"
        let originalUpdatedAt: Int64 = 9_000_000_000_000
        let (container, engine) = try Self.makeSeedMutationFixture(
            name: "customTypeMutationSignal",
            seedID: seedID,
            updatedAt: originalUpdatedAt
        )
        var signalCount = 0
        engine.onLocalHouseholdMutation = { signalCount += 1 }

        try engine.setLocalCustomType(seedID: seedID, type: "  Pepper  ")

        let context = ModelContext(container)
        let stored = try #require(
            context.fetch(FetchDescriptor<LocalSeed>(predicate: #Predicate { $0.id == seedID })).first
        )
        #expect(stored.customType == "Pepper")
        #expect(stored.updatedAt == originalUpdatedAt + 1)
        #expect(signalCount == 1)
    }

    @Test("missing-seed edits do not schedule a CloudKit save")
    func missingSeedEditsDoNotSignalCloudKitMutation() throws {
        let (_, engine) = try Self.makeSeedMutationFixture(
            name: "missingSeedMutationSignal",
            seedID: "unrelated-seed",
            updatedAt: 1
        )
        var signalCount = 0
        engine.onLocalHouseholdMutation = { signalCount += 1 }

        try engine.setLocalGrowingInfo(
            seedID: "missing-growing-info",
            snapshot: GrowingInfoSnapshot(scientific_name: "Capsicum annuum")
        )
        try engine.setLocalCustomType(seedID: "missing-custom-type", type: "Pepper")

        #expect(signalCount == 0)
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
        #expect(coordinator.keyCheckError == AIAssistantCoordinator.capabilityUnavailableMessage)
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

    @Test("CloudKit seed-photo upload stages bytes and persists locally before one save signal")
    func cloudKitSeedPhotoUploadStagesLocalMutation() async throws {
        let previous = UserDefaults.standard.object(forKey: FeatureFlags.cloudKitHouseholdSyncKey)
        defer { Self.restoreCloudKitFlag(previous) }
        FeatureFlags.setCloudKitHouseholdSync(true)

        let householdID = "photo-upload-\(UUID().uuidString)"
        defer { try? PhotoByteStore.purgeHousehold(householdID) }
        let session = CatalogRouterMockURLProtocol.makeSession(
            fallbackBody: Data(),
            fallbackStatus: 500
        )
        let container = makeTestContainer(name: "cloudKitSeedPhotoUpload")
        let context = ModelContext(container)
        context.insert(LocalSeed(
            id: "seed-photo-parent",
            householdID: householdID,
            state: .active,
            packetCount: 1,
            source: .store,
            createdAt: 1,
            updatedAt: 2
        ))
        try context.save()
        let engine = SyncEngine(
            client: SeedkeepClient(
                configuration: .init(baseURL: URL(string: "https://test.local")!, session: session),
                bearerToken: "test"
            ),
            container: container
        )
        var saveSignals = 0
        engine.onLocalHouseholdMutation = { saveSignals += 1 }
        let bytes = Data("cloudkit-seed-photo".utf8)

        try await engine.uploadPhoto(
            seedID: "seed-photo-parent",
            role: .front,
            jpegData: bytes,
            householdID: householdID
        )

        let stored = try #require(
            ModelContext(container).fetch(FetchDescriptor<LocalSeedPhoto>()).first
        )
        let recordName = SeedkeepRecordNames.seedPhoto(stored.id)
        #expect(stored.seedID == "seed-photo-parent")
        #expect(stored.householdID == householdID)
        #expect(stored.role == .front)
        #expect(stored.byteSize == bytes.count)
        #expect(stored.capturedAt > 0)
        #expect(PhotoByteStore(lifetime: .pendingUploads, householdID: householdID)
            .data(for: recordName) == bytes)
        #expect(saveSignals == 1)
        #expect(CatalogRouterMockURLProtocol.capturedPaths().isEmpty)
    }

    @Test("CloudKit journal-photo upload stages bytes and persists locally before one save signal")
    func cloudKitJournalPhotoUploadStagesLocalMutation() async throws {
        let previous = UserDefaults.standard.object(forKey: FeatureFlags.cloudKitHouseholdSyncKey)
        defer { Self.restoreCloudKitFlag(previous) }
        FeatureFlags.setCloudKitHouseholdSync(true)

        let householdID = "journal-photo-upload-\(UUID().uuidString)"
        defer { try? PhotoByteStore.purgeHousehold(householdID) }
        let session = CatalogRouterMockURLProtocol.makeSession(
            fallbackBody: Data(),
            fallbackStatus: 500
        )
        let container = makeTestContainer(name: "cloudKitJournalPhotoUpload")
        let context = ModelContext(container)
        context.insert(LocalJournalEntry(
            id: "journal-photo-parent",
            householdID: householdID,
            occurredOn: "2026-08-20",
            body: "Photo entry",
            seedID: nil,
            bedID: nil,
            plantingEventID: nil,
            createdAt: 1,
            updatedAt: 2,
            deletedAt: nil
        ))
        try context.save()
        let engine = SyncEngine(
            client: SeedkeepClient(
                configuration: .init(baseURL: URL(string: "https://test.local")!, session: session),
                bearerToken: "test"
            ),
            container: container
        )
        var saveSignals = 0
        engine.onLocalHouseholdMutation = { saveSignals += 1 }
        let bytes = Data("cloudkit-journal-photo".utf8)

        _ = try await engine.uploadJournalPhoto(
            entryId: "journal-photo-parent",
            jpegData: bytes,
            width: 640,
            height: 480,
            householdID: householdID
        )

        let stored = try #require(
            ModelContext(container).fetch(FetchDescriptor<LocalJournalEntryPhoto>()).first
        )
        let recordName = SeedkeepRecordNames.journalEntryPhoto(stored.id)
        #expect(stored.entryID == "journal-photo-parent")
        #expect(stored.sortOrder == 0)
        #expect(stored.width == 640)
        #expect(stored.height == 480)
        #expect(stored.createdAt > 0)
        #expect(stored.updatedAt == stored.createdAt)
        #expect(PhotoByteStore(lifetime: .pendingUploads, householdID: householdID)
            .data(for: recordName) == bytes)
        #expect(saveSignals == 1)
        #expect(CatalogRouterMockURLProtocol.capturedPaths().isEmpty)
    }

    @Test("CloudKit journal-photo upload rejects a parked entry before staging bytes")
    func cloudKitJournalPhotoUploadRejectsParkedEntry() async throws {
        let previous = UserDefaults.standard.object(forKey: FeatureFlags.cloudKitHouseholdSyncKey)
        defer { Self.restoreCloudKitFlag(previous) }
        FeatureFlags.setCloudKitHouseholdSync(true)

        let parkedHouseholdID = "parked-photo-\(UUID().uuidString)"
        let activeHouseholdID = "active-photo-\(UUID().uuidString)"
        defer {
            try? PhotoByteStore.purgeHousehold(parkedHouseholdID)
            try? PhotoByteStore.purgeHousehold(activeHouseholdID)
        }
        let session = CatalogRouterMockURLProtocol.makeSession(
            fallbackBody: Data(),
            fallbackStatus: 500
        )
        let container = makeTestContainer(name: "cloudKitJournalPhotoParkedEntry")
        let context = ModelContext(container)
        context.insert(LocalJournalEntry(
            id: "parked-photo-entry", householdID: parkedHouseholdID,
            occurredOn: "2026-08-20", body: "Parked",
            seedID: nil, bedID: nil, plantingEventID: nil,
            createdAt: 1, updatedAt: 2, deletedAt: nil))
        try context.save()
        let engine = SyncEngine(
            client: SeedkeepClient(
                configuration: .init(baseURL: URL(string: "https://test.local")!, session: session),
                bearerToken: "test"
            ),
            container: container
        )
        var saveSignals = 0
        engine.onLocalHouseholdMutation = { saveSignals += 1 }

        do {
            _ = try await engine.uploadJournalPhoto(
                entryId: "parked-photo-entry",
                jpegData: Data("photo".utf8),
                householdID: activeHouseholdID
            )
            Issue.record("Parked journal entry unexpectedly accepted a photo")
        } catch let error as SeedkeepError {
            #expect(error.code == "inactive_garden_entry")
        }

        #expect(try ModelContext(container)
            .fetch(FetchDescriptor<LocalJournalEntryPhoto>()).isEmpty)
        #expect(saveSignals == 0)
        #expect(CatalogRouterMockURLProtocol.capturedPaths().isEmpty)
    }

    @Test("CloudKit seed-photo delete queues one scoped intent and purges local bytes")
    func cloudKitSeedPhotoDeleteQueuesIntentAndPurgesBytes() async throws {
        let previous = UserDefaults.standard.object(forKey: FeatureFlags.cloudKitHouseholdSyncKey)
        defer { Self.restoreCloudKitFlag(previous) }
        FeatureFlags.setCloudKitHouseholdSync(true)

        let householdID = "seed-photo-delete-\(UUID().uuidString)"
        defer { try? PhotoByteStore.purgeHousehold(householdID) }
        let scopeID = HouseholdCloudCoordinator.ownerScopeID(householdID: householdID)
        let session = CatalogRouterMockURLProtocol.makeSession(
            fallbackBody: Data(),
            fallbackStatus: 500
        )
        let container = makeTestContainer(name: "cloudKitSeedPhotoDelete")
        let context = ModelContext(container)
        context.insert(LocalSeed(
            id: "seed-delete-parent", householdID: householdID, state: .active,
            packetCount: 1, source: .store, createdAt: 1, updatedAt: 2))
        let photo = LocalSeedPhoto(
            id: "seed-photo-delete", seedID: "seed-delete-parent", householdID: householdID,
            r2Key: nil, role: .front, byteSize: 5, capturedAt: 3)
        context.insert(photo)
        try context.save()
        let recordName = SeedkeepRecordNames.seedPhoto(photo.id)
        let bytes = Data("photo".utf8)
        try PhotoByteStore(lifetime: .pendingUploads, householdID: householdID)
            .write(bytes, for: recordName)
        try PhotoByteStore(lifetime: .cache, householdID: householdID)
            .write(bytes, for: recordName)
        let engine = SyncEngine(
            client: SeedkeepClient(
                configuration: .init(baseURL: URL(string: "https://test.local")!, session: session),
                bearerToken: "test"
            ),
            container: container
        )
        engine.cloudKitScopeIDProvider = { scopeID }
        var saveSignals = 0
        engine.onLocalHouseholdMutation = { saveSignals += 1 }

        try await engine.deleteSeedPhoto(photo.id, householdID: householdID)

        let verification = ModelContext(container)
        #expect(try verification.fetch(FetchDescriptor<LocalSeedPhoto>()).isEmpty)
        let deletion = try #require(
            verification.fetch(FetchDescriptor<LocalCloudKitDeletion>()).first)
        #expect(deletion.id == "\(scopeID)|\(recordName)")
        #expect(deletion.scopeID == scopeID)
        #expect(deletion.householdID == householdID)
        #expect(deletion.recordName == recordName)
        #expect(!PhotoByteStore(lifetime: .pendingUploads, householdID: householdID)
            .contains(recordName))
        #expect(!PhotoByteStore(lifetime: .cache, householdID: householdID)
            .contains(recordName))
        #expect(saveSignals == 1)
        #expect(CatalogRouterMockURLProtocol.capturedPaths().isEmpty)
    }

    @Test("CloudKit journal-photo delete queues one scoped intent and purges local bytes")
    func cloudKitJournalPhotoDeleteQueuesIntentAndPurgesBytes() async throws {
        let previous = UserDefaults.standard.object(forKey: FeatureFlags.cloudKitHouseholdSyncKey)
        defer { Self.restoreCloudKitFlag(previous) }
        FeatureFlags.setCloudKitHouseholdSync(true)

        let householdID = "journal-photo-delete-\(UUID().uuidString)"
        defer { try? PhotoByteStore.purgeHousehold(householdID) }
        let scopeID = HouseholdCloudCoordinator.ownerScopeID(householdID: householdID)
        let session = CatalogRouterMockURLProtocol.makeSession(
            fallbackBody: Data(),
            fallbackStatus: 500
        )
        let container = makeTestContainer(name: "cloudKitJournalPhotoDelete")
        let context = ModelContext(container)
        context.insert(LocalJournalEntry(
            id: "journal-delete-parent", householdID: householdID,
            occurredOn: "2026-08-20", body: "Delete photo",
            seedID: nil, bedID: nil, plantingEventID: nil,
            createdAt: 1, updatedAt: 2, deletedAt: nil))
        let photo = LocalJournalEntryPhoto(
            id: "journal-photo-delete", entryID: "journal-delete-parent",
            storageKey: nil, sortOrder: 0, width: 10, height: 20,
            createdAt: 2, updatedAt: 2)
        context.insert(photo)
        try context.save()
        let recordName = SeedkeepRecordNames.journalEntryPhoto(photo.id)
        let bytes = Data("photo".utf8)
        try PhotoByteStore(lifetime: .pendingUploads, householdID: householdID)
            .write(bytes, for: recordName)
        try PhotoByteStore(lifetime: .cache, householdID: householdID)
            .write(bytes, for: recordName)
        let engine = SyncEngine(
            client: SeedkeepClient(
                configuration: .init(baseURL: URL(string: "https://test.local")!, session: session),
                bearerToken: "test"
            ),
            container: container
        )
        engine.cloudKitScopeIDProvider = { scopeID }
        var saveSignals = 0
        engine.onLocalHouseholdMutation = { saveSignals += 1 }

        try await engine.deleteJournalPhoto(photo.id, householdID: householdID)

        let verification = ModelContext(container)
        #expect(try verification.fetch(FetchDescriptor<LocalJournalEntryPhoto>()).isEmpty)
        let deletion = try #require(
            verification.fetch(FetchDescriptor<LocalCloudKitDeletion>()).first)
        #expect(deletion.id == "\(scopeID)|\(recordName)")
        #expect(deletion.householdID == householdID)
        #expect(deletion.recordName == recordName)
        #expect(!PhotoByteStore(lifetime: .pendingUploads, householdID: householdID)
            .contains(recordName))
        #expect(!PhotoByteStore(lifetime: .cache, householdID: householdID)
            .contains(recordName))
        #expect(saveSignals == 1)
        #expect(CatalogRouterMockURLProtocol.capturedPaths().isEmpty)
    }

    @Test("CloudKit seed-photo cache miss performs one on-demand sync retry without a mutation signal")
    func cloudKitSeedPhotoCacheMissRetriesWithoutMutationSignal() async throws {
        let previous = UserDefaults.standard.object(forKey: FeatureFlags.cloudKitHouseholdSyncKey)
        defer { Self.restoreCloudKitFlag(previous) }
        FeatureFlags.setCloudKitHouseholdSync(true)

        let householdID = "seed-photo-read-\(UUID().uuidString)"
        defer { try? PhotoByteStore.purgeHousehold(householdID) }
        let session = CatalogRouterMockURLProtocol.makeSession(
            fallbackBody: Data(),
            fallbackStatus: 500
        )
        let container = makeTestContainer(name: "cloudKitSeedPhotoCacheMiss")
        let context = ModelContext(container)
        let photo = LocalSeedPhoto(
            id: "seed-photo-read", seedID: "seed-parent", householdID: householdID,
            r2Key: nil, role: .front, byteSize: 5, capturedAt: 3)
        context.insert(photo)
        try context.save()
        let recordName = SeedkeepRecordNames.seedPhoto(photo.id)
        let expected = Data("photo".utf8)
        let engine = SyncEngine(
            client: SeedkeepClient(
                configuration: .init(baseURL: URL(string: "https://test.local")!, session: session),
                bearerToken: "test"
            ),
            container: container
        )
        var cacheMisses = 0
        engine.onCloudKitPhotoCacheMiss = { requestedRecordName in
            cacheMisses += 1
            #expect(requestedRecordName == recordName)
            return expected
        }
        var saveSignals = 0
        engine.onLocalHouseholdMutation = { saveSignals += 1 }

        let data = try await engine.fetchSeedPhotoData(
            photoID: photo.id,
            householdID: householdID
        )

        #expect(data == expected)
        #expect(cacheMisses == 1)
        #expect(saveSignals == 0)
        #expect(CatalogRouterMockURLProtocol.capturedPaths().isEmpty)
    }

    @Test("CloudKit journal-photo cache miss performs one on-demand sync retry without a mutation signal")
    func cloudKitJournalPhotoCacheMissRetriesWithoutMutationSignal() async throws {
        let previous = UserDefaults.standard.object(forKey: FeatureFlags.cloudKitHouseholdSyncKey)
        defer { Self.restoreCloudKitFlag(previous) }
        FeatureFlags.setCloudKitHouseholdSync(true)

        let householdID = "journal-photo-read-\(UUID().uuidString)"
        defer { try? PhotoByteStore.purgeHousehold(householdID) }
        let session = CatalogRouterMockURLProtocol.makeSession(
            fallbackBody: Data(),
            fallbackStatus: 500
        )
        let container = makeTestContainer(name: "cloudKitJournalPhotoCacheMiss")
        let context = ModelContext(container)
        context.insert(LocalJournalEntry(
            id: "journal-photo-read-parent", householdID: householdID,
            occurredOn: "2026-08-20", body: "Read photo",
            seedID: nil, bedID: nil, plantingEventID: nil,
            createdAt: 1, updatedAt: 2, deletedAt: nil))
        let photo = LocalJournalEntryPhoto(
            id: "journal-photo-read", entryID: "journal-photo-read-parent",
            storageKey: nil, sortOrder: 0, width: 10, height: 20,
            createdAt: 2, updatedAt: 2)
        context.insert(photo)
        try context.save()
        let recordName = SeedkeepRecordNames.journalEntryPhoto(photo.id)
        let expected = Data("photo".utf8)
        let engine = SyncEngine(
            client: SeedkeepClient(
                configuration: .init(baseURL: URL(string: "https://test.local")!, session: session),
                bearerToken: "test"
            ),
            container: container
        )
        var cacheMisses = 0
        engine.onCloudKitPhotoCacheMiss = { requestedRecordName in
            cacheMisses += 1
            #expect(requestedRecordName == recordName)
            return expected
        }
        var saveSignals = 0
        engine.onLocalHouseholdMutation = { saveSignals += 1 }

        let data = try await engine.journalPhotoData(
            photoId: photo.id,
            householdID: householdID
        )

        #expect(data == expected)
        #expect(cacheMisses == 1)
        #expect(saveSignals == 0)
        #expect(CatalogRouterMockURLProtocol.capturedPaths().isEmpty)
    }

    @Test("flag OFF seed-photo upload persists the returned row without a destructive refresh")
    func flagOffSeedPhotoUploadPersistsReturnedRowWithoutRefresh() async throws {
        let previous = UserDefaults.standard.object(forKey: FeatureFlags.cloudKitHouseholdSyncKey)
        defer { Self.restoreCloudKitFlag(previous) }
        FeatureFlags.setCloudKitHouseholdSync(false)

        let response = Data(#"{"ok":true,"data":{"photo":{"id":"legacy-photo-created","seed_id":"legacy-seed","household_id":"legacy-household","r2_key":"photos/legacy.jpg","role":"extra","width":640,"height":480,"byte_size":4,"captured_at":3}}}"#.utf8)
        let session = CatalogRouterMockURLProtocol.makeSession(
            routes: ["POST /api/seeds/legacy-seed/photos": response],
            fallbackBody: Data(),
            fallbackStatus: 200
        )
        let container = makeTestContainer(name: "flagOffSeedPhotoUpload")
        let engine = SyncEngine(
            client: SeedkeepClient(
                configuration: .init(baseURL: URL(string: "https://test.local")!, session: session),
                bearerToken: "test"
            ),
            container: container
        )

        try await engine.uploadPhoto(
            seedID: "legacy-seed",
            role: .extra,
            jpegData: Data("jpeg".utf8),
            householdID: "legacy-household"
        )

        let photo = try #require(
            ModelContext(container).fetch(FetchDescriptor<LocalSeedPhoto>()).first)
        #expect(photo.id == "legacy-photo-created")
        #expect(photo.seedID == "legacy-seed")
        #expect(photo.householdID == "legacy-household")
        #expect(photo.r2Key == "photos/legacy.jpg")
        #expect(CatalogRouterMockURLProtocol.capturedMethodPaths().count == 1)
        #expect(CatalogRouterMockURLProtocol.capturedMethodPaths().first?.method == "POST")
        #expect(CatalogRouterMockURLProtocol.capturedMethodPaths().first?.path == "/api/seeds/legacy-seed/photos")
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

        #expect(try await engine.fetchSeedPhotoData(photoID: "legacy-photo") == bytes)
        #expect(CatalogRouterMockURLProtocol.capturedPaths() == ["/api/photos/legacy-photo"])
    }

    @Test("photo operations resolve the active owner, participant, and rollback garden IDs")
    func photoOperationsResolveActiveGardenIDs() {
        let previous = UserDefaults.standard.object(forKey: FeatureFlags.cloudKitHouseholdSyncKey)
        defer { Self.restoreCloudKitFlag(previous) }
        let modes: [(household: String, zone: String?, cloudKit: Bool, activeID: String)] = [
            ("owner-household", nil, true, "owner-household"),
            ("participant-household", "seedkeep-owner-household", true, "owner-household"),
            ("participant-household", "seedkeep-owner-household", false, "participant-household")
        ]

        for mode in modes {
            FeatureFlags.setCloudKitHouseholdSync(mode.cloudKit)
            let activeHouseholdID = ActiveGardenContext.householdID(
                signedInHouseholdID: mode.household,
                participantZoneName: mode.zone,
                cloudKitSyncEnabled: mode.cloudKit
            )
            #expect(activeHouseholdID == mode.activeID)
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

    @Test("leap-day retrospectives span February and March while rejecting impossible dates")
    func cloudKitRetrospectiveHandlesLeapDay() async throws {
        let previous = UserDefaults.standard.object(forKey: FeatureFlags.cloudKitHouseholdSyncKey)
        defer { Self.restoreCloudKitFlag(previous) }
        FeatureFlags.setCloudKitHouseholdSync(true)

        let container = makeTestContainer(name: "cloudKitLeapDayRetrospective")
        let store = JournalStore(
            client: SeedkeepClient(
                configuration: .init(baseURL: URL(string: "https://test.local")!),
                bearerToken: "test"
            ),
            container: container
        )
        let householdID = "leap-day-garden"
        let entries = [
            ("2024-02-25", "Before window"),
            ("2024-02-26", "February boundary"),
            ("2024-02-29", "Leap day"),
            ("2024-03-03", "March boundary"),
            ("2024-03-04", "After window")
        ]
        for (occurredOn, body) in entries {
            _ = try await store.create(
                occurredOn: occurredOn,
                body: body,
                householdID: householdID
            )
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let currentYear = calendar.component(.year, from: Date())
        _ = try await store.create(
            occurredOn: "\(currentYear)-03-01",
            body: "Current year",
            householdID: householdID
        )

        let retrospective = try await store.retrospective(on: "02-29", householdID: householdID)

        #expect(retrospective.years.map(\.year) == [2024])
        #expect(retrospective.years.first?.entries.map(\.body) == [
            "March boundary", "Leap day", "February boundary"
        ])
        await #expect(throws: SeedkeepError.self) {
            try await store.retrospective(on: "02-30", householdID: householdID)
        }
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
            #expect(error.message == AIAssistantCoordinator.capabilityUnavailableMessage)
        } catch {
            Issue.record("Unexpected gate error: \(error)")
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

    private static func makeSeedMutationFixture(
        name: String,
        seedID: String,
        updatedAt: Int64
    ) throws -> (ModelContainer, SyncEngine) {
        let container = makeTestContainer(name: name)
        let context = ModelContext(container)
        context.insert(LocalSeed(
            id: seedID,
            householdID: "household-cloudkit",
            state: .active,
            packetCount: 1,
            source: .store,
            createdAt: 1,
            updatedAt: updatedAt
        ))
        try context.save()
        let client = SeedkeepClient(
            configuration: .init(baseURL: URL(string: "https://test.local")!),
            bearerToken: "test_token"
        )
        return (container, SyncEngine(client: client, container: container))
    }
}
