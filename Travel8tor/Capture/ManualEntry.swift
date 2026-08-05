import Foundation

/// Turning typed fields into a `ParsedBooking`, with no SwiftUI in it.
///
/// The whole point of routing manual entry through `ParsedBooking` rather than
/// straight into a `Booking` is that it then goes through the same commit —
/// dedupe, place resolution, regrouping. Typing a booking you had already
/// captured badly should *fix* it, and it does, because `manual` outranks every
/// other provenance and merge fills the winner's empty fields from the loser.
///
/// One decision worth stating: a blank field is not an unsure field.
///
/// `unsureFields` means "the machine could not read this", and it is what
/// raises the amber flag and the DATA INCOMPLETE panel. A person who left the
/// seat box empty knows the seat is empty. Flagging it would report their own
/// omission back to them as a fault in the capture, and would make the flag
/// mean two different things at once.
nonisolated enum ManualEntry {

    enum Kind: String, CaseIterable, Sendable {
        case rail, desk, stay

        var title: String {
            switch self {
            case .rail: "[RAIL]"
            case .desk: "[DESK]"
            case .stay: "[STAY]"
            }
        }
    }

    /// Every field the form can hold, for all three kinds. One flat struct
    /// rather than three, because the form switches kind live and losing what
    /// was typed on the way is worse than a few unused properties.
    struct Draft: Equatable, Sendable {
        var kind: Kind = .desk

        // Rail
        var operatorName = ""
        var originStation = ""
        var destStation = ""
        var originCity = ""
        var destCity = ""
        var platform = ""
        var coach = ""
        var seat = ""
        var railRef = ""

        // Desk
        var placeName = ""
        var deskCity = ""
        var deskID = ""
        var floor = ""
        var deskZone = ""
        var hours = ""

        // Stay
        var hotelName = ""
        var stayCity = ""
        var address = ""
        var nights = "1"
        var stayRef = ""

        // Shared
        var startsAt: Date = Day.today.at(9, 0, in: TimeDisplay.uk)
        var endsAt: Date = Day.today.at(17, 0, in: TimeDisplay.uk)
        /// The zone the event happens in. Defaults to the UK and is only worth
        /// changing for a foreign leg — at which point the display rule adds
        /// the UK equivalent by itself.
        var zoneID: String = TimeDisplay.uk.identifier
    }

    enum Problem: Equatable, Sendable {
        case missing([String])
        case endsBeforeStart

        var message: String {
            switch self {
            case .missing(let fields):
                "\(fields.joined(separator: ", ")) \(fields.count == 1 ? "IS" : "ARE") REQUIRED."
            case .endsBeforeStart:
                "THE END IS BEFORE THE START."
            }
        }
    }

    /// What each kind cannot do without. Deliberately short: everything else is
    /// optional, and an optional field left blank is simply absent.
    static func missing(_ draft: Draft) -> [String] {
        switch draft.kind {
        case .rail:
            [
                ("OPERATOR", draft.operatorName), ("FROM", draft.originStation),
                ("TO", draft.destStation),
            ].filter { $0.1.trimmed.isEmpty }.map(\.0)
        case .desk:
            [("BUILDING", draft.placeName), ("DESK", draft.deskID)]
                .filter { $0.1.trimmed.isEmpty }.map(\.0)
        case .stay:
            [("HOTEL", draft.hotelName)].filter { $0.1.trimmed.isEmpty }.map(\.0)
        }
    }

    static func validate(_ draft: Draft) -> Problem? {
        let absent = missing(draft)
        if !absent.isEmpty { return .missing(absent) }
        if draft.endsAt <= draft.startsAt { return .endsBeforeStart }
        return nil
    }

    /// Nil when the draft is not yet valid. The form disables COMMIT on the
    /// same check, so this returning nil is belt and braces rather than a path
    /// the user can reach.
    static func booking(from draft: Draft) -> ParsedBooking? {
        guard validate(draft) == nil else { return nil }
        let zone = TimeZone(identifier: draft.zoneID) ?? TimeDisplay.uk

        switch draft.kind {
        case .rail:
            let originCity = draft.originCity.nilIfBlank
                ?? Zones.city(forStation: draft.originStation.trimmed)
                ?? draft.originStation.trimmed
            let destCity = draft.destCity.nilIfBlank
                ?? Zones.city(forStation: draft.destStation.trimmed)
                ?? draft.destStation.trimmed

            return ParsedBooking(
                detail: .rail(RailDetail(
                    operatorName: draft.operatorName.trimmed,
                    originStation: draft.originStation.trimmed,
                    destStation: draft.destStation.trimmed,
                    originCity: originCity,
                    destCity: destCity,
                    originCode: PassParser.shortCode(draft.originStation.trimmed),
                    destCode: PassParser.shortCode(draft.destStation.trimmed),
                    platform: draft.platform.nilIfBlank,
                    coach: draft.coach.nilIfBlank,
                    seat: draft.seat.nilIfBlank,
                    bookingRef: draft.railRef.nilIfBlank,
                    checkInBy: nil,
                    passSerial: nil
                )),
                startsAt: draft.startsAt,
                startZoneID: zone.identifier,
                endsAt: draft.endsAt,
                endZoneID: zone.identifier,
                unsureFields: [],
                provenance: .manual,
                confidence: .high
            )

        case .desk:
            return ParsedBooking(
                detail: .desk(DeskDetail(
                    // Replaced by PlaceResolver at commit if the building is
                    // one we already know.
                    placeID: UUID(),
                    placeName: draft.placeName.trimmed,
                    city: draft.deskCity.trimmed,
                    floor: draft.floor.nilIfBlank,
                    zone: draft.deskZone.nilIfBlank,
                    deskID: draft.deskID.trimmed,
                    hours: draft.hours.nilIfBlank,
                    countsToQuota: true
                )),
                startsAt: draft.startsAt,
                startZoneID: zone.identifier,
                endsAt: draft.endsAt,
                endZoneID: zone.identifier,
                unsureFields: [],
                provenance: .manual,
                confidence: .high
            )

        case .stay:
            let nights = Int(draft.nights.trimmed) ?? 1
            return ParsedBooking(
                detail: .stay(StayDetail(
                    hotelName: draft.hotelName.trimmed,
                    address: draft.address.nilIfBlank,
                    city: draft.stayCity.trimmed,
                    checkIn: draft.startsAt,
                    checkOut: draft.endsAt,
                    nights: max(1, nights),
                    bookingRef: draft.stayRef.nilIfBlank
                )),
                startsAt: draft.startsAt,
                startZoneID: zone.identifier,
                endsAt: draft.endsAt,
                endZoneID: zone.identifier,
                unsureFields: [],
                provenance: .manual,
                confidence: .high
            )
        }
    }
}
