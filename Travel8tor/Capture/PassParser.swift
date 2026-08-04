import Foundation

/// Path A: a `.pkpass` is a zip containing `pass.json`. Unzip, read the fields
/// directly. No model call, no confidence, nothing to confirm — the issuer
/// already structured the data.
///
/// Reading a pass you have been handed needs no entitlement. (`PKPassLibrary`
/// would not let the app enumerate passes already in Wallet — an app may only
/// read passes signed by its own team — so this only works for passes actively
/// shared with us, which is exactly the capture flow.)
nonisolated enum PassParser {

    // MARK: pass.json

    struct Pass: Decodable {
        var organizationName: String?
        var description: String?
        var serialNumber: String?
        var relevantDate: String?
        var expirationDate: String?
        var boardingPass: Structure?
        var eventTicket: Structure?
        var generic: Structure?
        var coupon: Structure?
        var storeCard: Structure?

        var structure: Structure? {
            boardingPass ?? eventTicket ?? generic ?? coupon ?? storeCard
        }
    }

    struct Structure: Decodable {
        var transitType: String?
        var headerFields: [Field]?
        var primaryFields: [Field]?
        var secondaryFields: [Field]?
        var auxiliaryFields: [Field]?
        var backFields: [Field]?

        /// All fields in reading order. Primary first, because a boarding pass
        /// puts origin and destination there.
        ///
        /// Accumulated rather than written as one chained expression: five
        /// `??`-defaulted arrays joined with `+` is enough overload resolution
        /// to time the type-checker out.
        var allFields: [Field] {
            var all: [Field] = []
            all.append(contentsOf: primaryFields ?? [])
            all.append(contentsOf: headerFields ?? [])
            all.append(contentsOf: secondaryFields ?? [])
            all.append(contentsOf: auxiliaryFields ?? [])
            all.append(contentsOf: backFields ?? [])
            return all
        }
    }

    struct Field: Decodable {
        var key: String
        var label: String?
        /// `value` may be a string, a number, or an ISO date. Decoded loosely
        /// because issuers are inconsistent and a type mismatch shouldn't fail
        /// the whole pass.
        var value: String?
        var dateStyle: String?
        var timeStyle: String?

        private enum CodingKeys: String, CodingKey { case key, label, value, dateStyle, timeStyle }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            key = try container.decode(String.self, forKey: .key)
            label = try? container.decode(String.self, forKey: .label)
            dateStyle = try? container.decode(String.self, forKey: .dateStyle)
            timeStyle = try? container.decode(String.self, forKey: .timeStyle)

            if let text = try? container.decode(String.self, forKey: .value) {
                value = text
            } else if let number = try? container.decode(Double.self, forKey: .value) {
                value = number == number.rounded() ? String(Int(number)) : String(number)
            } else {
                value = nil
            }
        }
    }

    // MARK: Parsing

    static func parse(passFile data: Data) throws -> ParsedBooking {
        let json = try ZipArchive.extract("pass.json", from: data)
        return try parse(passJSON: json)
    }

    static func parse(passJSON: Data) throws -> ParsedBooking {
        let pass: Pass
        do {
            pass = try JSONDecoder().decode(Pass.self, from: passJSON)
        } catch {
            throw CaptureError.malformedPass(error.localizedDescription)
        }

        guard let structure = pass.structure else {
            throw CaptureError.malformedPass("no pass structure")
        }

        // Rail is the only kind Wallet models directly. A hotel or desk booking
        // arriving as a pass is rare; treat anything non-transit as a stay only
        // when it actually looks like one.
        if pass.boardingPass != nil || structure.transitType != nil {
            return try rail(pass, structure)
        }
        throw CaptureError.malformedPass("pass is not a boarding pass")
    }

    private static func rail(_ pass: Pass, _ structure: Structure) throws -> ParsedBooking {
        let fields = structure.allFields
        var unsure: [String] = []

        let originRaw = value(fields, matching: ["origin", "from", "depart", "departure"])
        let destinationRaw = value(fields, matching: ["destination", "to", "arriv", "arrival"])

        // Primary fields on a boarding pass are conventionally origin then
        // destination, so fall back to position when the keys are unfamiliar.
        let primary = structure.primaryFields ?? []
        let origin = originRaw ?? primary.first?.value
        let destination = destinationRaw ?? (primary.count > 1 ? primary[1].value : nil)

        guard let origin, let destination else {
            throw CaptureError.malformedPass("no origin or destination")
        }

        // The departure instant. `relevantDate` is the convention; a dated
        // field is the fallback.
        let departureText = pass.relevantDate
            ?? value(fields, matching: ["depart", "departure", "time", "board"])
        guard let departureText, let departure = isoDate(departureText) else {
            throw CaptureError.malformedPass("no departure time")
        }

        let arrivalText = pass.expirationDate ?? value(fields, matching: ["arriv", "arrival"])
        let arrival = arrivalText.flatMap(isoDate)

        let originCity = Zones.city(forStation: origin) ?? origin
        let destCity = Zones.city(forStation: destination) ?? destination
        let startZone = Zones.resolve(city: originCity, offsetSeconds: isoOffset(departureText))
        let endZone = arrivalText.map {
            Zones.resolve(city: destCity, offsetSeconds: isoOffset($0))
        }

        // Every field the pass didn't carry is named rather than invented.
        let platform = value(fields, matching: ["platform", "plat"])
        let coach = value(fields, matching: ["coach", "carriage", "car"])
        let seat = value(fields, matching: ["seat"])
        let reference = value(fields, matching: ["ref", "booking", "pnr", "confirmation", "record"])
            ?? pass.serialNumber
        let gate = value(fields, matching: ["gate", "checkin", "check-in", "boarding"])

        if platform == nil { unsure.append("platform") }
        if coach == nil { unsure.append("coach") }
        if seat == nil { unsure.append("seat") }
        if arrival == nil { unsure.append("arrival") }

        let detail = RailDetail(
            operatorName: pass.organizationName ?? "RAIL",
            originStation: origin,
            destStation: destination,
            originCity: originCity,
            destCity: destCity,
            originCode: shortCode(origin),
            destCode: shortCode(destination),
            platform: platform,
            coach: coach,
            seat: seat,
            bookingRef: reference,
            checkInBy: gate.flatMap(isoDate),
            passSerial: pass.serialNumber
        )

        return ParsedBooking(
            detail: .rail(detail),
            startsAt: departure,
            startZoneID: startZone.identifier,
            endsAt: arrival,
            endZoneID: endZone?.identifier,
            unsureFields: unsure,
            provenance: .pass,
            // A pass is the issuer's own data. Missing fields are missing, not
            // uncertain — nothing here was inferred.
            confidence: .high
        )
    }

    // MARK: Field matching

    /// Issuers name fields inconsistently, so match on the key *and* the
    /// human label. Returns nil rather than a best guess.
    static func value(_ fields: [Field], matching needles: [String]) -> String? {
        for needle in needles {
            for field in fields {
                let key = field.key.lowercased()
                let label = (field.label ?? "").lowercased()
                if key.contains(needle) || label.contains(needle) {
                    if let value = field.value, !value.trimmingCharacters(in: .whitespaces).isEmpty {
                        return value
                    }
                }
            }
        }
        return nil
    }

    /// A value that already looks like a station code is kept; anything else is
    /// left to `Abbreviate`.
    static func shortCode(_ station: String) -> String? {
        let trimmed = station.trimmingCharacters(in: .whitespaces)
        let isCode = trimmed.count <= 5
            && trimmed.uppercased() == trimmed
            && trimmed.allSatisfy { $0.isLetter || $0.isNumber }
        return isCode ? trimmed : nil
    }

    // MARK: ISO 8601

    /// A fresh formatter per call. `ISO8601DateFormatter` is not `Sendable`, so
    /// a shared static would be a data race the compiler rightly rejects — and
    /// this runs a handful of times per capture, not per frame.
    static func isoDate(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text)
    }

    /// The offset the pass wrote, in seconds. `Z` is zero; a missing offset is
    /// nil, which sends `Zones.resolve` to its next fallback.
    static func isoOffset(_ text: String) -> Int? {
        if text.hasSuffix("Z") { return 0 }
        // Look at the last 6 characters: +HH:MM or -HH:MM
        guard text.count >= 6 else { return nil }
        let tail = String(text.suffix(6))
        guard let sign = tail.first, sign == "+" || sign == "-" else { return nil }
        let parts = tail.dropFirst().split(separator: ":")
        guard parts.count == 2, let hours = Int(parts[0]), let minutes = Int(parts[1]) else {
            return nil
        }
        let magnitude = hours * 3600 + minutes * 60
        return sign == "-" ? -magnitude : magnitude
    }
}
