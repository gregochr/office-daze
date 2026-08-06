import Foundation
import SwiftData
import Testing
import UserNotifications
@testable import Travel8tor

/// The rule the whole feature turns on. Four outcomes, tested without a device
/// walking through a door.
@Suite("The arrival rule")
struct ArrivalRuleTests {

    let london = UUID()
    let brussels = UUID()
    let today = Day(2026, 8, 5)

    func booking(_ office: UUID, _ day: Day, desk: String = "3C-114") -> ArrivalRule.Booking {
        .init(
            id: UUID(), officeID: office, day: day, deskID: desk,
            floor: "Level 3", zone: "C"
        )
    }

    @Test("A desk booked for today at this office is what the alert shows")
    func showsTheDesk() {
        let desk = booking(london, today)
        let decision = ArrivalRule.decide(.init(
            officeID: london, day: today, bookings: [desk]
        ))
        #expect(decision == .desk(desk))
    }

    /// The whole fire-once rule: one row per office per day, checked first and
    /// cheaply. Not a dwell timer and not an exit event — a ledger row survives
    /// the app being killed, which is the only thing that reliably happens
    /// between one crossing and the next.
    @Test("A second crossing on the same day does nothing at all")
    func firesOnce() {
        let decision = ArrivalRule.decide(.init(
            officeID: london, day: today,
            ledger: [.init(day: today, officeID: london)],
            bookings: [booking(london, today)]
        ))
        #expect(decision == .alreadyFired)
    }

    @Test("The ledger is per office and per day, not global")
    func ledgerIsScoped() {
        let fired = [ArrivalAlert.Row(day: today, officeID: london)]

        // A different office on the same day still fires.
        #expect(
            ArrivalRule.decide(.init(officeID: brussels, day: today, ledger: fired))
                == .nothingBooked
        )
        // The same office tomorrow still fires.
        #expect(
            ArrivalRule.decide(
                .init(officeID: london, day: today.adding(days: 1), ledger: fired)
            ) == .nothingBooked
        )
    }

    /// Turning up with nothing booked is the inverted prompt, not silence — the
    /// day still counts if the user says it does.
    @Test("Arriving with nothing booked still offers to record the day")
    func nothingBooked() {
        #expect(
            ArrivalRule.decide(.init(officeID: london, day: today)) == .nothingBooked
        )
        // A booking at a different office, or on a different day, is not this
        // arrival's booking.
        #expect(
            ArrivalRule.decide(.init(
                officeID: london, day: today,
                bookings: [booking(brussels, today), booking(london, today.adding(days: 1))]
            )) == .nothingBooked
        )
    }

    @Test("An office with its alert switched off never fires")
    func disabled() {
        #expect(
            ArrivalRule.decide(.init(
                officeID: london, day: today,
                bookings: [booking(london, today)], alertEnabled: false
            )) == .disabled
        )
    }
}

@Suite("The arrival alert's copy")
struct ArrivalNotificationTests {

    func booking(floor: String? = "Level 3", zone: String? = "C") -> ArrivalRule.Booking {
        .init(
            id: UUID(), officeID: UUID(), day: Day(2026, 8, 5),
            deskID: "3C-114", floor: floor, zone: zone
        )
    }

    /// The desk id is the title because the title is the largest text iOS will
    /// render on a lock screen, and reading it at arm's length without
    /// unlocking is the entire point.
    @Test("The desk number is the headline")
    func deskIsTheTitle() {
        let content = ArrivalNotifications.content(
            officeName: "Ropemaker Place", desk: booking(),
            attended: 4, target: 7, monthName: "August"
        )
        #expect(content.title == "3C-114")
        #expect(content.subtitle == "You're at Ropemaker Place")
        #expect(content.body.contains("Level 3, Zone C"))
        #expect(content.body.contains("Day 4 of 7 for August"))
        #expect(content.category == .booked)
    }

    /// A floor is free text: people type "Level 3", the Coleman system prints
    /// "03". A bare "03" on a lock screen says nothing, so it gets the word —
    /// but a value that already carries one must not become "Level Level 3".
    @Test("The floor gets the word Level exactly once")
    func floorIsNotDoublePrefixed() {
        #expect(ArrivalNotifications.level("Level 3") == "Level 3")
        #expect(ArrivalNotifications.level("03") == "Level 03")
        #expect(ArrivalNotifications.level("3") == "Level 3")
        #expect(ArrivalNotifications.level("Mezzanine") == "Mezzanine")

        let content = ArrivalNotifications.content(
            officeName: "Ropemaker Place", desk: booking(floor: "Level 3"),
            attended: 4, target: 7, monthName: "August"
        )
        #expect(content.body.contains("Level 3, Zone C"))
        #expect(!content.body.contains("Level Level"))
    }

    /// Only what was actually read. A floor the capture could not make out is
    /// absent from the line rather than an empty "Level ,".
    @Test("An unread floor or zone is left out, not left blank")
    func omitsUnreadFields() {
        let neither = ArrivalNotifications.content(
            officeName: "Brussels", desk: booking(floor: nil, zone: nil),
            attended: 1, target: 7, monthName: "August"
        )
        #expect(!neither.body.contains("Level"))
        #expect(!neither.body.contains("Zone"))
        #expect(neither.body.contains("Day 1 of 7"))

        let floorOnly = ArrivalNotifications.content(
            officeName: "Brussels", desk: booking(zone: nil),
            attended: 1, target: 7, monthName: "August"
        )
        #expect(floorOnly.body.contains("Level 3"))
        #expect(!floorOnly.body.contains("Level Level"))
        #expect(!floorOnly.body.contains("Zone"))
    }

    @Test("The unbooked prompt says so, and uses its own category")
    func unbooked() {
        let content = ArrivalNotifications.content(
            officeName: "Ropemaker Place", desk: nil,
            attended: 4, target: 7, monthName: "August"
        )
        #expect(content.title == "You're on site")
        #expect(content.body.contains("No desk booked today."))
        #expect(content.category == .unbooked)
    }

    /// The day being arrived at is not attended yet — it becomes day 5 only
    /// once the user confirms.
    @Test("The count is what is already recorded, not what today might become")
    func dayCount() {
        #expect(
            ArrivalNotifications.dayCount(attended: 4, target: 7, monthName: "August")
                == "Day 4 of 7 for August"
        )
        #expect(
            ArrivalNotifications.dayCount(attended: 4.5, target: 7, monthName: "August")
                == "Day 4.5 of 7 for August"
        )
    }

    @Test("Both categories offer the confirm button")
    func categories() {
        let categories = ArrivalNotifications.categories
        #expect(categories.count == 2)
        let confirmable = categories.allSatisfy { category in
            category.actions.contains { $0.identifier == ArrivalNotifications.Action.confirm.rawValue }
        }
        #expect(confirmable, "attendance must be recordable from the lock screen")
    }

    @Test("The request carries what the confirm button needs to write the record")
    func requestUserInfo() throws {
        let desk = booking()
        let officeID = UUID()
        let request = ArrivalNotifications.request(
            ArrivalNotifications.content(
                officeName: "Ropemaker Place", desk: desk,
                attended: 4, target: 7, monthName: "August"
            ),
            officeID: officeID, day: Day(2026, 8, 5), bookingID: desk.id
        )
        let info = request.content.userInfo
        #expect(info[ArrivalNotifications.UserInfo.officeID] as? String == officeID.uuidString)
        #expect(info[ArrivalNotifications.UserInfo.day] as? String == "2026-08-05")
        #expect(info[ArrivalNotifications.UserInfo.bookingID] as? String == desk.id.uuidString)
        // One notification per office per day, so a duplicate replaces rather
        // than stacking.
        #expect(request.identifier == "arrival.\(officeID.uuidString).2026-08-05")
    }
}

@Suite("The arrival ledger")
@MainActor
struct ArrivalLedgerTests {

    let container: ModelContainer
    let ledger: ArrivalLedger

    init() throws {
        container = try Store.makeInMemoryContainer(seeded: true)
        ledger = ArrivalLedger(context: container.mainContext)
    }

    /// Counts posts instead of posting. A real notification from a test run
    /// leaves one on the machine, and asking for permission in CI is a hang.
    final class Posted: @unchecked Sendable {
        var requests: [UNNotificationRequest] = []
    }

    func recording() -> Posted {
        let posted = Posted()
        ledger.post = { posted.requests.append($0) }
        return posted
    }

    @Test("Arriving on a booked day posts the desk and writes the ledger row")
    func booked() throws {
        let posted = recording()
        let decision = ledger.handleEntry(
            officeID: SeedData.ropemakerID, day: Day(2026, 8, 5)
        )

        guard case .desk(let booking) = decision else {
            Issue.record("expected a desk, got \(decision)")
            return
        }
        #expect(booking.deskID == "3C-114")
        #expect(posted.requests.count == 1)
        #expect(posted.requests.first?.content.title == "3C-114")

        let rows = try container.mainContext.fetch(FetchDescriptor<ArrivalAlert>())
        #expect(rows.count == 1)
        #expect(rows.first?.officeID == SeedData.ropemakerID)
    }

    @Test("The second crossing of the day posts nothing and writes nothing")
    func firesOnce() throws {
        let posted = recording()
        let day = Day(2026, 8, 5)
        ledger.handleEntry(officeID: SeedData.ropemakerID, day: day)
        let second = ledger.handleEntry(officeID: SeedData.ropemakerID, day: day)

        #expect(second == .alreadyFired)
        #expect(posted.requests.count == 1, "not a second notification")
        #expect(try container.mainContext.fetchCount(FetchDescriptor<ArrivalAlert>()) == 1)
    }

    /// The ledger row is written for both outcomes, so turning up with nothing
    /// booked also prompts only once.
    @Test("Arriving with nothing booked still writes the row")
    func unbookedStillFiresOnce() throws {
        let posted = recording()
        let day = Day(2026, 8, 20) // a working day with no seeded booking

        #expect(ledger.handleEntry(officeID: SeedData.ropemakerID, day: day) == .nothingBooked)
        #expect(ledger.handleEntry(officeID: SeedData.ropemakerID, day: day) == .alreadyFired)
        #expect(posted.requests.count == 1)
        #expect(posted.requests.first?.content.body.contains("No desk booked today.") == true)
    }

    /// The geofence offers; the user confirms. Nothing else writes attendance.
    @Test("An arrival records no attendance until the button is tapped")
    func neverRecordsSilently() throws {
        _ = recording()
        let day = Day(2026, 8, 20)
        let before = try container.mainContext.fetchCount(FetchDescriptor<AttendanceDay>())

        ledger.handleEntry(officeID: SeedData.ropemakerID, day: day)
        #expect(
            try container.mainContext.fetchCount(FetchDescriptor<AttendanceDay>()) == before,
            "the alert offers; it does not record"
        )

        ledger.confirmAttendance(officeID: SeedData.ropemakerID, day: day, bookingID: nil)
        #expect(
            try container.mainContext.fetchCount(FetchDescriptor<AttendanceDay>()) == before + 1
        )

        // And confirming twice does not double-count the day.
        ledger.confirmAttendance(officeID: SeedData.ropemakerID, day: day, bookingID: nil)
        #expect(
            try container.mainContext.fetchCount(FetchDescriptor<AttendanceDay>()) == before + 1
        )
    }

    @Test("An office with its alert off is not woken for")
    func disabledOffice() throws {
        let posted = recording()
        let office = try #require(
            try container.mainContext.fetch(FetchDescriptor<Office>())
                .first { $0.id == SeedData.ropemakerID }
        )
        office.alertEnabled = false
        try container.mainContext.save()

        #expect(ledger.handleEntry(officeID: office.id, day: Day(2026, 8, 5)) == .disabled)
        #expect(posted.requests.isEmpty)
        #expect(try container.mainContext.fetchCount(FetchDescriptor<ArrivalAlert>()) == 0)
    }
}
