import Foundation
import SwiftData

// Two decisions worth stating, because both look wrong to a JPA reflex.
//
// 1. Entities reference each other by UUID, not by SwiftData relationships.
//    The data-model document specifies `officeId`, `bookingId?`, `captureId?`
//    as ids, and it keeps the pure rules in Domain/ free of any persistence
//    type — `Quota` never imports SwiftData.
//
// 2. Days are stored as `Date` at midnight UTC, not as the `Day` struct.
//    SwiftData can persist Codable structs, but only stored properties of
//    primitive types work reliably inside `#Predicate`. Storing a Date keeps
//    fetches and sorts straightforward; the `Day` accessors below are the
//    bridge, and nothing outside this file should touch the raw Dates.
//
// Every property has a default value. SwiftData requires it for lightweight
// migration, and it is why the initialisers repeat what the declarations say.

/// A building with a perimeter. The user adds these by hand.
@Model
final class Office {
    var id: UUID = UUID()
    var name: String = ""
    var address: String = ""
    var postcode: String = ""
    var latitude: Double = 0
    var longitude: Double = 0
    var radiusMetres: Double = 50
    /// One of `OfficeColours.palette`.
    var colourHex: String = OfficeColours.palette[0]
    var alertEnabled: Bool = true
    /// What the booking system calls this building, as printed, for every name
    /// that is not the one the user typed — "Coleman, London" for an office
    /// saved as "Euroclear London".
    ///
    /// Written by answering the capture sheet's question rather than by typing
    /// here: the answer is already the thing worth remembering, and asking the
    /// same question after it has been answered is the app failing to listen.
    var aliases: [String] = []

    init(
        id: UUID = UUID(),
        name: String,
        address: String,
        postcode: String,
        latitude: Double = 0,
        longitude: Double = 0,
        radiusMetres: Double = 50,
        colourHex: String,
        alertEnabled: Bool = true,
        aliases: [String] = []
    ) {
        self.id = id
        self.name = name
        self.address = address
        self.postcode = postcode
        self.latitude = latitude
        self.longitude = longitude
        self.radiusMetres = radiusMetres
        self.colourHex = colourHex
        self.alertEnabled = alertEnabled
        self.aliases = aliases
    }

    /// Whether there is a point to draw a perimeter around. 0,0 is the
    /// Atlantic, and it is what an office the geocoder could not find holds —
    /// so it is the absence, not a location.
    var isLocated: Bool { latitude != 0 || longitude != 0 }
}

nonisolated enum BookingSource: String, Codable, Sendable {
    case capture, manual
}

/// One desk, one office, one day. No `kind` discriminator: there is only one
/// kind of booking in this app, and the previous version's rail and stay cases
/// are gone for good.
@Model
final class DeskBooking {
    var id: UUID = UUID()
    var officeID: UUID = UUID()
    var date: Date = Date.distantPast
    var deskID: String = ""
    var floor: String?
    var zone: String?
    /// Wall-clock, as printed — `08:00`. Strings rather than Dates because
    /// there is no timezone handling here and a time of day is not an instant.
    var startTime: String?
    var endTime: String?
    var source: BookingSource = BookingSource.capture
    /// Field names the model would not commit to. Non-empty means the row
    /// shows a "needs checking" marker. A field named here has no stored
    /// value — that is the invariant the whole never-guess rule rests on.
    var unsureFields: [String] = []
    var captureID: UUID?
    /// The EventKit identifier of the calendar entry this booking was written
    /// to, if it has been. Held because write-only access cannot read events
    /// back — without recording it here, a second tap of Add to calendar would
    /// write a twin and the app would have no way to know.
    var calendarEventID: String?

    init(
        id: UUID = UUID(),
        officeID: UUID,
        day: Day,
        deskID: String,
        floor: String? = nil,
        zone: String? = nil,
        startTime: String? = nil,
        endTime: String? = nil,
        source: BookingSource,
        unsureFields: [String] = [],
        captureID: UUID? = nil
    ) {
        self.id = id
        self.officeID = officeID
        self.date = day.startOfDayUTC
        self.deskID = deskID
        self.floor = floor
        self.zone = zone
        self.startTime = startTime
        self.endTime = endTime
        self.source = source
        self.unsureFields = unsureFields
        self.captureID = captureID
    }

    var day: Day {
        get { Day(of: date) }
        set { date = newValue.startOfDayUTC }
    }

    var needsChecking: Bool { !unsureFields.isEmpty }

    /// `09:00 – 17:00`, or nothing when neither end was read.
    var hoursText: String? {
        switch (startTime, endTime) {
        case (let start?, let end?): "\(start) – \(end)"
        case (let start?, nil): start
        case (nil, let end?): "until \(end)"
        case (nil, nil): nil
        }
    }
}

nonisolated enum AttendanceSource: String, Codable, Sendable {
    case geofence, manual
}

/// The only entity that counts toward the eight. Separate from `DeskBooking`
/// because the two come apart in both directions: you can book a desk and not
/// go, and you can go without booking. Never written without the user
/// confirming — the geofence offers, it does not record.
@Model
final class AttendanceDay {
    var id: UUID = UUID()
    var date: Date = Date.distantPast
    var officeID: UUID?
    var source: AttendanceSource = AttendanceSource.manual
    /// 1.0 or 0.5.
    var fraction: Double = 1.0
    /// Nil for a day you turned up without a booking — which is exactly what
    /// makes the inverted arrival prompt recordable.
    var bookingID: UUID?

    init(
        id: UUID = UUID(),
        day: Day,
        officeID: UUID? = nil,
        source: AttendanceSource,
        fraction: Double = 1.0,
        bookingID: UUID? = nil
    ) {
        self.id = id
        self.date = day.startOfDayUTC
        self.officeID = officeID
        self.source = source
        self.fraction = fraction
        self.bookingID = bookingID
    }

    var day: Day {
        get { Day(of: date) }
        set { date = newValue.startOfDayUTC }
    }
}

/// A day you intend to be on prem with no desk reserved — a workshop, a
/// meeting, a visit to another site.
///
/// Neither of the two it sits between. Not an `AttendanceDay`, because that is
/// a day already worked and the only thing the target is measured against; a
/// day still ahead recorded as attended makes the gauge claim days that have
/// not happened. Not a `DeskBooking`, because that would have to carry a desk
/// number the arrival alert would then display, and a made-up desk number is
/// the one thing that alert must never show.
///
/// It counts toward the forecast exactly as a booking does, and toward nothing
/// else. Once the day arrives, turning up is what converts it — the arrival
/// alert offers, as it does for any day with nothing booked.
@Model
final class PlannedDay {
    var id: UUID = UUID()
    var date: Date = Date.distantPast
    var officeID: UUID = UUID()

    init(id: UUID = UUID(), day: Day, officeID: UUID) {
        self.id = id
        self.date = day.startOfDayUTC
        self.officeID = officeID
    }

    var day: Day {
        get { Day(of: date) }
        set { date = newValue.startOfDayUTC }
    }
}

nonisolated enum LeaveKind: String, Codable, Sendable {
    case annual, bankHoliday, sick
}

/// A day off. Half-days matter: a half-day off is still a day you could have
/// been on prem, so it only takes half a day off the target.
@Model
final class LeaveDay {
    var id: UUID = UUID()
    var date: Date = Date.distantPast
    var fraction: Double = 1.0
    var kind: LeaveKind = LeaveKind.annual

    init(id: UUID = UUID(), day: Day, fraction: Double = 1.0, kind: LeaveKind = .annual) {
        self.id = id
        self.date = day.startOfDayUTC
        self.fraction = fraction
        self.kind = kind
    }

    var day: Day {
        get { Day(of: date) }
        set { date = newValue.startOfDayUTC }
    }
}

/// One row per delivered alert. Not a fire-once gate — that is an
/// `AttendanceDay` now — but the record of when this office last alerted today,
/// which is what the settle window measures and what says which notification to
/// take off the lock screen before posting the next.
///
/// A stored row rather than anything in memory, because it survives the app
/// being killed, which is the only thing that reliably happens between one
/// region crossing and the next.
@Model
final class ArrivalAlert {
    var id: UUID = UUID()
    var date: Date = Date.distantPast
    var officeID: UUID = UUID()
    var deliveredAt: Date = Date.distantPast

    init(id: UUID = UUID(), day: Day, officeID: UUID, deliveredAt: Date) {
        self.id = id
        self.date = day.startOfDayUTC
        self.officeID = officeID
        self.deliveredAt = deliveredAt
    }

    var day: Day {
        get { Day(of: date) }
        set { date = newValue.startOfDayUTC }
    }
}

nonisolated enum CaptureStatus: String, Codable, Sendable {
    case pending, parsed, failed
}

/// Keeps the original so "view original screenshot" works, and gives a monthly
/// call count and cost without instrumenting anything else.
@Model
final class Capture {
    var id: UUID = UUID()
    var receivedAt: Date = Date.distantPast
    @Attribute(.externalStorage) var asset: Data?
    var status: CaptureStatus = CaptureStatus.pending
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var bookingID: UUID?

    init(
        id: UUID = UUID(),
        receivedAt: Date,
        asset: Data? = nil,
        status: CaptureStatus = .pending,
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        bookingID: UUID? = nil
    ) {
        self.id = id
        self.receivedAt = receivedAt
        self.asset = asset
        self.status = status
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.bookingID = bookingID
    }
}

nonisolated enum OfficeDazeSchema {
    static let all: [any PersistentModel.Type] = [
        Office.self, DeskBooking.self, AttendanceDay.self, PlannedDay.self,
        LeaveDay.self, ArrivalAlert.self, Capture.self,
    ]
}
