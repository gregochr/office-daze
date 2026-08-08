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
        // Pinned to en_GB, like every `DateFormatter` in `Day`. The rest of this
        // sentence is hard-coded British English, so a figure that follows the
        // device region reads "2,5 days still to go" on a French phone — an
        // English sentence with a French decimal comma. It also made the copy
        // tests pass or fail on whatever region the simulator was set to.
        let days = shortfall.formatted(
            .number.precision(.fractionLength(0...1)).locale(Locale(identifier: "en_GB"))
        )
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

    /// The two branches want two different triggers, and the difference is the
    /// whole of a bug that used to record attendance against the wrong date.
    ///
    /// **`bookTomorrow` repeats daily.** The app is not running most evenings,
    /// and a schedule that depends on the app being awake to set it is a
    /// schedule that stops. The *decision* is therefore re-made whenever the app
    /// is awake, and between those moments a nudge that names a date now gone by
    /// is still better than silence. It carries no `userInfo` and its category
    /// has no buttons, so the worst a stale redelivery can do is read oddly.
    ///
    /// **`confirmToday` must not repeat**, and here staleness is not cosmetic.
    /// Its buttons write attendance straight from the payload, and the payload
    /// names one day. A repeating trigger redelivers "Were you at Coleman
    /// today?" the following evening still carrying yesterday's day; "I was
    /// there" then records the wrong date, in the one record this app says has
    /// no other copy — and the day actually worked stays unrecorded, so a single
    /// tap puts two days of the month wrong.
    ///
    /// So the question is pinned: a one-shot trigger at an absolute instant, the
    /// evening of the very day it asks about. The alternative considered was to
    /// keep the repeat and have the handler resolve "the unconfirmed day" from
    /// the store at tap time. That was rejected because it fixes the write and
    /// leaves the reading wrong — the alert would still say "today" about a day
    /// gone, and the user would still be answering a question they were not
    /// asked. (The handler is hardened as well, in `ArrivalNotifications.answer`:
    /// a *delivered* notification can sit on a lock screen for days.)
    ///
    /// If the pinned instant has already passed, iOS never delivers it. That is
    /// the right answer rather than a lost nudge: the question was about today,
    /// and today's evening has gone.
    static func request(
        at time: DateComponents, title: String, body: String,
        answering unconfirmed: Unconfirmed? = nil,
        in zone: TimeZone = .autoupdatingCurrent
    ) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let trigger: UNCalendarNotificationTrigger
        if let unconfirmed {
            content.categoryIdentifier = ArrivalNotifications.Category.nudgeConfirm.rawValue
            content.userInfo = [
                ArrivalNotifications.UserInfo.officeID: unconfirmed.officeID.uuidString,
                ArrivalNotifications.UserInfo.day: unconfirmed.day.description,
                ArrivalNotifications.UserInfo.bookingID: unconfirmed.bookingID.uuidString,
            ]
            trigger = UNCalendarNotificationTrigger(
                dateMatching: evening(of: unconfirmed.day, at: time, in: zone),
                repeats: false
            )
        } else {
            content.categoryIdentifier = category
            trigger = UNCalendarNotificationTrigger(
                dateMatching: daily(time, in: zone), repeats: true
            )
        }
        return UNNotificationRequest(
            identifier: identifier, content: content, trigger: trigger
        )
    }

    /// The chosen hour and minute, every day, with the calendar and zone stated
    /// rather than left to be inferred.
    ///
    /// `UNCalendarNotificationTrigger` matches bare components against the
    /// device's current calendar, so this changes nothing about when it fires —
    /// it makes the components say which clock the numbers are on. That is
    /// precisely the fact the settings screen used to get wrong: it read the
    /// picker through `Day.calendar`, which is pinned to UTC, and handed the UTC
    /// hour to a trigger that fires in local time.
    static func daily(
        _ time: DateComponents, in zone: TimeZone = .autoupdatingCurrent
    ) -> DateComponents {
        var parts = DateComponents(hour: time.hour ?? 18, minute: time.minute ?? 0)
        parts.calendar = Day.localCalendar(zone)
        parts.timeZone = zone
        return parts
    }

    /// One evening and no other: the day being asked about, at the chosen time,
    /// on the device's clock. Carrying the year, month and day is what makes the
    /// trigger a single instant instead of a daily match.
    static func evening(
        of day: Day, at time: DateComponents, in zone: TimeZone = .autoupdatingCurrent
    ) -> DateComponents {
        var parts = DateComponents(
            year: day.year, month: day.month, day: day.day,
            hour: time.hour ?? 18, minute: time.minute ?? 0
        )
        parts.calendar = Day.localCalendar(zone)
        parts.timeZone = zone
        return parts
    }
}
