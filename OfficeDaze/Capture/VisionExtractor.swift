import Foundation

/// The reader, end to end: bytes in, bookings out. Runs on the phone, so
/// nothing leaves it and nothing is billed.
nonisolated enum VisionExtractor {

    /// `today` draws the line under the past: a booking for an earlier day is
    /// read and then left out, and a page holding nothing else says so.
    static func extract(image: Data, today: Day) async throws -> [ParsedBooking] {
        let reading = try await DocumentReader.read(image).reading
        let all = BookingParser.parse(reading)
        let upcoming = all.filter { $0.day >= today }
        guard !upcoming.isEmpty else {
            throw CaptureError.nothingUsable(Self.nothingUsable(
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
}
