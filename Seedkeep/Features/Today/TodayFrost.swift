import Foundation

/// Frost on Today (R3 G4): the warning banner's count, copy and Open Garden route. Pure, so the rules are
/// tested without the view. A due row's frost flag comes from `FrostCheck` through the Garden's adapters.
enum TodayFrost {
    /// The banner covers today and the 13 days after it: 14 days in all.
    static let lookaheadDays = 13

    static let openGardenLabel = "Open Garden"

    /// The shell that shows Today. Open Garden routes from this host, never from the size class.
    enum Host: Equatable, Sendable {
        /// The compact tab shell.
        case compactTab
        /// The workbench's Today route, where the window's route switches to Garden.
        case workbenchRoute
    }

    /// Where Open Garden goes. The view applies the case it returns.
    enum GardenRoute: Equatable, Sendable {
        /// The compact tab shell: `requestedTab = .garden`.
        case gardenTab
        /// The workbench: its route switches to Garden.
        case gardenRoute

        static func route(for host: Host) -> GardenRoute {
            switch host {
            case .compactTab: return .gardenTab
            case .workbenchRoute: return .gardenRoute
            }
        }
    }

    /// How many plantings the banner counts: live, incomplete events of `householdID` planned from `today` through
    /// `today + 13` that `FrostCheck` flags. Each event counts, so two plantings of one seed count twice. Other
    /// households' events, deleted or completed rows, and events of seeds that aren't tender don't count. Only this
    /// household's live seeds are consulted.
    static func warningCount(
        events: [LocalPlantingEvent],
        seeds: [LocalSeed],
        householdID: String,
        climate: HomeClimate?,
        today: CalendarDay
    ) -> Int {
        let last = today.adding(days: lookaheadDays)
        let liveSeeds = seeds.filter { $0.householdID == householdID && $0.deletedAt == nil }
        let seedsByID = Dictionary(liveSeeds.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return TodayHouseholdScope.events(events, householdID: householdID).filter { event in
            guard event.deletedAt == nil,
                  event.completedAt == nil,
                  let planned = CalendarDay.parse(event.plannedFor),
                  planned >= today,
                  planned <= last
            else { return false }
            return FrostCheck.check(event, seed: event.seedID.flatMap { seedsByID[$0] }, climate: climate).isFlagged
        }.count
    }

    /// The banner's sentence, singular or plural: "1 planting may meet frost (zone estimate)." or
    /// "3 plantings may meet frost (zone estimate)."
    static func warningTitle(count: Int) -> String {
        count == 1
            ? "1 planting may meet frost (zone estimate)."
            : "\(count) plantings may meet frost (zone estimate)."
    }
}
