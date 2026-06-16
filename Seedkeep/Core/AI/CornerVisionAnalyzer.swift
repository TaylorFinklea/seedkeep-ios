import UIKit
import Vision

// MARK: - Cue types

/// Light-level heuristic derived from a captured corner image.
/// Values map to catalog sun_requirement strings:
///   .fullSun  → "full"
///   .partialSun → "partial"
///   .shade    → "shade"
///   .unknown  → no catalog field or analysis failed
enum Exposure: String, CaseIterable, Equatable, Sendable {
    case fullSun
    case partialSun
    case shade
    case unknown

    /// Human-readable chip label shown in `CornerSuggestionsView`.
    var displayLabel: String {
        switch self {
        case .fullSun:    return "Full sun"
        case .partialSun: return "Partial sun"
        case .shade:      return "Shade"
        case .unknown:    return "Unknown"
        }
    }
}

/// Spatial-openness heuristic: how crowded is the corner?
enum Openness: String, CaseIterable, Equatable, Sendable {
    case open
    case partial
    case crowded
    case unknown

    var displayLabel: String {
        switch self {
        case .open:    return "Open"
        case .partial: return "Partial"
        case .crowded: return "Crowded"
        case .unknown: return "Unknown"
        }
    }
}

/// Both heuristic cues from a single captured image.
struct CornerCues: Equatable, Sendable {
    var exposure: Exposure
    var openness: Openness

    static let unknown = CornerCues(exposure: .unknown, openness: .unknown)
}

// MARK: - CornerVisionAnalyzer

/// Takes a `UIImage` / `CGImage`, runs two cheap on-device Apple Vision
/// heuristics, and returns `CornerCues`.
///
/// - Exposure: mean luminance of a greyscale render. Bright image → full sun.
/// - Openness: foreground-to-background ratio from a `VNGenerateAttentionBasedSaliencyImageRequest`
///   (available iOS 13+). High saliency coverage → crowded; sparse → open.
///
/// No network. No LLM. Corrupt/empty image → `.unknown`, never crashes.
/// Designed to be testable: inject the image, no camera touches inside.
struct CornerVisionAnalyzer: Sendable {

    // MARK: - Public API

    func analyze(image: UIImage) async -> CornerCues {
        guard let cgImage = image.cgImage else { return .unknown }
        return await analyze(cgImage: cgImage)
    }

    func analyze(cgImage: CGImage) async -> CornerCues {
        guard cgImage.width > 0, cgImage.height > 0 else { return .unknown }
        let exposure = measureExposure(cgImage: cgImage)
        let openness = await measureOpenness(cgImage: cgImage)
        return CornerCues(exposure: exposure, openness: openness)
    }

    // MARK: - Exposure heuristic

    /// Mean luminance over a 64×64 pixel sample of the image.
    /// < 0.30  → shade
    /// 0.30–0.60 → partial sun
    /// ≥ 0.60  → full sun
    ///
    /// Thresholds are deliberately coarse — this is a nudge, not ground truth.
    private func measureExposure(cgImage: CGImage) -> Exposure {
        // Render down to a tiny greyscale bitmap to get a fast mean luminance.
        let side = 64
        var pixelData = [UInt8](repeating: 0, count: side * side)
        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(
            data: &pixelData,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: side,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return .unknown }

        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))

        let total = pixelData.reduce(0, { $0 + Int($1) })
        let mean = Double(total) / Double(pixelData.count * 255)

        if mean >= 0.60 { return .fullSun }
        if mean >= 0.30 { return .partialSun }
        return .shade
    }

    // MARK: - Openness heuristic

    /// Saliency foreground ratio from `VNGenerateAttentionBasedSaliencyImageRequest`.
    ///
    /// The saliency result's `salientObjects` bounds are summed over the
    /// normalised image area. High coverage (≥ 0.50) indicates dense foliage /
    /// crowding; sparse coverage (< 0.20) means open ground.
    ///
    /// Falls back to `.unknown` on any Vision error.
    ///
    /// Note: Vision's `perform` calls the completion handler SYNCHRONOUSLY
    /// before `perform` returns, which means the continuation is already
    /// resumed before the catch path could fire. We guard with `resumed`
    /// so the error path never double-resumes a finished continuation.
    private func measureOpenness(cgImage: CGImage) async -> Openness {
        return await withCheckedContinuation { continuation in
            var resumed = false
            let request = VNGenerateAttentionBasedSaliencyImageRequest { req, err in
                guard !resumed else { return }
                resumed = true
                guard err == nil,
                      let results = req.results as? [VNSaliencyImageObservation],
                      let saliency = results.first,
                      let objects = saliency.salientObjects,
                      !objects.isEmpty
                else {
                    continuation.resume(returning: .unknown)
                    return
                }

                // Sum normalised bounding-box areas.
                let coveredArea = objects.reduce(0.0) { sum, obj in
                    sum + Double(obj.boundingBox.width * obj.boundingBox.height)
                }
                let clamped = min(coveredArea, 1.0)

                let result: Openness
                if clamped >= 0.50 {
                    result = .crowded
                } else if clamped >= 0.20 {
                    result = .partial
                } else {
                    result = .open
                }
                continuation.resume(returning: result)
            }

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
                // Vision fires the handler synchronously; resumed == true here.
                // If it didn't fire (unexpected), resume with .unknown.
                if !resumed {
                    resumed = true
                    continuation.resume(returning: .unknown)
                }
            } catch {
                if !resumed {
                    resumed = true
                    continuation.resume(returning: .unknown)
                }
            }
        }
    }
}
