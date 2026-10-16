#if os(macOS)
import CloudKit
import Foundation

/// FIFO storage and drain logic for pending macOS CloudKit invitations.
/// Generic so the retry behavior can be tested with small value types.
@MainActor
final class PendingShareDrainQueue<Element> {
    struct Entry {
        let value: Element
        var failures = 0
        var nextAttempt = Date.distantPast
        var didSurfaceError = false
    }

    private var entries: [Entry] = []

    var isEmpty: Bool { entries.isEmpty }
    var count: Int { entries.count }

    func deposit(_ value: Element) { entries.append(Entry(value: value)) }
    func take() -> Element? { takeEligible(now: .now)?.value }

    fileprivate func takeEligible(now: Date) -> Entry? {
        guard let index = entries.firstIndex(where: { $0.nextAttempt <= now }) else { return nil }
        return entries.remove(at: index)
    }

    fileprivate func retry(_ entry: Entry, now: Date, error: Error) {
        var retry = entry
        retry.failures += 1
        retry.nextAttempt = now.addingTimeInterval(MacPendingShareRetryPolicy.delay(afterFailure: retry.failures, error: error))
        entries.append(retry)
    }

    fileprivate func requeueAtFront(_ entry: Entry) { entries.insert(entry, at: 0) }

    var drainStorage: PendingShareDrainStorage<Element> {
        PendingShareDrainStorage(
            takeEligible: { [weak self] now in self?.takeEligible(now: now) },
            retry: { [weak self] entry, now, error in self?.retry(entry, now: now, error: error) },
            requeueAtFront: { [weak self] entry in self?.requeueAtFront(entry) }
        )
    }
}

/// Closure-backed storage keeps the generic drain policy independent of CloudKit metadata and
/// lets tests inject a queue of any element type.
@MainActor
struct PendingShareDrainStorage<Element> {
    var takeEligible: @MainActor (Date) -> PendingShareDrainQueue<Element>.Entry?
    var retry: @MainActor (PendingShareDrainQueue<Element>.Entry, Date, Error) -> Void
    var requeueAtFront: @MainActor (PendingShareDrainQueue<Element>.Entry) -> Void
}

@MainActor
enum PendingShareQueueDrainer {
    static func drain<Element>(
        storage: PendingShareDrainStorage<Element>,
        isSignedIn: @MainActor () -> Bool,
        clock: @MainActor () -> Date = { .now },
        accept: @MainActor (Element) async throws -> Void,
        onError: @MainActor (Error) -> Void
    ) async {
        while isSignedIn(), var entry = storage.takeEligible(clock()) {
            do {
                try await accept(entry.value)
            } catch {
                guard !(error is PendingShareAuthChangedError), isSignedIn() else {
                    storage.requeueAtFront(entry)
                    return
                }
                let transient = MacPendingShareRetryPolicy.isTransient(error)
                if !entry.didSurfaceError {
                    onError(error)
                    entry.didSurfaceError = true
                }
                if transient && entry.failures < MacPendingShareRetryPolicy.maximumTransientFailures {
                    storage.retry(entry, clock(), error)
                }
            }
        }
    }
}

struct PendingShareAuthChangedError: Error {}
struct PendingShareWipeRetryError: Error {}

enum MacPendingShareRetryPolicy {
    static let maximumTransientFailures = 4

    static func delay(afterFailure count: Int, error: Error? = nil) -> TimeInterval {
        let backoff = min(2 * pow(2, Double(max(0, count - 1))), 60)
        let advised = error.flatMap(retryAfter) ?? 0
        return max(backoff, min(advised, 3_600))
    }

    static func isTransient(_ error: Error) -> Bool {
        if error is PendingShareWipeRetryError || error is PendingShareAuthChangedError { return true }
        guard let error = error as? CKError else { return false }
        switch error.code {
        case .networkUnavailable, .networkFailure, .serviceUnavailable, .requestRateLimited, .zoneBusy:
            return true
        case .partialFailure:
            guard let partialErrors = error.userInfo[CKPartialErrorsByItemIDKey] as? [AnyHashable: Any] else {
                return false
            }
            return partialErrors.values.compactMap { $0 as? Error }.contains(where: isTransient)
        default:
            return false
        }
    }

    private static func retryAfter(_ error: Error) -> TimeInterval? {
        guard let error = error as? CKError else { return nil }
        let ownDelay = (error.userInfo[CKErrorRetryAfterKey] as? NSNumber)?.doubleValue
        guard error.code == .partialFailure,
              let partialErrors = error.userInfo[CKPartialErrorsByItemIDKey] as? [AnyHashable: Any]
        else { return ownDelay }
        let nestedDelay = partialErrors.values.compactMap { $0 as? Error }.compactMap(retryAfter).max()
        return [ownDelay, nestedDelay].compactMap { $0 }.max()
    }
}

/// macOS-only CloudKit invitation queue. iOS keeps its original one-slot inbox.
@MainActor
final class MacPendingShareQueue {
    static let shared = MacPendingShareQueue()

    private let queue = PendingShareDrainQueue<CKShare.Metadata>()

    var count: Int { queue.count }
    var isEmpty: Bool { queue.isEmpty }

    func deposit(_ metadata: CKShare.Metadata) { queue.deposit(metadata) }

    func drain(
        isSignedIn: @MainActor () -> Bool,
        clock: @MainActor () -> Date = { .now },
        accept: @MainActor (CKShare.Metadata) async throws -> Void,
        onError: @MainActor (Error) -> Void
    ) async {
        await PendingShareQueueDrainer.drain(
            storage: queue.drainStorage,
            isSignedIn: isSignedIn,
            clock: clock,
            accept: accept,
            onError: onError
        )
    }
}
#endif
