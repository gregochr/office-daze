import Foundation

/// The wire shape the model returns, and the mapping into `ParsedBooking`.
///
/// Kept separate from the domain type so the model's vocabulary never leaks
/// into the app. The mapping is also where the never-guess rule is *enforced*
/// rather than merely requested: any field the model left null is added to
/// `unsureFields` here even if the model forgot to name it, and any field the
/// model named as unsure is discarded even if it also supplied a value.
nonisolated struct Extracted: Decodable {
    var kind: BookingKind
    var confidence: Confidence
    var unsureFields: [String]
    var rail: Rail?
    var desk: Desk?
    var stay: Stay?

    struct Rail: Decodable {
        var operatorName: String?
        var originStation: String?
        var destStation: String?
        var originCity: String?
        var destCity: String?
        var departsAt: String?
        var departZone: String?
        var arrivesAt: String?
        var arriveZone: String?
        var platform: String?
        var coach: String?
        var seat: String?
        var bookingRef: String?
        var checkInBy: String?
    }

    struct Desk: Decodable {
        var placeName: String?
        var address: String?
        var city: String?
        var date: String?
        var zone: String?
        var floor: String?
        var deskZone: String?
        var deskID: String?
        var hours: String?
    }

    struct Stay: Decodable {
        var hotelName: String?
        var address: String?
        var city: String?
        var checkIn: String?
        var checkOut: String?
        var zone: String?
        var nights: Int?
        var bookingRef: String?
    }

    func parsed(today: Day) throws -> ParsedBooking {
        switch kind {
        case .rail: try parsedRail()
        case .desk: try parsedDesk()
        case .stay: try parsedStay(today: today)
        }
    }

    // MARK: Enforcement

    /// A field the model named as unsure is dropped even if it also supplied a
    /// value — the instruction was to omit it, and a value that arrives beside
    /// its own name in `unsureFields` is exactly the "plausible guess" the
    /// design forbids storing.
    private func honouring<T>(_ name: String, _ value: T?) -> T? {
        unsureFields.contains(name) ? nil : value
    }

    /// The mirror of the above: a field the model left null is named here even
    /// if the model forgot to name it, so the amber count is always the truth.
    private static func naming(_ unsure: inout [String], _ name: String, isNil: Bool) {
        if isNil, !unsure.contains(name) { unsure.append(name) }
    }

    // MARK: Rail

    private func parsedRail() throws -> ParsedBooking {
        guard let rail else { throw CaptureError.modelReturnedNothingUsable("no rail detail") }
        var unsure = unsureFields

        guard let departsText = honouring("departsAt", rail.departsAt),
              let departs = PassParser.isoDate(departsText) else {
            throw CaptureError.modelReturnedNothingUsable("no readable departure time")
        }
        guard let origin = honouring("originStation", rail.originStation),
              let destination = honouring("destStation", rail.destStation) else {
            throw CaptureError.modelReturnedNothingUsable("no readable origin or destination")
        }

        let arrivesText = honouring("arrivesAt", rail.arrivesAt)
        let arrives = arrivesText.flatMap(PassParser.isoDate)

        let originCity = honouring("originCity", rail.originCity)
            ?? Zones.city(forStation: origin) ?? origin
        let destCity = honouring("destCity", rail.destCity)
            ?? Zones.city(forStation: destination) ?? destination

        let startZone = zone(rail.departZone, city: originCity, iso: departsText)
        let endZone = arrivesText.map { zone(rail.arriveZone, city: destCity, iso: $0) }

        let platform = honouring("platform", rail.platform)
        let coach = honouring("coach", rail.coach)
        let seat = honouring("seat", rail.seat)
        let reference = honouring("bookingRef", rail.bookingRef)

        Self.naming(&unsure, "platform", isNil: platform == nil)
        Self.naming(&unsure, "coach", isNil: coach == nil)
        Self.naming(&unsure, "seat", isNil: seat == nil)
        Self.naming(&unsure, "bookingRef", isNil: reference == nil)
        Self.naming(&unsure, "arrival", isNil: arrives == nil)

        let detail = RailDetail(
            operatorName: honouring("operatorName", rail.operatorName) ?? "RAIL",
            originStation: origin,
            destStation: destination,
            originCity: originCity,
            destCity: destCity,
            originCode: PassParser.shortCode(origin),
            destCode: PassParser.shortCode(destination),
            platform: platform,
            coach: coach,
            seat: seat,
            bookingRef: reference,
            checkInBy: honouring("checkInBy", rail.checkInBy).flatMap(PassParser.isoDate),
            passSerial: nil
        )

        return ParsedBooking(
            detail: .rail(detail),
            startsAt: departs,
            startZoneID: startZone.identifier,
            endsAt: arrives,
            endZoneID: endZone?.identifier,
            unsureFields: unsure,
            provenance: .screengrab,
            confidence: confidence
        )
    }

    // MARK: Desk

    private func parsedDesk() throws -> ParsedBooking {
        guard let desk else { throw CaptureError.modelReturnedNothingUsable("no desk detail") }
        var unsure = unsureFields

        guard let dateText = honouring("date", desk.date),
              let date = PassParser.isoDate(dateText) ?? dayOnly(dateText) else {
            throw CaptureError.modelReturnedNothingUsable("no readable date")
        }
        guard let deskID = honouring("deskID", desk.deskID) else {
            throw CaptureError.modelReturnedNothingUsable("no readable desk id")
        }

        let city = honouring("city", desk.city) ?? ""
        let timeZone = zone(desk.zone, city: city, iso: dateText)
        let floor = honouring("floor", desk.floor)
        let deskZone = honouring("deskZone", desk.deskZone)
        let hours = honouring("hours", desk.hours)

        Self.naming(&unsure, "floor", isNil: floor == nil)
        Self.naming(&unsure, "zone", isNil: deskZone == nil)
        Self.naming(&unsure, "hours", isNil: hours == nil)

        let detail = DeskDetail(
            placeID: UUID(),  // resolved against known Places when committed
            placeName: honouring("placeName", desk.placeName) ?? "OFFICE",
            city: city,
            floor: floor,
            zone: deskZone,
            deskID: deskID,
            hours: hours,
            countsToQuota: true
        )

        return ParsedBooking(
            detail: .desk(detail),
            startsAt: date,
            startZoneID: timeZone.identifier,
            endsAt: nil,
            endZoneID: nil,
            unsureFields: unsure,
            provenance: .screengrab,
            confidence: confidence
        )
    }

    // MARK: Stay

    private func parsedStay(today: Day) throws -> ParsedBooking {
        guard let stay else { throw CaptureError.modelReturnedNothingUsable("no stay detail") }
        var unsure = unsureFields

        guard let hotelName = honouring("hotelName", stay.hotelName) else {
            throw CaptureError.modelReturnedNothingUsable("no readable hotel name")
        }

        let checkInText = honouring("checkIn", stay.checkIn)
        let checkOutText = honouring("checkOut", stay.checkOut)
        let checkIn = checkInText.flatMap(PassParser.isoDate)
        let checkOut = checkOutText.flatMap(PassParser.isoDate)

        // A stay has to be filed under a day even when the check-in time is
        // unreadable — otherwise an unreadable clock loses the whole booking.
        // The date comes from check-in if we have it, else from check-out
        // minus the nights, and the *time* stays unknown either way.
        let nights = honouring("nights", stay.nights)
        let city = honouring("city", stay.city) ?? ""
        let timeZone = zone(stay.zone, city: city, iso: checkInText ?? checkOutText ?? "")

        let anchor: Date
        if let checkIn {
            anchor = checkIn
        } else if let checkOut, let nights, nights > 0 {
            anchor = Day(of: checkOut, in: timeZone)
                .adding(days: -nights)
                .at(18, 0, in: timeZone)
        } else if let checkOut {
            anchor = Day(of: checkOut, in: timeZone).adding(days: -1).at(18, 0, in: timeZone)
        } else {
            throw CaptureError.modelReturnedNothingUsable("no readable dates")
        }

        Self.naming(&unsure, "checkIn", isNil: checkIn == nil)
        Self.naming(&unsure, "checkOut", isNil: checkOut == nil)
        Self.naming(&unsure, "bookingRef", isNil: honouring("bookingRef", stay.bookingRef) == nil)

        let detail = StayDetail(
            hotelName: hotelName,
            address: honouring("address", stay.address),
            city: city,
            checkIn: checkIn,
            checkOut: checkOut,
            nights: nights ?? 1,
            bookingRef: honouring("bookingRef", stay.bookingRef)
        )

        return ParsedBooking(
            detail: .stay(detail),
            startsAt: anchor,
            startZoneID: timeZone.identifier,
            endsAt: checkOut,
            endZoneID: checkOut != nil ? timeZone.identifier : nil,
            unsureFields: unsure,
            provenance: .screengrab,
            confidence: confidence
        )
    }

    // MARK: Helpers

    /// The model's zone identifier if it gave a real one, else the city table,
    /// else the offset it wrote into the timestamp.
    private func zone(_ identifier: String?, city: String, iso: String) -> TimeZone {
        if let identifier, let known = TimeZone(identifier: identifier) { return known }
        return Zones.resolve(city: city.isEmpty ? nil : city, offsetSeconds: PassParser.isoOffset(iso))
    }

    /// A bare `2026-09-07` with no time, which the model sometimes returns for
    /// a desk booking that only prints a date.
    private func dayOnly(_ text: String) -> Date? {
        let parts = text.prefix(10).split(separator: "-")
        guard parts.count == 3, let year = Int(parts[0]), let month = Int(parts[1]),
              let day = Int(parts[2]) else { return nil }
        return Day(year, month, day).at(9, 0, in: TimeDisplay.uk)
    }
}
