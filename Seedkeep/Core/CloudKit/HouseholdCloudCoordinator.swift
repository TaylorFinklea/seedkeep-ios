#if canImport(CloudKit)
import CloudKit
import Foundation
import Observation
import SwiftData
import SeedkeepKit
import SeedkeepCloudKit

/// R1 live-engine wiring — the single app-lifetime bridge between SwiftData (the durable source of
/// truth) and the household `CKSyncEngine` shared zone. Mirrors SimmerSmith's `HouseholdSession`,
/// adapted so SwiftData (not an in-memory typed store) is the truth:
///
///   - `sync()` reconciles: pull (engine.fetchChanges → buffer → project into SwiftData with an
///     updatedAt-LWW gate) then push (scan SwiftData for records not already confirmed synced per the
///     durable per-record synced-state, exclude ones just applied this pass to avoid echo, encode,
///     engine.save, drain).
///   - `ensureStarted()` (once): gate on iCloud availability, provision zone/household/share (owner),
///     wire the merger + callbacks, first fetch, run the one-time migration (AC3, receipt-gated).
///   - `handleAccountChange` wipes SwiftData + the engine state token on sign-out/switch (AC5).
///
/// The engine is held behind `HouseholdRecordSyncing` so this whole class unit-tests against a fake
/// (no CKContainer / iCloud account). `provisioner == nil` (test path) skips live provisioning.
///
/// GATED OFF in production by `FeatureFlags.cloudKitHouseholdSyncEnabled` (additive; the legacy
/// server `SyncEngine` is unchanged until the device-proven cutover — see the 2026-06-28 spec).
@MainActor
@Observable
final class HouseholdCloudCoordinator {

    // MARK: Owned planes
    private let engine: HouseholdRecordSyncing
    private let zoneID: CKRecordZone.ID
    private let householdID: String
    private let householdName: String
    private let householdCreatedAt: Int64
    private let householdUpdatedAt: Int64
    private let container: ModelContainer
    private let photoAssets: PhotoAssetSyncBridge
    private let wipeOperation: (ModelContainer) throws -> Void
    /// Live provisioner — nil in tests AND for a participant (the owner owns the zone; a participant
    /// never provisions or runs the iCloud-availability gate against its own private DB).
    private let provisioner: SeedkeepZoneProvisioner?
    /// Durable engine-state token URL (Application Support); deleted on account-change. nil in tests.
    private let stateURL: URL?
    /// Write-ahead latch for account cleanup. If the process dies after an account event or during a
    /// partial wipe, the next coordinator must finish cleanup before it can fetch or stage records.
    private let cleanupMarkerURL: URL?
    /// Participant mode: the engine runs on the OWNER's shared zone (sharedCloudDatabase). A
    /// participant imports NOTHING (no migration) — it only reconciles the owner's zone into SwiftData.
    private let isParticipant: Bool
    let scopeID: String

    // MARK: Observable state (parity with SyncEngine for the banner + spinners)
    private(set) var isSyncing = false
    private(set) var lastHumanizedError: String?
    /// Diagnostics surfaced in Settings ▸ Sync so the beta test isn't blind.
    private(set) var lastSyncedAt: Date?
    private(set) var accountStatusText: String?
    /// Raw error detail (CKError code / description) for the diagnostics row — distinct from the
    /// humanized banner string, mirroring SyncEngine.lastError. nil when the last pass succeeded.
    private(set) var lastErrorDetail: String?
    /// True after an account-change cleanup fails; suppresses all CloudKit work until a subsequent
    /// Sync now invocation completes the wipe.
    private(set) var requiresWipeRetry = false
    /// Photos dropped after a permanent CloudKit save failure. Durable across relaunch so a large
    /// asset cannot be re-uploaded forever; Stage E can surface these and call `retryPhotoSync`.
    private(set) var failedPhotoRecordNames = Set<String>()
    /// Remote photo records whose CKAsset URL expired before its bytes reached the durable cache.
    /// The change cursor may still advance for unrelated records, so this roster survives relaunch
    /// and drives an exact-record refetch when the image is next requested.
    private(set) var unavailableFetchedPhotoRecordNames = Set<String>()
    /// Records currently mirrored in the CloudKit zone (in-memory store) — a rough "data is there"
    /// signal. NOTE: the store is rehydrated from CloudKit each launch, so it reads 0 until the first
    /// fetch this session (the Settings label says "this session" so 0 isn't misread as data loss).
    var zoneRecordCount: Int { engine.store.count() }
    /// Whether the one-time migration (initial upload) has completed for this household — the durable
    /// receipt marker. Surfaced so a tester can confirm their data uploaded.
    var initialUploadComplete: Bool { hasMigratedDurable }

    // MARK: Internal reconcile state
    /// Off-main buffer the engine's fetch callback appends into; drained on @MainActor.
    private let buffer = PendingApplyBuffer()
    /// recordNames projected from remote since the last push — excluded from pushDirty to avoid echo.
    private var appliedSinceLastPush = Set<String>()
    /// Lazy in-memory cache of the durable per-record synced-state map (nil until first touched this
    /// process; loaded from `syncedStateURL` on first read).
    private var syncedStateCache: [String: SyncedRecordState]?
    private var started = false
    /// Bumped by `wipeAndClear` so an in-flight `sync()` resuming after an await can detect that the
    /// account changed mid-pass and bail instead of operating on wiped/abandoned state.
    private var epoch = 0
    private var pushDebounceTask: Task<Void, Never>?
    var pushDebounceIntervalNanoseconds: UInt64 = 1_500_000_000
    /// Test seam: raised inside `drainPendingApplies` at exactly the point a `ModelContext.save()`
    /// failure surfaces, so the projection-failure policy (durable state must not advance past an
    /// unapplied batch) is exercisable without corrupting a real store. Always nil in production.
    @ObservationIgnored
    var projectionFaultForTesting: (() throws -> Void)?

    init(
        engine: HouseholdRecordSyncing,
        zoneID: CKRecordZone.ID,
        householdID: String,
        householdName: String,
        householdCreatedAt: Int64,
        householdUpdatedAt: Int64,
        container: ModelContainer,
        provisioner: SeedkeepZoneProvisioner?,
        stateURL: URL?,
        isParticipant: Bool = false,
        wipeOperation: ((ModelContainer) throws -> Void)? = nil
    ) {
        self.engine = engine
        self.zoneID = zoneID
        self.householdID = householdID
        self.householdName = householdName
        self.householdCreatedAt = householdCreatedAt
        self.householdUpdatedAt = householdUpdatedAt
        self.container = container
        self.photoAssets = PhotoAssetSyncBridge(householdID: householdID)
        self.wipeOperation = wipeOperation ?? Self.wipeHouseholdSwiftData
        self.provisioner = provisioner
        self.stateURL = stateURL
        self.cleanupMarkerURL = stateURL.map(Self.accountCleanupMarkerURL(forStateURL:))
        self.isParticipant = isParticipant
        self.scopeID = isParticipant
            ? Self.participantScopeID(ownerZoneID: zoneID)
            : Self.ownerScopeID(householdID: householdID)
        self.failedPhotoRecordNames = Self.loadFailedPhotoRecordNames(
            from: isParticipant
                ? Self.participantFailedPhotoStateURL(ownerZoneID: zoneID)
                : Self.ownerFailedPhotoStateURL(householdID: householdID))
        self.unavailableFetchedPhotoRecordNames = Self.loadUnavailablePhotoRecordNames(
            from: isParticipant
                ? Self.participantUnavailablePhotoStateURL(ownerZoneID: zoneID)
                : Self.ownerUnavailablePhotoStateURL(householdID: householdID))
        if let cleanupMarkerURL, FileManager.default.fileExists(atPath: cleanupMarkerURL.path) {
            requiresWipeRetry = true
            lastErrorDetail = "Pending CloudKit account cleanup from a previous launch."
            lastHumanizedError = "CloudKit account cleanup is incomplete — tap Sync now to retry."
        }
    }

    /// Production factory: real `HouseholdSyncEngine` on the owner's private DB, durable state token.
    static func live(
        householdID: String,
        householdName: String,
        householdCreatedAt: Int64,
        householdUpdatedAt: Int64,
        container: ModelContainer
    ) -> HouseholdCloudCoordinator {
        let provisioner = SeedkeepZoneProvisioner()
        let database = provisioner.container.privateCloudDatabase
        let zoneID = CKRecordZone.ID(
            zoneName: SeedkeepZoneProvisioner.zoneName(householdID: householdID),
            ownerName: CKCurrentUserDefaultName)

        let stateURL = ownerStateTokenURL(householdID: householdID)

        // automaticSync:false — the coordinator drives fetch/push explicitly from `sync()` (matching
        // the app's existing foreground-only sync model). This guarantees NO delegate event fires
        // before `ensureStarted()` wires the merger + callbacks (else fetched records would be lost
        // and conflicts would bypass the custom merger), and removes the construct-vs-wire race.
        let engine = HouseholdSyncEngine(
            database: database, zoneID: zoneID, store: HouseholdLocalStore(),
            stateURL: stateURL, automaticSync: false)

        return HouseholdCloudCoordinator(
            engine: engine, zoneID: zoneID, householdID: householdID, householdName: householdName,
            householdCreatedAt: householdCreatedAt, householdUpdatedAt: householdUpdatedAt,
            container: container, provisioner: provisioner, stateURL: stateURL)
    }

    /// Participant factory: sync the OWNER's shared zone on `sharedCloudDatabase`. No provisioner (the
    /// owner owns the zone), no migration (a participant imports nothing), a SEPARATE durable state
    /// token. `ownerZoneID.ownerName` is the OWNER's record name (NOT CKCurrentUserDefaultName).
    static func participant(
        ownerZoneID: CKRecordZone.ID,
        container: ModelContainer
    ) -> HouseholdCloudCoordinator {
        let ckContainer = SeedkeepZoneProvisioner().container
        let database = ckContainer.sharedCloudDatabase
        // The household id is the zone's: zoneName is "seedkeep-<householdID>".
        let householdID = SeedkeepRecordNames.householdID(fromZoneName: ownerZoneID.zoneName)
        // Separate token from the owner scope so the shared-zone change cursor never corrupts the
        // (parked) solo owner zone's.
        let stateURL = participantStateTokenURL(ownerZoneID: ownerZoneID)

        let engine = HouseholdSyncEngine(
            database: database, zoneID: ownerZoneID, store: HouseholdLocalStore(),
            stateURL: stateURL, automaticSync: false)

        return HouseholdCloudCoordinator(
            engine: engine, zoneID: ownerZoneID, householdID: householdID, householdName: "",
            householdCreatedAt: 0, householdUpdatedAt: 0,
            container: container, provisioner: nil, stateURL: stateURL, isParticipant: true)
    }

    // MARK: - Sync entry point

    /// Schedule a coalesced push through the normal reconcile path.
    func save() async {
        pushDebounceTask?.cancel()
        let armedEpoch = epoch
        pushDebounceTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(nanoseconds: self.pushDebounceIntervalNanoseconds)
            } catch {
                return
            }
            guard !Task.isCancelled, self.epoch == armedEpoch else { return }
            let ran = await self.sync()
            if !Task.isCancelled, self.epoch == armedEpoch, !ran {
                await self.save()
            }
        }
    }

    func awaitPendingImmediacy() async {
        await pushDebounceTask?.value
    }

    func pendingImmediacyTaskForTesting() -> Task<Void, Never>? {
        pushDebounceTask
    }

    /// Reconcile one pass: ensure started (provision + migrate once), pull + project, push dirty.
    /// Never throws — surfaces failures via `lastHumanizedError` (mirrors SyncEngine's contract so
    /// AppEnvironment's banner mirror works unchanged). Degrades quietly when iCloud is unavailable.
    /// Returns `false` (and does nothing) when another pass is already in flight, so the caller can
    /// skip its post-sync orchestration — same contract as `SyncEngine.syncAll`.
    @discardableResult
    func sync() async -> Bool {
        guard !isSyncing else { return false }
        if requiresWipeRetry {
            wipeAndClear()
            guard !requiresWipeRetry else { return false }
        }
        isSyncing = true
        let passEpoch = epoch
        // Always reset the per-pass echo set, even if a stage throws before pushDirty clears it —
        // otherwise a stale recordName would suppress a later legitimate push of that record.
        defer { isSyncing = false; appliedSinceLastPush.removeAll() }

        // Bounded auto-retry: a single transient CloudKit error (rate-limit / zone-busy / network /
        // first-write-of-a-new-type schema settle, or an incomplete drain) used to abort the whole
        // pass and force the user to tap "Sync now" again. Retry it inline, honoring CloudKit's
        // retry-after hint, so the hiccup self-heals and no scary banner fires. Permanent errors
        // (iCloud-unavailable, quota, permission) surface on the first try.
        let maxAttempts = 2
        for attempt in 0..<maxAttempts {
            do {
                try await runPass(passEpoch)
                // Don't record a fresh success for a pass the account-change abandoned mid-flight
                // (runPass returns cleanly on epoch change) — that would stamp lastSyncedAt + clear a
                // real prior error after the data was wiped.
                guard isCurrent(passEpoch) else { return true }
                lastHumanizedError = nil
                lastErrorDetail = nil
                lastSyncedAt = Date()
                return true
            } catch {
                guard isCurrent(passEpoch) else { return true }   // account changed mid-pass → abandon quietly
                if Self.isTransient(error), attempt < maxAttempts - 1 {
                    let delay = min(max(0, (error as? CKError)?.retryAfterSeconds ?? 0.5), 5)
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    continue   // auto-retry — no banner; the hiccup self-heals
                }
                lastErrorDetail = Self.errorDetail(error)
                lastHumanizedError = Self.humanizeCloudError(error)
                return true
            }
        }
        return true
    }

    /// One reconcile pass. Returns early (no throw) if the account changed mid-pass.
    private func runPass(_ passEpoch: Int) async throws {
        guard isCurrent(passEpoch) else { return }
        try await ensureStarted(passEpoch)
        guard isCurrent(passEpoch) else { return }
        try await pullAndApply(passEpoch)
        guard isCurrent(passEpoch) else { return }
        // Client-side soft-delete cascade (G5): a soft-deleted Seed/Bed/PE soft-deletes its
        // children locally so pushDirty propagates the tombstones (no server to cascade for us).
        try HouseholdCascade.apply(in: ModelContext(container), now: Int64(Date().timeIntervalSince1970 * 1000))
        try await pushDirty(passEpoch)
        guard isCurrent(passEpoch) else { return }
        // Project any send-path merge results (serverRecordChanged → merged re-save) buffered during
        // pushDirty's drain into SwiftData this pass rather than waiting for the next.
        try drainPendingApplies(passEpoch)
    }

    // MARK: - Lifecycle

    private func ensureStarted(_ passEpoch: Int) async throws {
        guard !started else { return }
        if let provisioner {
            let status = await accountStatus(provisioner.container)
            guard isCurrent(passEpoch) else { return }
            accountStatusText = Self.describe(status)
            guard status == .available else { throw CoordinatorError.iCloudUnavailable(status ?? .couldNotDetermine) }
            try await provisioner.ensureZone(householdID: householdID)
            guard isCurrent(passEpoch) else { return }
            let root = try await provisioner.ensureHousehold(householdID: householdID, name: householdName)
            guard isCurrent(passEpoch) else { return }
            _ = try await provisioner.ensureShare(for: root, title: householdName)
            guard isCurrent(passEpoch) else { return }
        }
        guard isCurrent(passEpoch) else { return }
        engine.activateForCurrentAccount()
        engine.merger = SeedkeepRecordMerger()
        engine.onFetchedChanges = { [weak self] mods, dels in
            guard let self else { throw SyncEngineError.accountInvalidated }
            try await self.receiveFetchedChanges(mods, dels, passEpoch: passEpoch)
        }
        let cleanupMarkerURL = cleanupMarkerURL
        engine.onAccountChange = { [weak self, buffer] change in
            switch change {
            case .signOut, .switchAccounts:
                // Persist before the MainActor hop. A process death in that scheduling window must
                // relaunch into cleanup, never into a replacement-account fetch over old local rows.
                if let cleanupMarkerURL {
                    try? HouseholdCloudCoordinator.markAccountCleanupPending(at: cleanupMarkerURL)
                }
                buffer.invalidate(epoch: passEpoch)
            case .signIn:
                break
            }
            Task { @MainActor in self?.handleAccountChange(change) }
        }
        try await engine.fetchChanges()
        guard isCurrent(passEpoch) else { return }
        try drainPendingApplies(passEpoch)
        if isParticipant {
            // Accept-race close (SimmerSmith's participantInitialFetch): right after accept the server
            // often hasn't materialized the shared zone yet and the accepting device gets no push — so
            // fetch once more after a short backoff so the first sync doesn't leave an empty garden.
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard isCurrent(passEpoch) else { return }
            try await engine.fetchChanges()
            guard isCurrent(passEpoch) else { return }
            try drainPendingApplies(passEpoch)
            // drainPendingApplies records synced-state for every fetched record, so it carries AC6
            // for participants across relaunch. A full-graph reseed here would suppress an unpushed
            // local edit (uxc.3).
        } else {
            // A participant imports NOTHING; migration (export + receipt) is the OWNER's one-time job.
            try await migrateIfNeeded(passEpoch)
        }
        guard isCurrent(passEpoch) else { return }
        started = true
    }

    /// Serialize asset materialization and its durable recovery roster with account cleanup. There
    /// is deliberately no suspension point inside this MainActor routine: either it runs before a
    /// wipe (whose purge then removes every copied byte) or after one (and the epoch guard rejects
    /// the retired callback before it touches disk).
    private func receiveFetchedChanges(
        _ mods: [CKRecord],
        _ dels: [CKRecord.ID],
        passEpoch: Int
    ) throws {
        guard isCurrent(passEpoch) else { throw SyncEngineError.accountInvalidated }
        // CKAsset URLs are framework-owned and temporary. Copy each photo independently before the
        // callback returns. One unreadable asset becomes a recoverable shell row and does not poison
        // the checkpoint for unrelated records in the same batch (D7).
        var unavailable = Set<String>()
        var resolved = Set<String>()
        for record in mods where Self.isPhotoRecordName(record.recordID.recordName) {
            let recordName = record.recordID.recordName
            let expectsAsset = record["asset"] != nil || record["assetSHA256"] != nil
            guard expectsAsset else {
                resolved.insert(recordName) // accepted legacy metadata-only shell
                continue
            }
            do {
                if try photoAssets.materializeFetchedAsset(record) != nil {
                    resolved.insert(recordName)
                } else {
                    unavailable.insert(recordName)
                }
            } catch {
                unavailable.insert(recordName)
            }
        }
        let deletedPhotoNames = Set(dels.map(\.recordName).filter(Self.isPhotoRecordName))
        try commitUnavailableFetchedPhotos(
            adding: unavailable, removing: resolved.union(deletedPhotoNames))
        buffer.append(mods, dels, epoch: passEpoch)
        try drainPendingApplies(passEpoch)
    }

    /// Pull remote changes then project the buffered records into SwiftData.
    private func pullAndApply(_ passEpoch: Int) async throws {
        guard isCurrent(passEpoch) else { return }
        try await engine.fetchChanges()
        guard isCurrent(passEpoch) else { return }
        try drainPendingApplies(passEpoch)
    }

    // MARK: - Project fetched remote → SwiftData (with the updatedAt-LWW gate)

    private func drainPendingApplies(_ passEpoch: Int) throws {
        guard isCurrent(passEpoch) else { return }
        let (mods, dels) = buffer.drain(for: passEpoch)
        guard !mods.isEmpty || !dels.isEmpty else { return }
        do {
            try applyDrained(mods: mods, dels: dels)
        } catch {
            // The projection failed, so the batch has NOT landed in SwiftData. Put it back: the engine
            // rewinds its durable cursor for a FETCHED batch, but a SENT batch (a merged
            // serverRecordChanged result) is never re-delivered by CloudKit at all — this buffer is its
            // only remaining copy. Re-applying a re-delivered batch is harmless: the apply is an
            // LWW-gated upsert keyed by record name.
            buffer.restore(mods, dels, epoch: passEpoch)
            throw error
        }
    }

    private func applyDrained(mods: [CKRecord], dels: [CKRecord.ID]) throws {
        let context = ModelContext(container)
        let activeScopeID = scopeID
        let pendingDeletionNames = Set(try context.fetch(
            FetchDescriptor<LocalCloudKitDeletion>(predicate: #Predicate {
                $0.scopeID == activeScopeID
            })
        ).map(\.recordName))
        var updates: [String: SyncedRecordState] = [:]
        var removals: Set<String> = []
        for record in mods {
            guard !pendingDeletionNames.contains(record.recordID.recordName) else { continue }
            guard let type = SeedkeepRecordType.type(forRecordTypeName: record.recordType) else { continue }
            let value = SeedkeepRecordCodec.decode(record, as: type)
            guard HouseholdApplyGate.shouldApply(value, into: context) else { continue }
            HouseholdRecordApplier.apply(value, householdID: householdID, into: context)
            appliedSinceLastPush.insert(value.recordName)
            // Synced-state write (the AC1 fix): apply is now a writer too, not just push — a peer
            // record's clock is recorded as KNOWN-synced the moment it lands locally, so it no longer
            // looks unconfirmed (and gets needlessly re-pushed) on the next relaunch.
            let clock = (record["updatedAt"] as? Int).map(Int64.init) ?? (record["capturedAt"] as? Int).map(Int64.init) ?? 0
            updates[value.recordName] = SyncedRecordState(clock: clock, tombstoned: (record["deletedAt"] as? Int) != nil)
        }
        for id in dels {
            HouseholdApplyGate.deleteLocal(recordName: id.recordName, householdID: householdID, into: context)
            appliedSinceLastPush.insert(id.recordName)
            removals.insert(id.recordName)   // S7 — clear the entry; nothing local left to compare against
        }
        try projectionFaultForTesting?()
        try context.save()
        try clearFailedPhotoRecords(removals)
        commitSyncedState(updates, removing: removals)
    }

    // MARK: - Push local-newer → engine

    /// Stage every local record whose current state isn't already confirmed in CloudKit, then drain.
    ///
    /// Echo / clock-skew safety (durable per-record synced-state — NOT a relaunch-only optimization;
    /// this is what kills the relaunch re-upload residual a single global push ceiling left behind):
    ///  - `appliedSinceLastPush` skips records projected from remote THIS pass (within-session echo).
    ///  - `syncedState(for:)` skips a record whose KNOWN CloudKit state is already at an equal-or-newer
    ///    clock for the SAME liveness (live-vs-live or tombstone-vs-tombstone) — durable across relaunch
    ///    because it's written on BOTH push-success (below) and apply-success (`drainPendingApplies`).
    ///  - EXCEPTION: a local TOMBSTONE whose known synced state is still LIVE always pushes, regardless
    ///    of clock — a peer's live edit must never strand our delete (sticky-deletedAt keeps it converged).
    /// No shared ceiling var, so a peer's clock can never raise a threshold that strands a later
    /// genuine local edit at a lower clock (the clock-skew-poisoning fix, expressed per-record).
    private func pushDirty(_ passEpoch: Int) async throws {
        guard isCurrent(passEpoch) else { return }
        let context = ModelContext(container)
        let activeScopeID = scopeID
        let deletionIntents = try context.fetch(
            FetchDescriptor<LocalCloudKitDeletion>(predicate: #Predicate {
                $0.scopeID == activeScopeID
            })
        )
        let deletionRecordNames = Set(deletionIntents.map(\.recordName))
        for recordName in deletionRecordNames {
            engine.delete(CKRecord.ID(recordName: recordName, zoneID: zoneID))
        }
        let input = HouseholdMigrationPlanner.fetchInput(
            from: context, householdID: householdID, householdName: householdName,
            householdCreatedAt: householdCreatedAt, householdUpdatedAt: householdUpdatedAt)
        var staged: [String: SyncedRecordState] = [:]
        var stagedPhotoRecordNames: [String] = []
        var firstPreparationError: Error?
        var pushed = 0
        for d in dirtyRecords(from: input) {
            guard !deletionRecordNames.contains(d.recordName) else { continue }
            guard !appliedSinceLastPush.contains(d.recordName) else { continue }   // applied from remote this pass
            let isLocalTombstone = d.value.scalars["deletedAt"] != nil
            if let known = syncedState(for: d.recordName) {
                if isLocalTombstone {
                    if known.tombstoned && known.clock >= d.clock { continue }
                } else {
                    if !known.tombstoned && known.clock >= d.clock { continue }
                }
                // else fall through & push (never-confirmed / stale-clock / confirmed-live-now-tombstoned)
            }
            let encoded = SeedkeepRecordCodec.encode(d.value, zoneID: zoneID)
            let prepared: CKRecord
            do {
                prepared = try photoAssets.prepareForUpload(encoded)
            } catch {
                if firstPreparationError == nil { firstPreparationError = error }
                continue   // fail closed for this photo; unrelated records still drain
            }
            engine.save(prepared)
            staged[d.recordName] = SyncedRecordState(clock: d.clock, tombstoned: isLocalTombstone)
            if Self.isPhotoRecordName(d.recordName) { stagedPhotoRecordNames.append(d.recordName) }
            pushed += 1
        }
        // Drain whenever ANYTHING is pending — not only when this pass staged new records — so a
        // record re-enqueued by a transient failure on a PRIOR pass still gets flushed (with
        // automaticSync:false the coordinator is the only drain driver). sendUntilDrained THROWS on an
        // incomplete drain, so the commit below is skipped → an unconfirmed record is NOT marked
        // synced; it retries next pass (invariant 3).
        if pushed > 0 || !deletionIntents.isEmpty || engine.hasPendingRecordChanges {
            do {
                try await engine.sendUntilDrained(maxPasses: 6)
            } catch {
                try recordPermanentPhotoFailures(engine.consumePermanentlyFailedSaveRecordIDs())
                throw error
            }
        }
        guard isCurrent(passEpoch) else { return }
        if !deletionIntents.isEmpty {
            for intent in deletionIntents {
                HouseholdApplyGate.deleteLocal(recordName: intent.recordName, householdID: householdID, into: context)
                context.delete(intent)
            }
            try context.save()
            try clearFailedPhotoRecords(deletionRecordNames)
            try commitUnavailableFetchedPhotos(adding: [], removing: deletionRecordNames)
        }
        commitSyncedState(staged, removing: deletionRecordNames)
        try photoAssets.confirmUploaded(recordNames: stagedPhotoRecordNames)
        if let firstPreparationError { throw firstPreparationError }
    }

    private struct Dirty { let recordName: String; let clock: Int64; let value: CloudKitRecordValue }

    private func dirtyRecords(from input: HouseholdMigrationPlanner.Input) -> [Dirty] {
        var out: [Dirty] = []
        func add(_ clock: Int64, _ value: CloudKitRecordValue) {
            guard !failedPhotoRecordNames.contains(value.recordName) else { return }
            out.append(Dirty(recordName: value.recordName, clock: clock, value: value))
        }
        for m in input.locations          { add(m.updatedAt, m.cloudKitValue) }
        for m in input.tags               { add(m.updatedAt, m.cloudKitValue) }
        for m in input.seeds              { add(m.updatedAt, m.cloudKitValue) }
        for m in input.seedPhotos         { add(m.capturedAt, m.cloudKitValue) }   // SeedPhoto clock = capturedAt
        for m in input.beds               { add(m.updatedAt, m.cloudKitValue) }
        for m in input.plantingEvents     { add(m.updatedAt, m.cloudKitValue) }
        for m in input.journalEntries     { add(m.updatedAt, m.cloudKitValue) }
        for m in input.journalEntryPhotos { add(m.updatedAt, m.cloudKitValue) }
        for m in input.checklistItems     { add(m.updatedAt, m.cloudKitValue) }
        for m in input.petDepartures      { add(m.updatedAt, m.cloudKitValue) }
        return out
    }

    // MARK: - One-time migration (AC3)

    private func migrateIfNeeded(_ passEpoch: Int) async throws {
        guard isCurrent(passEpoch) else { return }
        // DURABLE relaunch guard: the executor's receipt check reads the engine's IN-MEMORY store,
        // which an incremental fetch never re-populates on relaunch — so without this, the whole graph
        // would re-export on every launch. The marker (UserDefaults, per household) survives relaunch.
        if hasMigratedDurable { return }
        let context = ModelContext(container)
        let input = HouseholdMigrationPlanner.fetchInput(
            from: context, householdID: householdID, householdName: householdName,
            householdCreatedAt: householdCreatedAt, householdUpdatedAt: householdUpdatedAt)
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let plan = HouseholdMigrationPlanner.plan(input, completedAt: now)
        if let paused = plan.first(where: { failedPhotoRecordNames.contains($0.recordName) }) {
            throw PhotoAssetSyncError.retryRequired(recordName: paused.recordName)
        }
        let result: HouseholdMigrationExecutor.Result
        do {
            result = try await HouseholdMigrationExecutor.run(
                into: engine, zoneID: zoneID, householdID: householdID, plan: plan,
                prepareRecord: photoAssets.prepareForUpload)
        } catch {
            try recordPermanentPhotoFailures(engine.consumePermanentlyFailedSaveRecordIDs())
            throw error
        }
        guard isCurrent(passEpoch) else { return }
        // Migrated now (or the receipt was already present from a peer) → never migrate again on this
        // device for this household. (Cleared on account change in wipeAndClear.)
        hasMigratedDurable = true
        // On .migrated, input is exactly what was just exported, so seeding is correct. On
        // .alreadyMigrated, do not reseed the fresh graph: pushDirty pushes current state and records
        // synced-state only after a clean drain, avoiding suppression of an unconfirmed local edit.
        if !result.alreadyMigrated {
            let photoNames = plan.compactMap { value in
                Self.isPhotoRecordName(value.recordName) ? value.recordName : nil
            }
            try photoAssets.confirmUploaded(recordNames: photoNames)
            seedSyncedState(from: input)
        }
    }

    // MARK: - Account change (AC5)

    func handleAccountChange(_ change: HouseholdAccountChange) {
        switch change {
        case .signOut, .switchAccounts: wipeAndClear()
        case .signIn: break
        }
    }

    /// Wipe the household-zone-mirrored SwiftData rows + the engine state token; reset reconcile
    /// state so a different account re-provisions cleanly on the next sync. Driven by the engine's
    /// `onAccountChange` (AC5 — a CloudKit account sign-out/switch). NOTE: the APP-level sign-out
    /// (`AuthController.signOut` → `eraseAllLocalData`) already wipes household SwiftData generically;
    /// an account SWITCH additionally rebuilds this coordinator (different householdID → fresh state
    /// token + synced-state file in `AppEnvironment.ensureCloudCoordinator`).
    func wipeAndClear() {
        var markerError: Error?
        if let cleanupMarkerURL {
            do { try Self.markAccountCleanupPending(at: cleanupMarkerURL) }
            catch { markerError = error }
        }
        epoch += 1   // invalidate every in-flight CloudKit boundary before local cleanup begins
        engine.discardPendingChanges()
        buffer.discardAll()
        appliedSinceLastPush.removeAll()
        started = false
        pushDebounceTask?.cancel()
        pushDebounceTask = nil

        if let markerError {
            recordCleanupFailure(markerError)
            return
        }

        do {
            try wipeOperation(container)
            let context = ModelContext(container)
            let activeScopeID = scopeID
            let intents = try context.fetch(
                FetchDescriptor<LocalCloudKitDeletion>(predicate: #Predicate {
                    $0.scopeID == activeScopeID
                })
            )
            for intent in intents { context.delete(intent) }
            try context.save()
            // AC5 — a PRIVACY requirement: another household's photo bytes must not survive an
            // account switch. `householdID` identifies the same garden regardless of owner vs
            // participant role (the participant factory derives it from the shared zone's name —
            // see `Self.participant`), so purging under it here also covers the CKShare
            // adopt/leave paths (`AppEnvironment.bootParticipant` / `leaveSharedHousehold`), which
            // both route through this same function. THROWS into the existing wipe-retry
            // machinery below rather than silently leaving bytes behind on failure.
            try PhotoByteStore.purgeHousehold(householdID)
            if let stateURL { try Self.removeItemIfPresent(at: stateURL) }
            try Self.removeItemIfPresent(at: syncedStateURL)
            try Self.removeItemIfPresent(at: failedPhotoStateURL)
            try Self.removeItemIfPresent(at: unavailablePhotoStateURL)
            if let cleanupMarkerURL { try Self.removeItemIfPresent(at: cleanupMarkerURL) }
            syncedStateCache = [:]
            failedPhotoRecordNames = []
            unavailableFetchedPhotoRecordNames = []
            hasMigratedDurable = false
            requiresWipeRetry = false
        } catch {
            recordCleanupFailure(error)
        }
    }

    private func recordCleanupFailure(_ error: Error) {
        requiresWipeRetry = true
        lastErrorDetail = Self.errorDetail(error)
        lastHumanizedError = "CloudKit account cleanup is incomplete — tap Sync now to retry."
    }

    /// Delete every household-zone-mirrored SwiftData row (the 10 garden types). Standalone + static so
    /// the share-adopt / leave flows can clean-swap the local store without an existing coordinator.
    /// Device-local-only models (LocalForecastSnapshot / LocalPetMoodSnapshot) are intentionally left.
    static func wipeHouseholdSwiftData(container: ModelContainer) throws {
        let context = ModelContext(container)
        try wipeAll(LocalSeed.self, context)
        try wipeAll(LocalLocation.self, context)
        try wipeAll(LocalTag.self, context)
        try wipeAll(LocalSeedPhoto.self, context)
        try wipeAll(LocalBed.self, context)
        try wipeAll(LocalPlantingEvent.self, context)
        try wipeAll(LocalJournalEntry.self, context)
        try wipeAll(LocalJournalEntryPhoto.self, context)
        try wipeAll(LocalJournalChecklistItem.self, context)
        try wipeAll(LocalPetDeparture.self, context)
        try context.save()
    }

    private static func wipeAll<T: PersistentModel>(_ type: T.Type, _ context: ModelContext) throws {
        for model in try context.fetch(FetchDescriptor<T>()) { context.delete(model) }
    }

    private static func removeItemIfPresent(at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    // MARK: - Persisted per-household state (survives relaunch)

    private var migratedKey: String { "seedkeep.ck.migrated.\(Self.cloudKitEnvironmentTag).\(householdID)" }
    private var hasMigratedDurable: Bool {
        get { UserDefaults.standard.bool(forKey: migratedKey) }
        set { UserDefaults.standard.set(newValue, forKey: migratedKey) }
    }

    // MARK: - Durable permanent photo failures (D7)

    private var failedPhotoStateURL: URL {
        isParticipant
            ? Self.participantFailedPhotoStateURL(ownerZoneID: zoneID)
            : Self.ownerFailedPhotoStateURL(householdID: householdID)
    }

    func retryPhotoSync(recordName: String) async throws {
        guard Self.isPhotoRecordName(recordName), failedPhotoRecordNames.contains(recordName) else { return }
        var updated = failedPhotoRecordNames
        updated.remove(recordName)
        try Self.saveFailedPhotoRecordNames(updated, to: failedPhotoStateURL)
        failedPhotoRecordNames = updated
        _ = await sync()
    }

    private func recordPermanentPhotoFailures(_ recordIDs: [CKRecord.ID]) throws {
        let newNames = Set(recordIDs.map(\.recordName).filter(Self.isPhotoRecordName))
        guard !newNames.isEmpty else { return }
        let updated = failedPhotoRecordNames.union(newNames)
        try Self.saveFailedPhotoRecordNames(updated, to: failedPhotoStateURL)
        failedPhotoRecordNames = updated
    }

    private func clearFailedPhotoRecords(_ recordNames: Set<String>) throws {
        let clearing = recordNames.intersection(failedPhotoRecordNames)
        guard !clearing.isEmpty else { return }
        let updated = failedPhotoRecordNames.subtracting(clearing)
        try Self.saveFailedPhotoRecordNames(updated, to: failedPhotoStateURL)
        failedPhotoRecordNames = updated
    }

    nonisolated private static func isPhotoRecordName(_ recordName: String) -> Bool {
        recordName.hasPrefix("seedPhoto:") || recordName.hasPrefix("journalEntryPhoto:")
    }

    private static func loadFailedPhotoRecordNames(from url: URL) -> Set<String> {
        guard let data = try? Data(contentsOf: url),
              let names = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return Set(names.filter(isPhotoRecordName))
    }

    private static func saveFailedPhotoRecordNames(_ names: Set<String>, to url: URL) throws {
        let data = try JSONEncoder().encode(names.sorted())
        try data.write(to: url, options: .atomic)
    }

    // MARK: - Durable fetched-photo recovery roster

    private var unavailablePhotoStateURL: URL {
        isParticipant
            ? Self.participantUnavailablePhotoStateURL(ownerZoneID: zoneID)
            : Self.ownerUnavailablePhotoStateURL(householdID: householdID)
    }

    func recoverPhotoAssetData(recordName: String) async throws -> Data? {
        guard Self.isPhotoRecordName(recordName) else { return nil }
        guard !requiresWipeRetry else { throw CoordinatorError.accountCleanupPending }
        let recoveryEpoch = epoch
        let recordID = CKRecord.ID(recordName: recordName, zoneID: zoneID)
        let record = try await engine.fetchRecord(recordID)
        guard isCurrent(recoveryEpoch) else { throw SyncEngineError.accountInvalidated }
        guard let ref = try photoAssets.materializeFetchedAsset(record) else { return nil }
        let data = try Data(contentsOf: ref.url)
        try commitUnavailableFetchedPhotos(adding: [], removing: [recordName])
        return data
    }

    private func commitUnavailableFetchedPhotos(
        adding: Set<String>,
        removing: Set<String>
    ) throws {
        let additions = Set(adding.filter(Self.isPhotoRecordName))
        let removals = Set(removing.filter(Self.isPhotoRecordName)).subtracting(additions)
        guard !additions.isEmpty || !removals.isEmpty else { return }
        let updated = unavailableFetchedPhotoRecordNames
            .subtracting(removals)
            .union(additions)
        guard updated != unavailableFetchedPhotoRecordNames else { return }
        try Self.saveUnavailablePhotoRecordNames(updated, to: unavailablePhotoStateURL)
        unavailableFetchedPhotoRecordNames = updated
    }

    private static func loadUnavailablePhotoRecordNames(from url: URL) -> Set<String> {
        guard let data = try? Data(contentsOf: url),
              let names = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return Set(names.filter(isPhotoRecordName))
    }

    private static func saveUnavailablePhotoRecordNames(_ names: Set<String>, to url: URL) throws {
        guard !names.isEmpty else {
            try removeItemIfPresent(at: url)
            return
        }
        let data = try JSONEncoder().encode(names.sorted())
        try data.write(to: url, options: .atomic)
    }

    // MARK: - Per-record synced-state (replaces the single global push clock ceiling)

    /// The newest state we KNOW CloudKit holds for a given record — written on BOTH push-success
    /// (`pushDirty`) and apply-success (`drainPendingApplies`; the missing writer that fixes the
    /// relaunch re-upload residual, AC1). The `tombstoned` bit makes the tombstone-over-live-peer
    /// exception durable across relaunch instead of session-scoped (AC3).
    private struct SyncedRecordState: Codable { var clock: Int64; var tombstoned: Bool }

    /// Derived from ivars the same way `migratedKey` is — NOT an init param — so a second coordinator
    /// built against the same household (the relaunch tests) resolves to the same file.
    private var syncedStateURL: URL {
        isParticipant
            ? Self.participantSyncedStateURL(ownerZoneID: zoneID)
            : Self.ownerSyncedStateURL(householdID: householdID)
    }

    /// Mirrors `HouseholdSyncEngine.loadState`'s contract: best-effort, missing/corrupt → empty.
    private static func loadSyncedState(from url: URL) -> [String: SyncedRecordState] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: SyncedRecordState].self, from: data)) ?? [:]
    }

    /// Mirrors `HouseholdSyncEngine.saveState`'s contract: best-effort atomic write.
    private static func saveSyncedState(_ state: [String: SyncedRecordState], to url: URL) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func syncedState(for recordName: String) -> SyncedRecordState? {
        if syncedStateCache == nil { syncedStateCache = Self.loadSyncedState(from: syncedStateURL) }
        return syncedStateCache?[recordName]
    }

    /// Merge `updates` into the durable map and drop `removing`, then persist. No-ops (no disk
    /// touch) when both are empty, so a pass that pushed/applied nothing never writes the file.
    private func commitSyncedState(_ updates: [String: SyncedRecordState], removing: Set<String> = []) {
        guard !updates.isEmpty || !removing.isEmpty else { return }
        if syncedStateCache == nil { syncedStateCache = Self.loadSyncedState(from: syncedStateURL) }
        for (name, state) in updates { syncedStateCache?[name] = state }
        for name in removing { syncedStateCache?[name] = nil }
        Self.saveSyncedState(syncedStateCache ?? [:], to: syncedStateURL)
    }

    /// Seed synced-state for every record in the local graph with its REAL tombstoned bit (not always
    /// false — a pre-migration soft-delete would otherwise re-push immediately). Used only for the
    /// owner's genuine one-time migration export; participants seed through the apply-path writer.
    private func isCurrent(_ passEpoch: Int) -> Bool {
        passEpoch == epoch && !buffer.isInvalidated(epoch: passEpoch)
    }

    private func seedSyncedState(from input: HouseholdMigrationPlanner.Input) {
        var seed: [String: SyncedRecordState] = [:]
        for d in dirtyRecords(from: input) {
            seed[d.recordName] = SyncedRecordState(clock: d.clock, tombstoned: d.value.scalars["deletedAt"] != nil)
        }
        commitSyncedState(seed)
    }

    // MARK: - Helpers

    enum CoordinatorError: Error {
        case iCloudUnavailable(CKAccountStatus)
        case accountCleanupPending
    }

    /// MUST match `com.apple.developer.icloud-container-environment` in project.yml. All durable
    /// per-household CloudKit state (migration marker, per-record synced-state file, engine-state
    /// token) is namespaced by this, so flipping the CloudKit environment (the Development→Production
    /// cutover) re-migrates the INTACT local graph into the new environment rather than skipping it —
    /// the marker is otherwise env-agnostic, so a switched device would skip migration and its data
    /// would never reach the empty Production zone (silent divergence). The old env-agnostic
    /// keys/tokens are left as harmless orphans.
    nonisolated static let cloudKitEnvironmentTag = "production"

    // MARK: - Durable engine-state token paths (single source of truth for the factories + the
    // adopt/leave token resets — a full re-fetch repopulates wiped SwiftData).
    /// `nonisolated` (pure Foundation path/mkdir logic, safe off the main actor) and not `private`
    /// so `PhotoByteStore` (Photos-on-CloudKit Stage B) can derive its own namespaced
    /// subdirectories from the SAME root without duplicating this derivation — see
    /// `PhotoByteStore.rootDirectory`. "Do not invent a new location scheme."
    nonisolated static func householdSyncDir() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("HouseholdSync", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    static func ownerStateTokenURL(householdID: String) -> URL {
        householdSyncDir().appendingPathComponent("engine-state-\(cloudKitEnvironmentTag)-\(householdID).json")
    }
    static func participantStateTokenURL(ownerZoneID: CKRecordZone.ID) -> URL {
        householdSyncDir().appendingPathComponent(
            "engine-state-shared-\(durableScopeComponent(participantScopeID(ownerZoneID: ownerZoneID))).json"
        )
    }
    nonisolated static func accountCleanupMarkerURL(forStateURL stateURL: URL) -> URL {
        stateURL.appendingPathExtension("cleanup-pending")
    }
    nonisolated private static func markAccountCleanupPending(at url: URL) throws {
        try Data("pending".utf8).write(to: url, options: .atomic)
    }
    static func ownerSyncedStateURL(householdID: String) -> URL {
        householdSyncDir().appendingPathComponent("synced-state-\(cloudKitEnvironmentTag)-\(householdID).json")
    }
    static func participantSyncedStateURL(ownerZoneID: CKRecordZone.ID) -> URL {
        householdSyncDir().appendingPathComponent(
            "synced-state-shared-\(durableScopeComponent(participantScopeID(ownerZoneID: ownerZoneID))).json"
        )
    }
    static func ownerFailedPhotoStateURL(householdID: String) -> URL {
        householdSyncDir().appendingPathComponent(
            "failed-photos-\(cloudKitEnvironmentTag)-\(householdID).json")
    }
    static func participantFailedPhotoStateURL(ownerZoneID: CKRecordZone.ID) -> URL {
        householdSyncDir().appendingPathComponent(
            "failed-photos-shared-\(durableScopeComponent(participantScopeID(ownerZoneID: ownerZoneID))).json"
        )
    }
    static func ownerUnavailablePhotoStateURL(householdID: String) -> URL {
        householdSyncDir().appendingPathComponent(
            "unavailable-fetched-photos-\(cloudKitEnvironmentTag)-\(householdID).json")
    }
    static func participantUnavailablePhotoStateURL(ownerZoneID: CKRecordZone.ID) -> URL {
        householdSyncDir().appendingPathComponent(
            "unavailable-fetched-photos-shared-\(durableScopeComponent(participantScopeID(ownerZoneID: ownerZoneID))).json"
        )
    }
    static func ownerScopeID(householdID: String) -> String {
        let zoneID = CKRecordZone.ID(
            zoneName: SeedkeepZoneProvisioner.zoneName(householdID: householdID),
            ownerName: CKCurrentUserDefaultName
        )
        return scopeID(database: "private", zoneID: zoneID)
    }
    static func participantScopeID(ownerZoneID: CKRecordZone.ID) -> String {
        scopeID(database: "shared", zoneID: ownerZoneID)
    }
    private static func scopeID(database: String, zoneID: CKRecordZone.ID) -> String {
        "\(cloudKitEnvironmentTag)|\(database)|\(zoneID.zoneName)|\(zoneID.ownerName)"
    }
    private static func durableScopeComponent(_ scopeID: String) -> String {
        Data(scopeID.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
    }
    /// Delete a durable state token so the next coordinator on that scope does a FULL re-fetch. Used by
    /// adopt/leave: those wipe local SwiftData, so the rebuilt coordinator must re-download (an
    /// incremental fetch on the parked token would return nothing → an empty local store).
    static func resetStateToken(at url: URL) throws { try removeItemIfPresent(at: url) }

    /// A CloudKit error worth auto-retrying inline (transient infra) vs surfacing (permanent).
    static func isTransient(_ error: Error) -> Bool {
        if error is SyncEngineError { return true }   // drainIncomplete — pending changes, retry
        if error is URLError { return true }
        guard let ck = error as? CKError else { return false }
        switch ck.code {
        case .networkUnavailable, .networkFailure, .serviceUnavailable, .zoneBusy,
             .requestRateLimited, .serverResponseLost, .batchRequestFailed:
            return true
        default:
            return false   // serverRejectedRequest / quotaExceeded / permission / notAuthenticated → surface
        }
    }

    /// Raw detail for the diagnostics row (distinct from the humanized banner copy).
    static func errorDetail(_ error: Error) -> String {
        if let ck = error as? CKError { return "CKError \(ck.errorCode): \(ck.localizedDescription)" }
        return error.localizedDescription
    }

    /// CloudKit-aware humanized copy — keeps the CKError mapping out of the cross-platform
    /// SeedkeepKit humanizer; falls back to it for URLError / SeedkeepError.
    static func humanizeCloudError(_ error: Error) -> String {
        if case CoordinatorError.iCloudUnavailable(let status) = error {
            return "iCloud unavailable — \(describe(status))."
        }
        if case CoordinatorError.accountCleanupPending = error {
            return "CloudKit account cleanup is incomplete — tap Sync now to retry."
        }
        if let ck = error as? CKError {
            switch ck.code {
            case .networkUnavailable, .networkFailure:
                return "You're offline — your garden will sync when you're back online."
            case .serviceUnavailable, .zoneBusy, .requestRateLimited, .serverResponseLost, .serverRejectedRequest, .batchRequestFailed:
                return "iCloud is busy — your garden will sync shortly."
            case .notAuthenticated:
                return "Sign into iCloud (Settings ▸ Apple ID) to sync your garden across devices."
            case .quotaExceeded:
                return "Your iCloud storage is full — free up space to keep syncing."
            case .managedAccountRestricted:
                return "iCloud sync is restricted on this account."
            default:
                return "iCloud sync hit a snag — it will retry automatically."
            }
        }
        return humanizeError(error)
    }

    static func describe(_ status: CKAccountStatus?) -> String {
        switch status {
        case .available:        return "available"
        case .noAccount:        return "no iCloud account — sign into iCloud in Settings"
        case .restricted:       return "restricted (parental/MDM controls)"
        case .couldNotDetermine:return "could not determine"
        case .temporarilyUnavailable: return "temporarily unavailable — reopen Settings ▸ Apple ID"
        case .none:             return "timed out"
        @unknown default:       return "unknown"
        }
    }

    /// Standalone bounded iCloud-account check for the Settings diagnostics button — works even when
    /// no coordinator has been built yet (flag just toggled) or a sync errored.
    static func currentAccountStatusText(containerIdentifier: String = "iCloud.app.seedkeep") async -> String {
        let container = CKContainer(identifier: containerIdentifier)
        let box = ResumeOnce()
        let status: CKAccountStatus? = await withCheckedContinuation { cont in
            Task.detached { box.resume(cont, (try? await container.accountStatus())) }
            Task.detached { try? await Task.sleep(nanoseconds: 10 * 1_000_000_000); box.resume(cont, nil) }
        }
        return describe(status)
    }

    /// Bounded `accountStatus()` returning nil on timeout. A broken cloudd auth token can hang the
    /// call indefinitely AND ignore cancellation (spike gotcha), so we must NOT depend on structured
    /// task-group teardown (which awaits the hung child). Race two detached tasks into a resume-once
    /// continuation; if accountStatus wedges, the sleep still resolves us and the hung task is
    /// abandoned (leaked) rather than blocking the caller.
    private func accountStatus(_ container: CKContainer, seconds: UInt64 = 10) async -> CKAccountStatus? {
        let box = ResumeOnce()
        return await withCheckedContinuation { (cont: CheckedContinuation<CKAccountStatus?, Never>) in
            Task.detached { box.resume(cont, (try? await container.accountStatus())) }
            Task.detached {
                try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
                box.resume(cont, nil)
            }
        }
    }
}

/// Guarantees a CheckedContinuation is resumed exactly once across two racing tasks.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func resume(_ cont: CheckedContinuation<CKAccountStatus?, Never>, _ value: CKAccountStatus?) {
        lock.lock()
        let first = !done
        done = true
        lock.unlock()
        if first { cont.resume(returning: value) }
    }
}

/// Off-main, thread-safe staging buffer for records the engine fetch callback hands over (the
/// callback fires on CKSyncEngine's queue; ModelContext is @MainActor). Drained on the main actor.
final class PendingApplyBuffer: @unchecked Sendable {
    private struct Batch {
        let epoch: Int
        let mods: [CKRecord]
        let dels: [CKRecord.ID]
    }

    private let lock = NSLock()
    private var batches: [Batch] = []

    private var invalidatedEpochs = Set<Int>()

    func append(_ newMods: [CKRecord], _ newDels: [CKRecord.ID], epoch: Int) {
        lock.lock(); defer { lock.unlock() }
        guard !invalidatedEpochs.contains(epoch) else { return }
        batches.append(Batch(epoch: epoch, mods: newMods, dels: newDels))
    }

    /// Synchronously fences callbacks before the MainActor receives the account-change task.
    func invalidate(epoch: Int) {
        lock.lock(); defer { lock.unlock() }
        invalidatedEpochs.insert(epoch)
        batches.removeAll { $0.epoch == epoch }
    }

    func isInvalidated(epoch: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return invalidatedEpochs.contains(epoch)
    }

    func drain(for epoch: Int) -> (mods: [CKRecord], dels: [CKRecord.ID]) {
        lock.lock(); defer { lock.unlock() }
        let matching = batches.filter { $0.epoch == epoch }
        batches.removeAll()
        return (matching.flatMap(\.mods), matching.flatMap(\.dels))
    }

    /// Put a drained batch back at the FRONT of the queue after its SwiftData projection failed, so
    /// the next drain re-projects it in arrival order. An account change that invalidated the epoch
    /// meanwhile discards it, exactly as `append` would.
    func restore(_ mods: [CKRecord], _ dels: [CKRecord.ID], epoch: Int) {
        lock.lock(); defer { lock.unlock() }
        guard !invalidatedEpochs.contains(epoch) else { return }
        batches.insert(Batch(epoch: epoch, mods: mods, dels: dels), at: 0)
    }

    func discardAll() {
        lock.lock(); defer { lock.unlock() }
        batches.removeAll()
    }
}
#endif
