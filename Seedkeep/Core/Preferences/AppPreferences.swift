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
                return "Apple Foundation Models extract packet info on-device. No network calls, no cost. Requires iOS 26+ for the AI step; older devices fall back to manual entry."
            case .byok:
                return "Same on-device flow but you can configure your own OpenAI or Anthropic API key for higher accuracy. Keys live in the device Keychain and never reach our server."
            case .hosted:
                return "Server runs Anthropic vision + reviewer for the highest accuracy. Requires a Hosted subscription via the App Store."
            }
        }
    }

    private enum Key {
        static let serverURLOverride = "seedkeep.serverURL"
        static let aiProvider = "seedkeep.aiProvider"
        static let cachedTier = "seedkeep.cachedTier"
        static let lastFrostMonth = "seedkeep.garden.lastFrostMonth"
        static let lastFrostDay = "seedkeep.garden.lastFrostDay"
        static let firstFrostMonth = "seedkeep.garden.firstFrostMonth"
        static let firstFrostDay = "seedkeep.garden.firstFrostDay"
        static let hardinessZone = "seedkeep.garden.hardinessZone"
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
        self._lastFrostMonth = defaults.object(forKey: Key.lastFrostMonth) as? Int
        self._lastFrostDay = defaults.object(forKey: Key.lastFrostDay) as? Int
        self._firstFrostMonth = defaults.object(forKey: Key.firstFrostMonth) as? Int
        self._firstFrostDay = defaults.object(forKey: Key.firstFrostDay) as? Int
        self._hardinessZone = defaults.object(forKey: Key.hardinessZone) as? Int
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

    // MARK: - Phase 2B: Garden settings

    /// Average last spring frost — stored as month + day, year-agnostic.
    /// nil means the user hasn't entered one yet; UI surfaces it as a
    /// "Set your last frost date" CTA in Garden Settings.
    private var _lastFrostMonth: Int?
    private var _lastFrostDay: Int?
    public var lastFrost: MonthDay? {
        get { MonthDay(month: _lastFrostMonth, day: _lastFrostDay) }
        set {
            _lastFrostMonth = newValue?.month
            _lastFrostDay = newValue?.day
            persistMonthDay(newValue, monthKey: Key.lastFrostMonth, dayKey: Key.lastFrostDay)
        }
    }

    /// Average first fall frost — same shape, surfaces "is this packet
    /// worth starting in late August?" guidance later.
    private var _firstFrostMonth: Int?
    private var _firstFrostDay: Int?
    public var firstFrost: MonthDay? {
        get { MonthDay(month: _firstFrostMonth, day: _firstFrostDay) }
        set {
            _firstFrostMonth = newValue?.month
            _firstFrostDay = newValue?.day
            persistMonthDay(newValue, monthKey: Key.firstFrostMonth, dayKey: Key.firstFrostDay)
        }
    }

    /// USDA hardiness zone (1–13). Used to compare against a catalog
    /// entry's hardiness_zone_min/max when surfacing perennial viability.
    private var _hardinessZone: Int?
    public var hardinessZone: Int? {
        get { _hardinessZone }
        set {
            _hardinessZone = newValue
            if let v = newValue {
                defaults.set(v, forKey: Key.hardinessZone)
            } else {
                defaults.removeObject(forKey: Key.hardinessZone)
            }
        }
    }

    private func persistMonthDay(_ value: MonthDay?, monthKey: String, dayKey: String) {
        if let value {
            defaults.set(value.month, forKey: monthKey)
            defaults.set(value.day, forKey: dayKey)
        } else {
            defaults.removeObject(forKey: monthKey)
            defaults.removeObject(forKey: dayKey)
        }
    }
}

/// Year-agnostic month+day pair. Frost dates repeat annually, so we
/// store just the calendar slot and let the UI render it against the
/// current year as needed.
public struct MonthDay: Hashable, Sendable {
    public let month: Int   // 1..12
    public let day: Int     // 1..31 (Calendar handles month-day validity at render time)

    public init?(month: Int?, day: Int?) {
        guard let m = month, let d = day,
              (1...12).contains(m), (1...31).contains(d) else { return nil }
        self.month = m
        self.day = d
    }

    public init(month: Int, day: Int) {
        self.month = month
        self.day = day
    }

    /// Build a Date in the current year (or the supplied year) for
    /// comparing against event dates that come in as full Dates.
    public func date(inYear year: Int, calendar: Calendar = .current) -> Date? {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        return calendar.date(from: components)
    }
}
