import Foundation
import Testing
@preconcurrency import UserNotifications
@testable import Seedkeep

@Suite("Seasonal-care reminder reconciliation")
@MainActor
struct SeasonalCareReminderReconcilerTests {
    private let fireDate: Date = {
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = TimeZone(secondsFromGMT: 0)
        components.year = 2027
        components.month = 4
        components.day = 1
        components.hour = 9
        return components.date!
    }()

    private func item(
        taskID: String = "task-1",
        year: Int = 2027,
        title: String = "Check mulch"
    ) -> SeasonalCareReminderItem {
        SeasonalCareReminderItem(
            taskID: taskID,
            gardenYear: year,
            title: title,
            seedName: "Strawberry",
            fireDate: fireDate,
            timeZoneIdentifier: "UTC"
        )
    }

    @Test("default-off reconciliation never requests authorization")
    func defaultOff() async {
        let scheduler = MockNotificationScheduler()
        scheduler.setAuthorizationStatus(.notDetermined)
        let reconciler = SeasonalCareReminderReconciler(scheduler: scheduler)

        let outcome = await reconciler.reconcile(items: [], householdID: "household-1")

        #expect(outcome == .disabled)
        #expect(scheduler.authorizationStatusReadCount == 0)
        #expect(scheduler.recordedAdds.isEmpty)
    }

    @Test("denied authorization preserves in-app task use")
    func deniedAuthorization() async {
        let scheduler = MockNotificationScheduler()
        scheduler.setAuthorizationStatus(.denied)
        let reconciler = SeasonalCareReminderReconciler(scheduler: scheduler)

        let outcome = await reconciler.reconcile(items: [item()], householdID: "household-1")

        #expect(outcome == .permissionDenied)
        #expect(scheduler.recordedAdds.isEmpty)
    }

    @Test("reconciliation replaces stale care requests and preserves unrelated reminders")
    func diffsOnlyCareIDs() async {
        let scheduler = MockNotificationScheduler()
        scheduler.seedPending([
            request(id: SeasonalCareReminderReconciler.identifier(taskID: "task-1", gardenYear: 2027), title: "Old title"),
            request(id: "seedkeep.weather.frost.1", title: "Frost warning"),
            request(id: SeasonalCareReminderReconciler.identifier(taskID: "deleted", gardenYear: 2027), title: "Deleted")
        ])
        let reconciler = SeasonalCareReminderReconciler(scheduler: scheduler)

        let outcome = await reconciler.reconcile(items: [item()], householdID: "household-1")

        #expect(outcome == .reconciled(scheduled: 1, removed: 2))
        #expect(scheduler.pendingSnapshot.map(\.identifier).contains("seedkeep.weather.frost.1"))
        #expect(scheduler.pendingSnapshot.map(\.identifier).contains(item().identifier))
        #expect(!scheduler.pendingSnapshot.map(\.identifier).contains(SeasonalCareReminderReconciler.identifier(taskID: "deleted", gardenYear: 2027)))
    }

    @Test("request keeps the occurrence year and timezone")
    func requestDateComponents() async {
        let scheduler = MockNotificationScheduler()
        let reconciler = SeasonalCareReminderReconciler(scheduler: scheduler)

        _ = await reconciler.reconcile(items: [item()], householdID: "household-1")

        let trigger = scheduler.recordedAdds.first?.trigger as? UNCalendarNotificationTrigger
        #expect(trigger?.dateComponents.year == 2027)
        #expect(trigger?.dateComponents.month == 4)
        #expect(trigger?.dateComponents.day == 1)
        #expect(trigger?.dateComponents.timeZone?.identifier == "UTC")
    }

    @Test("mixed add failures report a partial scheduling failure")
    func mixedFailure() async {
        struct AddError: Error {}
        let scheduler = MockNotificationScheduler()
        scheduler.setFailureMode(.failFirstNAdds(1, AddError()))
        let reconciler = SeasonalCareReminderReconciler(scheduler: scheduler)

        let outcome = await reconciler.reconcile(
            items: [item(taskID: "task-1"), item(taskID: "task-2")],
            householdID: "household-1"
        )

        #expect(outcome == .schedulingFailed(attempted: 2, scheduled: 1))
    }

    @Test("late same-ID generation cannot remove the newer request")
    func overlappingGenerations() async {
        let scheduler = SuspendedNotificationScheduler()
        await scheduler.blockNextAdd()
        let reconciler = SeasonalCareReminderReconciler(scheduler: scheduler)

        let first = Task { @MainActor in
            await reconciler.reconcile(items: [item(title: "Old title")], householdID: "old-household")
        }
        await scheduler.waitForAddStarted()
        let second = Task { @MainActor in
            await reconciler.reconcile(items: [item(title: "New title")], householdID: "new-household")
        }
        await scheduler.releaseAdd()
        _ = await first.value
        _ = await second.value

        let pending = await scheduler.pendingSnapshot()
        #expect(pending.count == 1)
        #expect(pending.first?.content.title == "New title")
    }

    @Test("cancelAll racing a new household pass leaves the new request")
    func cancellationRace() async {
        let scheduler = SuspendedNotificationScheduler()
        await scheduler.blockNextAdd()
        let reconciler = SeasonalCareReminderReconciler(scheduler: scheduler)

        let first = Task { @MainActor in
            await reconciler.reconcile(items: [item(title: "Old title")], householdID: "old-household")
        }
        await scheduler.waitForAddStarted()
        let cancellation = Task { @MainActor in
            await reconciler.cancelAll()
        }
        let second = Task { @MainActor in
            await reconciler.reconcile(items: [item(title: "New title")], householdID: "new-household")
        }
        await scheduler.releaseAdd()
        _ = await first.value
        await cancellation.value
        _ = await second.value

        let pending = await scheduler.pendingSnapshot()
        #expect(pending.count == 1)
        #expect(pending.first?.content.title == "New title")
    }

    @Test("sign-out cancellation removes care requests only")
    func cancellation() async {
        let scheduler = MockNotificationScheduler()
        scheduler.seedPending([
            request(id: SeasonalCareReminderReconciler.identifier(taskID: "task-1", gardenYear: 2027), title: "Care"),
            request(id: "seedkeep.planting.1", title: "Planting")
        ])
        let reconciler = SeasonalCareReminderReconciler(scheduler: scheduler)

        await reconciler.cancelAll()

        #expect(scheduler.pendingSnapshot.map(\.identifier) == ["seedkeep.planting.1"])
        #expect(scheduler.recordedRemovals.flatMap { $0 }.contains(item().identifier))
        #expect(!scheduler.recordedRemovals.flatMap { $0 }.contains("seedkeep.planting.1"))
    }

    private func request(id: String, title: String) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = "Body"
        return UNNotificationRequest(identifier: id, content: content, trigger: nil)
    }
}

private actor SuspendedNotificationScheduler: NotificationScheduler {
    private var status: UNAuthorizationStatus = .authorized
    private var pending: [UNNotificationRequest] = []
    private var shouldBlockNextAdd = false
    private var addStarted = false
    private var addContinuation: CheckedContinuation<Void, Never>?

    func blockNextAdd() {
        shouldBlockNextAdd = true
    }

    func waitForAddStarted() async {
        while !addStarted {
            await Task.yield()
        }
    }

    func releaseAdd() {
        addContinuation?.resume()
        addContinuation = nil
    }

    func pendingSnapshot() -> [UNNotificationRequest] {
        pending
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        status
    }

    func requestAuthorization(options: UNAuthorizationOptions) async -> Bool {
        status = .authorized
        return true
    }

    func pendingNotificationRequests() async -> [UNNotificationRequest] {
        pending
    }

    func add(_ request: UNNotificationRequest) async throws {
        if shouldBlockNextAdd {
            shouldBlockNextAdd = false
            addStarted = true
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                addContinuation = continuation
            }
        }
        pending.removeAll { $0.identifier == request.identifier }
        pending.append(request)
    }

    func removePendingNotificationRequests(withIdentifiers ids: [String]) async {
        let idSet = Set(ids)
        pending.removeAll { idSet.contains($0.identifier) }
    }
}
