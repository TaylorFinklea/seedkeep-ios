#if SEEDKEEP_TEST_CLOUDKIT_ON
import Foundation
import SwiftData
import Testing
@testable import Seedkeep
import SeedkeepKit

@MainActor
@Suite("Production-default CloudKit gate", .serialized)
struct ProductionDefaultCloudKitGateTests {
    @Test("shipping default routes a household mutation to CloudKit and queues no server write")
    func productionDefaultRoutesHouseholdMutationToCloudKit() async throws {
        let defaults = UserDefaults.standard
        let key = FeatureFlags.cloudKitHouseholdSyncKey
        let previous = defaults.object(forKey: key)
        defer {
            if let previous {
                defaults.set(previous, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }

        defaults.set(false, forKey: key)
        #expect(FeatureFlags.cloudKitHouseholdSyncEnabled == false)
        defaults.removeObject(forKey: key)
        #expect(FeatureFlags.cloudKitHouseholdSyncEnabled == true)

        let container = makeTestContainer(name: "productionDefaultCloudKitGate")
        let engine = SyncEngine(container: container)
        var signals = 0
        engine.onLocalHouseholdMutation = { signals += 1 }

        let seed = try engine.enqueueCreateSeed(
            .init(state: .active, custom_name: "CloudKit gate seed"),
            householdID: "household-cloudkit-gate"
        )

        let context = ModelContext(container)
        let seedID = seed.id
        #expect(try context.fetch(FetchDescriptor<LocalSeed>(predicate: #Predicate { $0.id == seedID })).count == 1)
        #expect(signals == 1, "the CloudKit coordinator's save hook fires once")
        #expect(try context.fetch(FetchDescriptor<LocalPendingWrite>()).isEmpty)
    }
}
#endif
