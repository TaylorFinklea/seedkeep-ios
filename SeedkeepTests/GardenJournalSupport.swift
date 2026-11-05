import CloudKit
import Foundation
import SwiftData
import Testing
@testable import Seedkeep
import SeedkeepCloudKit

/// N2-E (G3) test rig: a guard, an in-memory store seeded with the pre-N3 fixture's garden (every model)
/// plus a second household that must never be touched, temp directories for scans and durable files,
/// and an executor whose seams (crash after an effect, failed commit, failed byte write) a test sets.
@MainActor
final class JournalRig {
    nonisolated static let account = "_userA|production"
    nonisolated static let userRecord = "_userA"

    let old = "hhr_old-\(UUID().uuidString)"
    let new = "hhr_new-\(UUID().uuidString)"
    let other = "hhr_other-\(UUID().uuidString)"
    /// The signed-in (own) household, which differs from `old` for a participant's gone garden.
    let signedIn = "hh_signed-\(UUID().uuidString)"
    let store = GardenGuardStore(directory: GuardTestDirectory.make())
    let container = makeTestContainer(name: "journal-\(UUID().uuidString)")
    let defaults: UserDefaults
    let scanRoot = FileManager.default.temporaryDirectory.appendingPathComponent("journal-scans-\(UUID().uuidString)", isDirectory: true)
    let files = FileManager.default.temporaryDirectory.appendingPathComponent("journal-files-\(UUID().uuidString)", isDirectory: true)

    struct Crash: Error {}
    final class ByteSwitch: @unchecked Sendable {
        private let lock = NSLock()
        private var _fail = false
        private var _lie = false
        var fail: Bool { get { lock.withLock { _fail } } set { lock.withLock { _fail = newValue } } }
        /// Reports a different hash than the bytes written.
        var lie: Bool { get { lock.withLock { _lie } } set { lock.withLock { _lie = newValue } } }
    }
    let bytes = ByteSwitch()

    var order: [String] = []
    var crashAfter: String?
    var crashOnce = true
    var failCommit: ((Int) -> Bool)?
    private(set) var commits = 0
    var bound: [String] = []
    var discarded: [String] = []
    var notificationsRemoved = 0
    var quiesced = 0
    var duringStep: [String: @MainActor () -> Void] = [:]

    /// `standard` runs the steps over `UserDefaults.standard`, which the coordinator reads for its migration
    /// marker; the keys are unique per rig and removed in `cleanUp`.
    init(suite: String = UUID().uuidString, standard: Bool = false) {
        if standard {
            defaults = .standard
        } else {
            defaults = UserDefaults(suiteName: "JournalRig.\(suite)")!
            defaults.removePersistentDomain(forName: "JournalRig.\(suite)")
        }
    }

    func cleanUp() {
        for id in [old, new, other] {
            try? PhotoByteStore.purgeHousehold(id)
            defaults.removeObject(forKey: GardenJournalExecutor.migrationMarkerKey(householdID: id))
            defaults.removeObject(forKey: "seedkeep.watering.lastFire.\(id)")
        }
        try? FileManager.default.removeItem(at: scanRoot)
        try? FileManager.default.removeItem(at: files)
    }

    func makeExecutor() -> GardenJournalExecutor {
        GardenJournalExecutor(store: store, deps: GardenJournalDependencies(
            container: container, defaults: defaults, scanStagingRoot: scanRoot,
            durableFiles: { [files] id, participant in
                var urls = ["engine", "synced", "failed", "unavailable"].map { files.appendingPathComponent("\($0)-\(id)") }
                if participant != nil { urls.append(files.appendingPathComponent("shared-\(id)")) }
                return urls
            },
            removeNotifications: { [self] in notificationsRemoved += 1 },
            quiesce: { [self] in quiesced += 1; order.append("quiesce") },
            didBind: { [self] account in bound.append(account) },
            didDiscard: { [self] account, _, _ in
                discarded.append(account)
                return true
            },
            afterEffect: { [self] step in
                order.append(step)
                duringStep[step]?()
                if crashAfter == step {
                    if crashOnce { crashAfter = nil }
                    throw Crash()
                }
            },
            commit: { [self] context in
                commits += 1
                if failCommit?(commits) == true { throw Crash() }
                try context.save()
            },
            writeBytes: { [bytes] store, data, name in
                if bytes.fail { throw Crash() }
                let ref = try store.write(data, for: name)
                return bytes.lie ? PhotoByteStore.Ref(recordName: ref.recordName, sha256: "0000", url: ref.url) : ref
            }))
    }

    // MARK: - The guard

    static func binding(_ id: String, participant: GardenGuardBinding.Participant? = nil,
                        signedIn: String? = nil) -> GardenGuardBinding {
        GardenGuardBinding(household: .init(id: signedIn ?? id, name: "Mine", createdAt: 1, updatedAt: 1), participant: participant)
    }

    /// An owned garden whose zone is gone, awaiting the choice; the user then chose `action`.
    func chooseGone(_ action: GardenGoneRecord.Action, participant: Bool = false) throws {
        if participant {
            let zone = SeedkeepRecordNames.zoneName(householdID: old)
            try store.setBinding(Self.account, Self.binding(
                old, participant: .init(zoneName: zone, ownerName: "_ownerX"), signedIn: signedIn))
        } else {
            try store.setBinding(Self.account, Self.binding(old))
        }
        try store.markGone(Self.account, old, reason: participant ? .accessLost : .zoneDeleted)
        try store.chooseAction(Self.account, old, action: action, replacementID: action == .discard ? nil : new)
    }

    /// The silent re-home, as `AuthController.bind` journals it for an absent zone.
    func journalRehome() throws {
        try store.setBinding(
            Self.account, Self.binding(old), newGrants: [new],
            journals: [old: GardenGoneRecord(reason: .absentZone, action: .rehome, phase: .journaled,
                                             replacementID: new, createdAt: Date())])
    }

    // MARK: - Seeding

    /// The fixture garden (every model, ids unique per rig) under `old`, plus `other`'s rows.
    func seed(recoveryScope: String? = nil) throws {
        let context = ModelContext(container)
        try PreN3StoreFixture.insertRows(into: context)
        let fixture = PreN3StoreFixture.householdID
        let old = self.old
        for row in try context.fetch(FetchDescriptor<LocalLocation>()) where row.householdID == fixture { row.householdID = old }
        for row in try context.fetch(FetchDescriptor<LocalTag>()) where row.householdID == fixture { row.householdID = old }
        for row in try context.fetch(FetchDescriptor<LocalSeed>()) where row.householdID == fixture { row.householdID = old }
        for row in try context.fetch(FetchDescriptor<LocalSeedPhoto>()) where row.householdID == fixture { row.householdID = old }
        for row in try context.fetch(FetchDescriptor<LocalBed>()) where row.householdID == fixture { row.householdID = old }
        for row in try context.fetch(FetchDescriptor<LocalPlantingEvent>()) where row.householdID == fixture { row.householdID = old }
        for row in try context.fetch(FetchDescriptor<LocalJournalEntry>()) where row.householdID == fixture { row.householdID = old }
        for row in try context.fetch(FetchDescriptor<LocalCloudKitDeletion>()) where row.householdID == fixture { row.householdID = old }
        for row in try context.fetch(FetchDescriptor<LocalAssistantThread>()) where row.householdID == fixture { row.householdID = old }
        for row in try context.fetch(FetchDescriptor<LocalAssistantKeyStatus>()) { row.id = "household_\(old)_anthropic" }
        for row in try context.fetch(FetchDescriptor<LocalJournalRecoveryItem>()) {
            row.scopeKey = recoveryScope ?? "\(old)|\(signedIn)"
            // Kept private by the user: not restored, still removed with the scope. Tests that restore
            // add their own pending items.
            row.status = "kept"
        }

        let other = self.other
        context.insert(LocalSeed(id: "other_seed", householdID: other, state: .active, packetCount: 1, source: .store,
                                 customName: "Other", createdAt: 1, updatedAt: 1))
        context.insert(LocalBed(id: "other_bed", householdID: other, name: "Other bed", createdAt: 1, updatedAt: 1))
        context.insert(LocalJournalEntry(id: "other_je", householdID: other, occurredOn: "2025-01-01", body: "x",
                                         seedID: nil, bedID: nil, plantingEventID: nil, createdAt: 1, updatedAt: 1, deletedAt: nil))
        context.insert(LocalJournalEntryPhoto(id: "other_jp", entryID: "other_je", storageKey: nil, sortOrder: 0,
                                              width: nil, height: nil, createdAt: 1, updatedAt: 1))
        context.insert(LocalJournalChecklistItem(id: "other_jc", entryID: "other_je", text: "t", completed: false,
                                                 sortOrder: 0, updatedAt: 1))
        context.insert(LocalPlantingEvent(id: "other_pe", householdID: other, bedID: nil, seedID: nil, kindRaw: "sowing",
                                          plannedFor: "2026-01-01", createdAt: 1, updatedAt: 1))
        context.insert(LocalPetDeparture(plantingEventID: "other_pe", goodbyeNoteJSON: nil, reason: "x",
                                         createdAt: 1, updatedAt: 1, departedAt: 1))
        context.insert(LocalPetMoodSnapshot(plantingEventID: "other_pe", dayYMD: "2026-01-02", moodLabel: "fine",
                                            compositeScore: 70, createdAt: 1))
        context.insert(LocalAssistantThread(id: "other_thread", householdID: other, title: "t", threadKind: "chat",
                                            createdAt: 1, updatedAt: 1, deletedAt: nil))
        context.insert(LocalAssistantMessage(id: "other_msg", threadID: "other_thread", role: "user", contentJSON: "[]",
                                             pageContext: nil, model: nil, usageJSON: nil, createdAt: 1))
        context.insert(LocalAssistantToolCall(id: "other_tool", messageID: "other_msg", threadID: "other_thread",
                                              toolName: "t", argsJSON: "{}", status: "done", resultJSON: nil,
                                              proposedChangeJSON: nil, confirmedAt: nil, createdAt: 1, updatedAt: 1))
        context.insert(LocalAssistantKeyStatus(id: "household_\(other)_anthropic", provider: "anthropic",
                                               configured: true, updatedAt: 1))
        context.insert(LocalCloudKitDeletion(scopeID: "x|other", householdID: other, recordName: "seed:other", createdAt: 1))
        context.insert(LocalJournalRecoveryItem(id: "other_rec", scopeKey: "\(other)|hh", snapshotJSON: "{}",
                                                detectedAt: 1, status: "pending"))
        try context.save()
    }

    /// Bytes for the fixture's four photos: one pending, one cached, one corrupt, one absent.
    func seedPhotoBytes() throws {
        let pending = PhotoByteStore(lifetime: .pendingUploads, householdID: old)
        let cache = PhotoByteStore(lifetime: .cache, householdID: old)
        try pending.write(Data("seed-local".utf8), for: SeedkeepRecordNames.seedPhoto("seed_photo_local_ck"))
        try cache.write(Data("journal-local".utf8), for: SeedkeepRecordNames.journalEntryPhoto("journal_photo_local_ck"))
        // A file whose bytes no longer match its own hash: unusable, so counted as not on the device.
        let ref = try pending.write(Data("legacy".utf8), for: SeedkeepRecordNames.seedPhoto("photo_legacy"))
        try Data("tampered".utf8).write(to: ref.url)
        // journal "jp_legacy": no bytes at all.
    }

    func seedDurableState() throws {
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        for name in ["engine", "synced", "failed", "unavailable", "shared"] {
            try Data("x".utf8).write(to: files.appendingPathComponent("\(name)-\(old)"))
            try Data("y".utf8).write(to: files.appendingPathComponent("\(name)-\(other)"))
        }
        defaults.set(true, forKey: GardenJournalExecutor.migrationMarkerKey(householdID: old))
        defaults.set(true, forKey: GardenJournalExecutor.migrationMarkerKey(householdID: other))
        defaults.set(true, forKey: ParticipantRowRecovery.markerKeyPrefix + "\(old)|\(signedIn)")
        defaults.set(true, forKey: ParticipantRowRecovery.markerKeyPrefix + "\(other)|hh")
        defaults.set(Date(timeIntervalSince1970: 5_000), forKey: "seedkeep.watering.lastFire.\(old)")
        defaults.set(Date(timeIntervalSince1970: 6_000), forKey: "seedkeep.watering.lastFire.\(other)")
    }

    // MARK: - Reading

    struct Snapshot: Equatable {
        var locations: Set<String> = [], tags: Set<String> = [], seeds: Set<String> = [], seedPhotos: Set<String> = []
        var beds: Set<String> = [], plantings: Set<String> = [], entries: Set<String> = []
        var entryPhotos: Set<String> = [], checklist: Set<String> = [], departures: Set<String> = [], moods: Set<String> = []
        var deletions: Set<String> = [], threads: Set<String> = [], messages: Set<String> = [], toolCalls: Set<String> = []
        var keyStatuses: Set<String> = []
    }

    /// Everything that belongs to `household`: its rows by household, its children by parent, its scoped rows.
    func snapshot(_ household: String) throws -> Snapshot {
        let context = ModelContext(container)
        var s = Snapshot()
        s.locations = Set(try context.fetch(FetchDescriptor<LocalLocation>()).filter { $0.householdID == household }.map(\.id))
        s.tags = Set(try context.fetch(FetchDescriptor<LocalTag>()).filter { $0.householdID == household }.map(\.id))
        s.seeds = Set(try context.fetch(FetchDescriptor<LocalSeed>()).filter { $0.householdID == household }.map(\.id))
        s.seedPhotos = Set(try context.fetch(FetchDescriptor<LocalSeedPhoto>()).filter { $0.householdID == household }.map(\.id))
        s.beds = Set(try context.fetch(FetchDescriptor<LocalBed>()).filter { $0.householdID == household }.map(\.id))
        let plantings = try context.fetch(FetchDescriptor<LocalPlantingEvent>()).filter { $0.householdID == household }
        s.plantings = Set(plantings.map(\.id))
        let entries = try context.fetch(FetchDescriptor<LocalJournalEntry>()).filter { $0.householdID == household }
        s.entries = Set(entries.map(\.id))
        s.entryPhotos = Set(try context.fetch(FetchDescriptor<LocalJournalEntryPhoto>()).filter { s.entries.contains($0.entryID) }.map(\.id))
        s.checklist = Set(try context.fetch(FetchDescriptor<LocalJournalChecklistItem>()).filter { s.entries.contains($0.entryID) }.map(\.id))
        s.departures = Set(try context.fetch(FetchDescriptor<LocalPetDeparture>()).filter { s.plantings.contains($0.plantingEventID) }.map(\.plantingEventID))
        s.moods = Set(try context.fetch(FetchDescriptor<LocalPetMoodSnapshot>()).filter { s.plantings.contains($0.plantingEventID) }.map(\.id))
        s.deletions = Set(try context.fetch(FetchDescriptor<LocalCloudKitDeletion>()).filter { $0.householdID == household }.map(\.id))
        let threads = try context.fetch(FetchDescriptor<LocalAssistantThread>()).filter { $0.householdID == household }
        s.threads = Set(threads.map(\.id))
        s.messages = Set(try context.fetch(FetchDescriptor<LocalAssistantMessage>()).filter { s.threads.contains($0.threadID) }.map(\.id))
        s.toolCalls = Set(try context.fetch(FetchDescriptor<LocalAssistantToolCall>()).filter { s.threads.contains($0.threadID) }.map(\.id))
        s.keyStatuses = Set(try context.fetch(FetchDescriptor<LocalAssistantKeyStatus>()).filter { $0.id.hasPrefix("household_\(household)_") }.map(\.id))
        return s
    }

    func count<T: PersistentModel>(_ type: T.Type) throws -> Int {
        try ModelContext(container).fetchCount(FetchDescriptor<T>())
    }

    func recoveryItems() throws -> [LocalJournalRecoveryItem] {
        try ModelContext(container).fetch(FetchDescriptor<LocalJournalRecoveryItem>())
    }
}
