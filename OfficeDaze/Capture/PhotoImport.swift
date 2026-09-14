import Foundation
import ImageIO

/// Whatever arrives — shared file or chosen photo — checked to be an image
/// before it goes any further.
///
/// This used to downsize, re-encode and rotate for a remote API with a size
/// cap and a short list of formats. The reader now runs on the phone, wants
/// every pixel it can get, and reads the orientation out of the header
/// itself (see `DocumentReader`), so the only thing left to do at the door is
/// refuse bytes that are not an image at all — a PDF, a truncated download —
/// with the one error every intake path already knows how to show.
nonisolated enum PhotoImport {

    /// The bytes, untouched, or `unreadableImage` if ImageIO cannot open them.
    static func prepare(_ data: Data) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0 else {
            throw CaptureError.unreadableImage
        }
        return data
    }
}
