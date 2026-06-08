import Foundation

/// Every user-visible string the weather-warnings stack emits, in one
/// file. Centralising copy lets a non-engineer review tone in a single
/// diff and lets `WarningCopyTests` lock the shipped frost-body
/// byte-for-byte across the Phase-4C refactor.
enum WarningCopy {

    // MARK: - FROST  (preserved byte-for-byte from the shipped string)

    static let frostTitle = "Frost warning"

    static func frostBody(weekday: String, lowF: Int) -> String {
        "\(weekday) night drops to \(lowF)°F. Cover tender plants or pull tender seedlings inside."
    }

    // MARK: - HEAT  (three variants, evening-before fire)

    static let heatTitle = "Heat warning"

    static func heatBodyDomeStarting(weekday: String, highF: Int) -> String {
        "A run of \(highF)°F+ days starts \(weekday). Give the beds a deep evening soak so they're loaded for the morning."
    }

    static func heatBodyExtreme(weekday: String, highF: Int) -> String {
        "\(weekday) climbs to \(highF)°F. Soak the beds tonight and check transplants by mid-afternoon."
    }

    static func heatBodyFirstOfSeason(weekday: String, highF: Int) -> String {
        "First real heat of the year — \(weekday) hits \(highF)°F. Transplants aren't acclimated yet; deep evening soak tonight."
    }

    // MARK: - WATERING  (three variants)

    static let wateringTitle = "Time to water"

    static let wateringBodyDryStretchStarting =
        "No real rain the past 5 days, and the next 3 look dry. Plan a deep soak — morning or evening."

    static let wateringBodyDryStretchContinuing =
        "Still dry out there. A second deep watering will carry the beds through the week."

    static let wateringBodyDryStretchExtended =
        "It's been dry for two weeks. If you haven't set up drip irrigation yet, this is when it pays off."

    // MARK: - Settings · toggle captions

    static let frostToggleCaption = "8am the morning before any forecast low ≤ 33°F"
    static let heatToggleCaption  = "7pm the evening before a heat-index ≥ 100°F day or a 4+ day heatwave"
    static let waterToggleCaption = "8am after 5 dry days with no soaking rain in the 3-day forecast"

    // MARK: - Settings · status rows

    static let frostStatusWatching = "Watching the forecast"
    static let frostStatusEmpty    = "No frost in the next 10 days."
    static let heatStatusWatching  = "Watching for heat"
    static let heatStatusEmpty     = "Nothing dangerous in sight."
    static let waterStatusWatching = "Watching for dry stretches"
    static let waterStatusEmpty    = "No dry stretch in sight."

    // MARK: - Settings · error / state rows (one per non-success outcome)

    static let errMissingLocation    = "Set a home location first (Settings → Home location)."
    static let errNoActivePlantings  = "Nothing planted to watch over."
    static let errPermissionDenied   = "Notifications are off for Seedkeep in iOS Settings."
    static let errProvisional        = "Notifications deliver quietly — tap to allow alerts."
    static let errWeatherKitFailed   = "Couldn't reach the forecast. Tap refresh to try again."
    static let errWeatherKitUnauthorized = "Weather service unavailable for this build. Contact support."

    static func errWeatherKitStale(hours: Int) -> String {
        "Using a forecast from \(hours)h ago — couldn't reach WeatherKit just now."
    }

    static func errPartialData(validDays: Int, waterSuppressed: Bool) -> String {
        let base = "Forecast was incomplete (\(validDays) days)."
        return waterSuppressed ? base + " Water reminder needs 3+ days — waiting for next refresh." : base
    }

    static let errClockSkew           = "Device clock changed — rebuilding warnings."
    static let errInsufficientHistory = "Water reminder collects 3 days of rain history before firing."
    static let errAllSchedulingFailed = "Couldn't schedule warnings (system busy). Tap refresh to retry."

    static func errQueueBudget(dropped: Int) -> String {
        "Watching the nearest warnings; \(dropped) further-out ones will schedule as nearer ones fire."
    }

    // MARK: - WeatherKit attribution (App Store review requirement)

    static let weatherKitAttribution = "Weather"
    static let weatherKitAttributionURL = "https://weatherkit.apple.com/legal-attribution.html"
}
