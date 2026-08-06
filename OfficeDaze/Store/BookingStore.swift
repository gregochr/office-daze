import Foundation
import SwiftData

/// Writing a desk booking, applying the one dedupe rule.
///
/// Everything that creates a booking goes through here — typing one in, and
/// the capture flow in stage 4 — so "one desk per office per day" holds
/// wherever the booking came from. The rule itself is in `BookingMerge`, which
/// knows nothing about SwiftData; this only knows how to fetch and write.
@MainActor
enum BookingStore {

    /// Inserts, or updates the booking already held for that office and day.
    /// Returns the row that now holds the data, which may be an existing one.
    @discardableResult
    static func upsert(
        _ incoming: BookingMerge.Candidate,
        captureID: UUID? = nil,
        chosen: Bool = false,
        in context: ModelContext
    ) throws -> DeskBooking {
        let existing = try context.fetch(FetchDescriptor<DeskBooking>())
            .first { $0.officeID == incoming.officeID && $0.day == incoming.day }

        guard let existing else {
            let booking = DeskBooking(
                officeID: incoming.officeID,
                day: incoming.day,
                deskID: incoming.deskID,
                floor: incoming.floor,
                zone: incoming.zone,
                startTime: incoming.startTime,
                endTime: incoming.endTime,
                source: incoming.source,
                unsureFields: incoming.unsureFields,
                captureID: captureID
            )
            context.insert(booking)
            try context.save()
            return booking
        }

        let merged = BookingMerge.merge(
            incoming: incoming, into: candidate(existing), chosen: chosen
        )
        existing.deskID = merged.deskID
        existing.floor = merged.floor
        existing.zone = merged.zone
        existing.startTime = merged.startTime
        existing.endTime = merged.endTime
        existing.source = merged.source
        existing.unsureFields = merged.unsureFields
        // Only ever gains a capture. A booking corrected by hand keeps the
        // screenshot it came from, so "view original" still works.
        if let captureID { existing.captureID = captureID }
        try context.save()
        return existing
    }

    static func candidate(_ booking: DeskBooking) -> BookingMerge.Candidate {
        .init(
            officeID: booking.officeID,
            day: booking.day,
            deskID: booking.deskID,
            floor: booking.floor,
            zone: booking.zone,
            startTime: booking.startTime,
            endTime: booking.endTime,
            source: booking.source,
            unsureFields: booking.unsureFields
        )
    }

    /// Removes a booking.
    ///
    /// Attendance is deliberately left standing. It is the only record that a
    /// day was worked on prem, and deleting the desk you reserved does not undo
    /// having been there — the two come apart in both directions, which is why
    /// they were separate entities in the first place. The link is cleared
    /// rather than left pointing at a row that is gone, which puts the day in
    /// the same state as one turned up for without booking. Which is what it
    /// now is.
    static func delete(_ booking: DeskBooking, in context: ModelContext) throws {
        let attendance = try context.fetch(FetchDescriptor<AttendanceDay>())
        for day in attendance where day.bookingID == booking.id {
            day.bookingID = nil
        }
        context.delete(booking)
        try context.save()
    }

    /// Records a day on prem. Never called without the user confirming — the
    /// geofence offers, it does not record.
    @discardableResult
    static func recordAttendance(
        day: Day, officeID: UUID?, source: AttendanceSource,
        bookingID: UUID? = nil, in context: ModelContext
    ) throws -> AttendanceDay? {
        let already = try context.fetch(FetchDescriptor<AttendanceDay>())
            .contains { $0.day == day && $0.officeID == officeID }
        guard !already else { return nil }

        let record = AttendanceDay(
            day: day, officeID: officeID, source: source, bookingID: bookingID
        )
        context.insert(record)
        try context.save()
        return record
    }
}
