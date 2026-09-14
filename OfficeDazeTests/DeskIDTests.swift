import Foundation
import Testing
@testable import OfficeDaze

/// A desk id's shape, its decoding, and the misreadings it undoes.
@Suite("Desk ids")
struct DeskIDTests {

    @Test("CO03C117 is site CO, floor 03, zone C, desk 117")
    func decodesTheLondonShape() throws {
        let id = try #require(DeskID.parse("CO03C117"))
        #expect(id.site == "CO")
        #expect(id.floor == "03")
        #expect(id.zone == "C")
        #expect(id.desk == "117")
        #expect(id.text == "CO03C117")
        #expect(id.isDecodable)
        #expect(id.decodedFloor == "03")
        #expect(id.decodedZone == "C")
    }

    /// The scheme is known for one site. Another site's id is still an id,
    /// but nothing is read out of it.
    @Test("An id from a site whose scheme is unknown is accepted but not decoded")
    func unknownSiteIsNotDecoded() throws {
        let id = try #require(DeskID.parse("BR02A014"))
        #expect(id.text == "BR02A014")
        #expect(!id.isDecodable)
        #expect(id.decodedFloor == nil)
        #expect(id.decodedZone == nil)
    }

    @Test("Anything else is not a desk id", arguments: [
        "WRES2011757", "CO03C11", "CO03C1177", "CO3C117", "COLEMAN,", "Building", "Location",
        "Reserved", "Duration", "Training", "", "2026-10-05",
    ])
    func rejectsTheRest(_ token: String) {
        #expect(DeskID.parse(token) == nil, Comment(rawValue: token))
    }

    // MARK: Misreadings

    @Test("A digit where a letter must be is the letter it looks like", arguments: [
        ("C003C407", "CO03C407"),
        ("0O03C407", "OO03C407"),
        ("CO03C117", "CO03C117"),
        ("C0O3C1I7", "CO03C117"),
        ("co03c117", "CO03C117"),
    ])
    func foldsDigitsIntoLetters(_ raw: String, _ expected: String) {
        #expect(DeskID.fold(raw) == expected)
        #expect(DeskID.parse(raw)?.text == expected)
    }

    /// The one that came back off a synthetic page when Vision was left to
    /// guess the language: a Cyrillic O and a Cyrillic Ze.
    @Test("Cyrillic lookalikes are read as the Latin they stand in for")
    func foldsCyrillic() {
        #expect(DeskID.fold("CО0ЗC407") == "CO03C407")
        #expect(DeskID.parse("CО0ЗC407")?.text == "CO03C407")
    }

    @Test("A digit in the zone slot is a letter too")
    func foldsTheZone() {
        #expect(DeskID.parse("CO030117")?.zone == "O")
        #expect(DeskID.parse("CO035117")?.zone == "S")
    }

    /// A 9 has no letter it could be, so an id carrying one in a letter slot
    /// is left as it came and fails the shape — the point is to undo a
    /// misreading, not to invent one.
    @Test("A digit with no letter twin is not corrected")
    func leavesUnknownDigitsAlone() {
        #expect(DeskID.fold("C903C407") == "C903C407")
        #expect(DeskID.parse("C903C407") == nil)
    }

    @Test("Only eight-character tokens are folded at all")
    func foldsOnlyTheShape() {
        #expect(DeskID.fold("C003C40") == "C003C40")
        #expect(DeskID.fold("buildings") == "BUILDINGS")
        // An eight-letter word is folded, and then fails the shape anyway.
        #expect(DeskID.parse("building") == nil)
    }

    @Test("Every id on a line is found, in order")
    func findsAll() {
        #expect(DeskID.all(in: "CO03C102 then CO03D218").map(\.text) == ["CO03C102", "CO03D218"])
        #expect(DeskID.all(in: "nothing").isEmpty)
    }

    // MARK: Finding one on a line

    @Test("The id is found wherever it sits on the line", arguments: [
        "Reservation for CO03C102",
        "CO03C102",
        "  CO03C102  ",
        "CO03C102 | 03, Coleman, London | 08:00 - 17:00",
        "Desk CO03C102, floor 3",
    ])
    func findsOnALine(_ line: String) {
        #expect(DeskID.find(in: line)?.text == "CO03C102")
    }

    @Test("A line with no id on it answers nothing", arguments: [
        "Reservation f...", "WRES2011757", "03, Coleman, London", "08:00 - 17:00",
        "Christopher Gregory", "Europe/London", "Times shown based on building location",
    ])
    func findsNothing(_ line: String) {
        #expect(DeskID.find(in: line) == nil)
    }

    @Test("The first id on a line wins")
    func firstWins() {
        #expect(DeskID.find(in: "CO03C102 replaces CO03C117")?.text == "CO03C102")
    }
}
