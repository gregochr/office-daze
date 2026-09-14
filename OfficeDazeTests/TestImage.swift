import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Real encoded images to feed the intake with: any size, any format ImageIO
/// writes, with or without an EXIF orientation.
nonisolated enum TestImage {

    /// Whether this host can write HEIC at all. Encoding support is not
    /// guaranteed off-device, and a test that cannot build its fixture should
    /// say it was skipped rather than quietly assert nothing.
    static var canEncodeHEIC: Bool {
        (CGImageDestinationCopyTypeIdentifiers() as? [String])?
            .contains(UTType.heic.identifier) ?? false
    }

    /// Flat grey unless `noisy`, which fills the buffer with something that
    /// will not compress — the only way to get a large file at small
    /// dimensions.
    static func make(
        width: Int, height: Int, type: UTType, orientation: Int? = nil, noisy: Bool = false
    ) -> Data {
        var pixels = [UInt8](repeating: 128, count: width * height * 4)
        if noisy {
            // xorshift rather than anything periodic: a repeating pattern is
            // exactly what PNG is good at, and the fixture only earns its keep
            // if it refuses to compress.
            var state: UInt64 = 0x2545_F491_4F6C_DD1D
            for index in pixels.indices {
                state ^= state << 13
                state ^= state >> 7
                state ^= state << 17
                pixels[index] = UInt8(truncatingIfNeeded: state)
            }
        }
        let image: CGImage? = pixels.withUnsafeMutableBytes { buffer in
            CGContext(
                data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            )?.makeImage()
        }
        let out = NSMutableData()
        guard let image, let writer = CGImageDestinationCreateWithData(
            out, type.identifier as CFString, 1, nil
        ) else { return Data() }
        var properties: [CFString: Any] = [:]
        if let orientation { properties[kCGImagePropertyOrientation] = orientation }
        CGImageDestinationAddImage(writer, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(writer) else { return Data() }
        return out as Data
    }

    static func dimensions(_ data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (width, height)
    }
}
