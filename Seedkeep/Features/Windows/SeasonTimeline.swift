import Foundation

/// The season timeline's date domain, bars, markers and month labels, pure.
enum SeasonTimeline {
    /// Whole months from the first day of `start`'s month to the last day of `end`'s month, inclusive.
    struct Domain: Equatable, Sendable {
        let start: CalendarDay
        let end: CalendarDay

        /// Days in the domain, both ends included.
        var dayCount: Int { start.days(to: end) + 1 }
    }

    struct Month: Equatable, Sendable {
        let year: Int
        let month: Int
        /// Short month name, e.g. "Jan".
        let label: String
        /// Leading edge and width as fractions of the domain.
        let offset: Double
        let width: Double
    }

    enum MarkerKind: Equatable, Sendable {
        case today, lastFrost, firstFrost

        var title: String {
            switch self {
            case .today: return "Today"
            case .lastFrost: return "Last frost"
            case .firstFrost: return "First frost"
            }
        }
    }

    struct Marker: Equatable, Sendable {
        let kind: MarkerKind
        let day: CalendarDay
    }

    /// A drawn bar in points.
    struct Bar: Equatable, Sendable {
        let x: Double
        let width: Double
    }

    /// The smallest drawn width of a bar, so a single-day range stays visible.
    static let minimumBarWidth = 4.0

    /// An inclusive range, or nil when either end is missing or unreadable, or the range is inverted.
    static func range(start: String?, end: String?) -> ClosedRange<CalendarDay>? {
        guard let start = start.flatMap(CalendarDay.parse),
              let end = end.flatMap(CalendarDay.parse),
              start <= end else { return nil }
        return start...end
    }

    /// Today, plus the average last and first frost in today's year when they form a frost season
    /// (see `FrostCheck.season`). A side with no season, such as a calendar edge, gets no marker.
    static func markers(today: CalendarDay, lastFrost: String?, firstFrost: String?) -> [Marker] {
        var markers = [Marker(kind: .today, day: today)]
        guard let frostSeason = FrostCheck.season(lastFrost: lastFrost, firstFrost: firstFrost, year: today.year)
        else { return markers }
        if let day = frostSeason.spring {
            markers.append(Marker(kind: .lastFrost, day: day))
        }
        if let day = frostSeason.fall {
            markers.append(Marker(kind: .firstFrost, day: day))
        }
        return markers
    }

    /// Jan 1 to Dec 31 of `year`, extended to cover every range and marker, then padded to whole months.
    static func domain(year: Int, ranges: [ClosedRange<CalendarDay>], markers: [Marker]) -> Domain {
        var low = CalendarDay.firstDay(ofYear: year)
        var high = CalendarDay.lastDay(ofYear: year)
        for range in ranges {
            low = min(low, range.lowerBound)
            high = max(high, range.upperBound)
        }
        for marker in markers {
            low = min(low, marker.day)
            high = max(high, marker.day)
        }
        return Domain(start: low.firstOfMonth, end: high.lastOfMonth)
    }

    /// The fraction of the domain before `day` starts.
    static func offset(of day: CalendarDay, in domain: Domain) -> Double {
        Double(domain.start.days(to: day)) / Double(domain.dayCount)
    }

    /// The bar for an inclusive range across `totalWidth` points, at least `minimumBarWidth` wide. A bar
    /// that would run past the right edge shifts left to end at it.
    static func bar(for range: ClosedRange<CalendarDay>, in domain: Domain, totalWidth: Double) -> Bar {
        var x = offset(of: range.lowerBound, in: domain) * totalWidth
        let days = range.lowerBound.days(to: range.upperBound) + 1
        let width = max(Double(days) / Double(domain.dayCount) * totalWidth, minimumBarWidth)
        if x + width > totalWidth { x = max(0, totalWidth - width) }
        return Bar(x: x, width: width)
    }

    /// The marker line's x in points: the middle of its day.
    static func markerX(_ day: CalendarDay, in domain: Domain, totalWidth: Double) -> Double {
        (offset(of: day, in: domain) + 0.5 / Double(domain.dayCount)) * totalWidth
    }

    /// One label per month of the domain.
    static func months(in domain: Domain, locale: Locale = .current) -> [Month] {
        var calendar = CalendarDay.utcCalendar
        calendar.locale = locale
        let names = calendar.shortMonthSymbols
        var result: [Month] = []
        var first = domain.start
        while first <= domain.end {
            let last = first.lastOfMonth
            let days = first.days(to: last) + 1
            result.append(Month(
                year: first.year,
                month: first.month,
                label: names[first.month - 1],
                offset: offset(of: first, in: domain),
                width: Double(days) / Double(domain.dayCount)
            ))
            first = last.adding(days: 1)
        }
        return result
    }
}
