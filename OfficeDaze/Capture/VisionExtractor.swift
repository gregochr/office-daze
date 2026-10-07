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
                readNothing: reading.isEmpty, pastBookings: all.count,
                found: BookingParser.found(in: reading.lines)
            ))
        }
        return upcoming
    }

    /// Why nothing came back, in the order the reasons would have stopped it.
    ///
    /// When the page had no whole booking on it, the reason says which of
    /// its parts were read, because that is the difference between a
    /// photograph that needs retaking and a photograph of the wrong thing.
    /// A date with no desk id is the common case — the dates are the
    /// biggest print on the list and the last to blur — and it names the
    /// fix. A desk id with no date is a page cropped above its heading. Both
    /// read but not as one booking is the list with its date cards out of
    /// frame. Neither is not a booking page at all.
    static func nothingUsable(
        readNothing: Bool, pastBookings: Int, found: BookingParser.Found = BookingParser.Found()
    ) -> String {
        if readNothing { return "no text was found in the image" }
        switch pastBookings {
        case 0: break
        case 1: return "the only booking in the document has already passed"
        default: return "all \(pastBookings) bookings in the document have already passed"
        }
        switch (found.dates.isEmpty, found.desks.isEmpty) {
        case (false, true):
            return "\(listing(found.dates)) \(verb(found.dates)) read but no desk id was. "
                + "The desk ids are too small or blurred to make out: move closer so they are sharp, "
                + "or share a screenshot instead."
        case (true, false):
            return "desk \(listing(found.desks)) \(verb(found.desks)) read but no date was. "
                + "Get the date into the frame as well."
        case (false, false):
            return "\(listing(found.dates)) and desk \(listing(found.desks)) were read "
                + "but not as one booking. Each desk needs its date card in frame above it."
        case (true, true):
            return "no date or desk id was found on the page"
        }
    }

    /// `2026-10-19`, `2026-10-19 and 2026-10-20`, `A, B and C`.
    private static func listing(_ items: [String]) -> String {
        guard items.count > 1 else { return items.first ?? "" }
        return items.dropLast().joined(separator: ", ") + " and " + items.last!
    }

    private static func verb(_ items: [String]) -> String {
        items.count == 1 ? "was" : "were"
    }
}
