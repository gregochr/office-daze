import Foundation

/// What to do when the phone crosses an office perimeter.
///
/// A pure function over a projection of the store: no CoreLocation, no
/// SwiftData, no notification centre. This is the rule the whole feature turns
/// on, it has five outcomes, and most of them are easy to get subtly wrong —
/// so it is worth being able to test without a device walking through a door.
nonisolated enum ArrivalRule {

    /// How long an office stays quiet after alerting.
    ///
    /// This is not a fire-once rule. The alert repeats on every arrival until
    /// the day is acknowledged; this only absorbs a perimeter crossed several
    /// times in a minute by GPS drift rather than by walking, which would
    /// otherwise deliver a burst of identical alerts — and a burst of identical
    /// alerts is how a notification gets switched off for good. Nobody leaves a
    /// building and comes back inside ten minutes.
    static let settleWindow: TimeInterval = 10 * 60

    struct Booking: Equatable, Sendable {
        var id: UUID
        var officeID: UUID
        var day: Day
        var deskID: String
        var floor: String?
        var zone: String?
    }

    /// A day already recorded at an office. This is the acknowledgement, and
    /// the only thing that stops the alert for the day.
    struct Attendance: Equatable, Sendable {
        var day: Day
        var officeID: UUID

        init(day: Day, officeID: UUID) {
            self.day = day
            self.officeID = officeID
        }
    }

    struct Input: Sendable {
        var officeID: UUID
        var day: Day
        var attendance: [Attendance]
        /// When this office last alerted today, if it has.
        var lastAlert: Date?
        var now: Date
        var bookings: [Booking]
        var alertEnabled: Bool

        init(
            officeID: UUID,
            day: Day,
            attendance: [Attendance] = [],
            lastAlert: Date? = nil,
            now: Date = .now,
            bookings: [Booking] = [],
            alertEnabled: Bool = true
        ) {
            self.officeID = officeID
            self.day = day
            self.attendance = attendance
            self.lastAlert = lastAlert
            self.now = now
            self.bookings = bookings
            self.alertEnabled = alertEnabled
        }
    }

    enum Decision: Equatable, Sendable {
        /// The day is already recorded at this office, so there is nothing left
        /// to ask for.
        case acknowledged
        /// Alerted moments ago. The perimeter is being crossed by drift rather
        /// than by walking.
        case settling
        /// The office's alert is switched off.
        case disabled
        /// Post the alert with the desk on it.
        case desk(Booking)
        /// Turned up with nothing booked. Post the inverted prompt — the day
        /// still counts if the user says it does.
        case nothingBooked
    }

    static func decide(_ input: Input) -> Decision {
        guard input.alertEnabled else { return .disabled }

        // The gate is the acknowledgement, not a record of having alerted
        // once. An arrival the user has not acted on is an arrival worth
        // repeating: the desk number is what they came for, and a single
        // notification missed on the walk in is gone.
        let acknowledged = input.attendance.contains {
            $0.day == input.day && $0.officeID == input.officeID
        }
        guard !acknowledged else { return .acknowledged }

        if let lastAlert = input.lastAlert,
           input.now.timeIntervalSince(lastAlert) < settleWindow {
            return .settling
        }

        let booking = input.bookings.first {
            $0.day == input.day && $0.officeID == input.officeID
        }
        return booking.map(Decision.desk) ?? .nothingBooked
    }
}
