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
        // Phase 4D — catalog correction outcomes. Per-correction pings
        // (`catalogCorrection + <id>`) and batch roundup pings
        // (`catalogCorrectionRoundup + <bucket>`) share the
        // `seedkeep.notif.catalog.` namespace so a single hasPrefix
        // sweep can clear all of them when the user disables the
        // toggle.
        static let catalogCorrection = "seedkeep.notif.catalog."
        static let catalogCorrectionRoundup = "seedkeep.notif.catalog.roundup."
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

    /// Sign-out / identity-switch cleanup: drop every pending AND
    /// delivered notification. Every notification in this center belongs
    /// to the app, and all of them reference the outgoing account's data
    /// (event reminders, pet pings, correction outcomes, weather
    /// warnings) — none may survive into the next account's session.
    func removeAllAppNotifications() {
        center.removeAllPendingNotificationRequests()
        center.removeAllDeliveredNotifications()
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
        guard let fire = Self.reminderFireDate(onDayOf: date, calendar: cal),
              fire > Date() else { return }

        let body = seedName.map { "\(kindLabel) · \($0)" } ?? kindLabel
        schedule(
            id: id,
            title: "Planned for today",
            body: body,
            fireDate: fire
        )
    }

    /// DST-safe "7am on the day of `date`". `startOfDay + 7 elapsed
    /// hours` lands at 8am on spring-forward days and 6am on fall-back
    /// days; `bySettingHour` pins the wall clock instead. Mirrors the
    /// weather evaluators' fire-time math (Evaluators.swift).
    nonisolated static func reminderFireDate(onDayOf date: Date, calendar: Calendar) -> Date? {
        calendar.date(
            bySettingHour: 7,
            minute: 0,
            second: 0,
            of: calendar.startOfDay(for: date),
            matchingPolicy: .nextTime,
            repeatedTimePolicy: .first,
            direction: .forward
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

    // MARK: - Catalog corrections (Phase 4D)

    /// Schedule a per-correction outcome ping. Used by
    /// `CatalogCorrectionNotifier` when a sync batch surfaces ≤3
    /// status transitions. Body copy is dictated by `newStatus` +
    /// `dismissedReason` per spec §7 — the orchestrator picks the
    /// reason; this method just renders it.
    ///
    /// Identifier is deterministic from `correctionID` so the
    /// cross-device dedup ledger can prevent double-pings (both
    /// devices try to schedule with the same UN identifier — second
    /// `add` is a no-op once the first lands).
    func scheduleCatalogCorrectionPing(
        correctionID: String,
        newStatus: String,
        catalogSeedName: String,
        fieldLabel: String,
        dismissedReason: String?
    ) async {
        guard UserDefaults.standard.bool(forKey: "seedkeep.notif.catalog") else { return }
        guard await ensureGranted() else { return }

        let title: String
        let body: String
        switch newStatus {
        case "applied":
            title = "Suggestion applied"
            body = "Your fix to \(catalogSeedName) (\(fieldLabel)) was applied automatically. Tap to see how we decided."
        case "dismissed":
            title = "Suggestion not applied"
            switch dismissedReason {
            case "ai_low_confidence":
                body = "Our AI moderator didn't agree about \(catalogSeedName). Tap to send it to a human reviewer."
            case "out_of_bounds", "invalid_enum":
                body = "Your suggestion was outside the typical range. Tap to send it on for human review."
            case "catalog_entry_unavailable":
                body = "The catalog entry for \(catalogSeedName) was removed before we could review your suggestion."
            default:
                body = "Your suggestion for \(catalogSeedName) wasn't applied. Tap to see why."
            }
        default:
            // `reviewed` transitions intentionally don't ping — the
            // user already saw the "saved for review" copy at submit.
            return
        }

        let id = IdPrefix.catalogCorrection + correctionID
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.interruptionLevel = .active
        // Immediate-delivery trigger — outcome pings ride in on the
        // next sync, so the user expects "you have a result now."
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)
        center.add(request) { _ in /* silent — denial caught above */ }
    }

    /// Schedule a coalesced roundup ping when a single sync batch
    /// surfaces more than 3 transitions. Title + body summarize
    /// applied / dismissed counts and tap routes to YouView. The
    /// identifier bucket is the wall-clock timestamp at schedule time
    /// so rapid-fire batches don't collide.
    func scheduleCatalogCorrectionRoundup(
        applied: Int,
        dismissed: Int,
        ids: [String]
    ) async {
        guard UserDefaults.standard.bool(forKey: "seedkeep.notif.catalog") else { return }
        guard await ensureGranted() else { return }

        let bucket = Int64(Date().timeIntervalSince1970)
        let id = IdPrefix.catalogCorrectionRoundup + String(bucket)
        let title = "Your suggestions updated"
        let body = "\(applied) applied, \(dismissed) dismissed. Tap to review."

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.interruptionLevel = .active
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)
        center.add(request) { _ in /* silent */ }
    }

    /// Cancel any pending UN request for a given correction. Called
    /// when the row is tombstoned server-side so a withdrawn /
    /// revoked correction doesn't leave a ghost ping queued.
    func cancelCatalogCorrectionPing(correctionID: String) {
        center.removePendingNotificationRequests(
            withIdentifiers: [IdPrefix.catalogCorrection + correctionID]
        )
    }

    /// Clear every catalog-correction ping — pending AND delivered.
    /// Used when the user flips the Settings toggle off. The delivered
    /// sweep matters because lock-screen pings accumulated before the
    /// toggle-off would otherwise stay visible.
    func clearAllCatalogCorrectionPings() async {
        let pending = await center.pendingNotificationRequests()
        let pendingIDs = pending
            .map(\.identifier)
            .filter { $0.hasPrefix(IdPrefix.catalogCorrection) }
        center.removePendingNotificationRequests(withIdentifiers: pendingIDs)

        let delivered = await center.deliveredNotifications()
        let deliveredIDs = delivered
            .map(\.request.identifier)
            .filter { $0.hasPrefix(IdPrefix.catalogCorrection) }
        center.removeDeliveredNotifications(withIdentifiers: deliveredIDs)
    }
}
