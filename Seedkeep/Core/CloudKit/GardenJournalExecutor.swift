import CloudKit
import CryptoKit
import Foundation
import SwiftData
import SeedkeepKit
import SeedkeepCloudKit

// N2-E (G3) §7: the steps of a keep, a discard and the silent re-home. The runner (`GardenGuardRunner`)
// owns execution: one journal per garden at a time, after it has quiesced the writers. This file holds
// only the steps and their checkpoints.
//
// Every step is idempotent and writes its checkpoint to the guard after its effect, so a crash between
// the two repeats the step safely. A failed step keeps its checkpoint (it is simply not written) and the
// runner offers Try again. The last step of each action is one guard write that also closes the journal.

/// What the runner needs from an executor.
@MainActor
protocol GardenJournalExecuting: AnyObject {
    /// Cancels and awaits the work that could race the journal (the scan resume, the weather refresh).
    func quiesceWriters() async
    /// Revalidates that the resolved account still owns this open journal after an await.
    func isCurrent(account: String, householdID: String, scopeEpoch: Int) -> Bool
    /// Runs the open journal of `householdID` to its end, or until a step throws.
    func run(account: String, householdID: String, scopeEpoch: Int) async throws
    /// Called after a discard journal task has ended, so identity resolution cannot make the task wait on itself.
    func didDiscard(account: String, householdID: String, scopeEpoch: Int) async -> Bool
}

/// The disposition table of contract §7, by model, checked against `SeedkeepSchema.all` by a test:
/// a new `@Model` has to be given a place here before the build is green.
enum GardenDisposition {
    enum OnKeep: Equatable {
        /// Every row moves to the new household (live and tombstoned), IDs and references unchanged.
        case rehomed
        /// No household column: the row follows its parent entry or planting event.
        case followsParent
        /// Deleted: the old scope's intents die with it (the new scope has no synced state).
        case deleted
        /// Pending snapshots are restored into the new garden through `ParticipantRowRecovery`, then deleted.
        case restoredThenDeleted
        case leftAlone
    }
    enum OnDiscard: Equatable {
        /// Deleted by household (children captured before their parents are deleted).
        case deleted
        /// Deleted with their parent entry or planting event.
        case deletedWithParent
        /// Deleted for the old scope only.
        case deletedForScope
        /// Server-era and inert (T1): deleted for every household, as an explicit cleanup.
        case deletedGlobally
        /// Deleted for the discarded household only (server-era assistant rows).
        case deletedForHousehold
        case unchanged
    }

    static let table: [(model: any PersistentModel.Type, keep: OnKeep, discard: OnDiscard)] = [
        (LocalLocation.self, .rehomed, .deleted),
        (LocalTag.self, .rehomed, .deleted),
        (LocalSeed.self, .rehomed, .deleted),
        (LocalSeedPhoto.self, .rehomed, .deleted),
        (LocalBed.self, .rehomed, .deleted),
        (LocalPlantingEvent.self, .rehomed, .deleted),
        (LocalJournalEntry.self, .rehomed, .deleted),
        (LocalJournalEntryPhoto.self, .followsParent, .deletedWithParent),
        (LocalJournalChecklistItem.self, .followsParent, .deletedWithParent),
        (LocalPetDeparture.self, .followsParent, .deletedWithParent),
        (LocalPetMoodSnapshot.self, .followsParent, .deletedWithParent),
        (LocalCloudKitDeletion.self, .deleted, .deletedForScope),
        (LocalJournalRecoveryItem.self, .restoredThenDeleted, .deletedForScope),
        (LocalSyncCursor.self, .leftAlone, .deletedGlobally),
        (LocalPendingWrite.self, .leftAlone, .deletedGlobally),
        (LocalAssistantThread.self, .leftAlone, .deletedForHousehold),
        (LocalAssistantMessage.self, .leftAlone, .deletedForHousehold),
        (LocalAssistantToolCall.self, .leftAlone, .deletedForHousehold),
        (LocalAssistantKeyStatus.self, .leftAlone, .deletedForHousehold),
        (LocalRecommendation.self, .leftAlone, .unchanged),
        (LocalForecastSnapshot.self, .leftAlone, .unchanged),
        (LocalCatalogCorrection.self, .leftAlone, .unchanged),
    ]
}

@MainActor
struct GardenJournalDependencies {
    var container: ModelContainer
    /// Holds the migration markers, recovery markers and the watering ledger (`.standard` live).
    var defaults: UserDefaults
    var scanStagingRoot: URL
    /// The old scope's durable CloudKit files: engine state and its cleanup marker, synced state,
    /// the failed-photo and unavailable-photo rosters.
    var durableFiles: @MainActor (_ householdID: String, _ participant: GardenGuardBinding.Participant?) -> [URL]
        = GardenJournalExecutor.defaultDurableFiles
    var removeNotifications: @MainActor () -> Void = {}
    var quiesce: @MainActor () async -> Void = {}
    /// The runner's caller supplies the currently resolved identity. Fakes default to current.
    var isCurrent: @MainActor (_ account: String, _ householdID: String, _ scopeEpoch: Int) -> Bool = { _, _, _ in true }
    /// A keep (or silent re-home) wrote its binding: derive the defaults and publish the new garden.
    var didBind: @MainActor (_ account: String) -> Void = { _ in }
    /// A discard cleared its binding: derive the defaults, then resolve the session again.
    var didDiscard: @MainActor (_ account: String, _ householdID: String, _ scopeEpoch: Int) async -> Bool = { _, _, _ in true }
    var now: @MainActor () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }

    // Seams for tests: a crash after an effect and before its checkpoint, a failed model commit, a
    // failed byte write.
    var beforePhotoFetch: @MainActor (GardenPhotoRows.Fetch) throws -> Void = { _ in }
    var afterEffect: (@MainActor (_ step: String) throws -> Void)?
    var commit: @MainActor (ModelContext) throws -> Void = { try $0.save() }
    var writeBytes: @Sendable (PhotoByteStore, Data, String) throws -> PhotoByteStore.Ref = { store, data, name in
        try store.write(data, for: name)
    }
}

@MainActor
final class GardenJournalExecutor: GardenJournalExecuting {
    /// A keep's steps, in the contract's order. The binding (the last step) is one guard write that
    /// also closes the journal.
    nonisolated static let keepSteps = ["photos", "scans", "rows", "recovery", "state", "bytes"]
    /// A discard's steps. The clearing of the binding is the closing guard write.
    nonisolated static let discardSteps = ["rows", "bytes", "state"]

    let store: GardenGuardStore
    var deps: GardenJournalDependencies

    /// How many photo rows the last keep dropped for having no bytes on the device (a test and report probe).
    private(set) var lastMissingPhotoCount = 0

    init(store: GardenGuardStore, deps: GardenJournalDependencies) {
        self.store = store
        self.deps = deps
    }

    func quiesceWriters() async { await deps.quiesce() }

    func isCurrent(account: String, householdID: String, scopeEpoch: Int) -> Bool {
        deps.isCurrent(account, householdID, scopeEpoch)
    }

    func didDiscard(account: String, householdID: String, scopeEpoch: Int) async -> Bool {
        await deps.didDiscard(account, householdID, scopeEpoch)
    }

    // MARK: - Run

    func run(account: String, householdID: String, scopeEpoch: Int = 0) async throws {
        guard store.isReadable, let record = store.journal(account, householdID), record.phase == .journaled,
              let action = record.action else { return }
        let discarding = action == .discard
        if !discarding && record.replacementID == nil { throw GardenGuardError.missingJournal }
        for step in discarding ? Self.discardSteps : Self.keepSteps {
            try Task.checkCancellation()
            guard deps.isCurrent(account, householdID, scopeEpoch), store.isReadable else { throw CancellationError() }
            guard let current = store.journal(account, householdID), current.phase == .journaled else { return }
            if current.hasCompleted(step) { continue }
            try await perform(step, account: account, householdID: householdID, record: current, discarding: discarding)
            try Task.checkCancellation()
            guard deps.isCurrent(account, householdID, scopeEpoch),
                  store.journal(account, householdID)?.phase == .journaled else { throw CancellationError() }
            try deps.afterEffect?(step)
            try store.checkpoint(account, householdID, step: step)
        }
        try Task.checkCancellation()
        guard deps.isCurrent(account, householdID, scopeEpoch) else { throw CancellationError() }
        guard let last = store.journal(account, householdID), last.phase == .journaled else { return }
        if discarding {
            try store.completeDiscard(account, householdID: householdID)
            try deps.afterEffect?("clear")
        } else {
            let binding = newBinding(account: account, from: householdID, to: last.replacementID ?? "")
            try store.completeRehome(account, from: householdID, binding: binding)
            try deps.afterEffect?("bind")
            deps.didBind(account)
        }
    }

    /// The new owned binding. An owned garden keeps its name and creation time; a shared garden's copy
    /// is a new garden of the user's own.
    private func newBinding(account: String, from old: String, to new: String) -> GardenGuardBinding {
        let now = deps.now()
        if let binding = store.latestBinding(account), binding.participant == nil, binding.household.id == old {
            return GardenGuardBinding(
                household: .init(id: new, name: binding.household.name, createdAt: binding.household.createdAt, updatedAt: now),
                participant: nil)
        }
        return GardenGuardBinding(household: .init(id: new, name: "My garden", createdAt: now, updatedAt: now), participant: nil)
    }

    /// The shared garden's reference when the old garden is the one the binding shares.
    private func sharedScope(_ account: String, _ householdID: String) -> GardenGuardBinding.Participant? {
        guard let binding = store.latestBinding(account), let participant = binding.participant,
              binding.gardenHouseholdID == householdID else { return nil }
        return participant
    }

    private func perform(
        _ step: String, account: String, householdID old: String, record: GardenGoneRecord, discarding: Bool
    ) async throws {
        let new = record.replacementID ?? ""
        switch (discarding, step) {
        case (false, "photos"): try await copyPhotos(from: old, to: new)
        case (false, "scans"): try ScanPhotoStaging.retarget(from: old, to: new, root: deps.scanStagingRoot)
        case (false, "rows"): try rehomeRows(from: old, to: new)
        case (false, "recovery"): try restoreRecovery(account: account, from: old, to: new)
        case (false, "state"): try moveState(account: account, from: old, to: new)
        case (false, "bytes"): try PhotoByteStore.purgeHousehold(old)
        case (true, "rows"): try deleteRows(of: old)
        case (true, "bytes"):
            try PhotoByteStore.purgeHousehold(old)
            try ScanPhotoStaging.purge(householdID: old, root: deps.scanStagingRoot)
        case (true, "state"): try discardState(account: account, of: old)
        default: break
        }
    }

    // MARK: - Keep

    /// Copies available photo bytes and verifies each hash. Unavailable or hash-invalid photo rows are
    /// dropped from the same SwiftData save that re-homes their parents.
    private func copyPhotos(from old: String, to new: String) async throws {
        let photos = try GardenPhotoRows.recordNames(container: deps.container, household: old, beforeFetch: deps.beforePhotoFetch)
        let write = deps.writeBytes
        lastMissingPhotoCount = try await Task.detached(priority: .userInitiated) {
            try Self.copyPhotoBytes(photos: photos, to: new, write: write)
        }.value
    }

    nonisolated static func copyPhotoBytes(
        photos: [GardenPhotoRows.Photo], to new: String,
        write: @Sendable (PhotoByteStore, Data, String) throws -> PhotoByteStore.Ref
    ) throws -> Int {
        var missing = 0
        for photo in photos {
            var copied = false
            for lifetime in [PhotoByteStore.Lifetime.pendingUploads, .cache] {
                let source = PhotoByteStore(lifetime: lifetime, householdID: photo.sourceHouseholdID)
                guard let ref = source.ref(for: photo.recordName),
                      let data = try? Data(contentsOf: ref.url), Self.sha256(data) == ref.sha256 else { continue }
                let destination = PhotoByteStore(lifetime: lifetime, householdID: new)
                let written = try write(destination, data, photo.recordName)
                guard written.sha256 == ref.sha256,
                      let stored = try? Data(contentsOf: written.url), Self.sha256(stored) == ref.sha256 else {
                    throw GardenJournalError.photoVerificationFailed(recordName: photo.recordName)
                }
                copied = true
            }
            if !copied { missing += 1 }
        }
        return missing
    }

    nonisolated static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Every row of the old household moves to the new one in ONE save: live and tombstoned, IDs and
    /// references unchanged, so no reference points at a dropped parent. The old scope's pending
    /// CloudKit deletions go in the same save. Children have no household column and follow.
    private func rehomeRows(from old: String, to new: String) throws {
        let photos = try GardenPhotoRows.recordNames(container: deps.container, household: old,
                                                     beforeFetch: deps.beforePhotoFetch)
        let unavailablePhotos = Set(photos.filter {
            !GardenInventory.hasBytes($0.recordName, household: $0.sourceHouseholdID)
        }.map(\.recordName))
        let context = ModelContext(deps.container)
        for row in try context.fetch(FetchDescriptor<LocalLocation>(predicate: #Predicate { $0.householdID == old })) { row.householdID = new }
        for row in try context.fetch(FetchDescriptor<LocalTag>(predicate: #Predicate { $0.householdID == old })) { row.householdID = new }
        for row in try context.fetch(FetchDescriptor<LocalSeed>(predicate: #Predicate { $0.householdID == old })) { row.householdID = new }
        for row in try context.fetch(FetchDescriptor<LocalSeedPhoto>(predicate: #Predicate { $0.householdID == old })) { row.householdID = new }
        for row in try context.fetch(FetchDescriptor<LocalBed>(predicate: #Predicate { $0.householdID == old })) { row.householdID = new }
        for row in try context.fetch(FetchDescriptor<LocalPlantingEvent>(predicate: #Predicate { $0.householdID == old })) { row.householdID = new }
        for row in try context.fetch(FetchDescriptor<LocalJournalEntry>(predicate: #Predicate { $0.householdID == old })) { row.householdID = new }
        for intent in try oldScopeDeletions(of: old, in: context) { context.delete(intent) }
        // Photo rows with no usable bytes on the device are dropped from the copy, in this same save.
        // The old bytes are still in place (they go in the later `bytes` step), so a rerun after a crash
        // judges exactly as the first run did, and the count equals the choice screen's.
        let entryIDs = Set(try context.fetch(FetchDescriptor<LocalJournalEntry>(
            predicate: #Predicate { $0.householdID == new })).map(\.id))
        for photo in try context.fetch(FetchDescriptor<LocalSeedPhoto>(predicate: #Predicate { $0.householdID == new }))
        where unavailablePhotos.contains(SeedkeepRecordNames.seedPhoto(photo.id)) {
            context.delete(photo)
        }
        for photo in try context.fetch(FetchDescriptor<LocalJournalEntryPhoto>()) where entryIDs.contains(photo.entryID)
            && unavailablePhotos.contains(SeedkeepRecordNames.journalEntryPhoto(photo.id)) {
            context.delete(photo)
        }
        try deps.commit(context)
    }

    private func oldScopeDeletions(of old: String, in context: ModelContext) throws -> [LocalCloudKitDeletion] {
        let owned = HouseholdCloudCoordinator.ownerScopeID(householdID: old)
        let sharedScopeSuffix = "|\(SeedkeepZoneProvisioner.zoneName(householdID: old))|"
        return try context.fetch(FetchDescriptor<LocalCloudKitDeletion>()).filter {
            $0.householdID == old || $0.scopeID == owned
                || ($0.scopeID.contains("|shared|") && $0.scopeID.contains(sharedScopeSuffix))
        }
    }

    /// Pending recovery snapshots of the old scope become journal entries of the new garden, through
    /// `ParticipantRowRecovery`'s low-level helpers with the item's original scope. Their atomic status
    /// change lets a retry restore only what is still pending. Then every item of the scope is removed.
    private func restoreRecovery(account: String, from old: String, to new: String) throws {
        let prefix = "\(old)|"
        let photos = try GardenPhotoRows.recordNames(container: deps.container, household: old,
                                                     beforeFetch: deps.beforePhotoFetch)
        let unavailablePhotos = Set(photos.filter {
            !GardenInventory.hasBytes($0.recordName, household: $0.sourceHouseholdID)
        }.map(\.recordName))
        let context = ModelContext(deps.container)
        let items = try context.fetch(FetchDescriptor<LocalJournalRecoveryItem>()).filter { $0.scopeKey.hasPrefix(prefix) }
        for item in items where item.status == "pending" {
            let id = item.id
            let scope = item.scopeKey
            if try ParticipantRowRecovery.shareLiveEntryIfPresent(
                itemID: id, ownerZoneHouseholdID: new, currentScopeKey: scope, container: deps.container,
                photoRecordNamesToDrop: unavailablePhotos, save: deps.commit) { continue }
            do {
                try ParticipantRowRecovery.recreateFromSnapshotAtomically(
                    itemID: id, ownerZoneHouseholdID: new, currentScopeKey: scope, container: deps.container)
            } catch let error as SeedkeepError where error.code == "invalid_snapshot" {
                // A snapshot that can't be read can never be restored: it must not hold the keep up.
                continue
            }
        }
        let removal = ModelContext(deps.container)
        for item in try removal.fetch(FetchDescriptor<LocalJournalRecoveryItem>()) where item.scopeKey.hasPrefix(prefix) {
            removal.delete(item)
        }
        try deps.commit(removal)
    }

    /// The old scope's durable CloudKit files, its markers and its per-household keys go; the new ID's
    /// migration marker is set (migration doesn't run: the ordinary first sync uploads everything, as
    /// the new scope has no synced state); the watering ledger moves.
    private func moveState(account: String, from old: String, to new: String) throws {
        try removeScope(account: account, of: old)
        deps.defaults.set(true, forKey: Self.migrationMarkerKey(householdID: new))
        WateringLedger.move(from: old, to: new, in: deps.defaults)
    }

    // MARK: - Discard

    /// Deletes everything of the old garden in ONE save, children captured before their parents are
    /// deleted: its rows, their children, the old scope's pending deletions and recovery items, the
    /// household's server-era assistant rows, and (an explicit global cleanup) every inert cursor and
    /// pending write.
    private func deleteRows(of old: String) throws {
        let context = ModelContext(deps.container)
        let entries = try context.fetch(FetchDescriptor<LocalJournalEntry>(predicate: #Predicate { $0.householdID == old }))
        let plantings = try context.fetch(FetchDescriptor<LocalPlantingEvent>(predicate: #Predicate { $0.householdID == old }))
        let entryIDs = Set(entries.map(\.id))
        let plantingIDs = Set(plantings.map(\.id))
        let entryPhotos = try context.fetch(FetchDescriptor<LocalJournalEntryPhoto>()).filter { entryIDs.contains($0.entryID) }
        let checklist = try context.fetch(FetchDescriptor<LocalJournalChecklistItem>()).filter { entryIDs.contains($0.entryID) }
        let departures = try context.fetch(FetchDescriptor<LocalPetDeparture>()).filter { plantingIDs.contains($0.plantingEventID) }
        let moods = try context.fetch(FetchDescriptor<LocalPetMoodSnapshot>()).filter { plantingIDs.contains($0.plantingEventID) }

        let threads = try context.fetch(FetchDescriptor<LocalAssistantThread>(predicate: #Predicate { $0.householdID == old }))
        let threadIDs = Set(threads.map(\.id))
        let messages = try context.fetch(FetchDescriptor<LocalAssistantMessage>()).filter { threadIDs.contains($0.threadID) }
        let toolCalls = try context.fetch(FetchDescriptor<LocalAssistantToolCall>()).filter { threadIDs.contains($0.threadID) }
        let keyPrefix = "household_\(old)_"
        let keyStatuses = try context.fetch(FetchDescriptor<LocalAssistantKeyStatus>()).filter { $0.id.hasPrefix(keyPrefix) }

        let recoveryPrefix = "\(old)|"
        let recovery = try context.fetch(FetchDescriptor<LocalJournalRecoveryItem>()).filter { $0.scopeKey.hasPrefix(recoveryPrefix) }

        for row in entryPhotos { context.delete(row) }
        for row in checklist { context.delete(row) }
        for row in departures { context.delete(row) }
        for row in moods { context.delete(row) }
        for row in messages { context.delete(row) }
        for row in toolCalls { context.delete(row) }
        for row in threads { context.delete(row) }
        for row in keyStatuses { context.delete(row) }
        for row in recovery { context.delete(row) }
        for row in try oldScopeDeletions(of: old, in: context) { context.delete(row) }
        for row in entries { context.delete(row) }
        for row in plantings { context.delete(row) }
        for row in try context.fetch(FetchDescriptor<LocalLocation>(predicate: #Predicate { $0.householdID == old })) { context.delete(row) }
        for row in try context.fetch(FetchDescriptor<LocalTag>(predicate: #Predicate { $0.householdID == old })) { context.delete(row) }
        for row in try context.fetch(FetchDescriptor<LocalSeed>(predicate: #Predicate { $0.householdID == old })) { context.delete(row) }
        for row in try context.fetch(FetchDescriptor<LocalSeedPhoto>(predicate: #Predicate { $0.householdID == old })) { context.delete(row) }
        for row in try context.fetch(FetchDescriptor<LocalBed>(predicate: #Predicate { $0.householdID == old })) { context.delete(row) }
        // Server-era and inert since T1: no code reads them, their payloads can't always be tied to a
        // household and can hold garden names. An explicit global cleanup, not garden-scoped.
        for row in try context.fetch(FetchDescriptor<LocalSyncCursor>()) { context.delete(row) }
        for row in try context.fetch(FetchDescriptor<LocalPendingWrite>()) { context.delete(row) }
        try deps.commit(context)
    }

    private func discardState(account: String, of old: String) throws {
        try removeScope(account: account, of: old)
        WateringLedger.remove(householdID: old, in: deps.defaults)
        deps.removeNotifications()
    }

    // MARK: - Shared

    /// The old scope's durable CloudKit files, migration marker and recovery markers.
    private func removeScope(account: String, of old: String) throws {
        let participant = sharedScope(account, old)
        for url in deps.durableFiles(old, participant) where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        deps.defaults.removeObject(forKey: Self.migrationMarkerKey(householdID: old))
        let recoveryPrefix = ParticipantRowRecovery.markerKeyPrefix + "\(old)|"
        for key in deps.defaults.dictionaryRepresentation().keys where key.hasPrefix(recoveryPrefix) {
            deps.defaults.removeObject(forKey: key)
        }
    }

    static func migrationMarkerKey(householdID: String) -> String {
        "\(HouseholdCloudCoordinator.migratedKeyPrefix)\(HouseholdCloudCoordinator.cloudKitEnvironmentTag).\(householdID)"
    }

    /// The durable files the coordinator keeps for a garden: owner scope always, shared scope when the
    /// binding shares it.
    static func defaultDurableFiles(householdID: String, participant: GardenGuardBinding.Participant?) -> [URL] {
        let state = HouseholdCloudCoordinator.ownerStateTokenURL(householdID: householdID)
        var urls = [
            state, HouseholdCloudCoordinator.accountCleanupMarkerURL(forStateURL: state),
            HouseholdCloudCoordinator.ownerSyncedStateURL(householdID: householdID),
            HouseholdCloudCoordinator.ownerFailedPhotoStateURL(householdID: householdID),
            HouseholdCloudCoordinator.ownerUnavailablePhotoStateURL(householdID: householdID),
        ]
        if let participant {
            let zone = CKRecordZone.ID(zoneName: participant.zoneName, ownerName: participant.ownerName)
            let shared = HouseholdCloudCoordinator.participantStateTokenURL(ownerZoneID: zone)
            urls += [
                shared, HouseholdCloudCoordinator.accountCleanupMarkerURL(forStateURL: shared),
                HouseholdCloudCoordinator.participantSyncedStateURL(ownerZoneID: zone),
                HouseholdCloudCoordinator.participantFailedPhotoStateURL(ownerZoneID: zone),
                HouseholdCloudCoordinator.participantUnavailablePhotoStateURL(ownerZoneID: zone),
            ]
        }
        return urls
    }
}

enum GardenJournalError: Error, LocalizedError, Equatable {
    case photoVerificationFailed(recordName: String)

    var errorDescription: String? {
        switch self {
        case .photoVerificationFailed:
            return "A photo couldn't be copied and checked. Nothing was lost."
        }
    }
}

// MARK: - What the device still has

/// What the choice screen counts: the garden's live rows still on the device, and how many of its
/// photos have no bytes here (and so can't be kept).
struct GardenInventory: Equatable, Sendable {
    var seeds = 0
    var beds = 0
    var journalEntries = 0
    var photos = 0
    var photosNotOnDevice = 0

    @MainActor
    static func count(
        container: ModelContainer, householdID: String,
        beforePhotoFetch: @MainActor (GardenPhotoRows.Fetch) throws -> Void = { _ in }
    ) async throws -> GardenInventory {
        let context = ModelContext(container)
        var inventory = GardenInventory()
        let seeds = try context.fetch(FetchDescriptor<LocalSeed>(
            predicate: #Predicate { $0.householdID == householdID && $0.deletedAt == nil }))
        let beds = try context.fetch(FetchDescriptor<LocalBed>(
            predicate: #Predicate { $0.householdID == householdID && $0.deletedAt == nil }))
        let entries = try context.fetch(FetchDescriptor<LocalJournalEntry>(
            predicate: #Predicate { $0.householdID == householdID && $0.deletedAt == nil }))
        inventory.seeds = seeds.count
        inventory.beds = beds.count
        inventory.journalEntries = entries.count
        let photos = try GardenPhotoRows.recordNames(container: container, household: householdID, beforeFetch: beforePhotoFetch)
        inventory.photos = photos.count
        inventory.photosNotOnDevice = await Task.detached(priority: .userInitiated) {
            photos.filter { !hasBytes($0.recordName, household: $0.sourceHouseholdID) }.count
        }.value
        return inventory
    }

    /// Whether the photo has bytes here that pass their own hash (what a copy could keep).
    nonisolated static func hasBytes(_ recordName: String, household: String) -> Bool {
        for lifetime in [PhotoByteStore.Lifetime.pendingUploads, .cache] {
            let store = PhotoByteStore(lifetime: lifetime, householdID: household)
            if let ref = store.ref(for: recordName), let data = try? Data(contentsOf: ref.url),
               GardenJournalExecutor.sha256(data) == ref.sha256 { return true }
        }
        return false
    }
}

/// Both the disclosure and the journal enumerate exactly these rows. A failed fetch is never absence.
@MainActor
enum GardenPhotoRows {
    enum Fetch: CaseIterable, Sendable { case seedPhotos, entries, journalPhotos }
    struct Photo: Hashable, Sendable {
        let recordName: String
        let sourceHouseholdID: String
    }

    static func recordNames(
        container: ModelContainer, household: String,
        beforeFetch: @MainActor (Fetch) throws -> Void = { _ in }
    ) throws -> [Photo] {
        let context = ModelContext(container)
        try beforeFetch(.seedPhotos)
        let seedPhotos = try context.fetch(FetchDescriptor<LocalSeedPhoto>(
            predicate: #Predicate { $0.householdID == household }))
        try beforeFetch(.entries)
        let entries = try context.fetch(FetchDescriptor<LocalJournalEntry>(
            predicate: #Predicate { $0.householdID == household }))
        let entryIDs = Set(entries.map(\.id))
        try beforeFetch(.journalPhotos)
        let journalPhotos = try context.fetch(FetchDescriptor<LocalJournalEntryPhoto>())
            .filter { entryIDs.contains($0.entryID) }
        var photos = seedPhotos.map { Photo(recordName: SeedkeepRecordNames.seedPhoto($0.id), sourceHouseholdID: household) }
            + journalPhotos.map { Photo(recordName: SeedkeepRecordNames.journalEntryPhoto($0.id), sourceHouseholdID: household) }

        // A pending recovery item can hold a live row parked under a different household. Include its
        // children before the later recovery step changes the parent's household. Snapshots contain
        // no photo rows, and private/kept or unrelated recovery items are never inferred here.
        let recoveryItems = try context.fetch(FetchDescriptor<LocalJournalRecoveryItem>())
            .filter { $0.scopeKey.hasPrefix("\(household)|") && $0.status == "pending" }
        guard !recoveryItems.isEmpty else { return Array(Set(photos)) }
        let recoverableIDs = Set(recoveryItems.map(\.id))
        let liveEntries = try context.fetch(FetchDescriptor<LocalJournalEntry>())
            .filter { recoverableIDs.contains($0.id) }
        let sourceByEntry = Dictionary(liveEntries.map { ($0.id, $0.householdID) }, uniquingKeysWith: { first, _ in first })
        let allEntryPhotos = try context.fetch(FetchDescriptor<LocalJournalEntryPhoto>())
        photos += allEntryPhotos.compactMap { photo in
            guard let source = sourceByEntry[photo.entryID] else { return nil }
            return Photo(recordName: SeedkeepRecordNames.journalEntryPhoto(photo.id), sourceHouseholdID: source)
        }
        return Array(Set(photos))
    }
}
