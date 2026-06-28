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
///     updatedAt-LWW gate) then push (scan SwiftData for records newer than the watermark, exclude
///     ones just applied this pass to avoid echo, encode, engine.save, drain).
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
    /// Live provisioner — nil in tests (skips zone/share creation + the iCloud-availability gate).
    private let provisioner: SeedkeepZoneProvisioner?
    /// Durable engine-state token URL (Application Support); deleted on account-change. nil in tests.
    private let stateURL: URL?

    // MARK: Observable state (parity with SyncEngine for the banner + spinners)
    private(set) var isSyncing = false
    private(set) var lastHumanizedError: String?

    // MARK: Internal reconcile state
    /// Off-main buffer the engine's fetch callback appends into; drained on @MainActor.
    private let buffer = PendingApplyBuffer()
    /// recordNames projected from remote since the last push — excluded from pushDirty to avoid echo.
    private var appliedSinceLastPush = Set<String>()
    private var started = false
    /// Bumped by `wipeAndClear` so an in-flight `sync()` resuming after an await can detect that the
    /// account changed mid-pass and bail instead of operating on wiped/abandoned state.
    private var epoch = 0

    init(
        engine: HouseholdRecordSyncing,
        zoneID: CKRecordZone.ID,
        householdID: String,
        householdName: String,
        householdCreatedAt: Int64,
        householdUpdatedAt: Int64,
        container: ModelContainer,
        provisioner: SeedkeepZoneProvisioner?,
        stateURL: URL?
    ) {
        self.engine = engine
        self.zoneID = zoneID
        self.householdID = householdID
        self.householdName = householdName
        self.householdCreatedAt = householdCreatedAt
        self.householdUpdatedAt = householdUpdatedAt
        self.container = container
        self.provisioner = provisioner
        self.stateURL = stateURL
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

        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("HouseholdSync", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stateURL = dir.appendingPathComponent("engine-state-\(householdID).json")

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

    // MARK: - Sync entry point

    /// Reconcile one pass: ensure started (provision + migrate once), pull + project, push dirty.
    /// Never throws — surfaces failures via `lastHumanizedError` (mirrors SyncEngine's contract so
    /// AppEnvironment's banner mirror works unchanged). Degrades quietly when iCloud is unavailable.
    /// Returns `false` (and does nothing) when another pass is already in flight, so the caller can
    /// skip its post-sync orchestration — same contract as `SyncEngine.syncAll`.
    @discardableResult
    func sync() async -> Bool {
        guard !isSyncing else { return false }
        isSyncing = true
        let passEpoch = epoch
        // Always reset the per-pass echo set, even if a stage throws before pushDirty clears it —
        // otherwise a stale recordName would suppress a later legitimate push of that record.
        defer { isSyncing = false; appliedSinceLastPush.removeAll() }
        do {
            try await ensureStarted()
            guard passEpoch == epoch else { return true }   // account changed mid-pass → abandon
            try await pullAndApply()
            guard passEpoch == epoch else { return true }
            // Client-side soft-delete cascade (G5): a soft-deleted Seed/Bed/PE soft-deletes its
            // children locally so pushDirty propagates the tombstones (no server to cascade for us).
            try HouseholdCascade.apply(in: ModelContext(container), now: Int64(Date().timeIntervalSince1970 * 1000))
            try await pushDirty()
            guard passEpoch == epoch else { return true }
            // Project any send-path merge results (serverRecordChanged → merged re-save) buffered
            // during pushDirty's drain into SwiftData this pass rather than waiting for the next.
            try drainPendingApplies()
            lastHumanizedError = nil
        } catch {
            lastHumanizedError = humanizeError(error)
        }
        return true
    }

    // MARK: - Lifecycle

    private func ensureStarted() async throws {
        guard !started else { return }
        if let provisioner {
            let status = await accountStatus(provisioner.container)
            guard status == .available else { throw CoordinatorError.iCloudUnavailable(status ?? .couldNotDetermine) }
            try await provisioner.ensureZone(householdID: householdID)
            let root = try await provisioner.ensureHousehold(householdID: householdID, name: householdName)
            _ = try await provisioner.ensureShare(for: root, title: householdName)
        }
        engine.merger = SeedkeepRecordMerger()
        engine.onFetchedChanges = { [buffer] mods, dels in buffer.append(mods, dels) }
        engine.onAccountChange = { [weak self] change in
            Task { @MainActor in self?.handleAccountChange(change) }
        }
        try await engine.fetchChanges()
        try drainPendingApplies()
        try await migrateIfNeeded()
        started = true
    }

    /// Pull remote changes then project the buffered records into SwiftData.
    private func pullAndApply() async throws {
        try await engine.fetchChanges()
        try drainPendingApplies()
    }

    // MARK: - Project fetched remote → SwiftData (with the updatedAt-LWW gate)

    private func drainPendingApplies() throws {
        let (mods, dels) = buffer.drain()
        guard !mods.isEmpty || !dels.isEmpty else { return }
        let context = ModelContext(container)
        for record in mods {
            guard let type = SeedkeepRecordType.type(forRecordTypeName: record.recordType) else { continue }
            let value = SeedkeepRecordCodec.decode(record, as: type)
            guard HouseholdApplyGate.shouldApply(value, into: context) else { continue }
            HouseholdRecordApplier.apply(value, householdID: householdID, into: context)
            appliedSinceLastPush.insert(value.recordName)
        }
        for id in dels {
            HouseholdApplyGate.deleteLocal(recordName: id.recordName, into: context)
            appliedSinceLastPush.insert(id.recordName)
        }
        try context.save()
    }

    // MARK: - Push local-newer → engine

    /// Stage every local record that is genuinely newer than what CloudKit holds, then drain.
    ///
    /// Echo / clock-skew safety (the watermark is a relaunch-only optimization, NOT the echo guard):
    ///  - `d.clock > watermark` skips records already pushed in a PRIOR SESSION (durable watermark).
    ///  - `appliedSinceLastPush` skips records projected from remote THIS pass.
    ///  - the `engine.store` comparison skips records the store already holds at an equal-or-newer
    ///    clock — i.e. remote-applied or already-pushed records — which is the cross-pass echo guard.
    ///  - the watermark advances ONLY over records actually PUSHED (local-origin). A peer's clock can
    ///    therefore never raise the local push threshold, so a local edit with a lower wall-clock than
    ///    a fast peer is still pushed (fixes the clock-skew poisoning the review flagged).
    private func pushDirty() async throws {
        let context = ModelContext(container)
        let input = HouseholdMigrationPlanner.fetchInput(
            from: context, householdID: householdID, householdName: householdName,
            householdCreatedAt: householdCreatedAt, householdUpdatedAt: householdUpdatedAt)
        let wm = watermark
        var pushedMaxClock = wm
        var pushed = 0
        for d in dirtyRecords(from: input) {
            guard d.clock > wm else { continue }                                   // pushed in a prior session
            guard !appliedSinceLastPush.contains(d.recordName) else { continue }   // applied from remote this pass
            let id = CKRecord.ID(recordName: d.recordName, zoneID: zoneID)
            if let stored = engine.store.record(for: id), storeClock(stored) >= d.clock {
                // Normally skip — CloudKit already holds this (remote-applied or already-pushed).
                // EXCEPTION: a local TOMBSTONE whose stored copy is still LIVE must always push, even
                // at a lower clock — a peer's live edit (high clock) in the store would otherwise
                // strand our cascade/delete tombstone. The merger's sticky-deletedAt keeps it converged.
                let localTombstoneVsLiveStore =
                    d.value.scalars["deletedAt"] != nil && (stored["deletedAt"] as? Int) == nil
                if !localTombstoneVsLiveStore { continue }
            }
            engine.save(SeedkeepRecordCodec.encode(d.value, zoneID: zoneID))
            pushedMaxClock = max(pushedMaxClock, d.clock)
            pushed += 1
        }
        if pushed > 0 { try await engine.sendUntilDrained(maxPasses: 8) }
        watermark = pushedMaxClock
    }

    /// The CloudKit-side merge clock of a stored CKRecord (updatedAt, or capturedAt for SeedPhoto).
    private func storeClock(_ record: CKRecord) -> Int64 {
        if let u = record["updatedAt"] as? Int { return Int64(u) }
        if let c = record["capturedAt"] as? Int { return Int64(c) }
        return 0
    }

    private struct Dirty { let recordName: String; let clock: Int64; let value: CloudKitRecordValue }

    private func dirtyRecords(from input: HouseholdMigrationPlanner.Input) -> [Dirty] {
        var out: [Dirty] = []
        func add(_ clock: Int64, _ value: CloudKitRecordValue) {
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

    private func migrateIfNeeded() async throws {
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
        let result = try await HouseholdMigrationExecutor.run(
            into: engine, zoneID: zoneID, householdID: householdID, plan: plan)
        // Migrated now (or the receipt was already present from a peer) → never migrate again on this
        // device for this household. (Cleared on account change in wipeAndClear.)
        hasMigratedDurable = true
        // The just-migrated graph is now in CloudKit; advance the watermark past it so pushDirty
        // doesn't immediately re-push every record it already exported.
        if !result.alreadyMigrated {
            let maxClock = dirtyRecords(from: input).map(\.clock).max() ?? watermark
            watermark = max(watermark, maxClock)
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
    /// token + watermark in `AppEnvironment.ensureCloudCoordinator`).
    func wipeAndClear() {
        let context = ModelContext(container)
        wipeAll(LocalSeed.self, context)
        wipeAll(LocalLocation.self, context)
        wipeAll(LocalTag.self, context)
        wipeAll(LocalSeedPhoto.self, context)
        wipeAll(LocalBed.self, context)
        wipeAll(LocalPlantingEvent.self, context)
        wipeAll(LocalJournalEntry.self, context)
        wipeAll(LocalJournalEntryPhoto.self, context)
        wipeAll(LocalJournalChecklistItem.self, context)
        wipeAll(LocalPetDeparture.self, context)
        try? context.save()
        if let stateURL { try? FileManager.default.removeItem(at: stateURL) }
        watermark = 0
        hasMigratedDurable = false
        _ = buffer.drain()
        appliedSinceLastPush.removeAll()
        started = false
        epoch += 1   // invalidate any in-flight sync() pass that resumes after this wipe
    }

    private func wipeAll<T: PersistentModel>(_ type: T.Type, _ context: ModelContext) {
        let all = (try? context.fetch(FetchDescriptor<T>())) ?? []
        for m in all { context.delete(m) }
    }

    // MARK: - Persisted per-household state (survives relaunch)

    private var watermarkKey: String { "seedkeep.ck.pushWatermark.\(householdID)" }
    private var watermark: Int64 {
        get { Int64(UserDefaults.standard.integer(forKey: watermarkKey)) }
        set { UserDefaults.standard.set(Int(newValue), forKey: watermarkKey) }
    }

    private var migratedKey: String { "seedkeep.ck.migrated.\(householdID)" }
    private var hasMigratedDurable: Bool {
        get { UserDefaults.standard.bool(forKey: migratedKey) }
        set { UserDefaults.standard.set(newValue, forKey: migratedKey) }
    }

    // MARK: - Helpers

    enum CoordinatorError: Error { case iCloudUnavailable(CKAccountStatus) }

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
    private let lock = NSLock()
    private var mods: [CKRecord] = []
    private var dels: [CKRecord.ID] = []

    func append(_ newMods: [CKRecord], _ newDels: [CKRecord.ID]) {
        lock.lock(); defer { lock.unlock() }
        mods += newMods
        dels += newDels
    }

    func drain() -> (mods: [CKRecord], dels: [CKRecord.ID]) {
        lock.lock(); defer { lock.unlock() }
        let result = (mods, dels)
        mods = []
        dels = []
        return result
    }
}
#endif
