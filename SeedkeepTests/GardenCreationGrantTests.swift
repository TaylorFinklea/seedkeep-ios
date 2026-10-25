import CloudKit
import Foundation
import SwiftData
import Testing
@testable import Seedkeep
import SeedkeepCloudKit

/// N2-E (G1) §2: zones are created only through a creation grant. Every test runs the real
/// `HouseholdCloudCoordinator` over `FakeEngine` and `FakeGardenProvisioner`; no CloudKit.
@MainActor
@Suite("Garden creation grants", .serialized)
struct GardenCreationGrantTests {
    private static let account = GardenGuardStore.accountKey(recordName: "_userA")

    private struct Rig {
        let coordinator: HouseholdCloudCoordinator
        let provisioner: FakeGardenProvisioner
        let store: GardenGuardStore
        let rehomer: RecordingRehomer
        let engine: HouseholdCloudCoordinatorTests.FakeEngine
        let householdID: String
    }

    private static func rig(
        householdID: String, store: GardenGuardStore? = nil, provisioner: FakeGardenProvisioner? = nil,
        rehomer: RecordingRehomer? = nil, grant: Bool, fresh: @escaping () -> String = { "hhr_fresh-" + UUID().uuidString }
    ) throws -> Rig {
        let store = store ?? GardenGuardStore(directory: GuardTestDirectory.make())
        let provisioner = provisioner ?? FakeGardenProvisioner()
        let rehomer = rehomer ?? RecordingRehomer()
        let engine = HouseholdCloudCoordinatorTests.FakeEngine()
        let binding = GardenGuardBinding(
            household: .init(id: householdID, name: "Test House", createdAt: 1, updatedAt: 1), participant: nil)
        try store.setBinding(account, binding, newGrants: grant ? [householdID] : [])
        let coordinator = HouseholdCloudCoordinator(
            engine: engine,
            zoneID: SeedkeepZoneProvisioner.zoneID(householdID: householdID),
            householdID: householdID, householdName: "Test House",
            householdCreatedAt: 1, householdUpdatedAt: 1,
            container: makeTestContainer(name: "grant-\(UUID().uuidString)"),
            provisioner: provisioner, stateURL: nil)
        coordinator.guardContext = GardenGuardContext(
            store: store, accountKey: { account }, rehomer: rehomer, makeFreshID: fresh)
        return Rig(coordinator: coordinator, provisioner: provisioner, store: store, rehomer: rehomer,
                   engine: engine, householdID: householdID)
    }

    // MARK: - A grant creates exactly once

    @Test("a pending grant creates the garden once, with the generation from the server result")
    func grantCreatesOnce() async throws {
        let id = "hhr_\(UUID().uuidString)"
        let rig = try Self.rig(householdID: id, grant: true)
        rig.provisioner.script(FakeGardenProvisioner.createdOutcome(
            householdID: id, creationDate: Date(timeIntervalSince1970: 1_234.5)))
        await rig.coordinator.sync()
        #expect(rig.provisioner.zoneSaves == [id])
        #expect(rig.provisioner.rootSaves == [id])
        #expect(rig.provisioner.ensureHouseholdCalls.isEmpty)   // none of the established checks apply
        #expect(rig.store.grant(Self.account, id) == nil)       // consumed...
        #expect(rig.store.seen(Self.account, id)?.generation == 1_234_500)   // ...with the generation, together
        #expect(rig.coordinator.lastHumanizedError == nil)

        await rig.coordinator.sync()
        #expect(rig.provisioner.zoneSaves == [id])   // never a second creation
    }

    @Test("a consumed grant is not a grant: a fresh coordinator for the same garden creates nothing")
    func consumedGrantNeverRecreates() async throws {
        let id = "hhr_\(UUID().uuidString)"
        let first = try Self.rig(householdID: id, grant: true)
        await first.coordinator.sync()
        let again = try Self.rig(householdID: id, store: first.store, provisioner: first.provisioner, grant: false)
        again.provisioner.setExistingRoot(householdID: id)
        await again.coordinator.sync()
        #expect(first.provisioner.zoneSaves == [id])
    }

    // MARK: - Undispatched keeps pending; dispatched non-success abandons

    @Test("an undispatched request keeps the grant pending and abandons nothing")
    func undispatchedKeepsPending() async throws {
        let id = "hhr_\(UUID().uuidString)"
        let rig = try Self.rig(householdID: id, grant: true)
        // sync() retries a transient error once, so the script covers both attempts.
        rig.provisioner.script(.notDispatched(CKError(.networkUnavailable)),
                               .notDispatched(CKError(.networkUnavailable)))
        await rig.coordinator.sync()
        #expect(rig.store.grant(Self.account, id)?.state == .pending)
        #expect(!rig.store.isRetired(Self.account, id))
        #expect(rig.store.seen(Self.account, id) == nil)
        #expect(rig.rehomer.requests.isEmpty)
        #expect(rig.coordinator.lastHumanizedError != nil)
    }

    @Test("every dispatched non-success abandons the ID and hands it to the re-home seam")
    func dispatchedNonSuccessAbandons() async throws {
        let id = "hhr_\(UUID().uuidString)"
        let rig = try Self.rig(householdID: id, grant: true, fresh: { "hhr_replacement" })
        rig.provisioner.script(.abandoned(reason: "zone save failed"))
        await rig.coordinator.sync()

        #expect(rig.store.isRetired(Self.account, id))
        #expect(rig.store.grant(Self.account, id) == nil)
        #expect(rig.store.grant(Self.account, "hhr_replacement")?.state == .pending)
        #expect(rig.store.journal(Self.account, id)?.replacementID == "hhr_replacement")
        #expect(rig.rehomer.requests == [GardenRehomeRequest(
            accountKey: Self.account, fromHouseholdID: id, toHouseholdID: "hhr_replacement", reason: .abandonedGrant)])
        #expect(rig.store.seen(Self.account, id) == nil)
    }

    @Test("after an abandonment creation waits for the next launch or Sync now")
    func abandonmentWaits() async throws {
        let id = "hhr_\(UUID().uuidString)"
        let rig = try Self.rig(householdID: id, grant: true, fresh: { "hhr_replacement" })
        rig.provisioner.script(.abandoned(reason: "x"))
        await rig.coordinator.sync()
        #expect(rig.provisioner.zoneSaves.count == 1)

        // The same process: the replacement's coordinator creates nothing while the hold is on.
        let next = try Self.rig(householdID: "hhr_replacement", store: rig.store,
                                provisioner: rig.provisioner, grant: false)
        await next.coordinator.sync()
        #expect(rig.provisioner.zoneSaves.count == 1)
        #expect(rig.store.grant(Self.account, "hhr_replacement")?.state == .pending)

        // Sync now (or the next launch, which has no hold) lets it go ahead.
        rig.store.releaseCreationHolds()
        await next.coordinator.sync()
        #expect(rig.provisioner.zoneSaves == [id, "hhr_replacement"])
    }

    @Test("a retired garden is never created or written again")
    func retiredGardenSendsNothing() async throws {
        let id = "hhr_\(UUID().uuidString)"
        let rig = try Self.rig(householdID: id, grant: true, fresh: { "hhr_replacement" })
        rig.provisioner.script(.abandoned(reason: "x"))
        await rig.coordinator.sync()
        rig.store.releaseCreationHolds()
        await rig.coordinator.sync()
        #expect(rig.provisioner.zoneSaves == [id])
        #expect(rig.provisioner.ensureHouseholdCalls.isEmpty)
    }

    @Test("three abandonments in 24 hours pause creation until Try again")
    func pauseAfterThree() async throws {
        let store = GardenGuardStore(directory: GuardTestDirectory.make())
        let provisioner = FakeGardenProvisioner()
        var ids = ["hhr_one"]
        for index in 0..<3 {
            let next = "hhr_\(["two", "three", "four"][index])"
            let rig = try Self.rig(householdID: ids.last!, store: store, provisioner: provisioner,
                                   grant: index == 0, fresh: { next })
            provisioner.script(.abandoned(reason: "x"))
            store.releaseCreationHolds()
            await rig.coordinator.sync()
            ids.append(next)
        }
        #expect(provisioner.zoneSaves.count == 3)
        #expect(store.isCreationPaused(Self.account))

        let paused = try Self.rig(householdID: "hhr_four", store: store, provisioner: provisioner, grant: false)
        store.releaseCreationHolds()
        await paused.coordinator.sync()
        #expect(provisioner.zoneSaves.count == 3)   // paused: nothing created
        #expect(store.grant(Self.account, "hhr_four")?.state == .pending)
        #expect(paused.coordinator.lastHumanizedError?.contains("Settings") == true)

        try store.resumeCreation(Self.account)
        await paused.coordinator.sync()
        #expect(provisioner.zoneSaves.count == 4)
        #expect(store.seen(Self.account, "hhr_four") != nil)
    }

    // MARK: - Start order

    @Test("an attempting grant is abandoned, never completed")
    func attemptingIsAbandoned() async throws {
        let id = "hhr_\(UUID().uuidString)"
        let rig = try Self.rig(householdID: id, grant: true, fresh: { "hhr_replacement" })
        try rig.store.markAttempting(Self.account, id)
        await rig.coordinator.sync()
        #expect(rig.provisioner.totalCreations == 0)
        #expect(rig.provisioner.ensureHouseholdCalls.isEmpty)
        #expect(rig.store.isRetired(Self.account, id))
        #expect(rig.store.grant(Self.account, "hhr_replacement")?.state == .pending)
        #expect(rig.rehomer.requests.count == 1)
    }

    @Test("a garden with no grant takes the established branch and creates nothing")
    func establishedBranchNeverCreates() async throws {
        let id = "legacy-\(UUID().uuidString)"
        let rig = try Self.rig(householdID: id, grant: false)
        rig.provisioner.setExistingRoot(householdID: id)
        await rig.coordinator.sync()
        #expect(rig.provisioner.ensureHouseholdCalls == [id])
        #expect(rig.provisioner.totalCreations == 0)
        #expect(rig.store.isSeen(Self.account, id))   // recorded, so it can be shared
        #expect(rig.store.seen(Self.account, id)?.generation == nil)
        #expect(rig.coordinator.lastHumanizedError == nil)
    }

    // MARK: - Existing gardens never create a zone

    @Test("an existing garden whose zone is missing creates nothing, at startup or on a later save")
    func missingZoneIsNeverRecreated() async throws {
        let id = "legacy-\(UUID().uuidString)"
        let rig = try Self.rig(householdID: id, grant: false)   // no root: ensureHousehold throws zoneNotFound
        await rig.coordinator.sync()
        #expect(rig.coordinator.lastHumanizedError != nil)
        await rig.coordinator.sync()
        #expect(rig.provisioner.totalCreations == 0)
        #expect(rig.engine.savedRecords.isEmpty)   // nothing is sent into a zone that isn't there
    }

    @Test("a lost attempting grant (Reset) never recreates its zone")
    func lostGrantNeverRecreates() async throws {
        let id = "hhr_\(UUID().uuidString)"
        let rig = try Self.rig(householdID: id, grant: true)
        try rig.store.markAttempting(Self.account, id)
        try rig.store.reset()   // every grant is gone
        await rig.coordinator.sync()
        #expect(rig.provisioner.totalCreations == 0)
    }

    @Test("an unreadable guard sends nothing for any garden")
    func unreadableGuardBlocksSends() async throws {
        let dir = GuardTestDirectory.make()
        let id = "hhr_\(UUID().uuidString)"
        let rig = try Self.rig(householdID: id, store: GardenGuardStore(directory: dir), grant: true)
        try Data("corrupt".utf8).write(to: rig.store.fileURL!)
        rig.store.tryAgain()
        #expect(!rig.store.isReadable)
        await rig.coordinator.sync()
        #expect(rig.provisioner.totalCreations == 0)
        #expect(rig.provisioner.ensureHouseholdCalls.isEmpty)
        #expect(rig.engine.savedRecords.isEmpty)
    }

    @Test("share preparation needs a seen garden and never reaches the zone provisioner")
    func sharePreparationRequiresSeenGarden() async throws {
        let suite = "GardenCreationGrantTests.share.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data("""
        {"user":{"id":"_userA","name":null,"email":null},"household":{"id":"hhr_unseen","name":"G","created_at":1,"updated_at":1}}
        """.utf8), forKey: AuthController.identityCacheKey)
        let store = GardenGuardStore(directory: nil)
        let env = AppEnvironment.makeForTesting(
            identity: FakeCloudIdentityProvider(owned: [], shared: []), tokenStore: InMemoryTokenStore(),
            defaults: defaults, container: makeTestContainer(name: "share-\(UUID().uuidString)"),
            durableStateDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("share-\(UUID().uuidString)", isDirectory: true),
            cloudCoordinators: FakeCloudCoordinators().factory, gardenGuard: store)
        await env.auth.restoreSession()
        // A seen garden would reach the live share flow, which tests never do: only the refusal is checked.
        #expect(!store.isSeen(Self.account, "hhr_unseen"))
        let prepared = await env.prepareOwnerShare()
        #expect(prepared == nil)
        #expect(env.bannerError != nil)
    }

    @Test("trust on first use records the existing root's server creationDate as the generation")
    func establishedRootRecordsGeneration() async throws {
        let id = "legacy-\(UUID().uuidString)"
        let rig = try Self.rig(householdID: id, grant: false)
        rig.provisioner.setExistingRoot(householdID: id, creationDate: Date(timeIntervalSince1970: 2_000))
        await rig.coordinator.sync()
        #expect(rig.store.seen(Self.account, id)?.generation == 2_000_000)
    }

    @Test("Settings content is hidden while the guard is unreadable, and a failed Reset keeps its error")
    func blockedGates() {
        #expect(SettingsPolicy.showsContent(guardReadable: true))
        #expect(!SettingsPolicy.showsContent(guardReadable: false))
        #expect(GardenGuardBlockedView.failureText(readable: false, existing: "Reset failed") == "Reset failed")
        #expect(GardenGuardBlockedView.failureText(readable: false, existing: nil) == "It still can't be read.")
        #expect(GardenGuardBlockedView.failureText(readable: true, existing: "old") == nil)
    }

    @Test("a fresh random ID is a valid zone name")
    func freshIDIsValidZoneName() {
        let id = GardenHouseholdID.make()
        let zoneName = SeedkeepRecordNames.zoneName(householdID: id)
        #expect(id.hasPrefix("hhr_"))
        #expect(GardenHouseholdID.isRandomFormat(id))
        #expect(!GardenHouseholdID.isRandomFormat(DeterministicHouseholdID.make(userRecordName: "_x")))
        #expect(zoneName.utf8.count <= 255)
        #expect(zoneName.allSatisfy { $0.isASCII })
        #expect(SeedkeepRecordNames.householdID(fromZoneName: zoneName) == id)
        #expect(GardenHouseholdID.make() != id)
    }
}
