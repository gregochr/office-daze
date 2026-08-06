import Foundation
import SwiftData
import Testing
@testable import Travel8tor

@Suite("Seed data and the store")
@MainActor
struct StoreTests {

    let container: ModelContainer

    init() throws {
        container = try Store.makeInMemoryContainer(seeded: true)
    }

    @Test("The six entities open, and the sample month lands")
    func seeds() throws {
        let context = container.mainContext
        #expect(try context.fetchCount(FetchDescriptor<Office>()) == 2)
        #expect(try context.fetchCount(FetchDescriptor<DeskBooking>()) == 4)
        #expect(try context.fetchCount(FetchDescriptor<AttendanceDay>()) == 4)
        #expect(try context.fetchCount(FetchDescriptor<LeaveDay>()) == 3)
    }

    @Test("The offices are the design's two, in different colours")
    func offices() throws {
        let offices = try container.mainContext.fetch(FetchDescriptor<Office>())
            .sorted { $0.name < $1.name }
        #expect(offices.map(\.name) == ["Brussels", "Ropemaker Place"])
        #expect(Set(offices.map(\.colourHex)).count == 2, "never the same colour twice")
        // Hoisted out of #expect: `allSatisfy` is `rethrows`, and the macro
        // cannot tell a non-throwing closure from a throwing one inside it.
        let fiftyMetres = offices.allSatisfy { $0.radiusMetres == 50 }
        let located = offices.allSatisfy(\.isLocated)
        #expect(fiftyMetres)
        #expect(located, "both are geocoded, so both can be monitored")
    }

    @Test("The bookings are the four on the home screen")
    func bookings() throws {
        let bookings = try container.mainContext.fetch(FetchDescriptor<DeskBooking>())
            .sorted { $0.day < $1.day }
        #expect(bookings.map(\.deskID) == ["3C-114", "3C-116", "2-041", "3C-121"])
        #expect(bookings.map(\.day) == [
            Day(2026, 8, 5), Day(2026, 8, 6), Day(2026, 8, 11), Day(2026, 8, 12),
        ])
        #expect(bookings[0].hoursText == "09:00 – 17:00")
    }

    /// The never-guess rule, at rest in the store: the Brussels booking's zone
    /// was not readable, so it is absent *and* named.
    @Test("An unread field is absent and flagged, not blank and silent")
    func needsChecking() throws {
        let brussels = try #require(
            try container.mainContext.fetch(FetchDescriptor<DeskBooking>())
                .first { $0.deskID == "2-041" }
        )
        #expect(brussels.zone == nil)
        #expect(brussels.unsureFields == ["zone"])
        #expect(brussels.needsChecking)
    }

    /// You can turn up without booking. The nullable bookingID is what makes
    /// that recordable, and two of the seeded days exercise it.
    @Test("Attendance stands on its own, with or without a booking")
    func attendanceWithoutBooking() throws {
        let attendance = try container.mainContext.fetch(FetchDescriptor<AttendanceDay>())
        #expect(attendance.filter { $0.bookingID == nil }.count == 2)
        #expect(attendance.filter { $0.bookingID != nil }.count == 2)
    }

    @Test("The seeded month is the worked example")
    func quotaFromTheStore() throws {
        let snapshot = try QuotaService.snapshot(
            for: SeedData.month, today: Day(2026, 8, 4), in: container.mainContext
        )
        #expect(snapshot.result.workingDays == 20)
        #expect(snapshot.result.leaveTaken == 3)
        #expect(snapshot.result.target == 7)
        #expect(snapshot.result.attended == 4, "London 3, Brussels 1")
    }

    @Test("The office cards split the month by office")
    func perOfficeCounts() throws {
        let snapshot = try QuotaService.snapshot(
            for: SeedData.month, today: Day(2026, 8, 4), in: container.mainContext
        )
        #expect(snapshot.attendedByOffice[SeedData.ropemakerID] == 3)
        #expect(snapshot.attendedByOffice[SeedData.brusselsID] == 1)
    }

    @Test("Wiping leaves nothing behind")
    func wipe() throws {
        let context = container.mainContext
        try Store.wipe(context)
        let counts = [
            try context.fetchCount(FetchDescriptor<Office>()),
            try context.fetchCount(FetchDescriptor<DeskBooking>()),
            try context.fetchCount(FetchDescriptor<AttendanceDay>()),
            try context.fetchCount(FetchDescriptor<LeaveDay>()),
        ]
        let allEmpty = counts.allSatisfy { $0 == 0 }
        #expect(allEmpty)
    }
}
