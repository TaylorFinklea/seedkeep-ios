import Foundation
import UserNotifications
import WeatherKit
import CoreLocation

/// Phase 4 C · Local notification scheduling. Two surfaces:
///
/// 1. **Frost warnings** — fetched from WeatherKit (10-day forecast) when
///    the user toggles them on. For every day in the next 10 with a low
///    below `frostThresholdF` (33°F default), schedule a notification
///    for 8am the morning *before*. Existing scheduled frost
///    notifications are cleared on each refresh.
///
/// 2. **Planting-event reminders** — scheduled when an event is created
///    or updated. Notification fires at 7am local time on the planned
///    date. Cancelled when the event is completed or deleted.
///
/// All scheduling happens locally — no server push, no APNS provisioning
/// required. The user must grant permission once (`requestAuthorization`).
@MainActor
final class NotificationsCenter {

    static let shared = NotificationsCenter()

    /// Centralized identifier prefixes so we can clear-by-prefix.
    private enum IdPrefix {
        static let frost = "seedkeep.notif.frost."
        static let event = "seedkeep.notif.event."
    }

    private let center = UNUserNotificationCenter.current()
    private let frostThresholdF: Double = 33.0

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

    // MARK: - Frost warnings

    /// Refresh frost-warning notifications. Clears existing frost
    /// notifications, then schedules new ones for every forecast day with
    /// a low below the threshold (default 33°F) in the next 10 days.
    /// Silent on WeatherKit / permission failures.
    func refreshFrostWarnings(latitude: Double, longitude: Double) async {
        await clearFrostWarnings()
        guard await ensureGranted() else { return }
        let forecast: [DailyFrostForecast]
        do {
            forecast = try await Self.fetchForecast(latitude: latitude, longitude: longitude)
        } catch {
            return
        }
        let cal = Calendar(identifier: .gregorian)
        for day in forecast {
            guard day.lowF < frostThresholdF else { continue }
            // Notify at 8am the morning *before* the frost day.
            guard let warnDate = cal.date(byAdding: .hour, value: 8,
                                          to: cal.startOfDay(for: day.date.addingTimeInterval(-86400))),
                  warnDate > Date() else { continue }
            let id = IdPrefix.frost + isoDay(day.date)
            schedule(
                id: id,
                title: "Frost warning",
                body: frostBody(for: day),
                fireDate: warnDate
            )
        }
    }

    /// Drops every scheduled frost notification. Called when the user
    /// flips the frost-warning toggle off, or before re-scheduling.
    func clearFrostWarnings() async {
        let pending = await center.pendingNotificationRequests()
        let ids = pending
            .map(\.identifier)
            .filter { $0.hasPrefix(IdPrefix.frost) }
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }

    private func frostBody(for day: DailyFrostForecast) -> String {
        let f = DateFormatter()
        f.dateFormat = "EEEE"
        let weekday = f.string(from: day.date)
        let lowText = String(format: "%.0f", day.lowF)
        return "\(weekday) night drops to \(lowText)°F. Cover tender plants or pull tender seedlings inside."
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

    // MARK: - Diagnostics

    /// Returns true if at least one frost notification is currently
    /// scheduled. Used by Settings to show "active / inactive" state.
    func hasScheduledFrostWarnings() async -> Bool {
        let pending = await center.pendingNotificationRequests()
        return pending.contains { $0.identifier.hasPrefix(IdPrefix.frost) }
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

    private func isoDay(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        return f.string(from: date)
    }

    // MARK: - WeatherKit lookup

    private struct DailyFrostForecast {
        let date: Date
        let lowF: Double
    }

    private static func fetchForecast(
        latitude: Double, longitude: Double
    ) async throws -> [DailyFrostForecast] {
        let weather = try await WeatherService.shared.weather(
            for: CLLocation(latitude: latitude, longitude: longitude))
        return weather.dailyForecast.forecast.prefix(10).map { day in
            DailyFrostForecast(
                date: day.date,
                lowF: day.lowTemperature.converted(to: .fahrenheit).value
            )
        }
    }
}
