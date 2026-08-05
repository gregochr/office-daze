import EventKit
import Foundation

/// The desk screen's CALENDAR action.
///
/// Write-only access — `requestWriteOnlyAccessToEvents` — because adding an
/// event is all this does. Full access would let the app read every event in
/// the calendar, which it has no use for, and iOS shows the user a
/// correspondingly heavier prompt.
///
/// The cost of write-only is that the app cannot read back what it wrote: there
/// is no fetching the event later to update or delete it, and no noticing that
/// the user deleted it by hand. So the booking records the identifier it was
/// given and the button says so; a second tap does not write a second event.
/// That asymmetry is the whole reason `Outcome` distinguishes `added` from
/// `alreadyAdded`.
@MainActor
enum CalendarWriter {

    enum Outcome: Equatable {
        case added
        case alreadyAdded
        case denied
        case noCalendar
        case failed(String)

        /// What the desk screen prints under the two actions.
        var message: String {
            switch self {
            case .added: "ADDED TO CALENDAR."
            case .alreadyAdded: "ALREADY IN THE CALENDAR."
            case .denied: "CALENDAR ACCESS REFUSED. GRANT IT IN SETTINGS."
            case .noCalendar: "NO WRITABLE CALENDAR ON THIS DEVICE."
            case .failed(let reason): "COULD NOT WRITE: \(reason.uppercased())"
            }
        }

        var isProblem: Bool {
            switch self {
            case .added, .alreadyAdded: false
            case .denied, .noCalendar, .failed: true
            }
        }
    }

    /// What a desk booking looks like to the calendar. A projection rather than
    /// the `Booking` itself, so the formatting below is testable without a
    /// store — and so nothing here can accidentally write to the model.
    struct Entry: Equatable {
        var deskID: String
        var placeName: String
        var address: String?
        var postcode: String?
        var floor: String?
        var zone: String?
        var startsAt: Date
        var endsAt: Date
        var timeZone: TimeZone
    }

    /// Natural case, deliberately. Every label *in* the app is upper case; this
    /// string leaves the app and lands in a calendar the user reads beside
    /// meetings written by other people, where SHOUTING would be noise.
    static func title(_ entry: Entry) -> String {
        "Desk \(entry.deskID.uppercased()) · \(entry.placeName)"
    }

    static func location(_ entry: Entry) -> String? {
        let parts = [entry.address, entry.postcode].compactMap { $0 }
        let full = ([entry.placeName] + parts).joined(separator: ", ")
        return full.isEmpty ? nil : full
    }

    /// Only what was actually read. A floor the capture could not make out is
    /// absent from the note rather than appearing as an empty line.
    static func notes(_ entry: Entry) -> String? {
        var lines: [String] = []
        if let floor = entry.floor { lines.append("Floor: \(Abbreviate.level(floor).capitalized)") }
        if let zone = entry.zone { lines.append("Zone: \(zone.uppercased())") }
        lines.append("Added by Travel8tor.")
        return lines.joined(separator: "\n")
    }

    /// Asks for access if it has not been asked for, then writes. Returns the
    /// event identifier alongside the outcome so the caller can record it.
    static func add(
        _ entry: Entry, existingEventID: String?, store: EKEventStore = EKEventStore()
    ) async -> (Outcome, eventID: String?) {
        if let existingEventID { return (.alreadyAdded, existingEventID) }

        let granted: Bool
        do {
            granted = try await store.requestWriteOnlyAccessToEvents()
        } catch {
            return (.failed(error.localizedDescription), nil)
        }
        guard granted else { return (.denied, nil) }

        guard let calendar = store.defaultCalendarForNewEvents else {
            return (.noCalendar, nil)
        }

        let event = EKEvent(eventStore: store)
        event.calendar = calendar
        event.title = title(entry)
        event.location = location(entry)
        event.notes = notes(entry)
        event.startDate = entry.startsAt
        event.endDate = entry.endsAt
        event.timeZone = entry.timeZone

        do {
            try store.save(event, span: .thisEvent, commit: true)
            return (.added, event.eventIdentifier)
        } catch {
            return (.failed(error.localizedDescription), nil)
        }
    }
}
