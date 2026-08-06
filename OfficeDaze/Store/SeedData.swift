import Foundation
import SwiftData

/// The sample month from the design: two offices, four desk bookings, four
/// attended days and three days' leave in August 2026.
///
/// Seeded so the app has something to show before a single screenshot has been
/// captured, and so the gauge can be looked at against a known answer. The
/// numbers are the design's — London 3, Brussels 1, target 7.
@MainActor
enum SeedData {

    // Offices are stable identities, so their ids are fixed rather than random:
    // the desk bookings, the attendance rows and the geofence all have to agree
    // on which building Coleman is.
    static let colemanID = UUID(uuidString: "A0000000-0000-0000-0000-000000000001")!
    static let brusselsID = UUID(uuidString: "A0000000-0000-0000-0000-000000000002")!

    /// The month the sample data describes.
    static let month = Month(year: 2026, month: 8)

    static func populate(_ context: ModelContext) throws {
        // Named as the booking system prints it, because that is what the
        // matcher has to recognise: every capture sample says "Coleman", and a
        // seed office called anything else makes the sheet ask which office
        // "Coleman" is on every single import.
        //
        // Coordinates as for Brussels — off the street, not surveyed, and
        // replaced by the geocoder the first time the office is saved.
        let coleman = Office(
            id: colemanID,
            name: "Coleman",
            address: "63 Coleman Street, London",
            postcode: "EC2R 5BB",
            latitude: 51.5172,
            longitude: -0.0893,
            colourHex: OfficeColours.palette[0]
        )
        // Euroclear Bank. The coordinates are read off the street, not
        // surveyed — close enough to seed a 50m perimeter for the simulator,
        // and the geocoder replaces them the first time the office is saved.
        let brussels = Office(
            id: brusselsID,
            name: "Brussels",
            address: "1 Boulevard du Roi Albert II, 1210 Brussels",
            postcode: "1210",
            latitude: 50.8568,
            longitude: 4.3567,
            colourHex: OfficeColours.palette[1]
        )
        context.insert(coleman)
        context.insert(brussels)

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

        // Three days' leave. Under the old pro-rate this moved the target to 7;
        // under blocks of five it moves nothing, and that is the state worth
        // seeding — it is the one that needs explaining, and the target line
        // has a sentence for it. Five days here would take the target to 6 and
        // put the month on track, which would cost the previews the amber
        // shortfall strip the design is built around.
        for day in [Day(2026, 8, 17), Day(2026, 8, 18), Day(2026, 8, 19)] {
            context.insert(LeaveDay(day: day, kind: .annual))
        }

        try context.save()
    }
}
