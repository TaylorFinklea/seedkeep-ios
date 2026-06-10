import Foundation

// MARK: - Inputs

/// One day of forecast data, sourced from WeatherKit. All temperatures are
/// Fahrenheit, all precipitation is millimetres of liquid-water-equivalent.
/// `date` is the WeatherKit-supplied midnight in the **home timezone**, as
/// an absolute `Date`.
struct DailyWeather: Sendable, Equatable {
    /// Midnight in homeTimeZone, as an absolute Date.
    let date: Date
    let lowF: Double
    let highF: Double
    /// Liquid-water-equivalent precipitation total (mm). Includes melted
    /// snow. The water evaluator should NOT use this directly — use
    /// `rainMM` instead.
    let precipMM: Double
    /// Rain only (snow stripped via `snowfallAmount * 0.1` density factor).
    /// For the water evaluator. May be 0 on a snow-only day.
    let rainMM: Double
    /// Apparent ("feels like") temperature high in Fahrenheit. Includes the
    /// humidity contribution. For the heat evaluator.
    let apparentHighF: Double
    let precipitationChance: Double
    let humidity: Double
    let windMPH: Double
}

/// One day of historical observations sourced from WeatherKit's
/// `weather(for:including: .daily(startDate:endDate:))` historical API.
/// Used by the water evaluator to score the past 5-day window.
struct ObservedDay: Sendable, Equatable {
    let date: Date
    /// Observed rain (mm). Snow stripped at the provider boundary.
    let rainMM: Double
    let highF: Double
    let humidity: Double
    let windMPH: Double
}

/// Persisted past-observations map, keyed by `Identifier.isoDay(...)` in
/// the home timezone. Empty on a fresh install until the first historical
/// fetch lands and the water evaluator's "min history" gate has been met.
struct PastObservations: Sendable, Equatable {
    /// Home-TZ YMD → observed day.
    let byYMD: [String: ObservedDay]
    /// YMD of the earliest observation we've ever persisted, for diagnostics.
    let firstObservationYMD: String?
}

/// KC-tuned threshold bundle. Designed to be extensible per-bed later —
/// in 4C we only consume `.kc`. All times are Fahrenheit or seconds.
struct WarningThresholds: Sendable {
    var frostLowF: Double = 33.0
    var heatApparentHighF: Double = 100.0       // heat-index trigger
    var heatRawHighF: Double = 95.0             // upgrade-trigger floor
    var heatDomeMinConsecutive: Int = 4
    var rainSignificantMM: Double = 6.0
    var rainCumulativeMinMM: Double = 12.0
    var dryStretchPastDays: Int = 5
    var dryStretchForecastDays: Int = 3
    var dryingScoreMinDailyHighF: Double = 75.0
    var waterDedupSeconds: TimeInterval = 7 * 86_400   // 7 days
    var waterExtendedAfterSeconds: TimeInterval = 10 * 86_400
    var waterMinObservedHistoryDays: Int = 3
    var queueBudget: Int = 40                   // leave headroom under iOS 64-cap

    /// Default-constructed singleton, KC-tuned.
    static let kc = WarningThresholds()
}

/// Three warning kinds. `rawValue` doubles as the AppStorage key suffix
/// (`seedkeep.notif.frost` / `…heat` / `…water`) and the notification
/// identifier prefix component.
enum WarningKind: String, Sendable, CaseIterable {
    case frost
    case heat
    case water
}

/// Reasons the water evaluator might pass on firing. Heat + frost don't
/// have a structured skip reason — they just emit `[]`.
enum SkipReason: Sendable, Equatable {
    case noTriggersInForecast
    case rainExpectedSoon(daysAhead: Int)
    case rainedRecentlyCumulative(mm: Double)
    case coolDryNotEnoughET
    case dedupWindow(secondsSinceLast: TimeInterval)
    case insufficientHistory(have: Int, need: Int)
    case heatDomeAlreadyAcknowledged
}

// MARK: - Frost

/// Frost is the simplest evaluator: any forecast day with a low strictly
/// below `thresholdF` fires a notification at 8am on the prior day.
enum FrostEvaluator {

    struct Hit: Sendable, Equatable {
        let frostDate: Date
        let fireDate: Date
        let lowF: Double
        let identifier: String
    }

    /// Walks the forecast and emits one `Hit` per day with `lowF < thresholdF`.
    /// Calendar math uses `guard let` everywhere — DST-skipped hours and
    /// edge-of-calendar days are silently skipped rather than crashing.
    static func evaluate(
        forecast: [DailyWeather],
        thresholdF: Double,
        now: Date,
        calendar: Calendar,
        homeTimeZone: TimeZone,
        fireBufferSeconds: TimeInterval = 15 * 60,
        /// Fire dates of OUR still-pending notification requests, keyed by
        /// identifier. Lets a refresh inside the pre-fire buffer keep the
        /// already-scheduled warning instead of cancelling it minutes
        /// before delivery.
        pendingFireDates: [String: Date] = [:]
    ) -> [Hit] {
        var hits: [Hit] = []
        let earliestFire = now.addingTimeInterval(fireBufferSeconds)

        for day in forecast {
            // 1) Strict-less-than threshold (32.9°F fires, 33.0°F doesn't).
            guard day.lowF < thresholdF else { continue }

            // 2) TZ-bound identifier — must use Identifier.isoDay so the id
            //    matches the legacy frost id char-for-char on upgrade.
            let identifier = WeatherWarningIdPrefix.frost
                + Identifier.isoDay(day.date, in: homeTimeZone)

            // 3) Prior day's midnight (home-TZ) → 8am.
            guard let priorDay = calendar.date(byAdding: .day, value: -1, to: day.date) else {
                continue
            }
            guard var fireDate = calendar.date(
                bySettingHour: 8,
                minute: 0,
                second: 0,
                of: priorDay,
                matchingPolicy: .nextTime,
                repeatedTimePolicy: .first,
                direction: .forward
            ) else {
                continue
            }

            // 4) Canonical fire time already passed (or is inside the
            //    15-min scheduling buffer):
            //    - our notification is still pending → keep its fire date
            //      so the diff preserves it (a refresh at 7:50am must not
            //      cancel the 8:00am warning);
            //    - frost night still ahead → deliver ASAP ("cover tender
            //      plants tonight" — a frost first forecast after 8am on
            //      the prior day must still warn);
            //    - frost morning already begun → nothing to deliver.
            if fireDate <= earliestFire {
                if let pendingFire = pendingFireDates[identifier] {
                    fireDate = pendingFire
                } else if day.date > now {
                    fireDate = earliestFire
                } else {
                    continue
                }
            }

            hits.append(Hit(
                frostDate: day.date,
                fireDate: fireDate,
                lowF: day.lowF,
                identifier: identifier
            ))
        }
        return hits
    }
}

// MARK: - Heat

/// Heat fires at 7pm the evening BEFORE the hot day. Three trigger paths
/// share one fire-time rule:
/// * **Heat-dome:** 4+ consecutive days at or above `heatRawHighF` (95°F).
/// * **Extreme:** any day where apparent (heat-index) ≥ `heatApparentHighF` (100°F).
/// * **First-of-season:** override variant on the first emitted hit if
///   `lastHeatEventDate` is nil OR > 30 days ago.
enum HeatEvaluator {

    enum Variant: Sendable, Equatable {
        case heatDomeStarting
        case extreme
        case firstOfSeason
    }

    struct Hit: Sendable, Equatable {
        /// First day of the dome, OR the extreme day. User reads
        /// "Saturday hits 103°F" while the notif arrives Friday evening.
        let heatDate: Date
        /// 7pm on the evening BEFORE `heatDate`.
        let fireDate: Date
        let highF: Double
        let apparentHighF: Double
        let variant: Variant
        let identifier: String
    }

    static func evaluate(
        forecast: [DailyWeather],
        thresholds: WarningThresholds,
        lastHeatDomeFireDate: Date?,
        lastHeatEventDate: Date?,
        now: Date,
        calendar: Calendar,
        homeTimeZone: TimeZone,
        fireBufferSeconds: TimeInterval = 15 * 60,
        /// Fire dates of OUR still-pending notification requests, keyed by
        /// identifier. The dome dedup must never drop a hit whose
        /// notification is still pending — `lastHeatDomeFireDate` is
        /// recorded at SCHEDULE time, so without this exemption the very
        /// hit that was just scheduled reads as "already acknowledged" on
        /// the next refresh and the diff cancels it before it ever fires.
        pendingFireDates: [String: Date] = [:]
    ) -> [Hit] {
        // ── Pass 1: find heat-dome runs and emit one hit per run. ───────
        var domeHits: [Hit] = []
        var domeCoveredYMDs: Set<String> = []

        var runStart = 0
        var i = 0
        while i < forecast.count {
            // Advance runStart through any sub-threshold day.
            if forecast[i].highF < thresholds.heatRawHighF {
                runStart = i + 1
                i += 1
                continue
            }
            // We're inside a >=heatRawHighF run starting at runStart.
            // Walk to the end of the run.
            var j = i
            while j < forecast.count && forecast[j].highF >= thresholds.heatRawHighF {
                j += 1
            }
            let runLength = j - runStart
            if runLength >= thresholds.heatDomeMinConsecutive {
                let runFirst = forecast[runStart]
                if let hit = makeHit(
                    day: runFirst,
                    variant: .heatDomeStarting,
                    calendar: calendar,
                    homeTimeZone: homeTimeZone,
                    now: now,
                    fireBufferSeconds: fireBufferSeconds,
                    pendingFireDates: pendingFireDates
                ) {
                    domeHits.append(hit)
                    // Mark every day in this run as dome-covered so the
                    // extreme path doesn't double-emit on the same day.
                    for k in runStart..<j {
                        domeCoveredYMDs.insert(
                            Identifier.isoDay(forecast[k].date, in: homeTimeZone)
                        )
                    }
                }
            }
            i = j
            runStart = j
        }

        // ── Pass 2: extreme apparent-temp days NOT already covered. ─────
        var extremeHits: [Hit] = []
        for day in forecast {
            guard day.apparentHighF >= thresholds.heatApparentHighF else { continue }
            let ymd = Identifier.isoDay(day.date, in: homeTimeZone)
            if domeCoveredYMDs.contains(ymd) { continue }
            if let hit = makeHit(
                day: day,
                variant: .extreme,
                calendar: calendar,
                homeTimeZone: homeTimeZone,
                now: now,
                fireBufferSeconds: fireBufferSeconds,
                pendingFireDates: pendingFireDates
            ) {
                extremeHits.append(hit)
            }
        }

        // ── Merge + sort chronologically by heatDate. ───────────────────
        var hits = (domeHits + extremeHits).sorted { $0.heatDate < $1.heatDate }

        // ── First-of-season override: if no recent heat event, the FIRST
        //    chronologically-emitted hit becomes `.firstOfSeason`. ───────
        let firstOfSeasonEligible: Bool
        if let last = lastHeatEventDate {
            firstOfSeasonEligible = now.timeIntervalSince(last) > 30 * 86_400
        } else {
            firstOfSeasonEligible = true
        }
        if firstOfSeasonEligible, let first = hits.first {
            hits[0] = Hit(
                heatDate: first.heatDate,
                fireDate: first.fireDate,
                highF: first.highF,
                apparentHighF: first.apparentHighF,
                variant: .firstOfSeason,
                identifier: first.identifier
            )
        }

        // ── Heat-dome dedup: drop a dome-variant hit that fires within 7d
        //    AFTER the last dome fire. (Applies only to dome-variant hits.)
        //    Two deliberate choices:
        //      1. A hit whose notification is still pending is exempt —
        //         it IS the recorded fire (recorded at schedule time);
        //         dropping it would cancel the warning before delivery.
        //      2. Compare fire dates to fire dates. The previous
        //         `abs(heatDate − lastDome)` conflated the hot day's
        //         midnight with a 7pm fire time across two date domains. ─
        if let lastDome = lastHeatDomeFireDate {
            hits.removeAll { hit in
                guard hit.variant == .heatDomeStarting || hit.variant == .firstOfSeason else {
                    return false
                }
                if pendingFireDates[hit.identifier] != nil { return false }
                let delta = hit.fireDate.timeIntervalSince(lastDome)
                return delta >= 0 && delta < 7 * 86_400
            }
        }

        return hits
    }

    /// Build a single `Hit` for the supplied hot day. Returns nil if the
    /// heat day has already begun (and nothing is pending) or any calendar
    /// math fails (DST-skipped 7pm hour, end-of-calendar overflow).
    private static func makeHit(
        day: DailyWeather,
        variant: Variant,
        calendar: Calendar,
        homeTimeZone: TimeZone,
        now: Date,
        fireBufferSeconds: TimeInterval,
        pendingFireDates: [String: Date]
    ) -> Hit? {
        guard let priorDay = calendar.date(byAdding: .day, value: -1, to: day.date) else {
            return nil
        }
        guard var fireDate = calendar.date(
            bySettingHour: 19,
            minute: 0,
            second: 0,
            of: priorDay,
            matchingPolicy: .nextTime,
            repeatedTimePolicy: .first,
            direction: .forward
        ) else {
            return nil
        }

        let identifier = WeatherWarningIdPrefix.heat
            + Identifier.isoDay(day.date, in: homeTimeZone)

        // Canonical 7pm-evening-before already passed (or inside the
        // 15-min buffer): keep a still-pending warning's fire date so a
        // pre-fire refresh doesn't cancel it; otherwise deliver ASAP when
        // the hot day is still ahead (first forecast after 7pm); drop it
        // once the hot day has begun.
        if fireDate <= now.addingTimeInterval(fireBufferSeconds) {
            if let pendingFire = pendingFireDates[identifier] {
                fireDate = pendingFire
            } else if day.date > now {
                fireDate = now.addingTimeInterval(fireBufferSeconds)
            } else {
                return nil
            }
        }

        return Hit(
            heatDate: day.date,
            fireDate: fireDate,
            highF: day.highF,
            apparentHighF: day.apparentHighF,
            variant: variant,
            identifier: identifier
        )
    }
}

// MARK: - Water

/// Five-stage gate. ALL must pass for the evaluator to emit `.notify(...)`:
/// 1. History sufficiency (have ≥ 3 distinct observed YMDs in the past window)
/// 2. Past cumulative rain < 12 mm
/// 3. Past warmth: avg high ≥ 75°F (a coarse ET proxy)
/// 4. No soaking rain in the 3-day forecast
/// 5. Dedup window: 7d minimum, 10d pivots copy to `.extended`
enum WaterEvaluator {

    /// Drives which copy variant fires.
    enum FireReason: Sendable, Equatable {
        case dryStretchStarting
        case dryStretchContinuing
        case dryStretchExtended
    }

    enum Decision: Sendable, Equatable {
        case notify(fireDate: Date, identifier: String, reason: FireReason)
        case skip(SkipReason)
    }

    static func evaluate(
        forecast: [DailyWeather],
        past: PastObservations,
        thresholds: WarningThresholds,
        /// Server-coordinated household state. `nil` falls back to local.
        householdLastWaterAt: Date?,
        /// Local offline fallback. Used iff `householdLastWaterAt` is nil.
        lastLocalFireDate: Date?,
        now: Date,
        calendar: Calendar,
        homeTimeZone: TimeZone,
        fireBufferSeconds: TimeInterval = 15 * 60,
        /// Fire dates of OUR still-pending notification requests, keyed by
        /// identifier. A FUTURE ledger timestamp matching a pending request
        /// is this household's own scheduled-but-not-yet-fired reminder —
        /// it must not dedup-suppress (and thereby cancel) itself.
        pendingFireDates: [String: Date] = [:]
    ) -> Decision {
        // ── Build the past-N-days YMD set anchored at YESTERDAY. ────────
        // Step 1 (history sufficiency) checks a slightly wider window
        // (`dryStretchPastDays + 1` = 6 days) than steps 2 & 3, which only
        // consider the past 5 days proper. Spec §5 Water step 1.
        guard let yesterday = calendar.date(byAdding: .day, value: -1, to: now) else {
            return .skip(.insufficientHistory(have: 0, need: thresholds.waterMinObservedHistoryDays))
        }

        var historyYMDs: [String] = []
        for offset in 0..<(thresholds.dryStretchPastDays + 1) {
            guard let d = calendar.date(byAdding: .day, value: -offset, to: yesterday) else {
                continue
            }
            historyYMDs.append(Identifier.isoDay(d, in: homeTimeZone))
        }
        var pastYMDs: [String] = []
        for offset in 0..<thresholds.dryStretchPastDays {
            guard let d = calendar.date(byAdding: .day, value: -offset, to: yesterday) else {
                continue
            }
            pastYMDs.append(Identifier.isoDay(d, in: homeTimeZone))
        }

        // 1) ── History sufficiency. ────────────────────────────────────
        let historyObserved = historyYMDs.compactMap { past.byYMD[$0] }
        if historyObserved.count < thresholds.waterMinObservedHistoryDays {
            return .skip(.insufficientHistory(
                have: historyObserved.count,
                need: thresholds.waterMinObservedHistoryDays
            ))
        }

        // Steps 2 & 3 consume the past-5-days window specifically.
        let observed = pastYMDs.compactMap { past.byYMD[$0] }

        // 2) ── Past cumulative rain check. ─────────────────────────────
        let pastRainSum = observed.reduce(0.0) { $0 + $1.rainMM }
        if pastRainSum >= thresholds.rainCumulativeMinMM {
            return .skip(.rainedRecentlyCumulative(mm: pastRainSum))
        }

        // 3) ── Past warmth / drying check. ─────────────────────────────
        // Guard against an empty `observed` window (history-sufficiency
        // passed on the 6-day window but the 5-day window has zero hits).
        guard !observed.isEmpty else {
            return .skip(.insufficientHistory(
                have: 0,
                need: thresholds.waterMinObservedHistoryDays
            ))
        }
        let pastHighsSum = observed.reduce(0.0) { $0 + $1.highF }
        let avgHigh = pastHighsSum / Double(observed.count)
        if avgHigh < thresholds.dryingScoreMinDailyHighF {
            return .skip(.coolDryNotEnoughET)
        }

        // 4) ── Forecast soaking-rain check. ────────────────────────────
        let window = Array(forecast.prefix(thresholds.dryStretchForecastDays))
        var cumulativeForecastRain = 0.0
        for (idx, day) in window.enumerated() {
            cumulativeForecastRain += day.rainMM
            if day.rainMM >= thresholds.rainSignificantMM
                || cumulativeForecastRain >= thresholds.rainCumulativeMinMM
            {
                return .skip(.rainExpectedSoon(daysAhead: idx))
            }
        }

        // 5) ── Dedup + variant selection. ──────────────────────────────
        // The ledger stores scheduledFor at SCHEDULE time, so a future
        // timestamp that matches one of our pending requests is just our
        // own not-yet-fired reminder — treating it as a prior fire would
        // dedup-skip, drop the warning from `planned`, and cancel the
        // pending notification before it ever delivers.
        var effectiveLastWaterAt = householdLastWaterAt ?? lastLocalFireDate
        if let last = effectiveLastWaterAt, last > now {
            let matchesPending = pendingFireDates.contains { id, fire in
                id.hasPrefix(WeatherWarningIdPrefix.water)
                    && abs(fire.timeIntervalSince(last)) < 60
            }
            if matchesPending {
                effectiveLastWaterAt = nil
            }
        }
        let reason: FireReason
        if let last = effectiveLastWaterAt {
            let elapsed = now.timeIntervalSince(last)
            if elapsed < thresholds.waterDedupSeconds {
                return .skip(.dedupWindow(secondsSinceLast: elapsed))
            } else if elapsed >= thresholds.waterExtendedAfterSeconds {
                reason = .dryStretchExtended
            } else {
                reason = .dryStretchContinuing
            }
        } else {
            reason = .dryStretchStarting
        }

        // ── Fire at 8am today (home-TZ). If 8am has already passed,
        //    advance to tomorrow. ─────────────────────────────────────────
        let startOfToday = calendar.startOfDay(for: now)
        guard var fireDate = calendar.date(
            bySettingHour: 8,
            minute: 0,
            second: 0,
            of: startOfToday,
            matchingPolicy: .nextTime,
            repeatedTimePolicy: .first,
            direction: .forward
        ) else {
            return .skip(.noTriggersInForecast)
        }
        if fireDate <= now.addingTimeInterval(fireBufferSeconds) {
            // A refresh inside the pre-fire buffer (e.g. 7:50am for an
            // 8:00am reminder) must keep today's still-pending request
            // rather than advancing to tomorrow — the identifier change
            // would cancel it minutes before delivery.
            let todayIdentifier = WeatherWarningIdPrefix.water
                + Identifier.isoDay(fireDate, in: homeTimeZone)
            if pendingFireDates[todayIdentifier] != nil {
                return .notify(
                    fireDate: fireDate,
                    identifier: todayIdentifier,
                    reason: reason
                )
            }
            guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: startOfToday) else {
                return .skip(.noTriggersInForecast)
            }
            guard let adv = calendar.date(
                bySettingHour: 8,
                minute: 0,
                second: 0,
                of: tomorrow,
                matchingPolicy: .nextTime,
                repeatedTimePolicy: .first,
                direction: .forward
            ) else {
                return .skip(.noTriggersInForecast)
            }
            fireDate = adv
        }

        let identifier = WeatherWarningIdPrefix.water
            + Identifier.isoDay(fireDate, in: homeTimeZone)

        return .notify(fireDate: fireDate, identifier: identifier, reason: reason)
    }
}

// MARK: - Identifier prefixes (shared with WeatherWarningsService)

/// Notification-identifier prefixes. Declared here so the pure evaluators
/// don't need to import the (not-yet-written) `WeatherWarningsService`
/// just to spell their own ids. `WeatherWarningsService.IdPrefix` will
/// alias to these in the orchestrator phase.
///
/// **`frost` is preserved CHAR-FOR-CHAR from the shipped string** so
/// pending notifications on TestFlight build 39 survive the build 40
/// upgrade.
enum WeatherWarningIdPrefix {
    static let frost = "seedkeep.notif.frost."
    static let heat  = "seedkeep.notif.heat."
    static let water = "seedkeep.notif.water."
}
