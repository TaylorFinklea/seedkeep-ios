import SwiftUI
import UIKit
import SeedkeepKit

/// Result the scan flow returns to its parent. Either a catalog hit (we
/// know exactly what packet it is) or an AI extraction (best-effort
/// fields the user can confirm or edit).
enum ScanResult: Equatable {
    case catalogHit(barcode: String, catalog: CatalogSeedDTO)
    case extracted(WireResponses.ExtractionResult, barcode: String?)
    /// Result of an on-device extraction (free / byok tier), persisted via
    /// `POST /api/extractions/pre-extracted`.
    case preExtracted(WireResponses.PreExtractedResult, barcode: String?)
}

/// Orchestrates the scan-to-data flow:
///   1. Camera live preview, barcode detection running.
///   2. Barcode detected → look it up in the global catalog.
///   3. Catalog hit → call back with `.catalogHit` (parent dismisses + opens AddSeedView).
///   4. No barcode hit (or user taps "Skip barcode") → two-shot photo capture (front then back).
///   5. POST /api/extractions, show spinner, return `.extracted` on success.
struct ScanFlow: View {
    @Environment(AppEnvironment.self) private var appEnv
    @Environment(\.dismiss) private var dismiss

    /// Called when the scan ends with a usable result. The parent uses
    /// this payload to populate `AddSeedView`. Closing the flow without
    /// a result dismisses without calling this.
    let onComplete: (ScanResult) -> Void

    enum Phase: Equatable {
        case scanning
        case lookingUp(String)
        /// Barcode detected and looked up; no catalog hit. Camera stays
        /// live so the user can frame the packet and tap to capture the
        /// front. Separating this from `.scanning` keeps the detector
        /// from re-firing the lookup in a loop while the user lines up
        /// the shot.
        case captureFront(barcode: String?)
        case promptForBack(frontJPEG: Data, barcode: String?)
        case extracting(Data, Data, String?)
        case error(String)
    }

    @State private var phase: Phase = .scanning
    @State private var capture: CaptureCommand = .idle
    @State private var detectedBarcode: String?

    var body: some View {
        NavigationStack {
            ZStack {
                CameraView(
                    onBarcodeDetected: handleBarcode,
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
                    Button("Cancel") { dismiss() }
                }
            }
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
    }

    private var navTitle: String {
        switch phase {
        case .scanning: return "Scriptorium"
        case .lookingUp: return "Reading…"
        case .captureFront: return "Front of the packet"
        case .promptForBack: return "Back of the packet"
        case .extracting: return "Reading…"
        case .error: return "Could not read"
        }
    }

    @ViewBuilder
    private var overlay: some View {
        switch phase {
        case .scanning:
            ScanningOverlay(
                onCaptureWithoutBarcode: { capture = .takePhoto }
            )
        case .lookingUp(let barcode):
            StatusOverlay(title: "Looking up barcode…", subtitle: barcode)
        case .captureFront(let barcode):
            FrontPromptOverlay(
                barcode: barcode,
                onCaptureFront: { capture = .takePhoto },
                onCancel: { phase = .scanning; detectedBarcode = nil }
            )
        case .promptForBack(_, _):
            BackPromptOverlay(
                onCaptureBack: { capture = .takePhoto },
                onCancel: { phase = .scanning; detectedBarcode = nil }
            )
        case .extracting:
            StatusOverlay(title: "Reading the packet…", subtitle: "This usually takes 8–15 seconds.")
        case .error(let message):
            ErrorOverlay(message: message, onRetry: { phase = .scanning })
        }
    }

    // MARK: - Camera callbacks

    private func handleBarcode(_ value: String) {
        guard case .scanning = phase else { return }
        detectedBarcode = value
        phase = .lookingUp(value)
        Task { await lookUpBarcode(value) }
    }

    private func handlePhoto(_ data: Data) {
        // Anthropic vision caps images at 5MB; Foundation Models is happy
        // at much smaller; our server's pre-extracted endpoint takes a
        // base64 string that bloats ~33% in transit. Resize once here so
        // every downstream path gets a bounded payload.
        //
        // Run the resize on a detached task: UIImage decode + render +
        // jpegData is sync and takes 1–3 sec per 12 MP photo on iPhone 16
        // — easily long enough to trip the iOS hang indicator if done on
        // MainActor.
        let phaseBeforeResize = phase
        Task.detached(priority: .userInitiated) {
            let resized = Self.resizedJPEG(data, maxDimension: 2048, quality: 0.75) ?? data
            await self.applyResizedPhoto(resized, phaseAtCapture: phaseBeforeResize)
        }
    }

    @MainActor
    private func applyResizedPhoto(_ resized: Data, phaseAtCapture: Phase) {
        // If the user cancelled / restarted while the resize was running,
        // drop the photo on the floor — phase has moved on.
        guard phase == phaseAtCapture else { return }
        switch phase {
        case .scanning:
            // Front photo without a barcode (user tapped "Skip barcode").
            phase = .promptForBack(frontJPEG: resized, barcode: detectedBarcode)
        case .captureFront(let barcode):
            // Barcode was captured but had no catalog hit; this is the
            // front photo for the AI-extraction pipeline.
            phase = .promptForBack(frontJPEG: resized, barcode: barcode)
        case .promptForBack(let frontJPEG, let barcode):
            phase = .extracting(frontJPEG, resized, barcode)
            Task { await runExtraction(front: frontJPEG, back: resized, barcode: barcode) }
        default:
            break
        }
    }

    /// Resize + recompress an oversize JPEG. Returns nil only if UIImage
    /// can't decode the bytes (e.g. corrupted capture); callers fall back
    /// to the original Data in that case.
    ///
    /// Guarantees the returned bytes are ≤ `targetBytes` by progressively
    /// dropping JPEG quality if the first pass overruns. Anthropic's
    /// vision API caps at 5 MB on the base64-encoded form, so a raw cap
    /// of 4 MB leaves headroom for the ~33% base64 inflation.
    ///
    /// `nonisolated` so the resize can run on a detached background task
    /// — UIImage/UIGraphicsImageRenderer are safe off main, and the
    /// MainActor isolation inherited from `View` would otherwise force
    /// this multi-second sync work back onto the main thread.
    nonisolated private static func resizedJPEG(
        _ data: Data,
        maxDimension: CGFloat,
        quality: CGFloat,
        targetBytes: Int = 4 * 1024 * 1024
    ) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let size = image.size
        let longest = max(size.width, size.height)

        // Critical: format.scale = 1 forces the renderer to emit a real
        // pixel-for-pixel bitmap at our requested CGSize. The default is
        // UIScreen.main.scale (2.0 or 3.0), which silently inflates a
        // "2048-point" output to 4096 or 6144 actual pixels.
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.opaque = true

        let drawSize: CGSize = {
            if longest <= maxDimension { return size }
            let scale = maxDimension / longest
            return CGSize(width: size.width * scale, height: size.height * scale)
        }()

        let scaled = UIGraphicsImageRenderer(size: drawSize, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: drawSize))
        }

        // Progressive quality fallback: rare but possible that an image
        // with a lot of fine detail still busts the budget at the first
        // chosen quality. Try descending steps before giving up.
        for q in [quality, 0.6, 0.5, 0.4, 0.3] as [CGFloat] {
            guard let encoded = scaled.jpegData(compressionQuality: q) else { continue }
            if encoded.count <= targetBytes { return encoded }
        }
        // Last resort: return the smallest one we got, even if it's over.
        return scaled.jpegData(compressionQuality: 0.3)
    }

    /// Run base64 encoding for both photos on a detached background task
    /// in parallel. Each ~4 MB Data turns into a ~5.3 MB String, and the
    /// encoder is synchronous — doing both on MainActor adds another
    /// ~1 second of hang on top of the resize work.
    nonisolated private static func encodeBase64Pair(front: Data, back: Data) async -> (String, String) {
        async let f = Task.detached(priority: .userInitiated) { front.base64EncodedString() }.value
        async let b = Task.detached(priority: .userInitiated) { back.base64EncodedString() }.value
        return await (f, b)
    }

    private func handleCameraError(_ error: CameraError) {
        phase = .error(error.errorDescription ?? "Camera error")
    }

    // MARK: - Network steps

    private func lookUpBarcode(_ barcode: String) async {
        do {
            if let hit = try await appEnv.client.catalogLookup(barcode: barcode) {
                onComplete(.catalogHit(barcode: barcode, catalog: hit))
                dismiss()
                return
            }
        } catch let err as SeedkeepError {
            // Lookup errored — surface but let the user fall back to photos.
            phase = .error("\(err.code): \(err.message)")
            return
        } catch {
            phase = .error(error.localizedDescription)
            return
        }
        // No catalog hit — move to the front-capture phase so the
        // detector doesn't immediately re-fire while the user lines up
        // the front-of-packet shot. The captured barcode rides through
        // the rest of the flow so it lands on the AI-extraction submit
        // and the resulting catalog entry inherits it.
        phase = .captureFront(barcode: barcode)
    }

    private func runExtraction(front: Data, back: Data, barcode: String?) async {
        // Branch on the user's chosen AI provider. Free runs Apple
        // Foundation Models on-device; BYOK calls the user's chosen
        // remote provider with their key (still bypassing our server);
        // Hosted hits the multipart server-vision route. All three
        // ultimately persist via /api/extractions/pre-extracted (or
        // /api/extractions for Hosted).
        switch appEnv.preferences.aiProvider {
        case .free:
            await runOnDeviceExtraction(front: front, back: back, barcode: barcode)
        case .byok:
            await runBYOKExtraction(front: front, back: back, barcode: barcode)
        case .hosted:
            await runHostedExtraction(front: front, back: back, barcode: barcode)
        }
    }

    private func runBYOKExtraction(front: Data, back: Data, barcode: String?) async {
        let extractor = BYOKExtractor(keyStore: appEnv.apiKeys)
        let output: BYOKExtractor.Output
        do {
            output = try await extractor.extract(frontJPEG: front, backJPEG: back)
        } catch BYOKExtractor.Failure.noKey {
            phase = .error("No API key set. Add one in Settings → API keys, or switch to Free / Hosted.")
            return
        } catch {
            phase = .error("BYOK extraction failed: \(error.localizedDescription)")
            return
        }

        let (frontB64, backB64) = await Self.encodeBase64Pair(front: front, back: back)
        let input = SeedkeepClient.PreExtractedInput(
            common_name: output.commonName,
            scientific_name: output.scientificName,
            variety: output.variety,
            company: output.company,
            instructions: output.instructions,
            days_to_germinate_min: output.daysToGerminateMin,
            days_to_germinate_max: output.daysToGerminateMax,
            days_to_maturity_min: output.daysToMaturityMin,
            days_to_maturity_max: output.daysToMaturityMax,
            soil_temp_min_f: output.soilTempMinF,
            soil_temp_max_f: output.soilTempMaxF,
            seed_depth_inches: output.seedDepthInches,
            plant_spacing_inches: output.plantSpacingInches,
            row_spacing_inches: output.rowSpacingInches,
            sun_requirement: output.sunRequirement,
            frost_tolerance: output.frostTolerance,
            sow_method: output.sowMethod,
            life_cycle: output.lifeCycle,
            hardiness_zone_min: output.hardinessZoneMin,
            hardiness_zone_max: output.hardinessZoneMax,
            self_confidence: output.selfConfidence,
            model_id: output.modelID,
            barcode: barcode,
            perceptual_hash: nil,
            front_jpeg_b64: frontB64,
            back_jpeg_b64: backB64
        )

        do {
            let result = try await appEnv.client.submitPreExtracted(input)
            onComplete(.preExtracted(result, barcode: barcode))
            dismiss()
        } catch let err as SeedkeepError where err.code == "wrong_tier" {
            phase = .error("Server says you're on Hosted — switch in Settings → AI provider, or downgrade.")
        } catch let err as SeedkeepError {
            phase = .error("\(err.code): \(err.message)")
        } catch {
            phase = .error(error.localizedDescription)
        }
    }

    private func runHostedExtraction(front: Data, back: Data, barcode: String?) async {
        do {
            let result = try await appEnv.client.submitExtraction(
                frontJPEG: front,
                backJPEG: back,
                barcode: barcode,
                perceptualHash: nil
            )
            onComplete(.extracted(result, barcode: barcode))
            dismiss()
        } catch let err as SeedkeepError where err.code == "wrong_tier" {
            phase = .error("Server says you're not on the Hosted tier. Switch to Free / BYOK in Settings → AI provider, or subscribe.")
        } catch let err as SeedkeepError {
            phase = .error("\(err.code): \(err.message)")
        } catch {
            phase = .error(error.localizedDescription)
        }
    }

    private func runOnDeviceExtraction(front: Data, back: Data, barcode: String?) async {
        let extractor = OnDeviceExtractor()
        let output: OnDeviceExtractor.Output
        do {
            output = try await extractor.extract(frontJPEG: front, backJPEG: back)
        } catch {
            phase = .error("On-device extraction failed: \(error.localizedDescription)")
            return
        }

        let (frontB64, backB64) = await Self.encodeBase64Pair(front: front, back: back)
        let input = SeedkeepClient.PreExtractedInput(
            common_name: output.commonName,
            scientific_name: output.scientificName,
            variety: output.variety,
            company: output.company,
            instructions: output.instructions,
            days_to_germinate_min: output.daysToGerminateMin,
            days_to_germinate_max: output.daysToGerminateMax,
            days_to_maturity_min: output.daysToMaturityMin,
            days_to_maturity_max: output.daysToMaturityMax,
            soil_temp_min_f: output.soilTempMinF,
            soil_temp_max_f: output.soilTempMaxF,
            seed_depth_inches: output.seedDepthInches,
            plant_spacing_inches: output.plantSpacingInches,
            row_spacing_inches: output.rowSpacingInches,
            sun_requirement: output.sunRequirement,
            frost_tolerance: output.frostTolerance,
            sow_method: output.sowMethod,
            life_cycle: output.lifeCycle,
            hardiness_zone_min: output.hardinessZoneMin,
            hardiness_zone_max: output.hardinessZoneMax,
            self_confidence: output.selfConfidence,
            model_id: output.modelID,
            barcode: barcode,
            perceptual_hash: nil,
            front_jpeg_b64: frontB64,
            back_jpeg_b64: backB64
        )

        do {
            let result = try await appEnv.client.submitPreExtracted(input)
            onComplete(.preExtracted(result, barcode: barcode))
            dismiss()
        } catch let err as SeedkeepError where err.code == "wrong_tier" {
            phase = .error("Server says you're on Hosted. Switch to Hosted in Settings → AI provider, or downgrade.")
        } catch let err as SeedkeepError {
            phase = .error("\(err.code): \(err.message)")
        } catch {
            phase = .error(error.localizedDescription)
        }
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

private struct ScanningOverlay: View {
    let onCaptureWithoutBarcode: () -> Void

    var body: some View {
        VStack {
            Spacer()
            ScanReticle()
            Spacer()
            VStack(spacing: 14) {
                Text("READ THE BARCODE")
                    .font(HerbFont.smallCaps(size: 11))
                    .tracking(2)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 8)
                    .background(.black.opacity(0.6), in: .capsule)
                Button {
                    onCaptureWithoutBarcode()
                } label: {
                    Text("No barcode — read the front")
                        .font(HerbFont.bodyItalic(size: 14))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 11)
                        .background(.black.opacity(0.55), in: .capsule)
                }
            }
            .padding(.bottom, 36)
        }
    }
}

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
    let barcode: String?
    let onCaptureFront: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack {
            Spacer()
            VStack(spacing: 14) {
                if let barcode {
                    VStack(spacing: 4) {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark")
                                .font(.system(size: 14))
                                .foregroundStyle(HerbColor.verdictNow)
                            Text("BARCODE READ")
                                .font(HerbFont.smallCaps(size: 10))
                                .tracking(1.5)
                                .foregroundStyle(.white)
                        }
                        Text(barcode)
                            .font(.caption.monospaced())
                            .foregroundStyle(.white.opacity(0.85))
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.black.opacity(0.6), in: .capsule)
                }
                Text("New packet — read the front to extract details.")
                    .font(HerbFont.bodyItalic(size: 14))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(.black.opacity(0.6), in: .capsule)
                HStack(spacing: 12) {
                    Button(role: .cancel) { onCancel() } label: {
                        Text("Restart")
                            .font(HerbFont.smallCaps(size: 11))
                            .tracking(1.5)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 11)
                            .background(.black.opacity(0.55), in: .capsule)
                    }
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
            }
            .padding(.bottom, 36)
        }
    }
}

private struct BackPromptOverlay: View {
    let onCaptureBack: () -> Void
    let onCancel: () -> Void

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
                    Button(role: .cancel) { onCancel() } label: {
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
