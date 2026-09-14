import Foundation

/// The on-device reader, end to end: bytes in, bookings out. The shape of
/// `CaptureCoordinator.extractor`, minus the usage the Claude call reports —
/// there is nothing to bill.
nonisolated enum VisionExtractor {

    /// `today` draws the line under the past: a booking for an earlier day is
    /// read and then left out, and a page holding nothing else says so.
    static func extract(image: Data, today: Day) async throws -> [ParsedBooking] {
        let reading = try await DocumentReader.read(image).reading
        let all = BookingParser.parse(reading)
        let upcoming = all.filter { $0.day >= today }
        guard !upcoming.isEmpty else {
            throw CaptureError.modelReturnedNothingUsable(Self.nothingUsable(
                readNothing: reading.isEmpty, pastBookings: all.count
            ))
        }
        return upcoming
    }

    /// Why nothing came back, in the order the reasons would have stopped it.
    static func nothingUsable(readNothing: Bool, pastBookings: Int) -> String {
        if readNothing { return "no text was found in the image" }
        switch pastBookings {
        case 0: return "no complete booking in the document"
        case 1: return "the only booking in the document has already passed"
        default: return "all \(pastBookings) bookings in the document have already passed"
        }
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
