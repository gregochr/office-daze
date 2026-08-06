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

    static let usage = HaikuClient.Usage(inputTokens: 1640, outputTokens: 520)
}
#endif
