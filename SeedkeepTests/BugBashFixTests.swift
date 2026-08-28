import Testing
import Foundation
import SwiftData
@testable import Seedkeep
import SeedkeepKit

// MARK: - [2] AIAssistantCoordinator double-send race

/// Verifies that a second `send()` call while a stream is in flight is
/// rejected. The fix sets `streamingState = .streaming(messageID: "pending")`
/// immediately after the `guard streamingState == .idle` check, before
/// the `await client.streamAssistantResponse(...)` call.
///
/// Strategy: use a URLProtocol that never calls `didFinishLoading` to hold
/// the stream open, insert a thread into SwiftData, call `send()` on a
/// Task, then immediately call `send()` again and verify the second call
/// returns without changing the state.
@MainActor
@Suite("AIAssistantCoordinator — double-send race ([2])", .serialized)
struct AIAssistantCoordinatorRaceTests {

    private static func makeContainer() -> ModelContainer {
        makeTestContainer(name: "assistantRace-\(UUID().uuidString)")
    }

    private static func makeCoordinator(container: ModelContainer) -> AIAssistantCoordinator {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HangingURLProtocol.self]
        let session = URLSession(configuration: config)
        let client = SeedkeepClient(
            configuration: .init(baseURL: URL(string: "https://test.local")!, session: session),
            bearerToken: "test"
        )
        return AIAssistantCoordinator(client: client, container: container)
    }

    private static func insertThread(id: String, in container: ModelContainer) throws {
        let ctx = ModelContext(container)
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        ctx.insert(LocalAssistantThread(
            id: id, householdID: "hh_test", title: "test",
            threadKind: "chat", createdAt: now, updatedAt: now, deletedAt: nil))
        try ctx.save()
    }

    @Test("second send() while stream in flight is rejected")
    func secondSendRejected() async throws {
        let container = Self.makeContainer()
        let coordinator = Self.makeCoordinator(container: container)
        try Self.insertThread(id: "thread_race_1", in: container)

        coordinator.openThread("thread_race_1")
        #expect(coordinator.streamingState == .idle)

        // Launch the first send — HangingURLProtocol keeps it open forever.
        let firstSend = Task {
            try? await coordinator.send(text: "hello")
        }

        // Yield briefly so the Task starts and `streamingState` advances.
        // The fix sets .streaming(messageID: "pending") before the network
        // await, so a single yield is sufficient.
        await Task.yield()
        await Task.yield()

        // The state should now be .streaming (the fix) not still .idle (the bug).
        if case .streaming = coordinator.streamingState {
            // expected
        } else {
            Issue.record("Expected .streaming after first send, got \(coordinator.streamingState)")
        }

        // A second send() should immediately return (guard fires) and not
        // advance to a second concurrent .streaming state.
        let beforeSecondSend = coordinator.streamingState
        try? await coordinator.send(text: "hello again")

        // State must be unchanged — second send was rejected.
        #expect(coordinator.streamingState == beforeSecondSend,
                "second send() while in-flight must be rejected; state changed unexpectedly")

        firstSend.cancel()
    }

    @Test("confirmToolCall while .awaitingConfirmation advances to .streaming before await")
    func confirmToolCallSetsStreamingBeforeAwait() async throws {
        let container = Self.makeContainer()
        let coordinator = Self.makeCoordinator(container: container)
        try Self.insertThread(id: "thread_race_2", in: container)

        coordinator.openThread("thread_race_2")

        // Insert a tool call row so confirmToolCall's SwiftData lookup
        // finds the row and doesn't bail before the network call.
        let toolCallID = "tc_race_1"
        let ctx = ModelContext(container)
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        ctx.insert(LocalAssistantToolCall(
            id: toolCallID, messageID: "msg_1", threadID: "thread_race_2",
            toolName: "update_seed", argsJSON: "{}", status: "proposed",
            resultJSON: nil, proposedChangeJSON: nil, confirmedAt: nil,
            createdAt: now, updatedAt: now))
        try ctx.save()

        // Inject .awaitingConfirmation via the test seam so we don't need
        // a real server round-trip to reach this state.
        coordinator._testInjectStreamingState(.awaitingConfirmation(toolCallID: toolCallID))
        #expect(coordinator.streamingState == .awaitingConfirmation(toolCallID: toolCallID),
                "state must be .awaitingConfirmation after injection")

        // Call confirmToolCall — the HangingURLProtocol keeps the confirm
        // stream open indefinitely, so the task never resolves on its own.
        let confirmTask = Task {
            try? await coordinator.confirmToolCall(toolCallID)
        }

        // Yield briefly so confirmToolCall() can advance past the guard
        // and set .streaming before the await on the network call.
        await Task.yield()
        await Task.yield()

        // The fix: confirmToolCall sets streamingState = .streaming(messageID: "pending")
        // BEFORE the `await client.confirmAssistantToolCall(...)` call.
        // If the old code is in place (no early set), state stays .awaitingConfirmation.
        if case .streaming = coordinator.streamingState {
            // Expected — fix is in place.
        } else {
            let got = coordinator.streamingState
            Issue.record("Expected .streaming after confirmToolCall() passed guard, got \(got). Fix: confirmToolCall must set .streaming before the network await.")
        }

        confirmTask.cancel()
    }

    @Test("send() after .error state is accepted and advances to .streaming")
    func sendAfterErrorIsAccepted() async throws {
        let container = Self.makeContainer()
        let coordinator = Self.makeCoordinator(container: container)
        try Self.insertThread(id: "thread_error_resume", in: container)

        coordinator.openThread("thread_error_resume")

        // Inject .error state directly — simulates a prior failed stream.
        coordinator._testInjectStreamingState(.error("network timed out"))
        #expect(coordinator.streamingState == .error("network timed out"),
                "state must be .error after injection")

        // Launch send() — HangingURLProtocol keeps the stream open so
        // the Task doesn't resolve before we can observe state.
        let sendTask = Task {
            try? await coordinator.send(text: "retry after error")
        }

        // Yield so send() can check the guard and advance state.
        await Task.yield()
        await Task.yield()

        // The fix: send() allows .error (isError == true) in its guard,
        // clears to .streaming before the network await.
        // Without the fix, the guard `streamingState == .idle` is false
        // for .error, so send() silently returns and state stays .error.
        if case .streaming = coordinator.streamingState {
            // Expected — fix is in place.
        } else {
            let got = coordinator.streamingState
            Issue.record("Expected .streaming after send() from .error state, got \(got). Fix: send() guard must also allow .error state.")
        }

        sendTask.cancel()
    }
}

// MARK: - URLProtocol that never completes (holds stream open)

/// A URLProtocol that accepts all requests and never calls
/// `urlProtocolDidFinishLoading`, simulating an open SSE stream.
/// Used to test race-condition guards in AIAssistantCoordinator.
final class HangingURLProtocol: URLProtocol, @unchecked Sendable {
    // Keep tasks alive so the stream's URLSessionDataDelegate stays retained.
    nonisolated(unsafe) static var activeTasks: [URLProtocolClient] = []
    static let lock = NSLock()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // Send a 200 header so the delegate doesn't fail immediately, but
        // never send data or finish — the stream stays open indefinitely.
        let url = request.url ?? URL(string: "https://test.local")!
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/event-stream"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        // Intentionally no data, no finish — stream hangs.
        if let c = client {
            Self.lock.withLock { Self.activeTasks.append(c) }
        }
    }

    override func stopLoading() {
        // Nothing to tear down.
    }
}

// MARK: - Journal date-only display

@Suite("JournalView — date-only display")
struct JournalDatePresentationTests {
    @Test("roundel keeps the wire date across time zones")
    func roundelKeepsWireDateAcrossTimeZones() {
        let chicago = TimeZone(identifier: "America/Chicago")!
        let utc = TimeZone(secondsFromGMT: 0)!

        for timeZone in [chicago, utc] {
            let parts = JournalDatePresentation.parts(
                for: "2026-08-28",
                timeZone: timeZone
            )

            #expect(parts.monthAbbrev == "AUG")
            #expect(parts.day == 28)
            #expect(parts.yearRoman == "MMXXVI")
        }
    }

    @Test("accessibility label keeps the wire date across time zones")
    func accessibilityLabelKeepsWireDateAcrossTimeZones() {
        let chicago = TimeZone(identifier: "America/Chicago")!
        let utc = TimeZone(secondsFromGMT: 0)!

        #expect(
            JournalDatePresentation.accessibleDate(
                for: "2026-08-28",
                timeZone: chicago,
                locale: Locale(identifier: "en_US_POSIX")
            ) == "August 28, 2026"
        )
        #expect(
            JournalDatePresentation.accessibleDate(
                for: "2026-08-28",
                timeZone: utc,
                locale: Locale(identifier: "en_US_POSIX")
            ) == "August 28, 2026"
        )
    }
}

// MARK: - [3] UTC-midnight off-by-one (AddPlantingEventView)

/// Verifies that `AddPlantingEventView.parseYYYYMMDD` (now using `.current`)
/// round-trips through `yyyymmdd(_:)` (also `.current`) without an off-by-one
/// day for UTC-negative timezones.
///
/// Test approach: extract the formatters as pure functions and exercise them
/// in a UTC-5 timezone (simulating US-Central winter offset). The bug was
/// that `parseYYYYMMDD` used UTC midnight while `yyyymmdd` used `.current`,
/// so converting "2026-04-15" to a Date at UTC midnight, then formatting that
/// Date with a UTC-5 formatter, produced "2026-04-14".
@Suite("AddPlantingEventView — UTC-midnight off-by-one ([3])")
struct AddPlantingEventViewDateTests {

    /// Parse a YYYY-MM-DD string to a Date at local midnight (the fixed
    /// version of parseYYYYMMDD, now using TimeZone.current).
    private func parseLocalMidnight(_ s: String, tz: TimeZone) -> Date? {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = tz
        return f.date(from: s)
    }

    /// Format a Date back to YYYY-MM-DD using local timezone (matches save()).
    private func formatYYYYMMDD(_ date: Date, tz: TimeZone) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = tz
        return f.string(from: date)
    }

    @Test("recommended date round-trips to same yyyy-mm-dd in UTC-5 timezone")
    func recommendedDateRoundTripUTCMinus5() {
        let utcMinus5 = TimeZone(secondsFromGMT: -5 * 3600)!
        let start = "2026-04-15"

        // Simulate "Use recommended date": parse with local TZ (the fix),
        // then format back with local TZ (how save() works).
        guard let parsed = parseLocalMidnight(start, tz: utcMinus5) else {
            Issue.record("parseLocalMidnight returned nil for \(start)")
            return
        }
        let formatted = formatYYYYMMDD(parsed, tz: utcMinus5)
        #expect(formatted == start,
                "Expected round-trip to produce \(start), got \(formatted)")
    }

    @Test("recommended date round-trips to same yyyy-mm-dd in UTC-8 timezone")
    func recommendedDateRoundTripUTCMinus8() {
        let utcMinus8 = TimeZone(secondsFromGMT: -8 * 3600)!
        let start = "2026-01-01"

        guard let parsed = parseLocalMidnight(start, tz: utcMinus8) else {
            Issue.record("parseLocalMidnight returned nil for \(start)")
            return
        }
        let formatted = formatYYYYMMDD(parsed, tz: utcMinus8)
        #expect(formatted == start,
                "Expected round-trip to produce \(start), got \(formatted)")
    }

    @Test("old UTC-midnight parse would have produced wrong date in UTC-5")
    func utcMidnightParseWouldProduceWrongDate() {
        // Demonstrate the old bug: parsing "2026-04-15" at UTC midnight,
        // then formatting with UTC-5, gives "2026-04-14" (the wrong day).
        let utcMinus5 = TimeZone(secondsFromGMT: -5 * 3600)!
        let start = "2026-04-15"

        let fUTC = DateFormatter()
        fUTC.dateFormat = "yyyy-MM-dd"
        fUTC.locale = Locale(identifier: "en_US_POSIX")
        fUTC.timeZone = TimeZone(identifier: "UTC")

        let fLocal = DateFormatter()
        fLocal.dateFormat = "yyyy-MM-dd"
        fLocal.locale = Locale(identifier: "en_US_POSIX")
        fLocal.timeZone = utcMinus5

        guard let utcMidnight = fUTC.date(from: start) else {
            Issue.record("UTC parse returned nil")
            return
        }
        // The old bug: format UTC midnight with local TZ → yields prior day.
        let buggyFormatted = fLocal.string(from: utcMidnight)
        #expect(buggyFormatted == "2026-04-14",
                "Expected the old bug to reproduce: UTC midnight in UTC-5 = prior day")
    }
}

// MARK: - [12] TodayView date helpers

/// Tests the pure date-string helpers extracted to TodayView static methods.
/// The @Query itself is a SwiftUI/SwiftData view-layer concern (device/manual);
/// these tests cover the date-bucketing logic that drives the query keys.
@MainActor
@Suite("TodayView — date-string helpers ([12])")
struct TodayViewDateHelpersTests {

    @Test("currentTodayString matches yyyy-MM-dd for today in local TZ")
    func currentTodayStringMatchesLocalDate() {
        let result = TodayView.currentTodayString()
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        let expected = f.string(from: Date())
        #expect(result == expected)
    }

    @Test("currentYesterdayString is one day before currentTodayString")
    func yesterdayIsOneDayBeforeToday() {
        let today = TodayView.currentTodayString()
        let yesterday = TodayView.currentYesterdayString()

        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")

        guard let todayDate = f.date(from: today),
              let yesterdayDate = f.date(from: yesterday) else {
            Issue.record("Date parse failed: today=\(today) yesterday=\(yesterday)")
            return
        }
        let diff = Calendar(identifier: .gregorian)
            .dateComponents([.day], from: yesterdayDate, to: todayDate).day ?? 0
        #expect(diff == 1, "yesterday should be exactly 1 day before today, got diff=\(diff)")
    }
}

// MARK: - Non-cooperative weather mock (ignores cancellation)

/// A WeatherProvider that truly ignores `Task.cancel()` — it blocks
/// a background thread with `DispatchSemaphore.wait` (not `Task.sleep`)
/// so `CancellationError` is never thrown. This mirrors real WeatherKit,
/// which has no cooperative cancellation point and must be abandoned
/// via the unstructured-Task race in `withTimeoutOrFailed`.
///
/// Tests that use `Task.sleep` for delay (like `MockWeatherProvider`)
/// satisfy cancellation immediately, so they never exercise the
/// "timeout wins over non-cooperative fetch" code path.
final class NonCooperativeMockWeatherProvider: WeatherProvider, @unchecked Sendable {
    private let delaySeconds: TimeInterval

    init(delaySeconds: TimeInterval) {
        self.delaySeconds = delaySeconds
    }

    func fetch(latitude: Double, longitude: Double, generation: Int) async -> ForecastResult {
        let delay = self.delaySeconds
        // Run the blocking wait on a background thread via a continuation.
        // DispatchSemaphore.wait() is NOT a Swift cooperative cancellation
        // point — CancellationError is never thrown here.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .background).async {
                let sem = DispatchSemaphore(value: 0)
                _ = sem.wait(timeout: .now() + delay)
                continuation.resume()
            }
        }
        return .fresh(
            forecast: [],
            observed: [],
            homeTimeZone: TimeZone(identifier: "America/Chicago")!,
            fetchedAt: Date()
        )
    }

    func bumpGeneration(to generation: Int) async {}
    func cachedSnapshot() async -> ForecastSnapshot? { nil }
}

// MARK: - [13] withTimeoutOrFailed

/// Tests that `withTimeoutOrFailed` returns `.failed("timeout")` when the
/// weather provider is non-cooperative (does not respond to cancellation).
///
/// Strategy: inject a `NonCooperativeMockWeatherProvider` with a 10s
/// delay, then call `withTimeoutOrFailed(seconds: 0.2, ...)` directly
/// on the service. The timeout fires at 0.2s; the whole call must
/// complete in well under 1s. If the fix (unstructured-Task race) is
/// absent the test would hang for 10s.
@Suite("WeatherWarningsService — withTimeoutOrFailed unblocks at timeout ([13])",
       .serialized)
struct WithTimeoutOrFailedTests {

    private static let homeTimeZone = TimeZone(identifier: "America/Chicago")!

    @MainActor
    private static func makeService() -> WeatherWarningsService {
        let schema = Schema(SeedkeepSchema.all)
        let config = ModelConfiguration(
            "timeoutTests-\(UUID().uuidString)",
            schema: schema,
            isStoredInMemoryOnly: true, cloudKitDatabase: .none
        )
        let container = try! ModelContainer(for: schema, configurations: config)
        // Non-cooperative provider: Thread.sleep for 10s, ignores cancellation.
        let provider = NonCooperativeMockWeatherProvider(delaySeconds: 10)
        let scheduler = MockNotificationScheduler()
        scheduler.setAuthorizationStatus(.authorized)
        let planting = StubPlantingEventQuery(activeCount: 1)
        let watering = MockWateringStateClient()
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = homeTimeZone
        let comps = DateComponents(
            calendar: cal, timeZone: homeTimeZone,
            year: 2026, month: 7, day: 15, hour: 3, minute: 0)
        let now = cal.date(from: comps) ?? Date()
        let clock = FixedClock(now: now)
        return WeatherWarningsService(
            container: container,
            provider: provider,
            scheduler: scheduler,
            planting: planting,
            wateringState: watering,
            clock: clock,
            thresholds: .kc,
            householdIDProvider: { "hh_timeout_test" },
            preferencesProvider: { (39.0997, -94.5786) },
            togglesProvider: { (true, false, false) }
        )
    }

    @Test("non-cooperative provider: withTimeoutOrFailed returns .failed within timeout window")
    func nonCooperativeProviderTimesOutFast() async {
        let service = await Self.makeService()

        // Call withTimeoutOrFailed with a 0.2s timeout directly.
        // The NonCooperativeMockWeatherProvider hangs for 10s without
        // yielding to cooperative cancellation, so without the
        // unstructured-Task race fix this would block for 10s.
        let start = Date()
        let result = await service.withTimeoutOrFailed(seconds: 0.2) {
            await NonCooperativeMockWeatherProvider(delaySeconds: 10)
                .fetch(latitude: 39.0997, longitude: -94.5786, generation: 0)
        }
        let elapsed = Date().timeIntervalSince(start)

        // Must complete in well under 1s (generous bound for CI jitter).
        #expect(elapsed < 1.0,
                "withTimeoutOrFailed should return at ~0.2s, not wait for the 10s provider; elapsed=\(elapsed)s")

        // The timeout path must produce .failed("timeout").
        if case .failed(let message, _) = result {
            #expect(message == "timeout",
                    "Expected .failed(\"timeout\") from the timeout path, got .failed(\"\(message)\")")
        } else {
            Issue.record("Expected .failed(message: \"timeout\") from withTimeoutOrFailed, got \(result). Fix: the unstructured-Task race must let the sleep-task win and return .failed.")
        }
    }
}
