import Foundation

/// How often the alert may fire. The design makes the once-per-day rule
/// visible and adjustable rather than hiding it.
nonisolated enum FireRate: String, CaseIterable, Sendable {
    /// Default. Spent once delivered — lunch runs do not re-fire.
    case firstArrivalOnly
    /// Every geofence crossing.
    case everyArrival
    /// Alerts once, exactly as `firstArrivalOnly` does, and additionally starts
    /// a Live Activity that persists on the lock screen and in the Dynamic
    /// Island until the desk booking ends.
    ///
    /// It is deliberately additive rather than a replacement: the notification
    /// is what carries the confirm action, and attendance is never written
    /// without one. A Live Activity on its own could only show the desk.
    case persistAllDay

    var title: String {
        switch self {
        case .firstArrivalOnly: "FIRST ARRIVAL ONLY"
        case .everyArrival: "EVERY ARRIVAL"
        case .persistAllDay: "PERSIST ALL DAY"
        }
    }

    var note: String {
        switch self {
        case .firstArrivalOnly: "SPENT ONCE DELIVERED. LUNCH RUNS DO NOT RE-FIRE."
        case .everyArrival: "EVERY GEOFENCE CROSSING"
        case .persistAllDay: "ALERTS ONCE, THEN HOLDS THE LOCK SCREEN UNTIL THE DESK ENDS"
        }
    }
}

/// What to do when the phone crosses a perimeter.
///
/// The whole implementation of "fires once" is the `ArrivalAlert` ledger: if a
/// row exists for today and this place, do nothing and return. No dwell time,
/// no exit events, no timers — the ledger is cheap, testable, and survives the
/// app being killed, which none of the clever alternatives do.
///
/// This is a pure function so the rule can be tested without a location
/// manager, a notification centre, or a store.
nonisolated enum ArrivalRule {

    struct DeskBooking: Equatable, Sendable {
        var id: UUID
        var placeID: UUID
        var day: Day
        var deskID: String
        var floor: String?
        /// When the desk is held until, which is what the Live Activity counts
        /// down to. Optional and defaulted so the rule's own tests, which do
        /// not care, keep their short call.
        var endsAt: Date?
        var endZoneID: String?
    }

    struct Input: Sendable {
        var day: Day
        var placeID: UUID
        /// Days a row already exists for, per place.
        var ledger: [(day: Day, placeID: UUID)]
        var deskBookings: [DeskBooking]
        /// Days attendance has already been recorded for.
        var attendedDays: Set<Day>
        var fireRate: FireRate
        var enabled: Bool

        init(
            day: Day, placeID: UUID,
            ledger: [(day: Day, placeID: UUID)] = [],
            deskBookings: [DeskBooking] = [],
            attendedDays: Set<Day> = [],
            fireRate: FireRate = .firstArrivalOnly,
            enabled: Bool = true
        ) {
            self.day = day
            self.placeID = placeID
            self.ledger = ledger
            self.deskBookings = deskBookings
            self.attendedDays = attendedDays
            self.fireRate = fireRate
            self.enabled = enabled
        }
    }

    enum Silence: Equatable, Sendable {
        case disabled
        /// A row already exists for today and this place.
        case alreadyFiredToday
        /// The day is already on the count; there is nothing left to offer.
        case alreadyAttended
    }

    enum Decision: Equatable, Sendable {
        case doNothing(Silence)
        /// A desk is booked here today. Offer to record the day against it.
        case offerBooked(DeskBooking)
        /// Nothing booked. The prompt inverts: offer to log the day anyway.
        case offerUnbooked
    }

    static func decide(_ input: Input) -> Decision {
        guard input.enabled else { return .doNothing(.disabled) }

        // Step 2 of the design's sequence, and the entire fire-once rule.
        if input.fireRate != .everyArrival,
           input.ledger.contains(where: { $0.day == input.day && $0.placeID == input.placeID }) {
            return .doNothing(.alreadyFiredToday)
        }

        // Nothing left to offer if the day is already counted — re-offering
        // would invite a double entry.
        if input.attendedDays.contains(input.day) {
            return .doNothing(.alreadyAttended)
        }

        // Step 3: is a desk booked here today?
        if let booking = input.deskBookings.first(
            where: { $0.placeID == input.placeID && $0.day == input.day }
        ) {
            return .offerBooked(booking)
        }
        return .offerUnbooked
    }

    /// Whether a decision should write a ledger row.
    ///
    /// Both offers do, so the inverted prompt also fires only once — a day you
    /// declined to log should not ask again at 14:00.
    static func writesLedgerRow(_ decision: Decision) -> Bool {
        switch decision {
        case .doNothing: false
        case .offerBooked, .offerUnbooked: true
        }
    }
}
