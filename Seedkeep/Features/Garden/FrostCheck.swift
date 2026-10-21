import Foundation

/// A calendar day with no time or time zone: proleptic Gregorian, compared by year, month and day.
/// Parsing is strict: a string must round-trip through a Gregorian UTC calendar.
struct CalendarDay: Hashable, Comparable, Sendable, CustomStringConvertible {
    let year: Int
    let month: Int
    let day: Int

    /// Only for components already known to be valid; use `make` or `parse` otherwise.
    private init(uncheckedYear year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    /// The day, or nil when the components are not a real Gregorian date.
    static func make(year: Int, month: Int, day: Int) -> CalendarDay? {
        guard (1...9999).contains(year), (1...12).contains(month), (1...31).contains(day) else { return nil }
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        guard let date = utcCalendar.date(from: components) else { return nil }
        let back = utcCalendar.dateComponents([.year, .month, .day], from: date)
        guard back.year == year, back.month == month, back.day == day else { return nil }
        return CalendarDay(uncheckedYear: year, month: month, day: day)
    }

    /// A strict "yyyy-MM-dd": four, two and two digits that name a real date.
    static func parse(_ text: String) -> CalendarDay? {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let year = digits(parts[0], count: 4),
              let month = digits(parts[1], count: 2),
              let day = digits(parts[2], count: 2) else { return nil }
        return make(year: year, month: month, day: day)
    }

    /// A strict "MM-dd" in `year`. 02-29 in a non-leap year becomes 02-28.
    static func parseMonthDay(_ text: String, year: Int) -> CalendarDay? {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let month = digits(parts[0], count: 2),
              let day = digits(parts[1], count: 2) else { return nil }
        if month == 2, day == 29, make(year: year, month: 2, day: 29) == nil {
            return make(year: year, month: 2, day: 28)
        }
        return make(year: year, month: month, day: day)
    }

    /// The device-local calendar day of `now`. Only `calendar`'s time zone is
    /// used: the components are always Gregorian, whatever calendar the
    /// device is set to (Buddhist, Japanese, ...).
    static func today(now: Date = Date(), calendar: Calendar = .current) -> CalendarDay {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        let parts = gregorian.dateComponents([.year, .month, .day], from: now)
        return make(year: parts.year ?? 1970, month: parts.month ?? 1, day: parts.day ?? 1)
            ?? CalendarDay(uncheckedYear: 1970, month: 1, day: 1)
    }

    /// "yyyy-MM-dd", the form the models store days in.
    var ymd: String { String(format: "%04ld-%02ld-%02ld", year, month, day) }

    /// "MM-dd", the form the climate stores frost dates in.
    var monthDay: String { String(format: "%02ld-%02ld", month, day) }

    var description: String { ymd }

    /// Days since 1970-01-01.
    var dayNumber: Int { PlantingEngine.dayNumber(year: year, month: month, day: day) }

    /// Midnight UTC of this day, for formatting with a UTC formatter.
    var utcDate: Date {
        Date(timeIntervalSince1970: TimeInterval(dayNumber) * 86_400)
    }

    func adding(days: Int) -> CalendarDay {
        let date = utcDate.addingTimeInterval(TimeInterval(days) * 86_400)
        let parts = Self.utcCalendar.dateComponents([.year, .month, .day], from: date)
        return CalendarDay(uncheckedYear: parts.year ?? year, month: parts.month ?? month, day: parts.day ?? day)
    }

    var firstOfMonth: CalendarDay { CalendarDay(uncheckedYear: year, month: month, day: 1) }

    var lastOfMonth: CalendarDay {
        let isLeap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
        let lengths = [31, isLeap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        return CalendarDay(uncheckedYear: year, month: month, day: lengths[month - 1])
    }

    /// Jan 1 and Dec 31 of `year` (clamped to 1...9999).
    static func firstDay(ofYear year: Int) -> CalendarDay {
        CalendarDay(uncheckedYear: min(max(year, 1), 9999), month: 1, day: 1)
    }

    static func lastDay(ofYear year: Int) -> CalendarDay {
        CalendarDay(uncheckedYear: min(max(year, 1), 9999), month: 12, day: 31)
    }

    /// Whole days from `self` to `other` (positive when `other` is later).
    func days(to other: CalendarDay) -> Int { other.dayNumber - dayNumber }

    static func < (lhs: CalendarDay, rhs: CalendarDay) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }

    static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    private static func digits(_ text: Substring, count: Int) -> Int? {
        guard text.count == count, text.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(text)
    }
}

/// Estimated frost risk for an outdoor sowing or transplant of a frost-tender seed, from the home
/// climate's zone-average frost dates (US zones, the bundled climate table). Pure.
///
/// Home climate is per device, so members of one household can see different flags.
enum FrostCheck {
    enum Side: Equatable, Sendable {
        /// Planned before the average last frost.
        case spring
        /// Planned on or after the average first frost.
        case fall
    }

    enum Outcome: Equatable, Sendable {
        /// The event is at risk; `frostDate` is the average frost date in the planned year.
        case flagged(Side, frostDate: CalendarDay)
        case notFlagged
        /// The dates could not be read, or there is no frost season to compare with.
        case unavailable

        var isFlagged: Bool {
            if case .flagged = self { return true }
            return false
        }
    }

    /// The planting kinds that put a plant outdoors.
    static let checkedKinds: Set<String> = ["sowing", "transplant"]

    /// The frost season in `year`: `spring` is the average last frost and `fall` the average first frost.
    /// Nil when either date is missing or unreadable, the first frost is not after the last, or both are
    /// calendar edges. The table uses the year's edges for zones with no frost season on that side, so a
    /// last frost of 01-01 has no spring (nil) and a first frost of 12-31 has no fall (nil).
    static func season(
        lastFrost: String?,
        firstFrost: String?,
        year: Int
    ) -> (spring: CalendarDay?, fall: CalendarDay?)? {
        guard let lastFrost, let firstFrost,
              let last = CalendarDay.parseMonthDay(lastFrost, year: year),
              let first = CalendarDay.parseMonthDay(firstFrost, year: year),
              first > last
        else { return nil }
        let hasSpring = !(last.month == 1 && last.day == 1)
        let hasFall = !(first.month == 12 && first.day == 31)
        guard hasSpring || hasFall else { return nil }
        return (spring: hasSpring ? last : nil, fall: hasFall ? first : nil)
    }

    static func check(
        plannedFor: String,
        kind: String,
        isCompleted: Bool,
        frostTolerance: String?,
        lastFrost: String?,
        firstFrost: String?
    ) -> Outcome {
        guard !isCompleted,
              checkedKinds.contains(kind),
              frostTolerance?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "tender"
        else { return .notFlagged }
        guard let planned = CalendarDay.parse(plannedFor),
              let frostSeason = season(lastFrost: lastFrost, firstFrost: firstFrost, year: planned.year)
        else { return .unavailable }
        if let spring = frostSeason.spring, planned < spring { return .flagged(.spring, frostDate: spring) }
        if let fall = frostSeason.fall, planned >= fall { return .flagged(.fall, frostDate: fall) }
        return .notFlagged
    }

    /// The one-line warning, e.g. "Frost risk if planted outdoors: before the average last frost (May 4)."
    static func sentence(side: Side, frostDate: CalendarDay, locale: Locale = .current) -> String {
        let date = monthDayText(frostDate, locale: locale)
        switch side {
        case .spring: return "Frost risk if planted outdoors: before the average last frost (\(date))."
        case .fall: return "Frost risk if planted outdoors: on or after the average first frost (\(date))."
        }
    }

    /// The sentence for a flagged outcome; nil otherwise.
    static func sentence(for outcome: Outcome, locale: Locale = .current) -> String? {
        guard case .flagged(let side, let date) = outcome else { return nil }
        return sentence(side: side, frostDate: date, locale: locale)
    }

    /// Shown with the sentence: the dates are estimates.
    static let estimateNote = "Frost dates are zone averages, not a forecast."

    /// Appended to VoiceOver labels of flagged items.
    static let accessibilityPhrase = "frost risk"

    /// "May 4" in `locale`.
    static func monthDayText(_ day: CalendarDay, locale: Locale = .current) -> String {
        let formatter = DateFormatter()
        formatter.calendar = CalendarDay.utcCalendar
        formatter.timeZone = CalendarDay.utcCalendar.timeZone
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate("MMMd")
        return formatter.string(from: day.utcDate)
    }
}
