import Foundation
@preconcurrency import UserNotifications

/// One committed, incomplete occurrence that is eligible for a local reminder.
/// The caller supplies only the next occurrence, so reconciliation never
/// re-evaluates recurrence or reaches into SwiftData.
public struct SeasonalCareReminderItem: Equatable, Sendable {
    public let taskID: String
    public let gardenYear: Int
    public let title: String
    public let seedName: String
    public let fireDate: Date
    public let timeZoneIdentifier: String

    public init(
        taskID: String,
        gardenYear: Int,
        title: String,
        seedName: String,
        fireDate: Date,
        timeZoneIdentifier: String
    ) {
        self.taskID = taskID
        self.gardenYear = gardenYear
        self.title = title
        self.seedName = seedName
        self.fireDate = fireDate
        self.timeZoneIdentifier = timeZoneIdentifier
    }

    public var identifier: String {
        SeasonalCareReminderReconciler.identifier(taskID: taskID, gardenYear: gardenYear)
    }
}

public enum SeasonalCareReminderOutcome: Equatable, Sendable {
    case disabled
    case reconciled(scheduled: Int, removed: Int)
    case permissionDenied
    case schedulingFailed(attempted: Int, scheduled: Int)
    case cancelled
}

/// Diff-based local reminder reconciliation for committed seasonal-care rows.
///
/// The generation token is deliberately local to this owner. A sign-out or
/// household switch can invalidate an in-flight pass before it adds a request;
/// a late add is removed immediately after it returns.
@MainActor
public final class SeasonalCareReminderReconciler {
    nonisolated public static let identifierPrefix = "seedkeep.care."

    private let scheduler: any NotificationScheduler
    private var generation: UInt64 = 0
    private var latestDesired: [String: SeasonalCareReminderItem] = [:]
    private var mutationTail: Task<Void, Never>?

    init(scheduler: any NotificationScheduler) {
        self.scheduler = scheduler
    }

    nonisolated public static func identifier(taskID: String, gardenYear: Int) -> String {
        "\(identifierPrefix)\(taskID).\(gardenYear)"
    }

    /// Reconciles the desired requests for one active household.
    ///
    /// `items` should contain only notification-enabled, incomplete future
    /// occurrences. Passing an empty array is the default-off path: it clears
    /// stale care requests without checking or requesting authorization.
    public func reconcile(
        items: [SeasonalCareReminderItem],
        householdID: String?,
        allowAuthorizationRequest: Bool = false
    ) async -> SeasonalCareReminderOutcome {
        generation &+= 1
        let pass = generation
        let desired = items.reduce(into: [String: SeasonalCareReminderItem]()) {
            $0[$1.identifier] = $1
        }
        latestDesired = desired
        return await enqueue { [weak self] in
            guard let self else { return .cancelled }
            return await self.reconcileNow(
                desired: desired,
                householdID: householdID,
                pass: pass,
                allowAuthorizationRequest: allowAuthorizationRequest
            )
        }
    }

    private func reconcileNow(
        desired: [String: SeasonalCareReminderItem],
        householdID: String?,
        pass: UInt64,
        allowAuthorizationRequest: Bool
    ) async -> SeasonalCareReminderOutcome {
        let pending = await scheduler.pendingNotificationRequests()
        guard pass == generation else { return .cancelled }

        let carePending = pending.filter { $0.identifier.hasPrefix(Self.identifierPrefix) }
        let pendingByID = carePending.reduce(into: [String: UNNotificationRequest]()) {
            $0[$1.identifier] = $1
        }

        // A nil household is the sign-out/identity transition path. It still
        // removes only this feature's requests and never touches weather or
        // planting-event reminders.
        if householdID == nil {
            let ids = carePending.map(\.identifier)
            if !ids.isEmpty { await scheduler.removePendingNotificationRequests(withIdentifiers: ids) }
            return pass == generation ? .reconciled(scheduled: 0, removed: ids.count) : .cancelled
        }

        guard !desired.isEmpty else {
            let ids = carePending.map(\.identifier)
            if !ids.isEmpty { await scheduler.removePendingNotificationRequests(withIdentifiers: ids) }
            return pass == generation ? .disabled : .cancelled
        }

        var status = await scheduler.authorizationStatus()
        guard pass == generation else { return .cancelled }
        if status == .notDetermined, allowAuthorizationRequest {
            let granted = await scheduler.requestAuthorization(options: [.alert, .sound])
            guard pass == generation else { return .cancelled }
            guard granted else {
                let ids = carePending.map(\.identifier)
                if !ids.isEmpty { await scheduler.removePendingNotificationRequests(withIdentifiers: ids) }
                return .permissionDenied
            }
            status = await scheduler.authorizationStatus()
            guard pass == generation else { return .cancelled }
        }

        if status == .notDetermined {
            return .permissionDenied
        }

        let grantedStatuses: Set<UNAuthorizationStatus> = [.authorized, .provisional, .ephemeral]
        guard grantedStatuses.contains(status) else {
            let ids = carePending.map(\.identifier)
            if !ids.isEmpty { await scheduler.removePendingNotificationRequests(withIdentifiers: ids) }
            return .permissionDenied
        }

        var replacements: [String] = []
        for (id, request) in pendingByID {
            guard let item = desired[id] else { continue }
            let expected = Self.makeRequest(for: item)
            if !Self.matches(request, expected: expected) { replacements.append(id) }
        }
        let stale = carePending.map(\.identifier).filter { desired[$0] == nil }
        let removeIDs = Array(Set(stale + replacements))
        if !removeIDs.isEmpty {
            await scheduler.removePendingNotificationRequests(withIdentifiers: removeIDs)
        }
        guard pass == generation else { return .cancelled }

        var scheduled = 0
        var attempted = 0
        for item in desired.values.sorted(by: { $0.identifier < $1.identifier }) {
            let current = pendingByID[item.identifier]
            let expected = Self.makeRequest(for: item)
            guard current == nil || !Self.matches(current!, expected: expected) else { continue }
            guard pass == generation else { return .cancelled }
            attempted += 1
            do {
                try await scheduler.add(expected)
                scheduled += 1
            } catch {
                // Preserve the task and report a retryable scheduling outcome.
            }
            guard pass == generation else {
                await repairStaleRequest(itemID: item.identifier)
                return .cancelled
            }
        }

        if attempted > scheduled {
            return .schedulingFailed(attempted: attempted, scheduled: scheduled)
        }
        return .reconciled(scheduled: scheduled, removed: removeIDs.count)
    }

    /// Invalidates all in-flight work and removes only seasonal-care requests.
    public func cancelAll() async {
        generation &+= 1
        latestDesired = [:]
        let pass = generation
        await enqueue { [weak self] in
            guard let self, pass == self.generation else { return }
            await self.cancelAllNow(pass: pass)
        }
    }

    private func cancelAllNow(pass: UInt64) async {
        let pending = await scheduler.pendingNotificationRequests()
        guard pass == generation else { return }
        let ids = pending
            .map(\.identifier)
            .filter { $0.hasPrefix(Self.identifierPrefix) }
        if !ids.isEmpty {
            await scheduler.removePendingNotificationRequests(withIdentifiers: ids)
        }
    }

    private func repairStaleRequest(itemID: String) async {
        if let current = latestDesired[itemID] {
            try? await scheduler.add(Self.makeRequest(for: current))
        } else {
            await scheduler.removePendingNotificationRequests(withIdentifiers: [itemID])
        }
    }

    /// Scheduler mutations are serialized so cancellation cannot remove a
    /// request added by a newer household pass during an older await.
    private func enqueue<T: Sendable>(
        _ operation: @escaping @MainActor () async -> T
    ) async -> T {
        let previous = mutationTail
        let task = Task { @MainActor in
            if let previous { await previous.value }
            return await operation()
        }
        mutationTail = Task { @MainActor in
            _ = await task.value
        }
        return await task.value
    }

    private static func makeRequest(for item: SeasonalCareReminderItem) -> UNNotificationRequest {
        var calendar = Calendar(identifier: .gregorian)
        let timeZone = TimeZone(identifier: item.timeZoneIdentifier) ?? .current
        calendar.timeZone = timeZone
        var components = calendar.dateComponents(
            [.calendar, .timeZone, .year, .month, .day, .hour, .minute],
            from: item.fireDate
        )
        components.calendar = calendar
        components.timeZone = timeZone
        let content = UNMutableNotificationContent()
        content.title = item.title
        content.body = "Care for \(item.seedName)."
        content.sound = .default
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        return UNNotificationRequest(identifier: item.identifier, content: content, trigger: trigger)
    }

    private static func matches(_ request: UNNotificationRequest, expected: UNNotificationRequest) -> Bool {
        guard request.identifier == expected.identifier,
              request.content.title == expected.content.title,
              request.content.body == expected.content.body,
              let left = request.trigger as? UNCalendarNotificationTrigger,
              let right = expected.trigger as? UNCalendarNotificationTrigger
        else { return false }
        return left.repeats == right.repeats && left.dateComponents == right.dateComponents
    }
}
