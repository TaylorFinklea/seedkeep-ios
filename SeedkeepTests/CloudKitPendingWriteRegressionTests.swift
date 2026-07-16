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

    @Test("every queue-backed household mutation signals exactly once")
    func everyQueueBackedMutationSignalsExactlyOnce() throws {
        let container = makeTestContainer(name: "queueBackedMutationSignalContract")
        let client = SeedkeepClient(
            configuration: .init(baseURL: URL(string: "https://test.local")!),
            bearerToken: "test_token"
        )
        let engine = SyncEngine(client: client, container: container)
        var signalCount = 0
        engine.onLocalHouseholdMutation = { signalCount += 1 }
        let householdID = "household-cloudkit"

        let location = try engine.enqueueCreateLocation(name: "Shed", householdID: householdID)
        try engine.enqueueUpdateLocation(id: location.id, name: "Barn", sortOrder: nil)
        try engine.enqueueDeleteLocation(id: location.id)
        #expect(signalCount == 3)

        let tag = try engine.enqueueCreateTag(name: "Heirloom", color: nil, householdID: householdID)
        try engine.enqueueUpdateTag(id: tag.id, name: "Saved", color: nil)
        try engine.enqueueDeleteTag(id: tag.id)
        #expect(signalCount == 6)

        let seed = try engine.enqueueCreateSeed(
            .init(state: .active, custom_name: "Queued seed"),
            householdID: householdID
        )
        try engine.enqueueUpdateSeed(id: seed.id, .init(notes: "Water daily"))
        try engine.enqueueDeleteSeed(id: seed.id)
        #expect(signalCount == 9)

        let bed = try engine.enqueueCreateBed(.init(name: "North bed"), householdID: householdID)
        try engine.enqueueUpdateBed(id: bed.id, .init(name: "South bed"))
        try engine.enqueueDeleteBed(id: bed.id)
        #expect(signalCount == 12)

        let event = try engine.enqueueCreatePlantingEvent(
            .init(kind: .sowing, planned_for: "2026-07-15"),
            householdID: householdID
        )
        try engine.enqueueUpdatePlantingEvent(id: event.id, .init(notes: "Thinned"))
        try engine.enqueueDeletePlantingEvent(id: event.id)
        #expect(signalCount == 15)
    }
}
