import Foundation
import SeedkeepKit

/// Hardcoded average frost-date lookup by USDA hardiness zone. Values
/// are agronomic baselines drawn from typical zone-by-zone references
/// (Burpee, Johnny's Seeds, USDA NRCS); not microclimate-precise. Users
/// can always override in Garden Settings.
///
/// Auto-fill is a starting point — the actual frost date depends on
/// the user's specific microclimate, altitude, and proximity to water.
/// We surface these as "approximate" in the UI so users adjust as they
/// learn their site over years.
enum HardinessZoneFrostData {
    struct FrostDates {
        let last: MonthDay   // Average last spring frost
        let first: MonthDay  // Average first fall frost
    }

    static let byZone: [Int: FrostDates] = [
        1:  FrostDates(last: MonthDay(month: 6, day: 15), first: MonthDay(month: 8, day: 31)),
        2:  FrostDates(last: MonthDay(month: 6, day: 1),  first: MonthDay(month: 9, day: 15)),
        3:  FrostDates(last: MonthDay(month: 5, day: 15), first: MonthDay(month: 9, day: 30)),
        4:  FrostDates(last: MonthDay(month: 5, day: 1),  first: MonthDay(month: 10, day: 15)),
        5:  FrostDates(last: MonthDay(month: 4, day: 15), first: MonthDay(month: 10, day: 30)),
        6:  FrostDates(last: MonthDay(month: 4, day: 1),  first: MonthDay(month: 11, day: 15)),
        7:  FrostDates(last: MonthDay(month: 3, day: 15), first: MonthDay(month: 11, day: 30)),
        8:  FrostDates(last: MonthDay(month: 3, day: 1),  first: MonthDay(month: 12, day: 15)),
        9:  FrostDates(last: MonthDay(month: 1, day: 30), first: MonthDay(month: 12, day: 30)),
        // Zones 10+ are effectively frost-free in most years; we still
        // surface a notional date so the UI has something to anchor on.
        10: FrostDates(last: MonthDay(month: 1, day: 15), first: MonthDay(month: 12, day: 31)),
        11: FrostDates(last: MonthDay(month: 1, day: 1),  first: MonthDay(month: 12, day: 31)),
        12: FrostDates(last: MonthDay(month: 1, day: 1),  first: MonthDay(month: 12, day: 31)),
        13: FrostDates(last: MonthDay(month: 1, day: 1),  first: MonthDay(month: 12, day: 31)),
    ]

    static func dates(for zone: Int) -> FrostDates? {
        byZone[zone]
    }
}
