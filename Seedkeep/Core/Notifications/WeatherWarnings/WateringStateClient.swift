import Foundation
import Synchronization

/// Phase 4C — per-garden ledger for the watering reminder, so repeated
/// weather refreshes don't schedule the same watering notification twice.
/// `LocalWateringStateClient` keeps it on this device (the server ledger
/// that deduped across devices was removed with the server in N3).
///
/// `.failure` makes callers fall back to the local
/// `LocalForecastSnapshot.lastWaterFireDate`.
protocol WateringStateClient: Sendable {
    /// Returns the last-scheduled timestamp for this household, or `nil`
    /// if no watering notification has ever been scheduled.
    func get(householdID: String) async -> Result<Date?, Error>

    /// Records a scheduled watering notification. Monotonic — recording
    /// an earlier timestamp than the stored one is a no-op. The returned
    /// value is the post-update timestamp (which may be later than
    /// `scheduledFor`). On `.failure` the local scheduling proceeds
    /// regardless.
    func put(householdID: String, scheduledFor: Date) async -> Result<Date?, Error>
}

/// Device-local watering reminder history.
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
    fileprivate static let keyPrefix = "seedkeep.watering.lastFire."

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

/// N2-E (G3): the watering ledger is per garden. A kept copy takes its old garden's timestamp with it
/// (the later of the two, as `put` is monotonic), and a discard removes it.
enum WateringLedger {
    static func move(from old: String, to new: String, in defaults: UserDefaults) {
        WateringStateDefaults.moveLedger(from: old, to: new, in: defaults)
    }

    static func remove(householdID: String, in defaults: UserDefaults) {
        WateringStateDefaults.removeLedger(householdID: householdID, in: defaults)
    }
}

extension WateringStateDefaults {
    fileprivate static func moveLedger(from old: String, to new: String, in defaults: UserDefaults) {
        lock.withLock { _ in
            let oldKey = keyPrefix + old
            let newKey = keyPrefix + new
            if let moved = defaults.object(forKey: oldKey) as? Date {
                let current = defaults.object(forKey: newKey) as? Date
                defaults.set(max(current ?? .distantPast, moved), forKey: newKey)
            }
            defaults.removeObject(forKey: oldKey)
        }
    }

    fileprivate static func removeLedger(householdID: String, in defaults: UserDefaults) {
        lock.withLock { _ in defaults.removeObject(forKey: keyPrefix + householdID) }
    }
}
