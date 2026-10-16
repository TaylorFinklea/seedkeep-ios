#if os(iOS)
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

extension PhotoResizer {
    /// Pixel size of encoded image bytes with the EXIF orientation applied: `UIImage.size` for
    /// `UIImage(data:)`, as the X-Photo headers have always been computed on iOS.
    static func pixelDimensions(_ data: Data) -> CGSize? {
        UIImage(data: data)?.size
    }
}

#else
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// macOS counterpart of the UIKit implementation above. It reproduces that path on ImageIO and
/// CoreGraphics, so the same input gives the same output on both platforms:
/// - Each side is rounded up to whole pixels, as UIKit's enclosing raster is.
/// - Wide-gamut sources (iPhone photos are Display P3) render into Display P3; others into sRGB.
/// - Transparency is flattened onto white, as the JPEG encoder did on iOS.
/// - The JPEG budget loop is the same. The budget values must match the iOS copy; the budget
///   test pins them on both platforms.
enum PhotoResizer {
    struct Budget: Sendable {
        let maxDimension: CGFloat
        let quality: CGFloat
        let targetBytes: Int
    }

    /// Scan/extraction budget. See the iOS copy for the reasoning.
    static let scan = Budget(maxDimension: 2048, quality: 0.75, targetBytes: 4 * 1024 * 1024)
    /// Photo-store budget. See the iOS copy for the reasoning.
    static let photo = Budget(maxDimension: 2048, quality: 0.75, targetBytes: Int(1.5 * 1024 * 1024))

    enum Failure: Error, Equatable, LocalizedError {
        case decodeFailed
        var errorDescription: String? { "Could not process this photo." }
    }

    /// Resize + progressively recompress a JPEG/PNG/HEIC to fit `budget`. Returns nil only if
    /// `data` can't be decoded. Same contract as the iOS copy.
    nonisolated static func resizedJPEG(_ data: Data, budget: Budget) -> Data? {
        guard let source = decode(data) else { return nil }
        let upright = source.uprightSize

        // Same arithmetic as the UIKit path: scale the longest side to maxDimension, then take the
        // enclosing whole-pixel raster, which rounds each side up.
        let longest = max(upright.width, upright.height)
        let drawSize: CGSize
        if longest <= budget.maxDimension {
            drawSize = upright
        } else {
            let scale = budget.maxDimension / longest
            drawSize = CGSize(width: upright.width * scale, height: upright.height * scale)
        }
        let width = max(1, Int(drawSize.width.rounded(.up)))
        let height = max(1, Int(drawSize.height.rounded(.up)))

        guard let scaled = render(source, drawSize: drawSize, width: width, height: height) else { return nil }

        // Progressive quality fallback, as on iOS.
        for q in [budget.quality, 0.6, 0.5, 0.4, 0.3] as [CGFloat] {
            guard let encoded = jpegData(scaled, quality: q) else { continue }
            if encoded.count <= budget.targetBytes { return encoded }
        }
        return jpegData(scaled, quality: 0.3)
    }

    /// Photo-path wrapper: resize failure throws and never falls back to the original (D6).
    nonisolated static func resizedPhotoJPEG(_ data: Data) throws -> Data {
        guard let resized = resizedJPEG(data, budget: photo) else { throw Failure.decodeFailed }
        return resized
    }

    /// Pixel size of encoded image bytes with the EXIF orientation applied, read from metadata
    /// without decoding the bitmap. Matches the iOS `UIImage.size` for the same bytes.
    nonisolated static func pixelDimensions(_ data: Data) -> CGSize? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let width = number(source, kCGImagePropertyPixelWidth),
              let height = number(source, kCGImagePropertyPixelHeight) else { return nil }
        let size = CGSize(width: width, height: height)
        return orientation(of: source).swapsAxes ? CGSize(width: height, height: width) : size
    }

    // MARK: - Pipeline

    /// Decoded primary image plus its EXIF orientation. `image` is unrotated, like `UIImage.cgImage`.
    private struct Source {
        let image: CGImage
        let orientation: CGImagePropertyOrientation

        /// Pixel size with the orientation applied.
        var uprightSize: CGSize {
            let size = CGSize(width: image.width, height: image.height)
            return orientation.swapsAxes ? CGSize(width: size.height, height: size.width) : size
        }
    }

    nonisolated private static func decode(_ data: Data) -> Source? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let index = CGImageSourceGetPrimaryImageIndex(source)
        guard let image = CGImageSourceCreateImageAtIndex(source, index, nil),
              image.width > 0, image.height > 0 else { return nil }
        return Source(image: image, orientation: orientation(of: source))
    }

    /// Draws the upright, orientation-corrected source into a `width` x `height` bitmap. The image
    /// covers `drawSize`; the rounding sliver stays white, as the iOS raster does.
    nonisolated private static func render(_ source: Source, drawSize: CGSize, width: Int, height: Int) -> CGImage? {
        let wideGamut = source.image.colorSpace?.isWideGamutRGB ?? false
        let spaceName = wideGamut ? CGColorSpace.displayP3 : CGColorSpace.sRGB
        guard let colorSpace = CGColorSpace(name: spaceName),
              let context = CGContext(
                  data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              ) else { return nil }

        // Flatten transparency onto white. The bitmap has no alpha, so drawing composites over this.
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let upright = source.uprightSize
        let rawWidth = CGFloat(source.image.width)
        let rawHeight = CGFloat(source.image.height)
        let fit = CGAffineTransform(scaleX: drawSize.width / upright.width, y: drawSize.height / upright.height)
        // Orientation first (raw pixels to upright), then the fit to the drawn size.
        let transform = orientationTransform(source.orientation, rawWidth: rawWidth, rawHeight: rawHeight)
            .concatenating(fit)

        context.interpolationQuality = .default
        context.concatenate(transform)
        context.draw(source.image, in: CGRect(x: 0, y: 0, width: rawWidth, height: rawHeight))
        return context.makeImage()
    }

    nonisolated private static func jpegData(_ image: CGImage, quality: CGFloat) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return nil }
        let options = [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
        CGImageDestinationAddImage(destination, image, options)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    // MARK: - Orientation

    /// Maps raw pixel space (a `rawWidth` x `rawHeight` rect in Core Graphics coordinates) onto the
    /// upright, unscaled image for an EXIF orientation.
    nonisolated private static func orientationTransform(
        _ orientation: CGImagePropertyOrientation,
        rawWidth w: CGFloat,
        rawHeight h: CGFloat
    ) -> CGAffineTransform {
        switch orientation {
        case .up: return .identity
        case .upMirrored: return CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: w, ty: 0)
        case .down: return CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: w, ty: h)
        case .downMirrored: return CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: h)
        case .leftMirrored: return CGAffineTransform(a: 0, b: -1, c: -1, d: 0, tx: h, ty: w)
        case .right: return CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: w)
        case .rightMirrored: return CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0)
        case .left: return CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: h, ty: 0)
        @unknown default: return .identity
        }
    }

    nonisolated private static func orientation(of source: CGImageSource) -> CGImagePropertyOrientation {
        guard let value = number(source, kCGImagePropertyOrientation),
              let orientation = CGImagePropertyOrientation(rawValue: UInt32(value)) else { return .up }
        return orientation
    }

    /// A numeric property of the primary image.
    nonisolated private static func number(_ source: CGImageSource, _ key: CFString) -> CGFloat? {
        let index = CGImageSourceGetPrimaryImageIndex(source)
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
        return (properties?[key] as? NSNumber).map { CGFloat($0.doubleValue) }
    }
}

private extension CGImagePropertyOrientation {
    /// True for the four orientations that rotate the image a quarter turn.
    var swapsAxes: Bool {
        switch self {
        case .leftMirrored, .right, .rightMirrored, .left: return true
        default: return false
        }
    }
}
#endif
