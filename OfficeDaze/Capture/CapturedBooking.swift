import Foundation

/// What the model returns for one row of the table, and the mapping into
/// something the app can commit.
///
/// Kept separate from `DeskBooking` so the model's vocabulary never leaks into
/// the store, and so the never-guess rule is *enforced* here rather than merely
/// requested: a field the model named in `unsureFields` is discarded even if it
/// also supplied a value, because a value arriving beside its own name in that
/// list is exactly the plausible guess the design forbids storing.
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

nonisolated struct CapturedResponse: Decodable, Sendable {
    var bookings: [CapturedBooking]
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

nonisolated enum CaptureError: LocalizedError, Equatable {
    case noAPIKey
    case unsupportedFile(String)
    /// Chosen from the library and then unreadable — a format ImageIO does not
    /// decode, or bytes that are not an image at all. Distinct from
    /// `unsupportedFile`, which knows what the thing was.
    case unreadableImage
    case network(String)
    case httpStatus(Int, String)
    case modelReturnedNothingUsable(String)
    case refused

    var errorDescription: String? {
        switch self {
        case .noAPIKey:
            "No API key yet. Add one in Settings to read screenshots."
        case .unsupportedFile(let ext):
            "Office Daze can't read a .\(ext.uppercased()) file."
        case .unreadableImage:
            "That image couldn't be opened. Try a screenshot or a photo instead."
        case .network(let why):
            "The network request failed: \(why)"
        case .httpStatus(let code, let why):
            "The model call failed (\(code)): \(why)"
        case .modelReturnedNothingUsable(let why):
            "Nothing usable came back: \(why)"
        case .refused:
            "The model declined to read this document."
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
    /// back nil whatever the model put in it.
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

        // A field the model left blank without naming it is still unread — the
        // schema asks for null and a name, but the flag has to hold even when
        // the model forgets half of that.
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
            deskID: desk,
            floor: honouring("floor", floor),
            zone: honouring("zone", zone),
            startTime: honouring("startTime", startTime),
            endTime: end,
            unsureFields: unsure
        )
    }

    /// `2026-08-05`. Strict: a date the model reformatted into something else
    /// is a date we did not read, and guessing at `05/08/2026` is exactly the
    /// day/month coin-flip the app must not make.
    ///
    /// Anything after the date itself is ignored, which is what lets a single
    /// confirmation's `2026-08-25 09:00:00 CEST` through unharmed — the day is
    /// the day whatever timezone the sender printed beside it.
    static func day(from text: String) -> Day? {
        let parts = text.prefix(10).split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              (1...12).contains(month), (1...31).contains(day) else { return nil }
        return Day(year, month, day)
    }
}
