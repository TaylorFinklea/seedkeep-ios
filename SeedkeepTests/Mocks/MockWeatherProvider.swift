import Foundation
import os
@testable import Seedkeep

/// Test double for `WeatherProvider`. Each test sets `forecastFixture` /
/// `observedFixture` / `homeTimeZoneFixture` (or `fetchResultFixture` for
/// canned `.failed` / `.stale` results) and asserts on `recordedFetchCount`
/// after driving the service.
///
/// Final class + `@unchecked Sendable` + `OSAllocatedUnfairLock`-guarded
/// state. `OSAllocatedUnfairLock` (Foundation `os` module) is async-safe in
/// Swift 6 — `NSLock` is not. The service is an actor so the provider
/// crosses isolation domains; we hand-roll the synchronization rather than
/// dragging the test target through Sendable closures.
final class MockWeatherProvider: WeatherProvider, @unchecked Sendable {

    // MARK: - Internal state (lock-guarded)

    private struct State {
        var forecastFixture: [DailyWeather] = []
        var observedFixture: [ObservedDay] = []
        var homeTimeZoneFixture: TimeZone = TimeZone(identifier: "America/Chicago")!
        var fetchResultFixture: ForecastResult?
        var cachedSnapshotFixture: ForecastSnapshot?
        var fetchDelayNanoseconds: UInt64 = 0
        var recordedFetchCount: Int = 0
        var recordedBumpGenerations: [Int] = []
        var recordedFetchCalls: [FetchCall] = []
    }

    struct FetchCall: Sendable {
        let latitude: Double
        let longitude: Double
        let generation: Int
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    // MARK: - Configuration

    func setForecast(_ forecast: [DailyWeather]) {
        state.withLock { $0.forecastFixture = forecast }
    }

    func setObserved(_ observed: [ObservedDay]) {
        state.withLock { $0.observedFixture = observed }
    }

    func setHomeTimeZone(_ tz: TimeZone) {
        state.withLock { $0.homeTimeZoneFixture = tz }
    }

    func setFetchResult(_ result: ForecastResult?) {
        state.withLock { $0.fetchResultFixture = result }
    }

    func setCachedSnapshot(_ snapshot: ForecastSnapshot?) {
        state.withLock { $0.cachedSnapshotFixture = snapshot }
    }

    /// Simulate a slow WeatherKit call — `fetch` sleeps this long before
    /// returning. Used by the coalescing tests to hold a refresh in
    /// flight while a state-changing caller arrives.
    func setFetchDelay(nanoseconds: UInt64) {
        state.withLock { $0.fetchDelayNanoseconds = nanoseconds }
    }

    // MARK: - Recorded state

    var recordedFetchCount: Int {
        state.withLock { $0.recordedFetchCount }
    }

    var recordedBumpGenerations: [Int] {
        state.withLock { $0.recordedBumpGenerations }
    }

    var recordedFetchCalls: [FetchCall] {
        state.withLock { $0.recordedFetchCalls }
    }

    // MARK: - WeatherProvider

    func fetch(
        latitude: Double,
        longitude: Double,
        generation: Int
    ) async -> ForecastResult {
        let snapshot = state.withLock { (s: inout State) -> (ForecastResult?, [DailyWeather], [ObservedDay], TimeZone, UInt64) in
            s.recordedFetchCount += 1
            s.recordedFetchCalls.append(FetchCall(
                latitude: latitude,
                longitude: longitude,
                generation: generation
            ))
            return (s.fetchResultFixture, s.forecastFixture, s.observedFixture, s.homeTimeZoneFixture, s.fetchDelayNanoseconds)
        }
        if snapshot.4 > 0 {
            try? await Task.sleep(nanoseconds: snapshot.4)
        }
        if let result = snapshot.0 {
            return result
        }
        return .fresh(
            forecast: snapshot.1,
            observed: snapshot.2,
            homeTimeZone: snapshot.3,
            fetchedAt: Date()
        )
    }

    func bumpGeneration(to generation: Int) async {
        state.withLock { $0.recordedBumpGenerations.append(generation) }
    }

    func cachedSnapshot() async -> ForecastSnapshot? {
        state.withLock { $0.cachedSnapshotFixture }
    }
}
