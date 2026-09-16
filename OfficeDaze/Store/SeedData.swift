import Foundation
import SwiftData

/// What a first launch finds: the company's two offices and, on the simulator,
/// the sample month from the design — four desk bookings, four attended days
/// and three days' leave in August 2026.
///
/// Seeded so the app has something to show before a single screenshot has been
/// captured, and so the gauge can be looked at against a known answer. The
/// numbers are the design's — London 3, Brussels 1, target 7.
///
/// Only the offices are real, so only the offices go onto a phone. The sample
/// month never happened, and in someone's own store it would be three weeks of
/// history they did not live. See `populate(_:forSimulator:)`.
@MainActor
enum SeedData {

    // Offices are stable identities, so their ids are fixed rather than random:
    // the desk bookings, the attendance rows and the geofence all have to agree
    // on which building Coleman is.
    static let colemanID = UUID(uuidString: "A0000000-0000-0000-0000-000000000001")!
    static let brusselsID = UUID(uuidString: "A0000000-0000-0000-0000-000000000002")!

    /// The month the sample data describes.
    static let month = Month(year: 2026, month: 8)

    /// Lays the seed down and saves it.
    ///
    /// `forSimulator` is the difference between the two places the app runs.
    /// The simulator gets everything: the screenshots, the debug screens and
    /// `-capture` are all drawn against the sample month, and the arrival alert
    /// can only be looked at with a perimeter to be inside. A phone gets the
    /// offices, with no sample month and no coordinates. Tests and previews
    /// take the default, which is the simulator's seed.
    static func populate(_ context: ModelContext, forSimulator: Bool = true) throws {
        insertOffices(context, located: forSimulator)
        if forSimulator {
            insertSampleMonth(context)
        }
        try context.save()
    }

    /// Coleman and Brussels, the part of the seed that is true for anyone at
    /// the company.
    ///
    /// Coordinates only when `located`. They were read off the street rather
    /// than surveyed — near enough to draw a 50m perimeter in the simulator,
    /// where nobody has to walk into it. On a phone they would be wrong in a
    /// way nothing corrects: a saved office is only geocoded again when its
    /// address changes. Left unlocated, Settings says "no location yet" and
    /// the first save in the office editor asks the geocoder where it is.
    private static func insertOffices(_ context: ModelContext, located: Bool) {
        // Named as the booking system prints it, because that is what the
        // matcher has to recognise: every capture sample says "Coleman", and a
        // seed office called anything else makes the sheet ask which office
        // "Coleman" is on every single import.
        let coleman = Office(
            id: colemanID,
            name: "Coleman",
            address: "63 Coleman Street, London",
            postcode: "EC2R 5BB",
            colourHex: OfficeColours.palette[0],
            siteCode: "CO"
        )
        // Euroclear Bank.
        let brussels = Office(
            id: brusselsID,
            name: "Brussels",
            address: "1 Boulevard du Roi Albert II, 1210 Brussels",
            postcode: "1210",
            colourHex: OfficeColours.palette[1]
        )
        if located {
            (coleman.latitude, coleman.longitude) = (51.5172, -0.0893)
            (brussels.latitude, brussels.longitude) = (50.8568, 4.3567)
        }
        context.insert(coleman)
        context.insert(brussels)
    }

    /// The design's August, which is there to be drawn rather than counted.
    private static func insertSampleMonth(_ context: ModelContext) {
        // The four bookings on the home screen. The 5th and 6th have been
        // attended; the 11th and 12th are still ahead, and count as forecast.
        let bookings = [
            DeskBooking(
                officeID: colemanID, day: Day(2026, 8, 5), deskID: "3C-114",
                floor: "Level 3", zone: "C",
                startTime: "09:00", endTime: "17:00", source: .capture
            ),
            DeskBooking(
                officeID: colemanID, day: Day(2026, 8, 6), deskID: "3C-116",
                floor: "Level 3", zone: "C",
                startTime: "09:00", endTime: "17:00", source: .capture
            ),
            DeskBooking(
                officeID: brusselsID, day: Day(2026, 8, 11), deskID: "2-041",
                floor: "Level 2", zone: nil,
                startTime: "09:00", endTime: "17:30", source: .capture,
                // One booking arrives incomplete on purpose, so the
                // needs-checking marker has something to mark. The zone is
                // absent rather than guessed, and named here.
                unsureFields: ["zone"]
            ),
            DeskBooking(
                officeID: colemanID, day: Day(2026, 8, 12), deskID: "3C-121",
                floor: "Level 3", zone: "C",
                startTime: "09:00", endTime: "17:00", source: .manual
            ),
        ]
        bookings.forEach(context.insert)

        // Four attended days: London 3, Brussels 1, as the office cards show.
        // Two of them have no desk booking behind them — days turned up for
        // without booking, which the nullable bookingID exists to record.
        let attendance = [
            AttendanceDay(day: Day(2026, 8, 3), officeID: colemanID, source: .manual),
            AttendanceDay(day: Day(2026, 8, 4), officeID: brusselsID, source: .manual),
            AttendanceDay(
                day: Day(2026, 8, 5), officeID: colemanID,
                source: .geofence, bookingID: bookings[0].id
            ),
            AttendanceDay(
                day: Day(2026, 8, 6), officeID: colemanID,
                source: .geofence, bookingID: bookings[1].id
            ),
        ]
        attendance.forEach(context.insert)

        // Three days' leave: one pair and a day over, so the target is 7 — the
        // design's number again, which blocks of five had put back to 8. Four
        // days here would take the target to 6 and put the month on track,
        // which would cost the previews the shortfall the design is built
        // around.
        for day in [Day(2026, 8, 17), Day(2026, 8, 18), Day(2026, 8, 19)] {
            context.insert(LeaveDay(day: day, kind: .annual))
        }
    }
}
