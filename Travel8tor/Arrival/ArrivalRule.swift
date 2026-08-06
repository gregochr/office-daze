import Foundation

/// What to do when the phone crosses an office perimeter.
///
/// A pure function over a projection of the store: no CoreLocation, no
/// SwiftData, no notification centre. This is the rule the whole feature turns
/// on, it has four outcomes, and three of them are easy to get subtly wrong —
/// so it is worth being able to test without a device walking through a door.
nonisolated enum ArrivalRule {

    struct Booking: Equatable, Sendable {
        var id: UUID
        var officeID: UUID
        var day: Day
        var deskID: String
        var floor: String?
        var zone: String?
    }

    struct Input: Sendable {
        var officeID: UUID
        var day: Day
        /// One row per office per day. The entire fire-once implementation.
        var ledger: [ArrivalAlert.Row]
        var bookings: [Booking]
        var alertEnabled: Bool

        init(
            officeID: UUID,
            day: Day,
            ledger: [ArrivalAlert.Row] = [],
            bookings: [Booking] = [],
            alertEnabled: Bool = true
        ) {
            self.officeID = officeID
            self.day = day
            self.ledger = ledger
            self.bookings = bookings
            self.alertEnabled = alertEnabled
        }
    }

    enum Decision: Equatable, Sendable {
        /// A row already exists for today and this office. Do nothing at all —
        /// no notification, no second ledger row.
        case alreadyFired
        /// The office's alert is switched off.
        case disabled
        /// Post the alert with the desk on it, and write the ledger row.
        case desk(Booking)
        /// Turned up with nothing booked. Post the inverted prompt — the day
        /// still counts if the user says it does — and write the ledger row
        /// anyway, so this also fires only once.
        case nothingBooked
    }

    static func decide(_ input: Input) -> Decision {
        guard input.alertEnabled else { return .disabled }

        // First, and cheaply. Not a dwell timer, not an exit event: a ledger
        // row is a fact that survives the app being killed, which is the only
        // thing that reliably happens between one region crossing and the next.
        let fired = input.ledger.contains {
            $0.day == input.day && $0.officeID == input.officeID
        }
        guard !fired else { return .alreadyFired }

        let booking = input.bookings.first {
            $0.day == input.day && $0.officeID == input.officeID
        }
        return booking.map(Decision.desk) ?? .nothingBooked
    }
}

nonisolated extension ArrivalAlert {
    /// The ledger as the rule sees it — two fields, no SwiftData.
    struct Row: Equatable, Sendable {
        var day: Day
        var officeID: UUID

        init(day: Day, officeID: UUID) {
            self.day = day
            self.officeID = officeID
        }
    }
}
