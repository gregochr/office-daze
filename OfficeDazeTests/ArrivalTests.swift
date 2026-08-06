import Foundation
import SwiftData
import Testing
import UserNotifications
@testable import OfficeDaze

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

    /// The whole point of the repeat: having alerted once is not a reason to
    /// stay quiet. The desk number is what the user came for, and one
    /// notification missed on the walk in is gone.
    @Test("A later arrival on an unacknowledged day alerts again")
    func repeatsUntilAcknowledged() {
        let arrived = Date(timeIntervalSince1970: 1_785_000_000)
        let desk = booking(london, today)
        let decision = ArrivalRule.decide(.init(
            officeID: london, day: today,
            lastAlert: arrived,
            now: arrived.addingTimeInterval(ArrivalRule.settleWindow + 1),
            bookings: [desk]
        ))
        #expect(decision == .desk(desk))
    }

    /// The acknowledgement, and the only thing that stops the day.
    @Test("A day already recorded at this office alerts no further")
    func acknowledged() {
        let decision = ArrivalRule.decide(.init(
            officeID: london, day: today,
            attendance: [.init(day: today, officeID: london)],
            bookings: [booking(london, today)]
        ))
        #expect(decision == .acknowledged)
    }

    @Test("The acknowledgement is per office and per day, not global")
    func acknowledgementIsScoped() {
        let recorded = [ArrivalRule.Attendance(day: today, officeID: london)]

        // A different office on the same day still alerts.
        #expect(
            ArrivalRule.decide(.init(officeID: brussels, day: today, attendance: recorded))
                == .nothingBooked
        )
        // The same office tomorrow still alerts.
        #expect(
            ArrivalRule.decide(
                .init(officeID: london, day: today.adding(days: 1), attendance: recorded)
            ) == .nothingBooked
        )
    }

    /// Drift across the perimeter is not an arrival. Without this a boundary
    /// flutter delivers a burst of identical alerts, which is how a
    /// notification gets switched off for good.
    @Test("A crossing moments after the last alert is drift, not a return")
    func settles() {
        let arrived = Date(timeIntervalSince1970: 1_785_000_000)
        #expect(
            ArrivalRule.decide(.init(
                officeID: london, day: today,
                lastAlert: arrived,
                now: arrived.addingTimeInterval(ArrivalRule.settleWindow - 1),
                bookings: [booking(london, today)]
            )) == .settling
        )
    }

    /// Order matters: an acknowledged day is silent whether or not the window
    /// has passed, and the window never resurrects an acknowledged day.
    @Test("Acknowledgement is checked before the settle window")
    func acknowledgementOutranksTheWindow() {
        let arrived = Date(timeIntervalSince1970: 1_785_000_000)
        #expect(
            ArrivalRule.decide(.init(
                officeID: london, day: today,
                attendance: [.init(day: today, officeID: london)],
                lastAlert: arrived,
                now: arrived.addingTimeInterval(ArrivalRule.settleWindow + 1)
            )) == .acknowledged
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

    /// Three screens described the old rule, and changing it left all three
    /// promising once a day. Copy cannot be tested for being *right*, but it
    /// can be held to naming the thing that actually ends the alert — and the
    /// old promise can be kept from coming back.
    @Test("No screen still promises the alert fires once a day")
    func copyMatchesTheRule() {
        for line in ArrivalCopy.all {
            #expect(!line.localizedCaseInsensitiveContains("once a day"))
            #expect(!line.localizedCaseInsensitiveContains("once per day"))
            #expect(
                line.contains("I'm here"),
                "the acknowledgement is the only thing that stops it, so each line says so"
            )
        }
    }


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
            officeName: "Coleman", desk: booking(),
            attended: 4, target: 7, monthName: "August"
        )
        #expect(content.title == "3C-114")
        #expect(content.subtitle == "You're at Coleman")
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
            officeName: "Coleman", desk: booking(floor: "Level 3"),
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
            officeName: "Coleman", desk: nil,
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
                officeName: "Coleman", desk: desk,
                attended: 4, target: 7, monthName: "August"
            ),
            officeID: officeID, day: Day(2026, 8, 5), bookingID: desk.id,
            at: Date(timeIntervalSince1970: 1_785_000_000)
        )
        let info = request.content.userInfo
        #expect(info[ArrivalNotifications.UserInfo.officeID] as? String == officeID.uuidString)
        #expect(info[ArrivalNotifications.UserInfo.day] as? String == "2026-08-05")
        #expect(info[ArrivalNotifications.UserInfo.bookingID] as? String == desk.id.uuidString)
    }

    /// iOS reads a repeated identifier as an edit of the notification already
    /// on screen, not as a new one — so two arrivals sharing an identifier
    /// would rewrite the first alert silently instead of alerting again.
    @Test("Each delivery has its own identifier")
    func identifierIsPerDelivery() {
        let officeID = UUID()
        let day = Day(2026, 8, 5)
        let first = Date(timeIntervalSince1970: 1_785_000_000)
        #expect(
            ArrivalNotifications.identifier(officeID: officeID, day: day, at: first)
                != ArrivalNotifications.identifier(
                    officeID: officeID, day: day, at: first.addingTimeInterval(3600)
                )
        )
        // Reconstructible: the ledger stores the time, and the identifier of
        // the notification to withdraw is derived from it rather than kept.
        #expect(
            ArrivalNotifications.identifier(officeID: officeID, day: day, at: first)
                == ArrivalNotifications.identifier(officeID: officeID, day: day, at: first)
        )
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

    func withdrawals() -> Withdrawn {
        let withdrawn = Withdrawn()
        ledger.withdraw = { withdrawn.identifiers.append(contentsOf: $0) }
        return withdrawn
    }

    final class Withdrawn: @unchecked Sendable {
        var identifiers: [String] = []
    }

    /// The 12th is booked at Coleman and not attended. The 5th is both, and is
    /// where the acknowledged path is exercised instead.
    let unattended = Day(2026, 8, 12)

    @Test("Arriving on a booked day posts the desk and writes the ledger row")
    func booked() throws {
        let posted = recording()
        let decision = ledger.handleEntry(officeID: SeedData.colemanID, day: unattended)

        guard case .desk(let booking) = decision else {
            Issue.record("expected a desk, got \(decision)")
            return
        }
        #expect(booking.deskID == "3C-121")
        #expect(posted.requests.count == 1)
        #expect(posted.requests.first?.content.title == "3C-121")

        let rows = try container.mainContext.fetch(FetchDescriptor<ArrivalAlert>())
        #expect(rows.count == 1)
        #expect(rows.first?.officeID == SeedData.colemanID)
    }

    /// A day already recorded has nothing left to ask for, so the perimeter is
    /// crossed and nothing happens. The 5th is seeded as attended at Coleman.
    @Test("An acknowledged day is silent")
    func acknowledgedIsSilent() throws {
        let posted = recording()
        let decision = ledger.handleEntry(officeID: SeedData.colemanID, day: Day(2026, 8, 5))

        #expect(decision == .acknowledged)
        #expect(posted.requests.isEmpty)
        #expect(try container.mainContext.fetchCount(FetchDescriptor<ArrivalAlert>()) == 0)
    }

    /// Walking out and back in is a second arrival, and the desk number is
    /// wanted again. The first notification comes off the lock screen so the
    /// two do not stack.
    @Test("A later arrival alerts again and withdraws the one before it")
    func repeatsAndReplaces() throws {
        let posted = recording()
        let withdrawn = withdrawals()
        let arrived = Date(timeIntervalSince1970: 1_785_000_000)

        ledger.handleEntry(officeID: SeedData.colemanID, day: unattended, now: arrived)
        let second = ledger.handleEntry(
            officeID: SeedData.colemanID, day: unattended,
            now: arrived.addingTimeInterval(ArrivalRule.settleWindow + 1)
        )

        guard case .desk = second else {
            Issue.record("expected a second desk alert, got \(second)")
            return
        }
        #expect(posted.requests.count == 2)
        #expect(
            posted.requests[0].identifier != posted.requests[1].identifier,
            "a shared identifier would edit the first alert instead of raising a second"
        )
        #expect(withdrawn.identifiers == [posted.requests[0].identifier])
        #expect(try container.mainContext.fetchCount(FetchDescriptor<ArrivalAlert>()) == 2)
    }

    @Test("A crossing inside the settle window posts nothing and writes nothing")
    func settlesInsideTheWindow() throws {
        let posted = recording()
        let arrived = Date(timeIntervalSince1970: 1_785_000_000)

        ledger.handleEntry(officeID: SeedData.colemanID, day: unattended, now: arrived)
        let second = ledger.handleEntry(
            officeID: SeedData.colemanID, day: unattended,
            now: arrived.addingTimeInterval(ArrivalRule.settleWindow - 1)
        )

        #expect(second == .settling)
        #expect(posted.requests.count == 1, "not a second notification")
        #expect(try container.mainContext.fetchCount(FetchDescriptor<ArrivalAlert>()) == 1)
    }

    /// Turning up with nothing booked repeats on the same terms — the day still
    /// counts if the user says it does, and until they do the prompt is worth
    /// making again.
    @Test("Arriving with nothing booked also repeats")
    func unbookedRepeats() throws {
        let posted = recording()
        _ = withdrawals()
        let day = Day(2026, 8, 20) // a working day with no seeded booking
        let arrived = Date(timeIntervalSince1970: 1_785_000_000)

        #expect(
            ledger.handleEntry(officeID: SeedData.colemanID, day: day, now: arrived)
                == .nothingBooked
        )
        #expect(
            ledger.handleEntry(
                officeID: SeedData.colemanID, day: day,
                now: arrived.addingTimeInterval(ArrivalRule.settleWindow + 1)
            ) == .nothingBooked
        )
        #expect(posted.requests.count == 2)
        #expect(posted.requests.first?.content.body.contains("No desk booked today.") == true)
    }

    /// The whole rule, end to end: it keeps asking until the button is tapped,
    /// and then it stops.
    @Test("Confirming is what ends the day's alerts")
    func confirmingStopsIt() throws {
        let posted = recording()
        _ = withdrawals()
        let arrived = Date(timeIntervalSince1970: 1_785_000_000)

        ledger.handleEntry(officeID: SeedData.colemanID, day: unattended, now: arrived)
        ledger.confirmAttendance(
            officeID: SeedData.colemanID, day: unattended, bookingID: nil
        )
        let after = ledger.handleEntry(
            officeID: SeedData.colemanID, day: unattended,
            now: arrived.addingTimeInterval(ArrivalRule.settleWindow + 1)
        )

        #expect(after == .acknowledged)
        #expect(posted.requests.count == 1, "the tap is what stopped it, not the window")
    }

    /// The geofence offers; the user confirms. Nothing else writes attendance.
    @Test("An arrival records no attendance until the button is tapped")
    func neverRecordsSilently() throws {
        _ = recording()
        let day = Day(2026, 8, 20)
        let before = try container.mainContext.fetchCount(FetchDescriptor<AttendanceDay>())

        ledger.handleEntry(officeID: SeedData.colemanID, day: day)
        #expect(
            try container.mainContext.fetchCount(FetchDescriptor<AttendanceDay>()) == before,
            "the alert offers; it does not record"
        )

        ledger.confirmAttendance(officeID: SeedData.colemanID, day: day, bookingID: nil)
        #expect(
            try container.mainContext.fetchCount(FetchDescriptor<AttendanceDay>()) == before + 1
        )

        // And confirming twice does not double-count the day.
        ledger.confirmAttendance(officeID: SeedData.colemanID, day: day, bookingID: nil)
        #expect(
            try container.mainContext.fetchCount(FetchDescriptor<AttendanceDay>()) == before + 1
        )
    }

    @Test("An office with its alert off is not woken for")
    func disabledOffice() throws {
        let posted = recording()
        let office = try #require(
            try container.mainContext.fetch(FetchDescriptor<Office>())
                .first { $0.id == SeedData.colemanID }
        )
        office.alertEnabled = false
        try container.mainContext.save()

        #expect(ledger.handleEntry(officeID: office.id, day: Day(2026, 8, 5)) == .disabled)
        #expect(posted.requests.isEmpty)
        #expect(try container.mainContext.fetchCount(FetchDescriptor<ArrivalAlert>()) == 0)
    }
}
