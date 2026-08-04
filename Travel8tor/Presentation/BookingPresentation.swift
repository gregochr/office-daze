import Foundation

/// Everything a `BookingCard` needs, derived from a `Booking`. Split out from
/// the view so the derivation can be tested without rendering anything — the
/// time-zone rule and the never-guess rule both surface here, and both are
/// worth asserting.
nonisolated struct BookingPresentation: Hashable, Sendable {
    let kind: BookingKind
    let typeCode: String
    let figure: String
    let figureSubtitle: String?
    let title: String
    let metadata: [String]
    let flag: String?
    let incomplete: Bool
    /// A booking with unread fields renders a step back, so it doesn't read as
    /// confirmed.
    let emphasis: Emphasis

    /// The placeholder for a field the model would not commit to. Never blank,
    /// so the absence is visible rather than merely missing.
    static let unread = "??:??"
}

@MainActor
enum BookingPresenter {

    /// `copy` is passed rather than reached for, so tests can render both
    /// modes without touching the shared instance or UserDefaults.
    static func present(
        _ booking: Booking,
        copy: @escaping (T8Label) -> String,
        compact: Bool = false
    ) -> BookingPresentation? {
        guard let detail = booking.detail else { return nil }
        let incomplete = booking.hasUnreadableFields
        let emphasis: Emphasis = incomplete ? .pending : .full
        // Computed once here rather than inside each branch, so the copy
        // closure never has to outlive this call.
        let flag = incomplete
            ? "\(copy(.dataIncomplete)) ▪ \(String(format: "%02d", booking.unsureFields.count)) FIELDS"
            : nil

        switch detail {
        case .rail(let rail):
            return railPresentation(booking, rail, flag, incomplete, emphasis, compact)
        case .desk(let desk):
            return deskPresentation(booking, desk, copy, flag, incomplete, emphasis, compact)
        case .stay(let stay):
            return stayPresentation(booking, stay, flag, incomplete, emphasis, compact)
        }
    }

    private static func railPresentation(
        _ booking: Booking, _ rail: RailDetail, _ flag: String?,
        _ incomplete: Bool, _ emphasis: Emphasis, _ compact: Bool
    ) -> BookingPresentation {
        let origin = Abbreviate.station(rail.originStation, code: rail.originCode)
        let destination = Abbreviate.station(rail.destStation, code: rail.destCode)

        // The departure renders in the zone it departs from — always.
        let (time, uk) = TimeDisplay.stacked(booking.startsAt, in: booking.startZone)

        var metadata: [String] = []
        if compact {
            // The nested-trip card carries the arrival inline instead of the
            // platform/coach/seat row: `ARR 20:05 (19:05 UK) ▪ 9/51`.
            if let arrival = booking.endsAt, let zone = booking.endZone {
                var line = "ARR \(TimeDisplay.inline(arrival, in: zone))"
                if let coach = rail.coach, let seat = rail.seat {
                    line += " ▪ \(coach)/\(seat)"
                }
                metadata = [line]
            }
        } else {
            if let platform = rail.platform { metadata.append("PLAT \(platform)") }
            if let coach = rail.coach { metadata.append("CCH \(coach)") }
            if let seat = rail.seat { metadata.append("SEAT \(seat)") }
        }

        return BookingPresentation(
            kind: .rail,
            typeCode: "[RAIL] \(rail.operatorName.uppercased())",
            figure: time,
            figureSubtitle: uk,
            title: "\(origin) → \(destination)",
            metadata: metadata,
            flag: flag,
            incomplete: incomplete,
            emphasis: emphasis
        )
    }

    private static func deskPresentation(
        _ booking: Booking, _ desk: DeskDetail,
        _ copy: (T8Label) -> String, _ flag: String?,
        _ incomplete: Bool, _ emphasis: Emphasis, _ compact: Bool
    ) -> BookingPresentation {
        var metadata: [String] = []
        if !compact {
            if let floor = desk.floor { metadata.append(floor) }
            if let zone = desk.zone { metadata.append("ZONE \(zone)") }
            if let hours = desk.hours { metadata.append(hours) }
        }

        // A desk that doesn't count toward the eight says so, rather than
        // silently looking like one that does.
        let counts = desk.countsToQuota ? "\(copy(.counts)) 1" : "NO COUNT"

        return BookingPresentation(
            kind: .desk,
            typeCode: "[DESK] \(counts)",
            figure: desk.deskID.uppercased(),
            figureSubtitle: nil,
            title: Abbreviate.place(desk.placeName),
            metadata: metadata,
            flag: flag,
            incomplete: incomplete,
            emphasis: emphasis
        )
    }

    private static func stayPresentation(
        _ booking: Booking, _ stay: StayDetail, _ flag: String?,
        _ incomplete: Bool, _ emphasis: Emphasis, _ compact: Bool
    ) -> BookingPresentation {
        // An unread check-in shows `??:??`, never a blank and never a guess.
        let figure: String
        let subtitle: String?
        if let checkIn = stay.checkIn {
            (figure, subtitle) = TimeDisplay.stacked(checkIn, in: booking.startZone)
        } else {
            figure = BookingPresentation.unread
            subtitle = nil
        }

        var metadata: [String] = []
        if !compact, let address = stay.address { metadata.append(address.uppercased()) }

        let nights = stay.nights == 1 ? "1 NIGHT" : "\(stay.nights) NIGHTS"

        return BookingPresentation(
            kind: .stay,
            typeCode: "[STAY] \(nights)",
            figure: figure,
            figureSubtitle: subtitle,
            title: stay.hotelName.uppercased(),
            metadata: metadata,
            flag: flag,
            incomplete: incomplete,
            emphasis: emphasis
        )
    }

}
