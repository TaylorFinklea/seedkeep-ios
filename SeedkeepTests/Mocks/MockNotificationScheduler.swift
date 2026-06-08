import Foundation
import os
@preconcurrency import UserNotifications
@testable import Seedkeep

/// Test double for `NotificationScheduler`.
///
/// Records every `add(_:)` and `removePendingNotificationRequests(...)`
/// call so tests can assert the diff-against-pending logic works correctly.
/// Maintains a virtual "pending" set so a sequence of add / remove calls
/// behaves like the real `UNUserNotificationCenter` from the caller's POV.
///
/// `final class` + `@unchecked Sendable` + `OSAllocatedUnfairLock` for the
/// same reason as `MockWeatherProvider` — the service is an actor and
/// crosses isolation. `NSLock` would be rejected by Swift 6's strict
/// concurrency checker in async contexts.
final class MockNotificationScheduler: NotificationScheduler, @unchecked Sendable {

    // MARK: - Failure modes

    enum FailureMode: @unchecked Sendable {
        case none
        /// Every `add(_:)` throws this error.
        case alwaysFailAdd(any Error)
        /// First N `add(_:)` calls throw; subsequent calls succeed.
        case failFirstNAdds(Int, any Error)
    }

    // MARK: - Internal state (lock-guarded)

    private struct State {
        var authorizationStatus: UNAuthorizationStatus = .authorized
        var pendingRequests: [UNNotificationRequest] = []
        var failureMode: FailureMode = .none
        var failAddRemaining: Int = 0
        var recordedAdds: [UNNotificationRequest] = []
        var recordedRemovals: [[String]] = []
        var authorizationStatusReadCount: Int = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    // MARK: - Configuration

    func setAuthorizationStatus(_ status: UNAuthorizationStatus) {
        state.withLock { $0.authorizationStatus = status }
    }

    /// Pre-seed the virtual pending set. Used to simulate legacy frost
    /// notifications that survived a build upgrade.
    func seedPending(_ requests: [UNNotificationRequest]) {
        state.withLock { $0.pendingRequests = requests }
    }

    func setFailureMode(_ mode: FailureMode) {
        state.withLock { s in
            s.failureMode = mode
            if case .failFirstNAdds(let n, _) = mode {
                s.failAddRemaining = n
            } else {
                s.failAddRemaining = 0
            }
        }
    }

    // MARK: - Recorders (read-only)

    var recordedAdds: [UNNotificationRequest] {
        state.withLock { $0.recordedAdds }
    }

    var recordedRemovals: [[String]] {
        state.withLock { $0.recordedRemovals }
    }

    var authorizationStatusReadCount: Int {
        state.withLock { $0.authorizationStatusReadCount }
    }

    /// Current virtual pending set — useful for tests that want to assert
    /// the post-state without re-reading the recorded events.
    var pendingSnapshot: [UNNotificationRequest] {
        state.withLock { $0.pendingRequests }
    }

    // MARK: - NotificationScheduler

    func authorizationStatus() async -> UNAuthorizationStatus {
        state.withLock { s in
            s.authorizationStatusReadCount += 1
            return s.authorizationStatus
        }
    }

    func requestAuthorization(options: UNAuthorizationOptions) async -> Bool {
        state.withLock { s in
            s.authorizationStatus == .authorized
                || s.authorizationStatus == .provisional
        }
    }

    func pendingNotificationRequests() async -> [UNNotificationRequest] {
        state.withLock { $0.pendingRequests }
    }

    func add(_ request: UNNotificationRequest) async throws {
        let throwError: (any Error)? = state.withLock { (s: inout State) -> (any Error)? in
            s.recordedAdds.append(request)
            switch s.failureMode {
            case .none:
                break
            case .alwaysFailAdd(let error):
                return error
            case .failFirstNAdds(_, let error):
                if s.failAddRemaining > 0 {
                    s.failAddRemaining -= 1
                    return error
                }
            }
            // Idempotent: replace existing-id request if present.
            s.pendingRequests.removeAll { $0.identifier == request.identifier }
            s.pendingRequests.append(request)
            return nil
        }
        if let error = throwError {
            throw error
        }
    }

    func removePendingNotificationRequests(withIdentifiers ids: [String]) async {
        state.withLock { s in
            s.recordedRemovals.append(ids)
            let toRemove = Set(ids)
            s.pendingRequests.removeAll { toRemove.contains($0.identifier) }
        }
    }
}
