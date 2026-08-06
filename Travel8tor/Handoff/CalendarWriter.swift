import EventKit
import Foundation

/// Putting a desk booking in the calendar, where the rest of the day already
/// is.
///
/// Write-only access, not full: the app adds an event and never reads one, and
/// iOS shows a lighter prompt for the smaller permission. The cost of that
/// choice is that a written event cannot be read back — which is why the event
/// identifier is stored on the booking, and why a second tap updates rather
/// than writing a twin.
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

    /// Wall clock, no timezone conversion — the app has none, and a desk
    /// booked 08:00–17:00 is 08:00–17:00 wherever the phone is. An all-day
    /// event when neither end was read, because a guessed 09:00 start would be
    /// a guess in somebody's calendar.
    static func span(_ entry: Entry) -> (start: Date, end: Date, isAllDay: Bool) {
        let midnight = entry.day.startOfDayUTC
        guard let start = minutes(entry.startTime), let end = minutes(entry.endTime),
              end > start else {
            return (midnight, midnight, true)
        }
        var calendar = Day.calendar
        calendar.timeZone = .current
        let base = calendar.date(
            from: DateComponents(year: entry.day.year, month: entry.day.month, day: entry.day.day)
        ) ?? midnight
        return (
            base.addingTimeInterval(TimeInterval(start * 60)),
            base.addingTimeInterval(TimeInterval(end * 60)),
            false
        )
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

    @MainActor
    static func write(_ entry: Entry, existingEventID: String?) async -> Outcome {
        let store = EKEventStore()
        do {
            guard try await store.requestWriteOnlyAccessToEvents() else { return .denied }
        } catch {
            return .failed(error.localizedDescription)
        }

        // Write-only access cannot read an event back, so an existing id can
        // only be updated blind — and if the user deleted the event by hand
        // that update fails, which is when a fresh one is written instead.
        if let existingEventID, let existing = store.event(withIdentifier: existingEventID) {
            apply(entry, to: existing, in: store)
            do {
                try store.save(existing, span: .thisEvent, commit: true)
                return .updated(existing.eventIdentifier)
            } catch {
                // Fall through and write a new one.
            }
        }

        let event = EKEvent(eventStore: store)
        apply(entry, to: event, in: store)
        do {
            try store.save(event, span: .thisEvent, commit: true)
            return .added(event.eventIdentifier)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private static func apply(_ entry: Entry, to event: EKEvent, in store: EKEventStore) {
        let span = span(entry)
        event.title = title(entry)
        event.location = location(entry)
        event.notes = notes(entry)
        event.isAllDay = span.isAllDay
        event.startDate = span.start
        event.endDate = span.end
        event.calendar = store.defaultCalendarForNewEvents
    }
}
