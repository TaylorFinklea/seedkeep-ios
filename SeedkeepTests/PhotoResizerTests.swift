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
