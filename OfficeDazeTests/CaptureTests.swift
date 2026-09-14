import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import OfficeDaze

/// The reader's row and its mapping. The never-guess rule lives here — it is
/// enforced in the mapping rather than merely assumed of the reader, so it can
/// be tested from a row written by hand.
@Suite("Capture mapping")
struct CaptureMappingTests {

    /// Rows as JSON, decoded and mapped the way a reader's output is.
    func decode(_ rows: String) throws -> [ParsedBooking] {
        try JSONDecoder().decode(
            [CapturedBooking].self, from: Data("[\(rows)]".utf8)
        ).compactMap { $0.parsed() }
    }

    func row(
        office: String = "\"Coleman, London\"", date: String = "\"2026-08-05\"",
        desk: String = "\"CO03C407\"", floor: String = "\"03\"", zone: String = "null",
        start: String = "\"08:00\"", end: String = "\"17:00\"", unsure: String = "[\"zone\"]"
    ) -> String {
        """
        {"office":\(office),"date":\(date),"deskId":\(desk),"floor":\(floor),\
        "zone":\(zone),"startTime":\(start),"endTime":\(end),"unsureFields":\(unsure)}
        """
    }

    @Test("Every row of the table becomes a booking, in the order printed")
    func tableRows() throws {
        let bookings = try decode([
            row(date: "\"2026-08-04\"", desk: "\"CO03A424\""),
            row(date: "\"2026-08-05\"", desk: "\"CO03C407\""),
            row(date: "\"2026-08-06\"", desk: "\"CO03D211\""),
        ].joined(separator: ","))

        #expect(bookings.count == 3, "three rows, three bookings")
        #expect(bookings.map(\.deskID) == ["CO03A424", "CO03C407", "CO03D211"])
        #expect(bookings.map(\.day) == [Day(2026, 8, 4), Day(2026, 8, 5), Day(2026, 8, 6)])
    }

    /// The other layout the booking system sends: a confirmation email for one
    /// reservation, its details as labelled fields and its date a timestamp
    /// with a timezone the app does not handle. One booking, one day.
    @Test("A single-reservation confirmation becomes one booking on the day it names")
    func singleConfirmation() throws {
        let bookings = try decode(row(
            office: "\"Coleman\"", date: "\"2026-08-25 09:00:00 CEST\"",
            desk: "\"CO03B424\"", floor: "\"03\"", zone: "null",
            start: "\"09:00\"", end: "null", unsure: "[\"zone\",\"endTime\"]"
        ))

        #expect(bookings.count == 1, "this layout is one booking, never a range")
        let booking = try #require(bookings.first)
        #expect(booking.day == Day(2026, 8, 25), "the timezone beside it changes nothing")
        #expect(booking.deskID == "CO03B424")
        #expect(booking.floor == "03", "read from its own field, not split off the desk id")
        #expect(booking.officeName == "Coleman", "no city was printed, so none is added")
        #expect(booking.startTime == "09:00")
        #expect(booking.endTime == "17:00", "unprinted, so the working day's end stands in")
        #expect(!booking.unsureFields.contains("endTime"), "a default, not a question")
        #expect(booking.needsChecking, "the zone is still unread")
    }

    /// The end of the day is the one field the app answers for itself: a
    /// confirmation prints when the desk becomes yours and never when it stops.
    @Test("An unread end time defaults to 17:00 rather than being flagged")
    func endTimeDefaults() throws {
        let fromNull = try decode(row(end: "null", unsure: "[]"))
        #expect(fromNull.first?.endTime == "17:00")
        #expect(fromNull.first?.unsureFields.contains("endTime") == false)

        // Even a value the reader itself called unread gives way to the default.
        let fromUnsure = try decode(row(end: "\"19:00\"", unsure: "[\"endTime\"]"))
        #expect(fromUnsure.first?.endTime == "17:00")
        #expect(fromUnsure.first?.unsureFields.contains("endTime") == false)
    }

    /// The desk id is `CO03C407` — Coleman, floor 03, desk C407 — and the
    /// mapping stores it whole. The floor arrives in its own field.
    @Test("A site-coded desk id is stored whole, and the floor read separately")
    func deskIDIsNotSplit() throws {
        let bookings = try decode(row())
        let booking = try #require(bookings.first)
        #expect(booking.deskID == "CO03C407")
        #expect(booking.floor == "03")
    }

    /// The never-guess rule, enforced rather than trusted: a value that arrives
    /// beside its own name in unsureFields is exactly the plausible guess the
    /// design forbids storing, so the mapping drops it.
    @Test("A value contradicted by unsureFields is discarded, not stored")
    func honoursUnsureFields() throws {
        let bookings = try decode(row(floor: "\"03\"", unsure: "[\"floor\"]"))
        let booking = try #require(bookings.first)
        #expect(booking.floor == nil, "the reader named it unread; the value goes")
        #expect(booking.unsureFields.contains("floor"))
    }

    @Test("A field left blank without being named is still flagged")
    func namesSilentBlanks() throws {
        let bookings = try decode(row(zone: "null", start: "null", unsure: "[]"))
        let booking = try #require(bookings.first)
        #expect(booking.zone == nil)
        #expect(booking.unsureFields.contains("zone"))
        #expect(booking.unsureFields.contains("startTime"))
        #expect(booking.needsChecking)
    }

    @Test("A row with no readable date is dropped; the rest of the table survives")
    func partialTable() throws {
        let bookings = try decode([
            row(date: "null", unsure: "[\"date\"]"),
            row(date: "\"2026-08-06\"", desk: "\"CO03D211\""),
        ].joined(separator: ","))

        #expect(bookings.count == 1, "most of a table beats none of it")
        #expect(bookings.first?.deskID == "CO03D211")
    }

    /// The correction has to be on the path every capture takes, not on a
    /// helper the mapping forgot to call.
    @Test("A misread site code is corrected on the way out of the mapping")
    func correctsTheSiteCodeOnDecode() throws {
        let bookings = try decode(row(desk: "\"C003A424\""))
        #expect(bookings.first?.deskID == "CO03A424")
    }

    /// A row with no date and no desk is not a booking, and the mapping says
    /// so by producing none; turning that into the failure the user reads is
    /// `VisionExtractor`'s job.
    @Test("A row with nothing readable becomes no booking")
    func nothingReadable() throws {
        #expect(try decode(row(date: "null", unsure: "[\"date\"]")).isEmpty)
        #expect(try decode(row(desk: "null", unsure: "[\"deskId\"]")).isEmpty)
        #expect(try decode("").isEmpty)
    }

    /// A date reformatted into something else is a date we did not read.
    /// Guessing at 05/08/2026 is the day/month coin-flip the app must not make.
    @Test("Only ISO dates are accepted")
    func strictDates() {
        #expect(CapturedBooking.day(from: "2026-08-05") == Day(2026, 8, 5))
        #expect(CapturedBooking.day(from: "2026-08-05T08:00:00+01:00") == Day(2026, 8, 5))
        #expect(CapturedBooking.day(from: "2026-08-25 09:00:00 CEST") == Day(2026, 8, 25))
        #expect(CapturedBooking.day(from: "05/08/2026") == nil)
        #expect(CapturedBooking.day(from: "5 August 2026") == nil)
        #expect(CapturedBooking.day(from: "2026-13-05") == nil)
    }

    /// A day the calendar would have to move is a day we did not read. It used
    /// to be accepted on `1...31` alone, and `Day(2026, 2, 30)` then displayed
    /// as "Monday 2 March" while comparing unequal to the `Day(2026, 3, 2)` a
    /// stored booking reads back as — so the day's existing desk was invisible
    /// to the clash strip and to the merge, and the office ended with two.
    @Test("A date that does not exist is not a date we read", arguments: [
        "2026-02-30", "2026-04-31", "2026-02-29", "2026-00-05", "2026-08-00",
        "2026-08-32", "2026-06-31",
    ])
    func rejectsImpossibleDates(_ text: String) {
        #expect(CapturedBooking.day(from: text) == nil)
    }

    /// The other side of that guard: the last day of a month, and a real 29
    /// February, are dates and have to stay ones.
    @Test("The dates at the edges of a month are still read", arguments: [
        ("2024-02-29", Day(2024, 2, 29)),
        ("2026-02-28", Day(2026, 2, 28)),
        ("2026-04-30", Day(2026, 4, 30)),
        ("2026-12-31", Day(2026, 12, 31)),
    ])
    func acceptsTheEdgesOfAMonth(_ text: String, _ expected: Day) {
        #expect(CapturedBooking.day(from: text) == expected)
    }

    /// The value the parser hands on has to survive the round trip through
    /// storage, or nothing downstream can find the day it names.
    @Test("Every date the parser accepts stores and reads back as itself")
    func acceptedDatesRoundTrip() throws {
        for text in ["2026-08-05", "2024-02-29", "2026-04-30", "2026-12-31"] {
            let day = try #require(CapturedBooking.day(from: text))
            #expect(Day(of: day.startOfDayUTC) == day, "\(text)")
        }
    }
}

/// The site-code correction, which is the one reading the app may overrule
/// without guessing: the first two characters are letters, always.
@Suite("The site code")
struct SiteCodeTests {

    /// A photograph of a monitor came back `C003A424`, and the app does not
    /// have to be told twice.
    @Test("A digit in the site code is corrected to the letter it misread", arguments: [
        ("C003A424", "CO03A424"),
        ("C003C117", "CO03C117"),
        ("1O03A424", "IO03A424"),
        ("5O03A424", "SO03A424"),
        ("8R02D100", "BR02D100"),
    ])
    func correctsTheSiteCode(_ read: String, _ corrected: String) {
        #expect(CapturedBooking.correctingSiteCode(read) == corrected)
    }

    /// Everything past the first two characters is a floor and a desk, where
    /// digits are what belong.
    @Test("The rest of the id is left alone", arguments: [
        "CO03A424", "CO03C117", "CO00B100", "AB11C555",
    ])
    func leavesTheRestOfTheIDAlone(_ deskID: String) {
        #expect(CapturedBooking.correctingSiteCode(deskID) == deskID)
    }

    /// A 3 is not a letter that was misread — it is a 3. Correcting it would
    /// mean choosing a letter, which is the guess this app does not make.
    @Test("A digit with no letter behind it is left as it came back")
    func leavesAnUnreadableDigitAlone() {
        #expect(CapturedBooking.correctingSiteCode("C903A424") == "C903A424")
        // The first character is correctable and the second is not, so the
        // whole correction is abandoned rather than left half applied.
        #expect(CapturedBooking.correctingSiteCode("09O3A424") == "09O3A424")
        #expect(CapturedBooking.correctingSiteCode("C") == "C")
        #expect(CapturedBooking.correctingSiteCode("") == "")
    }
}

/// The check at the door. The reader runs on the phone and takes the frame
/// as it is, so the only question left here is whether the bytes are an
/// image at all.
@Suite("Checking an image at the door")
struct PhotoImportTests {

    @Test("An image of any size and format goes through untouched", arguments: [
        (UTType.png, 1, 1), (UTType.jpeg, 5712, 4284), (UTType.png, 1568, 1000),
    ])
    func imagesPassThrough(_ type: UTType, _ width: Int, _ height: Int) throws {
        let data = TestImage.make(width: width, height: height, type: type)
        #expect(try PhotoImport.prepare(data) == data)
    }

    @Test("A camera frame keeps its orientation header, for the reader to honour")
    func orientationIsKept() throws {
        let sideways = TestImage.make(width: 40, height: 30, type: .jpeg, orientation: 6)
        let passed = try PhotoImport.prepare(sideways)
        let source = try #require(CGImageSourceCreateWithData(passed as CFData, nil))
        #expect(DocumentReader.orientation(of: source) == .right)
    }

    @Test("A HEIC frame goes through as HEIC")
    func heicPassesThrough() throws {
        guard TestImage.canEncodeHEIC else { return }
        let data = TestImage.make(width: 64, height: 48, type: .heic)
        #expect(try PhotoImport.prepare(data) == data)
    }

    @Test("Bytes that are not an image are refused by name")
    func refusesNonImages() {
        #expect(throws: CaptureError.unreadableImage) { try PhotoImport.prepare(Data("%PDF-1.7".utf8)) }
        #expect(throws: CaptureError.unreadableImage) { try PhotoImport.prepare(Data()) }
    }
}

@Suite("Office matching")
struct OfficeMatcherTests {

    let london = OfficeMatcher.Candidate(
        id: UUID(), name: "Coleman", postcode: "EC2R 5BB", address: "London"
    )
    let brussels = OfficeMatcher.Candidate(
        id: UUID(), name: "Brussels", postcode: "1040", address: "Rue de la Loi 42"
    )

    var offices: [OfficeMatcher.Candidate] { [london, brussels] }

    @Test("The office name as printed matches the one the user typed")
    func matchesByName() {
        #expect(OfficeMatcher.match("Coleman, London", against: offices)?.id == london.id)
        #expect(OfficeMatcher.match("coleman", against: offices)?.id == london.id)
        #expect(OfficeMatcher.match("Brussels", against: offices)?.id == brussels.id)
    }

    @Test("A postcode is unambiguous, so it wins")
    func matchesByPostcode() {
        #expect(
            OfficeMatcher.match("Somewhere, EC2R 5BB", against: offices)?.id == london.id
        )
    }

    /// Two offices in one building is a shape the app invites — a floor and its
    /// annexe, each with its own colour and perimeter. A postcode shared by
    /// both stops being the unambiguous thing, so it stops deciding.
    @Test("A postcode two offices share decides nothing on its own")
    func aSharedPostcodeIsNotAnAnswer() {
        let annexe = OfficeMatcher.Candidate(
            id: UUID(), name: "Ropemaker Annexe", postcode: "EC2R 5BB", address: "London"
        )
        // The name tells them apart, so the answer is the annexe — not
        // whichever of the two the fetch happened to return first.
        #expect(
            OfficeMatcher.match("Ropemaker Annexe, EC2R 5BB", against: [london, annexe])?.id
                == annexe.id,
            "the postcode no longer preempts the name rule that can decide"
        )
        // And where the name cannot tell them apart, nothing does: this is the
        // question the sheet has to ask.
        #expect(
            OfficeMatcher.match("Somewhere, EC2R 5BB", against: [london, annexe]) == nil,
            "one of two buildings picked by fetch order is the wrong perimeter half the time"
        )
    }

    /// A wrong match files a booking under the wrong building — worse than
    /// asking, so anything short of certain returns nil and the sheet asks.
    @Test("No match, and an ambiguous match, both return nothing")
    func refusesToGuess() {
        #expect(OfficeMatcher.match("Ropemaker Place", against: offices) == nil)
        #expect(OfficeMatcher.match(nil, against: offices) == nil)
        #expect(OfficeMatcher.match("", against: offices) == nil)
        #expect(OfficeMatcher.match("Coleman", against: []) == nil)

        let twins = [
            london,
            OfficeMatcher.Candidate(id: UUID(), name: "Coleman", postcode: "", address: "Leeds"),
        ]
        #expect(OfficeMatcher.match("Coleman", against: twins) == nil, "two look right; ask")
    }

    /// The floor number in "03, Coleman, London" is not a building name.
    @Test("Noise words and floor numbers do not break the match")
    func ignoresNoise() {
        #expect(OfficeMatcher.match("03, Coleman, London", against: offices)?.id == london.id)
        #expect(
            OfficeMatcher.match("The Coleman Building", against: offices)?.id == london.id
        )
    }

    // MARK: What the sheet was told

    /// An office saved as "Euroclear London" shares only the city with a
    /// printed "Coleman, London", so no rule here can match them and the sheet
    /// asks. Once answered, it must stop asking.
    let euroclear = OfficeMatcher.Candidate(
        id: UUID(), name: "Euroclear London", postcode: "", address: "",
        aliases: ["Coleman, London"]
    )

    @Test("A name the sheet was told about matches, where no rule could")
    func matchesByAlias() {
        #expect(OfficeMatcher.match("Coleman, London", against: [euroclear])?.id == euroclear.id)
        #expect(
            OfficeMatcher.match("Coleman, London", against: [brussels]) == nil,
            "an office without the alias is still no match"
        )
    }

    /// The same building prints with a floor in front of it on some rows and
    /// not on others. An alias taught by one row has to hold for the next.
    @Test("An alias is the same answer with the floor in front of it")
    func aliasIgnoresTheFloor() {
        #expect(
            OfficeMatcher.match("03, Coleman, London", against: [euroclear])?.id == euroclear.id
        )
        #expect(
            OfficeMatcher.match("coleman london", against: [euroclear])?.id == euroclear.id
        )
    }

    /// An alias is an answer, not a heuristic — it outranks the name rule that
    /// would otherwise have claimed this printed name for somebody else.
    @Test("An alias beats a name that merely looks right")
    func aliasWinsOverTheNameRule() {
        let taught = OfficeMatcher.Candidate(
            id: UUID(), name: "Euroclear London", postcode: "", address: "",
            aliases: ["Coleman"]
        )
        let matched = OfficeMatcher.match("Coleman", against: [london, taught])
        #expect(matched?.id == taught.id, "the answer wins over the resemblance")
    }

    /// Every word in "Level 5" is either a noise word or a number, so it
    /// tokenises to nothing — and a name that tokenises to nothing used to
    /// match no alias at all, including its own. The sheet asked forever and
    /// the office collected a copy of the answer each time.
    @Test("A name made only of noise words and numbers is still recognisable")
    func namesThatTokeniseToNothing() {
        #expect(OfficeMatcher.matches("Level 5", "Level 5"))
        #expect(OfficeMatcher.matches("The Building", "the building"))
        #expect(OfficeMatcher.matches(" Level 5 ", "Level 5"), "as printed, spacing and all")

        let taught = OfficeMatcher.Candidate(
            id: UUID(), name: "Euroclear London", postcode: "", address: "",
            aliases: ["Level 5"]
        )
        #expect(OfficeMatcher.match("Level 5", against: [taught])?.id == taught.id)
    }

    /// The fallback is a comparison, not a surrender: two different names that
    /// both tokenise to nothing are still two different names.
    @Test("Two different noise-only names are not the same name")
    func differentNoiseOnlyNamesDoNotMatch() {
        #expect(OfficeMatcher.matches("Level 5", "Level 6") == false)
        #expect(OfficeMatcher.matches("Level 5", "The Building") == false)
        #expect(OfficeMatcher.matches("Level 5", "Coleman") == false, "and neither is a real one")

        let taught = OfficeMatcher.Candidate(
            id: UUID(), name: "Euroclear London", postcode: "", address: "",
            aliases: ["Level 5"]
        )
        #expect(
            OfficeMatcher.match("Level 6", against: [taught]) == nil,
            "the floor above is a different answer, and asking is the right one"
        )
    }

    /// An accent is not a reason to ask a question the user has already
    /// answered by typing the name.
    @Test("An accent typed one way and printed another is the same building")
    func accentsFold() {
        let zurich = OfficeMatcher.Candidate(
            id: UUID(), name: "Zurich", postcode: "", address: ""
        )
        #expect(OfficeMatcher.match("Zürich", against: [zurich])?.id == zurich.id)
        #expect(
            OfficeMatcher.match("Zagreb", against: [zurich]) == nil,
            "folding accents is not the same as ignoring letters"
        )
    }

    /// Nothing should ever write this, since remembering strips the name off
    /// every other office. If it happens anyway, asking beats picking one.
    @Test("Two offices claiming one name is still a question")
    func twoClaimsAskAgain() {
        let rival = OfficeMatcher.Candidate(
            id: UUID(), name: "Euroclear Leeds", postcode: "", address: "",
            aliases: ["Coleman, London"]
        )
        #expect(OfficeMatcher.match("Coleman, London", against: [euroclear, rival]) == nil)
    }
}
