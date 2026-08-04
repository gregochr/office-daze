import Foundation
import SwiftData

// Two decisions worth stating, because both look wrong to a JPA reflex.
//
// 1. Entities reference each other by UUID, not by SwiftData relationships.
//    The data-model document specifies `tripId?`, `parentTripId?`, `bookingId?`
//    as ids, and says the schema should map cleanly onto a relational one
//    later. It also keeps the pure rules in Domain/ free of any persistence
//    type — `TripGrouping` never imports SwiftData.
//
// 2. Days are stored as `Date` at midnight UTC, not as the `Day` struct.
//    SwiftData can persist Codable structs, but only stored properties of
//    primitive types work reliably inside `#Predicate`. Storing a Date keeps
//    fetches and sorts straightforward; the `Day` accessors below are the
//    bridge, and nothing outside this file should touch the raw Dates.

@Model
final class Trip {
    var id: UUID = UUID()
    var label: String = ""
    var primaryCity: String = ""
    var startsOnDate: Date = Date.distantPast
    /// Nil while the trip is open — no homeward leg has closed it.
    var endsOnDate: Date?
    var parentTripID: UUID?

    init(
        id: UUID = UUID(),
        label: String,
        primaryCity: String,
        startsOn: Day,
        endsOn: Day? = nil,
        parentTripID: UUID? = nil
    ) {
        self.id = id
        self.label = label
        self.primaryCity = primaryCity
        self.startsOnDate = startsOn.startOfDayUTC
        self.endsOnDate = endsOn?.startOfDayUTC
        self.parentTripID = parentTripID
    }

    var startsOn: Day {
        get { Day(of: startsOnDate, in: Day.calendar.timeZone) }
        set { startsOnDate = newValue.startOfDayUTC }
    }

    var endsOn: Day? {
        get { endsOnDate.map { Day(of: $0, in: Day.calendar.timeZone) } }
        set { endsOnDate = newValue?.startOfDayUTC }
    }

    /// The projection the grouping rule works on.
    var shape: TripShape {
        TripShape(
            id: id, primaryCity: primaryCity,
            startsOn: startsOn, endsOn: endsOn, parentID: parentTripID
        )
    }
}

@Model
final class Booking {
    var id: UUID = UUID()
    var kind: BookingKind = BookingKind.desk
    var startsAt: Date = Date.distantPast
    /// IANA identifiers, one at each end of a journey. "Europe/London",
    /// "Europe/Brussels". Never a fixed offset — offsets don't survive DST.
    var startZoneID: String = "Europe/London"
    var endsAt: Date?
    var endZoneID: String?
    var tripID: UUID?
    /// `BookingDetail` JSON. Encoded rather than stored as a SwiftData
    /// attribute because it is an enum with associated values; Data is
    /// unambiguous and survives schema changes we can migrate by hand.
    var detailData: Data = Data()
    var provenance: Provenance = Provenance.manual
    /// Field names the model would not commit to. Non-empty means the amber
    /// flag. A field named here has no stored value — that is the invariant.
    var unsureFields: [String] = []
    var captureID: UUID?

    init(
        id: UUID = UUID(),
        detail: BookingDetail,
        startsAt: Date,
        startZoneID: String,
        endsAt: Date? = nil,
        endZoneID: String? = nil,
        tripID: UUID? = nil,
        provenance: Provenance,
        unsureFields: [String] = [],
        captureID: UUID? = nil
    ) {
        self.id = id
        self.kind = detail.kind
        self.detailData = (try? JSONEncoder().encode(detail)) ?? Data()
        self.startsAt = startsAt
        self.startZoneID = startZoneID
        self.endsAt = endsAt
        self.endZoneID = endZoneID
        self.tripID = tripID
        self.provenance = provenance
        self.unsureFields = unsureFields
        self.captureID = captureID
    }

    var detail: BookingDetail? {
        get { try? JSONDecoder().decode(BookingDetail.self, from: detailData) }
        set {
            guard let newValue else { return }
            detailData = (try? JSONEncoder().encode(newValue)) ?? Data()
            kind = newValue.kind
        }
    }

    var startZone: TimeZone { TimeZone(identifier: startZoneID) ?? .gmt }
    var endZone: TimeZone? { endZoneID.flatMap(TimeZone.init(identifier:)) }

    /// The day the booking files under, in the zone it starts in.
    var anchorDay: Day { Day(of: startsAt, in: startZone) }

    var hasUnreadableFields: Bool { !unsureFields.isEmpty }

    /// The projection the grouping rule works on.
    var shape: BookingShape? {
        guard let detail else { return nil }
        let geography: BookingGeography = switch detail {
        case .rail(let r): .journey(from: r.originCity, to: r.destCity)
        case .desk(let d): .single(city: d.city)
        case .stay(let s): .single(city: s.city)
        }
        return BookingShape(kind: kind, geography: geography, anchorDay: anchorDay)
    }
}

@Model
final class LeaveDay {
    var id: UUID = UUID()
    var date: Date = Date.distantPast
    /// 1.0 or 0.5.
    var fraction: Double = 1.0
    var kind: LeaveKind = LeaveKind.annual

    init(id: UUID = UUID(), day: Day, fraction: Double = 1.0, kind: LeaveKind = .annual) {
        self.id = id
        self.date = day.startOfDayUTC
        self.fraction = fraction
        self.kind = kind
    }

    var day: Day {
        get { Day(of: date, in: Day.calendar.timeZone) }
        set { date = newValue.startOfDayUTC }
    }
}

/// The only entity that counts toward the eight. Separate from Booking because
/// the two come apart in both directions: you can book a desk and not go, and
/// you can go without booking. Never written without the user confirming.
@Model
final class AttendanceDay {
    var id: UUID = UUID()
    var date: Date = Date.distantPast
    var placeID: UUID?
    var source: AttendanceSource = AttendanceSource.manual
    var fraction: Double = 1.0
    /// Nil for a day you turned up without a booking — which is exactly what
    /// makes the inverted arrival prompt recordable.
    var bookingID: UUID?

    init(
        id: UUID = UUID(),
        day: Day,
        placeID: UUID? = nil,
        source: AttendanceSource,
        fraction: Double = 1.0,
        bookingID: UUID? = nil
    ) {
        self.id = id
        self.date = day.startOfDayUTC
        self.placeID = placeID
        self.source = source
        self.fraction = fraction
        self.bookingID = bookingID
    }

    var day: Day {
        get { Day(of: date, in: Day.calendar.timeZone) }
        set { date = newValue.startOfDayUTC }
    }
}

@Model
final class Place {
    var id: UUID = UUID()
    var name: String = ""
    var city: String = ""
    var address: String = ""
    var postcode: String = ""
    var latitude: Double = 0
    var longitude: Double = 0
    var radiusMetres: Double = 50

    init(
        id: UUID = UUID(),
        name: String,
        city: String,
        address: String,
        postcode: String,
        latitude: Double,
        longitude: Double,
        radiusMetres: Double = 50
    ) {
        self.id = id
        self.name = name
        self.city = city
        self.address = address
        self.postcode = postcode
        self.latitude = latitude
        self.longitude = longitude
        self.radiusMetres = radiusMetres
    }
}

/// One row per place per day. The entire implementation of "fires once": on a
/// region entry, if a row exists for today, do nothing. Cheap, testable, and it
/// survives the app being killed — which dwell-time logic would not.
@Model
final class ArrivalAlert {
    var id: UUID = UUID()
    var date: Date = Date.distantPast
    var placeID: UUID = UUID()
    var deliveredAt: Date = Date.distantPast

    init(id: UUID = UUID(), day: Day, placeID: UUID, deliveredAt: Date) {
        self.id = id
        self.date = day.startOfDayUTC
        self.placeID = placeID
        self.deliveredAt = deliveredAt
    }

    var day: Day {
        get { Day(of: date, in: Day.calendar.timeZone) }
        set { date = newValue.startOfDayUTC }
    }
}

/// Keeps the original so "view original" works, and gives a monthly call count
/// and cost without instrumenting anything else.
@Model
final class Capture {
    var id: UUID = UUID()
    var receivedAt: Date = Date.distantPast
    var inputType: CaptureInputType = CaptureInputType.image
    @Attribute(.externalStorage) var asset: Data?
    var status: CaptureStatus = CaptureStatus.pending
    var model: String?
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var bookingID: UUID?

    init(
        id: UUID = UUID(),
        receivedAt: Date,
        inputType: CaptureInputType,
        asset: Data? = nil,
        status: CaptureStatus = .pending,
        model: String? = nil,
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        bookingID: UUID? = nil
    ) {
        self.id = id
        self.receivedAt = receivedAt
        self.inputType = inputType
        self.asset = asset
        self.status = status
        self.model = model
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.bookingID = bookingID
    }
}

enum Travel8torSchema {
    static let all: [any PersistentModel.Type] = [
        Trip.self, Booking.self, LeaveDay.self, AttendanceDay.self,
        Place.self, ArrivalAlert.self, Capture.self,
    ]
}
