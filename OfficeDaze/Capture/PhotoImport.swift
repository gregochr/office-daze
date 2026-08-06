import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Turns whatever arrives — shared file or chosen photo — into bytes the
/// Messages API will take.
///
/// Three things stop a photo going straight to the model. The iPhone camera
/// writes HEIC and the API accepts only PNG, JPEG, GIF and WebP. A 12MP frame
/// is around 5700px on its long edge, which the API downsizes to 1568 anyway,
/// so the full frame pays for base64 that is discarded before the model sees
/// it — and past 10MB encoded it is not downsized but refused, which is the
/// 400 a photographed confirmation actually came back with. And a photo taken
/// in landscape carries its rotation in EXIF, which a naive re-encode drops,
/// leaving the model a sideways page.
///
/// All three are fixed by re-encoding, and none is worth doing when it is not
/// needed: bytes that are already an acceptable format at an acceptable size go
/// through untouched, because a lossy round-trip of a screenshot that was
/// already fine can only make the text harder to read.
nonisolated enum PhotoImport {

    /// What the API downsizes a long edge to. Sending more is upload the
    /// service discards.
    static let maxEdge = 1568

    /// The bytes are sent base64, which is a third larger again, and the API
    /// rejects an encoded image over 10MB outright — the 400 that started this:
    /// `image exceeds 10 MB maximum: 11907424 bytes`. This bound leaves the
    /// encoded form comfortably inside it, with room for the rest of the body.
    static let maxBytes = 4_000_000

    /// High rather than default, because these are usually screenshots. JPEG
    /// rings around small text, and the model has to read that text.
    static let jpegQuality = 0.9

    /// The formats that need no work, and the media type each becomes.
    private static let acceptable: [String: String] = [
        UTType.png.identifier: "image/png",
        UTType.jpeg.identifier: "image/jpeg",
        UTType.gif.identifier: "image/gif",
        UTType.webP.identifier: "image/webp",
    ]

    /// CPU-bound — decodes and re-encodes an image. Call it off the main actor.
    static func prepare(_ data: Data) throws -> (data: Data, mediaType: String) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0 else {
            throw CaptureError.unreadableImage
        }

        let longestEdge = longestEdge(of: source)
        let type = CGImageSourceGetType(source) as String?
        if let type, let mediaType = acceptable[type],
           data.count <= maxBytes, let longestEdge, longestEdge <= maxEdge {
            return (data, mediaType)
        }

        // `WithTransform` is what applies the EXIF orientation. Without it a
        // photo taken in landscape re-encodes on its side, and the model then
        // reads a sideways table — or, more often, declines to.
        //
        // The cap is the image's own long edge when that is smaller. ImageIO
        // still returns the full image if asked for more, but it logs an error
        // doing it, and a logged error that is not one trains you to skip the
        // ones that are.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: min(maxEdge, longestEdge ?? maxEdge),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else {
            throw CaptureError.unreadableImage
        }

        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            encoded, UTType.jpeg.identifier as CFString, 1, nil
        ) else {
            throw CaptureError.unreadableImage
        }
        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: jpegQuality
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw CaptureError.unreadableImage
        }
        return (encoded as Data, "image/jpeg")
    }

    /// Read from the metadata rather than by decoding — the point of the check
    /// is to avoid decoding a frame that does not need it.
    ///
    /// Nil when the header will not say, which counts as out of bounds:
    /// re-encoding an image that did not need it costs a little quality, and
    /// sending 12MP of base64 because a header was unusual costs the whole
    /// call.
    private static func longestEdge(of source: CGImageSource) -> Int? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return max(width, height)
    }
}
