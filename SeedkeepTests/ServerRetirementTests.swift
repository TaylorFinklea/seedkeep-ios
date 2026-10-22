import Foundation
import SeedkeepKit
import Testing
@testable import Seedkeep

@Suite("Apple-only server retirement", .serialized)
struct ServerRetirementTests {
    @Test("the app session refuses requests before they reach the network")
    func refusingSessionCountsAndFails() async {
        ServerRetirement.resetRefusals()
        let session = ServerRetirement.makeRefusingSession()

        do {
            _ = try await session.data(from: URL(string: "https://seedkeep-server.invalid/api/health")!)
            Issue.record("expected the retired transport to refuse the request")
        } catch let error as URLError {
            #expect(error.code == .cannotConnectToHost)
        } catch {
            Issue.record("expected cannotConnectToHost, got \(error)")
        }

        #expect(ServerRetirement.refusals.count == 1)
        #expect(ServerRetirement.refusals.lastPath == "/api/health")
    }

    @MainActor
    @Test("subscription manager construction makes no immediate server request")
    func subscriptionManagerDoesNotStartListener() {
        ServerRetirement.resetRefusals()
        let client = SeedkeepClient(configuration: .init(
            baseURL: URL(string: "https://seedkeep-server.invalid")!,
            session: ServerRetirement.makeRefusingSession()
        ))
        let manager = SubscriptionManager(client: client)

        #expect(ServerRetirement.refusals.count == 0)
        _ = manager
    }

    @Test("watering timestamps persist independently per household")
    func localWateringStateIsHouseholdScopedAndMonotonic() async {
        let suiteName = "ServerRetirementTests.\(UUID().uuidString)"
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
        let suiteName = "ServerRetirementAdapterTests.\(UUID().uuidString)"
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
