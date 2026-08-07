import Foundation
import UserNotifications

/// The one notification the app sends that nobody asked for at the moment it
/// arrives. It has two things to say, and says at most one of them.
///
/// The first is the original: tomorrow is a working day, nothing is booked, and
/// the month is behind. All three, or it stays quiet — a reminder that fires
/// when the month is already met is a reminder that gets switched off, and then
/// the one that mattered never arrives either.
///
/// The second exists because attendance can be lost silently. A day booked,
/// worked, and never confirmed counts for nothing, and until now nothing asked:
/// this notification tested tomorrow, which is a prompt to book rather than a
/// prompt to confirm. Today's unanswered day comes first when there is one —
/// a fact about to be lost outranks a plan not yet made.
nonisolated enum EveningNudge {

    /// Today's booking that nothing has been said about, with what the alert
    /// needs to name it and what the buttons need to record it.
    struct Unconfirmed: Equatable, Sendable {
        var day: Day
        var officeID: UUID
        var officeName: String
        var bookingID: UUID
        var deskID: String
    }

    struct Input: Sendable {
        var tomorrow: Day
        var isWorkingDay: Bool
        var hasBookingTomorrow: Bool
        /// Days still needed this month after everything already booked ahead.
        var shortfall: Double
        /// A desk booked for today with no attendance recorded against it and
        /// no answer given either way.
        var unconfirmedToday: Unconfirmed?

        init(
            tomorrow: Day,
            isWorkingDay: Bool,
            hasBookingTomorrow: Bool,
            shortfall: Double,
            unconfirmedToday: Unconfirmed? = nil
        ) {
            self.tomorrow = tomorrow
            self.isWorkingDay = isWorkingDay
            self.hasBookingTomorrow = hasBookingTomorrow
            self.shortfall = shortfall
            self.unconfirmedToday = unconfirmedToday
        }
    }

    enum Decision: Equatable, Sendable {
        case quiet
        case bookTomorrow
        case confirmToday(Unconfirmed)
    }

    static func decide(_ input: Input) -> Decision {
        // Today first. A day worked and never recorded is a fact on its way out
        // of the app; a day not yet booked is a plan, and plans keep.
        if let unconfirmed = input.unconfirmedToday { return .confirmToday(unconfirmed) }
        return shouldNudge(input) ? .bookTomorrow : .quiet
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

    /// The same register: a question, and the reason it is being asked. It does
    /// not assume the day was worked — the desk was booked, which is a
    /// different thing, and assuming would make the one record the app cannot
    /// reconstruct into a guess.
    static func confirmMessage(_ unconfirmed: Unconfirmed) -> (title: String, body: String) {
        (
            title: "Were you at \(unconfirmed.officeName) today?",
            body: "Desk \(unconfirmed.deskID) was booked for today. "
                + "A day only counts once you say you were there."
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
    ///
    /// `answering` carries the booking the confirm branch is asking about. With
    /// it the notification takes the arrival alert's own category and user info,
    /// so the buttons record the day from the lock screen through the handler
    /// that already exists.
    static func request(
        at time: DateComponents, title: String, body: String,
        answering unconfirmed: Unconfirmed? = nil
    ) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if let unconfirmed {
            content.categoryIdentifier = ArrivalNotifications.Category.nudgeConfirm.rawValue
            content.userInfo = [
                ArrivalNotifications.UserInfo.officeID: unconfirmed.officeID.uuidString,
                ArrivalNotifications.UserInfo.day: unconfirmed.day.description,
                ArrivalNotifications.UserInfo.bookingID: unconfirmed.bookingID.uuidString,
            ]
        } else {
            content.categoryIdentifier = category
        }
        return UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: time, repeats: true)
        )
    }
}
