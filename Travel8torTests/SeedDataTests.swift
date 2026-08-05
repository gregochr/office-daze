import Foundation
import SwiftData
import Testing
@testable import Travel8tor

@Suite("Seed data")
struct SeedDataTests {

    // MARK: The grouping the seed produces, without a store

    @Test("The seed produces three trips: August, the London week, Brussels")
    func tripsFromSeed() {
        let seeded = SeedData.materialise(SeedData.allDrafts(), newID: sequentialIDs())

        #expect(seeded.trips.count == 3)

        let august = seeded.trips[0]
        #expect(august.primaryCity == "London")
        #expect(august.startsOn == Day(2026, 8, 5))
        #expect(august.endsOn == Day(2026, 8, 6), "must close, or it covers September")
        #expect(august.parentID == nil)

        let week = seeded.trips[1]
        #expect(week.primaryCity == "London")
        #expect(week.startsOn == Day(2026, 9, 7))
        #expect(week.endsOn == Day(2026, 9, 11))
        #expect(week.parentID == nil)

        let leg = seeded.trips[2]
        #expect(leg.primaryCity == "Brussels")
        #expect(leg.startsOn == Day(2026, 9, 7))
        #expect(leg.endsOn == Day(2026, 9, 10))
        #expect(leg.parentID == week.id, "Brussels nests inside the London week")
    }

    @Test("The Thursday London hotel is in the parent, Hotel Sablon in the child")
    func nestingOfStays() {
        let seeded = SeedData.materialise(SeedData.allDrafts(), newID: sequentialIDs())
        let week = seeded.trips[1].id
        let leg = seeded.trips[2].id

        let stays = seeded.bookings.filter { $0.draft.detail.kind == .stay }
        #expect(stays.count == 2)

        let sablon = stays.first { $0.draft.detail.stayDetail?.hotelName == "Hotel Sablon" }
        let ropewalk = stays.first { $0.draft.detail.stayDetail?.hotelName == "The Ropewalk" }

        #expect(sablon?.tripID == leg)
        #expect(ropewalk?.tripID == week, "the Thursday hotel belongs to the outer trip")
    }

    @Test("Every seeded booking finds a trip")
    func nothingOrphaned() {
        let seeded = SeedData.materialise(SeedData.allDrafts(), newID: sequentialIDs())
        for (draft, tripID) in seeded.bookings {
            #expect(tripID != nil, "\(draft.detail.kind) on \(draft.startsAt) is orphaned")
        }
    }

    @Test("The Ropewalk names its unreadable fields and stores no value for them")
    func neverGuess() {
        let ropewalk = SeedData.septemberDrafts().first {
            $0.detail.stayDetail?.hotelName == "The Ropewalk"
        }
        let stay = try! #require(ropewalk?.detail.stayDetail)

        // The design's stay screen: CHECK IN ??:??, two fields flagged amber.
        #expect(ropewalk?.unsureFields.sorted() == ["bookingRef", "checkIn"])
        #expect(stay.checkIn == nil, "an unread field stores nothing, not a guess")
        #expect(stay.bookingRef == nil)
        #expect(ropewalk?.provenance == .screengrab)

        // And the invariant: nothing named in unsureFields has a value.
        #expect(stay.checkOut != nil, "check-out was readable and is kept")
    }

    @Test("Foreign legs carry a zone at each end")
    func timeZones() {
        let eurostarOut = SeedData.septemberDrafts().first {
            $0.detail.railDetail?.destCity == "Brussels"
        }
        #expect(eurostarOut?.startZoneID == "Europe/London")
        #expect(eurostarOut?.endZoneID == "Europe/Brussels")

        // 17:04 London to 20:05 Brussels is 2h01, not 3h01 — the design's
        // ticket screen says 2h01 and 19:05 UK.
        let departure = try! #require(eurostarOut?.startsAt)
        let arrival = try! #require(eurostarOut?.endsAt)
        #expect(arrival.timeIntervalSince(departure) == 2 * 3600 + 60)

        let londonArrival = Day(of: arrival, in: TimeZone(identifier: "Europe/London")!)
        #expect(londonArrival == Day(2026, 9, 7))
    }

    // MARK: Through SwiftData

    @Test("A seeded store round-trips the trips and their nesting")
    @MainActor
    func storeRoundTrip() throws {
        let container = try Store.makeInMemoryContainer(seeded: true)
        let context = container.mainContext

        let trips = try context.fetch(
            FetchDescriptor<Trip>(sortBy: [SortDescriptor(\.startsOnDate)])
        )
        #expect(trips.count == 3)

        let leg = try #require(trips.first { $0.primaryCity == "Brussels" })
        #expect(leg.label == "Brussels leg")
        #expect(leg.startsOn == Day(2026, 9, 7))
        #expect(leg.endsOn == Day(2026, 9, 10))

        let parent = try #require(trips.first { $0.id == leg.parentTripID })
        #expect(parent.label == "London week")
        #expect(parent.startsOn == Day(2026, 9, 7))
        #expect(parent.endsOn == Day(2026, 9, 11))
    }

    @Test("Booking detail survives the encode/decode round trip")
    @MainActor
    func detailRoundTrip() throws {
        let container = try Store.makeInMemoryContainer(seeded: true)
        let context = container.mainContext

        let bookings = try context.fetch(FetchDescriptor<Booking>())
        #expect(bookings.count == 12)

        let eurostar = try #require(bookings.first {
            $0.detail?.railDetail?.operatorName == "Eurostar"
                && $0.detail?.railDetail?.destCity == "Brussels"
        })
        let rail = try #require(eurostar.detail?.railDetail)
        #expect(rail.coach == "09")
        #expect(rail.seat == "51")
        #expect(rail.bookingRef == "XKR48821")
        #expect(rail.platform == nil)
        #expect(eurostar.kind == .rail)
        #expect(eurostar.anchorDay == Day(2026, 9, 7))

        let ropewalk = try #require(bookings.first {
            $0.detail?.stayDetail?.hotelName == "The Ropewalk"
        })
        #expect(ropewalk.hasUnreadableFields)
        #expect(ropewalk.detail?.stayDetail?.checkIn == nil)
    }

    @Test("Seeding is skipped when the store already has bookings")
    @MainActor
    func seedIsIdempotent() throws {
        let container = try Store.makeInMemoryContainer(seeded: true)
        let context = container.mainContext

        try Store.seedIfNeeded(context)
        try Store.seedIfNeeded(context)

        #expect(try context.fetchCount(FetchDescriptor<Booking>()) == 12)
        #expect(try context.fetchCount(FetchDescriptor<Trip>()) == 3)
    }

    @Test("The seeded August matches the gauge in the design")
    @MainActor
    func seededAugustDrivesTheGauge() throws {
        let container = try Store.makeInMemoryContainer(seeded: true)
        let context = container.mainContext

        let august = Month(year: 2026, month: 8)
        let today = Day(2026, 8, 4)

        let leave = try context.fetch(FetchDescriptor<LeaveDay>())
            .filter { $0.kind != .bankHoliday && august.contains($0.day) }
            .map { Quota.DayFraction($0.day, $0.fraction) }

        let attendance = try context.fetch(FetchDescriptor<AttendanceDay>())
            .filter { august.contains($0.day) }
            .map { Quota.DayFraction($0.day, $0.fraction) }

        let deskDays = try context.fetch(FetchDescriptor<Booking>())
            .filter { $0.kind == .desk && $0.detail?.deskDetail?.countsToQuota == true }
            .map(\.anchorDay)
            .filter { august.contains($0) }

        let result = Quota.calculate(.init(
            month: august,
            leave: leave,
            attendance: attendance,
            deskBookingDays: Set(deskDays),
            today: today
        ))

        #expect(result.target == 7)
        #expect(result.attended == 2)
        #expect(result.forecast == 2)
        #expect(result.shortfall == 3)
        #expect(result.daysToRun == 18)
    }

    @Test("Places are seeded with the geofence radius the design specifies")
    @MainActor
    func places() throws {
        let container = try Store.makeInMemoryContainer(seeded: true)
        let ropemaker = try #require(
            try container.mainContext.fetch(FetchDescriptor<Place>()).first
        )
        #expect(ropemaker.name == "Ropemaker Place")
        #expect(ropemaker.postcode == "EC2Y 9LY")
        #expect(ropemaker.radiusMetres == 50)
        #expect(ropemaker.id == SeedData.ropemakerPlaceID)
    }
}

@Suite("Erase")
@MainActor
struct WipeTests {

    @Test("The wipe leaves nothing behind, in any entity")
    func wipesEverything() throws {
        let container = try Store.makeInMemoryContainer(seeded: true)
        let context = container.mainContext

        #expect(try context.fetchCount(FetchDescriptor<Booking>()) > 0)
        #expect(try context.fetchCount(FetchDescriptor<Trip>()) > 0)
        #expect(try context.fetchCount(FetchDescriptor<Place>()) > 0)

        try Store.wipe(context)

        #expect(try context.fetchCount(FetchDescriptor<Booking>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<Trip>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<Place>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<LeaveDay>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<AttendanceDay>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<ArrivalAlert>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<Capture>()) == 0)
    }

    @Test("An erased store does not re-seed itself on the next launch")
    func doesNotReseed() throws {
        // The whole reason the seed is gated on a flag rather than on "is the
        // store empty": an emptied store is empty on purpose.
        let container = try Store.makeInMemoryContainer(seeded: true)
        let context = container.mainContext
        let wasSeeded = Store.hasSeeded
        defer { Store.hasSeeded = wasSeeded }

        try Store.wipe(context)
        #expect(Store.hasSeeded, "the wipe records that seeding is spent")

        try Store.seedIfNeeded(context)
        #expect(try context.fetchCount(FetchDescriptor<Booking>()) == 0, "still empty")
    }
}
