import Testing
import Foundation
@testable import Seedkeep

/// Pin every user-visible string the weather-warnings stack emits.
///
/// **Frost body is byte-for-byte locked** — Phase 4C preserves the shipped
/// string so build-39 pending frost notifications don't get rebuilt on
/// upgrade. Any change to `frostBody` here is the regression signal.
///
/// Spec: `.docs/ai/specs/2026-06-07-phase-4c-native-warnings-design.md`
/// §4 (Copy.swift) + §11 (Layer 1 — WarningCopyTests).
@Suite("WarningCopy — Phase 4C user-visible strings")
struct WarningCopyTests {

    // MARK: - Titles

    @Test("titles match spec")
    func titles() {
        #expect(WarningCopy.frostTitle == "Frost warning")
        #expect(WarningCopy.heatTitle == "Heat warning")
        #expect(WarningCopy.wateringTitle == "Time to water")
    }

    // MARK: - Frost body — byte-for-byte lock

    @Test("frost body is preserved byte-for-byte from shipped string")
    func frostBodyByteForByte() {
        // SHIPPED build-39 string. Any character change here re-builds
        // pending frost notifications on upgrade — regression signal.
        let body = WarningCopy.frostBody(weekday: "Saturday", lowF: 30)
        #expect(body == "Saturday night drops to 30°F. Cover tender plants or pull tender seedlings inside.")
    }

    @Test("frost body weekday/lowF interpolation")
    func frostBodyInterpolation() {
        let body = WarningCopy.frostBody(weekday: "Tuesday", lowF: 27)
        #expect(body == "Tuesday night drops to 27°F. Cover tender plants or pull tender seedlings inside.")
    }

    // MARK: - Heat bodies (three variants)

    @Test("heat body — dome starting")
    func heatBodyDomeStarting() {
        let body = WarningCopy.heatBodyDomeStarting(weekday: "Saturday", highF: 96)
        #expect(body == "A run of 96°F+ days starts Saturday. Give the beds a deep evening soak so they're loaded for the morning.")
    }

    @Test("heat body — extreme")
    func heatBodyExtreme() {
        let body = WarningCopy.heatBodyExtreme(weekday: "Saturday", highF: 103)
        #expect(body == "Saturday climbs to 103°F. Soak the beds tonight and check transplants by mid-afternoon.")
    }

    @Test("heat body — first-of-season")
    func heatBodyFirstOfSeason() {
        let body = WarningCopy.heatBodyFirstOfSeason(weekday: "Friday", highF: 95)
        #expect(body == "First real heat of the year — Friday hits 95°F. Transplants aren't acclimated yet; deep evening soak tonight.")
    }

    // MARK: - Watering bodies (three variants)

    @Test("watering body — dry stretch starting")
    func wateringStarting() {
        #expect(WarningCopy.wateringBodyDryStretchStarting == "No real rain the past 5 days, and the next 3 look dry. Plan a deep soak — morning or evening.")
    }

    @Test("watering body — dry stretch continuing")
    func wateringContinuing() {
        #expect(WarningCopy.wateringBodyDryStretchContinuing == "Still dry out there. A second deep watering will carry the beds through the week.")
    }

    @Test("watering body — dry stretch extended")
    func wateringExtended() {
        #expect(WarningCopy.wateringBodyDryStretchExtended == "It's been dry for two weeks. If you haven't set up drip irrigation yet, this is when it pays off.")
    }

    // MARK: - Toggle captions

    @Test("toggle captions match spec")
    func toggleCaptions() {
        #expect(WarningCopy.frostToggleCaption == "8am the morning before any forecast low ≤ 33°F")
        #expect(WarningCopy.heatToggleCaption == "7pm the evening before a heat-index ≥ 100°F day or a 4+ day heatwave")
        #expect(WarningCopy.waterToggleCaption == "8am after 5 dry days with no soaking rain in the 3-day forecast")
    }

    // MARK: - Settings status rows

    @Test("status rows — watching")
    func statusRowsWatching() {
        #expect(WarningCopy.frostStatusWatching == "Watching the forecast")
        #expect(WarningCopy.heatStatusWatching == "Watching for heat")
        #expect(WarningCopy.waterStatusWatching == "Watching for dry stretches")
    }

    @Test("status rows — empty")
    func statusRowsEmpty() {
        #expect(WarningCopy.frostStatusEmpty == "No frost in the next 10 days.")
        #expect(WarningCopy.heatStatusEmpty == "Nothing dangerous in sight.")
        #expect(WarningCopy.waterStatusEmpty == "No dry stretch in sight.")
    }

    // MARK: - Error rows

    @Test("error row — missing location")
    func errMissingLocation() {
        #expect(WarningCopy.errMissingLocation == "Set a home location first (Settings → Home location).")
    }

    @Test("error row — no active plantings")
    func errNoActivePlantings() {
        #expect(WarningCopy.errNoActivePlantings == "Nothing planted to watch over.")
    }

    @Test("error row — permission denied")
    func errPermissionDenied() {
        #expect(WarningCopy.errPermissionDenied == "Notifications are off for Seedkeep in iOS Settings.")
    }

    @Test("error row — provisional")
    func errProvisional() {
        #expect(WarningCopy.errProvisional == "Notifications deliver quietly — tap to allow alerts.")
    }

    @Test("error row — weather-kit failed")
    func errWeatherKitFailed() {
        #expect(WarningCopy.errWeatherKitFailed == "Couldn't reach the forecast. Tap refresh to try again.")
    }

    @Test("error row — weather-kit unauthorized")
    func errWeatherKitUnauthorized() {
        #expect(WarningCopy.errWeatherKitUnauthorized == "Weather service unavailable for this build. Contact support.")
    }

    @Test("error row — weather-kit stale")
    func errWeatherKitStale() {
        #expect(WarningCopy.errWeatherKitStale(hours: 8) == "Using a forecast from 8h ago — couldn't reach WeatherKit just now.")
    }

    @Test("error row — partial data (water suppressed)")
    func errPartialDataWaterSuppressed() {
        let s = WarningCopy.errPartialData(validDays: 2, waterSuppressed: true)
        #expect(s == "Forecast was incomplete (2 days). Water reminder needs 3+ days — waiting for next refresh.")
    }

    @Test("error row — partial data (no water suppression)")
    func errPartialDataNoSuppression() {
        let s = WarningCopy.errPartialData(validDays: 2, waterSuppressed: false)
        #expect(s == "Forecast was incomplete (2 days).")
    }

    @Test("error row — clock skew")
    func errClockSkew() {
        #expect(WarningCopy.errClockSkew == "Device clock changed — rebuilding warnings.")
    }

    @Test("error row — insufficient history")
    func errInsufficientHistory() {
        #expect(WarningCopy.errInsufficientHistory == "Water reminder collects 3 days of rain history before firing.")
    }

    @Test("error row — all scheduling failed")
    func errAllSchedulingFailed() {
        #expect(WarningCopy.errAllSchedulingFailed == "Couldn't schedule warnings (system busy). Tap refresh to retry.")
    }

    @Test("error row — queue budget")
    func errQueueBudget() {
        #expect(WarningCopy.errQueueBudget(dropped: 4) == "Watching the nearest warnings; 4 further-out ones will schedule as nearer ones fire.")
    }

    // MARK: - WeatherKit attribution

    @Test("WeatherKit attribution")
    func weatherKitAttribution() {
        #expect(WarningCopy.weatherKitAttribution == "Weather")
        #expect(WarningCopy.weatherKitAttributionURL == "https://weatherkit.apple.com/legal-attribution.html")
    }
}
