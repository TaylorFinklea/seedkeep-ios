import Foundation

/// One seed's row on the Windows screen, as plain values: its window, its timing and its next planned
/// planting. The timeline and the list both draw from these. Pure.
struct WindowsRow: Equatable, Identifiable, Sendable {
    /// The seed's next incomplete planting: the bed it is in, and its day.
    struct NextPlanned: Equatable, Sendable {
        let bedName: String
        let plannedFor: CalendarDay
    }

    let id: String
    let name: String
    let group: PlantingWindowGroup
    /// too_early | plant_soon | plant_now | late | too_late | unknown. Colours the outdoor bar.
    let verdict: String
    /// Plan paints only with an active seed.
    let isActive: Bool
    /// The outdoor window, inclusive. Nil when the seed has none.
    let outdoor: ClosedRange<CalendarDay>?
    /// The indoor window, inclusive. Nil when the seed has none.
    let indoor: ClosedRange<CalendarDay>?
    /// "42 days left", "opens in 10 days" and the like. Nil when there is no outdoor window.
    let timing: String?
    /// Why there is no outdoor window, in the words the planting panel uses. Nil when there is one.
    let noWindowReason: String?
    let nextPlanned: NextPlanned?
}

/// The Windows screen's text, pure: the group headers, the window and timing wording, and the
/// VoiceOver label for each seed.
enum WindowsRowFormat {
    /// "Plant now (3)": a group's title with its count.
    static func groupHeader(_ group: PlantingWindowGroup, count: Int) -> String {
        "\(group.title) (\(count))"
    }

    /// Builds a row from a grouped window seed. `reason` is the recommendation's reason, read only when the
    /// seed has no outdoor window. `today` is the local calendar day the timing counts from. Main-actor only
    /// because the no-window copy comes from `RecommendationPanel`, a view.
    @MainActor
    static func row(
        seed: WindowSeed,
        reason: PlantingRecommendation.Reason?,
        today: CalendarDay,
        nextPlanned: WindowsRow.NextPlanned?
    ) -> WindowsRow {
        let outdoor = SeasonTimeline.range(start: seed.outdoorStart, end: seed.outdoorEnd)
        let indoor = SeasonTimeline.range(start: seed.indoorStart, end: seed.indoorEnd)
        return WindowsRow(
            id: seed.id,
            name: seed.name,
            group: PlantingWindowGroup(verdict: seed.verdict),
            verdict: seed.verdict,
            isActive: seed.isActive,
            outdoor: outdoor,
            indoor: indoor,
            timing: outdoor == nil ? nil : PlantingWindowDays.label(
                verdict: seed.verdict,
                rangeStart: seed.outdoorStart,
                rangeEnd: seed.outdoorEnd,
                today: (today.year, today.month, today.day)
            ),
            noWindowReason: outdoor == nil ? RecommendationPanel.noWindowNote(for: reason) : nil,
            nextPlanned: nextPlanned
        )
    }

    /// "May 18 – Jul 1".
    static func windowText(_ range: ClosedRange<CalendarDay>) -> String {
        "\(monthDay(range.lowerBound)) – \(monthDay(range.upperBound))"
    }

    /// "May 18", in the device language.
    static func monthDay(_ day: CalendarDay) -> String {
        FrostCheck.monthDayText(day)
    }

    /// "Next planned: Herb bed, May 3, 2026".
    static func nextPlannedText(_ next: WindowsRow.NextPlanned) -> String {
        "Next planned: \(next.bedName), \(humanDate(next.plannedFor.ymd))"
    }

    /// The whole VoiceOver label, in the contract's order:
    /// "<seed>, <group>, outdoors <start> to <end>, indoors <start> to <end>, <timing>, next planned <bed> <date>".
    /// An indoor window, the timing and the next planned planting are each left out when there is none. A seed
    /// with no outdoor window says so, with its reason in place of the outdoor dates.
    static func accessibilityLabel(_ row: WindowsRow) -> String {
        var parts = [row.name, row.group.title]
        if let outdoor = row.outdoor {
            parts.append("outdoors \(monthDay(outdoor.lowerBound)) to \(monthDay(outdoor.upperBound))")
        } else if let reason = row.noWindowReason {
            parts.append(reason)
        } else {
            parts.append("no outdoor window")
        }
        if let indoor = row.indoor {
            parts.append("indoors \(monthDay(indoor.lowerBound)) to \(monthDay(indoor.upperBound))")
        }
        if let timing = row.timing {
            parts.append(timing)
        }
        if let next = row.nextPlanned {
            parts.append("next planned \(next.bedName) \(humanDate(next.plannedFor.ymd))")
        }
        return parts.joined(separator: ", ")
    }
}

/// The "days left" and "opens in" wording for a window. It counts local calendar days: the window's
/// "YYYY-MM-DD" dates and the user's local today become day numbers, so a time zone west of UTC
/// never shifts the count by one.
enum PlantingWindowDays {
    static func label(
        verdict: String,
        rangeStart: String?,
        rangeEnd: String?,
        today: (year: Int, month: Int, day: Int)
    ) -> String? {
        let todayNumber = PlantingEngine.dayNumber(year: today.year, month: today.month, day: today.day)
        if verdict == "too_early", let rangeStart, let start = PlantingEngine.parseISODate(rangeStart) {
            let days = start - todayNumber
            return days > 0 ? "opens in \(days) day\(days == 1 ? "" : "s")" : nil
        }
        guard let rangeEnd, let end = PlantingEngine.parseISODate(rangeEnd) else { return nil }
        let days = end - todayNumber
        if days > 0 { return "\(days) day\(days == 1 ? "" : "s") left" }
        if days == 0 { return "closes today" }
        return "\(abs(days)) day\(abs(days) == 1 ? "" : "s") ago"
    }
}
