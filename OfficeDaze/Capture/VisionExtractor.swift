import Foundation

/// The on-device reader, end to end: bytes in, bookings out. The shape of
/// `CaptureCoordinator.extractor`, minus the usage the Claude call reports —
/// there is nothing to bill.
nonisolated enum VisionExtractor {

    static func extract(image: Data) async throws -> [ParsedBooking] {
        let reading = try await DocumentReader.read(image).reading
        let bookings = BookingParser.parse(reading)
        guard !bookings.isEmpty else {
            throw CaptureError.modelReturnedNothingUsable(
                reading.isEmpty
                    ? "no text was found in the image"
                    : "no complete booking in the document"
            )
        }
        return bookings
    }

    #if DEBUG
    private static let preferredKey = "visionExtractorPreferred"

    /// Whether the coordinator reads with this instead of Claude. Debug builds
    /// only, switched in Settings, so both readers can be pointed at the same
    /// page in the office and compared. Off by default: Claude stays the
    /// reader until the fixtures from the office say otherwise.
    static var isPreferred: Bool {
        get { UserDefaults.standard.bool(forKey: preferredKey) }
        set { UserDefaults.standard.set(newValue, forKey: preferredKey) }
    }
    #endif
}
