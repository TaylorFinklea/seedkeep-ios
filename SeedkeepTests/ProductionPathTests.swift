import Foundation
import SwiftData
import Testing
@testable import Seedkeep
import SeedkeepKit
import SeedkeepCloudKit
import CloudKit

/// N3 T2: the production write path, always compiled. It replaces the compile-guarded
/// production-default gate suite: CloudKit is the only sync path, so there is no flag or test lane
/// to select it. Every `SyncEngine` write entry point persists its local values in one save,
/// signals the CloudKit save hook exactly once, creates no `LocalPendingWrite` row and leaves the
/// rows older builds queued unchanged. `PreN3StoreCompatibilityTests` runs the same entry points
/// on a disk-backed pre-N3 store; this suite covers a fresh store, each call's signal on its own,
/// every explicit clear, and the environment wiring that turns a signal into a CloudKit push (on a
/// fake engine: no CloudKit, no network).
@MainActor
@Suite("Production CloudKit write path", .serialized)
struct ProductionPathTests {

    // MARK: - Fixtures

    private static let householdID = "hh-production-path"

    /// Two server writes an older build queued, one of them dead-lettered.
    private static func insertLegacyPendingWrites(_ container: ModelContainer) throws {
        let context = ModelContext(container)
        context.insert(LocalPendingWrite(
            id: "pw_legacy_create", entityType: "seed", entityID: "seed_legacy", operation: "create",
            payloadJSON: #"{"state":"active","packet_count":1,"source":"store"}"#, createdAt: 100))
        context.insert(LocalPendingWrite(
            id: "pw_legacy_dead", entityType: "tag", entityID: "tag_legacy", operation: "update",
            payloadJSON: #"{"color":null}"#, createdAt: 200, attemptCount: 6, lastError: "offline",
            nextAttemptAt: 900, isDeadLettered: true))
        try context.save()
    }

    /// Every field of every `LocalPendingWrite` row, so "unchanged" means byte-for-byte.
    private static func pendingWriteSnapshot(_ container: ModelContainer) throws -> [String] {
        try ModelContext(container).fetch(FetchDescriptor<LocalPendingWrite>()).map {
            [$0.id, $0.entityType, $0.entityID, $0.operation, $0.payloadJSON, "\($0.createdAt)",
             "\($0.attemptCount)", $0.lastError ?? "nil", "\($0.nextAttemptAt)", "\($0.isDeadLettered)"]
                .joined(separator: "|")
        }.sorted()
    }

    private static func one<T: PersistentModel>(
        _ container: ModelContainer, _ type: T.Type, _ predicate: Predicate<T>
    ) throws -> T {
        try #require(try ModelContext(container).fetch(FetchDescriptor<T>(predicate: predicate)).first)
    }

    /// Runs `write` and checks it signalled the CloudKit save hook exactly once.
    @discardableResult
    private static func once<T>(
        _ signals: () -> Int, _ label: String,
        sourceLocation: SourceLocation = #_sourceLocation,
        _ write: () throws -> T
    ) throws -> T {
        let before = signals()
        let result = try write()
        #expect(signals() == before + 1, "\(label) signals exactly once", sourceLocation: sourceLocation)
        return result
    }

    // MARK: - SyncEngine entry points

    @Test("every enqueue create, update and delete persists locally and signals exactly once, with no new pending write")
    func everyEnqueueOnTheProductionPath() throws {
        let container = makeTestContainer(name: "productionPath-\(UUID().uuidString)")
        try Self.insertLegacyPendingWrites(container)
        let legacyQueue = try Self.pendingWriteSnapshot(container)
        let engine = SyncEngine(container: container)
        var count = 0
        engine.onLocalHouseholdMutation = { count += 1 }
        let signals = { count }
        let h = Self.householdID

        // Creates, with every field the input carries.
        let location = try Self.once(signals, "location create") {
            try engine.enqueueCreateLocation(name: "Shed", sortOrder: 3, householdID: h)
        }
        let tag = try Self.once(signals, "tag create") {
            try engine.enqueueCreateTag(name: "Heirloom", color: "#aa0000", householdID: h)
        }
        let seed = try Self.once(signals, "seed create") {
            try engine.enqueueCreateSeed(.init(
                state: .saved, packet_count: 4, location_id: location.id, year_packed: 2025,
                source: .gift, custom_name: "Brandywine", custom_variety: "Pink",
                custom_company: "Baker Creek", notes: "From Ann", tag_ids: [tag.id]), householdID: h)
        }
        let bed = try Self.once(signals, "bed create") {
            try engine.enqueueCreateBed(.init(
                name: "North", description: "Raised", width_feet: 4, length_feet: 8, sort_order: 2),
                householdID: h)
        }
        let event = try Self.once(signals, "planting create") {
            try engine.enqueueCreatePlantingEvent(.init(
                bed_id: bed.id, seed_id: seed.id, catalog_seed_id: "cat_1", kind: .sowing,
                planned_for: "2026-05-01", completed_at: 1_700, notes: "Row 1", x_feet: 1.5, y_feet: 2.5),
                householdID: h)
        }

        let locationID = location.id, tagID = tag.id, seedID = seed.id, bedID = bed.id, eventID = event.id
        let storedLocation = try Self.one(container, LocalLocation.self, #Predicate { $0.id == locationID })
        #expect(storedLocation.name == "Shed" && storedLocation.sortOrder == 3 && storedLocation.householdID == h)
        let storedTag = try Self.one(container, LocalTag.self, #Predicate { $0.id == tagID })
        #expect(storedTag.name == "Heirloom" && storedTag.color == "#aa0000" && storedTag.householdID == h)
        var storedSeed = try Self.one(container, LocalSeed.self, #Predicate { $0.id == seedID })
        #expect(storedSeed.state == .saved && storedSeed.packetCount == 4 && storedSeed.source == .gift)
        #expect(storedSeed.locationID == location.id && storedSeed.yearPacked == 2025)
        #expect(storedSeed.customName == "Brandywine" && storedSeed.customVariety == "Pink")
        #expect(storedSeed.customCompany == "Baker Creek" && storedSeed.notes == "From Ann")
        #expect(storedSeed.tagIDs == [tag.id] && storedSeed.householdID == h && storedSeed.deletedAt == nil)
        let storedBed = try Self.one(container, LocalBed.self, #Predicate { $0.id == bedID })
        #expect(storedBed.name == "North" && storedBed.bedDescription == "Raised")
        #expect(storedBed.widthFeet == 4 && storedBed.lengthFeet == 8 && storedBed.sortOrder == 2)
        var storedEvent = try Self.one(container, LocalPlantingEvent.self, #Predicate { $0.id == eventID })
        #expect(storedEvent.bedID == bed.id && storedEvent.seedID == seed.id && storedEvent.catalogSeedID == "cat_1")
        #expect(storedEvent.kindRaw == "sowing" && storedEvent.plannedFor == "2026-05-01")
        #expect(storedEvent.completedAt == 1_700 && storedEvent.notes == "Row 1")
        #expect(storedEvent.xFeet == 1.5 && storedEvent.yFeet == 2.5)

        // Updates that set values.
        try Self.once(signals, "location update") {
            try engine.enqueueUpdateLocation(id: location.id, name: "Barn", sortOrder: 5)
        }
        try Self.once(signals, "tag update") {
            try engine.enqueueUpdateTag(id: tag.id, name: "Saved", color: .some("#00aa00"))
        }
        try Self.once(signals, "seed update") {
            try engine.enqueueUpdateSeed(id: seed.id, .init(state: .active, packet_count: 2, source: .swap))
        }
        try Self.once(signals, "bed update") {
            try engine.enqueueUpdateBed(id: bed.id, .init(name: "South", width_feet: 3, sort_order: 1))
        }
        try Self.once(signals, "planting update") {
            try engine.enqueueUpdatePlantingEvent(id: event.id, .init(kind: .transplant, planned_for: "2026-05-09", notes: "Moved"))
        }
        try Self.once(signals, "growing info update") {
            try engine.setLocalGrowingInfo(seedID: seed.id, snapshot: GrowingInfoSnapshot(scientific_name: "Solanum lycopersicum"))
        }
        try Self.once(signals, "custom type update") {
            try engine.setLocalCustomType(seedID: seed.id, type: " Tomato ")
        }

        let updatedLocation = try Self.one(container, LocalLocation.self, #Predicate { $0.id == locationID })
        #expect(updatedLocation.name == "Barn" && updatedLocation.sortOrder == 5)
        let updatedTag = try Self.one(container, LocalTag.self, #Predicate { $0.id == tagID })
        #expect(updatedTag.name == "Saved" && updatedTag.color == "#00aa00")
        storedSeed = try Self.one(container, LocalSeed.self, #Predicate { $0.id == seedID })
        #expect(storedSeed.state == .active && storedSeed.packetCount == 2 && storedSeed.source == .swap)
        #expect(storedSeed.customName == "Brandywine" && storedSeed.notes == "From Ann", "omitted fields are untouched")
        #expect(storedSeed.growingInfo?.scientific_name == "Solanum lycopersicum" && storedSeed.customType == "Tomato")
        let updatedBed = try Self.one(container, LocalBed.self, #Predicate { $0.id == bedID })
        #expect(updatedBed.name == "South" && updatedBed.widthFeet == 3 && updatedBed.sortOrder == 1)
        #expect(updatedBed.lengthFeet == 8 && updatedBed.bedDescription == "Raised", "omitted fields are untouched")
        storedEvent = try Self.one(container, LocalPlantingEvent.self, #Predicate { $0.id == eventID })
        #expect(storedEvent.kindRaw == "transplant" && storedEvent.plannedFor == "2026-05-09" && storedEvent.notes == "Moved")
        #expect(storedEvent.completedAt == 1_700 && storedEvent.xFeet == 1.5, "omitted fields are untouched")

        // Explicit clears: `.some(nil)` writes nil through; a blank custom type and a nil snapshot clear.
        try Self.once(signals, "tag color clear") {
            try engine.enqueueUpdateTag(id: tag.id, name: nil, color: .some(nil))
        }
        try Self.once(signals, "seed clears") {
            try engine.enqueueUpdateSeed(id: seed.id, .init(
                location_id: .some(nil), year_packed: .some(nil), custom_name: .some(nil),
                custom_variety: .some(nil), custom_company: .some(nil), notes: .some(nil)))
        }
        try Self.once(signals, "planting completion clear") {
            try engine.enqueueUpdatePlantingEvent(id: event.id, .init(completed_at: .some(nil)))
        }
        try Self.once(signals, "growing info clear") {
            try engine.setLocalGrowingInfo(seedID: seed.id, snapshot: nil)
        }
        try Self.once(signals, "custom type clear") {
            try engine.setLocalCustomType(seedID: seed.id, type: "   ")
        }

        let clearedTag = try Self.one(container, LocalTag.self, #Predicate { $0.id == tagID })
        #expect(clearedTag.color == nil && clearedTag.name == "Saved")
        storedSeed = try Self.one(container, LocalSeed.self, #Predicate { $0.id == seedID })
        #expect(storedSeed.locationID == nil && storedSeed.yearPacked == nil && storedSeed.customName == nil)
        #expect(storedSeed.customVariety == nil && storedSeed.customCompany == nil && storedSeed.notes == nil)
        #expect(storedSeed.growingInfo == nil && storedSeed.customType == nil)
        #expect(storedSeed.tagIDs == [tag.id] && storedSeed.state == .active, "fields outside the clears are untouched")
        storedEvent = try Self.one(container, LocalPlantingEvent.self, #Predicate { $0.id == eventID })
        #expect(storedEvent.completedAt == nil && storedEvent.notes == "Moved")

        // Deletes are tombstones: the row stays with `deletedAt` set, for the CloudKit push.
        try Self.once(signals, "planting delete") { try engine.enqueueDeletePlantingEvent(id: event.id) }
        try Self.once(signals, "bed delete") { try engine.enqueueDeleteBed(id: bed.id) }
        try Self.once(signals, "seed delete") { try engine.enqueueDeleteSeed(id: seed.id) }
        try Self.once(signals, "tag delete") { try engine.enqueueDeleteTag(id: tag.id) }
        try Self.once(signals, "location delete") { try engine.enqueueDeleteLocation(id: location.id) }

        #expect(try Self.one(container, LocalPlantingEvent.self, #Predicate { $0.id == eventID }).deletedAt != nil)
        #expect(try Self.one(container, LocalBed.self, #Predicate { $0.id == bedID }).deletedAt != nil)
        #expect(try Self.one(container, LocalSeed.self, #Predicate { $0.id == seedID }).deletedAt != nil)
        #expect(try Self.one(container, LocalTag.self, #Predicate { $0.id == tagID }).deletedAt != nil)
        #expect(try Self.one(container, LocalLocation.self, #Predicate { $0.id == locationID }).deletedAt != nil)

        #expect(count == 22, "22 writes, 22 signals")
        #expect(try Self.pendingWriteSnapshot(container) == legacyQueue,
                "no LocalPendingWrite is created, and the legacy rows are unchanged")
        #expect(try ModelContext(container).fetch(FetchDescriptor<LocalCloudKitDeletion>()).isEmpty,
                "a tombstoned row needs no hard-delete intent")
    }

    // MARK: - Hard deletes need a CloudKit scope

    /// The seed-photo delete's only guard is now its scope guard (the flag guard is gone). Hard
    /// deletes (seed photo, journal photo, checklist item) need the active CloudKit scope to record
    /// their deletion intent; without one they throw and change nothing. Checklist add and update are
    /// row edits the next push carries, so they need no scope, as on a live device.
    @Test("without a CloudKit scope, hard deletes throw and change nothing; checklist add and update still work")
    func hardDeletesNeedACloudKitScope() async throws {
        let householdID = "scope-guard-\(UUID().uuidString)"
        defer { try? PhotoByteStore.purgeHousehold(householdID) }
        let container = makeTestContainer(name: "productionPathScope-\(UUID().uuidString)")
        let setup = ModelContext(container)
        setup.insert(LocalSeed(id: "seed-scope", householdID: householdID, state: .active,
                               packetCount: 1, source: .store, createdAt: 1, updatedAt: 2))
        setup.insert(LocalSeedPhoto(id: "seed-photo-scope", seedID: "seed-scope", householdID: householdID,
                                    r2Key: nil, role: .front, byteSize: 5, capturedAt: 3))
        try setup.save()
        let engine = SyncEngine(container: container)
        let journal = JournalStore(container: container)
        var signals = 0
        engine.onLocalHouseholdMutation = { signals += 1 }
        journal.onLocalHouseholdMutation = { signals += 1 }
        // As before sign-in resolves: the live provider returns nil without a signed-in garden.
        engine.cloudKitScopeIDProvider = { nil }
        journal.cloudKitScopeIDProvider = { nil }

        await Self.expectMissingScope { try await engine.deleteSeedPhoto("seed-photo-scope", householdID: householdID) }
        await Self.expectMissingScope { try await engine.deleteJournalPhoto("journal-photo-any", householdID: householdID) }

        let entry = try await journal.create(occurredOn: "2026-07-15", body: "Scope", householdID: householdID)
        let item = try await journal.addChecklistItem(entryID: entry.id, text: "Water", householdID: householdID)
        try await journal.updateChecklistItem(item, completed: true, householdID: householdID)
        let signalsBeforeDelete = signals
        await Self.expectMissingScope { try await journal.deleteChecklistItem(item, householdID: householdID) }

        let c = ModelContext(container)
        #expect(try c.fetchCount(FetchDescriptor<LocalSeedPhoto>()) == 1, "the photo stays")
        let itemID = item.id
        let stored = try #require(try c.fetch(FetchDescriptor<LocalJournalChecklistItem>(
            predicate: #Predicate { $0.id == itemID })).first)
        #expect(stored.completed, "the checklist item stays, with its update")
        #expect(try c.fetchCount(FetchDescriptor<LocalCloudKitDeletion>()) == 0, "no deletion intent")
        #expect(signals == signalsBeforeDelete, "a refused delete signals nothing")
        #expect(try c.fetchCount(FetchDescriptor<LocalPendingWrite>()) == 0)

        // With the scope, the same checklist delete records its intent and signals once.
        let scopeID = HouseholdCloudCoordinator.ownerScopeID(householdID: householdID)
        journal.cloudKitScopeIDProvider = { scopeID }
        try await journal.deleteChecklistItem(item, householdID: householdID)
        #expect(signals == signalsBeforeDelete + 1)
        let intent = try #require(try ModelContext(container).fetch(FetchDescriptor<LocalCloudKitDeletion>()).first)
        #expect(intent.scopeID == scopeID && intent.recordName == SeedkeepRecordNames.journalChecklistItem(itemID))
    }

    private static func expectMissingScope(
        sourceLocation: SourceLocation = #_sourceLocation,
        _ body: () async throws -> Void
    ) async {
        do {
            try await body()
            Issue.record("expected missing_cloudkit_scope", sourceLocation: sourceLocation)
        } catch let error as SeedkeepError {
            #expect(error.code == "missing_cloudkit_scope", sourceLocation: sourceLocation)
        } catch {
            Issue.record("unexpected error \(error)", sourceLocation: sourceLocation)
        }
    }

    // MARK: - The environment wiring, on a fake CloudKit engine

    private struct Environment {
        let env: AppEnvironment
        let coordinators: FakeCloudCoordinators
        let container: ModelContainer
        let householdID: String
        let cleanup: () -> Void
    }

    /// A verified iCloud identity with a cached garden, so `canUseCloudKit` is true once the
    /// session is restored. Every coordinator is a `FakeCloudCoordinators` one.
    private static func makeEnvironment(participantZone: CKRecordZone.ID? = nil) async throws -> Environment {
        let suite = "ProductionPathTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProductionPathTests-\(UUID().uuidString)", isDirectory: true)
        let syncDirectory = root.appendingPathComponent("HouseholdSync", isDirectory: true)
        try FileManager.default.createDirectory(at: syncDirectory, withIntermediateDirectories: true)
        let householdID = "hh-\(UUID().uuidString)"
        let json = """
        {"user":{"id":"_userA","name":null,"email":null},"household":{"id":"\(householdID)","name":"Garden","created_at":1,"updated_at":1}}
        """
        defaults.set(Data(json.utf8), forKey: AuthController.identityCacheKey)
        if let participantZone {
            ActiveGardenContext.recordParticipant(
                zoneName: participantZone.zoneName, ownerName: participantZone.ownerName, in: defaults)
        }
        let container = makeTestContainer(name: "productionPathEnv-\(UUID().uuidString)")
        try Self.insertLegacyPendingWrites(container)
        let coordinators = FakeCloudCoordinators()
        let env = AppEnvironment.makeForTesting(
            identity: FakeCloudIdentityProvider(recordName: "_userA"),
            tokenStore: InMemoryTokenStore(), defaults: defaults,
            container: container, durableStateDirectory: syncDirectory,
            cloudCoordinators: coordinators.factory)
        await env.auth.restoreSession()
        return Environment(env: env, coordinators: coordinators, container: container,
                           householdID: householdID, cleanup: {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: env.scanStagingRoot)
            // Each coordinator's one-time migration marker lives in the standard defaults, keyed by
            // its own household (a participant's is the owner's, not the signed-in one).
            let households = Set(coordinators.built.map(\.householdID) + [householdID])
            for key in UserDefaults.standard.dictionaryRepresentation().keys
            where key.hasPrefix(HouseholdCloudCoordinator.migratedKeyPrefix)
                && households.contains(where: { key.hasSuffix($0) }) {
                UserDefaults.standard.removeObject(forKey: key)
            }
        })
    }

    @Test("a local write on a verified identity builds the owner coordinator and Sync now pushes it, with no pending write")
    func localWriteReachesTheCloudKitCoordinator() async throws {
        let e = try await Self.makeEnvironment()
        defer { e.cleanup() }
        let legacyQueue = try Self.pendingWriteSnapshot(e.container)
        #expect(e.env.canUseCloudKit)
        #expect(e.env.activeGardenHouseholdID == e.householdID)
        #expect(e.coordinators.built.isEmpty)

        let seed = try e.env.sync.enqueueCreateSeed(.init(state: .active, custom_name: "Sungold"),
                                                     householdID: e.householdID)

        // The mutation signal reached `noteHouseholdMutation`, which built (and scheduled a save on)
        // exactly one owner coordinator for the signed-in garden.
        #expect(e.coordinators.built.count == 1)
        let built = try #require(e.coordinators.built.first)
        #expect(!built.isParticipant && built.householdID == e.householdID)
        #expect(e.env.hasCloudCoordinator)

        await e.env.syncIfPossible()

        #expect(e.coordinators.built.count == 1, "the sync reuses the coordinator")
        #expect(e.env.cloudKit === built.coordinator)
        #expect(built.coordinator.lastPassCompleted)
        #expect(built.coordinator.lastHumanizedError == nil)
        #expect(e.env.bannerError == nil)
        #expect(built.engine.savedRecords.map(\.recordID.recordName).contains(SeedkeepRecordNames.seed(seed.id)),
                "the pass pushed the new seed to the (fake) CloudKit engine")
        #expect(try Self.pendingWriteSnapshot(e.container) == legacyQueue)
        #expect(!e.env.isCloudSyncRunning)
    }

    @Test("a participant marker scopes writes to the owner's garden and syncs through a participant coordinator")
    func participantMarkerSelectsTheSharedGarden() async throws {
        let ownerHousehold = "hh-owner-\(UUID().uuidString)"
        let zone = CKRecordZone.ID(zoneName: SeedkeepZoneProvisioner.zoneName(householdID: ownerHousehold),
                                   ownerName: "_owner")
        let e = try await Self.makeEnvironment(participantZone: zone)
        defer { e.cleanup() }
        #expect(e.env.isViewingSharedHousehold)
        #expect(e.env.activeGardenHouseholdID == ownerHousehold, "the shared garden is active")

        _ = try e.env.sync.enqueueCreateLocation(name: "Shared shed", householdID: ownerHousehold)

        let built = try #require(e.coordinators.built.first)
        #expect(e.coordinators.built.count == 1)
        #expect(built.isParticipant && built.householdID == ownerHousehold)
    }
}
