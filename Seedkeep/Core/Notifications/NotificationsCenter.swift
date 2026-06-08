import Foundation
import UserNotifications

/// Phase 4 C · Local notification scheduling. Frost warnings live in the
/// `WeatherWarningsService` actor (Phase 4C native-warnings refactor);
/// this center now owns:
///
/// 1. **Planting-event reminders** — scheduled when an event is created
///    or updated. Notification fires at 7am local time on the planned
///    date. Cancelled when the event is completed or deleted.
///
/// 2. **Plant-pet notifications** — wilted / departed / Sunday-roundup
///    (Phase 5.1.4).
///
/// All scheduling happens locally — no server push, no APNS provisioning
/// required. The user must grant permission once (`requestAuthorization`).
@MainActor
final class NotificationsCenter {

    static let shared = NotificationsCenter()

    /// Centralized identifier prefixes so we can clear-by-prefix.
    enum IdPrefix {
        static let event = "seedkeep.notif.event."
        // Phase 5 — plant pets. Singular `pet` matches `event` prefix.
        static let petWilted = "seedkeep.notif.pet.wilted."
        static let petDeparted = "seedkeep.notif.pet.departed."
        static let petRoundup = "seedkeep.notif.pet.roundup"
    }

    private let center = UNUserNotificationCenter.current()

    // MARK: - Permission

    /// Request notification permission (alert + sound). Returns true if
    /// the user already granted or grants now; false otherwise.
    func requestAuthorization() async -> Bool {
        do {
            return try await center.requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            return false
        }
    }

    /// Current authorization status. Useful for showing "enable in
    /// Settings" guidance when the user has previously denied.
    func authorizationStatus() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }

    // MARK: - Planting-event reminders

    /// Schedule a 7am reminder on the planned date of a planting event.
    /// Replaces any prior notification with the same event id (so
    /// rescheduling an event moves the reminder).
    func schedulePlantingEventReminder(
        eventID: String,
        plannedFor ymd: String,
        kindLabel: String,
        seedName: String?
    ) async {
        guard await ensureGranted() else { return }
        let id = IdPrefix.event + eventID
        center.removePendingNotificationRequests(withIdentifiers: [id])

        let parser = DateFormatter()
        parser.dateFormat = "yyyy-MM-dd"
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = TimeZone.current
        guard let date = parser.date(from: ymd) else { return }

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone.current
        guard let fire = cal.date(byAdding: .hour, value: 7, to: cal.startOfDay(for: date)),
              fire > Date() else { return }

        let body = seedName.map { "\(kindLabel) · \($0)" } ?? kindLabel
        schedule(
            id: id,
            title: "Planned for today",
            body: body,
            fireDate: fire
        )
    }

    /// Cancel a pending planting-event reminder.
    func cancelPlantingEventReminder(eventID: String) {
        center.removePendingNotificationRequests(
            withIdentifiers: [IdPrefix.event + eventID])
    }

    // MARK: - Internals

    private func ensureGranted() async -> Bool {
        let status = await authorizationStatus()
        switch status {
        case .authorized, .provisional, .ephemeral: return true
        case .notDetermined: return await requestAuthorization()
        case .denied: return false
        @unknown default: return false
        }
    }

    private func schedule(id: String, title: String, body: String, fireDate: Date) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute], from: fireDate)
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)
        center.add(request) { _ in /* silent — first failure usually means denied */ }
    }

    private func scheduleRecurring(id: String, title: String, body: String, dateComponents: DateComponents) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let trigger = UNCalendarNotificationTrigger(dateMatching: dateComponents, repeats: true)
        let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)
        center.add(request) { _ in /* silent */ }
    }

    // MARK: - Plant pets (Phase 5.1.4)

    func schedulePetWiltedWarning(eventID: String, petName: String) async {
        guard UserDefaults.standard.bool(forKey: "seedkeep.notif.pet.wilted") else { return }
        guard await ensureGranted() else { return }
        let fire = Date().addingTimeInterval(10) // ~10s in future per spec
        schedule(
            id: IdPrefix.petWilted + eventID,
            title: "Pet wilting",
            body: "\(petName) is wilting. Tap to check in.",
            fireDate: fire
        )
    }

    func schedulePetDeparted(eventID: String, goodbyeFirstLine: String) async {
        guard UserDefaults.standard.bool(forKey: "seedkeep.notif.pet.departed") else { return }
        guard await ensureGranted() else { return }
        let fire = Date().addingTimeInterval(5)
        schedule(
            id: IdPrefix.petDeparted + eventID,
            title: "Pet farewell",
            body: goodbyeFirstLine,
            fireDate: fire
        )
    }

    func cancelPetWiltedWarning(eventID: String) {
        center.removePendingNotificationRequests(withIdentifiers: [IdPrefix.petWilted + eventID])
    }

    func cancelPetDeparted(eventID: String) {
        center.removePendingNotificationRequests(withIdentifiers: [IdPrefix.petDeparted + eventID])
    }

    func cancelAllPetNotifications(eventID: String) {
        cancelPetWiltedWarning(eventID: eventID)
        cancelPetDeparted(eventID: eventID)
    }

    /// Schedule (or replace) the weekly Sunday-8am pet roundup. Idempotent:
    /// re-scheduling with the same identifier preserves the next-fire date.
    /// `thrivingCount` + `wiltingCount` are baked into the body at schedule
    /// time; the caller is expected to re-invoke this after each `syncAll`.
    func schedulePetWeeklyRoundup(thrivingCount: Int, wiltingCount: Int) async {
        guard UserDefaults.standard.bool(forKey: "seedkeep.notif.pet.roundup") else { return }
        guard await ensureGranted() else { return }
        var dc = DateComponents()
        dc.hour = 8
        dc.minute = 0
        dc.weekday = 1  // Sunday (Gregorian)
        let body = "\(thrivingCount) thriving · \(wiltingCount) wilting"
        scheduleRecurring(
            id: IdPrefix.petRoundup,
            title: "Pet roundup",
            body: body,
            dateComponents: dc
        )
    }

    func clearPetWeeklyRoundup() {
        center.removePendingNotificationRequests(withIdentifiers: [IdPrefix.petRoundup])
    }

    /// Clears every pending pet notification (both prefixes + roundup).
    /// Used when the user disables pets in Settings entirely. Mirrors
    /// `clearAllFrostWarnings` shape.
    func clearAllPetNotifications() async {
        let pending = await center.pendingNotificationRequests()
        let ids = pending
            .map(\.identifier)
            .filter {
                $0.hasPrefix(IdPrefix.petWilted)
                || $0.hasPrefix(IdPrefix.petDeparted)
                || $0 == IdPrefix.petRoundup
            }
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }

    private func isoDay(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        return f.string(from: date)
    }
}
