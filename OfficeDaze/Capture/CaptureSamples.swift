#if DEBUG
import Foundation

/// The Coleman week, as the real booking system's table comes back.
///
/// There is no way to hand the simulator a screenshot through the share sheet
/// from a script, so without this the capture sheets could only ever be looked
/// at by hand. Debug builds only; it never ships.
nonisolated enum CaptureSamples {

    /// Three confirmed rows under three date headings, one with an unread zone.
    static let colemanWeek: [ParsedBooking] = [
        ParsedBooking(
            officeName: "Coleman, London", day: Day(2026, 8, 4), deskID: "CO03A424",
            floor: "03", zone: nil, startTime: "08:00", endTime: "17:00",
            unsureFields: ["zone"]
        ),
        ParsedBooking(
            officeName: "Coleman, London", day: Day(2026, 8, 5), deskID: "CO03C407",
            floor: "03", zone: "C", startTime: "08:00", endTime: "17:00",
            unsureFields: []
        ),
        ParsedBooking(
            officeName: "Coleman, London", day: Day(2026, 8, 6), deskID: "CO03D211",
            floor: "03", zone: "D", startTime: "08:00", endTime: "17:00",
            unsureFields: []
        ),
    ]

    /// A single booking, to check the sheet hides the counter and the bar.
    static let one: [ParsedBooking] = [colemanWeek[1]]

    /// The other layout: a confirmation email for one reservation on one day.
    /// No city beside the building, and no end time printed anywhere — that one
    /// defaults to 17:00 rather than being asked about, so the sheet has only
    /// the zone to query.
    static let confirmation: [ParsedBooking] = [
        ParsedBooking(
            officeName: "Coleman", day: Day(2026, 8, 25), deskID: "CO03B424",
            floor: "03", zone: nil, startTime: "09:00", endTime: "17:00",
            unsureFields: ["zone"]
        )
    ]

    /// The third layout: the reservation's own page. Its desk id came out of
    /// the heading, and unlike the confirmation email it prints both ends of
    /// the day — so nothing is defaulted and only the floor, which the page
    /// never states, is flagged.
    static let reservationPage: [ParsedBooking] = [
        ParsedBooking(
            officeName: "Coleman, London", day: Day(2026, 9, 7), deskID: "CO03C117",
            floor: nil, zone: nil, startTime: "08:00", endTime: "17:00",
            unsureFields: ["floor", "zone"]
        )
    ]

    static let usage = HaikuClient.Usage(inputTokens: 1640, outputTokens: 520)

    /// A real 1×1 PNG, because the debug flow runs the app's own intake and
    /// that intake decodes what it is given. A string standing in for an image
    /// used to be enough; now it fails at the door, which is the point.
    static let pixel = Data(base64Encoded: """
        iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGA\
        hKmMIQAAAABJRU5ErkJggg==
        """)!
}
#endif
