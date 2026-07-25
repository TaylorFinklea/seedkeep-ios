#if canImport(CloudKit)
import Foundation

/// The CKSyncEngine generation currently authorized to talk to CloudKit, together with the
/// per-generation "zone save is staged" bit.
///
/// Both are PRIVATE to this holder and reachable only from inside its lock, so there is no stored
/// property left for a CKSyncEngine delegate task to read while an account event replaces it — the
/// structural half of `HouseholdSyncEngine`'s `@unchecked Sendable` justification. An account event
/// retires the live generation and fences every later body until the coordinator finishes the
/// replacement account's cleanup and calls `reactivate()`; a projection rollback swaps the
/// generation WITHOUT retiring, since the account is unchanged.
///
/// Generic over the engine type only so the invariant can be exercised off-device (a live
/// `CKSyncEngine` needs a real container); production instantiates it with `CKSyncEngine`.
/// No lock is held across an `await`: every body is synchronous.
final class EngineGeneration<Engine: AnyObject>: @unchecked Sendable {
    private let lock = NSLock()
    private var live: Engine
    private var zoneStaged = false
    private var active = true

    init(_ engine: Engine) {
        self.live = engine
    }

    /// Run `body` against the live generation and its `zoneStaged` bit. Returns nil — without running
    /// `body` — once an account event retired the generation.
    @discardableResult
    func withLive<T>(_ body: (Engine, inout Bool) -> T) -> T? {
        lock.lock()
        defer { lock.unlock() }
        guard active else { return nil }
        return body(live, &zoneStaged)
    }

    /// Run `body` only while `engine` IS the live generation — the guard every delegate callback
    /// needs, so an event from a replaced engine is inert.
    @discardableResult
    func withCurrent<T>(_ engine: Engine, _ body: (Engine) -> T) -> T? {
        lock.lock()
        defer { lock.unlock() }
        guard active, engine === live else { return nil }
        return body(live)
    }

    func isCurrent(_ engine: Engine) -> Bool {
        withCurrent(engine) { _ in true } ?? false
    }

    /// The live generation, or nil once retired.
    func current() -> Engine? {
        lock.lock()
        defer { lock.unlock() }
        return active ? live : nil
    }

    /// Swap in a replacement generation. `drain` runs against the outgoing engine while the lock is
    /// held, so no other body can observe the half-retired state. `retire: true` additionally fences
    /// every later body until `reactivate()`.
    ///
    /// `zoneStaged` always resets: the replacement carries no staged `.saveZone`, so the next save
    /// must re-stage one. Returns false when the holder is already retired, or when `origin` is not
    /// the live generation (a late event from a replaced engine must not retire its successor).
    @discardableResult
    func replaceLive(
        origin: Engine?,
        retire: Bool,
        drain: (Engine) -> Void,
        make: () -> Engine
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard active, origin == nil || origin === live else { return false }
        drain(live)
        live = make()
        zoneStaged = false
        if retire { active = false }
        return true
    }

    /// Re-enable work after the replacement account's cleanup completed.
    func reactivate() {
        lock.lock()
        active = true
        lock.unlock()
    }
}
#endif
