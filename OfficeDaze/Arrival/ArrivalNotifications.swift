import Foundation
import UserNotifications

/// The alert itself: what it says, and the two buttons under it.
///
/// The desk id goes in the title because the title is the largest text iOS
/// will render on a lock screen, and reading the desk number at arm's length
/// without unlocking is the entire point of the app. Everything else is
/// supporting detail.
nonisolated enum ArrivalNotifications {

    enum Category: String {
        case booked = "arrival.booked"
        case unbooked = "arrival.unbooked"
        /// The evening nudge asking about a day already gone. Same two actions,
        /// wearing the past tense: "I'm here" is wrong at six in the evening
        /// about a morning that has been and gone.
        case nudgeConfirm = "nudge.confirm"
    }

    enum Action: String {
        /// Records the day. The geofence offers; the user confirms.
        case confirm = "arrival.confirm"
        case dismiss = "arrival.dismiss"
        /// Answers the evening question with a no, which stores the answer
        /// rather than nothing — so the row stops asking and the notification
        /// does not come back tomorrow about the same day.
        case decline = "nudge.decline"
    }

    enum UserInfo {
        static let officeID = "officeID"
        static let day = "day"
        static let bookingID = "bookingID"
    }

    /// What the notification will say, as plain strings — so the copy can be
    /// tested without a notification centre or a device.
    struct Content: Equatable, Sendable {
        var title: String
        var subtitle: String
        var body: String
        var category: Category
    }

    /// `3C-114` / `You're at Coleman` / `Level 3, Zone C` + the day
    /// count.
    ///
    /// With a desk, the title is the desk id and there is nothing to argue
    /// about: it is the whole point of the app in the largest text iOS renders.
    /// Without one it used to be "You're on site", which the subtitle says again
    /// in more detail a line later — the largest line on the alert spent
    /// repeating the second largest. The fact that actually matters when nothing
    /// is booked is where the month stands, so that goes in the title instead
    /// and the body carries the rest.
    ///
    /// `alreadyRecorded` is the day having been confirmed somewhere already —
    /// arriving at a second office, or coming back after tapping "I'm here".
    /// The count is still worth showing; the tail is not, because a day already
    /// recorded is already worth a whole day and the button cannot add to it.
    /// Two separate guards make that true, and the tail is a lie if either goes:
    /// `BookingStore.recordAttendance` refuses a row that would take one date
    /// past 1.0, and `Quota.calculate` caps each date at a day when it sums.
    /// Before the cap, the same tap credited the date twice and "tap to make it
    /// 5" was honoured by a count going to 6 — which is why the tail is dropped
    /// on the promise rather than on the arithmetic that happens to back it.
    static func content(
        officeName: String,
        desk: ArrivalRule.Booking?,
        attended: Double,
        target: Int,
        monthName: String,
        alreadyRecorded: Bool = false
    ) -> Content {
        let count = dayCount(attended: attended, target: target, monthName: monthName)
        let tail = alreadyRecorded ? nil : consequence(attended: attended)

        var lines: [String] = []
        if let desk {
            // Only what was actually read. A floor the capture could not make
            // out is absent from the line rather than an empty "Level ,".
            let place = [desk.floor.map(level), desk.zone.map { "Zone \($0)" }]
                .compactMap { $0 }
            if !place.isEmpty { lines.append(place.joined(separator: ", ")) }
            // `Day 4 of 7 for August — tap to make it 5`, as one line: the
            // figure and what the button will do to it belong together.
            lines.append([count, tail].compactMap { $0 }.joined(separator: " — "))
        } else {
            lines.append("No desk booked today.")
            if let tail { lines.append("\(tail.prefix(1).uppercased())\(tail.dropFirst()).") }
        }

        return Content(
            title: desk?.deskID ?? shortCount(attended: attended, target: target),
            subtitle: "You're at \(officeName)",
            body: lines.joined(separator: "\n"),
            category: desk == nil ? .unbooked : .booked
        )
    }

    /// A floor is free text: people type `Level 3`, the Coleman system prints
    /// `03`. A bare `03` on a lock screen says nothing, so it gets the word —
    /// but a value that already carries one must not become `Level Level 3`.
    static func level(_ floor: String) -> String {
        let trimmed = floor.trimmingCharacters(in: .whitespaces)
        let hasWord = trimmed.contains { $0.isLetter }
        return hasWord ? trimmed : "Level \(trimmed)"
    }

    /// `Day 4 of 7 for August`. The day being arrived at is not attended yet —
    /// it becomes day 5 only once the user confirms — so this counts what is
    /// already recorded.
    static func dayCount(attended: Double, target: Int, monthName: String) -> String {
        "Day \(number(attended)) of \(target) for \(monthName)"
    }

    /// The same figure without the month, for the title of the unbooked alert,
    /// where the subtitle is already carrying the place and the room is spent.
    static func shortCount(attended: Double, target: Int) -> String {
        "Day \(number(attended)) of \(target)"
    }

    /// `tap to make it 5`.
    ///
    /// The count above it is deliberately the figure *before* confirming, which
    /// is correct and reads as though turning up had already been counted — the
    /// one thing this app is careful never to claim. Naming the consequence
    /// fixes that, and doubles as a label for the button underneath.
    static func consequence(attended: Double) -> String {
        "tap to make it \(number(attended + 1))"
    }

    /// Pinned to en_GB, the way every `DateFormatter` in `Day` is, and for the
    /// same reason: every other word on this alert is hard-coded British
    /// English, so a figure that followed the device region produced "Day 4,5 of
    /// 7 for August" — an English sentence with a French decimal comma. It also
    /// made the copy tests depend on the region the simulator happened to be
    /// set to, green on an en_* host and red on a fr/de/es one.
    private static func number(_ value: Double) -> String {
        value.formatted(
            .number.precision(.fractionLength(0...1)).locale(Locale(identifier: "en_GB"))
        )
    }

    /// The two buttons. `confirm` is what makes attendance recordable from the
    /// lock screen without opening the app — and it is the only thing that
    /// records it, because the geofence never writes silently.
    static var categories: Set<UNNotificationCategory> {
        let confirm = UNNotificationAction(
            identifier: Action.confirm.rawValue,
            title: "I'm here",
            options: []
        )
        let dismiss = UNNotificationAction(
            identifier: Action.dismiss.rawValue,
            title: "Not today",
            options: []
        )
        // Same identifiers, past tense. The handler keys off the identifier, so
        // the evening question records through exactly the same path.
        let wasThere = UNNotificationAction(
            identifier: Action.confirm.rawValue,
            title: "I was there",
            options: []
        )
        let wasNot = UNNotificationAction(
            identifier: Action.decline.rawValue,
            title: "No",
            options: []
        )
        return [
            UNNotificationCategory(
                identifier: Category.booked.rawValue,
                actions: [confirm, dismiss],
                intentIdentifiers: []
            ),
            UNNotificationCategory(
                identifier: Category.unbooked.rawValue,
                actions: [confirm, dismiss],
                intentIdentifiers: []
            ),
            UNNotificationCategory(
                identifier: Category.nudgeConfirm.rawValue,
                actions: [wasThere, wasNot],
                intentIdentifiers: []
            ),
        ]
    }

    /// Unique per delivery, because the alert now repeats until the day is
    /// acknowledged.
    ///
    /// iOS treats a request whose identifier matches an already-delivered
    /// notification as an edit of that notification rather than a new one, so a
    /// per-day identifier would make the second arrival silently rewrite the
    /// first instead of alerting. The delivery time is what makes each one
    /// distinct; the ledger row it came from is what lets the previous one be
    /// withdrawn, so the lock screen holds one arrival rather than a stack.
    static func identifier(officeID: UUID, day: Day, at: Date) -> String {
        "arrival.\(officeID.uuidString).\(day).\(Int(at.timeIntervalSince1970))"
    }

    // MARK: What a tap means

    /// The outcome of a tapped button, decided from the payload alone — so the
    /// rule can be tested without a notification centre, a device, or a
    /// `UNNotificationResponse`, which has no initialiser anyone can call.
    enum Answer: Equatable, Sendable {
        case ignore
        case record(officeID: UUID, day: Day, bookingID: UUID?)
        case decline(bookingID: UUID)
    }

    /// The payload names one day. That day is an answer to the question the user
    /// actually read only if the notification carrying it was *delivered* on
    /// that day — which holds by construction for everything this app posts: an
    /// arrival alert is delivered the instant it is built, and the evening
    /// question is pinned to the evening of the day it names.
    ///
    /// Comparing against the delivery date rather than against today is the
    /// point, and it is not the obvious choice. An alert can sit unanswered on a
    /// lock screen for days, and Monday's arrival tapped on Wednesday is still
    /// Monday's arrival and must still record Monday — a "is this day recent?"
    /// guard would throw that away. What must not happen is the reverse: content
    /// built for Monday being re-delivered on Tuesday and answered as though it
    /// were Tuesday's question. Only the delivery date separates the two, and
    /// getting it wrong costs the day actually worked as well as the day wrongly
    /// written, because `recordAttendance`'s only date check is `day <= today`
    /// and a stale past day sails through it.
    static func answer(
        to action: String, userInfo: [AnyHashable: Any], delivered: Day
    ) -> Answer {
        guard let action = Action(rawValue: action) else { return .ignore }
        guard let officeText = userInfo[UserInfo.officeID] as? String,
              let officeID = UUID(uuidString: officeText),
              let dayText = userInfo[UserInfo.day] as? String,
              let day = CapturedBooking.day(from: dayText),
              day == delivered
        else { return .ignore }

        // Written as "" rather than omitted when there is no booking, so this
        // has to survive a string that is not a UUID, not merely a missing key.
        let bookingID = (userInfo[UserInfo.bookingID] as? String)
            .flatMap(UUID.init(uuidString:))

        switch action {
        case .confirm:
            return .record(officeID: officeID, day: day, bookingID: bookingID)
        case .decline:
            // Only the evening question offers No, and only ever about a
            // booking — there is nothing to write a no against without one.
            guard let bookingID else { return .ignore }
            return .decline(bookingID: bookingID)
        case .dismiss:
            return .ignore
        }
    }

    static func request(
        _ content: Content, officeID: UUID, day: Day, bookingID: UUID?, at: Date
    ) -> UNNotificationRequest {
        let notification = UNMutableNotificationContent()
        notification.title = content.title
        notification.subtitle = content.subtitle
        notification.body = content.body
        notification.categoryIdentifier = content.category.rawValue
        notification.sound = .default
        // Anyone walking into an office at nine has a Work Focus running, and a
        // default-level notification under a Focus is silently held back — so
        // the alert is least likely to arrive on precisely the mornings it was
        // written for. Time Sensitive breaks through, iOS labels it in the
        // header so the reason is visible, and it is honest about itself: this
        // is useful for the two minutes between the door and the desk and
        // worthless an hour later.
        //
        // **It does not work on this build.** The level needs the Time
        // Sensitive Notifications capability, and a personal team cannot have
        // it — Xcode refuses to make a profile: "Personal development teams do
        // not support the Time Sensitive Notifications capability." Without the
        // entitlement iOS quietly ignores the level rather than failing, so the
        // line is harmless and correct in waiting: adding the capability is all
        // it takes on a paid account. The review said this needed no
        // entitlement. It was wrong, and the app cannot have it today.
        notification.interruptionLevel = .timeSensitive
        notification.userInfo = [
            UserInfo.officeID: officeID.uuidString,
            UserInfo.day: day.description,
            UserInfo.bookingID: bookingID?.uuidString ?? "",
        ]
        // Nil trigger: deliver now. The region crossing is the trigger, and
        // handing iOS a CLRegion trigger here would monitor the region twice.
        return UNNotificationRequest(
            identifier: identifier(officeID: officeID, day: day, at: at),
            content: notification,
            trigger: nil
        )
    }
}
