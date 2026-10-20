import Foundation
import Testing
@testable import Seedkeep

// N2 slice D: Cancel stops a scan's extraction, drops any late result and deletes the staged
// photos. Once a result is handed to the review, the staging belongs to the save.
@MainActor
@Suite("Scan run cancellation (N2)")
struct ScanRunTests {

    private struct ExtractionFailed: Error {}

    private static let scope = ScanPhotoStaging.Scope(userRecordName: "_user", householdID: "hh-scan-run")

    private static func makeRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("scan-run-tests-\(UUID().uuidString)", isDirectory: true)
    }

    @Test("cancel deletes the staging and drops a late extraction result")
    func cancelDropsLateResult() async throws {
        let root = Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let run = ScanRun(root: root)
        try ScanPhotoStaging.write(Data("front".utf8), side: .front, scanID: run.scanID, scope: Self.scope, root: root)
        var delivered: [Int] = []

        run.run({ 42 }, deliver: { result in
            if case .success(let value) = result { delivered.append(value) }
        })
        let extraction = try #require(run.extraction)
        run.cancel()
        await extraction.value

        #expect(delivered.isEmpty)
        #expect(ScanPhotoStaging.manifest(for: run.scanID, root: root) == nil)
        #expect(!run.isActive)
    }

    @Test("a finished extraction is delivered, and a hand-off keeps the staging for the save")
    func handOffKeepsStaging() async throws {
        let root = Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let run = ScanRun(root: root)
        try ScanPhotoStaging.write(Data("front".utf8), side: .front, scanID: run.scanID, scope: Self.scope, root: root)
        var delivered: [Int] = []

        run.run({ 7 }, deliver: { result in
            if case .success(let value) = result { delivered.append(value) }
        })
        await run.extraction?.value
        run.handOff()
        run.cancel()

        #expect(delivered == [7])
        #expect(ScanPhotoStaging.manifest(for: run.scanID, root: root) != nil)
    }

    @Test("a failed extraction is delivered as a failure")
    func failureIsDelivered() async throws {
        let root = Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let run = ScanRun(root: root)
        var failed = false

        run.run({ () throws -> Int in throw ExtractionFailed() }, deliver: { result in
            if case .failure = result { failed = true }
        })
        await run.extraction?.value

        #expect(failed)
        #expect(run.isActive)
    }

    @Test("cancel is safe to repeat")
    func cancelIsIdempotent() throws {
        let root = Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let run = ScanRun(root: root)
        run.cancel()
        run.cancel()

        #expect(run.isCancelled)
        #expect(!run.isActive)
    }

    // MARK: - Capture tokens (S2)

    @Test("a second capture request while one is outstanding is ignored, so a double tap takes one photo")
    func doubleTapTakesOnePhoto() throws {
        let run = ScanRun(root: Self.makeRoot())

        let first = try #require(run.requestCapture(side: .front))
        #expect(run.requestCapture(side: .front) == nil)
        #expect(run.accepts(first))

        run.finishCapture(first)
        let second = try #require(run.requestCapture(side: .back))
        #expect(second.side == .back)
        #expect(!run.accepts(first), "a finished capture's token is stale")
    }

    @Test("a photo that arrives after Restart is dropped by the new scan and the cancelled one")
    func lateCallbackAfterRestartIsStale() throws {
        let root = Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let old = ScanRun(root: root)
        let lateToken = try #require(old.requestCapture(side: .front))

        // Restart: the flow cancels the scan and starts a new one, which asks for its own front.
        old.cancel()
        let restarted = ScanRun(root: root)
        let current = try #require(restarted.requestCapture(side: .front))

        #expect(!old.accepts(lateToken), "the cancelled scan drops its own late photo")
        #expect(!restarted.accepts(lateToken), "the new scan never takes the old scan's photo")
        #expect(restarted.accepts(current))
        #expect(lateToken.scanID != current.scanID)
    }

    @Test("a late failure for a stale token does not end the current capture")
    func staleFinishLeavesCurrentCapture() throws {
        let run = ScanRun(root: Self.makeRoot())
        let stale = CaptureToken(scanID: UUID(), generation: 0, side: .front)
        let current = try #require(run.requestCapture(side: .front))

        run.finishCapture(stale)

        #expect(run.accepts(current))
        #expect(run.outstandingCapture == current)
    }

    @Test("cancel ends the outstanding capture and refuses new ones")
    func cancelEndsCapture() throws {
        let run = ScanRun(root: Self.makeRoot())
        let token = try #require(run.requestCapture(side: .front))

        run.cancel()

        #expect(!run.accepts(token))
        #expect(run.requestCapture(side: .front) == nil)
    }

    // MARK: - Scope binding (V1) and capture timeout (V6)

    @Test("a capture that arrives after a scope change is not staged, and the scan is discarded")
    func captureAfterScopeChangeIsNotStaged() throws {
        let root = Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let run = ScanRun(root: root)
        run.bind(ScanPhotoStaging.ScanBinding(scope: Self.scope, epoch: 0))
        try ScanPhotoStaging.write(Data("front".utf8), side: .front, scanID: run.scanID, scope: Self.scope, root: root)
        let token = try #require(run.requestCapture(side: .back))

        // An eraser bumped the scan epoch while the camera was busy.
        let result = try run.stage(
            Data("back".utf8), for: token,
            current: ScanPhotoStaging.ScanBinding(scope: Self.scope, epoch: 1)
        )

        #expect(result == .scopeChanged)
        #expect(ScanPhotoStaging.manifest(for: run.scanID, root: root) == nil)
        #expect(ScanPhotoStaging.photoData(.back, scanID: run.scanID, root: root) == nil)
        #expect(!run.isActive)
    }

    @Test("another garden is a scope change; the bound garden stages under the bound scope")
    func stageChecksGarden() throws {
        let root = Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let binding = ScanPhotoStaging.ScanBinding(scope: Self.scope, epoch: 3)
        let run = ScanRun(root: root)
        run.bind(binding)
        run.bind(ScanPhotoStaging.ScanBinding(scope: Self.scope, epoch: 9))   // ignored: the first binding counts
        let front = try #require(run.requestCapture(side: .front))

        #expect(try run.stage(Data("front".utf8), for: front, current: binding) == .staged)
        #expect(ScanPhotoStaging.manifest(for: run.scanID, root: root)?.scope == Self.scope)
        run.finishCapture(front)

        let back = try #require(run.requestCapture(side: .back))
        let elsewhere = ScanPhotoStaging.ScanBinding(
            scope: ScanPhotoStaging.Scope(userRecordName: "_user", householdID: "hh-other"), epoch: 3)
        #expect(try run.stage(Data("back".utf8), for: back, current: elsewhere) == .scopeChanged)
        #expect(ScanPhotoStaging.manifest(for: run.scanID, root: root) == nil)
    }

    @Test("an unbound scan never stages")
    func unboundScanDoesNotStage() throws {
        let root = Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let run = ScanRun(root: root)
        let token = try #require(run.requestCapture(side: .front))

        #expect(try run.stage(Data("front".utf8), for: token, current: nil) == .scopeChanged)
        #expect(ScanPhotoStaging.manifest(for: run.scanID, root: root) == nil)
    }

    @Test("a capture the camera never answers frees up after the timeout, and its late photo is stale")
    func unansweredCaptureTimesOut() throws {
        let run = ScanRun(root: Self.makeRoot())
        var clock = Date(timeIntervalSince1970: 1_000)
        run.now = { clock }
        let lost = try #require(run.requestCapture(side: .front))

        clock = clock.addingTimeInterval(ScanRun.captureTimeout - 1)
        #expect(run.requestCapture(side: .front) == nil, "still waiting within the timeout")

        clock = clock.addingTimeInterval(2)
        let retry = try #require(run.requestCapture(side: .front))
        #expect(!run.accepts(lost))
        #expect(run.accepts(retry))
    }

    @Test("a delivered photo does not time out while it is resized and staged")
    func deliveredCaptureDoesNotTimeOut() throws {
        let run = ScanRun(root: Self.makeRoot())
        var clock = Date(timeIntervalSince1970: 1_000)
        run.now = { clock }
        let token = try #require(run.requestCapture(side: .front))

        run.captureDelivered(token)
        clock = clock.addingTimeInterval(ScanRun.captureTimeout * 3)

        #expect(run.accepts(token))
    }
}
