import Foundation
import Observation
import SeedkeepKit
import SwiftData
import Testing
import UserNotifications
@testable import Seedkeep

#if DEBUG
/// Sample-garden mode through its factory, without the launch argument. Serialized because every
/// test here uses the one fixture defaults suite.
@MainActor
@Suite("Sample-garden environment (DEBUG)", .serialized)
struct FixtureEnvironmentTests {
    private static func clearFixtureSuite() {
        UserDefaults(suiteName: FixtureMode.defaultsSuiteName)?
            .removePersistentDomain(forName: FixtureMode.defaultsSuiteName)
    }

    /// A sample-garden environment whose scratch directory lives in this suite's own temporary folder,
    /// so the factory's cleanup never touches the host's real temporary directory.
    private static let isolatedTemporary = FileManager.default.temporaryDirectory
        .appendingPathComponent("fixture-tests-\(UUID().uuidString)", isDirectory: true)

    private static func makeFixture() -> AppEnvironment {
        try? FileManager.default.createDirectory(at: isolatedTemporary, withIntermediateDirectories: true)
        return AppEnvironment.makeForFixture(temporaryRoot: isolatedTemporary, installsNotificationOverride: false)
    }

    @Test func usesItsOwnDefaultsSuiteAndNeverStandard() async throws {
        defer { Self.clearFixtureSuite() }
        let homeZipKey = "seedkeep.location.homeZip"
        let identityKey = AuthController.identityCacheKey
        let standard = UserDefaults.standard
        let homeZipBefore = standard.string(forKey: homeZipKey)
        let identityBefore = standard.data(forKey: identityKey)

        let env = Self.makeFixture()
        await env.auth.restoreSession()

        let suite = try #require(UserDefaults(suiteName: FixtureMode.defaultsSuiteName))
        #expect(suite.string(forKey: homeZipKey) == FixtureSampleGarden.homeZip)
        #expect(suite.data(forKey: identityKey) != nil)
        #expect(standard.string(forKey: homeZipKey) == homeZipBefore)
        #expect(standard.data(forKey: identityKey) == identityBefore)
    }

    @Test func buildsNoCloudKitCoordinatorAndKeepsCloudKitOff() async throws {
        defer { Self.clearFixtureSuite() }
        let env = Self.makeFixture()
        #expect(!env.canUseCloudKit)

        await env.auth.restoreSession()
        // Signed in and verified, yet CloudKit stays off.
        #expect(env.activeGardenHouseholdID == FixtureCloudIdentityProvider.householdID)
        #expect(env.auth.isIdentityVerified)
        #expect(!env.canUseCloudKit)
        #expect(env.cloudKit == nil)

        // `syncIfPossible` (the CloudKit path a live device runs) builds no coordinator.
        await env.syncIfPossible()
        #expect(!env.hasCloudCoordinator)
        #expect(!env.canUseCloudKit)
        // No pass is left looking busy, so loading states settle.
        #expect(!env.isCloudSyncRunning)
        #expect(!env.isSyncingForDisplay)
    }

    @Test func aCloudSyncPassIsObservedFromItsStart() async throws {
        defer { Self.clearFixtureSuite() }
        let env = Self.makeFixture()
        #expect(!env.isSyncingForDisplay)

        // A view that read the flag while idle hears the first pass begin, although the
        // coordinator reference itself is not observed.
        let changed = ChangeFlag()
        withObservationTracking {
            _ = env.isSyncingForDisplay
        } onChange: {
            changed.fired = true
        }
        let ran = await env.runCloudSyncPass {
            #expect(env.isSyncingForDisplay)
            // An overlapping pass ending first doesn't clear the outer one.
            let inner = await env.runCloudSyncPass { true }
            #expect(inner)
            #expect(env.isSyncingForDisplay)
            return true
        }
        #expect(ran)
        #expect(changed.fired)
        #expect(!env.isSyncingForDisplay)
        #expect(env.cloudSyncPassesInFlight == 0)
    }

    @Test func factorySeedsTheExpectedSampleGarden() throws {
        defer { Self.clearFixtureSuite() }
        let env = Self.makeFixture()
        let context = env.container.mainContext

        let seeds = try context.fetch(FetchDescriptor<LocalSeed>())
        #expect(seeds.count == 20)
        #expect(Set(seeds.map(\.state)) == Set(SeedState.allCases))
        #expect(seeds.allSatisfy { $0.householdID == FixtureCloudIdentityProvider.householdID })
        #expect(try context.fetchCount(FetchDescriptor<LocalBed>()) == 2)
        #expect(try context.fetchCount(FetchDescriptor<LocalPlantingEvent>()) == 19)
        #expect(try context.fetchCount(FetchDescriptor<LocalJournalEntry>()) == 6)
        #expect(try context.fetchCount(FetchDescriptor<LocalJournalChecklistItem>()) == 8)
        #expect(try context.fetchCount(FetchDescriptor<LocalTag>()) == 4)
        #expect(try context.fetchCount(FetchDescriptor<LocalLocation>()) == 3)
        #expect(env.preferences.homeClimate?.zip == FixtureSampleGarden.homeZip)
    }

    @Test func fixtureSessionLeavesStandardWhatsNewAndNotificationKeysAlone() async throws {
        defer { Self.clearFixtureSuite() }
        let standard = UserDefaults.standard
        let notificationKeys = [
            "seedkeep.notif.frost", "seedkeep.notif.heat", "seedkeep.notif.water",
            "seedkeep.notif.events",
            "seedkeep.notif.pet.wilted", "seedkeep.notif.pet.departed", "seedkeep.notif.pet.roundup",
        ]
        let keys = [WhatsNewGate.lastSeenBuildKey] + notificationKeys
        let snapshot = { (defaults: UserDefaults) in
            keys.map { defaults.object(forKey: $0).map { String(describing: $0) } }
        }
        let before = snapshot(standard)

        let env = Self.makeFixture()
        await env.auth.restoreSession()

        // The What's New baseline and the notification toggles go through the store the app selects
        // in sample-garden mode, so the fixture suite takes the writes.
        let store = DevicePreferences.store(isFixture: true)
        WhatsNewGate.markSeen(build: 99, defaults: store)
        for key in notificationKeys { store.set(true, forKey: key) }
        #expect(WhatsNewGate.lastSeenBuild(defaults: store) == 99)
        #expect(store.bool(forKey: "seedkeep.notif.frost"))
        #expect(snapshot(standard) == before)
    }

    @Test func launchRootIsFreshAndOlderFixtureDirectoriesAreRemoved() throws {
        let fileManager = FileManager.default
        let base = fileManager.temporaryDirectory
            .appendingPathComponent("fixture-root-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: base) }
        for name in ["seedkeep-fixture", "seedkeep-fixture-\(UUID().uuidString)", "unrelated"] {
            try fileManager.createDirectory(
                at: base.appendingPathComponent(name, isDirectory: true),
                withIntermediateDirectories: true
            )
        }

        let id = UUID()
        let root = FixtureMode.prepareLaunchRoot(in: base, id: id)

        #expect(root.lastPathComponent == "seedkeep-fixture-\(id.uuidString)")
        // Every older fixture directory is gone; a directory the fixture doesn't own is kept.
        #expect(try fileManager.contentsOfDirectory(atPath: base.path) == ["unrelated"])
    }

    @Test func fixtureAPIKeysStayInMemoryAcrossLaunches() {
        defer { Self.clearFixtureSuite() }
        let first = Self.makeFixture()
        first.apiKeys.save(.anthropic, key: "test-key-not-real")
        #expect(first.apiKeys.has(.anthropic))

        // A Keychain item would survive into the next launch. The fixture's in-memory store does not.
        let second = Self.makeFixture()
        #expect(!second.apiKeys.has(.anthropic))
    }

    @Test func fixtureNotificationStatusIsAuthorizedWithoutAskingTheSystem() async {
        // The status a sample-garden launch installs. Tests never install it: the override is
        // process-wide and other suites own it.
        #expect(await FixtureMode.authorizationStatus() == .authorized)
        #expect(!FixtureMode.isEnabled)
    }

    @Test func cleanupRemovesOnlyDirectoriesTheFixtureOwns() {
        #expect(FixtureMode.isFixtureRootName("seedkeep-fixture"))
        #expect(FixtureMode.isFixtureRootName("seedkeep-fixture-\(UUID().uuidString)"))
        #expect(!FixtureMode.isFixtureRootName("seedkeep-fixture-backup"))
        #expect(!FixtureMode.isFixtureRootName("seedkeep-fixtures"))
        #expect(!FixtureMode.isFixtureRootName("unrelated"))
    }

    @Test func fixtureLaunchStartsSeedsUngrouped() {
        defer { Self.clearFixtureSuite() }
        let store = DevicePreferences.store(isFixture: true)
        store.set(true, forKey: "library.groupByType")

        // The launch wipes the fixture suite, so the Seeds list starts ungrouped on every launch.
        _ = Self.makeFixture()
        #expect(store.object(forKey: "library.groupByType") == nil)
    }

}
#endif

/// Records that an observation fired.
private final class ChangeFlag: @unchecked Sendable {
    var fired = false
}
