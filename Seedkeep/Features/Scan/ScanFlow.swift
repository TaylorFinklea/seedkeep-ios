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
        case .scanning: return "Scan"
        case .lookingUp: return "Looking up…"
        case .captureFront: return "Capture front"
        case .promptForBack: return "Capture back"
        case .extracting: return "Extracting…"
        case .error: return "Scan failed"
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
        let resized = Self.resizedJPEG(data, maxDimension: 2048, quality: 0.75) ?? data
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
    private static func resizedJPEG(_ data: Data, maxDimension: CGFloat, quality: CGFloat) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let size = image.size
        let longest = max(size.width, size.height)
        if longest <= maxDimension {
            // Already within target dimensions — recompress only.
            return image.jpegData(compressionQuality: quality)
        }
        let scale = maxDimension / longest
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        let scaled = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
        return scaled.jpegData(compressionQuality: quality)
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
            front_jpeg_b64: front.base64EncodedString(),
            back_jpeg_b64: back.base64EncodedString()
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
            front_jpeg_b64: front.base64EncodedString(),
            back_jpeg_b64: back.base64EncodedString()
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

private struct ScanningOverlay: View {
    let onCaptureWithoutBarcode: () -> Void

    var body: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                ScanReticle()
                Spacer()
            }
            Spacer()
            VStack(spacing: 12) {
                Text("Point at the barcode on the seed packet")
                    .font(.callout)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.6), in: .capsule)
                Button {
                    onCaptureWithoutBarcode()
                } label: {
                    Text("No barcode? Capture front photo")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(.regularMaterial, in: .capsule)
                }
            }
            .padding(.bottom, 32)
        }
    }
}

private struct ScanReticle: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(.white.opacity(0.9), lineWidth: 3)
            .frame(width: 260, height: 160)
            .shadow(color: .black.opacity(0.5), radius: 6, y: 1)
    }
}

private struct FrontPromptOverlay: View {
    let barcode: String?
    let onCaptureFront: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack {
            Spacer()
            VStack(spacing: 12) {
                if let barcode {
                    VStack(spacing: 4) {
                        Label("Barcode captured", systemImage: "checkmark.circle.fill")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.white)
                        Text(barcode)
                            .font(.caption.monospaced())
                            .foregroundStyle(.white.opacity(0.85))
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.black.opacity(0.6), in: .capsule)
                }
                Text("This packet is new — take a front photo so we can extract details.")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(.black.opacity(0.6), in: .capsule)
                HStack(spacing: 12) {
                    Button(role: .cancel) { onCancel() } label: {
                        Text("Restart")
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(.regularMaterial, in: .capsule)
                    }
                    Button {
                        onCaptureFront()
                    } label: {
                        Text("Capture front")
                            .font(.headline)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 12)
                            .background(.tint, in: .capsule)
                            .foregroundStyle(.white)
                    }
                }
            }
            .padding(.bottom, 32)
        }
    }
}

private struct BackPromptOverlay: View {
    let onCaptureBack: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack {
            Spacer()
            VStack(spacing: 12) {
                Text("Now flip the packet over and capture the back")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(.black.opacity(0.6), in: .capsule)
                HStack(spacing: 12) {
                    Button(role: .cancel) { onCancel() } label: {
                        Text("Restart")
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(.regularMaterial, in: .capsule)
                    }
                    Button {
                        onCaptureBack()
                    } label: {
                        Text("Capture back")
                            .font(.headline)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 12)
                            .background(.tint, in: .capsule)
                            .foregroundStyle(.white)
                    }
                }
            }
            .padding(.bottom, 32)
        }
    }
}

private struct StatusOverlay: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
                .progressViewStyle(.circular)
                .controlSize(.large)
                .tint(.white)
            Text(title)
                .font(.headline)
                .foregroundStyle(.white)
            Text(subtitle)
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.85))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .padding(28)
        .background(.black.opacity(0.55), in: .rect(cornerRadius: 18))
    }
}

private struct ErrorOverlay: View {
    let message: String
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.largeTitle)
            Text(message)
                .font(.callout)
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
            Button("Try again", action: onRetry)
                .buttonStyle(.borderedProminent)
        }
        .padding(20)
        .background(.black.opacity(0.65), in: .rect(cornerRadius: 18))
        .padding(.horizontal, 32)
    }
}
