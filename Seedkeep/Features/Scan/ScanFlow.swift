import SwiftUI
import SeedkeepKit

// Live packet scanning needs the camera, so the flow is iOS-only. The macOS build hides the
// scan entry points (LibraryView, SeedsTableView) instead of presenting this.
#if os(iOS)

/// Result the scan flow returns to its parent: the on-device (Free) or BYOK extraction of the two
/// packet photos. Both photos are already staged under `scanID`, and nothing went to our server (N2).
enum ScanResult: Equatable {
    /// `binding` is the scope the scan was bound to, so the save sheet saves into that garden only.
    case localExtraction(scanID: UUID, fields: WireResponses.ExtractionFields,
                         binding: ScanPhotoStaging.ScanBinding?)
}

/// Orchestrates the scan-to-data flow (N2 slice D):
///   1. Camera live preview. The user reads the front of the packet, then the back.
///   2. Each photo is resized to the saved-photo budget and staged on disk as it is captured.
///   3. The user's on-device or BYOK extraction runs over the two photos.
///   4. The result goes to the parent, which opens `AddSeedView` prefilled. Cancel stops the
///      extraction and deletes the staging.
struct ScanFlow: View {
    @Environment(AppEnvironment.self) private var appEnv
    @Environment(\.dismiss) private var dismiss

    /// Called when extraction finishes with a usable result. Closing the flow before that deletes
    /// the scan's staged photos and dismisses without calling this.
    let onComplete: (ScanResult) -> Void

    enum Phase: Equatable {
        case captureFront
        case promptForBack
        case extracting
        case error(String)
    }

    @State private var phase: Phase = .captureFront
    @State private var capture: CaptureCommand = .idle
    @State private var run = ScanRun()
    @State private var frontJPEG: Data?

    var body: some View {
        NavigationStack {
            ZStack {
                CameraView(
                    onPhotoCaptured: handlePhoto,
                    onError: handleCameraError,
                    capture: $capture
                )
                .ignoresSafeArea()

                overlay
            }
            .navigationTitle(navTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        run.cancel()
                        dismiss()
                    }
                }
            }
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
        // The scan belongs to the account and garden it starts under (V1).
        .onAppear { run.bind(appEnv.scanBinding) }
        // Swipe-down and any other dismissal also end the scan. After a hand-off this is a no-op.
        .onDisappear { run.cancel() }
    }

    private var navTitle: String {
        switch phase {
        case .captureFront: return "Front of the packet"
        case .promptForBack: return "Back of the packet"
        case .extracting: return "Reading…"
        case .error: return "Could not read"
        }
    }

    @ViewBuilder
    private var overlay: some View {
        switch phase {
        case .captureFront:
            FrontPromptOverlay(onCaptureFront: { requestCapture(.front) })
        case .promptForBack:
            BackPromptOverlay(
                onCaptureBack: { requestCapture(.back) },
                onRestart: restart
            )
        case .extracting:
            StatusOverlay(title: "Reading the packet…", subtitle: "This usually takes 8–15 seconds.")
        case .error(let message):
            ErrorOverlay(message: message, onRetry: restart)
        }
    }

    // MARK: - Camera callbacks

    /// The phase that takes a photo of `side`.
    private static func capturePhase(for side: ScanPhotoStaging.Side) -> Phase {
        side == .front ? .captureFront : .promptForBack
    }

    /// Asks the camera for one photo of `side`. Ignored while a capture is outstanding, so a double
    /// tap takes one photo.
    private func requestCapture(_ side: ScanPhotoStaging.Side) {
        guard phase == Self.capturePhase(for: side), let token = run.requestCapture(side: side) else { return }
        capture = .takePhoto(token)
    }

    private func handlePhoto(_ data: Data, token: CaptureToken) {
        // A photo from before a Restart or Cancel, or for another request, is stale.
        guard run.accepts(token), phase == Self.capturePhase(for: token.side) else { return }
        run.captureDelivered(token)
        // Resize on a detached task. UIImage decode and render take seconds for a 12 MP capture,
        // which is too long to run on the main actor. A stored photo never falls back to the
        // original bytes: a decode failure is reported as an error.
        Task.detached(priority: .userInitiated) {
            let resized = try? ScanPhotoStaging.resizedPhoto(data)
            await self.applyStagedPhoto(resized, token: token)
        }
    }

    @MainActor
    private func applyStagedPhoto(_ resized: Data?, token: CaptureToken) {
        // The user cancelled, restarted or moved on while the resize ran: drop the photo.
        guard run.accepts(token), phase == Self.capturePhase(for: token.side) else { return }
        defer { run.finishCapture(token) }
        let side = token.side
        guard let resized else {
            phase = .error(PhotoResizer.Failure.decodeFailed.localizedDescription)
            return
        }
        do {
            switch try run.stage(resized, for: token, current: appEnv.scanBinding) {
            case .staged:
                break
            case .stale:
                return
            case .scopeChanged:
                discardForScopeChange()
                return
            }
        } catch {
            phase = .error("Could not keep this photo: \(error.localizedDescription)")
            return
        }
        switch side {
        case .front:
            frontJPEG = resized
            phase = .promptForBack
        case .back:
            guard let front = frontJPEG else {
                phase = .error("The front photo is missing. Start the scan again.")
                return
            }
            phase = .extracting
            runExtraction(front: front, back: resized)
        }
    }

    private func handleCameraError(_ error: CameraError, token: CaptureToken?) {
        // A failed capture from before a Restart or Cancel is stale too.
        if let token {
            guard run.accepts(token) else { return }
            run.finishCapture(token)
        }
        phase = .error(error.errorDescription ?? "Camera error")
    }

    /// The account or garden changed under the scan (V1): the run is cancelled (its staging
    /// deleted), and the sheet closes with a notice.
    private func discardForScopeChange() {
        run.cancel()
        appEnv.surfaceMessage(ScanPhotoStaging.scopeChangedNotice)
        dismiss()
    }

    // MARK: - Extraction

    private func runExtraction(front: Data, back: Data) {
        let provider = appEnv.preferences.aiProvider
        let keyStore = appEnv.apiKeys
        let scanID = run.scanID
        run.run({
            try await Self.extract(front: front, back: back, provider: provider, keyStore: keyStore)
        }, deliver: { result in
            switch result {
            case .success(let fields):
                guard run.binding?.matches(appEnv.scanBinding) == true else {
                    discardForScopeChange()
                    return
                }
                run.handOff()
                onComplete(.localExtraction(scanID: scanID, fields: fields, binding: run.binding))
                dismiss()
            case .failure(let error):
                phase = .error(Self.failureMessage(error, provider: provider))
            }
        })
    }

    /// Runs the extraction the user chose. Free uses Apple's on-device model. BYOK sends the photos
    /// to the provider the user configured, with their own key. Neither path calls our server.
    private static func extract(
        front: Data,
        back: Data,
        provider: AppPreferences.AIProvider,
        keyStore: APIKeyStore
    ) async throws -> WireResponses.ExtractionFields {
        switch provider {
        case .free:
            return try await OnDeviceExtractor().extract(frontJPEG: front, backJPEG: back).extractionFields
        case .byok:
            return try await BYOKExtractor(keyStore: keyStore).extract(frontJPEG: front, backJPEG: back).extractionFields
        case .hosted:
            throw ScanFlowFailure.hostedUnavailable
        }
    }

    private static func failureMessage(_ error: Error, provider: AppPreferences.AIProvider) -> String {
        if case BYOKExtractor.Failure.noKey = error {
            return "No API key set. Add one in Settings → API keys, or switch to Free."
        }
        switch provider {
        case .free: return "On-device extraction failed: \(error.localizedDescription)"
        case .byok: return "BYOK extraction failed: \(error.localizedDescription)"
        case .hosted: return error.localizedDescription
        }
    }

    /// Starts a new scan. The current scan's staging is deleted, and an extraction still in flight
    /// is dropped.
    private func restart() {
        run.cancel()
        run = ScanRun()
        run.bind(appEnv.scanBinding)
        frontJPEG = nil
        phase = .captureFront
    }
}

/// Why an extraction could not start. Hosted extraction runs on our server, which is retired (N2).
private enum ScanFlowFailure: LocalizedError {
    case hostedUnavailable

    var errorDescription: String? {
        "Hosted scanning is unavailable. Switch to Free or BYOK in Settings → AI provider."
    }
}

// MARK: - Overlays

// MARK: - Camera overlays
//
// These sit on top of the live camera feed (dark + photographic), so
// chrome stays dark/black to keep prompts readable over arbitrary
// scenes. The herbarium typography (IM Fell SC small-caps for headers,
// Spectral italic for prompts) carries the design language without
// breaking legibility.

/// Reticle as four corner brackets — reads as a scholar's viewfinder
/// rather than a generic rounded rectangle.
private struct ScanReticle: View {
    var body: some View {
        ZStack {
            ForEach(0..<4, id: \.self) { corner in
                CornerBracket()
                    .stroke(.white.opacity(0.92), lineWidth: 2.5)
                    .frame(width: 24, height: 24)
                    .rotationEffect(.degrees(Double(corner) * 90))
                    .offset(
                        x: (corner == 1 || corner == 2) ? 130 : -130,
                        y: (corner >= 2) ? 80 : -80
                    )
            }
        }
        .frame(width: 280, height: 180)
        .shadow(color: .black.opacity(0.5), radius: 6, y: 1)
    }
}

/// L-shape bracket facing into the reticle's upper-left corner. Rotations
/// + offsets paint the other three corners.
private struct CornerBracket: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 0, y: rect.height))
        p.addLine(to: CGPoint(x: 0, y: 0))
        p.addLine(to: CGPoint(x: rect.width, y: 0))
        return p
    }
}

private struct FrontPromptOverlay: View {
    let onCaptureFront: () -> Void

    var body: some View {
        VStack {
            Spacer()
            ScanReticle()
            Spacer()
            VStack(spacing: 14) {
                Text("New packet — read the front to extract details.")
                    .font(HerbFont.bodyItalic(size: 14))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(.black.opacity(0.6), in: .capsule)
                Button { onCaptureFront() } label: {
                    Text("READ FRONT")
                        .font(HerbFont.smallCaps(size: 12))
                        .tracking(2)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 22)
                        .padding(.vertical, 13)
                        .background(HerbColor.sepia, in: .capsule)
                }
            }
            .padding(.bottom, 36)
        }
    }
}

private struct BackPromptOverlay: View {
    let onCaptureBack: () -> Void
    let onRestart: () -> Void

    var body: some View {
        VStack {
            Spacer()
            VStack(spacing: 14) {
                Text("Now the back — flip the packet over.")
                    .font(HerbFont.bodyItalic(size: 14))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(.black.opacity(0.6), in: .capsule)
                HStack(spacing: 12) {
                    Button(role: .cancel) { onRestart() } label: {
                        Text("Restart")
                            .font(HerbFont.smallCaps(size: 11))
                            .tracking(1.5)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 11)
                            .background(.black.opacity(0.55), in: .capsule)
                    }
                    Button { onCaptureBack() } label: {
                        Text("READ BACK")
                            .font(HerbFont.smallCaps(size: 12))
                            .tracking(2)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 22)
                            .padding(.vertical, 13)
                            .background(HerbColor.sepia, in: .capsule)
                    }
                }
            }
            .padding(.bottom, 36)
        }
    }
}

private struct StatusOverlay: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 14) {
            ProgressView()
                .progressViewStyle(.circular)
                .controlSize(.large)
                .tint(.white)
            Text(title.uppercased())
                .font(HerbFont.smallCaps(size: 13))
                .tracking(2)
                .foregroundStyle(.white)
            Text(subtitle)
                .font(HerbFont.bodyItalic(size: 12))
                .foregroundStyle(.white.opacity(0.85))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .padding(28)
        .background(.black.opacity(0.6), in: .rect(cornerRadius: 4))
        .overlay(
            Rectangle().strokeBorder(.white.opacity(0.18), lineWidth: 0.5)
        )
    }
}

private struct ErrorOverlay: View {
    let message: String
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 32))
                .foregroundStyle(HerbColor.ochre)
            Text("COULD NOT READ")
                .font(HerbFont.smallCaps(size: 12))
                .tracking(2)
                .foregroundStyle(.white)
            Text(message)
                .font(HerbFont.bodyItalic(size: 13))
                .foregroundStyle(.white.opacity(0.9))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
            Button { onRetry() } label: {
                Text("TRY AGAIN")
                    .font(HerbFont.smallCaps(size: 11))
                    .tracking(2)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 11)
                    .background(HerbColor.sepia, in: .capsule)
            }
        }
        .padding(24)
        .background(.black.opacity(0.7), in: .rect(cornerRadius: 4))
        .overlay(Rectangle().strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
        .padding(.horizontal, 32)
    }
}

#endif
