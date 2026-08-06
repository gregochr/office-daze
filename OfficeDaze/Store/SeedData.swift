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
    // on which building Ropemaker Place is.
    static let ropemakerID = UUID(uuidString: "A0000000-0000-0000-0000-000000000001")!
    static let brusselsID = UUID(uuidString: "A0000000-0000-0000-0000-000000000002")!

    /// The month the sample data describes.
    static let month = Month(year: 2026, month: 8)

    static func populate(_ context: ModelContext) throws {
        let ropemaker = Office(
            id: ropemakerID,
            name: "Ropemaker Place",
            address: "25 Ropemaker St, London",
            postcode: "EC2Y 9LY",
            latitude: 51.5195,
            longitude: -0.0885,
            colourHex: OfficeColours.palette[0]
        )
        let brussels = Office(
            id: brusselsID,
            name: "Brussels",
            address: "Rue de la Loi 42, 1040 Brussels",
            postcode: "1040",
            latitude: 50.8467,
            longitude: 4.3676,
            colourHex: OfficeColours.palette[1]
        )
        context.insert(ropemaker)
        context.insert(brussels)

        // The four bookings on the home screen. The 5th and 6th have been
        // attended; the 11th and 12th are still ahead, and count as forecast.
        let bookings = [
            DeskBooking(
                officeID: ropemakerID, day: Day(2026, 8, 5), deskID: "3C-114",
                floor: "Level 3", zone: "C",
                startTime: "09:00", endTime: "17:00", source: .capture
            ),
            DeskBooking(
                officeID: ropemakerID, day: Day(2026, 8, 6), deskID: "3C-116",
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
                officeID: ropemakerID, day: Day(2026, 8, 12), deskID: "3C-121",
                floor: "Level 3", zone: "C",
                startTime: "09:00", endTime: "17:00", source: .manual
            ),
        ]
        bookings.forEach(context.insert)

        // Four attended days: London 3, Brussels 1, as the office cards show.
        // Two of them have no desk booking behind them — days turned up for
        // without booking, which the nullable bookingID exists to record.
        let attendance = [
            AttendanceDay(day: Day(2026, 8, 3), officeID: ropemakerID, source: .manual),
            AttendanceDay(day: Day(2026, 8, 4), officeID: brusselsID, source: .manual),
            AttendanceDay(
                day: Day(2026, 8, 5), officeID: ropemakerID,
                source: .geofence, bookingID: bookings[0].id
            ),
            AttendanceDay(
                day: Day(2026, 8, 6), officeID: ropemakerID,
                source: .geofence, bookingID: bookings[1].id
            ),
        ]
        attendance.forEach(context.insert)

        // Three days' leave — the worked example's 8 × 17 ÷ 20.
        for day in [Day(2026, 8, 17), Day(2026, 8, 18), Day(2026, 8, 19)] {
            context.insert(LeaveDay(day: day, kind: .annual))
        }

        try context.save()
    }
}
