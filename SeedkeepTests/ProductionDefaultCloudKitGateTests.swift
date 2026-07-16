#if SEEDKEEP_TEST_CLOUDKIT_ON
import Foundation
import SwiftData
import Testing
@testable import Seedkeep
import SeedkeepKit

@MainActor
@Suite("Production-default CloudKit gate", .serialized)
struct ProductionDefaultCloudKitGateTests {
    @Test("shipping default routes a household mutation away from legacy POST flush")
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

        let emptyFeed = Data(#"{"ok":true,"data":{"items":[],"cursor":0,"has_more":false}}"#.utf8)
        let session = CatalogRouterMockURLProtocol.makeSession(
            fallbackBody: emptyFeed,
            fallbackStatus: 200
        )
        let client = SeedkeepClient(
            configuration: .init(baseURL: URL(string: "https://test.local")!, session: session),
            bearerToken: "test"
        )
        let container = makeTestContainer(name: "productionDefaultCloudKitGate")
        let engine = SyncEngine(client: client, container: container)

        _ = try engine.enqueueCreateSeed(
            .init(state: .active, custom_name: "CloudKit gate seed"),
            householdID: "household-cloudkit-gate"
        )
        _ = await engine.syncAll(householdID: "household-cloudkit-gate")

        let context = ModelContext(container)
        let pending = try context.fetch(FetchDescriptor<LocalPendingWrite>())
        #expect(pending.count == 1)
        #expect(CatalogRouterMockURLProtocol.capturedMethodPaths().filter { $0.method == "POST" }.isEmpty)
    }
}
#endif
