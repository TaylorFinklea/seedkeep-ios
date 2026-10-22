import Foundation
import SeedkeepKit
import Testing
@testable import Seedkeep

// Moved from ServerRetirementTests when N3 (F) deleted `ServerRetirement`: the watering ledger is
// live on-device state, used by the weather warnings.
@Suite("Local watering state")
struct LocalWateringStateClientTests {
    @Test("watering timestamps persist independently per household")
    func localWateringStateIsHouseholdScopedAndMonotonic() async {
        let suiteName = "LocalWateringStateClientTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let client = LocalWateringStateClient(defaults: defaults)
        let first = Date(timeIntervalSince1970: 1_000)
        let later = Date(timeIntervalSince1970: 2_000)

        let firstPut = await client.put(householdID: "garden-a", scheduledFor: first)
        let secondPut = await client.put(householdID: "garden-a", scheduledFor: later)
        let olderPut = await client.put(householdID: "garden-a", scheduledFor: first)
        let otherGarden = await client.get(householdID: "garden-b")
        let firstGarden = await client.get(householdID: "garden-a")

        #expect((try? firstPut.get()) == first)
        #expect((try? secondPut.get()) == later)
        #expect((try? olderPut.get()) == later)
        #expect((try? otherGarden.get()) == nil)
        #expect((try? firstGarden.get()) == later)
    }

    @Test("separate watering adapters cannot regress a shared timestamp")
    func localWateringAdaptersSerializeWrites() async {
        let suiteName = "LocalWateringStateClientAdapterTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let firstClient = LocalWateringStateClient(defaults: defaults)
        let secondClient = LocalWateringStateClient(defaults: defaults)
        let earlier = Date(timeIntervalSince1970: 1_000)
        let later = Date(timeIntervalSince1970: 2_000)

        async let earlierWrite = firstClient.put(householdID: "shared-garden", scheduledFor: earlier)
        async let laterWrite = secondClient.put(householdID: "shared-garden", scheduledFor: later)
        _ = await (earlierWrite, laterWrite)
        let saved = await firstClient.get(householdID: "shared-garden")

        #expect((try? saved.get()) == later)
    }
}
