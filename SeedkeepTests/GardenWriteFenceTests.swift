import CloudKit
import Foundation
import SwiftData
import Testing
@preconcurrency import UserNotifications
@testable import Seedkeep
import SeedkeepKit
import SeedkeepCloudKit

/// N2-E (G2) §6: the guard runner and the write fence, launch ordering and the gone placeholder.
/// Every test runs on fakes: `FakeCloudIdentityProvider`, `FakeCloudCoordinators`,
/// `FakeGardenProvisioner` and a recording notifier. No CloudKit and no real notifications.
@MainActor
@Suite("Deleted-garden guard: runner and fence", .serialized)
struct GardenWriteFenceTests {
    nonisolated static let userA = "_userA"
    nonisolated static let userB = "_userB"
    nonisolated static let keyA = "_userA|production"
    nonisolated static let keyB = "_userB|production"

    /// Records every notification call, and can run a hook in the middle of a schedule call.
    @MainActor
    final class RecordingNotifier: GardenNotifying {
        private(set) var remindersScheduled: [String] = []
        private(set) var remindersCancelled: [String] = []
        private(set) var roundupsScheduled = 0
        private(set) var roundupsCleared = 0
        private(set) var removedAll = 0
        var duringSchedule: (@MainActor () -> Void)?

        func scheduleEventReminder(eventID: String, plannedFor: String, kindLabel: String, seedName: String?) async {
            remindersScheduled.append(eventID)
            duringSchedule?()
        }
        func cancelEventReminder(eventID: String) { remindersCancelled.append(eventID) }
        func schedulePetRoundup(thriving: Int, wilting: Int) async {
            roundupsScheduled += 1
            duringSchedule?()
        }
        func clearPetRoundup() { roundupsCleared += 1 }
        func removeAll() { removedAll += 1 }
    }

    static func defaults(_ name: String) -> UserDefaults {
        let suite = "GardenWriteFenceTests.\(name)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    static func cache(_ defaults: UserDefaults, user: String, household: String) {
        let json = """
        {"user":{"id":"\(user)","name":null,"email":null},"household":{"id":"\(household)","name":"Mine","created_at":1,"updated_at":1}}
        """
        defaults.set(Data(json.utf8), forKey: AuthController.identityCacheKey)
    }

    static func binding(_ id: String) -> GardenGuardBinding {
        GardenGuardBinding(household: .init(id: id, name: "Mine", createdAt: 1, updatedAt: 1), participant: nil)
    }

    struct Env {
        let env: AppEnvironment
        let store: GardenGuardStore
        let coordinators: FakeCloudCoordinators
        let notifier: RecordingNotifier
        let rehomer: RecordingRehomer
        let provider: FakeCloudIdentityProvider
        let defaults: UserDefaults
    }

    /// An environment signed in to `household` for `user` (a cached identity), over a guard that
    /// already holds `prepare`'s entries.
    static func makeEnv(
        _ name: String, user: String = userA, household: String = "hhr_g",
        store: GardenGuardStore = GardenGuardStore(directory: GuardTestDirectory.make()),
        provider: FakeCloudIdentityProvider? = nil,
        ownerShares: (any OwnerShareMaking)? = nil,
        deferring: Bool = false, starter: (() -> Void)? = nil,
        prepare: (GardenGuardStore) throws -> Void = { _ in }
    ) throws -> Env {
        let defaults = Self.defaults(name)
        Self.cache(defaults, user: user, household: household)
        try prepare(store)
        let coordinators = FakeCloudCoordinators()
        let notifier = RecordingNotifier()
        let rehomer = RecordingRehomer()
        let provider = provider ?? FakeCloudIdentityProvider(recordName: user, owned: nil, shared: nil)
        let env = AppEnvironment.makeForTesting(
            identity: provider, tokenStore: InMemoryTokenStore(), defaults: defaults,
            container: makeTestContainer(name: "fence-\(UUID().uuidString)"),
            durableStateDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("fence-\(UUID().uuidString)", isDirectory: true),
            cloudCoordinators: coordinators.factory, gardenGuard: store, gardenRehomer: rehomer,
            notifier: notifier, ownerShares: ownerShares, deferringBackgroundServices: deferring, backgroundServiceStarter: starter)
        return Env(env: env, store: store, coordinators: coordinators, notifier: notifier,
                   rehomer: rehomer, provider: provider, defaults: defaults)
    }

    /// Whether `body` was refused by the write fence.
    static func isRefused(_ body: () async throws -> Void) async -> Bool {
        do { try await body(); return false } catch let error as SeedkeepError {
            return error.code == GardenWriteFence.refusedCode
        } catch { return false }
    }

    static func markGone(_ store: GardenGuardStore, _ account: String, _ household: String) throws {
        try store.setBinding(account, binding(household))
        try store.markGone(account, household, reason: .zoneDeleted)
    }

    // MARK: - A gone garden is not writable

    @Test("a gone garden has no writable garden, no scan binding, and refuses every write")
    func goneGardenRefusesWrites() async throws {
        let rig = try Self.makeEnv("goneRefuses", prepare: { try Self.markGone($0, Self.keyA, "hhr_g") })
        await rig.env.auth.restoreSession()
        let env = rig.env
        #expect(env.isActiveGardenGone)
        #expect(env.writableGarden == nil)
        #expect(env.scanBinding == nil)
        #expect(!env.gardenWriteStillValid(nil))

        let refused122 = await Self.isRefused { _ = try env.sync.enqueueCreateLocation(name: "Shed", householdID: "hhr_g") }
        #expect(refused122)
        let refused123 = await Self.isRefused { try env.sync.enqueueDeleteSeed(id: "any") }
        #expect(refused123)
        let refused124 = await Self.isRefused {
            _ = try await env.journal.create(occurredOn: "2026-10-24", body: "late", householdID: "hhr_g")
        }
        #expect(refused124)
        let context = ModelContext(env.container)
        #expect(try context.fetch(FetchDescriptor<LocalLocation>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<LocalJournalEntry>()).isEmpty)

        // A sync builds no coordinator and sends nothing.
        await env.syncIfPossible()
        #expect(rig.coordinators.built.isEmpty)
        #expect(!env.hasCloudCoordinator)
    }

    @Test("a garden that is not gone is writable, and any scope change ends what already began")
    func scopeChangesEndWriters() async throws {
        let rig = try Self.makeEnv("scopeChanges")
        await rig.env.auth.restoreSession()
        let env = rig.env
        let first = try #require(env.writableGarden)
        #expect(first.householdID == "hhr_g")
        let binding = try #require(env.scanBinding)
        _ = try env.sync.enqueueCreateLocation(name: "Shed", householdID: "hhr_g")
        #expect(env.gardenWriteStillValid(first))

        env.gardenRunner.bumpScopeEpoch()   // a binding change or an account transition
        #expect(!env.gardenWriteStillValid(first))
        #expect(!binding.matches(env.scanBinding))
        let second = try #require(env.writableGarden)
        #expect(second.epoch == first.epoch + 1)
    }

    @Test("an account pause and a binding change bump the scope epoch")
    func authTransitionsBumpEpoch() async throws {
        let rig = try Self.makeEnv("authBumps")
        await rig.env.auth.restoreSession()
        let afterSignIn = rig.env.gardenScopeEpoch
        #expect(afterSignIn > 0)
        rig.env.auth.pauseForAccountChange()
        #expect(rig.env.gardenScopeEpoch > afterSignIn)
        let afterPause = rig.env.gardenScopeEpoch
        await rig.env.auth.revalidateAfterAccountChange()
        #expect(rig.env.gardenScopeEpoch > afterPause)
    }

    // MARK: - The gone step, end to end through the environment

    @Test("a deleted garden found by the start check fences every writer and cancels notifications, in one step")
    func goneThroughTheEnvironment() async throws {
        let rig = try Self.makeEnv("goneEnv", prepare: { store in
            try store.setBinding(Self.keyA, Self.binding("hhr_g"))
            try store.recordSeen(Self.keyA, "hhr_g", generation: 1_000_000)
        })
        let provisioner = FakeGardenProvisioner()
        provisioner.setRoot(householdID: "hhr_g", .zoneMissing)
        rig.coordinators.provisioner = provisioner
        await rig.env.auth.restoreSession()
        let env = rig.env
        let before = try #require(env.writableGarden)
        let scanBefore = try #require(env.scanBinding)
        #expect(env.adoptionIsCurrent(0))                // the share epoch before the garden went

        await env.syncIfPossible()

        #expect(rig.store.isGone(Self.keyA, "hhr_g"))
        #expect(env.isActiveGardenGone)
        #expect(env.writableGarden == nil)
        #expect(!env.gardenWriteStillValid(before))      // a writer that began earlier does nothing
        #expect(!scanBefore.matches(env.scanBinding))    // an open scan sheet stops
        #expect(!env.adoptionIsCurrent(0))               // pendingShareEpoch bumped
        #expect(rig.notifier.removedAll == 1)            // the garden's notifications are cancelled
        #expect(provisioner.totalCreations == 0)
        #expect(rig.coordinators.built.allSatisfy { $0.engine.batchesSent == 0 })
        let refused196 = await Self.isRefused { _ = try env.sync.enqueueCreateLocation(name: "Shed", householdID: "hhr_g") }
        #expect(refused196)
        // Later passes touch nothing.
        let inspections = provisioner.inspectCalls.count
        await env.syncIfPossible()
        #expect(provisioner.inspectCalls.count == inspections)
    }

    @Test("a late pet-roundup notification is removed when the garden goes while it is being scheduled")
    func latePetRoundupRemoved() async throws {
        let rig = try Self.makeEnv("lateRoundup", prepare: { try $0.setBinding(Self.keyA, Self.binding("hhr_g")) })
        await rig.env.auth.restoreSession()
        let env = rig.env
        let store = rig.store
        rig.notifier.duringSchedule = {
            try? store.markGone(Self.keyA, "hhr_g", reason: .zoneDeleted)
            env.gardenRunner.finishGone(GardenGoneEvent(accountKey: Self.keyA, householdID: "hhr_g", reason: .zoneDeleted))
        }
        await env.syncIfPossible()
        #expect(rig.notifier.roundupsScheduled == 1)
        #expect(rig.notifier.roundupsCleared == 1)   // taken back
    }

    @Test("a pet roundup scheduled in a stable scope stays")
    func stableRoundupStays() async throws {
        let rig = try Self.makeEnv("stableRoundup", prepare: { try $0.setBinding(Self.keyA, Self.binding("hhr_g")) })
        await rig.env.auth.restoreSession()
        await rig.env.syncIfPossible()
        #expect(rig.notifier.roundupsScheduled == 1)
        #expect(rig.notifier.roundupsCleared == 0)
    }

    // MARK: - Individual writers

    @Test("a planting-event reminder scheduled after its scope went stale is cancelled again")
    func lateReminderCancelled() async throws {
        DevicePreferences.store.set(true, forKey: "seedkeep.notif.events")
        defer { DevicePreferences.store.removeObject(forKey: "seedkeep.notif.events") }
        final class Scope { var current: WritableGarden? = WritableGarden(householdID: "hhr_g", epoch: 1) }
        let scope = Scope()
        let engine = SyncEngine(container: makeTestContainer(name: "reminder-\(UUID().uuidString)"))
        let notifier = RecordingNotifier()
        engine.notifier = notifier
        engine.writeFence = GardenWriteFence(current: { scope.current })
        notifier.duringSchedule = { scope.current = nil }   // the garden goes mid-schedule
        let input = CreatePlantingEventInput(id: "pe_late", kind: .sowing, planned_for: "2099-01-01")
        _ = try engine.enqueueCreatePlantingEvent(input, householdID: "hhr_g")
        for _ in 0..<200 where notifier.remindersCancelled.isEmpty { await Task.yield() }
        #expect(notifier.remindersScheduled == ["pe_late"])
        #expect(notifier.remindersCancelled == ["pe_late"])

        // A stable scope keeps its reminder.
        let steady = RecordingNotifier()
        engine.notifier = steady
        scope.current = WritableGarden(householdID: "hhr_g", epoch: 1)
        _ = try engine.enqueueCreatePlantingEvent(CreatePlantingEventInput(id: "pe_ok", kind: .sowing, planned_for: "2099-01-01"),
                                                  householdID: "hhr_g")
        for _ in 0..<200 where steady.remindersScheduled.isEmpty { await Task.yield() }
        for _ in 0..<50 { await Task.yield() }
        #expect(steady.remindersScheduled == ["pe_ok"])
        #expect(steady.remindersCancelled.isEmpty)
    }

    @Test("journal writes check the scope at their final boundary")
    func journalWritesFenced() async throws {
        final class Scope { var current: WritableGarden? = WritableGarden(householdID: "hhr_g", epoch: 1) }
        let scope = Scope()
        let container = makeTestContainer(name: "journal-\(UUID().uuidString)")
        let journal = JournalStore(container: container)
        journal.writeFence = GardenWriteFence(current: { scope.current })
        let entry = try await journal.create(occurredOn: "2026-10-24", body: "fine", householdID: "hhr_g")
        scope.current = nil
        let refused267 = await Self.isRefused {
            try await journal.update(entry, occurredOn: "2026-10-24", body: "late", seedID: nil, bedID: nil,
                                     plantingEventID: nil, householdID: "hhr_g")
        }
        #expect(refused267)
        let refused271 = await Self.isRefused { try await journal.softDelete(entry, householdID: "hhr_g") }
        #expect(refused271)
        let entryID = entry.id
        let refused273 = await Self.isRefused {
            _ = try await journal.addChecklistItem(entryID: entryID, text: "late", householdID: "hhr_g")
        }
        #expect(refused273)
        let rows = try ModelContext(container).fetch(FetchDescriptor<LocalJournalEntry>())
        #expect(rows.count == 1)
        #expect(rows.first?.body == "fine")
        #expect(rows.first?.deletedAt == nil)
        // A scope that moves between the start and the save is refused at the save.
        scope.current = WritableGarden(householdID: "hhr_g", epoch: 2)
        let again = try await journal.create(occurredOn: "2026-10-25", body: "back", householdID: "hhr_g")
        #expect(again.body == "back")
    }

    @Test("pet ticks write nothing for a stale scope, and re-check right before the save")
    func petTicksFenced() throws {
        let container = makeTestContainer(name: "pets-\(UUID().uuidString)")
        let context = ModelContext(container)
        let now = Date()
        let ms = Int64(now.timeIntervalSince1970 * 1000)
        let event = LocalPlantingEvent(
            id: "pe_pet", householdID: "hhr_g", kindRaw: "sowing", plannedFor: "2026-01-01", completedAt: nil,
            createdAt: ms - 3 * 86_400_000, updatedAt: ms - 3 * 86_400_000, petSeed: "seed_pe", petRarity: "common",
            petCreatureKind: "garden_worm", petName: "Pip", petSpawnedAt: ms - 3 * 86_400_000)
        context.insert(event)
        try context.save()

        func snapshots() throws -> Int { try ModelContext(container).fetchCount(FetchDescriptor<LocalPetMoodSnapshot>()) }
        #expect(PetStateEngine.tickAll(householdID: "hhr_g", container: container, now: now, isWritable: { false }).isEmpty)
        #expect(try snapshots() == 0)
        // The scope is valid when the ticks start and stale by the save: nothing is saved.
        var checks = 0
        _ = PetStateEngine.tickAll(householdID: "hhr_g", container: container, now: now, isWritable: {
            checks += 1
            return checks == 1
        })
        #expect(try snapshots() == 0)
        // A stable scope ticks.
        _ = PetStateEngine.tickAll(householdID: "hhr_g", container: container, now: now, isWritable: { true })
        #expect(try snapshots() == 1)
    }

    @Test("participant row recovery writes nothing for a stale scope")
    func participantRecoveryFenced() throws {
        let container = makeTestContainer(name: "recovery-\(UUID().uuidString)")
        let signedIn = "hh_signed_\(UUID().uuidString)"
        let owner = "hh_owner_\(UUID().uuidString)"
        let context = ModelContext(container)
        context.insert(LocalLocation(id: "loc_stranded", householdID: signedIn, name: "Shed", sortOrder: 0,
                                     createdAt: 1, updatedAt: 1))
        try context.save()
        func householdOfRow() throws -> String? {
            try ModelContext(container).fetch(FetchDescriptor<LocalLocation>()).first?.householdID
        }
        let staleAtStart = ParticipantRowRecovery.runIfNeeded(
            container: container, signedInHouseholdID: signedIn, ownerZoneHouseholdID: owner, isWritable: { false })
        #expect(!staleAtStart)
        #expect(try householdOfRow() == signedIn)
        var checks = 0
        let staleAtSave = ParticipantRowRecovery.runIfNeeded(
            container: container, signedInHouseholdID: signedIn, ownerZoneHouseholdID: owner, isWritable: {
                checks += 1
                return checks == 1
            })
        #expect(!staleAtSave)
        #expect(try householdOfRow() == signedIn)
        let stable = ParticipantRowRecovery.runIfNeeded(
            container: container, signedInHouseholdID: signedIn, ownerZoneHouseholdID: owner, isWritable: { true })
        #expect(stable)
        #expect(try householdOfRow() == owner)
        UserDefaults.standard.removeObject(forKey: "seedkeep.ck.recovery27d18.\(HouseholdCloudCoordinator.cloudKitEnvironmentTag).\(ParticipantRowRecovery.scopeKey(ownerZoneHouseholdID: owner, signedInHouseholdID: signedIn))")
    }

    @Test("the frost backfill writes nothing for a stale scope")
    func frostBackfillFenced() async {
        let suite = "GardenWriteFenceTests.frost.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let prefs = AppPreferences(defaults: defaults)
        prefs.homeZip = "10001"
        await prefs.backfillFrostDates(isWritable: { false })
        #expect(prefs.avgLastFrost == nil)
        var checks = 0
        await prefs.backfillFrostDates(isWritable: {
            checks += 1
            return checks == 1   // stale by the time the lookup returns
        })
        #expect(prefs.avgLastFrost == nil)
        await prefs.backfillFrostDates(isWritable: { true })
        #expect(prefs.avgLastFrost == "04-01")
    }

    // MARK: - Weather notifications

    private static func weatherService(
        scope: @escaping @MainActor () -> String?
    ) async -> (WeatherWarningsService, MockNotificationScheduler, MockWeatherProvider) {
        let tz = TimeZone(identifier: "America/Chicago")!
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        let now = cal.date(from: DateComponents(calendar: cal, timeZone: tz, year: 2026, month: 7, day: 15, hour: 3))!
        let provider = MockWeatherProvider()
        provider.setHomeTimeZone(tz)
        var forecast: [DailyWeather] = []
        for offset in 1...10 {
            guard let day = cal.date(byAdding: .day, value: offset, to: now) else { continue }
            forecast.append(DailyWeather(date: day, lowF: 28, highF: 50, precipMM: 0, rainMM: 0, apparentHighF: 50,
                                         precipitationChance: 0, humidity: 0, windMPH: 0))
        }
        provider.setForecast(forecast)
        let scheduler = MockNotificationScheduler()
        scheduler.setAuthorizationStatus(.authorized)
        let service = await WeatherWarningsService(
            container: makeTestContainer(name: "weather-\(UUID().uuidString)"),
            provider: provider, scheduler: scheduler, planting: StubPlantingEventQuery(activeCount: 1),
            wateringState: MockWateringStateClient(), clock: FixedClock(now: now), thresholds: .kc,
            householdIDProvider: { "hhr_g" }, scopeProvider: scope,
            preferencesProvider: { (39.0997, -94.5786) },
            togglesProvider: { (frost: true, heat: false, water: false) })
        return (service, scheduler, provider)
    }

    @Test("with no writable garden a weather refresh schedules nothing and clears what is pending")
    func weatherRefreshNoScope() async {
        let (service, scheduler, provider) = await Self.weatherService(scope: { nil })
        scheduler.seedPending([UNNotificationRequest(identifier: "seedkeep.notif.frost.2026-07-20",
                                                     content: UNMutableNotificationContent(), trigger: nil)])
        _ = await service.refreshAll(reason: .test)
        #expect(scheduler.recordedAdds.isEmpty)
        #expect(scheduler.pendingSnapshot.isEmpty)
        #expect(provider.recordedFetchCount == 0)
    }

    @Test("a weather notification added just as the scope goes stale is removed again")
    func weatherNotificationRemovedWhenStale() async {
        final class Calls: @unchecked Sendable {
            let lock = NSLock()
            var count = 0
            func next() -> Int { lock.withLock { count += 1; return count } }
        }
        let calls = Calls()
        // Calls: 1 = the refresh's snapshot, 2 = before the first add, 3 = right after it.
        let (service, scheduler, _) = await Self.weatherService(scope: { calls.next() <= 2 ? "hhr_g#1" : "hhr_g#2" })
        _ = await service.refreshAll(reason: .test)
        #expect(scheduler.recordedAdds.count == 1)          // one went in...
        #expect(scheduler.pendingSnapshot.isEmpty)           // ...and was taken back
        #expect(scheduler.recordedRemovals.flatMap { $0 }.contains(scheduler.recordedAdds[0].identifier))
    }

    @Test("a stable scope keeps its weather notifications")
    func weatherNotificationsStayInStableScope() async {
        let (service, scheduler, _) = await Self.weatherService(scope: { "hhr_g#1" })
        _ = await service.refreshAll(reason: .test)
        #expect(!scheduler.recordedAdds.isEmpty)
        #expect(scheduler.pendingSnapshot.count == scheduler.recordedAdds.count)
    }

    // MARK: - Resolution

    @Test("resolution never selects a gone garden, even when its zone is still listed")
    func resolutionSkipsGoneGarden() async throws {
        let store = GardenGuardStore(directory: GuardTestDirectory.make())
        try store.markGone(Self.keyA, "hhr_gone", reason: .recreated)
        let defaults = Self.defaults("resolveGone")
        let gone = FakeCloudIdentityProvider.zone("hhr_gone", scope: .owned, name: "Gone", updatedAt: 5)
        let other = FakeCloudIdentityProvider.zone("hhr_other", scope: .owned, name: "Other", updatedAt: 5)

        let onlyGone = AuthController(
            identity: FakeCloudIdentityProvider(owned: [gone], shared: []), tokenStore: InMemoryTokenStore(),
            defaults: defaults, guardStore: store, rehomer: RecordingRehomer(), makeHouseholdID: { "hhr_minted" })
        onlyGone.wireLocalDataEraser {}
        await onlyGone.restoreSession()
        guard case .signedIn(_, let household) = onlyGone.state else { Issue.record("expected signed in"); return }
        #expect(household.id == "hhr_minted")   // a new garden, not the gone one

        let defaults2 = Self.defaults("resolveGone2")
        let both = AuthController(
            identity: FakeCloudIdentityProvider(owned: [gone, other], shared: []), tokenStore: InMemoryTokenStore(),
            defaults: defaults2, guardStore: GardenGuardStore(directory: nil), rehomer: RecordingRehomer())
        both.wireLocalDataEraser {}
        let store2 = both.guardStore
        try store2.markGone(Self.keyA, "hhr_gone", reason: .recreated)
        await both.restoreSession()
        guard case .signedIn(_, let chosen) = both.state else { Issue.record("expected signed in"); return }
        #expect(chosen.id == "hhr_other")
    }

    // MARK: - Launch ordering (§6)

    @Test("a launch with a gone entry starts nothing until restoreSession has verified the account and the runner resumed")
    func launchOrdering() async throws {
        var started = 0
        let rig = try Self.makeEnv("launchOrder", deferring: true, starter: { started += 1 }, prepare: {
            try Self.markGone($0, Self.keyA, "hhr_g")
        })
        let env = rig.env
        #expect(env.isLaunchGuardPending)
        #expect(started == 0)
        await env.auth.restoreSession()
        #expect(env.isLaunchGuardPending)          // verified, but the runner has not resumed
        #expect(started == 0)
        #expect(rig.coordinators.built.isEmpty)

        env.resumeGuardAfterLaunch()
        #expect(!env.isLaunchGuardPending)
        #expect(started == 1)
        #expect(rig.notifier.removedAll == 1)        // a gone garden has no notifications
        env.resumeGuardAfterLaunch()
        #expect(started == 1)                        // once
        #expect(env.isActiveGardenGone)              // the placeholder, not a garden
    }

    @Test("another account's entries are left untouched, and its launch follows the normal identity flow")
    func otherAccountUntouched() async throws {
        var started = 0
        let store = GardenGuardStore(directory: GuardTestDirectory.make())
        let rig = try Self.makeEnv("launchOther", user: Self.userB, household: "hhr_b", store: store,
                                   deferring: true, starter: { started += 1 }, prepare: {
            try Self.markGone($0, Self.keyA, "hhr_a")
            try $0.setBinding(Self.keyA, Self.binding("hhr_a"),
                              journals: ["hhr_a": GardenGoneRecord(reason: .absentZone, action: .rehome, phase: .journaled,
                                                                   replacementID: "hhr_new", createdAt: Date())])
        })
        let before = store.file
        let env = rig.env
        #expect(env.isLaunchGuardPending)
        await env.auth.restoreSession()
        env.resumeGuardAfterLaunch()
        #expect(started == 1)
        #expect(!env.isLaunchGuardPending)
        #expect(!env.isActiveGardenGone)                       // account B's garden is untouched
        #expect(env.writableGarden?.householdID == "hhr_b")
        #expect(rig.rehomer.requests.isEmpty)                  // account A's journal is not B's to resume
        #expect(store.account(Self.keyA) == before.accounts[Self.keyA])
    }

    @Test("the owning account's open journal is handed to the re-home seam after verification, not before")
    func journalResumesAfterVerification() async throws {
        let rig = try Self.makeEnv("launchJournal", deferring: true, starter: {}, prepare: {
            try $0.setBinding(Self.keyA, Self.binding("hhr_g"),
                              journals: ["hhr_g": GardenGoneRecord(reason: .absentZone, action: .rehome, phase: .journaled,
                                                                   replacementID: "hhr_new", createdAt: Date())])
        })
        #expect(rig.rehomer.requests.isEmpty)
        await rig.env.auth.restoreSession()
        #expect(rig.rehomer.requests.isEmpty)
        rig.env.resumeGuardAfterLaunch()
        #expect(rig.rehomer.requests == [GardenRehomeRequest(
            accountKey: Self.keyA, fromHouseholdID: "hhr_g", toHouseholdID: "hhr_new", reason: .absentZone)])
        // The garden stays usable on the device while only a journal waits for G3.
        #expect(rig.env.writableGarden != nil)
    }

    @Test("a running journal stops writes to its garden, and only its garden (the G3 seam)")
    func runningJournalBlocksWrites() throws {
        let store = GardenGuardStore(directory: nil)
        let runner = GardenGuardRunner(store: store, rehomer: RecordingRehomer())
        #expect(!runner.isBlocked(account: Self.keyA, householdID: "hhr_g"))
        runner.beginJournal(account: Self.keyA, householdID: "hhr_g")
        #expect(runner.isBlocked(account: Self.keyA, householdID: "hhr_g"))
        #expect(!runner.isBlocked(account: Self.keyA, householdID: "hhr_other"))
        #expect(!runner.isBlocked(account: Self.keyB, householdID: "hhr_g"))
        runner.endJournal(account: Self.keyA, householdID: "hhr_g")
        #expect(!runner.isBlocked(account: Self.keyA, householdID: "hhr_g"))
        // A gone entry blocks on its own.
        try Self.markGone(store, Self.keyA, "hhr_g")
        #expect(runner.isBlocked(account: Self.keyA, householdID: "hhr_g"))
    }

    @Test("an unconfirmed account keeps the gate closed; verification later opens it and resumes once")
    func unverifiedLaunchKeepsGateClosed() async throws {
        var started = 0
        let provider = FakeCloudIdentityProvider(status: .unverified, recordName: Self.userA, owned: nil, shared: nil)
        let rig = try Self.makeEnv("launchUnverified", provider: provider, deferring: true, starter: { started += 1 }, prepare: {
            try $0.setBinding(Self.keyA, Self.binding("hhr_g"),
                              journals: ["hhr_g": GardenGoneRecord(reason: .absentZone, action: .rehome, phase: .journaled,
                                                                   replacementID: "hhr_new", createdAt: Date())])
        })
        await rig.env.auth.restoreSession()
        #expect(!rig.env.auth.isIdentityVerified)
        rig.env.resumeGuardAfterLaunch()
        #expect(rig.rehomer.requests.isEmpty)
        #expect(rig.env.isLaunchGuardPending)      // windows and deferred services still wait
        #expect(started == 0)

        provider.status = .available               // the account is confirmed later
        await rig.env.auth.restoreSession()
        #expect(rig.env.auth.isIdentityVerified)
        rig.env.resumeGuardAfterLaunch()
        #expect(!rig.env.isLaunchGuardPending)
        #expect(started == 1)
        #expect(rig.rehomer.requests.count == 1)
        rig.env.resumeGuardAfterLaunch()
        #expect(rig.rehomer.requests.count == 1)   // never re-issued
    }

    @Test("a launch with nothing to resume starts its background services at once")
    func cleanLaunchStartsAtOnce() throws {
        let store = GardenGuardStore(directory: GuardTestDirectory.make())
        let runner = GardenGuardRunner(store: store, rehomer: RecordingRehomer())
        #expect(runner.isLaunchResolved)
        try Self.markGone(store, Self.keyA, "hhr_g")
        #expect(runner.isLaunchResolved)   // an entry written while running is not a launch to wait for
        #expect(!GardenGuardRunner(store: store, rehomer: RecordingRehomer()).isLaunchResolved)
    }

    // MARK: - The placeholder

    @Test("the placeholder says the garden is no longer in iCloud")
    func placeholderWording() {
        #expect(GardenGonePlaceholderView.title == "This garden is no longer in iCloud")
        #expect(!GardenGonePlaceholderView.message.isEmpty)
    }
}
