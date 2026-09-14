import Foundation

/// A desk identifier as the booking system prints it, and what it encodes.
///
/// `CO03C117` is site `CO`, floor `03`, zone `C`, desk `117`. The shape is
/// fixed for the London office — two letters, two digits, one letter, three
/// digits — and that fixedness is what makes the recogniser's mistakes
/// correctable: a digit where a letter must be is a letter misread, and the
/// only question is which one.
///
/// The decoding is only trusted for the one site whose scheme is known. An id
/// from another site is accepted in the same shape, because a booking there
/// is still a booking, but its office, floor and zone come from the page or
/// not at all — reading them out of an id whose scheme nobody has confirmed
/// would be the guess the whole capture path exists to refuse.
nonisolated struct DeskID: Equatable, Sendable {

    /// The sites whose scheme is known, and the office each one is. `CO` is
    /// the Coleman building, which is the London office; the booking system
    /// prints it as "Coleman, London" in the list and "Coleman" on a
    /// reservation page, and the matcher takes either.
    static let knownSites: [String: String] = ["CO": "Coleman, London"]

    var site: String
    var floor: String
    var zone: String
    var desk: String

    /// The id as it should be printed.
    var text: String { site + floor + zone + desk }

    /// Whether the office, floor and zone can be read off the id.
    var isDecodable: Bool { Self.knownSites[site] != nil }

    /// The office, when the id's scheme is known. A page that prints no
    /// office still names its building in every desk id on it.
    var decodedOffice: String? { Self.knownSites[site] }

    /// The floor, when the id's scheme is known.
    var decodedFloor: String? { isDecodable ? floor : nil }

    /// The zone, when the id's scheme is known.
    var decodedZone: String? { isDecodable ? zone : nil }

    // MARK: Reading one

    /// The id an eight-character token is, once its misreadings are undone —
    /// or nil if no amount of undoing makes it one.
    static func parse(_ token: String) -> DeskID? {
        let folded = fold(token)
        guard folded.count == 8,
              folded.wholeMatch(of: /[A-Z]{2}\d{2}[A-Z]\d{3}/) != nil else { return nil }
        let characters = Array(folded)
        return DeskID(
            site: String(characters[0..<2]),
            floor: String(characters[2..<4]),
            zone: String(characters[4]),
            desk: String(characters[5..<8])
        )
    }

    /// The first desk id on a line. `Reservation for CO03C102` and a bare
    /// `CO03C102` both answer; a reservation number like `WRES2011757` does
    /// not, because it fails the shape at every position.
    static func find(in line: String) -> DeskID? {
        all(in: line).first
    }

    /// Every desk id on a line, in order. A row Vision returned as one string
    /// has one; a page it returned as one string may have several.
    static func all(in line: String) -> [DeskID] {
        line.split { !$0.isLetter && !$0.isNumber }
            .compactMap { parse(String($0)) }
    }

    // MARK: Undoing the recogniser

    /// Digits that are only ever a letter misread, and the letter each one is;
    /// and the Cyrillic capitals that look like Latin ones, which Vision
    /// produces when left to guess the language.
    private static let toLetter: [Character: Character] = [
        "0": "O", "1": "I", "2": "Z", "5": "S", "8": "B",
        "А": "A", "В": "B", "С": "C", "Е": "E", "Н": "H", "К": "K", "М": "M",
        "О": "O", "Р": "P", "Т": "T", "Х": "X",
    ]

    /// Letters that are only ever a digit misread, and the digit each one is.
    /// `З` is the Cyrillic Ze, which is what a 3 came back as.
    private static let toDigit: [Character: Character] = [
        "O": "0", "D": "0", "I": "1", "L": "1", "Z": "2", "S": "5", "B": "8",
        "О": "0", "З": "3",
    ]

    /// Which positions hold letters. Everything else holds a digit.
    private static let letterPositions: Set<Int> = [0, 1, 4]

    /// The token with each character read as the kind its position demands.
    ///
    /// Positional rather than global: a `0` is an `O` in the site code and a
    /// zero in the desk number, and the same fold applied everywhere would
    /// break as many ids as it fixed. Only eight-character tokens are
    /// touched; anything else is returned upper-cased and unchanged, and
    /// fails the shape on its own.
    static func fold(_ token: String) -> String {
        let upper = token.uppercased()
        guard upper.count == 8 else { return upper }
        return String(upper.enumerated().map { index, character in
            if letterPositions.contains(index) {
                toLetter[character] ?? character
            } else {
                toDigit[character] ?? character
            }
        })
    }
}
