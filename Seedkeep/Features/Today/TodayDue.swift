import Foundation
import SeedkeepKit

/// Pure helpers for the Today screen's Due section: the queue, day offsets and labels, and the
/// row text, including its VoiceOver label.
enum TodayDue {
    /// Rows shown in the Due section. The queue is cut to this after household scoping.
    static let queueLimit = 6

    /// The whole Due set: incomplete, non-deleted events for `householdID` planned on or before `today`
    /// (`yyyy-MM-dd`), in the order given (the view's query sorts oldest first). Nothing is cut here.
    static func dueSet(
        _ events: [LocalPlantingEvent],
        householdID: String,
        today: String
    ) -> [LocalPlantingEvent] {
        events.filter {
            $0.householdID == householdID
                && $0.deletedAt == nil
                && $0.completedAt == nil
                && $0.plannedFor <= today
        }
    }

    /// The Due queue: the first `queueLimit` rows of `dueSet`, so the cut comes after scoping.
    static func queue(
        _ events: [LocalPlantingEvent],
        householdID: String,
        today: String
    ) -> [LocalPlantingEvent] {
        Array(dueSet(events, householdID: householdID, today: today).prefix(queueLimit))
    }

    /// How many due events the queue leaves out, counted from the whole `dueSet` before the cut. Zero when the
    /// queue shows every due event.
    static func moreCount(
        _ events: [LocalPlantingEvent],
        householdID: String,
        today: String
    ) -> Int {
        max(0, dueSet(events, householdID: householdID, today: today).count - queueLimit)
    }

    /// The "more due" row's text: "1 more due", or "N more due".
    static func moreLabel(count: Int) -> String {
        "\(count) more due"
    }

    /// The "more due" row's VoiceOver label: its text, then that it opens Garden.
    static func moreAccessibilityLabel(count: Int) -> String {
        "\(moreLabel(count: count)), open Garden"
    }

    /// Whole days from `today` to `plannedFor`, both `yyyy-MM-dd`: negative when overdue, zero when
    /// due today. Both dates are read as UTC calendar days, so a daylight-saving change can't shift
    /// the count. An unreadable date gives 0, the same as today.
    static func dayOffset(plannedFor: String, today: String) -> Int {
        guard let planned = calendarDay(plannedFor), let current = calendarDay(today) else { return 0 }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = .gmt
        return utc.dateComponents([.day], from: current, to: planned).day ?? 0
    }

    /// The trailing label for a due row: "1 day overdue", "N days overdue", "Today", "1 day left",
    /// or "N days left".
    static func dayLabel(offset: Int) -> String {
        if offset < 0 {
            let overdue = -offset
            return overdue == 1 ? "1 day overdue" : "\(overdue) days overdue"
        }
        if offset == 0 {
            return "Today"
        }
        return offset == 1 ? "1 day left" : "\(offset) days left"
    }

    /// The name of a planting event kind (`PlantingEventKind.displayName`), or "Event" for a kind
    /// this build doesn't know.
    static func kindLabel(_ raw: String) -> String {
        PlantingEventKind(rawValue: raw)?.displayName ?? "Event"
    }

    /// The second line of a due row: the kind, then the seed's type when it has one.
    static func rowSubtitle(kind: String, type: String?) -> String {
        let typeText = (type ?? "").trimmingCharacters(in: .whitespaces)
        return typeText.isEmpty ? kind : "\(kind) · \(typeText)"
    }

    /// One VoiceOver label for a due row: name, kind, then the day label, then "frost risk" when flagged.
    static func rowAccessibilityLabel(name: String, kind: String, dayLabel: String, frostRisk: Bool = false) -> String {
        var parts = [name, kind, dayLabel]
        if frostRisk { parts.append(FrostCheck.accessibilityPhrase) }
        return parts.joined(separator: ", ")
    }

    /// Parses a `yyyy-MM-dd` string as a UTC midnight. Returns nil unless the string round-trips,
    /// so impossible dates such as 2026-02-30 are rejected rather than rolled over.
    private static func calendarDay(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .gmt
        guard let date = formatter.date(from: text), formatter.string(from: date) == text else {
            return nil
        }
        return date
    }
}
