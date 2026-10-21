import Foundation

/// A seed with a planting window, as the Windows screen reads it.
struct WindowSeed: Equatable, Hashable, Sendable, Identifiable {
    let id: String
    let name: String
    /// True for archived seeds, which the Windows screen leaves out.
    let isArchived: Bool
    /// True for active seeds, which Plan can paint with.
    let isActive: Bool
    /// too_early | plant_soon | plant_now | late | too_late | unknown
    let verdict: String
    /// "yyyy-MM-dd" endpoints, inclusive.
    let outdoorStart: String?
    let outdoorEnd: String?
    let indoorStart: String?
    let indoorEnd: String?
}

/// The Windows screen's groups, in display order.
enum PlantingWindowGroup: String, CaseIterable, Sendable {
    case plantNow, plantSoon, closingSoon, later

    var title: String {
        switch self {
        case .plantNow: return "Plant now"
        case .plantSoon: return "Plant soon"
        case .closingSoon: return "Closing soon"
        case .later: return "Later"
        }
    }

    /// `late` is "Closing soon"; too_early, too_late, unknown and anything else is "Later".
    init(verdict: String) {
        switch verdict {
        case "plant_now": self = .plantNow
        case "plant_soon": self = .plantSoon
        case "late": self = .closingSoon
        default: self = .later
        }
    }
}

struct WindowSection: Equatable, Sendable {
    let group: PlantingWindowGroup
    let seeds: [WindowSeed]
}

/// Groups and orders the Windows screen, pure.
enum WindowsGrouping {
    /// The non-empty groups in display order. Archived seeds are left out. Within a group: window
    /// start, then name, then id; seeds with no (readable) window start come last.
    static func sections(_ seeds: [WindowSeed]) -> [WindowSection] {
        let live = seeds.filter { !$0.isArchived }
        let byGroup = Dictionary(grouping: live) { PlantingWindowGroup(verdict: $0.verdict) }
        return PlantingWindowGroup.allCases.compactMap { group in
            guard let members = byGroup[group], !members.isEmpty else { return nil }
            return WindowSection(group: group, seeds: ordered(members))
        }
    }

    static func ordered(_ seeds: [WindowSeed]) -> [WindowSeed] {
        seeds.sorted { lhs, rhs in
            let left = lhs.outdoorStart.flatMap(CalendarDay.parse)
            let right = rhs.outdoorStart.flatMap(CalendarDay.parse)
            switch (left, right) {
            case let (l?, r?) where l != r: return l < r
            case (.some, nil): return true
            case (nil, .some): return false
            default: break
            }
            let byName = lhs.name.localizedStandardCompare(rhs.name)
            if byName != .orderedSame { return byName == .orderedAscending }
            return lhs.id < rhs.id
        }
    }

    /// The seed's next planned event: its first incomplete event by date, then id. Callers pass live events.
    static func nextPlanned(seedID: String, events: [GridEvent]) -> GridEvent? {
        GardenGrid.ordered(events.filter { $0.seedID == seedID && !$0.isCompleted }).first
    }

    /// `nextPlanned` for every seed with an incomplete event.
    static func nextPlannedBySeed(_ events: [GridEvent]) -> [String: GridEvent] {
        var result: [String: GridEvent] = [:]
        for event in GardenGrid.ordered(events) where !event.isCompleted {
            guard let seedID = event.seedID, result[seedID] == nil else { continue }
            result[seedID] = event
        }
        return result
    }

    /// The next planned event for every seed, scoped to one household. Only its events count, and only those in a
    /// live bed (`liveBedIDs`). Each event is paired with the household it belongs to. Nil `householdID` yields none.
    static func nextPlannedBySeed(
        _ events: [(householdID: String, event: GridEvent)],
        householdID: String?,
        liveBedIDs: Set<String>
    ) -> [String: GridEvent] {
        guard let householdID else { return [:] }
        let scoped = events.compactMap { item -> GridEvent? in
            guard item.householdID == householdID,
                  let bedID = item.event.bedID, liveBedIDs.contains(bedID) else { return nil }
            return item.event
        }
        return nextPlannedBySeed(scoped)
    }
}
