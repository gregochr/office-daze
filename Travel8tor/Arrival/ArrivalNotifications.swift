import Foundation
import UserNotifications

/// The notification the geofence posts, and the actions that answer it.
///
/// The alert is an *offer*, never a record. Turning up is confirmed by tapping
/// an action; nothing is written to the count until then. A geofence hit at the
/// wrong building, or walking past on a Sunday, must not quietly move the
/// figure.
nonisolated enum ArrivalNotifications {

    enum Category: String {
        case booked = "t8.arrival.booked"
        case unbooked = "t8.arrival.unbooked"
    }

    enum Action: String {
        case confirm = "t8.arrival.confirm"
        case decline = "t8.arrival.decline"
    }

    /// Carried on the notification so the action handler knows what it is
    /// confirming after the app has been relaunched.
    enum UserInfo {
        static let placeID = "placeID"
        static let bookingID = "bookingID"
        static let day = "day"
    }

    static func categories(copy: (T8Label) -> String) -> Set<UNNotificationCategory> {
        let confirm = UNNotificationAction(
            identifier: Action.confirm.rawValue,
            title: copy(.confirmArrival),
            options: []
        )
        let decline = UNNotificationAction(
            identifier: Action.decline.rawValue,
            title: "NOT TODAY",
            options: [.destructive]
        )

        return [
            UNNotificationCategory(
                identifier: Category.booked.rawValue,
                actions: [confirm, decline],
                intentIdentifiers: []
            ),
            UNNotificationCategory(
                identifier: Category.unbooked.rawValue,
                actions: [confirm, decline],
                intentIdentifiers: []
            ),
        ]
    }

    /// The alert for a day with a desk booked. Mirrors screen 4b: the place,
    /// the desk id, and where in the building it is.
    static func bookedContent(
        place: Place, booking: ArrivalRule.DeskBooking, day: Day,
        shortfall: Int, target: Int, dayNumber: Int,
        copy: (T8Label) -> String
    ) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = copy(.targetAcquired)

        var lines = ["\(place.name.uppercased()) ▪ \(booking.deskID.uppercased())"]
        var where_ : [String] = []
        if let floor = booking.floor { where_.append(Abbreviate.level(floor)) }
        if !where_.isEmpty { lines.append(where_.joined(separator: "  ")) }
        lines.append(
            "DAY \(String(format: "%02d", dayNumber)) OF \(String(format: "%02d", target))"
        )
        content.body = lines.joined(separator: "\n")

        content.categoryIdentifier = Category.booked.rawValue
        content.userInfo = [
            UserInfo.placeID: place.id.uuidString,
            UserInfo.bookingID: booking.id.uuidString,
            UserInfo.day: day.description,
        ]
        content.interruptionLevel = .timeSensitive
        return content
    }

    /// The inverted prompt: arrive with nothing booked and the alert offers to
    /// log the day rather than reporting a desk.
    static func unbookedContent(
        place: Place, day: Day, copy: (T8Label) -> String
    ) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = "NO BOOKING ▪ \(place.name.uppercased())"
        content.body = copy(.logThisDay)
        content.categoryIdentifier = Category.unbooked.rawValue
        content.userInfo = [
            UserInfo.placeID: place.id.uuidString,
            UserInfo.day: day.description,
        ]
        content.interruptionLevel = .timeSensitive
        return content
    }
}

nonisolated extension T8Label {
    /// The two labels the notification actions need. Same matched-pair rule as
    /// everything else on screen.
    static let arrivalLabels: [T8Label] = [.confirmArrival, .logThisDay]
}
