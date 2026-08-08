import EventKit
import Foundation

/// The three EventKit calls this file makes, behind a protocol.
///
/// `EKEventStore` cannot be exercised in a test: `requestWriteOnlyAccessToEvents`
/// puts a permission alert on screen and `save` needs a real calendar database.
/// Without a seam the add-or-refuse rule below — the whole reason the event
/// identifier is stored on the booking — is unassertable, which is how it came
/// to be written against an API that cannot work under the access the app asks
/// for. The protocol is deliberately narrow: three calls, no `EKEventStore` in
/// the signature, so a fake needs no calendar at all.
///
/// `save` returns the identifier rather than leaving the caller to read
/// `event.eventIdentifier`, because that property is only populated once the
/// event has been committed — a fake cannot set it, and an implicitly
/// unwrapped nil would be a crash rather than a failed test.
@MainActor
protocol CalendarBackend {
    func requestWriteOnlyAccess() async throws -> Bool
    func makeEvent() -> EKEvent
    func save(_ event: EKEvent) throws -> String
}

/// The real one, one `EKEventStore` per write.
@MainActor
struct EventKitBackend: CalendarBackend {
    private let store = EKEventStore()

    func requestWriteOnlyAccess() async throws -> Bool {
        try await store.requestWriteOnlyAccessToEvents()
    }

    /// The calendar is chosen here rather than in `apply`, so that `apply` is
    /// about the booking and can be asserted without a store.
    func makeEvent() -> EKEvent {
        let event = EKEvent(eventStore: store)
        event.calendar = store.defaultCalendarForNewEvents
        return event
    }

    func save(_ event: EKEvent) throws -> String {
        try store.save(event, span: .thisEvent, commit: true)
        return event.eventIdentifier
    }
}

/// Putting a desk booking in the calendar, where the rest of the day already
/// is.
///
/// Write-only access, not full: the app adds an event and never reads one, and
/// iOS shows a lighter prompt for the smaller permission. The cost of that
/// choice is the rule in `write` — a booking gets one event, ever, because an
/// event this app wrote is an event it can no longer find, change or delete.
nonisolated enum CalendarWriter {

    /// Everything the writer needs, and nothing from SwiftData — so the title
    /// and notes can be tested without a calendar.
    struct Entry: Equatable, Sendable {
        var deskID: String
        var officeName: String
        var address: String
        var floor: String?
        var zone: String?
        var day: Day
        var startTime: String?
        var endTime: String?
    }

    enum Outcome: Equatable, Sendable {
        case added(String)
        /// Unreachable while the app asks for write-only access — see `write`.
        /// It stays because it is the outcome the day the app asks for full
        /// access instead, and because the booking detail row still switches
        /// on it.
        case updated(String)
        case denied
        case failed(String)
    }

    /// Natural case, deliberately. Every label *in* the app is sentence case
    /// too, but this string leaves the app and lands in a calendar beside
    /// meetings written by other people.
    static func title(_ entry: Entry) -> String {
        "Desk \(entry.deskID) · \(entry.officeName)"
    }

    static func location(_ entry: Entry) -> String? {
        let full = [entry.officeName, entry.address]
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
        return full.isEmpty ? nil : full
    }

    /// Only what was actually read. A floor the capture could not make out is
    /// absent from the note rather than an empty line.
    static func notes(_ entry: Entry) -> String {
        var lines: [String] = []
        if let floor = entry.floor { lines.append("Floor: \(floor)") }
        if let zone = entry.zone { lines.append("Zone: \(zone)") }
        lines.append("Added by Office Daze.")
        return lines.joined(separator: "\n")
    }

    /// The two instants an `EKEvent` is made of, in the zone the phone is in.
    ///
    /// A `Day` has no zone and an `EKEvent` is a pair of instants, so this is
    /// the boundary where one has to be chosen, and every part of the choice
    /// has been wrong here before:
    ///
    /// * Both instants come from one calendar. The all-day branch used to
    ///   return `startOfDayUTC` while the timed branch built local midnight —
    ///   two different instants for the same day, and west of Greenwich
    ///   midnight UTC is the previous evening, so the all-day event filed
    ///   itself a day early.
    /// * Both instants are built from full date components. The timed branch
    ///   used to reach the start time with `addingTimeInterval` from midnight,
    ///   which is absolute seconds: on the two days a year the clocks move,
    ///   08:00 came out as 09:00 in spring and 07:00 in autumn.
    ///
    /// `zone` is a parameter, defaulted rather than read inside, so a test can
    /// pin one — the arithmetic above is correct-looking in London in July and
    /// wrong everywhere else, which is precisely what an unpinned test hides.
    static func span(
        _ entry: Entry, in zone: TimeZone = .autoupdatingCurrent
    ) -> (start: Date, end: Date, isAllDay: Bool) {
        let calendar = Day.localCalendar(zone)
        func instant(minutesAfterMidnight: Int) -> Date? {
            calendar.date(from: DateComponents(
                year: entry.day.year, month: entry.day.month, day: entry.day.day,
                hour: minutesAfterMidnight / 60, minute: minutesAfterMidnight % 60
            ))
        }
        // The first moment of the day, reached via noon rather than by asking
        // for hour 0: a few zones skip 00:00 on the day the clocks go forward
        // (Santiago, Beirut) and have no midnight to ask for.
        let dayStart = calendar.startOfDay(for: entry.day.localNoon(in: zone))
        guard let opening = minutes(entry.startTime), let closing = minutes(entry.endTime),
              closing > opening,
              let start = instant(minutesAfterMidnight: opening),
              let end = instant(minutesAfterMidnight: closing) else {
            // An all-day event when neither end was read, because a guessed
            // 09:00 start would be a guess in somebody's calendar.
            return (dayStart, dayStart, true)
        }
        return (start, end, false)
    }

    /// `08:00` → 480. Nil for anything that is not a wall-clock time, so a
    /// half-read value becomes an all-day event rather than a wrong one.
    static func minutes(_ text: String?) -> Int? {
        guard let text else { return nil }
        let parts = text.split(separator: ":")
        guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        return hour * 60 + minute
    }

    // MARK: Writing

    /// The message the user sees for the second tap. Written here rather than
    /// at the call site because it is the explanation for a rule this file
    /// owns.
    static let alreadyWritten =
        "This booking is already in your calendar. Office Daze can't change an "
        + "event it has added, so it won't add a second one — edit or delete it "
        + "in Calendar."

    /// One event per booking. A booking that already has an identifier is
    /// refused, and nothing is written.
    ///
    /// The refusal is the honest end of the write-only choice.
    /// `event(withIdentifier:)` is a read, and a write-only grant does not
    /// permit reads, so it answers nil however the event was created — the
    /// update branch that used to stand here could never run. What ran instead
    /// was the fall-through beneath it: a second `EKEvent` saved as a fresh
    /// event, a twin of the first in the user's calendar, with the identifier
    /// of the original overwritten by the new one and so lost for good. The row
    /// said "Update calendar event" and the app reported "Added to calendar";
    /// both were wrong, and every further tap added another.
    ///
    /// Refusing loses something real: a user who deleted the event by hand
    /// cannot get it back, because the booking still holds an identifier for
    /// an event that no longer exists and this app cannot tell the difference.
    /// That is the smaller harm — a missing event is visible and a duplicate is
    /// confusing — but it is a harm, and the way out of it is a product
    /// decision, not a code one: asking for full access
    /// (`requestFullAccessToEvents`, plus the full-access usage description in
    /// Info.plist) makes the identifier work as intended, at the cost of a much
    /// heavier permission prompt for a feature this small.
    ///
    /// The refusal comes before the access request on purpose: there is no
    /// reason to put a permission alert in front of someone in order to tell
    /// them nothing will be written.
    @MainActor
    static func write(
        _ entry: Entry,
        existingEventID: String?,
        in zone: TimeZone = .autoupdatingCurrent,
        using backend: any CalendarBackend = EventKitBackend()
    ) async -> Outcome {
        if let existingEventID, !existingEventID.isEmpty {
            return .failed(alreadyWritten)
        }

        do {
            guard try await backend.requestWriteOnlyAccess() else { return .denied }
        } catch {
            return .failed(error.localizedDescription)
        }

        let event = backend.makeEvent()
        apply(entry, to: event, in: zone)
        do {
            return .added(try backend.save(event))
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Internal rather than private so a test can assert what lands on the
    /// event without a calendar to save it to.
    static func apply(
        _ entry: Entry, to event: EKEvent, in zone: TimeZone = .autoupdatingCurrent
    ) {
        let span = span(entry, in: zone)
        event.title = title(entry)
        event.location = location(entry)
        event.notes = notes(entry)
        event.isAllDay = span.isAllDay
        event.startDate = span.start
        event.endDate = span.end
        // An all-day event must have no zone, and this is not a stylistic
        // point: assigning one turns `isAllDay` back off — EventKit takes a
        // zone to mean the event has a clock time, which an all-day event by
        // definition does not. A timed event gets the zone its instants were
        // built in, so it keeps the hour the desk was booked for; left nil it
        // floats, and a booking made in London would read 09:00 again after
        // the user lands in New York, where the desk did not move.
        event.timeZone = span.isAllDay ? nil : zone
    }
}
