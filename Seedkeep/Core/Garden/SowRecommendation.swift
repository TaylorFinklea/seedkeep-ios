import Foundation
import SeedkeepKit

/// Derives a recommended sow date from a catalog entry's frost
/// tolerance + sow method, anchored against the user's average last
/// spring frost. Returns nil when there's not enough signal — better
/// to stay quiet than to push a wrong date.
///
/// Rules drawn from standard agronomic practice:
///   - tender + transplant     → start indoors ~6 weeks before last frost
///   - tender + direct         → direct sow ~2 weeks after last frost
///   - tender + either         → start indoors ~6 weeks before, transplant after
///   - half_hardy + transplant → start indoors ~4 weeks before last frost
///   - half_hardy + direct     → direct sow ~1 week before last frost
///   - half_hardy + either     → start indoors ~4 weeks before
///   - hardy + direct          → direct sow ~4 weeks before last frost
///   - hardy + transplant      → start indoors ~6 weeks before last frost
///   - hardy + either          → direct sow ~4 weeks before
enum SowRecommendation {
    struct Plan: Equatable {
        let kind: PlantingEventKind        // sowing or transplant
        let date: Date
        /// Headline like "Start indoors" or "Direct sow"
        let phrase: String
        /// Short rationale like "6 weeks before last frost"
        let detail: String
    }

    static func recommend(
        for catalog: CatalogSeedDTO,
        lastFrost: MonthDay,
        year: Int = Calendar.current.component(.year, from: Date()),
        calendar: Calendar = .current
    ) -> Plan? {
        guard let frostDate = lastFrost.date(inYear: year, calendar: calendar) else {
            return nil
        }
        let tolerance = catalog.frost_tolerance
        let sow = catalog.sow_method

        // Walk through the rules. Anything we can't classify → nil.
        let recommendation: (offsetWeeks: Int, kind: PlantingEventKind, phrase: String)?
        switch (tolerance, sow) {
        case ("tender", "transplant"), ("tender", "either"):
            recommendation = (-6, .transplant, "Start indoors")
        case ("tender", "direct"):
            recommendation = (+2, .sowing, "Direct sow")
        case ("half_hardy", "transplant"), ("half_hardy", "either"):
            recommendation = (-4, .transplant, "Start indoors")
        case ("half_hardy", "direct"):
            recommendation = (-1, .sowing, "Direct sow")
        case ("hardy", "transplant"):
            recommendation = (-6, .transplant, "Start indoors")
        case ("hardy", "direct"), ("hardy", "either"):
            recommendation = (-4, .sowing, "Direct sow")
        default:
            return nil
        }
        guard let rec = recommendation else { return nil }
        guard let date = calendar.date(byAdding: .day, value: rec.offsetWeeks * 7, to: frostDate) else {
            return nil
        }
        let weeksAbs = abs(rec.offsetWeeks)
        let direction = rec.offsetWeeks < 0 ? "before" : "after"
        let detail: String
        if weeksAbs == 0 {
            detail = "on your last-frost date"
        } else {
            detail = "\(weeksAbs) week\(weeksAbs == 1 ? "" : "s") \(direction) last frost"
        }
        return Plan(kind: rec.kind, date: date, phrase: rec.phrase, detail: detail)
    }
}
