import Foundation

/// A planting recommendation for one seed at one home location, computed on the device.
/// Ports the server's `computeRuleBaseline` (`engine.ts`) and `projectWindow` (`projection.ts`).
struct PlantingRecommendation: Equatable, Sendable {
    /// Always "rule". The device has no AI fallback.
    let source: String
    /// 0...1, rounded to two decimals. A low value means the rule had less to go on.
    let confidence: Double
    /// too_early | plant_soon | plant_now | late | too_late | unknown
    let verdict: String
    /// "YYYY-MM-DD"
    let rangeStart: String?
    let rangeEnd: String?
    let indoorStart: String?
    let indoorEnd: String?
    /// "YYYY-MM-DD", the date of `dailyScores[0]`.
    let scoresAnchorDate: String
    /// One score per day for 60 days from `scoresAnchorDate`.
    let dailyScores: [Double]
    /// Always nil for the rule source.
    let reasoning: String?
    /// Why there is no window, or why its confidence is low. nil for a confident window.
    var reason: Reason? = nil

    /// What the engine was missing. The panel words its note from this.
    enum Reason: String, Equatable, Sendable {
        /// The crop cannot mature before the first frost: the latest date falls before the earliest.
        case seasonTooShort
        /// No days to maturity, so there is no latest planting date.
        case missingMaturity
        /// A window exists, but its confidence is low because growing info fields are missing.
        case incompleteInfo
        /// The home location's frost dates could not be read.
        case unreadableClimate
    }
}

/// Deterministic planting-window engine. Pure: the caller passes the date, and nothing reads the
/// clock, a time zone, or `Calendar.current`. Dates are integer day numbers (days since
/// 1970-01-01, proleptic Gregorian), so day arithmetic is exact.
enum PlantingEngine {
    /// The server's `CONFIDENCE_THRESHOLD`. A window whose latest date falls before its earliest is
    /// capped just under this value.
    static let confidenceThreshold = 0.6

    private static let maturityBufferDays = 14
    private static let indoorStartMinDays = 42
    private static let indoorStartMaxDays = 56
    private static let scoreDays = 60
    private static let rampDays = 7.0
    private static let plantNowFraction = 0.4
    private static let tooEarlyDays = 14

    /// The recommendation for `growingInfo` at `climate`, as of the local calendar date `today`.
    static func recommend(
        growingInfo: GrowingInfoSnapshot,
        climate: HomeClimate,
        today: (year: Int, month: Int, day: Int)
    ) -> PlantingRecommendation {
        let anchorDate = isoDate(dayNumber(year: today.year, month: today.month, day: today.day))
        guard let baseline = ruleBaseline(growingInfo: growingInfo, climate: climate, year: today.year) else {
            return PlantingRecommendation(
                source: "rule",
                confidence: 0,
                verdict: "unknown",
                rangeStart: nil,
                rangeEnd: nil,
                indoorStart: nil,
                indoorEnd: nil,
                scoresAnchorDate: anchorDate,
                dailyScores: Array(repeating: 0, count: scoreDays),
                reasoning: nil,
                reason: .unreadableClimate
            )
        }
        let projection = project(
            windowStart: baseline.windowStart,
            windowEnd: baseline.windowEnd,
            today: anchorDate
        )
        return PlantingRecommendation(
            source: "rule",
            confidence: baseline.confidence,
            verdict: projection.verdict,
            rangeStart: baseline.windowStart,
            rangeEnd: baseline.windowEnd,
            indoorStart: baseline.indoorStart,
            indoorEnd: baseline.indoorEnd,
            scoresAnchorDate: anchorDate,
            dailyScores: projection.dailyScores,
            reasoning: nil,
            reason: baseline.reason
        )
    }

    /// The local calendar date of `date` in `timeZone`, as the components `recommend` takes.
    static func localToday(now: Date = Date(), timeZone: TimeZone = .current) -> (year: Int, month: Int, day: Int) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: now)
        return (parts.year ?? 1970, parts.month ?? 1, parts.day ?? 1)
    }

    // MARK: - Rule baseline (engine.ts)

    struct RuleBaseline: Equatable {
        let windowStart: String?
        let windowEnd: String?
        let indoorStart: String?
        let indoorEnd: String?
        let confidence: Double
        var reason: PlantingRecommendation.Reason? = nil
    }

    /// `nil` when either frost date is malformed.
    static func ruleBaseline(growingInfo: GrowingInfoSnapshot, climate: HomeClimate, year: Int) -> RuleBaseline? {
        guard let lastFrost = monthDayNumber(climate.avgLastFrost, year: year),
              let firstFrost = monthDayNumber(climate.avgFirstFrost, year: year) else { return nil }

        // Earliest outdoor plant date by frost tolerance.
        var earliestOffset = 0
        if growingInfo.frost_tolerance == "half_hardy" {
            earliestOffset = -7
        } else if growingInfo.frost_tolerance == "hardy" {
            earliestOffset = -28
        }
        let earliest = lastFrost + earliestOffset

        // Latest plant date: must mature plus the buffer before first frost.
        let maturity = growingInfo.days_to_maturity_max ?? growingInfo.days_to_maturity_min
        let latest = maturity.map { firstFrost - ($0 + maturityBufferDays) }

        // Indoor-start window for transplant varieties.
        var indoorStart: String?
        var indoorEnd: String?
        if growingInfo.sow_method == "transplant" {
            indoorStart = isoDate(earliest - indoorStartMaxDays)
            indoorEnd = isoDate(earliest - indoorStartMinDays)
        }

        // Confidence: full data is 1.0, and each missing key input subtracts. The frost tolerance is
        // the most load-bearing input, so its absence costs the most.
        var confidence = 1.0
        if growingInfo.frost_tolerance == nil { confidence -= 0.25 }
        if growingInfo.soil_temp_min_f == nil { confidence -= 0.20 }
        if growingInfo.sow_method == nil { confidence -= 0.15 }
        if growingInfo.days_to_maturity_max == nil && growingInfo.days_to_maturity_min == nil {
            confidence -= 0.10
        }
        if let zone = leadingInteger(climate.usdaZone),
           growingInfo.hardiness_zone_min == nil || growingInfo.hardiness_zone_max == nil,
           zone < 3 || zone > 10 {
            confidence -= 0.10
        }
        confidence = max(0, (confidence * 100).rounded() / 100)

        // No window when latest is absent, or when latest is before earliest (an inverted window: the
        // crop cannot mature before frost in a short season). Cap the confidence below the threshold
        // so the window is shown as low-confidence.
        var windowStart: String?
        var windowEnd: String?
        let reason: PlantingRecommendation.Reason?
        if let latest {
            if latest >= earliest {
                windowStart = isoDate(earliest)
                windowEnd = isoDate(latest)
                reason = confidence < confidenceThreshold ? .incompleteInfo : nil
            } else {
                confidence = min(confidence, confidenceThreshold - 0.01)
                reason = .seasonTooShort
            }
        } else {
            reason = .missingMaturity
        }

        return RuleBaseline(
            windowStart: windowStart,
            windowEnd: windowEnd,
            indoorStart: indoorStart,
            indoorEnd: indoorEnd,
            confidence: confidence,
            reason: reason
        )
    }

    // MARK: - Projection (projection.ts)

    struct Projection: Equatable {
        let verdict: String
        let dailyScores: [Double]
    }

    /// Projects a season-stable window onto `today` (a "YYYY-MM-DD" string): the verdict and a
    /// 60-day suitability curve.
    static func project(windowStart: String?, windowEnd: String?, today: String) -> Projection {
        let zeros = Array(repeating: 0.0, count: scoreDays)
        guard let windowStart, let windowEnd,
              let start = parseISODate(windowStart),
              let end = parseISODate(windowEnd),
              let now = parseISODate(today) else {
            return Projection(verdict: "unknown", dailyScores: zeros)
        }

        let windowLength = max(1, end - start)

        let verdict: String
        if start - now > tooEarlyDays {
            verdict = "too_early"
        } else if now < start {
            verdict = "plant_soon"
        } else if Double(now - start) <= plantNowFraction * Double(windowLength) {
            verdict = "plant_now"
        } else if now <= end {
            verdict = "late"
        } else {
            verdict = "too_late"
        }

        // Short windows would have overlapping ramps and never reach 1.0. Use the smaller of the ramp
        // and half the window, so the midpoint always scores 1.0.
        let effectiveRamp = min(rampDays, Double(windowLength) / 2)

        var scores: [Double] = []
        scores.reserveCapacity(scoreDays)
        for offset in 0..<scoreDays {
            let day = now + offset
            guard day >= start, day <= end else {
                scores.append(0)
                continue
            }
            let rampUp = min(1, Double(day - start) / effectiveRamp)
            let rampDown = min(1, Double(end - day) / effectiveRamp)
            scores.append(min(rampUp, rampDown))
        }

        return Projection(verdict: verdict, dailyScores: scores)
    }

    // MARK: - Day numbers

    /// Days since 1970-01-01 for a proleptic Gregorian date (Howard Hinnant's `days_from_civil`).
    /// Day overflow carries into the next month, as `Date.UTC` does in the server.
    static func dayNumber(year: Int, month: Int, day: Int) -> Int {
        let shiftedYear = month <= 2 ? year - 1 : year
        let era = (shiftedYear >= 0 ? shiftedYear : shiftedYear - 399) / 400
        let yearOfEra = shiftedYear - era * 400
        let shiftedMonth = month > 2 ? month - 3 : month + 9
        let dayOfYear = (153 * shiftedMonth + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    /// The (year, month, day) of a day number (Hinnant's `civil_from_days`).
    private static func civilDate(_ dayNumber: Int) -> (year: Int, month: Int, day: Int) {
        let shifted = dayNumber + 719_468
        let era = (shifted >= 0 ? shifted : shifted - 146_096) / 146_097
        let dayOfEra = shifted - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let shiftedMonth = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * shiftedMonth + 2) / 5 + 1
        let month = shiftedMonth < 10 ? shiftedMonth + 3 : shiftedMonth - 9
        let year = yearOfEra + era * 400 + (month <= 2 ? 1 : 0)
        return (year, month, day)
    }

    /// "YYYY-MM-DD" for a day number.
    private static func isoDate(_ dayNumber: Int) -> String {
        let date = civilDate(dayNumber)
        return String(format: "%04ld-%02ld-%02ld", date.year, date.month, date.day)
    }

    /// The day number of a "YYYY-MM-DD" string, or nil when it does not parse.
    static func parseISODate(_ text: String) -> Int? {
        let parts = text.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return dayNumber(year: parts[0], month: parts[1], day: parts[2])
    }

    /// The day number of a "MM-DD" frost date in `year`, or nil when it does not parse.
    private static func monthDayNumber(_ text: String, year: Int) -> Int? {
        let parts = text.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 2 else { return nil }
        return dayNumber(year: year, month: parts[0], day: parts[1])
    }

    /// The integer `parseInt(text, 10)` reads from the front of a zone such as "7a", or nil when
    /// there are no leading digits.
    private static func leadingInteger(_ text: String) -> Int? {
        Int(text.prefix { ("0"..."9").contains($0) })
    }
}
