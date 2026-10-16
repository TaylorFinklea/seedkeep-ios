#if os(macOS)
import CloudKit
import Testing
@testable import Seedkeep

@MainActor
@Suite("macOS share acceptance routing", .serialized)
struct MacShareAcceptanceRoutingTests {
    @Test("hosted unit tests disable live application startup work")
    func hostedTestsDisableLiveStartup() {
        #expect(FeatureFlags.isRunningUnitTests)
        #expect(!FeatureFlags.canRunLiveAppStartup)
    }

    @Test("drain waits until session restoration signs the user in")
    func waitsForSignedInState() async {
        let inbox = PendingShareDrainQueue<String>()
        inbox.deposit("invite")
        var accepted: [String] = []

        var signedIn = false
        await PendingShareQueueDrainer.drain(storage: inbox.drainStorage, isSignedIn: { signedIn }) { accepted.append($0) } onError: { _ in }
        #expect(accepted.isEmpty)
        #expect(inbox.count == 1)

        signedIn = true
        await PendingShareQueueDrainer.drain(storage: inbox.drainStorage, isSignedIn: { signedIn }) { accepted.append($0) } onError: { _ in }
        #expect(accepted == ["invite"])
        #expect(inbox.isEmpty)
    }

    @Test("terminal invitation failure is removed and does not block a later invitation")
    func terminalFailureRemovedBeforeNextInvitation() async {
        let inbox = PendingShareDrainQueue<String>()
        inbox.deposit("revoked")
        inbox.deposit("valid")
        var accepted: [String] = []
        var surfaced = 0

        await PendingShareQueueDrainer.drain(storage: inbox.drainStorage, isSignedIn: { true }) { value in
            if value == "revoked" { throw CKError(.permissionFailure) }
            accepted.append(value)
        } onError: { _ in surfaced += 1 }

        #expect(accepted == ["valid"])
        #expect(inbox.isEmpty)
        #expect(surfaced == 1)
    }

    @Test("transient failure is delayed behind a later invitation and surfaced only once")
    func transientFailureRetriedWithoutBlockingQueue() async {
        let inbox = PendingShareDrainQueue<String>()
        inbox.deposit("offline")
        inbox.deposit("valid")
        let start = Date(timeIntervalSince1970: 1_000)
        var accepted: [String] = []
        var surfaced = 0

        await PendingShareQueueDrainer.drain(storage: inbox.drainStorage, isSignedIn: { true }, clock: { start }) { value in
            if value == "offline" { throw CKError(.networkUnavailable) }
            accepted.append(value)
        } onError: { _ in surfaced += 1 }

        #expect(accepted == ["valid"])
        #expect(inbox.count == 1)
        #expect(surfaced == 1)

        await PendingShareQueueDrainer.drain(storage: inbox.drainStorage, isSignedIn: { true }, clock: { start.addingTimeInterval(1) }) { _ in
            Issue.record("backoff must defer the transient retry")
        } onError: { _ in surfaced += 1 }
        #expect(surfaced == 1)

        await PendingShareQueueDrainer.drain(storage: inbox.drainStorage, isSignedIn: { true }, clock: { start.addingTimeInterval(2) }) { _ in
            throw CKError(.networkUnavailable)
        } onError: { _ in surfaced += 1 }
        #expect(inbox.count == 1)
        #expect(surfaced == 1)
    }

    @Test("transient retries stop after the bounded attempt count")
    func transientRetriesAreBounded() async {
        let inbox = PendingShareDrainQueue<String>()
        inbox.deposit("offline")
        let start = Date(timeIntervalSince1970: 2_000)
        var surfaced = 0

        for seconds in [0.0, 2, 6, 14, 30] {
            await PendingShareQueueDrainer.drain(storage: inbox.drainStorage, isSignedIn: { true }, clock: { start.addingTimeInterval(seconds) }) { _ in
                throw CKError(.serviceUnavailable)
            } onError: { _ in surfaced += 1 }
        }

        #expect(inbox.isEmpty)
        #expect(surfaced == 1)
    }

    @Test("partial failures retry nested transient errors after the advised delay")
    func nestedTransientFailureHonorsRetryAfter() async {
        let inbox = PendingShareDrainQueue<String>()
        inbox.deposit("nested")
        inbox.deposit("later")
        let start = Date(timeIntervalSince1970: 3_000)
        let nestedError = CKError(.zoneBusy, userInfo: [CKErrorRetryAfterKey: NSNumber(value: 120)])
        let partialError = CKError(.partialFailure, userInfo: [
            CKPartialErrorsByItemIDKey: ["share": nestedError]
        ])
        var shouldFail = true
        var accepted: [String] = []

        var currentTime = start
        await PendingShareQueueDrainer.drain(storage: inbox.drainStorage, isSignedIn: { true }, clock: { currentTime }) { value in
            if value == "nested" && shouldFail { throw partialError }
            accepted.append(value)
        } onError: { _ in }

        #expect(accepted == ["later"])
        #expect(inbox.count == 1)
        #expect(MacPendingShareRetryPolicy.isTransient(partialError))
        #expect(MacPendingShareRetryPolicy.delay(afterFailure: 1, error: partialError) == 120)

        currentTime = start.addingTimeInterval(119)
        await PendingShareQueueDrainer.drain(storage: inbox.drainStorage, isSignedIn: { true }, clock: { currentTime }) { _ in
            Issue.record("the retry-after delay must be honored")
        } onError: { _ in }
        shouldFail = false
        currentTime = start.addingTimeInterval(120)
        await PendingShareQueueDrainer.drain(storage: inbox.drainStorage, isSignedIn: { true }, clock: { currentTime }) { value in
            accepted.append(value)
        } onError: { _ in }

        #expect(accepted == ["later", "nested"])
        #expect(inbox.isEmpty)
    }

    @Test("retry backoff starts when acceptance fails, after a long await")
    func retryDelayStartsAtFailureTime() async {
        let inbox = PendingShareDrainQueue<String>()
        inbox.deposit("slow")
        let start = Date(timeIntervalSince1970: 4_000)
        var currentTime = start
        var attempts = 0

        await PendingShareQueueDrainer.drain(storage: inbox.drainStorage, isSignedIn: { true }, clock: { currentTime }) { _ in
            attempts += 1
            currentTime = start.addingTimeInterval(100)
            throw CKError(.networkUnavailable)
        } onError: { _ in }

        #expect(attempts == 1)
        #expect(inbox.count == 1)

        currentTime = start.addingTimeInterval(101)
        await PendingShareQueueDrainer.drain(storage: inbox.drainStorage, isSignedIn: { true }, clock: { currentTime }) { _ in
            attempts += 1
            throw CKError(.networkUnavailable)
        } onError: { _ in }
        #expect(attempts == 1)

        currentTime = start.addingTimeInterval(102)
        await PendingShareQueueDrainer.drain(storage: inbox.drainStorage, isSignedIn: { true }, clock: { currentTime }) { _ in
            attempts += 1
        } onError: { _ in }
        #expect(attempts == 2)
        #expect(inbox.isEmpty)
    }

    @Test("sign-out during acceptance leaves later invitations queued")
    func signOutDuringAcceptanceStopsBeforeNextInvitation() async {
        let inbox = PendingShareDrainQueue<String>()
        inbox.deposit("first")
        inbox.deposit("later")
        var signedIn = true
        var accepted: [String] = []

        await PendingShareQueueDrainer.drain(storage: inbox.drainStorage, isSignedIn: { signedIn }) { value in
            accepted.append(value)
            signedIn = false
        } onError: { _ in }

        #expect(accepted == ["first"])
        #expect(inbox.count == 1)
        #expect(inbox.take() == "later")
    }
}
#endif
