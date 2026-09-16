import Foundation
import Testing
@testable import OfficeDaze

/// The parser, driven from lines written to match the three pages the
/// booking system prints, photographed on 14 September 2026.
///
/// Every page here is a literal. That is the point of the seam: a reading is
/// a list of strings, so the cases that matter — a row with its date cut off,
/// a date with its row cut off, a cancelled row, a page scrolled past its
/// heading — can be written down rather than photographed. The readings
/// Vision produces in the office join these as JSON fixtures; they do not
/// replace them.
@Suite("The booking parser")
struct BookingParserTests {

    // MARK: The pages

    /// "My reservations", as photographed: five dates, five bookings.
    static let list = """
        My reservations
        2026-09-16
        Times shown based on building location
        Reservation f...
        CO03C108
        03, Coleman, London
        08:00 - 17:00
        Europe/London
        Christopher Gregory
        Confirmed
        2026-10-05
        Times shown based on building location
        Reservation f...
        CO03C102
        03, Coleman, London
        08:00 - 17:00
        Europe/London
        Christopher Gregory
        Confirmed
        2026-10-06
        Times shown based on building location
        Reservation f...
        CO03D218
        03, Coleman, London
        08:00 - 17:00
        Europe/London
        Christopher Gregory
        Confirmed
        2026-10-07
        Times shown based on building location
        Reservation f...
        CO03C117
        03, Coleman, London
        08:00 - 17:00
        Europe/London
        Christopher Gregory
        Confirmed
        2026-10-08
        Times shown based on building location
        Reservation f...
        CO03C117
        03, Coleman, London
        08:00 - 17:00
        Europe/London
        Christopher Gregory
        Confirmed
        """

    /// The reservation's own page, as photographed: heading scrolled off,
    /// reserved-items block in frame.
    static let summary = """
        Reservation Number
        WRES2011757
        Location
        Campus
        London
        Buildings
        Coleman
        Time details
        Starts
        2026-10-05 08:00
        Europe/London
        Ends
        2026-10-05 17:00
        Europe/London
        Duration
        9 Hours
        Shift schedule
        All day
        Shift details
        All day(08:00 - 17:00) - All day
        Created
        just now
        Updated
        just now
        Meeting details
        Reservation organizer
        Christopher Gregory
        Reserved items (1)
        Coleman
        London
        1 Desks
        2026-10-05 • 08:00 - 17:00 Europe/London
        CO03C102
        03, Coleman, London
        Confirmed
        """

    /// The "Reservation details" form, as photographed.
    static let details = """
        Home > Reservation Details
        Reservation details
        Reservation subject
        Reservation for CO03C102
        This reservation is for
        Christopher Gregory
        Coleman · London
        2026-09-14 • 11:00 - 17:00 Europe/London
        CO03C102
        03, Coleman, London
        Seats 1
        Add extra services
        """

    static func lines(_ page: String) -> [String] {
        page.split(separator: "\n").map(String.init)
    }

    static func parse(_ page: String) -> [ParsedBooking] {
        BookingParser.parse(DocumentReading(blocks: [.init(page, top: 1)]))
    }

    // MARK: Layouts

    @Test("Each page is recognised for what it is")
    func layouts() {
        #expect(BookingParser.layout(of: Self.lines(Self.list)) == .list)
        #expect(BookingParser.layout(of: Self.lines(Self.summary)) == .summary)
        #expect(BookingParser.layout(of: Self.lines(Self.details)) == .details)
        #expect(BookingParser.layout(of: ["Building: Coleman", "Desk: CO03B424"]) == .unknown)
        #expect(BookingParser.layout(of: []) == .unknown)
    }

    // MARK: The list

    @Test("The list gives one booking per date, fully read")
    func readsTheWholeList() {
        let bookings = Self.parse(Self.list)
        #expect(bookings.map(\.day) == [
            Day(2026, 9, 16), Day(2026, 10, 5), Day(2026, 10, 6), Day(2026, 10, 7), Day(2026, 10, 8),
        ])
        #expect(bookings.map(\.deskID) == ["CO03C108", "CO03C102", "CO03D218", "CO03C117", "CO03C117"])
        #expect(bookings.map(\.zone) == ["C", "C", "D", "C", "C"])
        #expect(bookings.allSatisfy { $0.officeName == "Coleman, London" })
        #expect(bookings.allSatisfy { $0.floor == "03" })
        #expect(bookings.allSatisfy { $0.startTime == "08:00" && $0.endTime == "17:00" })
        #expect(bookings.allSatisfy { !$0.needsChecking }, "\(bookings.map(\.unsureFields))")
    }

    /// The top of a photograph: a booking card whose date card is above the
    /// edge. It has no date, and the date beneath it belongs to the next row.
    @Test("A row above the first date is dropped, not filed under the date below")
    func rowCutOffAtTheTop() {
        let page = """
            CO03C108
            03, Coleman, London
            08:00 - 17:00
            Confirmed
            2026-10-05
            Times shown based on building location
            CO03C102
            03, Coleman, London
            08:00 - 17:00
            Confirmed
            """
        let bookings = Self.parse(page)
        #expect(bookings.map(\.deskID) == ["CO03C102"])
        #expect(bookings.map(\.day) == [Day(2026, 10, 5)])
    }

    /// The bottom of a photograph: a date card whose booking is below the
    /// edge. A date with nothing under it is not a booking.
    @Test("A date with no row beneath it produces nothing")
    func dateCutOffAtTheBottom() {
        let page = """
            2026-10-05
            Times shown based on building location
            CO03C102
            03, Coleman, London
            08:00 - 17:00
            Confirmed
            2026-10-06
            Times shown based on building location
            """
        #expect(Self.parse(page).map(\.deskID) == ["CO03C102"])
    }

    /// The status column is the right-hand edge of the list, and a phone held
    /// close enough to read the desk ids is often too close to keep it in
    /// frame. The row is still a row the booking system holds.
    @Test("A row without a status is a booking: its place in the list is its confirmation")
    func rowWithoutStatus() {
        let page = """
            2026-10-05
            Times shown based on building location
            CO03C102
            03, Coleman, London
            08:00 - 17:00
            2026-10-06
            Times shown based on building location
            CO03D218
            03, Coleman, London
            08:00 - 17:00
            """
        let bookings = Self.parse(page)
        #expect(bookings.map(\.deskID) == ["CO03C102", "CO03D218"])
        #expect(bookings.map(\.day) == [Day(2026, 10, 5), Day(2026, 10, 6)])
        #expect(bookings.allSatisfy { !$0.needsChecking }, "\(bookings.map(\.unsureFields))")
    }

    /// The rule the user set: the column is not read. A row in the list is a
    /// booking the system holds, and whatever word sits at its edge does not
    /// change that.
    @Test("The status column is not read: a row is a booking whatever it says", arguments: [
        "Confirmed", "Cancelled", "Canceled", "Pending", "Waitlisted", "Declined",
    ])
    func statusColumnIsNotRead(_ status: String) {
        let page = """
            2026-10-05
            CO03C102
            03, Coleman, London
            08:00 - 17:00
            \(status)
            2026-10-06
            CO03D218
            03, Coleman, London
            08:00 - 17:00
            Confirmed
            """
        #expect(Self.parse(page).map(\.deskID) == ["CO03C102", "CO03D218"])
    }

    @Test("Two rows under one date are two bookings on that day")
    func twoRowsOneDate() {
        let page = """
            2026-10-05
            CO03C102
            03, Coleman, London
            08:00 - 12:00
            Confirmed
            CO03D218
            03, Coleman, London
            13:00 - 17:00
            Confirmed
            """
        let bookings = Self.parse(page)
        #expect(bookings.map(\.deskID) == ["CO03C102", "CO03D218"])
        #expect(bookings.map(\.day) == [Day(2026, 10, 5), Day(2026, 10, 5)])
        #expect(bookings.map(\.startTime) == ["08:00", "13:00"])
        #expect(bookings.map(\.endTime) == ["12:00", "17:00"])
    }

    /// The card's cells sit on one line, and Vision may return them in any
    /// order. The section is read as a bag, not a sequence.
    @Test("The order of a row's cells does not matter")
    func cellOrderIsIrrelevant() {
        let page = """
            2026-10-05
            Confirmed
            08:00 - 17:00
            Christopher Gregory
            03, Coleman, London
            CO03C102
            """
        let booking = Self.parse(page).first
        #expect(booking?.deskID == "CO03C102")
        #expect(booking?.startTime == "08:00")
        #expect(booking?.floor == "03")
        #expect(booking?.officeName == "Coleman, London")
    }

    @Test("A date card read together with its caption is still a date")
    func dateGluedToItsCaption() {
        let page = """
            2026-10-05 Times shown based on building location
            CO03C102
            Confirmed
            """
        #expect(Self.parse(page).map(\.day) == [Day(2026, 10, 5)])
    }

    @Test("A misread desk id is corrected before it is filed")
    func misreadIdInTheList() {
        let page = """
            2026-10-05
            CО0ЗC102
            03, Coleman, London
            Confirmed
            """
        #expect(Self.parse(page).map(\.deskID) == ["CO03C102"])
    }

    // MARK: A page about one reservation

    @Test("The reservation page is one booking, read from its reserved-items block")
    func readsTheSummaryPage() throws {
        let booking = try #require(Self.parse(Self.summary).first)
        #expect(Self.parse(Self.summary).count == 1)
        #expect(booking.day == Day(2026, 10, 5))
        #expect(booking.deskID == "CO03C102")
        #expect(booking.floor == "03")
        #expect(booking.zone == "C")
        #expect(booking.startTime == "08:00")
        #expect(booking.endTime == "17:00")
        #expect(booking.officeName == "Coleman, London")
        #expect(!booking.needsChecking)
    }

    /// The same page, photographed before scrolling: heading in frame,
    /// reserved-items block below the edge. The desk comes from the heading,
    /// the date from `Starts`, the building from its label, and the floor and
    /// zone from the id.
    @Test("The reservation page still reads when only its heading is in frame")
    func readsTheSummaryHeading() throws {
        let page = """
            Reservation for CO03C117
            Reservation Number
            WRES1946519
            Location
            Campus
            London
            Buildings
            Coleman
            Time details
            Starts
            2026-09-07 08:00
            Europe/London
            Ends
            2026-09-07 17:00
            Europe/London
            Duration
            9 Hours
            """
        let booking = try #require(Self.parse(page).first)
        #expect(booking.deskID == "CO03C117")
        #expect(booking.day == Day(2026, 9, 7))
        #expect(booking.startTime == "08:00")
        #expect(booking.endTime == "17:00")
        #expect(booking.officeName == "Coleman")
        #expect(booking.floor == "03")
        #expect(booking.zone == "C")
        #expect(!booking.needsChecking)
    }

    @Test("The details form is one booking, for the day it names")
    func readsTheDetailsForm() throws {
        let booking = try #require(Self.parse(Self.details).first)
        #expect(Self.parse(Self.details).count == 1)
        #expect(booking.day == Day(2026, 9, 14))
        #expect(booking.deskID == "CO03C102")
        #expect(booking.startTime == "11:00")
        #expect(booking.endTime == "17:00")
        #expect(booking.floor == "03")
        #expect(booking.zone == "C")
        #expect(booking.officeName == "Coleman, London")
    }

    @Test("A reservation page is a booking whatever status word it prints")
    func summaryStatusIsNotRead() {
        let read = Self.parse(Self.summary.replacing("Confirmed", with: "Cancelled"))
        #expect(read.map(\.deskID) == Self.parse(Self.summary).map(\.deskID))
    }

    /// The layout the old prompt called the second: a confirmation email with
    /// labelled fields and a timestamp. The end time is not stated, so it is
    /// the working day's, and not flagged.
    @Test("A confirmation email reads as one booking with the default end")
    func readsAnEmail() throws {
        let page = """
            Your desk is booked
            Building: Coleman
            Floor: 03
            Desk: CO03B424
            Date: 2026-08-25 09:00:00 CEST
            """
        let booking = try #require(Self.parse(page).first)
        #expect(booking.day == Day(2026, 8, 25))
        #expect(booking.deskID == "CO03B424")
        #expect(booking.startTime == "09:00")
        #expect(booking.endTime == "17:00")
        #expect(booking.officeName == "Coleman")
        #expect(booking.floor == "03")
        #expect(!booking.unsureFields.contains("endTime"))
    }

    @Test("A page with a desk but no date is not a booking")
    func noDateNoBooking() {
        #expect(Self.parse("Reservation for CO03C117\nBuildings\nColeman").isEmpty)
    }

    @Test("A page with a date but no desk is not a booking")
    func noDeskNoBooking() {
        #expect(Self.parse("Reservation Number\n2026-10-05 • 08:00 - 17:00").isEmpty)
    }

    @Test("A photograph of something else is nothing")
    func nothingIsNothing() {
        #expect(Self.parse("Funds\nESA\nSystems\nTeam\nOffice").isEmpty)
        #expect(BookingParser.parse(DocumentReading()).isEmpty)
    }

    // MARK: The past

    /// The list photographed on 14 September starts on the 16th. Seen from
    /// 6 October, the first two have gone and today's is still a booking.
    @Test("Bookings before today are set aside, and today's is kept")
    func thePastIsSetAside() {
        let reading = DocumentReading(blocks: [.init(Self.list, top: 1)])
        #expect(BookingParser.parse(reading, from: Day(2026, 10, 6)).map(\.day) == [
            Day(2026, 10, 6), Day(2026, 10, 7), Day(2026, 10, 8),
        ])
        #expect(BookingParser.parse(reading, from: Day(2026, 9, 14)).count == 5, "nothing has passed yet")
        #expect(BookingParser.parse(reading, from: Day(2026, 10, 9)).isEmpty, "everything has")
        #expect(BookingParser.parse(reading).count == 5, "and the unfiltered read still has them all")
    }

    // MARK: Floor and zone

    /// Two sources for the floor: the id and the page. When they disagree,
    /// one of them is misread and there is no way to say which.
    @Test("A floor the id and the page disagree on is left unread")
    func floorDisagreement() throws {
        let page = """
            2026-10-05
            CO03C102
            04, Coleman, London
            Confirmed
            """
        let booking = try #require(Self.parse(page).first)
        #expect(booking.floor == nil)
        #expect(booking.unsureFields.contains("floor"))
    }

    @Test("A floor the page prints as 3 and the id as 03 is one floor")
    func floorPaddingAgrees() throws {
        let page = """
            2026-10-05
            CO03C102
            3, Coleman, London
            Confirmed
            """
        let booking = try #require(Self.parse(page).first)
        #expect(booking.floor == "3")
        #expect(!booking.unsureFields.contains("floor"))
    }

    /// The Brussels office's scheme is unknown. Its id is accepted; its
    /// floor comes from the page and its zone from nowhere.
    @Test("An id from an unknown site gives up nothing, and the page stands alone")
    func unknownSite() throws {
        let page = """
            2026-10-05
            BR02A014
            02, Brussels
            08:00 - 17:00
            Confirmed
            """
        let booking = try #require(Self.parse(page).first)
        #expect(booking.deskID == "BR02A014")
        #expect(booking.floor == "02")
        #expect(booking.zone == nil)
        #expect(booking.unsureFields == ["zone"])
    }

    @Test("A page with nothing but the id still knows its floor, zone and office")
    func floorFromTheIdAlone() throws {
        let page = """
            2026-10-05
            CO03C102
            Confirmed
            """
        let booking = try #require(Self.parse(page).first)
        #expect(booking.floor == "03")
        #expect(booking.zone == "C")
        #expect(booking.officeName == "Coleman, London", "CO is Coleman, and the sheet need not ask")
        #expect(booking.unsureFields == ["startTime"])
    }

    /// The page's own words come first. The site code only fills a gap.
    @Test("An office the page prints is kept over the one the id decodes to")
    func printedOfficeWins() throws {
        let page = """
            2026-10-05
            CO03C102
            03, Coleman Annexe, London
            Confirmed
            """
        #expect(try #require(Self.parse(page).first).officeName == "Coleman Annexe, London")
    }

    @Test("An id from an unknown site names no office, and the sheet asks")
    func unknownSiteNamesNoOffice() throws {
        let page = """
            2026-10-05
            BR02A014
            Confirmed
            """
        #expect(try #require(Self.parse(page).first).officeName == nil)
    }

    // MARK: Reading a line

    @Test("A line states its facts", arguments: [
        ("2026-09-16", [BookingParser.Line.date("2026-09-16")]),
        ("2026-09-16 Times shown", [.date("2026-09-16")]),
        ("2026-10-05 • 08:00 - 17:00 Europe/London",
         [.dateAndRange("2026-10-05", .init(start: "08:00", end: "17:00"))]),
        ("2026-10-05 08:00", [.stamp(date: "2026-10-05", time: "08:00")]),
        ("Date: 2026-08-25 09:00:00 CEST", [.stamp(date: "2026-08-25", time: "09:00")]),
        ("08:00 - 17:00", [.range(.init(start: "08:00", end: "17:00"))]),
        ("8:00 – 17:00", [.range(.init(start: "08:00", end: "17:00"))]),
        ("All day(08:00 - 17:00) - All day", [.range(.init(start: "08:00", end: "17:00"))]),
        ("Confirmed", []),
        ("CANCELLED", []),
        ("Christopher Gregory Confirmed", []),
        ("03, Coleman, London", [.location(.init(floor: "03", office: "Coleman, London"))]),
        ("Coleman · London", [.location(.init(floor: nil, office: "Coleman, London"))]),
        ("Reservation for CO03C102", [.desk(DeskID.parse("CO03C102")!)]),
        ("Coleman • London • 1 Desks", []),
        ("Christopher Gregory", []),
        ("Europe/London", []),
        ("9 Hours", []),
        ("Reservation f...", []),
    ])
    func statesItsFacts(_ line: String, _ expected: [BookingParser.Line]) {
        #expect(BookingParser.facts(in: line) == expected, Comment(rawValue: line))
    }

    /// A whole row as one string, which is how Vision returned a drawn list.
    @Test("A row returned as one line states everything the row says")
    func aWholeRowOnOneLine() {
        let facts = BookingParser.facts(
            in: "Reservation f... CO03C102 03, Coleman, London 08:00 - 17:00 Europe/London Christopher Gregory Confirmed"
        )
        #expect(facts == [
            .desk(DeskID.parse("CO03C102")!),
            .range(.init(start: "08:00", end: "17:00")),
            .location(.init(floor: "03", office: "Coleman, London")),
        ])
    }

    @Test("A list whose rows came back as single lines reads the same")
    func rowsAsSingleLines() {
        let page = """
            2026-10-05 Times shown based on building location
            Reservation f... CO03C102 03, Coleman, London 08:00 - 17:00 Europe/London Christopher Gregory Confirmed
            2026-10-06 Times shown based on building location
            Reservation f... CO03D218 03, Coleman, London 08:00 - 17:00 Europe/London Christopher Gregory
            """
        let bookings = Self.parse(page)
        #expect(bookings.map(\.deskID) == ["CO03C102", "CO03D218"])
        #expect(bookings.map(\.day) == [Day(2026, 10, 5), Day(2026, 10, 6)])
        #expect(bookings.allSatisfy { $0.floor == "03" && $0.startTime == "08:00" })
    }

    @Test("The building label's value is found beneath it or beside it")
    func buildingValue() {
        #expect(BookingParser.buildingValue(in: ["Buildings", "Coleman", "Time details"]) == "Coleman")
        #expect(BookingParser.buildingValue(in: ["Building: Coleman"]) == "Coleman")
        #expect(BookingParser.buildingValue(in: ["Buildings"]) == nil)
        #expect(BookingParser.buildingValue(in: ["Location", "Campus"]) == nil)
    }

    // MARK: Through the reading

    /// The same list as a table rather than a column of paragraphs, which is
    /// the other thing Vision might return. Same bookings.
    @Test("A list Vision returned as a table reads the same as one it returned as paragraphs")
    func tableAndParagraphsAgree() {
        let asTable = DocumentReading(blocks: [
            .init(kind: .table, top: 0.9, rows: [
                ["2026-10-05"],
                ["CO03C102", "03, Coleman, London", "08:00 - 17:00", "Christopher Gregory", "Confirmed"],
                ["2026-10-06"],
                ["CO03D218", "03, Coleman, London", "08:00 - 17:00", "Christopher Gregory", "Confirmed"],
            ]),
        ])
        let asParagraphs = DocumentReading(blocks: [
            .init("2026-10-05", top: 0.9),
            .init("CO03C102\n03, Coleman, London", top: 0.8),
            .init("08:00 - 17:00", top: 0.8),
            .init("Confirmed", top: 0.8),
            .init("2026-10-06", top: 0.6),
            .init("CO03D218\n03, Coleman, London", top: 0.5),
            .init("08:00 - 17:00", top: 0.5),
            .init("Confirmed", top: 0.5),
        ])
        let fromTable = BookingParser.parse(asTable)
        let fromParagraphs = BookingParser.parse(asParagraphs)
        #expect(fromTable.map(\.deskID) == ["CO03C102", "CO03D218"])
        #expect(fromTable.map(\.day) == fromParagraphs.map(\.day))
        #expect(fromTable.map(\.deskID) == fromParagraphs.map(\.deskID))
        #expect(fromTable.map(\.startTime) == fromParagraphs.map(\.startTime))
    }
}
