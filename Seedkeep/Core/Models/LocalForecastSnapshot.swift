import Foundation
import SwiftData

/// Singleton `@Model` row that backs `WeatherWarningsService`'s persistent
/// state. There is exactly ONE instance per device, keyed `id == "current"`
/// — the service does fetch-or-create on each refresh. Phase 4C scopes
/// this strictly to the iOS device; the row is **never** synced over
/// CloudKit or the Seedkeep server.
///
/// Compound fields (`forecast`, `observed`) are JSON-encoded strings
/// rather than `@Relationship` arrays — SwiftData's predicate macro caps
/// at 3 ANDs and we don't need to query inside these blobs. The mapping
/// follows the precedent set by `LocalRecommendation.dailyScoresJSON`.
///
/// All `Date` fields persisted as Date (SwiftData natively supports
/// `Date?`). `lastAuthStatusRaw` mirrors `UNAuthorizationStatus.rawValue`
/// (`Int`) so we don't have to import `UserNotifications` from this
/// pure-model file.
///
/// Spec: `.docs/ai/specs/2026-06-07-phase-4c-native-warnings-design.md`
/// §3 (file layout) and §6.s (persist snapshot).
@Model
public final class LocalForecastSnapshot {
    /// Singleton key. Always `"current"`. Enforced by `@Attribute(.unique)`.
    @Attribute(.unique) public var id: String

    /// JSON-encoded `[DailyWeather]`. Empty string = none cached.
    public var forecastJSON: String

    /// JSON-encoded `[ObservedDay]`. Empty string = none cached.
    public var observedJSON: String

    /// Last successfully-scheduled water-notification fireDate, used as
    /// the **offline** fallback when the server-coordinated household
    /// ledger is unreachable. Set ONLY after the post-add pending re-read
    /// confirms the notif landed.
    public var lastWaterFireDate: Date?

    /// Last time a heat-dome variant warning fired. Drives the 7-day
    /// dedup so a single 11-day dome only pings once.
    public var lastHeatDomeFireDate: Date?

    /// Last time **any** heat warning fired (dome OR extreme OR
    /// first-of-season). Drives the 30-day first-of-season gap.
    public var lastHeatEventDate: Date?

    /// Most recent observed `UNAuthorizationStatus.rawValue` from the
    /// scheduler. Used to detect a permission re-grant during a
    /// `.foreground` refresh and bypass the 2h staleness gate.
    public var lastAuthStatusRaw: Int?

    /// `TimeZone.current.identifier` at the time of last refresh. A
    /// mismatch on cold-launch forces a TZ-change refresh.
    public var sawTimeZoneIdentifier: String?

    /// `clock.now` at the time of last refresh — for clock-skew
    /// detection (>14d forward OR >24h backward).
    public var sawClockAt: Date?

    /// Generation counter bumped by `invalidateLocation()`. The provider
    /// uses it to drop a stale cache after a home-location change.
    public var coordGeneration: Int

    /// Persisted last-refresh outcome, encoded as a JSON-friendly string.
    /// Settings reads via the `@Observable Projection`; this field is
    /// purely for restoring state across launches.
    public var outcomeRaw: String?

    public init(
        id: String = "current",
        forecastJSON: String = "",
        observedJSON: String = "",
        lastWaterFireDate: Date? = nil,
        lastHeatDomeFireDate: Date? = nil,
        lastHeatEventDate: Date? = nil,
        lastAuthStatusRaw: Int? = nil,
        sawTimeZoneIdentifier: String? = nil,
        sawClockAt: Date? = nil,
        coordGeneration: Int = 0,
        outcomeRaw: String? = nil
    ) {
        self.id = id
        self.forecastJSON = forecastJSON
        self.observedJSON = observedJSON
        self.lastWaterFireDate = lastWaterFireDate
        self.lastHeatDomeFireDate = lastHeatDomeFireDate
        self.lastHeatEventDate = lastHeatEventDate
        self.lastAuthStatusRaw = lastAuthStatusRaw
        self.sawTimeZoneIdentifier = sawTimeZoneIdentifier
        self.sawClockAt = sawClockAt
        self.coordGeneration = coordGeneration
        self.outcomeRaw = outcomeRaw
    }
}
