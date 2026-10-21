import Foundation
import SeedkeepKit
import SwiftData
import Testing
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

    @Test func usesItsOwnDefaultsSuiteAndNeverStandard() async throws {
        defer { Self.clearFixtureSuite() }
        let homeZipKey = "seedkeep.location.homeZip"
        let identityKey = AuthController.identityCacheKey
        let standard = UserDefaults.standard
        let homeZipBefore = standard.string(forKey: homeZipKey)
        let identityBefore = standard.data(forKey: identityKey)

        let env = AppEnvironment.makeForFixture()
        await env.auth.restoreSession()

        let suite = try #require(UserDefaults(suiteName: FixtureMode.defaultsSuiteName))
        #expect(suite.string(forKey: homeZipKey) == FixtureSampleGarden.homeZip)
        #expect(suite.data(forKey: identityKey) != nil)
        #expect(standard.string(forKey: homeZipKey) == homeZipBefore)
        #expect(standard.data(forKey: identityKey) == identityBefore)
    }

    @Test func buildsNoCloudKitCoordinatorAndKeepsCloudKitOff() async throws {
        defer { Self.clearFixtureSuite() }
        let env = AppEnvironment.makeForFixture()
        #expect(!env.canUseCloudKit)

        await env.auth.restoreSession()
        // Signed in and verified, yet CloudKit stays off.
        #expect(env.activeGardenHouseholdID == FixtureCloudIdentityProvider.householdID)
        #expect(env.auth.isIdentityVerified)
        #expect(!env.canUseCloudKit)
        #expect(env.cloudKit == nil)

        // The CloudKit branch of `syncIfPossible` (what a live device runs) builds no coordinator.
        env.cloudKitSyncOverrideForTesting = true
        await env.syncIfPossible()
        #expect(!env.hasCloudCoordinator)
        #expect(!env.canUseCloudKit)
    }

    @Test func factorySeedsTheExpectedSampleGarden() throws {
        defer { Self.clearFixtureSuite() }
        let env = AppEnvironment.makeForFixture()
        let context = env.container.mainContext

        let seeds = try context.fetch(FetchDescriptor<LocalSeed>())
        #expect(seeds.count == 20)
        #expect(Set(seeds.map(\.state)) == Set(SeedState.allCases))
        #expect(seeds.allSatisfy { $0.householdID == FixtureCloudIdentityProvider.householdID })
        #expect(try context.fetchCount(FetchDescriptor<LocalBed>()) == 2)
        #expect(try context.fetchCount(FetchDescriptor<LocalPlantingEvent>()) == 9)
        #expect(try context.fetchCount(FetchDescriptor<LocalJournalEntry>()) == 5)
        #expect(try context.fetchCount(FetchDescriptor<LocalJournalChecklistItem>()) == 8)
        #expect(try context.fetchCount(FetchDescriptor<LocalTag>()) == 4)
        #expect(try context.fetchCount(FetchDescriptor<LocalLocation>()) == 3)
        #expect(env.preferences.homeClimate?.zip == FixtureSampleGarden.homeZip)
    }

}
#endif
