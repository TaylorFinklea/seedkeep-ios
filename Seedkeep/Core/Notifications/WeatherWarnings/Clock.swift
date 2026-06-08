import Foundation

/// Dependency-injectable wall-clock used by the weather-warnings stack.
///
/// Production code wires `SystemClock` (reads `Date()`). Tests inject
/// `FixedClock(now:)` so deterministic time-travel scenarios — DST cuts,
/// dedup-window boundaries, clock-skew detection — don't depend on the
/// host machine's wall clock.
protocol Clock: Sendable {
    var now: Date { get }
}

struct SystemClock: Clock {
    var now: Date { Date() }
}

struct FixedClock: Clock {
    let now: Date
}
