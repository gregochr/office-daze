import Foundation
import SwiftData

/// The September trip from the design, plus the August context the gauge needs.
///
/// The trip nesting is not written down here. The bookings are declared flat,
/// in chronological order, and `TripGrouper` derives the London week and the
/// Brussels leg from them. If the rule regresses, the seed changes shape and
/// the tests fail — which is the point.
nonisolated enum SeedData {

    static let homeCity = "Durham"
    static let london = TimeZone(identifier: "Europe/London")!
    static let brussels = TimeZone(identifier: "Europe/Brussels")!

    // Places are stable identities, so their ids are fixed rather than random —
    // the desk bookings and the geofence both need to agree on which building
    // Ropemaker Place is.
    static let ropemakerPlaceID = UUID(uuidString: "A0000000-0000-0000-0000-000000000001")!

    static func places() -> [Place] {
        [
            Place(
                id: ropemakerPlaceID,
                name: "Ropemaker Place",
                city: "London",
                address: "25 Ropemaker St",
                postcode: "EC2Y 9LY",
                latitude: 51.5203,
                longitude: -0.0879,
                radiusMetres: 50
            )
        ]
    }

    // MARK: - The September bookings, flat and in order

    /// A booking before it has a trip. `make` turns it into a `Booking` once
    /// grouping has decided where it goes.
    struct Draft {
        let id: UUID
        let detail: BookingDetail
        let startsAt: Date
        let startZoneID: String
        let endsAt: Date?
        let endZoneID: String?
        let provenance: Provenance
        let unsureFields: [String]
    }

    static func septemberDrafts() -> [Draft] {
        let mon = Day(2026, 9, 7)
        let thu = Day(2026, 9, 10)
        let fri = Day(2026, 9, 11)

        return [
            // 1 — Durham → King's Cross, Monday morning. Opens the London week.
            Draft(
                id: UUID(),
                detail: .rail(RailDetail(
                    operatorName: "LNER",
                    originStation: "Durham",
                    destStation: "King's Cross",
                    originCity: "Durham",
                    destCity: "London",
                    originCode: "DURHAM",
                    destCode: "KGX",
                    platform: "2",
                    coach: "B",
                    seat: "12",
                    bookingRef: "LNR44120",
                    checkInBy: nil,
                    passSerial: nil
                )),
                startsAt: mon.at(6, 40, in: london),
                startZoneID: "Europe/London",
                endsAt: mon.at(9, 33, in: london),
                endZoneID: "Europe/London",
                provenance: .pass,
                unsureFields: []
            ),

            // 2 — London desk, Monday. Joins the London week.
            Draft(
                id: UUID(),
                detail: .desk(DeskDetail(
                    placeID: ropemakerPlaceID,
                    placeName: "Ropemaker Place",
                    city: "London",
                    floor: "L3",
                    zone: "C",
                    deskID: "3C-114",
                    hours: "10:00–16:00",
                    countsToQuota: true
                )),
                startsAt: mon.at(10, 0, in: london),
                startZoneID: "Europe/London",
                endsAt: mon.at(16, 0, in: london),
                endZoneID: "Europe/London",
                provenance: .email,
                unsureFields: []
            ),

            // 3 — Eurostar to Brussels, Monday evening. Opens the Brussels leg
            //     as a child of the London week.
            Draft(
                id: UUID(),
                detail: .rail(RailDetail(
                    operatorName: "Eurostar",
                    originStation: "St Pancras",
                    destStation: "Brussels Midi",
                    originCity: "London",
                    destCity: "Brussels",
                    originCode: "STP",
                    destCode: "MIDI",
                    platform: nil,
                    coach: "09",
                    seat: "51",
                    bookingRef: "XKR48821",
                    checkInBy: mon.at(16, 34, in: london),
                    passSerial: "EUROSTAR_XKR48821"
                )),
                startsAt: mon.at(17, 4, in: london),
                startZoneID: "Europe/London",
                endsAt: mon.at(20, 5, in: brussels),
                endZoneID: "Europe/Brussels",
                provenance: .pass,
                unsureFields: []
            ),

            // 4 — Hotel Sablon, three nights. Joins the Brussels leg.
            Draft(
                id: UUID(),
                detail: .stay(StayDetail(
                    hotelName: "Hotel Sablon",
                    address: "Rue de Rollebeek 12",
                    city: "Brussels",
                    checkIn: mon.at(21, 0, in: brussels),
                    checkOut: thu.at(11, 0, in: brussels),
                    nights: 3,
                    bookingRef: "SAB-99310"
                )),
                startsAt: mon.at(21, 0, in: brussels),
                startZoneID: "Europe/Brussels",
                endsAt: thu.at(11, 0, in: brussels),
                endZoneID: "Europe/Brussels",
                provenance: .email,
                unsureFields: []
            ),

            // 5 — Eurostar home, Thursday. Closes the Brussels leg.
            Draft(
                id: UUID(),
                detail: .rail(RailDetail(
                    operatorName: "Eurostar",
                    originStation: "Brussels Midi",
                    destStation: "St Pancras",
                    originCity: "Brussels",
                    destCity: "London",
                    originCode: "MIDI",
                    destCode: "STP",
                    platform: nil,
                    coach: "14",
                    seat: "22",
                    bookingRef: "XKR48822",
                    checkInBy: thu.at(17, 22, in: brussels),
                    passSerial: "EUROSTAR_XKR48822"
                )),
                startsAt: thu.at(17, 52, in: brussels),
                startZoneID: "Europe/Brussels",
                endsAt: thu.at(18, 57, in: london),
                endZoneID: "Europe/London",
                provenance: .pass,
                unsureFields: []
            ),

            // 6 — The Ropewalk, Thursday night, London. This is the one that
            //     matters: it sits inside the Brussels leg's dates and must
            //     still belong to the London week. Also the incomplete-data
            //     case — the screengrab was cut off below the room line, so
            //     check-in and the reference are unread, not guessed.
            Draft(
                id: UUID(),
                detail: .stay(StayDetail(
                    hotelName: "The Ropewalk",
                    address: "41 Rivington St",
                    city: "London",
                    checkIn: nil,
                    checkOut: fri.at(11, 0, in: london),
                    nights: 1,
                    bookingRef: nil
                )),
                startsAt: thu.at(19, 30, in: london),
                startZoneID: "Europe/London",
                endsAt: fri.at(11, 0, in: london),
                endZoneID: "Europe/London",
                provenance: .screengrab,
                unsureFields: ["checkIn", "bookingRef"]
            ),

            // 7 — London desk, Friday. Back at full width in the parent.
            Draft(
                id: UUID(),
                detail: .desk(DeskDetail(
                    placeID: ropemakerPlaceID,
                    placeName: "Ropemaker Place",
                    city: "London",
                    floor: "L3",
                    zone: "C",
                    deskID: "3C-118",
                    hours: "09–17",
                    countsToQuota: true
                )),
                startsAt: fri.at(9, 0, in: london),
                startZoneID: "Europe/London",
                endsAt: fri.at(17, 0, in: london),
                endZoneID: "Europe/London",
                provenance: .email,
                unsureFields: []
            ),

            // 8 — King's Cross → Durham, Friday evening. Closes the week.
            Draft(
                id: UUID(),
                detail: .rail(RailDetail(
                    operatorName: "LNER",
                    originStation: "King's Cross",
                    destStation: "Durham",
                    originCity: "London",
                    destCity: "Durham",
                    originCode: "KGX",
                    destCode: "DURHAM",
                    platform: nil,
                    coach: "C",
                    seat: "44",
                    bookingRef: "LNR44121",
                    checkInBy: nil,
                    passSerial: nil
                )),
                startsAt: fri.at(17, 33, in: london),
                startZoneID: "Europe/London",
                endsAt: fri.at(20, 26, in: london),
                endZoneID: "Europe/London",
                provenance: .pass,
                unsureFields: []
            ),
        ]
    }

    /// The August bookings and records behind the gauge in screen 5a:
    /// TERMINATED 02, FORECAST 02, TARGET 07, 03 LEFT ALIVE, 18 DAYS TO RUN,
    /// as at Tuesday 4 August 2026.
    static func augustDrafts() -> [Draft] {
        let wed = Day(2026, 8, 5)
        let thu = Day(2026, 8, 6)

        return [
            Draft(
                id: UUID(),
                detail: .rail(RailDetail(
                    operatorName: "LNER",
                    originStation: "Durham",
                    destStation: "King's Cross",
                    originCity: "Durham",
                    destCity: "London",
                    originCode: "DURHAM",
                    destCode: "KGX",
                    platform: "2",
                    coach: "B",
                    seat: "12",
                    bookingRef: "LNR43980",
                    checkInBy: nil,
                    passSerial: nil
                )),
                startsAt: wed.at(6, 40, in: london),
                startZoneID: "Europe/London",
                endsAt: wed.at(9, 33, in: london),
                endZoneID: "Europe/London",
                provenance: .pass,
                unsureFields: []
            ),
            Draft(
                id: UUID(),
                detail: .desk(DeskDetail(
                    placeID: ropemakerPlaceID,
                    placeName: "Ropemaker Place",
                    city: "London",
                    floor: "L3",
                    zone: "C",
                    deskID: "3C-114",
                    hours: "09–17",
                    countsToQuota: true
                )),
                startsAt: wed.at(9, 0, in: london),
                startZoneID: "Europe/London",
                endsAt: wed.at(17, 0, in: london),
                endZoneID: "Europe/London",
                provenance: .email,
                unsureFields: []
            ),
            Draft(
                id: UUID(),
                detail: .desk(DeskDetail(
                    placeID: ropemakerPlaceID,
                    placeName: "Ropemaker Place",
                    city: "London",
                    floor: "L3",
                    zone: "C",
                    deskID: "3C-116",
                    hours: "09–17",
                    countsToQuota: true
                )),
                startsAt: thu.at(9, 0, in: london),
                startZoneID: "Europe/London",
                endsAt: thu.at(17, 0, in: london),
                endZoneID: "Europe/London",
                provenance: .email,
                unsureFields: []
            ),
            // Not in the mock, which only shows the next two days. Without a
            // homeward leg the August trip never closes, and an open trip
            // covers every day after it — including all of September, which
            // would swallow the London week before it could open.
            Draft(
                id: UUID(),
                detail: .rail(RailDetail(
                    operatorName: "LNER",
                    originStation: "King's Cross",
                    destStation: "Durham",
                    originCity: "London",
                    destCity: "Durham",
                    originCode: "KGX",
                    destCode: "DURHAM",
                    platform: nil,
                    coach: "B",
                    seat: "31",
                    bookingRef: "LNR43981",
                    checkInBy: nil,
                    passSerial: nil
                )),
                startsAt: thu.at(18, 33, in: london),
                startZoneID: "Europe/London",
                endsAt: thu.at(21, 26, in: london),
                endZoneID: "Europe/London",
                provenance: .pass,
                unsureFields: []
            ),
        ]
    }

    /// August then September, in one run. Grouping is order-dependent and the
    /// two months share a trip list — the August trip has to be closed before
    /// September's outbound leg looks for a covering trip.
    static func allDrafts() -> [Draft] { augustDrafts() + septemberDrafts() }

    /// Two days already attended in August, and three days' annual leave — the
    /// numbers the design's worked example depends on.
    static func augustAttendance() -> [AttendanceDay] {
        [
            AttendanceDay(day: Day(2026, 8, 3), placeID: ropemakerPlaceID, source: .geofence),
            AttendanceDay(day: Day(2026, 8, 4), placeID: ropemakerPlaceID, source: .manual),
        ]
    }

    static func augustLeave() -> [LeaveDay] {
        [
            LeaveDay(day: Day(2026, 8, 17)),
            LeaveDay(day: Day(2026, 8, 18)),
            LeaveDay(day: Day(2026, 8, 19)),
        ]
    }

    // MARK: - Materialising

    /// Runs the drafts through the grouping rule and returns trips and bookings
    /// ready to insert. No SwiftData involved — so a test can call this and
    /// assert on the nesting without a store.
    struct Materialised {
        var trips: [TripShape]
        var bookings: [(draft: Draft, tripID: UUID?)]

        /// Plural on purpose: the seed has two London trips, August's and the
        /// September week. Callers say which one they mean.
        func trips(in city: String) -> [TripShape] {
            trips.filter { $0.primaryCity == city }
        }

        func tripID(of draftID: UUID) -> UUID? {
            bookings.first { $0.draft.id == draftID }?.tripID
        }
    }

    static func materialise(_ drafts: [Draft], newID: () -> UUID = { UUID() }) -> Materialised {
        let shapes: [(id: UUID, shape: BookingShape)] = drafts.compactMap { draft in
            let geography: BookingGeography = switch draft.detail {
            case .rail(let r): .journey(from: r.originCity, to: r.destCity)
            case .desk(let d): .single(city: d.city)
            case .stay(let s): .single(city: s.city)
            }
            let zone = TimeZone(identifier: draft.startZoneID) ?? .gmt
            return (
                draft.id,
                BookingShape(
                    kind: draft.detail.kind,
                    geography: geography,
                    anchorDay: Day(of: draft.startsAt, in: zone)
                )
            )
        }

        let result = TripGrouper.group(bookings: shapes, homeCity: homeCity, newID: newID)

        return Materialised(
            trips: result.trips,
            bookings: drafts.map { ($0, result.tripID(of: $0.id)) }
        )
    }

    /// Populate an empty store. Idempotent by virtue of only being called when
    /// the store has no trips.
    @MainActor
    static func populate(_ context: ModelContext) throws {
        for place in places() { context.insert(place) }

        let materialised = materialise(allDrafts())

        for shape in materialised.trips {
            context.insert(Trip(
                id: shape.id,
                label: TripGrouper.label(city: shape.primaryCity, isChild: shape.parentID != nil),
                primaryCity: shape.primaryCity,
                startsOn: shape.startsOn,
                endsOn: shape.endsOn,
                parentTripID: shape.parentID
            ))
        }

        for (draft, tripID) in materialised.bookings {
            context.insert(Booking(
                id: draft.id,
                detail: draft.detail,
                startsAt: draft.startsAt,
                startZoneID: draft.startZoneID,
                endsAt: draft.endsAt,
                endZoneID: draft.endZoneID,
                tripID: tripID,
                provenance: draft.provenance,
                unsureFields: draft.unsureFields
            ))
        }

        for record in augustAttendance() { context.insert(record) }
        for leave in augustLeave() { context.insert(leave) }

        try context.save()
    }
}
