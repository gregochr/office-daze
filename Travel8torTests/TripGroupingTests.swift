import Foundation
import Testing
@testable import Travel8tor

/// Sequential UUIDs so a failure names a trip you can find, rather than a
/// random hex blob that changes every run.
func sequentialIDs() -> () -> UUID {
    var n = 0
    return {
        n += 1
        return UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!
    }
}

func id(_ n: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!
}

@Suite("Trip grouping — the September week")
struct SeptemberGroupingTests {

    // The eight bookings of the design's September trip, as the rule sees them.
    static let mon = Day(2026, 9, 7)
    static let thu = Day(2026, 9, 10)
    static let fri = Day(2026, 9, 11)

    static let bookings: [(id: UUID, shape: BookingShape)] = [
        (id(101), BookingShape(kind: .rail,
            geography: .journey(from: "Durham", to: "London"), anchorDay: mon)),
        (id(102), BookingShape(kind: .desk,
            geography: .single(city: "London"), anchorDay: mon)),
        (id(103), BookingShape(kind: .rail,
            geography: .journey(from: "London", to: "Brussels"), anchorDay: mon)),
        (id(104), BookingShape(kind: .stay,
            geography: .single(city: "Brussels"), anchorDay: mon)),
        (id(105), BookingShape(kind: .rail,
            geography: .journey(from: "Brussels", to: "London"), anchorDay: thu)),
        (id(106), BookingShape(kind: .stay,
            geography: .single(city: "London"), anchorDay: thu)),
        (id(107), BookingShape(kind: .desk,
            geography: .single(city: "London"), anchorDay: fri)),
        (id(108), BookingShape(kind: .rail,
            geography: .journey(from: "London", to: "Durham"), anchorDay: fri)),
    ]

    static func grouped() -> TripGrouper.Result {
        var next = 0
        return TripGrouper.group(bookings: bookings, homeCity: "Durham") {
            next += 1
            return id(next) // trips get 1, 2, …; bookings are 101+
        }
    }

    @Test("Two trips: the London week and the Brussels leg inside it")
    func tripShape() {
        let result = Self.grouped()

        #expect(result.trips.count == 2)

        let london = result.trips[0]
        #expect(london.primaryCity == "London")
        #expect(london.parentID == nil)
        #expect(london.startsOn == Day(2026, 9, 7))
        #expect(london.endsOn == Day(2026, 9, 11))

        let brussels = result.trips[1]
        #expect(brussels.primaryCity == "Brussels")
        #expect(brussels.parentID == london.id)
        #expect(brussels.startsOn == Day(2026, 9, 7))
        #expect(brussels.endsOn == Day(2026, 9, 10))

        // The design's headers: LONDON WEEK 07–11.09, SUB-ROUTE BRUSSELS 07–10.09.
        #expect(TripGrouper.label(city: london.primaryCity, isChild: false) == "London week")
        #expect(TripGrouper.label(city: brussels.primaryCity, isChild: true) == "Brussels leg")
    }

    @Test("Every booking lands where the design puts it")
    func assignments() {
        let result = Self.grouped()
        let london = result.trips[0].id
        let brussels = result.trips[1].id

        #expect(result.tripID(of: id(101)) == london,   "Monday LNER opens the week")
        #expect(result.tripID(of: id(102)) == london,   "Monday desk joins it")
        #expect(result.tripID(of: id(103)) == brussels, "Eurostar out opens the child")
        #expect(result.tripID(of: id(104)) == brussels, "Hotel Sablon joins the child")
        #expect(result.tripID(of: id(105)) == brussels, "Eurostar back joins and closes it")
        #expect(result.tripID(of: id(107)) == london,   "Friday desk is back in the parent")
        #expect(result.tripID(of: id(108)) == london,   "Friday LNER closes the week")
    }

    @Test("The Thursday London hotel belongs to the parent, not the Brussels leg")
    func theHardOne() {
        let result = Self.grouped()
        let london = result.trips[0].id
        let brussels = result.trips[1].id

        // This is the case the document's rule 1 gets wrong. The Brussels leg
        // spans 07–10.09 and so covers Thursday the 10th by date. Taken
        // literally — "attach to the innermost covering trip and stop" — a
        // London hotel would be filed inside the Brussels leg.
        let brusselsLeg = result.trips[1]
        #expect(brusselsLeg.covers(Day(2026, 9, 10)), "the date range really does cover it")

        // The city walk is what saves it.
        #expect(result.tripID(of: id(106)) == london)
        #expect(result.tripID(of: id(106)) != brussels)
    }
}

@Suite("Trip grouping — the contract")
struct TripGroupingContractTests {

    let london = TripShape(
        id: id(1), primaryCity: "London",
        startsOn: Day(2026, 9, 7), endsOn: nil, parentID: nil
    )

    var brussels: TripShape {
        TripShape(
            id: id(2), primaryCity: "Brussels",
            startsOn: Day(2026, 9, 7), endsOn: Day(2026, 9, 10), parentID: id(1)
        )
    }

    @Test("An outbound leg from home with no covering trip opens one")
    func outboundOpensTrip() {
        let outcome = TripGrouping.classify(
            BookingShape(kind: .rail,
                geography: .journey(from: "Durham", to: "London"),
                anchorDay: Day(2026, 9, 7)),
            among: [], homeCity: "Durham"
        )
        #expect(outcome == .openRootTrip(city: "London", startsOn: Day(2026, 9, 7)))
    }

    @Test("A homeward leg with nothing open attaches to nothing")
    func homewardWithNoTrip() {
        let outcome = TripGrouping.classify(
            BookingShape(kind: .rail,
                geography: .journey(from: "London", to: "Durham"),
                anchorDay: Day(2026, 9, 11)),
            among: [], homeCity: "Durham"
        )
        #expect(outcome == .unattached)
    }

    @Test("A desk or stay with no covering trip does not open one")
    func singleCityNeverOpensARootTrip() {
        for geography in [BookingGeography.single(city: "London")] {
            let outcome = TripGrouping.classify(
                BookingShape(kind: .desk, geography: geography, anchorDay: Day(2026, 9, 7)),
                among: [], homeCity: "Durham"
            )
            #expect(outcome == .unattached)
        }
    }

    @Test("A leg to a new city opens a child; the leg back closes it")
    func farEndKeying() {
        // Finding 3: a rail leg cannot be keyed on origin or destination alone.
        // The outbound creates the child, the return joins it — and the same
        // rule has to produce both.
        let out = TripGrouping.classify(
            BookingShape(kind: .rail,
                geography: .journey(from: "London", to: "Brussels"),
                anchorDay: Day(2026, 9, 7)),
            among: [london], homeCity: "Durham"
        )
        #expect(out == .openChildTrip(parentID: id(1), city: "Brussels", startsOn: Day(2026, 9, 7)))

        let back = TripGrouping.classify(
            BookingShape(kind: .rail,
                geography: .journey(from: "Brussels", to: "London"),
                anchorDay: Day(2026, 9, 10)),
            among: [london, brussels], homeCity: "Durham"
        )
        #expect(back == .attachAndClose(tripID: id(2), on: Day(2026, 9, 10)))
    }

    @Test("A leg toward home closes the parent rather than opening a child")
    func homewardClosesParent() {
        let outcome = TripGrouping.classify(
            BookingShape(kind: .rail,
                geography: .journey(from: "London", to: "Durham"),
                anchorDay: Day(2026, 9, 11)),
            among: [london], homeCity: "Durham"
        )
        #expect(outcome == .attachAndClose(tripID: id(1), on: Day(2026, 9, 11)))
    }

    @Test("Nesting stops at one level")
    func oneLevelOnly() {
        // The document is explicit: "One level of nesting is enough; don't build
        // a tree." A third city inside a child attaches to the child.
        let outcome = TripGrouping.classify(
            BookingShape(kind: .stay,
                geography: .single(city: "Amsterdam"),
                anchorDay: Day(2026, 9, 9)),
            among: [london, brussels], homeCity: "Durham"
        )
        #expect(outcome == .attach(tripID: id(2)))

        let leg = TripGrouping.classify(
            BookingShape(kind: .rail,
                geography: .journey(from: "Brussels", to: "Amsterdam"),
                anchorDay: Day(2026, 9, 9)),
            among: [london, brussels], homeCity: "Durham"
        )
        #expect(leg == .attach(tripID: id(2)))
    }

    @Test("An unmatched city inside a root trip opens a child")
    func newCityOpensChild() {
        let outcome = TripGrouping.classify(
            BookingShape(kind: .stay,
                geography: .single(city: "Paris"),
                anchorDay: Day(2026, 9, 8)),
            among: [london], homeCity: "Durham"
        )
        #expect(outcome == .openChildTrip(parentID: id(1), city: "Paris", startsOn: Day(2026, 9, 8)))
    }

    @Test("An open trip covers everything after it starts; a closed one does not")
    func coverage() {
        #expect(london.covers(Day(2027, 1, 1)), "open trips have no end")
        #expect(!london.covers(Day(2026, 9, 6)))
        #expect(brussels.covers(Day(2026, 9, 10)))
        #expect(!brussels.covers(Day(2026, 9, 11)))
    }

    @Test("The chain runs innermost first")
    func chainOrder() {
        let chain = TripGrouping.ancestorChain(
            covering: Day(2026, 9, 9), in: [london, brussels]
        )
        #expect(chain.map(\.primaryCity) == ["Brussels", "London"])

        // After the Brussels leg closes, only the parent covers the Friday.
        let friday = TripGrouping.ancestorChain(
            covering: Day(2026, 9, 11), in: [london, brussels]
        )
        #expect(friday.map(\.primaryCity) == ["London"])
    }

    @Test("A local hop within the covering trip's own city just attaches")
    func localHop() {
        let outcome = TripGrouping.classify(
            BookingShape(kind: .rail,
                geography: .journey(from: "London", to: "London"),
                anchorDay: Day(2026, 9, 8)),
            among: [london], homeCity: "Durham"
        )
        #expect(outcome == .attach(tripID: id(1)))
    }
}
