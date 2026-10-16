import CoreGraphics
import Foundation
@testable import Seedkeep

/// Platform-neutral image fixtures for tests. They draw through Core Graphics, so the same
/// fixture code builds and runs on iOS and macOS. Images are 1 pixel per point (`scale` 1).
enum PlatformImageFixtures {
    /// A solid, opaque colour of `size` pixels.
    static func solid(red: CGFloat, green: CGFloat, blue: CGFloat, size: CGSize) -> PlatformImage {
        guard let cgImage = solidCGImage(
            red: red, green: green, blue: blue,
            width: Int(size.width), height: Int(size.height)
        ) else {
            preconditionFailure("could not build a \(Int(size.width))x\(Int(size.height)) fixture bitmap")
        }
        return PlatformImageCoding.image(cgImage: cgImage, scale: 1)
    }

    /// A solid, opaque colour as a `CGImage` in sRGB.
    static func solidCGImage(red: CGFloat, green: CGFloat, blue: CGFloat, width: Int, height: Int) -> CGImage? {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              ) else { return nil }
        context.setFillColor(red: red, green: green, blue: blue, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}
