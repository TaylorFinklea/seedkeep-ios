import Foundation
@preconcurrency import UserNotifications

/// Phase 4C — testable wrapper over `UNUserNotificationCenter`.
///
/// The shipped `NotificationsCenter` calls `center.add(_:withCompletionHandler:)`
/// silently and can't be intercepted by unit tests. This protocol exposes
/// the same surface as `async throws` so:
///   1. Tests inject a `MockNotificationScheduler` that records every
///      `add` / `removePendingNotificationRequests` call.
///   2. `WeatherWarningsService` can `try await` each schedule and react
///      per-id (some succeed, some fail) instead of fire-and-forget.
protocol NotificationScheduler: Sendable {
    func authorizationStatus() async -> UNAuthorizationStatus
    func requestAuthorization(options: UNAuthorizationOptions) async -> Bool
    func pendingNotificationRequests() async -> [UNNotificationRequest]
    func add(_ request: UNNotificationRequest) async throws
    func removePendingNotificationRequests(withIdentifiers ids: [String]) async
}

/// Production impl. Each method runs its entire body inside a single
/// `MainActor.run` block — UNUserNotificationCenter is not `Sendable`,
/// so we can't return the center handle across isolation domains.
/// Inside the main-actor closure we await the async APIs, then return
/// only `Sendable` value types (status, [Request], Bool, Void). One
/// hop per call keeps the actor-isolated callers (`WeatherWarningsService`)
/// from re-entering the main thread implicitly.
struct SystemNotificationScheduler: NotificationScheduler {

    init() {}

    func authorizationStatus() async -> UNAuthorizationStatus {
        await mainActorResult { await $0.notificationSettings().authorizationStatus }
    }

    func requestAuthorization(options: UNAuthorizationOptions) async -> Bool {
        await mainActorResult { center in
            do {
                return try await center.requestAuthorization(options: options)
            } catch {
                return false
            }
        }
    }

    func pendingNotificationRequests() async -> [UNNotificationRequest] {
        await mainActorResult { await $0.pendingNotificationRequests() }
    }

    func add(_ request: UNNotificationRequest) async throws {
        try await mainActorThrowingResult { try await $0.add(request) }
    }

    func removePendingNotificationRequests(withIdentifiers ids: [String]) async {
        await MainActor.run {
            UNUserNotificationCenter.current()
                .removePendingNotificationRequests(withIdentifiers: ids)
        }
    }

    // MARK: - Internals

    /// Run `body` on the main actor with the shared
    /// `UNUserNotificationCenter`. The async body is owned by the
    /// main-actor closure, so the non-Sendable center never crosses
    /// an isolation domain. Returns only a Sendable result.
    private func mainActorResult<T: Sendable>(
        _ body: @escaping @Sendable @MainActor (UNUserNotificationCenter) async -> T
    ) async -> T {
        await Task { @MainActor in
            await body(UNUserNotificationCenter.current())
        }.value
    }

    private func mainActorThrowingResult<T: Sendable>(
        _ body: @escaping @Sendable @MainActor (UNUserNotificationCenter) async throws -> T
    ) async throws -> T {
        try await Task { @MainActor in
            try await body(UNUserNotificationCenter.current())
        }.value
    }
}
