#if os(iOS)
import Testing
import Foundation
import UIKit
import ImageIO
@testable import Seedkeep

// Photos-on-CloudKit D6 — the single shared resize implementation collapsing ScanFlow's and
// JournalEntryView's formerly-divergent copies. Budgets, failure behavior (throw on the photo
// path vs `?? data` fallback preserved at ScanFlow's own call site), and EXIF-orientation
// normalization (the hash depends on it — nothing previously exercised it).
struct PhotoResizerTests {

    // MARK: - Budgets are parameters, not a second implementation

    @Test("scan and photo budgets match the spec's D6 table exactly")
    func budgetValues() {
        #expect(PhotoResizer.scan.maxDimension == 2048)
        #expect(PhotoResizer.scan.quality == 0.75)
        #expect(PhotoResizer.scan.targetBytes == 4 * 1024 * 1024)

        #expect(PhotoResizer.photo.maxDimension == 2048)
        #expect(PhotoResizer.photo.quality == 0.75)
        #expect(PhotoResizer.photo.targetBytes == 1_572_864)   // 1.5 MB — owner's iCloud bills shared-zone assets
        #expect(PhotoResizer.photo.targetBytes < PhotoResizer.scan.targetBytes)
    }

    // MARK: - Failure behavior: throw on the photo path, nil (→ caller's `?? data`) on the scan path

    @Test("resizedJPEG returns nil for undecodable bytes on either budget")
    func resizeReturnsNilOnDecodeFailure() {
        let garbage = Data("not a real image".utf8)
        #expect(PhotoResizer.resizedJPEG(garbage, budget: PhotoResizer.scan) == nil)
        #expect(PhotoResizer.resizedJPEG(garbage, budget: PhotoResizer.photo) == nil)
    }

    @Test("resizedPhotoJPEG (the photo path) THROWS on decode failure — it must never silently return the original")
    func photoPathThrowsOnDecodeFailure() {
        let garbage = Data("not a real image".utf8)
        #expect(throws: PhotoResizer.Failure.decodeFailed) {
            try PhotoResizer.resizedPhotoJPEG(garbage)
        }
    }

    @Test("resizedPhotoJPEG returns real bytes for a valid image")
    func photoPathSucceedsForValidImage() throws {
        let source = Self.solidColorJPEG(width: 400, height: 300)
        let resized = try PhotoResizer.resizedPhotoJPEG(source)
        #expect(!resized.isEmpty)
        #expect(UIImage(data: resized) != nil)
    }

    // MARK: - Dimension budget

    @Test("output never exceeds maxDimension on the longest side")
    func respectsMaxDimension() throws {
        let source = Self.solidColorJPEG(width: 6000, height: 4000)
        let resized = try #require(PhotoResizer.resizedJPEG(source, budget: PhotoResizer.photo))
        let image = try #require(UIImage(data: resized))
        #expect(max(image.size.width, image.size.height) <= PhotoResizer.photo.maxDimension)
    }

    @Test("a source already under maxDimension is not upscaled")
    func doesNotUpscaleSmallSource() throws {
        let source = Self.solidColorJPEG(width: 200, height: 150)
        let resized = try #require(PhotoResizer.resizedJPEG(source, budget: PhotoResizer.photo))
        let image = try #require(UIImage(data: resized))
        #expect(image.size.width == 200)
        #expect(image.size.height == 150)
    }

    // MARK: - EXIF orientation normalization (D6: "the hash depends on it and nothing exercises it")

    @Test("EXIF orientation is normalized into the output pixel layout, not carried through as metadata")
    func normalizesEXIFOrientation() throws {
        // Raw pixel buffer is landscape (80x40) but tagged with a 90°-rotate EXIF orientation. The
        // user-correct DISPLAY shape is therefore portrait (height > width). UIImage(data:) parses
        // that tag into `.imageOrientation`, and `draw(in:)` bakes the correction into the output
        // pixels — this is what makes two photos of "the same image" hash identically under D2
        // regardless of which orientation the sensor captured in.
        let raw = Self.orientedJPEG(width: 80, height: 40, orientation: .right)
        let rawImage = try #require(UIImage(data: raw))
        #expect(rawImage.size.height > rawImage.size.width,
                "sanity check: UIImage itself must already report the corrected (portrait) size for the source")

        let resized = try #require(PhotoResizer.resizedJPEG(raw, budget: PhotoResizer.photo))
        let resizedImage = try #require(UIImage(data: resized))
        #expect(resizedImage.size.height > resizedImage.size.width,
                "the RESIZED output must keep the corrected portrait shape, not the raw landscape buffer")
    }

    // MARK: - Test fixtures

    private static func solidColorJPEG(width: Int, height: Int) -> Data {
        // format.scale = 1 — same reasoning as PhotoResizer.resizedJPEG itself: without it the
        // renderer uses the simulator/device screen scale (e.g. 3x), so a "200x150" fixture would
        // actually rasterize at 600x450 pixels and silently invalidate any exact-dimension
        // assertion once round-tripped through JPEG bytes (JPEG decode has no logical point size).
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format)
        let image = renderer.image { ctx in
            UIColor.systemGreen.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        return image.jpegData(compressionQuality: 0.9)!
    }

    /// Builds a JPEG whose raw pixel buffer is `width` x `height` but carries an EXIF orientation
    /// tag, via ImageIO — real EXIF metadata, not just a UIImage-level orientation flag, so this
    /// exercises the same parsing path `UIImage(data:)` uses on a real camera capture.
    private static func orientedJPEG(width: Int, height: Int, orientation: CGImagePropertyOrientation) -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        ctx.setFillColor(CGColor(red: 0.7, green: 0.3, blue: 0.2, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let cgImage = ctx.makeImage()!

        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil)!
        let props: [CFString: Any] = [kCGImagePropertyOrientation: orientation.rawValue]
        CGImageDestinationAddImage(dest, cgImage, props as CFDictionary)
        CGImageDestinationFinalize(dest)
        return data as Data
    }
}

#else
import Testing
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import Seedkeep

// macOS half of the suite. The iOS half above is the HEAD file, unchanged. These checks pin the
// same behaviour through ImageIO and CoreGraphics, plus the three things the two platforms must
// agree on: whole-pixel round-up sizes, Display P3 preservation, and white flattening of
// transparency.
struct PhotoResizerTests {

    // MARK: - Budgets are parameters, not a second implementation

    @Test("scan and photo budgets match the spec's D6 table exactly")
    func budgetValues() {
        #expect(PhotoResizer.scan.maxDimension == 2048)
        #expect(PhotoResizer.scan.quality == 0.75)
        #expect(PhotoResizer.scan.targetBytes == 4 * 1024 * 1024)

        #expect(PhotoResizer.photo.maxDimension == 2048)
        #expect(PhotoResizer.photo.quality == 0.75)
        #expect(PhotoResizer.photo.targetBytes == 1_572_864)   // 1.5 MB — owner's iCloud bills shared-zone assets
        #expect(PhotoResizer.photo.targetBytes < PhotoResizer.scan.targetBytes)
    }

    // MARK: - Failure behavior: throw on the photo path, nil (→ caller's `?? data`) on the scan path

    @Test("resizedJPEG returns nil for undecodable bytes on either budget")
    func resizeReturnsNilOnDecodeFailure() {
        let garbage = Data("not a real image".utf8)
        #expect(PhotoResizer.resizedJPEG(garbage, budget: PhotoResizer.scan) == nil)
        #expect(PhotoResizer.resizedJPEG(garbage, budget: PhotoResizer.photo) == nil)
    }

    @Test("resizedPhotoJPEG (the photo path) THROWS on decode failure — it must never silently return the original")
    func photoPathThrowsOnDecodeFailure() {
        let garbage = Data("not a real image".utf8)
        #expect(throws: PhotoResizer.Failure.decodeFailed) {
            try PhotoResizer.resizedPhotoJPEG(garbage)
        }
    }

    @Test("resizedPhotoJPEG returns real bytes for a valid image")
    func photoPathSucceedsForValidImage() throws {
        let source = Self.solidColorJPEG(width: 400, height: 300)
        let resized = try PhotoResizer.resizedPhotoJPEG(source)
        #expect(!resized.isEmpty)
        #expect(Self.decodedImage(resized) != nil)
    }

    // MARK: - Dimension budget

    @Test("output never exceeds maxDimension on the longest side")
    func respectsMaxDimension() throws {
        let source = Self.solidColorJPEG(width: 6000, height: 4000)
        let resized = try #require(PhotoResizer.resizedJPEG(source, budget: PhotoResizer.photo))
        let size = try #require(Self.decodedPixelSize(resized))
        #expect(max(size.width, size.height) <= PhotoResizer.photo.maxDimension)
    }

    @Test("a source already under maxDimension is not upscaled")
    func doesNotUpscaleSmallSource() throws {
        let source = Self.solidColorJPEG(width: 200, height: 150)
        let resized = try #require(PhotoResizer.resizedJPEG(source, budget: PhotoResizer.photo))
        let size = try #require(Self.decodedPixelSize(resized))
        #expect(size.width == 200)
        #expect(size.height == 150)
    }

    // MARK: - Whole-pixel round-up (the iOS raster rounds each side up; these are measured on iOS)

    @Test("6000×4000 → 2048×1366: the short side rounds up")
    func roundsUp6000x4000() throws {
        try Self.expectResizedSize(width: 6000, height: 4000, expectedWidth: 2048, expectedHeight: 1366)
    }

    @Test("3000×2001 → 2048×1367: the short side rounds up")
    func roundsUp3000x2001() throws {
        try Self.expectResizedSize(width: 3000, height: 2001, expectedWidth: 2048, expectedHeight: 1367)
    }

    @Test("2048×2049 → 2048×2048: a one-pixel overshoot scales back under the budget")
    func roundsUp2048x2049() throws {
        try Self.expectResizedSize(width: 2048, height: 2049, expectedWidth: 2048, expectedHeight: 2048)
    }

    @Test("4032×3024 → 2048×1536: an exact fit stays exact")
    func exactFitStaysExact() throws {
        try Self.expectResizedSize(width: 4032, height: 3024, expectedWidth: 2048, expectedHeight: 1536)
    }

    // MARK: - Wide gamut

    @Test("a Display P3 source stays in Display P3 with its colour intact")
    func keepsDisplayP3() throws {
        // The fixture's own stored P3 values are the reference. Drawing a P3 fill does not store the
        // nominal 234/51/35 exactly (measured 215/69/50), so comparing against the nominal value
        // would test the fixture, not the resize.
        let source = Self.displayP3PNG(red: 234, green: 51, blue: 35, width: 64, height: 64)
        let sourceImage = try #require(Self.decodedImage(source))
        let sourceSpace = try #require(sourceImage.colorSpace)
        let expected = try #require(Self.pixel(of: sourceImage, x: 32, y: 32, in: sourceSpace))

        let resized = try #require(PhotoResizer.resizedJPEG(source, budget: Self.lossless))
        let image = try #require(Self.decodedImage(resized))
        #expect(image.colorSpace?.name as String? == CGColorSpace.displayP3 as String,
                "the embedded profile must stay Display P3")
        let pixel = try #require(Self.pixel(of: image, x: 32, y: 32, in: sourceSpace))
        // JPEG chroma quantization leaves a small drift even at quality 1.0, so allow 3 levels.
        #expect(abs(Int(pixel.r) - Int(expected.r)) <= 3
                && abs(Int(pixel.g) - Int(expected.g)) <= 3
                && abs(Int(pixel.b) - Int(expected.b)) <= 3,
                "measured \(pixel) against the source's \(expected)")
    }

    // MARK: - Transparency

    @Test("transparent areas flatten to white, as the iOS encoder does")
    func flattensTransparencyToWhite() throws {
        let source = Self.halfTransparentPNG(width: 64, height: 64)   // top clear, bottom black
        let resized = try #require(PhotoResizer.resizedJPEG(source, budget: Self.lossless))
        let image = try #require(Self.decodedImage(resized))
        let space = CGColorSpaceCreateDeviceRGB()
        let top = try #require(Self.pixel(of: image, x: 32, y: 4, in: space))
        let bottom = try #require(Self.pixel(of: image, x: 32, y: 60, in: space))
        #expect(top.r >= 250 && top.g >= 250 && top.b >= 250)
        #expect(bottom.r <= 5 && bottom.g <= 5 && bottom.b <= 5)
    }

    // MARK: - EXIF orientation normalization

    @Test("EXIF orientation is normalized into the output pixel layout, not carried through as metadata")
    func normalizesEXIFOrientation() throws {
        // Raw pixel buffer is landscape (80x40) but tagged with a 90°-rotate EXIF orientation. The
        // user-correct DISPLAY shape is therefore portrait (height > width). The EXIF tag is applied
        // while rendering, which bakes the correction into the output pixels — this is what makes
        // two photos of "the same image" hash identically under D2 regardless of which orientation
        // the sensor captured in.
        let raw = Self.orientedJPEG(width: 80, height: 40, orientation: .right)
        let rawSize = try #require(PhotoResizer.pixelDimensions(raw))
        #expect(rawSize.height > rawSize.width,
                "sanity check: the source must already report the corrected (portrait) size")

        let resized = try #require(PhotoResizer.resizedJPEG(raw, budget: PhotoResizer.photo))
        let resizedSize = try #require(Self.decodedPixelSize(resized))
        #expect(resizedSize.height > resizedSize.width,
                "the RESIZED output must keep the corrected portrait shape, not the raw landscape buffer")
    }

    // MARK: - Helpers

    /// Budget that never re-encodes lower: a single pass at full quality, for colour checks.
    private static let lossless = PhotoResizer.Budget(maxDimension: 2048, quality: 1.0, targetBytes: Int.max)

    private static func expectResizedSize(width: Int, height: Int, expectedWidth: Int, expectedHeight: Int) throws {
        let source = solidColorJPEG(width: width, height: height)
        let resized = try #require(PhotoResizer.resizedJPEG(source, budget: PhotoResizer.photo))
        let size = try #require(decodedPixelSize(resized))
        #expect(Int(size.width) == expectedWidth)
        #expect(Int(size.height) == expectedHeight)
    }

    private static func decodedImage(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, CGImageSourceGetPrimaryImageIndex(source), nil)
    }

    /// Pixel size of the decoded primary image (the outputs carry no orientation tag).
    private static func decodedPixelSize(_ data: Data) -> CGSize? {
        decodedImage(data).map { CGSize(width: $0.width, height: $0.height) }
    }

    /// The RGB value at (x, y), with y counted from the top, read in `space`.
    private static func pixel(of image: CGImage, x: Int, y: Int, in space: CGColorSpace)
        -> (r: UInt8, g: UInt8, b: UInt8)?
    {
        let width = image.width
        var buffer = [UInt8](repeating: 0, count: width * image.height * 4)
        guard let context = CGContext(
            data: &buffer, width: width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: image.height))
        let i = (y * width + x) * 4
        return (buffer[i], buffer[i + 1], buffer[i + 2])
    }

    private static func encode(_ image: CGImage, type: CFString, properties: [CFString: Any] = [:]) -> Data {
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, type, 1, nil)!
        CGImageDestinationAddImage(dest, image, properties as CFDictionary)
        CGImageDestinationFinalize(dest)
        return data as Data
    }

    private static func solidColorJPEG(width: Int, height: Int) -> Data {
        // Drawn at 1 pixel per point: the requested pixel size must survive the JPEG round trip.
        let space = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        context.setFillColor(red: 0.2, green: 0.78, blue: 0.35, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return encode(context.makeImage()!, type: "public.jpeg" as CFString,
                      properties: [kCGImageDestinationLossyCompressionQuality: 0.9])
    }

    /// A solid Display P3 colour, as a lossless PNG that keeps its profile.
    private static func displayP3PNG(red: Int, green: Int, blue: Int, width: Int, height: Int) -> Data {
        let space = CGColorSpace(name: CGColorSpace.displayP3)!
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        context.setFillColor(red: CGFloat(red) / 255, green: CGFloat(green) / 255,
                             blue: CGFloat(blue) / 255, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return encode(context.makeImage()!, type: "public.png" as CFString)
    }

    /// Top half fully transparent, bottom half opaque black, as a lossless PNG.
    private static func halfTransparentPNG(width: Int, height: Int) -> Data {
        let space = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height / 2))   // CG origin is bottom-left
        return encode(context.makeImage()!, type: "public.png" as CFString)
    }

    /// Builds a JPEG whose raw pixel buffer is `width` x `height` but carries an EXIF orientation
    /// tag, via ImageIO — real EXIF metadata, so this exercises the same parsing path a real camera
    /// capture takes.
    private static func orientedJPEG(width: Int, height: Int, orientation: CGImagePropertyOrientation) -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        ctx.setFillColor(CGColor(red: 0.7, green: 0.3, blue: 0.2, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let cgImage = ctx.makeImage()!

        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil)!
        let props: [CFString: Any] = [kCGImagePropertyOrientation: orientation.rawValue]
        CGImageDestinationAddImage(dest, cgImage, props as CFDictionary)
        CGImageDestinationFinalize(dest)
        return data as Data
    }
}
#endif
