import Foundation
import SwiftData
import Testing
@testable import Seedkeep
import SeedkeepKit
import SeedkeepCloudKit

@Suite("Seasonal-care store")
@MainActor
struct SeasonalCareStoreTests {
    private let householdID = "hh-seasonal"

    private func fixedDate(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }

    @Test("manual mutation validates, signals after save, completes idempotently, and deletes children")
    func mutationLifecycle() throws {
        let container = makeTestContainer(name: "seasonal-store-\(UUID().uuidString)")
        let context = ModelContext(container)
        context.insert(LocalSeed(
            id: "seed1", householdID: householdID, state: .active,
            packetCount: 1, source: .store, createdAt: 1, updatedAt: 1))
        try context.save()
        var signals = 0
        let now = fixedDate("2026-07-15T12:00:00Z")
        let store = SeasonalCareStore(
            container: container,
            householdIDProvider: { householdID },
            clock: { now },
            onLocalHouseholdMutation: { signals += 1 })
        let draft = SeasonalCareTaskDraft(
            title: "Mulch", instructions: "Add mulch",
            startMonth: 7, startDay: 1, endMonth: 7, endDay: 31)
        let taskID = try store.createManual(draft, seedID: "seed1")
        #expect(signals == 1)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        try store.complete(taskID: taskID, on: now, calendar: calendar, timeZone: calendar.timeZone)
        #expect(signals == 2)
        try store.complete(taskID: taskID, on: now, calendar: calendar, timeZone: calendar.timeZone)
        #expect(signals == 2)
        let completionID = LocalSeasonalCareCompletion.id(taskID: taskID, gardenYear: 2026)
        #expect(try context.fetch(FetchDescriptor<LocalSeasonalCareCompletion>(predicate: #Predicate { $0.id == completionID })).count == 1)

        let updated = SeasonalCareTaskDraft(
            title: "Mulch well", instructions: "Add clean mulch",
            startMonth: 7, startDay: 1, endMonth: 8, endDay: 15,
            notificationEnabled: true)
        try store.update(taskID: taskID, draft: updated)
        #expect(signals == 3)
        try store.delete(taskID: taskID)
        #expect(signals == 4)
        #expect(try context.fetch(FetchDescriptor<LocalSeasonalCareCompletion>(predicate: #Predicate { $0.id == completionID })).isEmpty)
        let task = try #require(context.fetch(FetchDescriptor<LocalSeasonalCareTask>(predicate: #Predicate { $0.id == taskID })).first)
        #expect(task.deletedAt != nil)
    }

    @Test("malformed windows and foreign seeds do not emit household mutations")
    func validationAndScope() throws {
        let container = makeTestContainer(name: "seasonal-validation-\(UUID().uuidString)")
        let context = ModelContext(container)
        context.insert(LocalSeed(id: "foreign", householdID: "other", state: .active, packetCount: 1, source: .store, createdAt: 1, updatedAt: 1))
        try context.save()
        var signals = 0
        let store = SeasonalCareStore(container: container, householdIDProvider: { householdID }, onLocalHouseholdMutation: { signals += 1 })
        #expect(throws: SeasonalCareStoreError.invalidWindow(.invalidDay(month: 4, day: 31))) {
            try store.createManual(SeasonalCareTaskDraft(title: "Task", instructions: "Do it", startMonth: 4, startDay: 31, endMonth: 5, endDay: 1), seedID: "foreign")
        }
        #expect(throws: SeasonalCareStoreError.seedBelongsToAnotherHousehold) {
            try store.createManual(SeasonalCareTaskDraft(title: "Task", instructions: "Do it", startMonth: 4, startDay: 1, endMonth: 5, endDay: 1), seedID: "foreign")
        }
        #expect(signals == 0)
    }

    @Test("a fetched peer completion is found by local identity and stays idempotent")
    func fetchedCompletionIdentity() throws {
        let container = makeTestContainer(name: "seasonal-peer-completion-\(UUID().uuidString)")
        let context = ModelContext(container)
        context.insert(LocalSeed(
            id: "seed1", householdID: householdID, state: .active,
            packetCount: 1, source: .store, createdAt: 1, updatedAt: 1))
        try context.save()
        let now = fixedDate("2026-04-15T12:00:00Z")
        var signals = 0
        let store = SeasonalCareStore(
            container: container, householdIDProvider: { householdID },
            clock: { now }, onLocalHouseholdMutation: { signals += 1 })
        let taskID = try store.createManual(
            SeasonalCareTaskDraft(title: "Mulch", instructions: "Add mulch",
                                  startMonth: 4, startDay: 1, endMonth: 4, endDay: 30),
            seedID: "seed1")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let peer = SeedkeepRecordValues.seasonalCareCompletion(
            taskID: taskID, gardenYear: 2026, completedAt: 20, updatedAt: 20)
        HouseholdRecordApplier.apply(peer, householdID: householdID, into: context)
        try context.save()
        let before = signals
        try store.complete(taskID: taskID, on: now, calendar: calendar, timeZone: calendar.timeZone)
        #expect(signals == before)
        let completionID = LocalSeasonalCareCompletion.id(taskID: taskID, gardenYear: 2026)
        #expect(try context.fetch(FetchDescriptor<LocalSeasonalCareCompletion>(predicate: #Predicate {
            $0.id == completionID
        })).count == 1)
    }
}
