import CloudKit
import Foundation
import SwiftData
import Testing
@testable import Seedkeep
import SeedkeepCloudKit

@MainActor
final class JournalPausePoint {
    private var continuation: CheckedContinuation<Void, Never>?
    private var startWaiter: CheckedContinuation<Void, Never>?
    private(set) var started = false

    func pause() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            started = true
            startWaiter?.resume()
            startWaiter = nil
        }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { startWaiter = $0 }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

/// N2-E (G3) §7: the steps of a keep, a discard and the silent re-home. Every test runs on fakes: an
/// in-memory store, a temp guard file, temp directories. No CloudKit and no real notifications.
@MainActor
@Suite("Garden journals: steps, checkpoints, dispositions", .serialized)
struct GardenJournalTests {
    typealias Rig = JournalRig
    static let account = JournalRig.account

    private final class PhotoCopyPause: @unchecked Sendable {
        private let entered = DispatchSemaphore(value: 0)
        private let released = DispatchSemaphore(value: 0)

        func pause() {
            entered.signal()
            released.wait()
        }

        func waitUntilEntered() { entered.wait() }
        func resume() {
            // The photo fixture can write more than one available photo and lifetime.
            for _ in 0..<16 { released.signal() }
        }
    }

    /// A keep (or silent re-home) rig with the garden seeded and its journal fixed.
    private static func keepRig(
        _ action: GardenGoneRecord.Action = .keep, participant: Bool = false, photos: Bool = true
    ) throws -> Rig {
        let rig = Rig()
        try rig.seed()
        if photos { try rig.seedPhotoBytes() }
        try rig.seedDurableState()
        if action == .rehome { try rig.journalRehome() } else { try rig.chooseGone(action, participant: participant) }
        return rig
    }

    @Test("every photo enumeration failure stops before checkpoint/purge; retry copies every available photo",
          arguments: GardenPhotoRows.Fetch.allCases)
    func photoEnumerationFailureAndRetry(_ failedFetch: GardenPhotoRows.Fetch) async throws {
        let rig = try Self.keepRig()
        defer { rig.cleanUp() }
        let before = try rig.snapshot(rig.old)
        let executor = rig.makeExecutor()
        executor.deps.beforePhotoFetch = { fetch in
            if fetch == failedFetch { throw Rig.Crash() }
        }
        await #expect(throws: Rig.Crash.self) {
            try await executor.run(account: Self.account, householdID: rig.old)
        }
        #expect(rig.store.journal(Self.account, rig.old)?.steps == [])
        #expect(try rig.snapshot(rig.old) == before)
        #expect(GardenInventory.hasBytes(SeedkeepRecordNames.seedPhoto("seed_photo_local_ck"), household: rig.old))
        #expect(GardenInventory.hasBytes(SeedkeepRecordNames.journalEntryPhoto("journal_photo_local_ck"), household: rig.old))
        await #expect(throws: Rig.Crash.self) {
            try await GardenInventory.count(container: rig.container, householdID: rig.old,
                                            beforePhotoFetch: executor.deps.beforePhotoFetch)
        }
        executor.deps.beforePhotoFetch = { _ in }
        let inventory = try await GardenInventory.count(container: rig.container, householdID: rig.old)
        #expect(inventory.photos == 4 && inventory.photosNotOnDevice == 2)
        try await executor.run(account: Self.account, householdID: rig.old)
        #expect(rig.store.journal(Self.account, rig.old)?.phase == .done)
        #expect(executor.lastMissingPhotoCount == inventory.photosNotOnDevice)
        #expect(GardenInventory.hasBytes(SeedkeepRecordNames.seedPhoto("seed_photo_local_ck"), household: rig.new))
        #expect(GardenInventory.hasBytes(SeedkeepRecordNames.journalEntryPhoto("journal_photo_local_ck"), household: rig.new))
        #expect(!GardenInventory.hasBytes(SeedkeepRecordNames.seedPhoto("seed_photo_local_ck"), household: rig.old))
        #expect(try rig.snapshot(rig.new).seedPhotos == ["seed_photo_local_ck"])
        #expect(try rig.snapshot(rig.new).entryPhotos == ["journal_photo_local_ck"])
    }

    @Test("photo inventory and re-home include pending parked recovery photos and drop unavailable children atomically")
    func pendingRecoveryPhotosUseTheirParkedHousehold() async throws {
        let rig = try Self.keepRig()
        let parked = "hhr_parked-\(UUID().uuidString)"
        defer { rig.cleanUp(); try? PhotoByteStore.purgeHousehold(parked) }
        let scope = "\(rig.old)|\(rig.signedIn)"
        let pendingName = SeedkeepRecordNames.journalEntryPhoto("recovery-pending-photo")
        let cacheName = SeedkeepRecordNames.journalEntryPhoto("recovery-cache-photo")
        let missingName = SeedkeepRecordNames.journalEntryPhoto("recovery-missing-photo")
        let corruptName = SeedkeepRecordNames.journalEntryPhoto("recovery-corrupt-photo")
        let privateName = SeedkeepRecordNames.journalEntryPhoto("recovery-private-photo")
        let unrelatedName = SeedkeepRecordNames.journalEntryPhoto("recovery-unrelated-photo")
        let context = ModelContext(rig.container)
        for (id, deletedAt) in [("recovery-pending", Int64?(nil)), ("recovery-cache", nil),
                                ("recovery-missing", nil), ("recovery-corrupt", nil),
                                ("recovery-private", nil), ("recovery-unrelated", nil)] {
            let household = id == "recovery-unrelated" ? rig.other : parked
            context.insert(LocalJournalEntry(id: id, householdID: household, occurredOn: "2026-01-01", body: id,
                seedID: nil, bedID: nil, plantingEventID: nil, createdAt: 1, updatedAt: 2, deletedAt: deletedAt))
        }
        for (id, entryID) in [("recovery-pending-photo", "recovery-pending"), ("recovery-cache-photo", "recovery-cache"),
                              ("recovery-missing-photo", "recovery-missing"), ("recovery-corrupt-photo", "recovery-corrupt"),
                              ("recovery-private-photo", "recovery-private"), ("recovery-unrelated-photo", "recovery-unrelated")] {
            context.insert(LocalJournalEntryPhoto(id: id, entryID: entryID, storageKey: nil, sortOrder: 0,
                width: nil, height: nil, createdAt: 1, updatedAt: 1))
        }
        for id in ["recovery-pending", "recovery-cache", "recovery-missing", "recovery-corrupt", "recovery-unrelated"] {
            context.insert(LocalJournalRecoveryItem(id: id, scopeKey: id == "recovery-unrelated" ? "\(rig.other)|else" : scope,
                snapshotJSON: "{}", detectedAt: 1, status: "pending"))
        }
        context.insert(LocalJournalRecoveryItem(id: "recovery-private", scopeKey: scope,
            snapshotJSON: "{}", detectedAt: 1, status: "kept"))
        try context.save()

        try PhotoByteStore(lifetime: .pendingUploads, householdID: parked).write(Data("pending".utf8), for: pendingName)
        try PhotoByteStore(lifetime: .cache, householdID: parked).write(Data("cache".utf8), for: cacheName)
        let corruptRef = try PhotoByteStore(lifetime: .cache, householdID: parked).write(Data("original".utf8), for: corruptName)
        try Data("tampered".utf8).write(to: corruptRef.url)
        try PhotoByteStore(lifetime: .cache, householdID: parked).write(Data("private".utf8), for: privateName)
        try PhotoByteStore(lifetime: .cache, householdID: rig.other).write(Data("unrelated".utf8), for: unrelatedName)

        let inventory = try await GardenInventory.count(container: rig.container, householdID: rig.old)
        #expect(inventory.photos == 8) // four ordinary fixture rows plus four pending recovery children
        #expect(inventory.photosNotOnDevice == 4) // two ordinary fixture rows plus missing and hash-invalid recovery bytes

        let executor = rig.makeExecutor()
        try await executor.run(account: Self.account, householdID: rig.old)
        #expect(executor.lastMissingPhotoCount == inventory.photosNotOnDevice)
        #expect(GardenInventory.hasBytes(pendingName, household: rig.new))
        #expect(GardenInventory.hasBytes(cacheName, household: rig.new))
        #expect(!GardenInventory.hasBytes(missingName, household: rig.new))
        #expect(!GardenInventory.hasBytes(corruptName, household: rig.new))
        #expect(GardenInventory.hasBytes(pendingName, household: parked))
        #expect(GardenInventory.hasBytes(cacheName, household: parked))
        #expect(try ModelContext(rig.container).fetch(FetchDescriptor<LocalJournalEntryPhoto>(predicate: #Predicate { $0.entryID == "recovery-missing" })).isEmpty)
        #expect(try ModelContext(rig.container).fetch(FetchDescriptor<LocalJournalEntryPhoto>(predicate: #Predicate { $0.entryID == "recovery-corrupt" })).isEmpty)
        #expect(try ModelContext(rig.container).fetch(FetchDescriptor<LocalJournalEntryPhoto>(predicate: #Predicate { $0.entryID == "recovery-pending" })).count == 1)
        #expect(try ModelContext(rig.container).fetch(FetchDescriptor<LocalJournalEntry>(predicate: #Predicate { $0.id == "recovery-private" })).first?.householdID == parked)
        #expect(try ModelContext(rig.container).fetch(FetchDescriptor<LocalJournalEntry>(predicate: #Predicate { $0.id == "recovery-unrelated" })).first?.householdID == rig.other)
        #expect(GardenInventory.hasBytes(unrelatedName, household: rig.other))
    }

    @Test("recovery photo move save failure is atomic and retryable; a crash after its save keeps copied bytes")
    func recoveryPhotoSaveFailureAndPostSaveCrashRetry() async throws {
        let rig = try Self.keepRig(photos: false)
        let parked = "hhr_parked-\(UUID().uuidString)"
        defer { rig.cleanUp(); try? PhotoByteStore.purgeHousehold(parked) }
        let photoName = SeedkeepRecordNames.journalEntryPhoto("recovery-atomic-photo")
        let setup = ModelContext(rig.container)
        setup.insert(LocalJournalEntry(id: "recovery-atomic", householdID: parked, occurredOn: "2026-01-01", body: "entry",
            seedID: nil, bedID: nil, plantingEventID: nil, createdAt: 1, updatedAt: 2, deletedAt: nil))
        setup.insert(LocalJournalEntryPhoto(id: "recovery-atomic-photo", entryID: "recovery-atomic", storageKey: nil,
            sortOrder: 0, width: nil, height: nil, createdAt: 1, updatedAt: 1))
        setup.insert(LocalJournalRecoveryItem(id: "recovery-atomic", scopeKey: "\(rig.old)|\(rig.signedIn)",
            snapshotJSON: "{}", detectedAt: 1, status: "pending"))
        try setup.save()
        try PhotoByteStore(lifetime: .pendingUploads, householdID: parked).write(Data("available".utf8), for: photoName)

        let executor = rig.makeExecutor()
        rig.failCommit = { $0 == 2 } // row re-home commits first; the live recovery entry's atomic save is second
        await #expect(throws: Rig.Crash.self) { try await executor.run(account: Self.account, householdID: rig.old) }
        #expect(try ModelContext(rig.container).fetch(FetchDescriptor<LocalJournalEntry>(predicate: #Predicate { $0.id == "recovery-atomic" })).first?.householdID == parked)
        #expect(try ModelContext(rig.container).fetch(FetchDescriptor<LocalJournalRecoveryItem>(predicate: #Predicate { $0.id == "recovery-atomic" })).first?.status == "pending")
        #expect(try ModelContext(rig.container).fetch(FetchDescriptor<LocalJournalEntryPhoto>(predicate: #Predicate { $0.id == "recovery-atomic-photo" })).count == 1)

        rig.failCommit = nil
        rig.crashAfter = "recovery"
        await #expect(throws: Rig.Crash.self) { try await executor.run(account: Self.account, householdID: rig.old) }
        #expect(GardenInventory.hasBytes(photoName, household: rig.new))
        #expect(try ModelContext(rig.container).fetch(FetchDescriptor<LocalJournalEntry>(predicate: #Predicate { $0.id == "recovery-atomic" })).first?.householdID == rig.new)
        try await executor.run(account: Self.account, householdID: rig.old)
        #expect(rig.store.journal(Self.account, rig.old)?.phase == .done)
        #expect(GardenInventory.hasBytes(photoName, household: rig.new))
    }

    // MARK: - The disposition table against the real schema

    @Test("every model in the schema has a place in the disposition table, and none is extra")
    func dispositionTableCoversTheSchema() {
        let schema = Set(SeedkeepSchema.all.map { String(describing: $0) })
        let table = GardenDisposition.table.map { String(describing: $0.model) }
        #expect(Set(table) == schema)
        #expect(table.count == Set(table).count)   // no model twice
        #expect(schema.count == 22)
    }

    // MARK: - Keep: the disposition table, model by model

    @Test("keep re-homes every row (live and tombstoned) with IDs and references unchanged")
    func keepRehomesRows() async throws {
        let rig = try Self.keepRig()
        defer { rig.cleanUp() }
        let before = try rig.snapshot(rig.old)
        let otherBefore = try rig.snapshot(rig.other)
        let cursors = try rig.count(LocalSyncCursor.self)
        let pending = try rig.count(LocalPendingWrite.self)
        let threadsOfOld = before.threads

        // The fixture holds a tombstoned seed, bed and journal entry; they move too.
        let context = ModelContext(rig.container)
        let seedBefore = try context.fetch(FetchDescriptor<LocalSeed>()).first { $0.id == "seed_2" }
        #expect(seedBefore?.deletedAt != nil)
        let referenceBefore = try context.fetch(FetchDescriptor<LocalPlantingEvent>()).first { $0.id == "pe_1" }?.seedID

        try await rig.makeExecutor().run(account: Self.account, householdID: rig.old)

        // Everything that was the old garden's is the new garden's, under the same IDs.
        var expected = before
        expected.seedPhotos = ["seed_photo_local_ck"]; expected.entryPhotos = ["journal_photo_local_ck"]   // no bytes: dropped
        expected.deletions = []                       // the old scope's pending deletions die with it
        expected.threads = []; expected.messages = []; expected.toolCalls = []; expected.keyStatuses = []   // server-era rows are left alone
        #expect(try rig.snapshot(rig.new) == expected)
        let oldAfter = try rig.snapshot(rig.old)
        #expect(oldAfter.seeds.isEmpty && oldAfter.entries.isEmpty && oldAfter.beds.isEmpty && oldAfter.plantings.isEmpty)
        #expect(oldAfter.locations.isEmpty && oldAfter.tags.isEmpty && oldAfter.seedPhotos.isEmpty)
        #expect(oldAfter.deletions.isEmpty)
        // Children follow their parents untouched.
        #expect(try rig.snapshot(rig.new).checklist == before.checklist)
        #expect(try rig.snapshot(rig.new).departures == before.departures)
        #expect(try rig.snapshot(rig.new).moods == before.moods)
        // Tombstones are kept as tombstones; references are unchanged.
        let after = ModelContext(rig.container)
        let seedAfter = try after.fetch(FetchDescriptor<LocalSeed>()).first { $0.id == "seed_2" }
        #expect(seedAfter?.householdID == rig.new)
        #expect(seedAfter?.deletedAt != nil)
        #expect(try after.fetch(FetchDescriptor<LocalPlantingEvent>()).first { $0.id == "pe_1" }?.seedID == referenceBefore)
        // Other households and the left-alone models are untouched.
        #expect(try rig.snapshot(rig.other) == otherBefore)
        #expect(try rig.count(LocalSyncCursor.self) == cursors)
        #expect(try rig.count(LocalPendingWrite.self) == pending)
        let threadsLeft = try after.fetch(FetchDescriptor<LocalAssistantThread>()).filter { threadsOfOld.contains($0.id) }
        #expect(threadsLeft.count == threadsOfOld.count)
        #expect(try rig.count(LocalRecommendation.self) == 1)
        #expect(try rig.count(LocalForecastSnapshot.self) == 1)
        #expect(try rig.count(LocalCatalogCorrection.self) == 1)
    }

    @Test("keep moves the guard in one write: new owned binding, old garden retired, journal done")
    func keepBinds() async throws {
        let rig = try Self.keepRig()
        defer { rig.cleanUp() }
        try await rig.makeExecutor().run(account: Self.account, householdID: rig.old)

        let binding = try #require(rig.store.latestBinding(Self.account))
        #expect(binding.household.id == rig.new)
        #expect(binding.household.name == "Mine")
        #expect(binding.participant == nil)
        #expect(rig.store.isRetired(Self.account, rig.old))
        let journal = try #require(rig.store.journal(Self.account, rig.old))
        #expect(journal.phase == .done)
        #expect(journal.hasCompleted("bind"))
        // The pending grant is fixed in the same write as the choice, and survives the bind.
        #expect(rig.store.grant(Self.account, rig.new)?.state == .pending)
        #expect(rig.bound == [Self.account])
        #expect(rig.order == ["photos", "scans", "rows", "recovery", "state", "bytes", "bind"])
    }

    @Test("keep moves the state: old files and markers go, the new migration marker is set, the ledger moves")
    func keepMovesState() async throws {
        let rig = try Self.keepRig()
        defer { rig.cleanUp() }
        try await rig.makeExecutor().run(account: Self.account, householdID: rig.old)

        for name in ["engine", "synced", "failed", "unavailable"] {
            #expect(!FileManager.default.fileExists(atPath: rig.files.appendingPathComponent("\(name)-\(rig.old)").path))
            #expect(FileManager.default.fileExists(atPath: rig.files.appendingPathComponent("\(name)-\(rig.other)").path))
        }
        let d = rig.defaults
        #expect(d.object(forKey: GardenJournalExecutor.migrationMarkerKey(householdID: rig.old)) == nil)
        #expect(d.bool(forKey: GardenJournalExecutor.migrationMarkerKey(householdID: rig.new)))
        #expect(d.bool(forKey: GardenJournalExecutor.migrationMarkerKey(householdID: rig.other)))
        #expect(d.object(forKey: ParticipantRowRecovery.markerKeyPrefix + "\(rig.old)|\(rig.signedIn)") == nil)
        #expect(d.bool(forKey: ParticipantRowRecovery.markerKeyPrefix + "\(rig.other)|hh"))
        #expect(d.object(forKey: "seedkeep.watering.lastFire.\(rig.old)") == nil)
        #expect(d.object(forKey: "seedkeep.watering.lastFire.\(rig.new)") as? Date == Date(timeIntervalSince1970: 5_000))
        #expect(d.object(forKey: "seedkeep.watering.lastFire.\(rig.other)") as? Date == Date(timeIntervalSince1970: 6_000))
    }

    @Test("keep for a shared garden removes its shared-scope files and restores pending recovery items")
    func keepSharedGardenRestoresRecovery() async throws {
        let rig = Rig()
        defer { rig.cleanUp() }
        try rig.seed()
        try rig.seedDurableState()
        // A pending item whose parked row still exists, one with only its snapshot, one kept private.
        let scope = "\(rig.old)|\(rig.signedIn)"
        let context = ModelContext(rig.container)
        context.insert(LocalJournalEntry(id: "parked", householdID: rig.signedIn, occurredOn: "2025-09-01", body: "parked",
                                         seedID: nil, bedID: nil, plantingEventID: nil, createdAt: 1, updatedAt: 1, deletedAt: nil))
        let snapshot = ParticipantRowRecovery.EntrySnapshot(
            entry: LocalJournalEntry(id: "gone", householdID: rig.signedIn, occurredOn: "2025-09-02", body: "from snapshot",
                                     seedID: "x", bedID: nil, plantingEventID: nil, createdAt: 1, updatedAt: 1, deletedAt: nil),
            checklistItems: [LocalJournalChecklistItem(id: "c", entryID: "gone", text: "step", completed: true, sortOrder: 0, updatedAt: 1)])
        context.insert(LocalJournalRecoveryItem(id: "parked", scopeKey: scope, snapshotJSON: "{}", detectedAt: 1, status: "pending"))
        context.insert(LocalJournalRecoveryItem(id: "gone", scopeKey: scope, snapshotJSON: try #require(snapshot.encodedJSON),
                                                detectedAt: 2, status: "pending"))
        context.insert(LocalJournalRecoveryItem(id: "kept", scopeKey: scope, snapshotJSON: "{}", detectedAt: 3, status: "kept"))
        try context.save()
        try rig.chooseGone(.keep, participant: true)

        try await rig.makeExecutor().run(account: Self.account, householdID: rig.old)

        let after = ModelContext(rig.container)
        let entries = try after.fetch(FetchDescriptor<LocalJournalEntry>())
        // The parked row was re-homed in place; the snapshot became a new entry (and its checklist item).
        #expect(entries.first { $0.id == "parked" }?.householdID == rig.new)
        let recreated = try #require(entries.first { $0.body == "from snapshot" })
        #expect(recreated.householdID == rig.new)
        #expect(try after.fetch(FetchDescriptor<LocalJournalChecklistItem>()).contains { $0.entryID == recreated.id && $0.text == "step" })
        // Every item of the old scope is removed, other scopes' stay.
        #expect(try rig.recoveryItems().map(\.id) == ["other_rec"])
        // A shared garden also has shared-scope files, and its binding becomes an owned one.
        #expect(!FileManager.default.fileExists(atPath: rig.files.appendingPathComponent("shared-\(rig.old)").path))
        #expect(FileManager.default.fileExists(atPath: rig.files.appendingPathComponent("shared-\(rig.other)").path))
        let binding = try #require(rig.store.latestBinding(Self.account))
        #expect(binding.household.id == rig.new && binding.household.name == "My garden" && binding.participant == nil)
    }

    @Test("a failed recovery commit restores nothing twice on retry")
    func recoveryRetryRestoresOnce() async throws {
        let rig = Rig()
        defer { rig.cleanUp() }
        try rig.seed()
        let scope = "\(rig.old)|\(rig.signedIn)"
        let context = ModelContext(rig.container)
        let snapshot = ParticipantRowRecovery.EntrySnapshot(
            entry: LocalJournalEntry(id: "gone", householdID: rig.signedIn, occurredOn: "2025-09-02", body: "from snapshot",
                                     seedID: nil, bedID: nil, plantingEventID: nil, createdAt: 1, updatedAt: 1, deletedAt: nil),
            checklistItems: [])
        context.insert(LocalJournalRecoveryItem(id: "gone", scopeKey: scope, snapshotJSON: try #require(snapshot.encodedJSON),
                                                detectedAt: 2, status: "pending"))
        try context.save()
        try rig.chooseGone(.keep, participant: true)
        // Commits: 1 is the item removal of the recovery step (the restore commits through the helper).
        rig.failCommit = { $0 == 2 }   // the rows commit is 1; the recovery removal is 2
        let executor = rig.makeExecutor()
        await #expect(throws: JournalRig.Crash.self) { try await executor.run(account: Self.account, householdID: rig.old) }
        #expect(rig.store.journal(Self.account, rig.old)?.hasCompleted("recovery") == false)
        let restoredOnce = try ModelContext(rig.container).fetch(FetchDescriptor<LocalJournalEntry>()).filter { $0.body == "from snapshot" }
        #expect(restoredOnce.count == 1)

        rig.failCommit = nil
        try await rig.makeExecutor().run(account: Self.account, householdID: rig.old)
        let restored = try ModelContext(rig.container).fetch(FetchDescriptor<LocalJournalEntry>()).filter { $0.body == "from snapshot" }
        #expect(restored.count == 1)   // the retry restored only what was still pending
        #expect(try rig.recoveryItems().map(\.id) == ["other_rec"])
    }

    // MARK: - Photos

    @Test("keep copies and verifies photo bytes per lifetime, counts what is missing, and removes the old bytes")
    func keepCopiesPhotos() async throws {
        let rig = try Self.keepRig()
        defer { rig.cleanUp() }
        let shown = try await GardenInventory.count(container: rig.container, householdID: rig.old)
        let executor = rig.makeExecutor()
        try await executor.run(account: Self.account, householdID: rig.old)
        #expect(shown.photosNotOnDevice == executor.lastMissingPhotoCount)

        // The usable photos are in the new household, in the lifetime they were in; the rows all stay.
        let newPending = PhotoByteStore(lifetime: .pendingUploads, householdID: rig.new)
        let newCache = PhotoByteStore(lifetime: .cache, householdID: rig.new)
        #expect(newPending.data(for: SeedkeepRecordNames.seedPhoto("seed_photo_local_ck")) == Data("seed-local".utf8))
        #expect(newCache.data(for: SeedkeepRecordNames.journalEntryPhoto("journal_photo_local_ck")) == Data("journal-local".utf8))
        // The corrupt file and the absent one were skipped, and counted.
        #expect(!newPending.contains(SeedkeepRecordNames.seedPhoto("photo_legacy")))
        #expect(!newPending.contains(SeedkeepRecordNames.journalEntryPhoto("jp_legacy")) && !newCache.contains(SeedkeepRecordNames.journalEntryPhoto("jp_legacy")))
        #expect(executor.lastMissingPhotoCount == 2)
        // Their rows are dropped from the copy, and the count equals what the choice screen showed.
        let snapshot = try rig.snapshot(rig.new)
        #expect(snapshot.seedPhotos == ["seed_photo_local_ck"])
        #expect(snapshot.entryPhotos == ["journal_photo_local_ck"])
        #expect(try rig.snapshot(rig.old).seedPhotos.isEmpty && rig.snapshot(rig.old).entryPhotos.isEmpty)
        // The old bytes are gone.
        let oldPending = PhotoByteStore(lifetime: .pendingUploads, householdID: rig.old)
        let oldCache = PhotoByteStore(lifetime: .cache, householdID: rig.old)
        #expect(!oldPending.contains(SeedkeepRecordNames.seedPhoto("seed_photo_local_ck")))
        #expect(!oldCache.contains(SeedkeepRecordNames.journalEntryPhoto("journal_photo_local_ck")))
    }

    @Test("a failed byte write stops the step, moves nothing, and a retry finishes")
    func failedByteWrite() async throws {
        let rig = try Self.keepRig()
        defer { rig.cleanUp() }
        let before = try rig.snapshot(rig.old)
        rig.bytes.fail = true
        let executor = rig.makeExecutor()
        await #expect(throws: JournalRig.Crash.self) { try await executor.run(account: Self.account, householdID: rig.old) }
        let journal = try #require(rig.store.journal(Self.account, rig.old))
        #expect(journal.phase == .journaled && journal.steps == [])
        #expect(try rig.snapshot(rig.old) == before)
        // The old bytes are intact.
        #expect(PhotoByteStore(lifetime: .pendingUploads, householdID: rig.old)
            .data(for: SeedkeepRecordNames.seedPhoto("seed_photo_local_ck")) == Data("seed-local".utf8))

        rig.bytes.fail = false
        try await rig.makeExecutor().run(account: Self.account, householdID: rig.old)
        #expect(rig.store.journal(Self.account, rig.old)?.phase == .done)
    }

    @Test("a copy whose hash doesn't verify is a failed step, never a silent success")
    func unverifiedCopyFails() async throws {
        let rig = try Self.keepRig()
        defer { rig.cleanUp() }
        rig.bytes.lie = true
        let executor = rig.makeExecutor()
        await #expect(throws: GardenJournalError.self) { try await executor.run(account: Self.account, householdID: rig.old) }
        #expect(rig.store.journal(Self.account, rig.old)?.hasCompleted("photos") == false)
        #expect(try rig.snapshot(rig.old).seeds.isEmpty == false)
    }

    // MARK: - Staged scans

    @Test("staged scans are re-targeted before the new scope is visible; other gardens' scans are not")
    func scansRetargetedBeforeExposure() async throws {
        let rig = try Self.keepRig()
        defer { rig.cleanUp() }
        let mine = UUID(), theirs = UUID()
        try ScanPhotoStaging.write(Data("a".utf8), side: .front, scanID: mine,
                                   scope: .init(userRecordName: "_userA", householdID: rig.old), root: rig.scanRoot)
        try ScanPhotoStaging.write(Data("b".utf8), side: .front, scanID: theirs,
                                   scope: .init(userRecordName: "_userA", householdID: rig.other), root: rig.scanRoot)
        // When the scans step has taken effect, the binding still names the old garden: the new scope
        // is not visible yet, and the manifest already points at it.
        var bindingAtScans: String?
        var scopeAtScans: String?
        rig.duringStep["scans"] = {
            bindingAtScans = rig.store.latestBinding(Self.account)?.household.id
            scopeAtScans = ScanPhotoStaging.manifest(for: mine, root: rig.scanRoot)?.scope?.householdID
        }
        try await rig.makeExecutor().run(account: Self.account, householdID: rig.old)

        #expect(bindingAtScans == rig.old)
        #expect(scopeAtScans == rig.new)
        #expect(ScanPhotoStaging.manifest(for: mine, root: rig.scanRoot)?.scope?.householdID == rig.new)
        #expect(ScanPhotoStaging.manifest(for: theirs, root: rig.scanRoot)?.scope?.householdID == rig.other)
    }

    // MARK: - Failed commit

    @Test("a failed model commit changes no row, keeps the checkpoint, and a retry finishes")
    func failedModelCommit() async throws {
        let rig = try Self.keepRig()
        defer { rig.cleanUp() }
        let before = try rig.snapshot(rig.old)
        rig.failCommit = { $0 == 1 }   // the rows step's one save
        let executor = rig.makeExecutor()
        await #expect(throws: JournalRig.Crash.self) { try await executor.run(account: Self.account, householdID: rig.old) }
        #expect(try rig.snapshot(rig.old) == before)
        let journal = try #require(rig.store.journal(Self.account, rig.old))
        #expect(journal.steps == ["photos", "scans"])   // earlier steps keep their checkpoints
        #expect(journal.phase == .journaled)

        rig.failCommit = nil
        try await rig.makeExecutor().run(account: Self.account, householdID: rig.old)
        #expect(rig.store.journal(Self.account, rig.old)?.phase == .done)
        #expect(try rig.snapshot(rig.new).seeds == before.seeds)
        #expect(rig.bound == [Self.account])
    }

    // MARK: - Crash and resume between every effect and its checkpoint

    enum Scenario: String, CaseIterable, Sendable { case keep, rehome, discard }
    struct CrashPoint: Sendable, CustomTestStringConvertible {
        let scenario: Scenario
        let step: String
        var testDescription: String { "\(scenario.rawValue) after \(step)" }
    }
    nonisolated static let crashPoints: [CrashPoint] =
        GardenJournalExecutor.keepSteps.map { CrashPoint(scenario: .keep, step: $0) }
        + GardenJournalExecutor.keepSteps.map { CrashPoint(scenario: .rehome, step: $0) }
        + GardenJournalExecutor.discardSteps.map { CrashPoint(scenario: .discard, step: $0) }

    @Test("a crash after any step's effect, before its checkpoint, repeats safely and ends the same", arguments: crashPoints)
    func crashAndResume(_ point: CrashPoint) async throws {
        let action: GardenGoneRecord.Action = point.scenario == .keep ? .keep : (point.scenario == .rehome ? .rehome : .discard)
        let rig = try Self.keepRig(action)
        defer { rig.cleanUp() }
        let before = try rig.snapshot(rig.old)

        // The "crash": the effect happened, the checkpoint did not.
        rig.crashAfter = point.step
        await #expect(throws: JournalRig.Crash.self) {
            try await rig.makeExecutor().run(account: Self.account, householdID: rig.old)
        }
        let interrupted = try #require(rig.store.journal(Self.account, rig.old))
        #expect(interrupted.phase == .journaled)
        #expect(!interrupted.hasCompleted(point.step))
        #expect(rig.bound.isEmpty && rig.discarded.isEmpty)

        // A fresh executor (a relaunch) resumes from the guard alone. Discard resolution belongs
        // to the runner and happens after its task has left the task registry.
        if point.scenario == .discard {
            let runner = GardenGuardRunner(store: rig.store, rehomer: DeferredGardenRehomer())
            runner.executor = rig.makeExecutor()
            runner.startJournal(account: Self.account, householdID: rig.old)
            await runner.awaitJournal(account: Self.account, householdID: rig.old)
        } else {
            try await rig.makeExecutor().run(account: Self.account, householdID: rig.old)
        }
        let finished = try #require(rig.store.journal(Self.account, rig.old))
        #expect(finished.phase == .done)
        #expect(rig.store.isRetired(Self.account, rig.old))
        switch point.scenario {
        case .keep, .rehome:
            #expect(rig.bound == [Self.account])
            #expect(try rig.snapshot(rig.new).seeds == before.seeds)
            #expect(try rig.snapshot(rig.new).entries == before.entries)
            #expect(try rig.snapshot(rig.new).entryPhotos == ["journal_photo_local_ck"])   // the missing one is dropped
            #expect(try rig.snapshot(rig.new).seedPhotos == ["seed_photo_local_ck"])
            #expect(try rig.snapshot(rig.old).seeds.isEmpty)
            #expect(rig.store.latestBinding(Self.account)?.household.id == rig.new)
            #expect(rig.defaults.bool(forKey: GardenJournalExecutor.migrationMarkerKey(householdID: rig.new)))
            #expect(rig.defaults.object(forKey: "seedkeep.watering.lastFire.\(rig.new)") as? Date == Date(timeIntervalSince1970: 5_000))
            #expect(PhotoByteStore(lifetime: .pendingUploads, householdID: rig.new)
                .contains(SeedkeepRecordNames.seedPhoto("seed_photo_local_ck")))
        case .discard:
            #expect(rig.discarded == [Self.account])
            #expect(try rig.snapshot(rig.old) == Rig.Snapshot())
            #expect(rig.store.latestBinding(Self.account) == nil)
            #expect(rig.store.account(Self.account).bindingWritten)
        }
        #expect(try rig.snapshot(rig.other).seeds == ["other_seed"])
    }

    @Test("a crash after the closing guard write leaves the journal done, and nothing runs again")
    func crashAfterBind() async throws {
        let rig = try Self.keepRig()
        defer { rig.cleanUp() }
        rig.crashAfter = "bind"
        let executor = rig.makeExecutor()
        await #expect(throws: JournalRig.Crash.self) { try await executor.run(account: Self.account, householdID: rig.old) }
        // The binding is written and the journal is done; the defaults were not derived yet.
        #expect(rig.store.journal(Self.account, rig.old)?.phase == .done)
        #expect(rig.store.latestBinding(Self.account)?.household.id == rig.new)
        #expect(rig.bound.isEmpty)
        let seeds = try rig.snapshot(rig.new).seeds
        try await rig.makeExecutor().run(account: Self.account, householdID: rig.old)   // a done journal is never replayed
        #expect(rig.bound.isEmpty)
        #expect(try rig.snapshot(rig.new).seeds == seeds)
    }

    // MARK: - Discard: the disposition table

    @Test("discard deletes the old garden model by model and leaves every other household alone")
    func discardDisposition() async throws {
        let rig = try Self.keepRig(.discard)
        defer { rig.cleanUp() }
        let otherBefore = try rig.snapshot(rig.other)
        let before = try rig.snapshot(rig.old)
        #expect(!before.entryPhotos.isEmpty && !before.checklist.isEmpty && !before.departures.isEmpty && !before.moods.isEmpty)
        #expect(!before.threads.isEmpty && !before.messages.isEmpty && !before.toolCalls.isEmpty && !before.keyStatuses.isEmpty)
        let recommendations = try rig.count(LocalRecommendation.self)
        let forecasts = try rig.count(LocalForecastSnapshot.self)
        let corrections = try rig.count(LocalCatalogCorrection.self)

        let runner = GardenGuardRunner(store: rig.store, rehomer: DeferredGardenRehomer())
        runner.executor = rig.makeExecutor()
        runner.startJournal(account: Self.account, householdID: rig.old)
        await runner.awaitJournal(account: Self.account, householdID: rig.old)

        // Rows, children (captured before their parents), the old scope's deletions, the household's
        // assistant rows and its recovery items are gone.
        #expect(try rig.snapshot(rig.old) == Rig.Snapshot())
        #expect(try rig.recoveryItems().map(\.id) == ["other_rec"])
        // The other household's, with its children, is untouched.
        #expect(try rig.snapshot(rig.other) == otherBefore)
        // The inert server-era rows are deleted for every household: the explicit global cleanup.
        #expect(try rig.count(LocalSyncCursor.self) == 0)
        #expect(try rig.count(LocalPendingWrite.self) == 0)
        // Not garden data: unchanged.
        #expect(try rig.count(LocalRecommendation.self) == recommendations)
        #expect(try rig.count(LocalForecastSnapshot.self) == forecasts)
        #expect(try rig.count(LocalCatalogCorrection.self) == corrections)
    }

    @Test("discard purges bytes, scans, files, markers and notifications of the old garden only, then clears the binding")
    func discardState() async throws {
        let rig = try Self.keepRig(.discard)
        defer { rig.cleanUp() }
        let mine = UUID(), theirs = UUID()
        try ScanPhotoStaging.write(Data("a".utf8), side: .front, scanID: mine,
                                   scope: .init(userRecordName: "_userA", householdID: rig.old), root: rig.scanRoot)
        try ScanPhotoStaging.write(Data("b".utf8), side: .front, scanID: theirs,
                                   scope: .init(userRecordName: "_userA", householdID: rig.other), root: rig.scanRoot)
        try PhotoByteStore(lifetime: .cache, householdID: rig.other).write(Data("o".utf8), for: SeedkeepRecordNames.seedPhoto("o"))

        let runner = GardenGuardRunner(store: rig.store, rehomer: DeferredGardenRehomer())
        runner.executor = rig.makeExecutor()
        runner.startJournal(account: Self.account, householdID: rig.old)
        await runner.awaitJournal(account: Self.account, householdID: rig.old)

        #expect(!PhotoByteStore(lifetime: .pendingUploads, householdID: rig.old).contains(SeedkeepRecordNames.seedPhoto("seed_photo_local_ck")))
        #expect(PhotoByteStore(lifetime: .cache, householdID: rig.other).contains(SeedkeepRecordNames.seedPhoto("o")))
        #expect(ScanPhotoStaging.manifest(for: mine, root: rig.scanRoot) == nil)
        #expect(ScanPhotoStaging.manifest(for: theirs, root: rig.scanRoot) != nil)
        for name in ["engine", "synced", "failed", "unavailable"] {
            #expect(!FileManager.default.fileExists(atPath: rig.files.appendingPathComponent("\(name)-\(rig.old)").path))
            #expect(FileManager.default.fileExists(atPath: rig.files.appendingPathComponent("\(name)-\(rig.other)").path))
        }
        let d = rig.defaults
        #expect(d.object(forKey: GardenJournalExecutor.migrationMarkerKey(householdID: rig.old)) == nil)
        #expect(d.bool(forKey: GardenJournalExecutor.migrationMarkerKey(householdID: rig.other)))
        #expect(d.object(forKey: ParticipantRowRecovery.markerKeyPrefix + "\(rig.old)|\(rig.signedIn)") == nil)
        #expect(d.object(forKey: "seedkeep.watering.lastFire.\(rig.old)") == nil)
        #expect(d.object(forKey: "seedkeep.watering.lastFire.\(rig.other)") != nil)
        #expect(rig.notificationsRemoved == 1)

        // The binding is cleared (explicitly), the garden retired, the journal done, the session resolved again.
        #expect(rig.store.latestBinding(Self.account) == nil)
        #expect(rig.store.account(Self.account).bindingWritten)
        #expect(rig.store.isRetired(Self.account, rig.old))
        #expect(rig.store.journal(Self.account, rig.old)?.phase == .done)
        #expect(rig.discarded == [Self.account])
        #expect(rig.order == ["quiesce", "rows", "bytes", "state", "clear"])
    }

    @Test("discard of a shared garden removes its shared-scope files")
    func discardSharedGarden() async throws {
        let rig = Rig()
        defer { rig.cleanUp() }
        try rig.seed()
        try rig.seedDurableState()
        try rig.chooseGone(.discard, participant: true)
        try await rig.makeExecutor().run(account: Self.account, householdID: rig.old)
        #expect(!FileManager.default.fileExists(atPath: rig.files.appendingPathComponent("shared-\(rig.old)").path))
        #expect(FileManager.default.fileExists(atPath: rig.files.appendingPathComponent("shared-\(rig.other)").path))
        #expect(rig.store.latestBinding(Self.account) == nil)
    }

    // MARK: - The guard transitions

    @Test("the choice is one guard write: action, replacement ID and pending grant; a second answer changes nothing")
    func choiceIsOneWrite() throws {
        let store = GardenGuardStore(directory: GuardTestDirectory.make())
        try store.setBinding(Self.account, JournalRig.binding("hhr_g"))
        try store.markGone(Self.account, "hhr_g", reason: .zoneDeleted)
        #expect(store.isGone(Self.account, "hhr_g"))

        let chosen = try store.chooseAction(Self.account, "hhr_g", action: .keep, replacementID: "hhr_n1")
        #expect(chosen.action == .keep && chosen.phase == .journaled && chosen.replacementID == "hhr_n1")
        #expect(store.grant(Self.account, "hhr_n1")?.state == .pending)
        #expect(!store.isGone(Self.account, "hhr_g"))
        #expect(store.hasOpenJournal(Self.account, "hhr_g"))

        // A second tap, or a second window, neither re-mints the ID nor switches the action.
        let again = try store.chooseAction(Self.account, "hhr_g", action: .discard, replacementID: "hhr_n2")
        #expect(again == chosen)
        #expect(store.grant(Self.account, "hhr_n2") == nil)
    }

    @Test("a superseded journal is never advanced or closed over a newer binding")
    func supersededJournalNeverOverwrites() throws {
        let store = GardenGuardStore(directory: GuardTestDirectory.make())
        try store.setBinding(Self.account, JournalRig.binding("hhr_g"))
        try store.markGone(Self.account, "hhr_g", reason: .zoneDeleted)
        try store.chooseAction(Self.account, "hhr_g", action: .discard, replacementID: nil)
        // Another binding lands first (a successor).
        try store.setBinding(Self.account, JournalRig.binding("hhr_successor"), newGrants: ["hhr_successor"])
        #expect(store.journal(Self.account, "hhr_g")?.phase == .superseded)
        #expect(throws: GardenGuardError.self) { try store.completeDiscard(Self.account, householdID: "hhr_g") }
        #expect(throws: GardenGuardError.self) { try store.checkpoint(Self.account, "hhr_g", step: "rows") }
        #expect(store.latestBinding(Self.account)?.household.id == "hhr_successor")
    }

    // MARK: - Writers are quiesced first, and the garden is blocked while a journal runs

    @Test("the runner quiesces the writers before the first step, and blocks the garden while the journal runs")
    func runnerQuiescesFirst() async throws {
        let rig = try Self.keepRig()
        defer { rig.cleanUp() }
        let runner = GardenGuardRunner(store: rig.store, rehomer: DeferredGardenRehomer())
        runner.executor = rig.makeExecutor()
        var blockedDuringSteps = true
        rig.duringStep["rows"] = { blockedDuringSteps = blockedDuringSteps && runner.isBlocked(account: Self.account, householdID: rig.old) }

        runner.startJournal(account: Self.account, householdID: rig.old)
        #expect(runner.runningJournals.contains(GardenGuardRunner.journalKey(Self.account, rig.old)))   // before any await
        runner.startJournal(account: Self.account, householdID: rig.old)   // a second window: no second run
        await runner.awaitJournal(account: Self.account, householdID: rig.old)

        #expect(rig.order.first == "quiesce")
        #expect(rig.quiesced == 1)
        #expect(runner.journalStarts == 1)
        #expect(blockedDuringSteps)
        #expect(runner.runningJournals.isEmpty)
        #expect(runner.journalFailure(account: Self.account, householdID: rig.old) == nil)
    }

    @Test("a failed step leaves a message for Try again, and Try again continues from the checkpoint")
    func failureThenTryAgain() async throws {
        let rig = try Self.keepRig()
        defer { rig.cleanUp() }
        rig.failCommit = { $0 == 1 }
        let runner = GardenGuardRunner(store: rig.store, rehomer: DeferredGardenRehomer())
        runner.executor = rig.makeExecutor()

        runner.startJournal(account: Self.account, householdID: rig.old)
        await runner.awaitJournal(account: Self.account, householdID: rig.old)
        #expect(runner.journalFailure(account: Self.account, householdID: rig.old) != nil)
        #expect(runner.runningJournals.isEmpty)
        #expect(runner.isBlocked(account: Self.account, householdID: rig.old))
        #expect(rig.store.journal(Self.account, rig.old)?.steps == ["photos", "scans"])

        rig.failCommit = nil
        runner.retryJournal(account: Self.account, householdID: rig.old)
        await runner.awaitJournal(account: Self.account, householdID: rig.old)
        #expect(runner.journalFailure(account: Self.account, householdID: rig.old) == nil)
        #expect(rig.store.journal(Self.account, rig.old)?.phase == .done)
        #expect(rig.order.filter { $0 == "photos" }.count == 1)   // the checkpointed steps did not run again
    }

    // MARK: - Journal lifetime

    @Test("a closed journal is removed only by a later launch, with confirmed defaults, and a keep only once its grant is consumed")
    func journalLifetime() async throws {
        let rig = try Self.keepRig()
        defer { rig.cleanUp() }
        let runner = GardenGuardRunner(store: rig.store, rehomer: DeferredGardenRehomer())
        runner.executor = rig.makeExecutor()
        var confirmed = true
        runner.defaultsConfirmed = { _ in confirmed }
        runner.startJournal(account: Self.account, householdID: rig.old)
        await runner.awaitJournal(account: Self.account, householdID: rig.old)
        #expect(rig.store.journal(Self.account, rig.old)?.phase == .done)

        // The launch that ran it never removes it.
        runner.resume(accountKey: Self.account)
        #expect(rig.store.journal(Self.account, rig.old) != nil)

        // A later launch: the grant is not consumed yet (the first sync has not created the zone).
        let launch2 = GardenGuardRunner(store: rig.store, rehomer: DeferredGardenRehomer())
        launch2.defaultsConfirmed = { _ in confirmed }
        launch2.resume(accountKey: Self.account)
        #expect(rig.store.journal(Self.account, rig.old) != nil)

        // The grant is consumed, but this launch had to repair the defaults: not confirmed.
        try rig.store.consumeGrant(Self.account, rig.new, generation: 1)
        confirmed = false
        let launch3 = GardenGuardRunner(store: rig.store, rehomer: DeferredGardenRehomer())
        launch3.defaultsConfirmed = { _ in confirmed }
        launch3.resume(accountKey: Self.account)
        #expect(rig.store.journal(Self.account, rig.old) != nil)

        // A later launch with the defaults confirmed removes it.
        confirmed = true
        let launch4 = GardenGuardRunner(store: rig.store, rehomer: DeferredGardenRehomer())
        launch4.defaultsConfirmed = { _ in confirmed }
        launch4.resume(accountKey: Self.account)
        #expect(rig.store.journal(Self.account, rig.old) == nil)
        #expect(rig.store.isRetired(Self.account, rig.old))   // the old ID stays retired
    }

    @Test("an open journal is never removed, and a journal of another account is never touched")
    func openJournalsStay() throws {
        let rig = Rig()
        defer { rig.cleanUp() }
        try rig.chooseGone(.keep)
        let runner = GardenGuardRunner(store: rig.store, rehomer: DeferredGardenRehomer())
        runner.defaultsConfirmed = { _ in true }
        runner.resume(accountKey: "_userB|production")
        #expect(rig.store.journal(Self.account, rig.old)?.phase == .journaled)
        #expect(throws: Never.self) { try rig.store.removeJournal(Self.account, rig.old) }
        #expect(rig.store.journal(Self.account, rig.old)?.phase == .journaled)
    }

    @Test("an account switch during writer quiescence cancels and awaits the old journal")
    func accountSwitchDuringQuiesce() async throws {
        let rig = try Self.keepRig()
        defer { rig.cleanUp() }
        let pause = JournalPausePoint()
        let executor = rig.makeExecutor()
        executor.deps.quiesce = { await pause.pause() }
        let runner = GardenGuardRunner(store: rig.store, rehomer: DeferredGardenRehomer())
        runner.executor = executor

        runner.startJournal(account: Self.account, householdID: rig.old)
        await pause.waitUntilStarted()
        let switchRelease = Task.detached {
            try? await Task.sleep(for: .milliseconds(50))
            await pause.resume()
        }
        await runner.cancelAndWaitJournals()
        await switchRelease.value

        #expect(rig.store.journal(Self.account, rig.old)?.phase == .journaled)
        #expect(rig.store.latestBinding(Self.account)?.household.id == rig.old)
        #expect(rig.order.isEmpty)
        #expect(rig.bound.isEmpty && rig.discarded.isEmpty && rig.notificationsRemoved == 0)
        #expect(runner.isBlocked(account: Self.account, householdID: rig.old))
        #expect(!runner.isBlocked(account: "_userB|production", householdID: rig.old))
    }

    @Test("an account switch during detached photo copy awaits it before same-ID rows can belong to the new account")
    func accountSwitchDuringPhotoCopy() async throws {
        let rig = try Self.keepRig()
        defer { rig.cleanUp() }
        let pause = PhotoCopyPause()
        let executor = rig.makeExecutor()
        executor.deps.writeBytes = { store, data, name in
            pause.pause()
            return try store.write(data, for: name)
        }
        let runner = GardenGuardRunner(store: rig.store, rehomer: DeferredGardenRehomer())
        runner.executor = executor

        runner.startJournal(account: Self.account, householdID: rig.old)
        await Task.detached { pause.waitUntilEntered() }.value
        let switchRelease = Task.detached {
            try? await Task.sleep(for: .milliseconds(50))
            pause.resume()
        }
        await runner.cancelAndWaitJournals()
        await switchRelease.value

        #expect(rig.store.journal(Self.account, rig.old)?.phase == .journaled)
        #expect(rig.store.journal(Self.account, rig.old)?.steps == [])
        #expect(rig.store.latestBinding(Self.account)?.household.id == rig.old)
        #expect(rig.order == ["quiesce"])
        #expect(rig.bound.isEmpty && rig.discarded.isEmpty && rig.notificationsRemoved == 0)

        // The switched-to account can use the exact same household ID after the awaited wipe boundary.
        let context = ModelContext(rig.container)
        context.insert(LocalSeed(id: "new-account-seed", householdID: rig.old, state: .active,
                                 packetCount: 1, source: .store, customName: "New account", createdAt: 1, updatedAt: 1))
        try context.save()
        #expect(try context.fetch(FetchDescriptor<LocalSeed>()).contains { $0.id == "new-account-seed" })
        #expect(!runner.isBlocked(account: "_userB|production", householdID: rig.old))
        #expect(runner.isBlocked(account: Self.account, householdID: rig.old))
    }

    @Test("discard re-resolution can start an account wipe after the journal task has exited")
    func discardResolutionDoesNotAwaitItsOwnJournal() async throws {
        let rig = Rig()
        defer { rig.cleanUp() }
        try rig.seed()
        try rig.chooseGone(.discard)
        let runner = GardenGuardRunner(store: rig.store, rehomer: DeferredGardenRehomer())
        let executor = rig.makeExecutor()
        var wipeReached = false
        executor.deps.didDiscard = { _, _, _ in
            wipeReached = true
            await runner.cancelAndWaitJournals()
            return true
        }
        runner.executor = executor

        runner.startJournal(account: Self.account, householdID: rig.old)
        await runner.awaitJournal(account: Self.account, householdID: rig.old)

        #expect(wipeReached)
        #expect(rig.store.journal(Self.account, rig.old)?.phase == .done)
        #expect(runner.runningJournals.isEmpty)
    }
}
