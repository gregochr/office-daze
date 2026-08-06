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
    }

    enum Action: String {
        /// Records the day. The geofence offers; the user confirms.
        case confirm = "arrival.confirm"
        case dismiss = "arrival.dismiss"
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
    static func content(
        officeName: String,
        desk: ArrivalRule.Booking?,
        attended: Double,
        target: Int,
        monthName: String
    ) -> Content {
        var lines: [String] = []
        if let desk {
            // Only what was actually read. A floor the capture could not make
            // out is absent from the line rather than an empty "Level ,".
            let place = [desk.floor.map(level), desk.zone.map { "Zone \($0)" }]
                .compactMap { $0 }
            if !place.isEmpty { lines.append(place.joined(separator: ", ")) }
        } else {
            lines.append("No desk booked today.")
        }
        lines.append(dayCount(attended: attended, target: target, monthName: monthName))

        return Content(
            title: desk?.deskID ?? "You're on site",
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
        let days = attended.formatted(.number.precision(.fractionLength(0...1)))
        return "Day \(days) of \(target) for \(monthName)"
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

    static func request(
        _ content: Content, officeID: UUID, day: Day, bookingID: UUID?, at: Date
    ) -> UNNotificationRequest {
        let notification = UNMutableNotificationContent()
        notification.title = content.title
        notification.subtitle = content.subtitle
        notification.body = content.body
        notification.categoryIdentifier = content.category.rawValue
        notification.sound = .default
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
