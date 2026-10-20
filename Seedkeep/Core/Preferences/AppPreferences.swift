import Foundation
import Observation

/// User-configurable preferences that survive app launches via
/// `UserDefaults`. Exposes server URL + AI provider as observable
/// properties so SwiftUI views and `AppEnvironment` can react to changes
/// without singleton wiring.
///
/// The two values are intentionally separate from `Info.plist` config:
/// the plist gives us the *default* server URL (e.g. the official cloud
/// host) and `serverURLOverride` lets users point at their own
/// self-hosted backend without rebuilding the app.
@MainActor
@Observable
public final class AppPreferences {
    /// Master switch for the Hosted (paid) tier. Flip to `true` once the
    /// App Store Connect subscription products + `APPLE_IAP_SHARED_SECRET`
    /// are configured. Off keeps the UI clean — Hosted disappears from
    /// the provider picker and the Subscription settings row hides.
    public static let isHostedTierEnabled: Bool = false

    public enum AIProvider: String, CaseIterable, Sendable, Identifiable {
        /// On-device extraction via Apple Foundation Models. The default
        /// for everyone who hasn't subscribed and hasn't pasted their own
        /// API key. Costs the server nothing.
        case free
        /// Bring-your-own-key. The user pastes an Anthropic or OpenAI key
        /// in Settings; we run extraction on-device against their key.
        case byok
        /// Server-side extraction with our key, gated by a Hosted-tier
        /// subscription via Apple IAP.
        case hosted

        public var id: String { rawValue }

        public var displayName: String {
            switch self {
            case .free: return "Free (on-device)"
            case .byok: return "BYOK (your own key)"
            case .hosted: return "Hosted (subscription)"
            }
        }

        public var helpText: String {
            switch self {
            case .free:
                return "Extraction runs on your device. Saved seeds sync through iCloud."
            case .byok:
                return "Packet photos are sent to your AI provider with your own key. Your key is stored only on this device and sent only to your AI provider."
            case .hosted:
                return "Server runs Anthropic vision + reviewer for the highest accuracy. Requires a Hosted subscription via the App Store."
            }
        }
    }

    private enum Key {
        static let serverURLOverride = "seedkeep.serverURL"
        static let aiProvider = "seedkeep.aiProvider"
        static let cachedTier = "seedkeep.cachedTier"
        static let homeZip = "seedkeep.location.homeZip"
        static let cachedUsdaZone = "seedkeep.location.usdaZone"
        static let cachedLatitude = "seedkeep.location.latitude"
        static let cachedLongitude = "seedkeep.location.longitude"
        static let avgLastFrost = "seedkeep.location.avgLastFrost"
        static let avgFirstFrost = "seedkeep.location.avgFirstFrost"
    }

    private let defaults: UserDefaults
    private let bundleDefaultURL: URL

    public init(defaults: UserDefaults = .standard, bundleDefaultURL: URL) {
        self.defaults = defaults
        self.bundleDefaultURL = bundleDefaultURL
        self._serverURLOverride = defaults.url(forKey: Key.serverURLOverride)
        let stored = defaults.string(forKey: Key.aiProvider).flatMap(AIProvider.init(rawValue:)) ?? .free
        // If a stored preference points at a tier that's currently
        // gated off, fall back to .free so ScanFlow doesn't keep
        // dispatching to a path the UI can no longer reach.
        self._aiProvider = (stored == .hosted && !Self.isHostedTierEnabled) ? .free : stored
        self._cachedTier = defaults.string(forKey: Key.cachedTier)
        self._homeZip = defaults.string(forKey: Key.homeZip)
        self._cachedUsdaZone = defaults.string(forKey: Key.cachedUsdaZone)
        self._cachedLatitude = defaults.object(forKey: Key.cachedLatitude) as? Double
        self._cachedLongitude = defaults.object(forKey: Key.cachedLongitude) as? Double
        self._avgLastFrost = defaults.string(forKey: Key.avgLastFrost)
        self._avgFirstFrost = defaults.string(forKey: Key.avgFirstFrost)
    }

    private var _serverURLOverride: URL?
    public var serverURLOverride: URL? {
        get { _serverURLOverride }
        set {
            _serverURLOverride = newValue
            if let url = newValue {
                defaults.set(url, forKey: Key.serverURLOverride)
            } else {
                defaults.removeObject(forKey: Key.serverURLOverride)
            }
        }
    }

    /// The URL the app should actually use right now: override if set,
    /// otherwise the bundle default.
    public var effectiveServerURL: URL {
        serverURLOverride ?? bundleDefaultURL
    }

    public var bundleDefault: URL { bundleDefaultURL }

    public var isUsingDefaultServer: Bool { serverURLOverride == nil }

    private var _aiProvider: AIProvider
    public var aiProvider: AIProvider {
        get { _aiProvider }
        set {
            _aiProvider = newValue
            defaults.set(newValue.rawValue, forKey: Key.aiProvider)
        }
    }

    /// The most recently observed server-reported tier. Persisted so the
    /// UI can render a useful state on cold launch before the server
    /// round-trip completes. Authoritative answer always comes from
    /// `GET /api/subscriptions/me` — this is just a cache.

    private var _cachedTier: String?
    public var cachedTier: String? {
        get { _cachedTier }
        set {
            _cachedTier = newValue
            if let v = newValue {
                defaults.set(v, forKey: Key.cachedTier)
            } else {
                defaults.removeObject(forKey: Key.cachedTier)
            }
        }
    }

    // MARK: - Phase 2C: Home location (ZIP-based)

    /// The 5-digit ZIP code the user entered for their home location.
    /// nil means the user hasn't set one yet.
    private var _homeZip: String?
    public var homeZip: String? {
        get { _homeZip }
        set {
            _homeZip = newValue
            if let v = newValue {
                defaults.set(v, forKey: Key.homeZip)
            } else {
                defaults.removeObject(forKey: Key.homeZip)
            }
        }
    }

    /// The USDA hardiness zone string resolved from `homeZip` by the bundled
    /// climate table (e.g. "7b").
    private var _cachedUsdaZone: String?
    public var cachedUsdaZone: String? {
        get { _cachedUsdaZone }
        set {
            _cachedUsdaZone = newValue
            if let v = newValue {
                defaults.set(v, forKey: Key.cachedUsdaZone)
            } else {
                defaults.removeObject(forKey: Key.cachedUsdaZone)
            }
        }
    }

    // MARK: - Cached coordinates (resolved from homeZip by the bundled climate table)

    /// Latitude of the home location, resolved from the ZIP by the bundled
    /// climate table and cached so `WeatherKitRefiner` can request a local
    /// forecast.  nil until the user has saved a ZIP at least once.
    private var _cachedLatitude: Double?
    public var cachedLatitude: Double? {
        get { _cachedLatitude }
        set {
            _cachedLatitude = newValue
            if let v = newValue {
                defaults.set(v, forKey: Key.cachedLatitude)
            } else {
                defaults.removeObject(forKey: Key.cachedLatitude)
            }
        }
    }

    /// Longitude of the home location (see `cachedLatitude`).
    private var _cachedLongitude: Double?
    public var cachedLongitude: Double? {
        get { _cachedLongitude }
        set {
            _cachedLongitude = newValue
            if let v = newValue {
                defaults.set(v, forKey: Key.cachedLongitude)
            } else {
                defaults.removeObject(forKey: Key.cachedLongitude)
            }
        }
    }

    // MARK: - Cached frost dates (resolved from homeZip by the bundled climate table)

    /// Average last spring frost for the home location, "MM-DD". nil until a
    /// ZIP is saved, or for a ZIP saved before frost dates were cached.
    private var _avgLastFrost: String?
    public var avgLastFrost: String? {
        get { _avgLastFrost }
        set {
            _avgLastFrost = newValue
            if let v = newValue {
                defaults.set(v, forKey: Key.avgLastFrost)
            } else {
                defaults.removeObject(forKey: Key.avgLastFrost)
            }
        }
    }

    /// Average first autumn frost for the home location, "MM-DD" (see `avgLastFrost`).
    private var _avgFirstFrost: String?
    public var avgFirstFrost: String? {
        get { _avgFirstFrost }
        set {
            _avgFirstFrost = newValue
            if let v = newValue {
                defaults.set(v, forKey: Key.avgFirstFrost)
            } else {
                defaults.removeObject(forKey: Key.avgFirstFrost)
            }
        }
    }

    /// The home climate built from the cached location fields, or nil while any of them is missing.
    var homeClimate: HomeClimate? {
        guard let zip = homeZip,
              let zone = cachedUsdaZone,
              let latitude = cachedLatitude,
              let longitude = cachedLongitude,
              let lastFrost = avgLastFrost,
              let firstFrost = avgFirstFrost else { return nil }
        return HomeClimate(
            zip: zip,
            latitude: latitude,
            longitude: longitude,
            usdaZone: zone,
            avgLastFrost: lastFrost,
            avgFirstFrost: firstFrost
        )
    }

    /// Caches every home-location field from a climate lookup.
    func saveHomeClimate(_ climate: HomeClimate) {
        homeZip = climate.zip
        cachedUsdaZone = climate.usdaZone
        cachedLatitude = climate.latitude
        cachedLongitude = climate.longitude
        avgLastFrost = climate.avgLastFrost
        avgFirstFrost = climate.avgFirstFrost
    }

    /// Fills the frost dates of a saved ZIP that predates them. The ZIP is unchanged, so the cached
    /// coordinates stay as they are. The table lookup runs off the main actor.
    func backfillFrostDates() async {
        guard let zip = homeZip, avgLastFrost == nil || avgFirstFrost == nil else { return }
        let climate = await Task.detached { ClimateLookup.climate(forZip: zip) }.value
        // The ZIP may have changed while the lookup ran; only fill the ZIP that was asked for.
        guard let climate, homeZip == zip else { return }
        avgLastFrost = climate.avgLastFrost
        avgFirstFrost = climate.avgFirstFrost
    }
}
