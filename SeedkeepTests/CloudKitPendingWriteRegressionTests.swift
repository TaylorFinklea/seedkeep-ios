import Foundation
import SwiftData
import Testing
@testable import Seedkeep
import SeedkeepKit

@MainActor
@Suite("CloudKit household sync pending writes", .serialized)
struct CloudKitPendingWriteRegressionTests {
    @Test("CloudKit household sync still queues an optimistic seed create")
    func cloudKitFlagDoesNotSuppressPendingWrite() throws {
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
        FeatureFlags.setCloudKitHouseholdSync(true)

        let container = makeTestContainer(name: "cloudKitPendingWriteRegressionTests")
        let client = SeedkeepClient(
            configuration: .init(baseURL: URL(string: "https://test.local")!),
            bearerToken: "test_token"
        )
        let engine = SyncEngine(client: client, container: container)

        _ = try engine.enqueueCreateSeed(
            .init(state: .active, custom_name: "Queued seed"),
            householdID: "household-cloudkit"
        )

        let context = ModelContext(container)
        let pending = try context.fetch(FetchDescriptor<LocalPendingWrite>())
        #expect(pending.count == 1)
        #expect(pending.first?.entityType == "seed")
        #expect(pending.first?.operation == "create")
    }
}
