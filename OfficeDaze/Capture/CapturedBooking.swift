import Foundation

/// What the reader found for one booking, and the mapping into something the
/// app can commit.
///
/// Kept separate from `DeskBooking` so the reader's vocabulary never leaks into
/// the store, and so the never-guess rule is *enforced* here rather than merely
/// assumed: a field named in `unsureFields` is discarded even if a value was
/// also supplied, because a value arriving beside its own name in that list is
/// exactly the plausible guess the design forbids storing. `Decodable` so a
/// test can write a row as JSON.
nonisolated struct CapturedBooking: Decodable, Equatable, Sendable {
    var office: String?
    var date: String?
    var deskId: String?
    var floor: String?
    var zone: String?
    var startTime: String?
    var endTime: String?
    var unsureFields: [String]
}

/// One row, mapped and ready for review. The office is not resolved yet — that
/// needs the store, and this type stays free of it.
nonisolated struct ParsedBooking: Equatable, Sendable, Identifiable {
    var id = UUID()
    /// The office name as printed, e.g. `Coleman, London`.
    var officeName: String?
    var day: Day
    var deskID: String
    var floor: String?
    var zone: String?
    var startTime: String?
    var endTime: String?
    var unsureFields: [String]

    var needsChecking: Bool { !unsureFields.isEmpty }
}

nonisolated extension ParsedBooking {

    /// This booking as filed under an office whose desk ids open with `site`.
    ///
    /// A desk id the recogniser got the site code wrong on — `CC03D128` for a
    /// Coleman desk — is put right by the office it is filed under, because
    /// the office is the one fact about the desk the user has just confirmed.
    /// Once the id decodes, the floor and zone it encodes fill in whatever
    /// the page did not print, and stop being fields to check. Nothing else
    /// changes; an id already under that site, or a desk that is not an id
    /// in the site's shape at all, comes back as it was.
    func filed(underSite site: String?) -> ParsedBooking {
        guard let site, let desk = DeskID.parse(deskID), desk.site != site else { return self }
        let filed = desk.filed(underSite: site)
        var booking = self
        booking.deskID = filed.text
        if booking.floor == nil, let floor = filed.decodedFloor {
            booking.floor = floor
            booking.unsureFields.removeAll { $0 == "floor" }
        }
        if booking.zone == nil, let zone = filed.decodedZone {
            booking.zone = zone
            booking.unsureFields.removeAll { $0 == "zone" }
        }
        return booking
    }
}

nonisolated enum CaptureError: LocalizedError, Equatable {
    case unsupportedFile(String)
    /// Chosen from the library and then unreadable — a format ImageIO does not
    /// decode, or bytes that are not an image at all. Distinct from
    /// `unsupportedFile`, which knows what the thing was.
    case unreadableImage
    /// The image was read and no booking came of it — nothing printed, no
    /// whole row, or nothing still to come. The reason is the reader's.
    case nothingUsable(String)
    /// The reading worked and the writing did not — a full disk, a store that
    /// refused. Its own case because the sheet must never show a booking as
    /// saved when nothing was written, and because "try again" is the wrong
    /// offer for it.
    case couldNotSave(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedFile(let ext):
            "Office Daze can't read a .\(ext.uppercased()) file."
        case .unreadableImage:
            "That image couldn't be opened. Try a screenshot or a photo instead."
        case .nothingUsable(let why):
            "Nothing usable came back: \(why)"
        case .couldNotSave(let why):
            "That booking couldn't be saved: \(why). Nothing was written."
        }
    }
}

nonisolated extension CapturedBooking {

    /// The end of the working day, used when the document does not print one.
    static let defaultEndTime = "17:00"

    /// Nil when the row cannot become a booking at all — no legible date, or no
    /// desk. Everything else is optional by design.
    ///
    /// `honouring` is the enforcement: a field named in `unsureFields` comes
    /// back nil whatever value came with it.
    func parsed() -> ParsedBooking? {
        func honouring(_ name: String, _ value: String?) -> String? {
            guard !unsureFields.contains(name) else { return nil }
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (trimmed?.isEmpty ?? true) ? nil : trimmed
        }

        guard let dateText = honouring("date", date), let day = Self.day(from: dateText),
              let desk = honouring("deskId", deskId) else { return nil }

        // The one value the app supplies for itself. A single confirmation
        // prints when the desk becomes yours and never when it stops being, and
        // the answer is 17:00 every time — so this is a default rather than a
        // question, and the field is not flagged for review.
        let end = honouring("endTime", endTime) ?? Self.defaultEndTime

        // A field left blank without being named is still unread — the flag
        // has to hold whether or not the reader said so.
        var unsure = unsureFields.filter { $0 != "endTime" }
        for (name, value) in [
            ("floor", honouring("floor", floor)),
            ("zone", honouring("zone", zone)),
            ("startTime", honouring("startTime", startTime)),
        ] where value == nil && !unsure.contains(name) {
            unsure.append(name)
        }

        return ParsedBooking(
            officeName: honouring("office", office),
            day: day,
            deskID: Self.correctingSiteCode(desk),
            floor: honouring("floor", floor),
            zone: honouring("zone", zone),
            startTime: honouring("startTime", startTime),
            endTime: end,
            unsureFields: unsure
        )
    }

    /// Digits that are only ever a letter misread, and the letter each one is.
    ///
    /// Confined to the pairs that are the same shape twice — a zero for an O, a
    /// one for an I, a five for an S, an eight for a B. A 9 has no letter it
    /// could be, so an id carrying one is left exactly as it came back: the
    /// point of this is to undo a misreading, and a 9 turned into a letter of
    /// our choosing would be an invention, which is the thing the whole capture
    /// path exists to avoid.
    private static let letterTwins: [Character: Character] = [
        "0": "O", "1": "I", "5": "S", "8": "B",
    ]

    /// A desk id always opens with the two-letter site code, so a digit in
    /// either position is a misreading — `C003A424` for `CO03A424`, which is
    /// the one that came back from a photograph of a monitor.
    ///
    /// `DeskID` undoes this and more before a booking gets here, so on the
    /// on-device path this is a second net under the same rule. It is the one
    /// correction the app can make without guessing: those two characters are
    /// known to be letters, so no reading of them as digits can be right.
    ///
    /// All or nothing across the pair. Half a correction would leave an id that
    /// is neither what was printed nor what was read, and no one downstream
    /// could tell which half to trust.
    static func correctingSiteCode(_ deskID: String) -> String {
        var characters = Array(deskID)
        guard characters.count >= 2 else { return deskID }

        for index in 0..<2 where characters[index].isNumber {
            guard let letter = letterTwins[characters[index]] else { return deskID }
            characters[index] = letter
        }
        return String(characters)
    }

    /// `2026-08-05`. Strict: a date reformatted into something else is a date
    /// we did not read, and guessing at `05/08/2026` is exactly the
    /// day/month coin-flip the app must not make.
    ///
    /// Anything after the date itself is ignored, which is what lets a single
    /// confirmation's `2026-08-25 09:00:00 CEST` through unharmed — the day is
    /// the day whatever timezone the sender printed beside it.
    ///
    /// The day is validated against the month rather than against `1...31`.
    /// `Calendar.date(from:)` is lenient, so `Day(2026, 2, 30)` is a
    /// constructible value whose `startOfDayUTC` is 2 March: it renders as
    /// "Monday 2 March" in the review sheet, and then fails to equal the
    /// `Day(2026, 3, 2)` a stored booking reads back as — so the clash strip
    /// never appears, `BookingStore.upsert` finds nothing to merge with, and
    /// the office ends the day with two desks on it. A hallucinated 30 February
    /// is precisely the misreading this parser exists to refuse.
    static func day(from text: String) -> Day? {
        let parts = text.prefix(10).split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2])
        else { return nil }
        return Day(validating: year, month, day)
    }
}
