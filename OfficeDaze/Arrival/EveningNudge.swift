import Foundation
import UserNotifications

/// The one nudge the app sends that nobody asked for at the moment it arrives:
/// tomorrow is a working day, nothing is booked, and the month is behind.
///
/// All three conditions, or it stays quiet. A reminder that fires when the
/// month is already met is a reminder that gets switched off, and then the one
/// that mattered never arrives either.
nonisolated enum EveningNudge {

    struct Input: Sendable {
        var tomorrow: Day
        var isWorkingDay: Bool
        var hasBookingTomorrow: Bool
        /// Days still needed this month after everything already booked ahead.
        var shortfall: Double

        init(
            tomorrow: Day,
            isWorkingDay: Bool,
            hasBookingTomorrow: Bool,
            shortfall: Double
        ) {
            self.tomorrow = tomorrow
            self.isWorkingDay = isWorkingDay
            self.hasBookingTomorrow = hasBookingTomorrow
            self.shortfall = shortfall
        }
    }

    static func shouldNudge(_ input: Input) -> Bool {
        input.isWorkingDay && !input.hasBookingTomorrow && input.shortfall > 0
    }

    /// Says what is true and stops. No exclamation, no streak, no guilt — the
    /// number Office Daze shows is the user's own record kept in good faith,
    /// not a policy score, and the copy should not pretend otherwise.
    static func message(shortfall: Double, tomorrow: Day) -> (title: String, body: String) {
        let days = shortfall.formatted(.number.precision(.fractionLength(0...1)))
        let noun = shortfall == 1 ? "day" : "days"
        return (
            title: "No desk booked for tomorrow",
            body: "\(days) \(noun) still to go this month. \(tomorrow.mediumText) is a working day."
        )
    }

    static let identifier = "nudge.evening"
    static let category = "nudge.evening"

    /// A calendar trigger repeating daily at the chosen time, rather than one
    /// notification scheduled each evening: the app is not running most
    /// evenings, and a schedule that depends on the app being awake to set it
    /// is a schedule that stops.
    ///
    /// The consequence is that the *decision* has to happen when it fires
    /// rather than when it is scheduled, which is why the app re-evaluates and
    /// withdraws on launch.
    static func request(at time: DateComponents, title: String, body: String) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.categoryIdentifier = category
        content.sound = .default
        return UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: time, repeats: true)
        )
    }
}
