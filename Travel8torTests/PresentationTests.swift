import Foundation
import SwiftData
import Testing
@testable import Travel8tor

@Suite("Abbreviation")
struct AbbreviateTests {

    @Test("A supplied code always wins")
    func codeWins() {
        #expect(Abbreviate.station("King's Cross", code: "KGX") == "KGX")
        #expect(Abbreviate.station("Somewhere Unknown", code: "SWU") == "SWU")
    }

    @Test("Known stations fall back to the table")
    func table() {
        #expect(Abbreviate.station("King's Cross") == "KGX")
        #expect(Abbreviate.station("St Pancras") == "STP")
        #expect(Abbreviate.station("Brussels Midi") == "MIDI")
    }

    @Test("An unknown station keeps its full name rather than being truncated")
    func unknownStation() {
        // A truncation could read as a different station, which is worse than
        // a long label.
        #expect(Abbreviate.station("Newcastle Central") == "NEWCASTLE CENTRAL")
        #expect(Abbreviate.station("Durham", code: "") == "DURHAM")
    }

    @Test("Only the trailing word of a place is abbreviated")
    func places() {
        #expect(Abbreviate.place("Ropemaker Place") == "ROPEMAKER PL")
        #expect(Abbreviate.place("41 Rivington Street") == "41 RIVINGTON ST")
        #expect(Abbreviate.place("Place Farm Road") == "PLACE FARM RD")
        #expect(Abbreviate.place("Broadgate") == "BROADGATE")
    }
}

@Suite("Booking presentation")
@MainActor
struct BookingPresentationTests {

    let terminator: @Sendable (T8Label) -> String = { $0.terminator }
    let plain: @Sendable (T8Label) -> String = { $0.plain }

    /// The container is held for the life of the test. A `@Model` is a live
    /// reference into its context, so letting the container fall out of scope
    /// leaves every fetched object a trap — Swift Testing makes a fresh suite
    /// instance per test, so this is per-test isolation as well.
    let container: ModelContainer

    init() throws {
        container = try Store.makeInMemoryContainer(seeded: true)
    }

    func seeded() throws -> [Booking] {
        try container.mainContext.fetch(FetchDescriptor<Booking>())
    }

    /// The lookup runs before `#require` rather than inside it: `#require` takes
    /// an autoclosure, which would force the predicate to be escaping.
    func booking(_ bookings: [Booking], where predicate: (Booking) -> Bool) throws -> Booking {
        let found = bookings.first(where: predicate)
        return try #require(found)
    }

    @Test("A domestic rail card carries no UK line")
    func domesticRail() throws {
        let all = try seeded()
        let lner = try booking(all) {
            $0.detail?.railDetail?.operatorName == "LNER" && $0.anchorDay == Day(2026, 9, 7)
        }
        let presented = try #require(BookingPresenter.present(lner, copy: terminator))

        #expect(presented.typeCode == "[RAIL] LNER")
        #expect(presented.figure == "06:40")
        #expect(presented.figureSubtitle == nil, "a UK event never carries a UK line")
        #expect(presented.title == "DURHAM → KGX")
        #expect(presented.metadata == ["PLAT 2", "CCH B", "SEAT 12"])
        #expect(presented.flag == nil)
    }

    @Test("A foreign departure carries the UK equivalent beneath it")
    func foreignRail() throws {
        let all = try seeded()
        // The Thursday return leaves Brussels at 17:52, which is 16:52 UK.
        let eurostar = try booking(all) {
            $0.detail?.railDetail?.originCity == "Brussels"
        }
        let presented = try #require(BookingPresenter.present(eurostar, copy: terminator))

        #expect(presented.figure == "17:52")
        #expect(presented.figureSubtitle == "16:52 UK")
        #expect(presented.title == "MIDI → STP")
    }

    @Test("The compact card carries the arrival inline instead of seat details")
    func compactRail() throws {
        let all = try seeded()
        let outbound = try booking(all) { $0.detail?.railDetail?.destCity == "Brussels" }
        let presented = try #require(
            BookingPresenter.present(outbound, copy: terminator, compact: true)
        )
        #expect(presented.metadata == ["ARR 20:05 (19:05 UK) ▪ 09/51"])
    }

    @Test("An unread check-in shows the placeholder, never a blank or a guess")
    func unreadCheckIn() throws {
        let all = try seeded()
        let ropewalk = try booking(all) { $0.detail?.stayDetail?.hotelName == "The Ropewalk" }
        let presented = try #require(BookingPresenter.present(ropewalk, copy: terminator))

        #expect(presented.figure == "??:??")
        #expect(presented.figureSubtitle == nil)
        #expect(presented.incomplete)
        #expect(presented.emphasis == .pending, "an unread booking must not read as confirmed")
        #expect(presented.flag == "DATA INCOMPLETE ▪ 02 FIELDS")
        #expect(presented.typeCode == "[STAY] 1 NIGHT")
    }

    @Test("A complete stay renders its check-in and no flag")
    func completeStay() throws {
        let all = try seeded()
        let sablon = try booking(all) { $0.detail?.stayDetail?.hotelName == "Hotel Sablon" }
        let presented = try #require(BookingPresenter.present(sablon, copy: terminator))

        #expect(presented.figure == "21:00")
        #expect(presented.figureSubtitle == "20:00 UK")
        #expect(presented.typeCode == "[STAY] 3 NIGHTS")
        #expect(presented.flag == nil)
        #expect(presented.emphasis == .full)
    }

    @Test("Desk cards abbreviate the building and name the count")
    func desk() throws {
        let all = try seeded()
        let desk = try booking(all) { $0.detail?.deskDetail?.deskID == "3C-118" }
        let presented = try #require(BookingPresenter.present(desk, copy: terminator))

        #expect(presented.typeCode == "[DESK] TERMINATES 1")
        #expect(presented.figure == "3C-118")
        #expect(presented.title == "ROPEMAKER PL")
    }

    @Test("Plain copy mode changes the labels and nothing else")
    func plainCopy() throws {
        let all = try seeded()
        let desk = try booking(all) { $0.detail?.deskDetail?.deskID == "3C-118" }
        let terminatorCard = try #require(BookingPresenter.present(desk, copy: terminator))
        let plainCard = try #require(BookingPresenter.present(desk, copy: plain))

        #expect(plainCard.typeCode == "[DESK] COUNTS 1")
        #expect(plainCard.figure == terminatorCard.figure)
        #expect(plainCard.title == terminatorCard.title)

        let ropewalk = try booking(all) { $0.detail?.stayDetail?.hotelName == "The Ropewalk" }
        let plainStay = try #require(BookingPresenter.present(ropewalk, copy: plain))
        #expect(plainStay.flag == "NEEDS CHECKING ▪ 02 FIELDS")
    }
}

@Suite("Targets feed")
@MainActor
struct TargetsFeedTests {

    let container: ModelContainer

    init() throws {
        container = try Store.makeInMemoryContainer(seeded: true)
    }

    func store() throws -> (bookings: [Booking], trips: [Trip]) {
        let context = container.mainContext
        return (
            try context.fetch(FetchDescriptor<Booking>(sortBy: [SortDescriptor(\.startsAt)])),
            try context.fetch(FetchDescriptor<Trip>(sortBy: [SortDescriptor(\.startsOnDate)]))
        )
    }

    @Test("Near bookings expand by day; far trips collapse to a card")
    func twoModes() throws {
        let (bookings, trips) = try store()
        let sections = TargetsFeed.build(bookings: bookings, trips: trips, today: Day(2026, 8, 4))

        #expect(sections.map(\.kicker) == ["INBOUND", "SEPTEMBER"])

        // August's four bookings sit on two days, expanded.
        let inbound = sections[0].rows
        #expect(inbound.count == 2)
        if case .day(let day, let items) = inbound[0] {
            #expect(day == Day(2026, 8, 5))
            #expect(items.count == 2)
        } else {
            Issue.record("expected a day row")
        }

        // September is one trip card, not eight cards.
        let september = sections[1].rows
        #expect(september.count == 1)
        if case .trip(let trip, let children) = september[0] {
            #expect(trip.primaryCity == "London")
            #expect(trip.parentTripID == nil, "the card is the root trip, not the child")
            #expect(children.map(\.primaryCity) == ["Brussels"])
        } else {
            Issue.record("expected a trip row")
        }
    }

    @Test("Past bookings drop out of the feed")
    func pastDropsOut() throws {
        let (bookings, trips) = try store()
        let sections = TargetsFeed.build(bookings: bookings, trips: trips, today: Day(2026, 9, 11))
        let days = sections.flatMap(\.rows).compactMap { row -> Day? in
            if case .day(let day, _) = row { return day } else { return nil }
        }
        #expect(days.allSatisfy { $0 >= Day(2026, 9, 11) })
    }

    @Test("An empty store produces no sections rather than an empty INBOUND")
    func empty() {
        #expect(TargetsFeed.build(bookings: [], trips: [], today: Day(2026, 8, 4)).isEmpty)
    }

    @Test("The trip card's segment weights reproduce the mock")
    func segmentWeights() throws {
        let (bookings, trips) = try store()
        let week = try #require(trips.first { $0.startsOn == Day(2026, 9, 7) && $0.parentTripID == nil })
        let tree = TargetsFeed.bookings(inTripTree: week, trips: trips, bookings: bookings)

        #expect(tree.count == 8, "the child trip's bookings are included")
        let weights = tree.compactMap { $0.detail.map(TargetsFeed.segmentWeight(for:)) }
        #expect(weights == [1, 2, 1, 5, 1, 2, 2, 1])
    }

    @Test("Termination count is desk days, not bookings")
    func terminationCount() throws {
        let (bookings, trips) = try store()
        let week = try #require(trips.first { $0.startsOn == Day(2026, 9, 7) && $0.parentTripID == nil })
        let tree = TargetsFeed.bookings(inTripTree: week, trips: trips, bookings: bookings)
        // Eight bookings, two of which are desks: the subtitle reads 02.
        #expect(TargetsFeed.quotaDayCount(in: tree) == 2)
    }
}

@Suite("Mission grid")
struct MissionGridTests {

    @Test("August 2026 lays out with no leading blanks and 21 weekdays")
    func layout() {
        let cells = MissionGrid.cells(.init(
            month: Month(year: 2026, month: 8),
            attended: [], deskBookingDays: [], leave: [:], today: Day(2026, 8, 4)
        ))
        // 1 August is a Saturday, so the first weekday is Monday the 3rd —
        // column 0, no padding.
        #expect(cells.compactMap { $0 }.count == 21)
        #expect(cells.first??.day == Day(2026, 8, 3))
    }

    @Test("A month starting mid-week is padded so the columns line up")
    func padding() {
        // 1 September 2026 is a Tuesday: one blank before it.
        let cells = MissionGrid.cells(.init(
            month: Month(year: 2026, month: 9),
            attended: [], deskBookingDays: [], leave: [:], today: Day(2026, 9, 1)
        ))
        #expect(cells[0] == nil)
        #expect(cells[1]?.day == Day(2026, 9, 1))
    }

    @Test("States follow the design's precedence")
    func states() {
        let cells = MissionGrid.cells(.init(
            month: Month(year: 2026, month: 8),
            attended: [Day(2026, 8, 3), Day(2026, 8, 4)],
            deskBookingDays: [Day(2026, 8, 5), Day(2026, 8, 6), Day(2026, 8, 3)],
            leave: [Day(2026, 8, 17): 1.0, Day(2026, 8, 18): 1.0, Day(2026, 8, 19): 1.0],
            today: Day(2026, 8, 4)
        ))
        func state(_ day: Day) -> MissionGrid.State? {
            cells.compactMap { $0 }.first { $0.day == day }?.state
        }

        #expect(state(Day(2026, 8, 3)) == .attended, "attendance beats a booking on the same day")
        #expect(state(Day(2026, 8, 4)) == .attended)
        #expect(state(Day(2026, 8, 5)) == .booked)
        #expect(state(Day(2026, 8, 17)) == .leave)
        #expect(state(Day(2026, 8, 31)) == .bankHoliday)
        #expect(state(Day(2026, 8, 7)) == .ordinary)
    }

    @Test("A desk booked for a past day is not shown as booked ahead")
    func pastBooking() {
        let cells = MissionGrid.cells(.init(
            month: Month(year: 2026, month: 8),
            attended: [], deskBookingDays: [Day(2026, 8, 3)], leave: [:],
            today: Day(2026, 8, 10)
        ))
        let state = cells.compactMap { $0 }.first { $0.day == Day(2026, 8, 3) }?.state
        #expect(state == .ordinary, "booked and not turned up for counts for nothing")
    }

    @Test("Consecutive leave days collapse into a range")
    func ranges() {
        #expect(MissionGrid.dayRanges([Day(2026, 8, 17), Day(2026, 8, 18), Day(2026, 8, 19)]) == "17–19")
        #expect(MissionGrid.dayRanges([Day(2026, 8, 3)]) == "03")
        #expect(
            MissionGrid.dayRanges([Day(2026, 8, 3), Day(2026, 8, 17), Day(2026, 8, 18)]) == "03, 17–18"
        )
        #expect(MissionGrid.dayRanges([]) == "")
    }

    @Test("The derivation panel reproduces the mock line for line")
    func derivation() {
        let leave = [Day(2026, 8, 17), Day(2026, 8, 18), Day(2026, 8, 19)]
        let result = Quota.calculate(.init(
            month: Month(year: 2026, month: 8),
            leave: leave.map { Quota.DayFraction($0) },
            today: Day(2026, 8, 4)
        ))
        let lines = MissionGrid.derivation(result, leave: leave)

        #expect(lines.map(\.label) == ["WORKING DAYS", "LEAVE 17–19", "8 × 17 ÷ 20", "TARGET"])
        #expect(lines.map(\.value) == ["20", "−03", "6.8", "07"])
    }

    @Test("With no leave the leave line is omitted rather than showing zero")
    func noLeave() {
        let result = Quota.calculate(.init(
            month: Month(year: 2026, month: 9), today: Day(2026, 9, 1)
        ))
        let lines = MissionGrid.derivation(result, leave: [])
        #expect(lines.map(\.label) == ["WORKING DAYS", "8 × 22 ÷ 22", "TARGET"])
        #expect(lines.last?.value == "08")
    }
}

@Suite("Trip layout")
@MainActor
struct TripLayoutTests {

    let container: ModelContainer

    init() throws {
        container = try Store.makeInMemoryContainer(seeded: true)
    }

    func fixture() throws -> (week: Trip, child: Trip, bookings: [Booking]) {
        let context = container.mainContext
        let trips = try context.fetch(FetchDescriptor<Trip>())
        let week = try #require(
            trips.first { $0.startsOn == Day(2026, 9, 7) && $0.parentTripID == nil }
        )
        let child = try #require(trips.first { $0.parentTripID == week.id })
        return (week, child, try context.fetch(FetchDescriptor<Booking>()))
    }

    @Test("The child block sits after the parent's own Monday, not before it")
    func orderingIsByInstant() throws {
        let (week, child, bookings) = try fixture()
        let blocks = TripLayout.blocks(for: week, child: child, bookings: bookings)

        // The Brussels leg opens at 17:04 on a Monday whose 06:40 train and
        // 10:00 desk belong to the parent. Comparing days rather than instants
        // put the whole child block above them.
        guard case .day(let firstDay, let firstBookings) = blocks.first else {
            Issue.record("the parent's own Monday must come first")
            return
        }
        #expect(firstDay == Day(2026, 9, 7))
        #expect(firstBookings.count == 2)

        guard case .child = blocks[1] else {
            Issue.record("the child block must follow the parent's Monday")
            return
        }
    }

    @Test("After the child closes, the parent's days continue at full width")
    func parentResumes() throws {
        let (week, child, bookings) = try fixture()
        let blocks = TripLayout.blocks(for: week, child: child, bookings: bookings)

        // This is what makes the Thursday London hotel and the Friday desk read
        // as belonging to the outer trip.
        let after = blocks.drop { block in
            if case .child = block { return false } else { return true }
        }.dropFirst()

        let days = after.compactMap { block -> Day? in
            if case .day(let day, _) = block { return day } else { return nil }
        }
        #expect(days == [Day(2026, 9, 10), Day(2026, 9, 11)])

        // Thursday in the parent is the Ropewalk, not the Eurostar.
        guard case .day(_, let thursday) = after.first else {
            Issue.record("expected a parent Thursday")
            return
        }
        #expect(thursday.count == 1)
        #expect(thursday[0].detail?.stayDetail?.hotelName == "The Ropewalk")
    }

    @Test("Empty days inside the child's span still get a row")
    func emptyDaysAreShown() throws {
        let (week, child, bookings) = try fixture()
        let blocks = TripLayout.blocks(for: week, child: child, bookings: bookings)

        guard case .child(_, let childDays) = blocks[1] else {
            Issue.record("expected the child block")
            return
        }
        #expect(childDays.map(\.day) == [
            Day(2026, 9, 7), Day(2026, 9, 8), Day(2026, 9, 9), Day(2026, 9, 10),
        ])
        #expect(childDays[1].bookings.isEmpty, "Tuesday reads ON SITE ▪ NO BOOKINGS")
        #expect(childDays[2].bookings.isEmpty)
        #expect(childDays[0].bookings.count == 2, "Eurostar out and Hotel Sablon")
    }

    @Test("A trip with no child lays out as plain day rows")
    func noChild() throws {
        let context = container.mainContext
        let trips = try context.fetch(FetchDescriptor<Trip>())
        let august = try #require(trips.first { $0.startsOn == Day(2026, 8, 5) })
        let bookings = try context.fetch(FetchDescriptor<Booking>())

        let blocks = TripLayout.blocks(for: august, child: nil, bookings: bookings)
        #expect(blocks.count == 2)
        #expect(blocks.allSatisfy { if case .day = $0 { true } else { false } })
    }
}
