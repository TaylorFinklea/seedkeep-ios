import Foundation
import Synchronization
import SeedkeepKit

/// Phase 4C — household-scoped server ledger for the watering reminder.
///
/// Watering reminders dedupe across devices via a server timestamp
/// (frost + heat stay per-device because the date-anchored identifier
/// is the same across devices anyway). The server holds
/// `households.last_watering_notification_at` and treats POSTs with
/// `GREATEST(existing, scheduled_for)` so concurrent device POSTs are
/// monotonically merged.
///
/// Network errors return `.failure` — callers fall back to the local
/// `LocalForecastSnapshot.lastWaterFireDate` so the user still gets a
/// notification offline, accepting the cross-device redundancy.
protocol WateringStateClient: Sendable {
    /// Returns the server-authoritative last-scheduled timestamp for
    /// this household, or `nil` if no watering notification has ever
    /// been scheduled. `.failure` on network error.
    func get(householdID: String) async -> Result<Date?, Error>

    /// Records a scheduled watering notification. Idempotent — POSTing
    /// an earlier timestamp than the server already has is a no-op
    /// (server applies `GREATEST`). The returned value is the
    /// post-update timestamp (which may be later than `scheduledFor`
    /// if another device already POSTed a further-out fire). `.failure`
    /// on network error; the local scheduling proceeds regardless.
    func put(householdID: String, scheduledFor: Date) async -> Result<Date?, Error>
}

/// Production impl. Thin adapter over `SeedkeepClient`'s
/// `getWateringState` / `putWateringState` methods (added to
/// `SeedkeepKit` as part of the Phase 4C server piece). Translates
/// `throws` into `Result.failure` so the actor-isolated service can
/// `switch` on the outcome without an extra `do/catch` wrapper.
struct SystemWateringStateClient: WateringStateClient {

    private let client: SeedkeepClient

    init(client: SeedkeepClient) {
        self.client = client
    }

    func get(householdID: String) async -> Result<Date?, Error> {
        do {
            let dto = try await client.getWateringState(householdID: householdID)
            return .success(dto.lastWateringNotificationAt)
        } catch {
            return .failure(error)
        }
    }

    func put(
        householdID: String,
        scheduledFor: Date
    ) async -> Result<Date?, Error> {
        do {
            let dto = try await client.putWateringState(
                householdID: householdID,
                scheduledFor: scheduledFor
            )
            return .success(dto.lastWateringNotificationAt)
        } catch {
            return .failure(error)
        }
    }
}

/// Device-local watering reminder history used while the Seedkeep server is retired.
/// Each garden keeps an independent monotonic timestamp in UserDefaults.
struct LocalWateringStateClient: WateringStateClient {
    private let store: WateringStateDefaults

    init(defaults: UserDefaults = .standard) {
        self.store = WateringStateDefaults(defaults: defaults)
    }

    func get(householdID: String) async -> Result<Date?, Error> {
        .success(store.get(householdID: householdID))
    }

    func put(householdID: String, scheduledFor: Date) async -> Result<Date?, Error> {
        .success(store.put(householdID: householdID, scheduledFor: scheduledFor))
    }
}

/// UserDefaults access is serialized so concurrent weather refreshes cannot
/// overwrite a later watering timestamp with an earlier one.
private final class WateringStateDefaults: @unchecked Sendable {
    private let defaults: UserDefaults
    private static let lock = Mutex(())
    private static let keyPrefix = "seedkeep.watering.lastFire."

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    func get(householdID: String) -> Date? {
        Self.lock.withLock { _ in
            defaults.object(forKey: Self.keyPrefix + householdID) as? Date
        }
    }

    func put(householdID: String, scheduledFor: Date) -> Date {
        Self.lock.withLock { _ in
            let key = Self.keyPrefix + householdID
            let current = defaults.object(forKey: key) as? Date
            let latest = max(current ?? .distantPast, scheduledFor)
            defaults.set(latest, forKey: key)
            return latest
        }
    }
}
