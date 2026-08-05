import Foundation

nonisolated enum BookingKind: String, Codable, Sendable, CaseIterable {
    case rail, desk, stay
}

/// Dedupe precedence: `manual` beats everything, then pass, email, screengrab.
/// Conforming to Comparable makes `max(a, b)` mean "the one that wins", which
/// reads better at the call site than an `int rank()` method would in Java.
nonisolated enum Provenance: String, Codable, Sendable, Comparable, CaseIterable {
    case screengrab, email, pass, manual

    private var rank: Int {
        switch self {
        case .screengrab: 0
        case .email: 1
        case .pass: 2
        case .manual: 3
        }
    }

    static func < (a: Provenance, b: Provenance) -> Bool { a.rank < b.rank }
}

nonisolated enum LeaveKind: String, Codable, Sendable {
    case annual, bankHoliday, sick
}

nonisolated enum AttendanceSource: String, Codable, Sendable {
    case geofence, manual
}

nonisolated enum CaptureInputType: String, Codable, Sendable {
    case passFile, image, pdf, text
}

nonisolated enum CaptureStatus: String, Codable, Sendable {
    case pending, parsed, failed
}

// Every field the model might fail to read is Optional. That is the whole
// point of the "never guess" rule: an unreadable check-in time is `nil` and its
// name goes in `unsureFields`, rather than a plausible-looking 15:00 that
// nobody can later tell apart from a real one. Swift's Optional makes the
// distinction unavoidable at the type level — you cannot read `checkIn` without
// handling the absence.

nonisolated struct RailDetail: Codable, Hashable, Sendable {
    /// `operator` is a Swift keyword — it declares custom operators. Backticks
    /// would escape it, but a clear name is better than an escaped keyword.
    var operatorName: String
    var originStation: String
    var destStation: String
    /// Cities, not stations. The grouping rule works on cities: St Pancras and
    /// King's Cross are both London, and that is what makes the Eurostar read
    /// as leaving the London week rather than starting a new one. The data-model
    /// document lists only stations; these two fields are the addition.
    var originCity: String
    var destCity: String
    /// Short codes as printed on the ticket — `KGX`, `STP`, `MIDI`. Optional
    /// because not every source supplies them; `Abbreviate` falls back to a
    /// table and then to the full name, never to a truncation.
    var originCode: String?
    var destCode: String?
    var platform: String?
    var coach: String?
    var seat: String?
    var bookingRef: String?
    var checkInBy: Date?
    var passSerial: String?
}

nonisolated struct DeskDetail: Codable, Hashable, Sendable {
    var placeID: UUID
    var placeName: String
    var city: String
    var floor: String?
    var deskID: String
    var hours: String?
    /// A desk in a building that isn't the office — a client site, say — is a
    /// booking but not a quota day.
    var countsToQuota: Bool = true
}

nonisolated struct StayDetail: Codable, Hashable, Sendable {
    var hotelName: String
    var address: String?
    var city: String
    var checkIn: Date?
    var checkOut: Date?
    var nights: Int
    var bookingRef: String?
}

/// One of three shapes, chosen by `kind`. In Java this would be a sealed
/// interface plus Jackson polymorphic type configuration; in Swift an enum with
/// associated values gets Codable synthesised for free, and `switch` over it is
/// exhaustive — add a fourth kind and every call site fails to compile until it
/// handles the new case.
nonisolated enum BookingDetail: Codable, Hashable, Sendable {
    case rail(RailDetail)
    case desk(DeskDetail)
    case stay(StayDetail)

    var kind: BookingKind {
        switch self {
        case .rail: .rail
        case .desk: .desk
        case .stay: .stay
        }
    }

    var railDetail: RailDetail? { if case .rail(let d) = self { d } else { nil } }
    var deskDetail: DeskDetail? { if case .desk(let d) = self { d } else { nil } }
    var stayDetail: StayDetail? { if case .stay(let d) = self { d } else { nil } }
}
