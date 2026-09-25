import Foundation

/// An inclusive annual month/day window. The start month/day may be after the end
/// month/day to represent a window that crosses New Year's Day.
public struct AnnualCareWindow: Equatable, Sendable {
    public enum ValidationError: Error, Equatable, Sendable {
        case invalidMonth(Int)
        case invalidDay(month: Int, day: Int)
    }

    public let startMonth: Int
    public let startDay: Int
    public let endMonth: Int
    public let endDay: Int

    public init(startMonth: Int, startDay: Int, endMonth: Int, endDay: Int) throws {
        try Self.validate(month: startMonth, day: startDay)
        try Self.validate(month: endMonth, day: endDay)
        self.startMonth = startMonth
        self.startDay = startDay
        self.endMonth = endMonth
        self.endDay = endDay
    }

    public var crossesYearBoundary: Bool {
        startMonth > endMonth || (startMonth == endMonth && startDay > endDay)
    }

    /// Resolve the occurrence containing (or following) `on` and evaluate it.
    /// `completedGardenYears` contains the start year of completed occurrences.
    public func evaluation(
        on date: Date,
        calendar suppliedCalendar: Calendar,
        timeZone: TimeZone,
        completedGardenYears: Set<Int>,
        firstGardenYear: Int? = nil,
        firstOccurrenceDate: Date? = nil
    ) throws -> AnnualCareEvaluation {
        var calendar = suppliedCalendar
        calendar.timeZone = timeZone
        let normalizedDate = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: date) ?? date
        let dateYear = calendar.component(.year, from: normalizedDate)
        let current = try occurrence(gardenYear: dateYear, calendar: calendar, timeZone: timeZone)
        let previous = try occurrence(gardenYear: dateYear - 1, calendar: calendar, timeZone: timeZone)

        // Select the occurrence that owns the current work. An uncompleted
        // occurrence stays overdue until the next start, including the gap
        // between a window's end and its next start. First eligibility is based
        // on the task's creation day when that context is available.
        let minimumGardenYear: Int
        if let firstOccurrenceDate {
            minimumGardenYear = try firstEligibleOccurrence(
                on: firstOccurrenceDate, calendar: calendar, timeZone: timeZone).gardenYear
        } else {
            minimumGardenYear = firstGardenYear ?? Int.min
        }

        var selected: AnnualCareOccurrence
        if crossesYearBoundary {
            if normalizedDate >= current.start {
                selected = current
            } else if normalizedDate <= previous.end {
                selected = previous.gardenYear >= minimumGardenYear ? previous : current
            } else if previous.gardenYear >= minimumGardenYear,
                      !completedGardenYears.contains(previous.gardenYear) {
                selected = previous
            } else {
                selected = current
            }
        } else if normalizedDate < current.start,
                  (firstOccurrenceDate != nil || firstGardenYear != nil),
                  previous.gardenYear >= minimumGardenYear,
                  !completedGardenYears.contains(previous.gardenYear) {
            selected = previous
        } else {
            selected = current
        }

        if selected.gardenYear < minimumGardenYear {
            selected = try occurrence(gardenYear: minimumGardenYear, calendar: calendar, timeZone: timeZone)
        }

        let state = state(
            for: selected, on: normalizedDate, calendar: calendar,
            completedGardenYears: completedGardenYears)
        return AnnualCareEvaluation(occurrence: selected, state: state)
    }

    /// Evaluates the next incomplete occurrence for queue surfaces such as
    /// Today. The ordinary evaluator intentionally reports a completed current
    /// occurrence so Seed Detail can show completion; this path advances past
    /// completed years and keeps the next annual window visible.
    public func nextIncompleteEvaluation(
        on date: Date,
        calendar suppliedCalendar: Calendar,
        timeZone: TimeZone,
        completedGardenYears: Set<Int>,
        firstOccurrenceDate: Date? = nil
    ) throws -> AnnualCareEvaluation {
        var calendar = suppliedCalendar
        calendar.timeZone = timeZone
        let current = try evaluation(
            on: date, calendar: calendar, timeZone: timeZone,
            completedGardenYears: completedGardenYears,
            firstOccurrenceDate: firstOccurrenceDate)
        guard current.state == .completed else { return current }

        var gardenYear = current.occurrence.gardenYear + 1
        var next = try occurrence(gardenYear: gardenYear, calendar: calendar, timeZone: timeZone)
        while completedGardenYears.contains(gardenYear) {
            gardenYear += 1
            next = try occurrence(gardenYear: gardenYear, calendar: calendar, timeZone: timeZone)
        }
        let normalizedDate = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: date) ?? date
        return AnnualCareEvaluation(
            occurrence: next,
            state: state(for: next, on: normalizedDate, calendar: calendar,
                         completedGardenYears: completedGardenYears))
    }

    /// Returns the first occurrence a task created on `date` may own. The
    /// comparison uses the local calendar day, so creation late on an
    /// inclusive end day still belongs to that occurrence.
    public func firstEligibleOccurrence(
        on date: Date,
        calendar suppliedCalendar: Calendar,
        timeZone: TimeZone
    ) throws -> AnnualCareOccurrence {
        var calendar = suppliedCalendar
        calendar.timeZone = timeZone
        let normalizedDate = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: date) ?? date
        let year = calendar.component(.year, from: normalizedDate)
        let current = try occurrence(gardenYear: year, calendar: calendar, timeZone: timeZone)
        if crossesYearBoundary {
            let previous = try occurrence(gardenYear: year - 1, calendar: calendar, timeZone: timeZone)
            if normalizedDate <= previous.end || normalizedDate >= current.start {
                return normalizedDate <= previous.end ? previous : current
            }
            return current
        }
        return normalizedDate <= current.end
            ? current
            : try occurrence(gardenYear: year + 1, calendar: calendar, timeZone: timeZone)
    }

    private func state(
        for occurrence: AnnualCareOccurrence,
        on date: Date,
        calendar: Calendar,
        completedGardenYears: Set<Int>
    ) -> AnnualCareState {
        if completedGardenYears.contains(occurrence.gardenYear) {
            return .completed
        }
        if date < occurrence.start {
            let days = calendar.dateComponents(
                [.day],
                from: calendar.startOfDay(for: date),
                to: calendar.startOfDay(for: occurrence.start)
            ).day ?? 0
            return .upcoming(daysUntilStart: max(0, days))
        }
        return date <= occurrence.end ? .due : .overdue
    }

    public func occurrence(
        gardenYear: Int,
        calendar suppliedCalendar: Calendar,
        timeZone: TimeZone
    ) throws -> AnnualCareOccurrence {
        var calendar = suppliedCalendar
        calendar.timeZone = timeZone
        let start = try resolve(month: startMonth, day: startDay, year: gardenYear, calendar: calendar)
        let endYear = crossesYearBoundary ? gardenYear + 1 : gardenYear
        let end = try resolve(month: endMonth, day: endDay, year: endYear, calendar: calendar)
        return AnnualCareOccurrence(gardenYear: gardenYear, start: start, end: end)
    }

    private static func validate(month: Int, day: Int) throws {
        guard (1...12).contains(month) else { throw ValidationError.invalidMonth(month) }
        // 2000 is a leap year, so this accepts Feb 29 while rejecting all other
        // impossible month/day combinations without depending on the user's clock.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let date = calendar.date(from: DateComponents(year: 2000, month: month, day: day)),
              calendar.component(.month, from: date) == month,
              calendar.component(.day, from: date) == day else {
            throw ValidationError.invalidDay(month: month, day: day)
        }
    }

    private func resolve(month: Int, day: Int, year: Int, calendar: Calendar) throws -> Date {
        let components = DateComponents(calendar: calendar, timeZone: calendar.timeZone,
                                        year: year, month: month, day: day, hour: 12)
        if let date = calendar.date(from: components),
           calendar.component(.month, from: date) == month,
           calendar.component(.day, from: date) == day {
            return date
        }
        // Annual tasks keep their occurrence in non-leap years. Feb 29 therefore
        // resolves to Feb 28 instead of disappearing for four years.
        if month == 2, day == 29 {
            var fallback = components
            fallback.day = 28
            if let date = calendar.date(from: fallback) { return date }
        }
        throw ValidationError.invalidDay(month: month, day: day)
    }
}

public enum AnnualCareState: Equatable, Sendable {
    case upcoming(daysUntilStart: Int)
    case due
    case overdue
    case completed
}

public struct AnnualCareOccurrence: Equatable, Sendable {
    public let gardenYear: Int
    public let start: Date
    public let end: Date

    public init(gardenYear: Int, start: Date, end: Date) {
        self.gardenYear = gardenYear
        self.start = start
        self.end = end
    }
}

public struct AnnualCareEvaluation: Equatable, Sendable {
    public let occurrence: AnnualCareOccurrence
    public let state: AnnualCareState

    public init(occurrence: AnnualCareOccurrence, state: AnnualCareState) {
        self.occurrence = occurrence
        self.state = state
    }
}
