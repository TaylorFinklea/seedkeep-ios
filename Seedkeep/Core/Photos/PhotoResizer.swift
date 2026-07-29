import UIKit

/// Single shared JPEG resize/recompress implementation — Photos-on-CloudKit D6.
///
/// Two call sites used to carry independent copies (`ScanFlow.resizedJPEG` at quality 0.75,
/// `JournalEntryView.resizedJPEG` at quality 0.85): the same source image produced different
/// bytes — and therefore a different content hash — depending on which path created it. This is
/// that ScanFlow implementation (it correctly sets `format.scale = 1.0`; without that the
/// renderer silently emits 4096–6144px for a 2048-point request), generalized so the byte/quality
/// budget is a PARAMETER rather than a second implementation.
enum PhotoResizer {
    struct Budget: Sendable {
        let maxDimension: CGFloat
        let quality: CGFloat
        let targetBytes: Int
    }

    /// Scan/extraction budget — sized for Anthropic's base64 vision cap (base64 inflates raw bytes
    /// ~33%, so a 4 MB raw cap leaves headroom under the 5 MB encoded limit). Scan bytes are
    /// transient extraction input, never a stored photo.
    static let scan = Budget(maxDimension: 2048, quality: 0.75, targetBytes: 4 * 1024 * 1024)
    /// Photo-store budget — shared-zone assets bill the OWNER's iCloud, so this is tighter than
    /// `scan` even though scan-time byte counts often look similar.
    static let photo = Budget(maxDimension: 2048, quality: 0.75, targetBytes: Int(1.5 * 1024 * 1024))

    enum Failure: Error, Equatable, LocalizedError {
        case decodeFailed
        var errorDescription: String? { "Could not process this photo." }
    }

    /// Resize + progressively recompress a JPEG/PNG/HEIC to fit `budget`. Returns nil only if
    /// `UIImage` can't decode `data` (e.g. a corrupted capture) — callers on the SCAN path fall
    /// back to the original bytes on nil (transient extraction input; see `resizedPhotoJPEG` for
    /// the photo path, which must never do that).
    ///
    /// `nonisolated` so the multi-second work (UIImage decode + render + jpegData — 1–3s for a
    /// 12MP photo on iPhone 16) can run off MainActor via `Task.detached` at call sites; doing it
    /// inline on MainActor is easily long enough to trip the iOS hang indicator.
    nonisolated static func resizedJPEG(_ data: Data, budget: Budget) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let size = image.size
        let longest = max(size.width, size.height)

        // Critical: format.scale = 1 forces the renderer to emit a real pixel-for-pixel bitmap at
        // our requested CGSize. The default is UIScreen.main.scale (2.0 or 3.0), which silently
        // inflates a "2048-point" output to 4096 or 6144 actual pixels.
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.opaque = true

        let drawSize: CGSize = {
            if longest <= budget.maxDimension { return size }
            let scale = budget.maxDimension / longest
            return CGSize(width: size.width * scale, height: size.height * scale)
        }()

        // UIImage.draw(in:) is orientation-aware — it bakes the EXIF-corrected (upright) pixels
        // into the renderer output regardless of how the source was captured, which is also what
        // keeps two shots of "the same image" hashing identically under D2 regardless of which
        // orientation the sensor recorded in.
        let scaled = UIGraphicsImageRenderer(size: drawSize, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: drawSize))
        }

        // Progressive quality fallback: rare but possible that an image with a lot of fine detail
        // still busts the budget at the first chosen quality. Try descending steps before giving up.
        for q in [budget.quality, 0.6, 0.5, 0.4, 0.3] as [CGFloat] {
            guard let encoded = scaled.jpegData(compressionQuality: q) else { continue }
            if encoded.count <= budget.targetBytes { return encoded }
        }
        // Last resort: return the smallest one we got, even if it's over.
        return scaled.jpegData(compressionQuality: 0.3)
    }

    /// Photo-path wrapper: resize failure means "photo not created," never "upload the original"
    /// (D6) — shared-zone assets bill the owner's iCloud, so a silent fallback to a full-size
    /// original would blow the byte budget on every failure. Callers on this path must NOT add a
    /// `?? data` fallback around the result — that is the exact bug D6 calls out and forbids here
    /// (the scan path's `?? data` fallback is a separate, intentional exception — see `scan`).
    nonisolated static func resizedPhotoJPEG(_ data: Data) throws -> Data {
        guard let resized = resizedJPEG(data, budget: photo) else { throw Failure.decodeFailed }
        return resized
    }
}
