import Testing
import Foundation
@testable import Seedkeep

// Golden cases ported from seedkeep-server/src/lib/recommendation/__tests__/engine.test.ts and
// projection.test.ts. Dates are fixed, so nothing here reads the clock.

// MARK: - Fixtures

private let zone7a = HomeClimate(
    zip: "00000", latitude: 0, longitude: 0,
    usdaZone: "7a", avgLastFrost: "04-10", avgFirstFrost: "11-01"
)

private let fullTenderDirect = GrowingInfoSnapshot(
    frost_tolerance: "tender",
    sow_method: "direct",
    days_to_germinate_min: 7,
    days_to_germinate_max: 14,
    days_to_maturity_min: 60,
    days_to_maturity_max: 80,
    soil_temp_min_f: 60,
    soil_temp_max_f: 95,
    hardiness_zone_min: 3,
    hardiness_zone_max: 11
)

private func baseline(
    _ info: GrowingInfoSnapshot,
    _ climate: HomeClimate = zone7a,
    year: Int = 2026
) throws -> PlantingEngine.RuleBaseline {
    try #require(PlantingEngine.ruleBaseline(growingInfo: info, climate: climate, year: year))
}

private func climate(zone: String, lastFrost: String, firstFrost: String) -> HomeClimate {
    HomeClimate(
        zip: "00000", latitude: 0, longitude: 0,
        usdaZone: zone, avgLastFrost: lastFrost, avgFirstFrost: firstFrost
    )
}

// MARK: - Rule baseline

@Suite("PlantingEngine — rule baseline")
struct PlantingEngineRuleBaselineTests {
    @Test("tender direct-sow opens at last frost, at full confidence")
    func tenderOpensAtLastFrost() throws {
        let b = try baseline(fullTenderDirect)
        #expect(b.windowStart == "2026-04-10")
        #expect(b.confidence == 1.0)
        #expect(b.confidence >= PlantingEngine.confidenceThreshold)
    }

    @Test("hardy direct-sow opens four weeks before last frost")
    func hardyOpensFourWeeksEarlier() throws {
        var info = fullTenderDirect
        info.frost_tolerance = "hardy"
        #expect(try baseline(info).windowStart == "2026-03-13")
    }

    @Test("half-hardy direct-sow opens a week before last frost")
    func halfHardyOpensAWeekEarlier() throws {
        var info = fullTenderDirect
        info.frost_tolerance = "half_hardy"
        #expect(try baseline(info).windowStart == "2026-04-03")
    }

    @Test("latest plant date leaves maturity plus a 14-day buffer before first frost")
    func latestLeavesMaturityBuffer() throws {
        // 11-01 minus 80 days maturity minus 14 buffer is 2026-07-30.
        #expect(try baseline(fullTenderDirect).windowEnd == "2026-07-30")
    }

    @Test("the minimum maturity is used only when the maximum is missing")
    func maturityFallsBackToMinimum() throws {
        var info = fullTenderDirect
        info.days_to_maturity_max = nil
        // 11-01 minus 60 days minimum minus 14 buffer is 2026-08-19.
        #expect(try baseline(info).windowEnd == "2026-08-19")
    }

    @Test("a transplant variety gets an indoor window 42 to 56 days before its earliest planting")
    func transplantGetsIndoorWindow() throws {
        var info = fullTenderDirect
        info.sow_method = "transplant"
        let b = try baseline(info)
        #expect(b.indoorStart == "2026-02-13")
        #expect(b.indoorEnd == "2026-02-27")
    }

    @Test("a direct-sow variety gets no indoor window")
    func directSowHasNoIndoorWindow() throws {
        let b = try baseline(fullTenderDirect)
        #expect(b.indoorStart == nil)
        #expect(b.indoorEnd == nil)
    }

    @Test("missing frost tolerance and soil temperature drops confidence below the threshold")
    func missingFrostAndSoilDropsConfidence() throws {
        var info = fullTenderDirect
        info.frost_tolerance = nil
        info.soil_temp_min_f = nil
        let b = try baseline(info)
        #expect(b.confidence == 0.55)
        #expect(b.confidence < PlantingEngine.confidenceThreshold)
    }

    @Test("a missing sow method and soil temperature round to two decimals")
    func confidenceRoundsToTwoDecimals() throws {
        // 1.0 - 0.20 - 0.15 is 0.6499999... in binary floating point; it must round to 0.65.
        var info = fullTenderDirect
        info.soil_temp_min_f = nil
        info.sow_method = nil
        #expect(try baseline(info).confidence == 0.65)
    }

    @Test("missing maturity leaves no window and costs 0.10 of confidence")
    func missingMaturityHasNoWindow() throws {
        var info = fullTenderDirect
        info.days_to_maturity_min = nil
        info.days_to_maturity_max = nil
        let b = try baseline(info)
        #expect(b.windowStart == nil)
        #expect(b.windowEnd == nil)
        #expect(b.confidence == 0.9)
    }

    @Test("an inverted window (season too short) has no window and is capped just under the threshold")
    func invertedWindowIsCapped() throws {
        // Zone 3: last frost about May 28, first frost about Sep 12. A tender 110-day crop needs to be
        // planted by May 11, which is before the earliest planting, May 28.
        let zone3 = climate(zone: "3", lastFrost: "05-28", firstFrost: "09-12")
        var info = fullTenderDirect
        info.days_to_maturity_min = 100
        info.days_to_maturity_max = 110
        let b = try baseline(info, zone3)
        #expect(b.windowStart == nil)
        #expect(b.windowEnd == nil)
        #expect(b.confidence == 0.59)
        #expect(b.confidence < PlantingEngine.confidenceThreshold)
    }

    @Test("a valid window passes unchanged when the latest date is not before the earliest")
    func validWindowIsUnchanged() throws {
        let b = try baseline(fullTenderDirect)
        #expect(b.windowStart == "2026-04-10")
        #expect(b.windowEnd == "2026-07-30")
        #expect(b.confidence >= PlantingEngine.confidenceThreshold)
    }

    @Test("a zone above 10 with no hardiness range costs 0.10, and a zone from 3 to 10 does not")
    func zonePenaltyOnlyOutsideThreeToTen() throws {
        var info = fullTenderDirect
        info.hardiness_zone_min = nil
        info.hardiness_zone_max = nil
        #expect(try baseline(info, climate(zone: "7a", lastFrost: "04-10", firstFrost: "11-01")).confidence == 1.0)
        #expect(try baseline(info, climate(zone: "10b", lastFrost: "04-10", firstFrost: "11-01")).confidence == 1.0)
        #expect(try baseline(info, climate(zone: "11a", lastFrost: "04-10", firstFrost: "11-01")).confidence == 0.9)
    }

    @Test("a zone below 3 with no hardiness range costs 0.10")
    func lowZonePenalty() throws {
        // A 40-day crop keeps the window valid in zone 2 (first frost 08-28), so only the zone applies.
        var info = fullTenderDirect
        info.hardiness_zone_min = nil
        info.hardiness_zone_max = nil
        info.days_to_maturity_min = 30
        info.days_to_maturity_max = 40
        let b = try baseline(info, climate(zone: "2b", lastFrost: "06-05", firstFrost: "08-28"))
        #expect(b.windowStart == "2026-06-05")
        #expect(b.confidence == 0.9)
    }

    @Test("a malformed frost date returns no baseline")
    func malformedFrostReturnsNil() throws {
        #expect(PlantingEngine.ruleBaseline(growingInfo: fullTenderDirect, climate: climate(zone: "7a", lastFrost: "april", firstFrost: "11-01"), year: 2026) == nil)
    }
}

// MARK: - Projection

@Suite("PlantingEngine — projection")
struct PlantingEngineProjectionTests {
    @Test("a missing window is unknown with 60 zero scores")
    func missingWindowIsUnknown() {
        let p = PlantingEngine.project(windowStart: nil, windowEnd: nil, today: "2026-05-20")
        #expect(p.verdict == "unknown")
        #expect(p.dailyScores.count == 60)
        #expect(p.dailyScores.allSatisfy { $0 == 0 })
    }

    @Test("the verdict is too_early well before the window opens")
    func tooEarly() {
        let p = PlantingEngine.project(windowStart: "2026-06-15", windowEnd: "2026-08-01", today: "2026-05-20")
        #expect(p.verdict == "too_early")
    }

    @Test("the verdict is plant_soon within 14 days of opening")
    func plantSoon() {
        let p = PlantingEngine.project(windowStart: "2026-05-25", windowEnd: "2026-07-01", today: "2026-05-20")
        #expect(p.verdict == "plant_soon")
    }

    @Test("the verdict is plant_now in the early part of the window")
    func plantNow() {
        let p = PlantingEngine.project(windowStart: "2026-05-18", windowEnd: "2026-07-01", today: "2026-05-20")
        #expect(p.verdict == "plant_now")
    }

    @Test("the verdict is late in the back part of the window")
    func late() {
        let p = PlantingEngine.project(windowStart: "2026-04-01", windowEnd: "2026-05-25", today: "2026-05-20")
        #expect(p.verdict == "late")
    }

    @Test("the verdict is too_late past the window")
    func tooLate() {
        let p = PlantingEngine.project(windowStart: "2026-03-01", windowEnd: "2026-05-01", today: "2026-05-20")
        #expect(p.verdict == "too_late")
    }

    @Test("plant_soon covers exactly 14 days before the window and too_early starts at 15")
    func tooEarlyBoundary() {
        // 2026-05-20 to 2026-06-03 is 14 days; to 2026-06-04 is 15.
        #expect(PlantingEngine.project(windowStart: "2026-06-03", windowEnd: "2026-07-01", today: "2026-05-20").verdict == "plant_soon")
        #expect(PlantingEngine.project(windowStart: "2026-06-04", windowEnd: "2026-07-01", today: "2026-05-20").verdict == "too_early")
    }

    @Test("plant_now covers exactly the first 40 percent of the window")
    func plantNowBoundary() {
        // A 30-day window has a plant-now span of 12 days after it opens.
        let start = "2026-05-20"
        let end = "2026-06-19"
        #expect(PlantingEngine.project(windowStart: start, windowEnd: end, today: "2026-06-01").verdict == "plant_now")
        #expect(PlantingEngine.project(windowStart: start, windowEnd: end, today: "2026-06-02").verdict == "late")
    }

    @Test("the last day of the window is late and the day after is too_late")
    func windowEndBoundary() {
        #expect(PlantingEngine.project(windowStart: "2026-05-01", windowEnd: "2026-05-20", today: "2026-05-20").verdict == "late")
        #expect(PlantingEngine.project(windowStart: "2026-05-01", windowEnd: "2026-05-20", today: "2026-05-21").verdict == "too_late")
    }

    @Test("scores are 0 at the window edge, ramp to 1 after a full ramp, and stay within 0...1")
    func scoresRamp() throws {
        let p = PlantingEngine.project(windowStart: "2026-05-20", windowEnd: "2026-09-20", today: "2026-05-20")
        #expect(p.dailyScores.count == 60)
        #expect(p.dailyScores[0] == 0)
        #expect(abs(p.dailyScores[7] - 1) < 1e-9)
        #expect(p.dailyScores.allSatisfy { $0 >= 0 && $0 <= 1 })
    }

    @Test("a short window ramps over half its length, so its midpoint still scores 1.0")
    func shortWindowPeaks() {
        // 2026-05-20 to 2026-05-26 is 6 days, so the ramp is 3 and the midpoint is day 3.
        let p = PlantingEngine.project(windowStart: "2026-05-20", windowEnd: "2026-05-26", today: "2026-05-20")
        #expect(abs(p.dailyScores[3] - 1) < 1e-9)
        #expect(p.dailyScores.allSatisfy { $0 >= 0 && $0 <= 1 })
    }

    @Test("an eight-day window ramps over four days, and the days after its end score 0")
    func shortWindowRampAndEnd() {
        // 2026-05-22 to 2026-05-30 is 8 days, so the ramp is 4. Index 2 is the start, index 10 the end.
        let p = PlantingEngine.project(windowStart: "2026-05-22", windowEnd: "2026-05-30", today: "2026-05-20")
        #expect(p.dailyScores[0] == 0)
        #expect(p.dailyScores[1] == 0)
        #expect(p.dailyScores[2] == 0)
        #expect(p.dailyScores[3] == 0.25)
        #expect(p.dailyScores[6] == 1)
        #expect(p.dailyScores[10] == 0)
        #expect(p.dailyScores[11] == 0)
    }

    @Test("a window that opens after the 60-day span scores all zeros")
    func windowBeyondSpan() {
        let p = PlantingEngine.project(windowStart: "2026-09-01", windowEnd: "2026-10-01", today: "2026-05-20")
        #expect(p.verdict == "too_early")
        #expect(p.dailyScores.allSatisfy { $0 == 0 })
    }
}

// MARK: - Recommendation

@Suite("PlantingEngine — recommend")
struct PlantingEngineRecommendTests {
    @Test("a recommendation carries the rule source, the window, a 60-day curve and no reasoning")
    func recommendationShape() {
        let rec = PlantingEngine.recommend(
            growingInfo: fullTenderDirect,
            climate: zone7a,
            today: (2026, 5, 20)
        )
        #expect(rec.source == "rule")
        #expect(rec.verdict == "plant_now")
        #expect(rec.rangeStart == "2026-04-10")
        #expect(rec.rangeEnd == "2026-07-30")
        #expect(rec.indoorStart == nil)
        #expect(rec.scoresAnchorDate == "2026-05-20")
        #expect(rec.dailyScores.count == 60)
        #expect(rec.reasoning == nil)
        #expect(rec.confidence == 1.0)
    }

    @Test("a seed with no maturity has no window, is unknown, and has 60 zero scores")
    func noWindowIsUnknown() {
        var info = fullTenderDirect
        info.days_to_maturity_min = nil
        info.days_to_maturity_max = nil
        let rec = PlantingEngine.recommend(growingInfo: info, climate: zone7a, today: (2026, 5, 20))
        #expect(rec.verdict == "unknown")
        #expect(rec.rangeStart == nil)
        #expect(rec.rangeEnd == nil)
        #expect(rec.dailyScores == Array(repeating: 0, count: 60))
    }

    @Test("a low-confidence rule window is returned with its confidence and no AI fallback")
    func lowConfidenceWindowIsShown() {
        var info = fullTenderDirect
        info.frost_tolerance = nil
        info.soil_temp_min_f = nil
        let rec = PlantingEngine.recommend(growingInfo: info, climate: zone7a, today: (2026, 5, 20))
        #expect(rec.source == "rule")
        #expect(rec.confidence == 0.55)
        #expect(rec.verdict == "plant_now")
        #expect(rec.rangeStart == "2026-04-10")
    }

    @Test("year rollover: the same season is too_late on December 31 and the next year's window starts on January 1")
    func yearRollover() {
        let lastDay = PlantingEngine.recommend(growingInfo: fullTenderDirect, climate: zone7a, today: (2026, 12, 31))
        #expect(lastDay.verdict == "too_late")
        #expect(lastDay.rangeStart == "2026-04-10")

        let newYear = PlantingEngine.recommend(growingInfo: fullTenderDirect, climate: zone7a, today: (2027, 1, 1))
        #expect(newYear.scoresAnchorDate == "2027-01-01")
        #expect(newYear.rangeStart == "2027-04-10")
        #expect(newYear.verdict == "too_early")
    }

    @Test("a leap day is handled and the next day is March 1")
    func leapDay() {
        let leap = PlantingEngine.recommend(growingInfo: fullTenderDirect, climate: zone7a, today: (2028, 2, 29))
        #expect(leap.scoresAnchorDate == "2028-02-29")
        let march = PlantingEngine.recommend(growingInfo: fullTenderDirect, climate: zone7a, today: (2028, 3, 1))
        #expect(march.scoresAnchorDate == "2028-03-01")
    }

    @Test("the recommendation depends only on the date it is given, not on the clock")
    func usesGivenDateOnly() {
        let a = PlantingEngine.recommend(growingInfo: fullTenderDirect, climate: zone7a, today: (2026, 5, 20))
        let b = PlantingEngine.recommend(growingInfo: fullTenderDirect, climate: zone7a, today: (2026, 5, 20))
        #expect(a == b)
    }
}

// MARK: - Local date

@Suite("PlantingEngine — local date and day numbers")
struct PlantingEngineLocalDateTests {
    /// 2026-05-20 01:30 UTC: May 20 in Tokyo, May 19 in Los Angeles.
    private let instant = Date(timeIntervalSince1970: 1_779_240_600)

    @Test("the local date east of UTC is the calendar day where the user is")
    func eastOfUTC() throws {
        let tokyo = try #require(TimeZone(identifier: "Asia/Tokyo"))
        let today = PlantingEngine.localToday(now: instant, timeZone: tokyo)
        #expect(today == (2026, 5, 20))
    }

    @Test("the local date west of UTC can still be the previous UTC day")
    func westOfUTC() throws {
        let losAngeles = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let today = PlantingEngine.localToday(now: instant, timeZone: losAngeles)
        #expect(today == (2026, 5, 19))
    }

    @Test("the local date changes the verdict for a window that opens on the local date")
    func localDateDrivesVerdict() throws {
        let losAngeles = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let tokyo = try #require(TimeZone(identifier: "Asia/Tokyo"))
        let window = climate(zone: "7a", lastFrost: "05-20", firstFrost: "11-01")
        let info = fullTenderDirect

        let laRec = PlantingEngine.recommend(growingInfo: info, climate: window,
                                             today: PlantingEngine.localToday(now: instant, timeZone: losAngeles))
        let tokyoRec = PlantingEngine.recommend(growingInfo: info, climate: window,
                                                today: PlantingEngine.localToday(now: instant, timeZone: tokyo))
        #expect(laRec.verdict == "plant_soon")
        #expect(tokyoRec.verdict == "plant_now")
    }

    @Test("day numbers match the Gregorian calendar in UTC across leap years and the year boundary")
    func dayNumbersMatchGregorianCalendar() {
        // Oracle: Foundation's Gregorian calendar in UTC, counted from the Unix epoch. The engine
        // computes the same number with integer arithmetic.
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let epoch = Date(timeIntervalSince1970: 0)
        var day = utc.date(from: DateComponents(year: 1999, month: 12, day: 25))!
        let end = utc.date(from: DateComponents(year: 2030, month: 1, day: 5))!
        while day <= end {
            let parts = utc.dateComponents([.year, .month, .day], from: day)
            let expected = utc.dateComponents([.day], from: epoch, to: day).day!
            #expect(PlantingEngine.dayNumber(year: parts.year!, month: parts.month!, day: parts.day!) == expected)
            day = utc.date(byAdding: .day, value: 1, to: day)!
        }
    }
}

// MARK: - Reasons and panel wording (N2 review O1, O2)

@MainActor
@Suite("PlantingEngine — reasons and panel wording")
struct PlantingEngineReasonTests {
    @Test("a full window has no reason")
    func fullWindowHasNoReason() {
        let rec = PlantingEngine.recommend(growingInfo: fullTenderDirect, climate: zone7a, today: (2026, 5, 20))
        #expect(rec.reason == nil)
        #expect(RecommendationPanel.confidenceNote(for: rec) == nil)
    }

    @Test("no days to maturity is missingMaturity, worded as such")
    func missingMaturityReason() {
        var info = fullTenderDirect
        info.days_to_maturity_min = nil
        info.days_to_maturity_max = nil
        let rec = PlantingEngine.recommend(growingInfo: info, climate: zone7a, today: (2026, 5, 20))
        #expect(rec.reason == .missingMaturity)
        #expect(RecommendationPanel.noWindowNote(for: rec.reason).contains("no days to maturity"))
        #expect(RecommendationPanel.confidenceNote(for: rec) == nil)
    }

    @Test("an inverted window is seasonTooShort, not incomplete info")
    func seasonTooShortReason() {
        var info = fullTenderDirect
        info.days_to_maturity_max = 120
        let short = climate(zone: "3b", lastFrost: "05-25", firstFrost: "09-08")
        let rec = PlantingEngine.recommend(growingInfo: info, climate: short, today: (2026, 5, 20))
        #expect(rec.reason == .seasonTooShort)
        #expect(rec.confidence < PlantingEngine.confidenceThreshold)
        #expect(RecommendationPanel.noWindowNote(for: rec.reason).contains("season here is too short"))
        #expect(RecommendationPanel.confidenceNote(for: rec) == nil, "the low-confidence note would blame the growing info")
    }

    @Test("a low-confidence window from missing fields is incompleteInfo, with the confidence note")
    func incompleteInfoReason() throws {
        var info = fullTenderDirect
        info.frost_tolerance = nil
        info.soil_temp_min_f = nil
        let rec = PlantingEngine.recommend(growingInfo: info, climate: zone7a, today: (2026, 5, 20))
        #expect(rec.reason == .incompleteInfo)
        let note = try #require(RecommendationPanel.confidenceNote(for: rec))
        #expect(note.contains("55%"))
        #expect(note.contains("incomplete"))
    }

    @Test("unreadable frost dates are unreadableClimate")
    func unreadableClimateReason() {
        let broken = climate(zone: "7a", lastFrost: "april", firstFrost: "11-01")
        let rec = PlantingEngine.recommend(growingInfo: fullTenderDirect, climate: broken, today: (2026, 5, 20))
        #expect(rec.reason == .unreadableClimate)
        #expect(RecommendationPanel.noWindowNote(for: rec.reason).contains("frost dates"))
    }

    @Test("no recommendation reads 'No growing info' only when the seed has none at all (V7)")
    func noRecommendationNote() {
        #expect(RecommendationPanel.noRecommendationNote(hasGrowingInfo: false) == "No growing info for this seed.")
        #expect(RecommendationPanel.noRecommendationNote(hasGrowingInfo: true).hasPrefix("This seed's growing info doesn't include"))
    }

    @Test("the unknown verdict is final on the device and reads No window")
    func unknownReadsNoWindow() {
        #expect(RecommendationPanel.verdictLabel(for: "unknown") == "No window")
        #expect(RecommendationPanel.verdictLabel(for: "plant_now") == "Plant now")
        #expect(SeedTableRow.verdictLabel(for: "unknown") == "No window")
    }
}

// MARK: - What-to-plant day counts (N2 review O8)

@Suite("What to plant — local day counts")
struct PlantingWindowDaysTests {
    /// 2026-05-20 01:30 UTC: still May 19 in Los Angeles.
    private let instant = Date(timeIntervalSince1970: 1_779_240_600)

    @Test("west of UTC, the count runs from the local day, not the UTC day")
    func westOfUTCCountsLocalDays() throws {
        let losAngeles = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let today = PlantingEngine.localToday(now: instant, timeZone: losAngeles)

        #expect(PlantingWindowDays.label(verdict: "plant_now", rangeStart: "2026-05-01", rangeEnd: "2026-05-20", today: today) == "1 day left")
        #expect(PlantingWindowDays.label(verdict: "plant_now", rangeStart: "2026-05-01", rangeEnd: "2026-05-19", today: today) == "closes today")
        #expect(PlantingWindowDays.label(verdict: "too_early", rangeStart: "2026-05-29", rangeEnd: "2026-07-01", today: today) == "opens in 10 days")
        #expect(PlantingWindowDays.label(verdict: "too_late", rangeStart: "2026-04-01", rangeEnd: "2026-05-17", today: today) == "2 days ago")
    }

    @Test("a window that opens today is not counted as opening")
    func opensTodayHasNoLabel() {
        #expect(PlantingWindowDays.label(verdict: "too_early", rangeStart: "2026-05-19", rangeEnd: "2026-06-01", today: (2026, 5, 19)) == nil)
    }
}
