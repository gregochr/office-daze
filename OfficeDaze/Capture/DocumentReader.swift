import Foundation
import ImageIO
import Vision

/// Vision's document reader, run on the bytes as they arrived.
///
/// Reading the pixels, and nothing else. What they say is `BookingParser`'s
/// job.
nonisolated enum DocumentReader {

    /// What one image was read as: Vision's observations, whole, and their
    /// reduction. The observations are kept for the spike's records; the
    /// parser only ever sees the reading.
    struct Result: Sendable {
        var observations: [DocumentObservation]
        var reading: DocumentReading
    }

    /// The request, configured once. English is pinned rather than detected:
    /// left to guess, Vision read a desk id off a synthetic page as `CО0ЗC407`
    /// with a Cyrillic O and Ze in it, which is the recogniser deciding the
    /// page might be Russian. Nothing the booking system prints is.
    static func request() -> RecognizeDocumentsRequest {
        var request = RecognizeDocumentsRequest()
        request.textRecognitionOptions.automaticallyDetectLanguage = false
        request.textRecognitionOptions.recognitionLanguages = [Locale.Language(identifier: "en-GB")]
        return request
    }

    /// Decoded to a `CGImage` at full size rather than handed over as `Data`,
    /// and with the orientation read out of the header and passed explicitly.
    /// A photograph taken sideways carries its rotation in EXIF, and a Vision
    /// pass over the unrotated pixels reads a sideways table — the same trap
    /// `PhotoImport` steps around with `kCGImageSourceCreateThumbnailWithTransform`,
    /// handled here the way Vision itself expects it to be.
    ///
    /// `@concurrent` because this project builds with approachable
    /// concurrency, under which a bare `nonisolated` async function runs on
    /// the caller's executor — and the caller is the main actor.
    @concurrent
    static func read(_ data: Data) async throws -> Result {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw CaptureError.unreadableImage
        }
        let observations = try await request().perform(on: image, orientation: orientation(of: source))
        // Several observations would be several documents in one image. The
        // reading takes the first because a capture holds one; the
        // observations keep them all because the spike is there to find out.
        let reading = observations.first.map(DocumentReading.init) ?? DocumentReading()
        return Result(observations: observations, reading: reading)
    }

    /// The EXIF orientation, or `.up` when the header does not say. A
    /// screenshot has none and is upright; a camera frame always has one.
    static func orientation(of source: CGImageSource) -> CGImagePropertyOrientation {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let raw = properties[kCGImagePropertyOrientation] as? UInt32,
              let orientation = CGImagePropertyOrientation(rawValue: raw) else { return .up }
        return orientation
    }
}
