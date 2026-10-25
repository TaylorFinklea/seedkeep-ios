import Foundation

/// N2-E (G2): where garden-scoped local notifications are scheduled and removed (planting-event
/// reminders, the weekly pet roundup, and the all-clear when a garden is gone). The shipping
/// implementation is `NotificationsCenter`; tests pass a recorder, so a late notification and its
/// removal are observable without touching the device's notifications.
@MainActor
protocol GardenNotifying: AnyObject {
    func scheduleEventReminder(eventID: String, plannedFor: String, kindLabel: String, seedName: String?) async
    func cancelEventReminder(eventID: String)
    func schedulePetRoundup(thriving: Int, wilting: Int) async
    func clearPetRoundup()
    func removeAll()
}

@MainActor
final class LiveGardenNotifier: GardenNotifying {
    func scheduleEventReminder(eventID: String, plannedFor: String, kindLabel: String, seedName: String?) async {
        await NotificationsCenter.shared.schedulePlantingEventReminder(
            eventID: eventID, plannedFor: plannedFor, kindLabel: kindLabel, seedName: seedName)
    }
    func cancelEventReminder(eventID: String) {
        NotificationsCenter.shared.cancelPlantingEventReminder(eventID: eventID)
    }
    func schedulePetRoundup(thriving: Int, wilting: Int) async {
        await NotificationsCenter.shared.schedulePetWeeklyRoundup(thrivingCount: thriving, wiltingCount: wilting)
    }
    func clearPetRoundup() {
        NotificationsCenter.shared.clearPetWeeklyRoundup()
    }
    func removeAll() {
        NotificationsCenter.shared.removeAllAppNotifications()
    }
}

/// Schedules nothing. `AppEnvironment.makeForTesting` uses it unless a test passes a recorder, so a
/// unit test never touches the device's real notifications.
@MainActor
final class NoopGardenNotifier: GardenNotifying {
    func scheduleEventReminder(eventID: String, plannedFor: String, kindLabel: String, seedName: String?) async {}
    func cancelEventReminder(eventID: String) {}
    func schedulePetRoundup(thriving: Int, wilting: Int) async {}
    func clearPetRoundup() {}
    func removeAll() {}
}
