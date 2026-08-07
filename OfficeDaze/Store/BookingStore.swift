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

    /// Saves an edit to a booking that already exists.
    ///
    /// It cannot go through `upsert` alone. Editing a booking's date or office
    /// can move it onto a day that already has one, and `upsert` — which finds
    /// its match by office and day — would find the very row being edited and
    /// merge it with itself. So the old row goes first.
    ///
    /// Which means the row that comes back is a new one, and every field the
    /// candidate does not describe has to be carried across by hand. Here is
    /// where that happens: a property added to `DeskBooking` that
    /// `BookingMerge.Candidate` does not carry needs a line below, or editing
    /// a booking will quietly drop it.
    @discardableResult
    static func replace(
        _ booking: DeskBooking,
        with incoming: BookingMerge.Candidate,
        in context: ModelContext
    ) throws -> DeskBooking {
        // The calendar event id is the only handle the app has on an event
        // that write-only access cannot read back; the capture id is what
        // keeps "view original" working, which `upsert` already promises a
        // booking corrected by hand does not lose.
        let calendarEventID = booking.calendarEventID
        let captureID = booking.captureID
        context.delete(booking)
        let saved = try upsert(incoming, in: context)
        // Never over what the destination already holds. An edit that moves
        // this booking onto a day with an event or a screenshot of its own
        // would otherwise orphan that one in the course of saving this one.
        if saved.calendarEventID == nil { saved.calendarEventID = calendarEventID }
        if saved.captureID == nil { saved.captureID = captureID }
        try context.save()
        return saved
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

    /// Notes a day still ahead as one you intend to be on prem for, with no
    /// desk. The mirror of `recordAttendance`: that one refuses the future,
    /// this one refuses the past, and between them every day has exactly one
    /// record that fits it.
    @discardableResult
    static func recordPlanned(
        day: Day, officeID: UUID, today: Day = .today, in context: ModelContext
    ) throws -> PlannedDay? {
        guard day > today else { return nil }
        let already = try context.fetch(FetchDescriptor<PlannedDay>())
            .contains { $0.day == day && $0.officeID == officeID }
        guard !already else { return nil }

        let planned = PlannedDay(day: day, officeID: officeID)
        context.insert(planned)
        try context.save()
        return planned
    }

    static func deletePlanned(_ planned: PlannedDay, in context: ModelContext) throws {
        context.delete(planned)
        try context.save()
    }

    /// Removes a recorded day. The counterpart of `recordAttendance`, for a day
    /// entered by hand and then thought better of.
    static func deleteAttendance(_ day: AttendanceDay, in context: ModelContext) throws {
        context.delete(day)
        try context.save()
    }

    /// Records a day on prem. Never called without the user confirming — the
    /// geofence offers, it does not record.
    @discardableResult
    ///
    /// `today` is injected rather than read, as it is in `QuotaService` and
    /// `ArrivalRule`, so the boundary itself can be tested instead of only
    /// holding on whatever date the suite happens to run.
    static func recordAttendance(
        day: Day, officeID: UUID?, source: AttendanceSource,
        bookingID: UUID? = nil, today: Day = .today, in context: ModelContext
    ) throws -> AttendanceDay? {
        // A day that has not happened cannot have been worked. The rule lives
        // here rather than only in the date picker because `attended` is the
        // one number the target is measured against — and the difference
        // between "target met" and "on track" is precisely that attendance
        // counts days behind you while a booking counts intent. A future
        // attendance row collapses that distinction and the gauge starts
        // claiming days that have not happened.
        guard day <= today else { return nil }

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
