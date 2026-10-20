import Foundation

/// Names one camera capture: the scan, its generation and the side it is for (N2). The camera hands
/// it back with the photo, so a photo from an earlier capture (before a Restart or Cancel) is
/// recognised as stale and dropped.
struct CaptureToken: Equatable, Sendable {
    let scanID: UUID
    let generation: Int
    let side: ScanPhotoStaging.Side
    /// Counts requests within the scan, so a retry after a timeout is a different token.
    var sequence = 0
}

/// One scan, from its first photo to the seed it saves as (N2 slice D). It owns the scan's staging
/// and its extraction task. Cancelling stops the extraction, drops any late result and deletes the
/// staging. Once a result is handed to the review, the staging belongs to the save, so a later
/// cancel leaves it alone.
///
/// Kept free of camera code so the macOS test target can exercise it.
@MainActor
final class ScanRun {
    let scanID: UUID
    let root: URL

    /// Bumped by `cancel()`. A result is delivered only while its generation is still current.
    private(set) var generation = 0
    private(set) var isCancelled = false
    private(set) var isHandedOff = false
    /// The extraction in flight, if any. Tests await it to observe delivery.
    private(set) var extraction: Task<Void, Never>?
    /// The capture requested and not yet staged. Only one is outstanding at a time.
    private(set) var outstandingCapture: CaptureToken?
    private var captureSequence = 0
    /// When the outstanding capture was requested; nil once its photo arrived. A camera that never
    /// calls back frees the capture after `captureTimeout`.
    private var outstandingSince: Date?
    /// The account, garden and scan epoch the scan started under (V1).
    private(set) var binding: ScanPhotoStaging.ScanBinding?

    /// How long a requested capture may wait for the camera before another can start.
    static let captureTimeout: TimeInterval = 10

    /// The clock for the capture timeout. Tests substitute a fixed one.
    var now: () -> Date = { Date() }

    init(scanID: UUID = UUID(), root: URL = ScanPhotoStaging.rootDirectory()) {
        self.scanID = scanID
        self.root = root
    }

    /// Binds the scan to the scope it starts under. Only the first binding counts.
    func bind(_ binding: ScanPhotoStaging.ScanBinding?) {
        if self.binding == nil { self.binding = binding }
    }

    /// What `stage` did with a photo.
    enum StageResult: Equatable {
        case staged
        /// The photo answers a capture that is no longer outstanding; it was dropped.
        case stale
        /// The account, garden or scan epoch changed since the scan started. The scan was cancelled
        /// and its staging deleted; the sheet should close with `ScanPhotoStaging.scopeChangedNotice`.
        case scopeChanged
    }

    /// Stages a resized photo for `token`, only while the token is outstanding and the scan is still
    /// bound to `current`. Throws when the write fails.
    func stage(
        _ photo: Data,
        for token: CaptureToken,
        current: ScanPhotoStaging.ScanBinding?,
        capturedAt: Date = Date()
    ) throws -> StageResult {
        guard accepts(token) else { return .stale }
        guard let binding, binding.matches(current) else {
            cancel()
            return .scopeChanged
        }
        try ScanPhotoStaging.write(
            photo, side: token.side, scanID: scanID, scope: binding.scope, capturedAt: capturedAt, root: root
        )
        return .staged
    }

    /// False once the scan was cancelled or its result handed off.
    var isActive: Bool { !isCancelled && !isHandedOff }

    /// Runs `work` off the main actor and delivers its result on the main actor. A result that
    /// arrives after `cancel()` is dropped.
    func run<T: Sendable>(
        _ work: @escaping @Sendable () async throws -> T,
        deliver: @escaping @MainActor (Result<T, Error>) -> Void
    ) {
        extraction?.cancel()
        let current = generation
        extraction = Task { [weak self] in
            let result: Result<T, Error>
            do {
                result = .success(try await work())
            } catch {
                result = .failure(error)
            }
            guard let self, self.generation == current else { return }
            deliver(result)
        }
    }

    /// Starts a capture for `side` and returns its token, or nil while another capture is
    /// outstanding (a double tap) or the scan is over.
    func requestCapture(side: ScanPhotoStaging.Side) -> CaptureToken? {
        expireCaptureIfNeeded()
        guard isActive, outstandingCapture == nil else { return nil }
        captureSequence += 1
        let token = CaptureToken(scanID: scanID, generation: generation, side: side, sequence: captureSequence)
        outstandingCapture = token
        outstandingSince = now()
        return token
    }

    /// True while `token` is this scan's outstanding capture. A photo for any other token, or for a
    /// capture that timed out, is stale.
    func accepts(_ token: CaptureToken) -> Bool {
        expireCaptureIfNeeded()
        return isActive && token == outstandingCapture
    }

    /// The camera delivered `token`'s photo: it no longer times out while it is resized and staged.
    func captureDelivered(_ token: CaptureToken) {
        if outstandingCapture == token { outstandingSince = nil }
    }

    /// Ends the outstanding capture once its photo is staged or failed, so the next can start.
    func finishCapture(_ token: CaptureToken) {
        if outstandingCapture == token {
            outstandingCapture = nil
            outstandingSince = nil
        }
    }

    /// Frees a capture the camera never answered, so capturing is never blocked for good.
    private func expireCaptureIfNeeded() {
        guard let since = outstandingSince, now().timeIntervalSince(since) > Self.captureTimeout else { return }
        outstandingCapture = nil
        outstandingSince = nil
    }

    /// Passes the result to the review. The staging now belongs to the save.
    func handOff() {
        isHandedOff = true
    }

    /// Stops the scan: cancels the extraction, drops its late result and deletes the staging.
    /// Does nothing after `handOff()`.
    func cancel() {
        guard !isHandedOff else { return }
        isCancelled = true
        generation += 1
        outstandingCapture = nil
        outstandingSince = nil
        extraction?.cancel()
        extraction = nil
        ScanPhotoStaging.discard(scanID: scanID, root: root)
    }
}
