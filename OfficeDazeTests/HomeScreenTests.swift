import Foundation
import SwiftData
import SwiftUI
import Testing
import UIKit
@testable import OfficeDaze

/// The home screen's decisions, taken without a screen.
///
/// Everything here is a `static` on `HomeScreen` for the reason the file's own
/// comments give: the rules worth getting right are the ones about which record
/// a row stands for, and those should be assertable without rendering anything.
@Suite("The home screen's rows, and what can be done to them")
@MainActor
struct HomeScreenTests {

    let container: ModelContainer

    init() throws {
        container = try Store.makeInMemoryContainer(seeded: true)
    }

    private func rows(in context: ModelContext) throws -> [HomeScreen.Entry] {
        HomeScreen.entries(
            bookings: try context.fetch(FetchDescriptor<DeskBooking>()),
            attendance: try context.fetch(FetchDescriptor<AttendanceDay>()),
            planned: try context.fetch(FetchDescriptor<PlannedDay>()),
            in: SeedData.month
        )
    }

    // MARK: The record a row stands for

    /// The seeded 5 August is the exact shape of the bug: a desk at Coleman and
    /// an AttendanceDay for the same day at the same office. The list shows one
    /// row for it — the booking's — so the attendance had no delete anywhere in
    /// the app, and `deleteAttendance` was unreachable for the commonest case
    /// there is, since a booked day is precisely the day the arrival alert
    /// fires on with an "I'm here" button to mis-tap.
    @Test("A day that was booked and worked can still have the day in the office removed")
    func bookedAndAttendedCanLoseTheAttendance() throws {
        let context = container.mainContext
        let fifth = Day(2026, 8, 5)
        let booking = try #require(
            try context.fetch(FetchDescriptor<DeskBooking>()).first { $0.day == fifth }
        )

        // One row for the day, and it is the booking — not an `.attended` one.
        // That is the invariant this fix has to leave standing.
        let dayRows = try rows(in: context).filter { $0.day == fifth }
        #expect(dayRows.count == 1)
        #expect(dayRows.first?.booking?.id == booking.id)

        // So that row's Delete has to ask, and it has to name the record it
        // would take: the 5th at Coleman, not some other day's.
        let attendance = try context.fetch(FetchDescriptor<AttendanceDay>())
        guard case .bookingOrAttendance(let record) = HomeScreen.deletion(
            for: try #require(dayRows.first), attendance: attendance
        ) else {
            Issue.record("the row should offer both of the records behind it")
            return
        }
        #expect(record.day == fifth)
        #expect(record.officeID == SeedData.colemanID)

        let today = Day(2026, 8, 13)
        let before = try QuotaService.snapshot(
            for: SeedData.month, today: today, in: context
        ).result.attended
        try BookingStore.deleteAttendance(record, in: context)
        let after = try QuotaService.snapshot(
            for: SeedData.month, today: today, in: context
        ).result.attended
        #expect(after == before - 1, "the day comes off the gauge")

        // The desk survives it. The two are separate records and the dialog
        // says so; removing the day worked is not cancelling the booking.
        #expect(try context.fetchCount(FetchDescriptor<DeskBooking>()) == 4)
        #expect(!booking.notAttended, "removing the record is not answering no")

        // And the day goes back to being an open question, which is the point:
        // it can now be answered again, at a half day if that is what it was.
        #expect(HomeScreen.isUnanswered(
            .booking(booking),
            attendance: try context.fetch(FetchDescriptor<AttendanceDay>()),
            today: today
        ))
    }

    /// The negative. Asking on every delete would be a worse trade than the one
    /// the question buys, so only a row with two records behind it asks.
    @Test("A row with one record behind it deletes without a question")
    func singleRecordRowsDeleteOutright() throws {
        let context = container.mainContext
        // 12 August: booked at Coleman, nobody has said they were there.
        let unattended = try #require(
            try context.fetch(FetchDescriptor<DeskBooking>())
                .first { $0.day == Day(2026, 8, 12) }
        )
        try BookingStore.recordPlanned(
            day: Day(2026, 8, 20), officeID: SeedData.brusselsID,
            today: Day(2026, 8, 13), in: context
        )
        let attendance = try context.fetch(FetchDescriptor<AttendanceDay>())
        let planned = try #require(try context.fetch(FetchDescriptor<PlannedDay>()).first)
        // 3 August: attended at Coleman with no desk behind it — the deskless
        // row, which is where `deleteAttendance` could already be reached.
        let deskless = try #require(
            attendance.first { $0.day == Day(2026, 8, 3) }
        )

        for entry in [
            HomeScreen.Entry.booking(unattended),
            .attended(deskless),
            .planned(planned),
        ] {
            guard case .record = HomeScreen.deletion(for: entry, attendance: attendance) else {
                Issue.record("\(entry.day) holds one record and should not ask")
                continue
            }
        }
    }

    /// The pairing is day *and* office, the same one `entries` uses to decide
    /// which rows exist. Get it wrong and a row's Delete offers to remove a
    /// record that belongs to the row underneath it.
    @Test("A day worked at the other office is not the booking row's to remove")
    func attendanceIsMatchedOnOfficeAsWellAsDay() throws {
        let context = container.mainContext
        let twelfth = Day(2026, 8, 12)
        let colemanDesk = try #require(
            try context.fetch(FetchDescriptor<DeskBooking>()).first { $0.day == twelfth }
        )
        #expect(colemanDesk.officeID == SeedData.colemanID)

        // Same day, other building: an afternoon in Brussels with no desk.
        try BookingStore.recordAttendance(
            day: twelfth, officeID: SeedData.brusselsID, source: .manual,
            today: twelfth, in: context
        )
        let attendance = try context.fetch(FetchDescriptor<AttendanceDay>())

        #expect(
            HomeScreen.attendanceRecord(for: colemanDesk, in: attendance) == nil,
            "the Coleman desk was not attended, whatever happened in Brussels"
        )
        guard case .record = HomeScreen.deletion(for: .booking(colemanDesk), attendance: attendance)
        else {
            Issue.record("the desk row should delete the desk, with nothing else behind it")
            return
        }

        // The Brussels day is not lost by that — it is its own row, with its
        // own delete, exactly as an unbooked day has always been.
        let dayRows = try rows(in: context).filter { $0.day == twelfth }
        #expect(dayRows.count == 2)
        let attended = dayRows.compactMap { entry -> AttendanceDay? in
            if case .attended(let record) = entry { return record }
            return nil
        }
        #expect(attended.map(\.officeID) == [SeedData.brusselsID])
    }

    /// Each booking has to find its own record, not merely some record. The two
    /// seeded attended bookings are a day apart at the same office, which is
    /// the case a lookup that only matched on office would get wrong.
    @Test("Each booking finds the record for its own day")
    func attendanceRecordIsPerBooking() throws {
        let context = container.mainContext
        let attendance = try context.fetch(FetchDescriptor<AttendanceDay>())
        let bookings = try context.fetch(FetchDescriptor<DeskBooking>())

        for day in [Day(2026, 8, 5), Day(2026, 8, 6)] {
            let booking = try #require(bookings.first { $0.day == day })
            let record = try #require(HomeScreen.attendanceRecord(for: booking, in: attendance))
            #expect(record.day == day)
            #expect(record.bookingID == booking.id, "and it is the record that names it")
        }
    }

    // MARK: The office split

    /// The bar is one figure divided, so each segment has to be that office's
    /// own days. An office with nothing recorded has no segment at all.
    @Test("The split gives each office its own days, biggest first, and drops the empty ones")
    func officeSharesOrderAndFilter() {
        let coleman = Office(
            id: SeedData.colemanID, name: "Coleman", address: "", postcode: "",
            colourHex: OfficeColours.palette[0]
        )
        let brussels = Office(
            id: SeedData.brusselsID, name: "Brussels", address: "", postcode: "",
            colourHex: OfficeColours.palette[1]
        )
        // Two ways to have nothing this month: absent from the split, and
        // present with a zero.
        let amsterdam = Office(
            name: "Amsterdam", address: "", postcode: "",
            colourHex: OfficeColours.palette[2]
        )
        let dublin = Office(
            name: "Dublin", address: "", postcode: "",
            colourHex: OfficeColours.palette[3]
        )

        let shares = HomeScreen.officeShares(
            offices: [coleman, brussels, amsterdam, dublin],
            attendedByOffice: [
                SeedData.colemanID: 1.5, SeedData.brusselsID: 3, dublin.id: 0,
            ]
        )
        #expect(shares.map(\.office.name) == ["Brussels", "Coleman"])
        #expect(shares.map(\.days) == [3, 1.5], "each office keeps its own figure")
    }

    // MARK: The heading over the list

    /// The heading was the literal "This month" over rows the stepper moves in
    /// both directions.
    @Test("The bookings heading names the month the list is actually showing")
    func headingFollowsTheStepper() {
        let today = Day(2026, 8, 7)
        #expect(HomeScreen.bookingsTitle(month: Month(year: 2026, month: 8), today: today)
                == "This month")
        #expect(HomeScreen.bookingsTitle(month: Month(year: 2026, month: 10), today: today)
                == "October 2026")
        #expect(HomeScreen.bookingsTitle(month: Month(year: 2026, month: 7), today: today)
                == "July 2026")
        // The same month a year out is not this month, and only comparing the
        // month number would say it was.
        #expect(HomeScreen.bookingsTitle(month: Month(year: 2025, month: 8), today: today)
                == "August 2025")
    }

    // MARK: Answering "Were you there?"

    /// The refusal `try?` hid.
    ///
    /// `recordAttendance` declines a write by returning nil, not by throwing, so
    /// `try? BookingStore.recordAttendance(...)` discarded a decline and a throw
    /// alike and the screen carried on to `answered()`. This is the reachable
    /// decline: a day whose recorded fractions already total a whole day in the
    /// other building. The row goes on asking, because `isUnanswered` matches on
    /// the row's own office — so Yes was live, wrote nothing, and said nothing.
    @Test("Yes on a day already recorded in full at another office is refused, and says why")
    func yesIsRefusedWhenTheDayIsWholeAtAnotherOffice() throws {
        let context = container.mainContext
        let twelfth = Day(2026, 8, 12)
        let today = Day(2026, 8, 13)
        let desk = try #require(
            try context.fetch(FetchDescriptor<DeskBooking>()).first { $0.day == twelfth }
        )
        #expect(desk.officeID == SeedData.colemanID)

        try BookingStore.recordAttendance(
            day: twelfth, officeID: SeedData.brusselsID, source: .manual,
            today: today, in: context
        )
        let entry = HomeScreen.Entry.booking(desk)
        #expect(
            HomeScreen.isUnanswered(
                entry, attendance: try context.fetch(FetchDescriptor<AttendanceDay>()),
                today: today
            ),
            "the Coleman row still asks — which is what makes the refusal reachable"
        )

        let before = try context.fetchCount(FetchDescriptor<AttendanceDay>())
        let answer = HomeScreen.answerYes(entry) { day, officeID, bookingID in
            try BookingStore.recordAttendance(
                day: day, officeID: officeID, source: .manual,
                bookingID: bookingID, today: today, in: context
            ) != nil
        }
        #expect(answer == .refused, "nil from the store is not a success")
        #expect(
            try context.fetchCount(FetchDescriptor<AttendanceDay>()) == before,
            "and nothing was written, which is precisely what went unsaid"
        )

        // And the sentence the user now gets names the day, the reason, and the
        // fact that nothing changed.
        #expect(
            HomeScreen.refusal(
                day: twelfth, officeID: SeedData.colemanID,
                attendance: try context.fetch(FetchDescriptor<AttendanceDay>())
            ) == "12 August already has a whole day recorded at another office, and a whole "
            + "day here would take it over one. Remove that day first if it is wrong."
        )

        // The row is unchanged by the refusal: still asking, still answerable
        // once the wrong day is taken off.
        #expect(
            HomeScreen.isUnanswered(
                entry, attendance: try context.fetch(FetchDescriptor<AttendanceDay>()),
                today: today
            )
        )
    }

    /// The negative of the above, and the case that must not regress: an
    /// ordinary unanswered day answers yes, the record lands, and the row stops
    /// asking.
    @Test("Yes on a day nothing else claims writes the record and reports it written")
    func yesWritesAnOrdinaryDay() throws {
        let context = container.mainContext
        let twelfth = Day(2026, 8, 12)
        let today = Day(2026, 8, 13)
        let desk = try #require(
            try context.fetch(FetchDescriptor<DeskBooking>()).first { $0.day == twelfth }
        )
        let before = try context.fetchCount(FetchDescriptor<AttendanceDay>())

        let answer = HomeScreen.answerYes(.booking(desk)) { day, officeID, bookingID in
            try BookingStore.recordAttendance(
                day: day, officeID: officeID, source: .manual,
                bookingID: bookingID, today: today, in: context
            ) != nil
        }
        #expect(answer == .written)

        let attendance = try context.fetch(FetchDescriptor<AttendanceDay>())
        #expect(attendance.count == before + 1)
        let written = try #require(attendance.first { $0.day == twelfth })
        #expect(written.officeID == SeedData.colemanID)
        #expect(written.bookingID == desk.id, "and it knows which desk it belongs to")
        #expect(!HomeScreen.isUnanswered(.booking(desk), attendance: attendance, today: today))
    }

    /// The row's *own* day and office, and the booking id only where there is a
    /// booking. A planned day has no desk, and an attendance row that claimed
    /// one would point at a booking that does not exist.
    @Test("Yes hands the store the row's own day and office, with a booking id only for a booking")
    func yesPassesTheRowsOwnArguments() throws {
        let context = container.mainContext
        let desk = try #require(
            try context.fetch(FetchDescriptor<DeskBooking>())
                .first { $0.day == Day(2026, 8, 12) }
        )
        let plan = try #require(
            try BookingStore.recordPlanned(
                day: Day(2026, 8, 20), officeID: SeedData.brusselsID,
                today: Day(2026, 8, 13), in: context
            )
        )

        var seen: [(day: Day, officeID: UUID?, bookingID: UUID?)] = []
        // The write succeeds only for the arguments the row actually stands for.
        // Reading the wrong record comes back as a refusal rather than as a
        // success nobody looked at.
        let booked = HomeScreen.answerYes(.booking(desk)) { day, officeID, bookingID in
            seen.append((day, officeID, bookingID))
            return day == desk.day && officeID == desk.officeID && bookingID == desk.id
        }
        #expect(booked == .written)

        let intended = HomeScreen.answerYes(.planned(plan)) { day, officeID, bookingID in
            seen.append((day, officeID, bookingID))
            return day == plan.day && officeID == plan.officeID && bookingID == nil
        }
        #expect(intended == .written)

        #expect(seen.count == 2, "one write each, and no extra")
        #expect(seen.map(\.day) == [desk.day, plan.day])
        #expect(seen.map(\.officeID) == [SeedData.colemanID, SeedData.brusselsID])
        #expect(seen.map(\.bookingID) == [desk.id, nil])
    }

    /// The other half of what `try?` swallowed. A throw is a different failure
    /// from a refusal and has to reach the user as one — with the error in it,
    /// because unlike a refusal there is nothing on screen that explains it.
    @Test("A Yes whose write throws is reported with the day and the reason")
    func yesReportsAThrow() throws {
        let desk = try #require(
            try container.mainContext.fetch(FetchDescriptor<DeskBooking>())
                .first { $0.day == Day(2026, 8, 12) }
        )
        let answer = HomeScreen.answerYes(.booking(desk)) { _, _, _ in throw StoreRefused() }
        guard case .failed(let why) = answer else {
            Issue.record("a thrown write is a failure, not a success: \(answer)")
            return
        }
        #expect(why.contains("12 August"))
        #expect(why.contains("the store would not save"))
        #expect(why.contains("Nothing was saved."))
    }

    /// A day already answered has nothing to write. The store must not be
    /// touched at all — asking it would be a second row for a day that has one,
    /// and neither button on such a row has anything left to say.
    @Test("An attended row has no question, and neither answer reaches the store")
    func attendedRowsWriteNothing() throws {
        let record = try #require(
            try container.mainContext.fetch(FetchDescriptor<AttendanceDay>())
                .first { $0.day == Day(2026, 8, 3) }
        )
        var calls = 0
        let yes = HomeScreen.answerYes(.attended(record)) { _, _, _ in
            calls += 1
            return true
        }
        #expect(yes == .nothing, "and not `.written`, which would claim a write")

        let no = HomeScreen.answerNo(
            .attended(record),
            mark: { _ in calls += 1 },
            forget: { _ in calls += 1 }
        )
        #expect(no == .nothing)
        #expect(calls == 0)
    }

    /// The red strip's trailing half. Singular and plural are the whole of it,
    /// and "1 days left" under the app's only red is the kind of thing that
    /// makes the number beside it look guessed at.
    @Test("The days left in an unreachable month are counted in English")
    func daysLeftIsSingularForOne() {
        // Friday 28 August 2026 is the last working day of that month — the
        // 29th and 30th are the weekend and the 31st is the summer bank
        // holiday — so the day itself is the only one left.
        let one = Quota.calculate(
            Quota.Inputs(month: Month(year: 2026, month: 8), today: Day(2026, 8, 28))
        )
        #expect(one.daysAvailable == 1)
        #expect(HomeScreen.daysLeftText(one) == "1 day left")

        let several = Quota.calculate(
            Quota.Inputs(month: Month(year: 2026, month: 8), today: Day(2026, 8, 26))
        )
        #expect(several.daysAvailable == 3, "the 26th, 27th and 28th")
        #expect(HomeScreen.daysLeftText(several) == "3 days left")
    }

    /// The branch the two closures exist to protect. A booked day is marked and
    /// kept — the desk was reserved whether or not it was used — and an
    /// intention that came to nothing is deleted. Swapping them would lose a
    /// booking or leave a forecast standing for a day that did not happen.
    @Test("No marks a booking and deletes a plan, each with its own record")
    func noTakesTheRightRecordForEachRow() throws {
        let context = container.mainContext
        let desk = try #require(
            try context.fetch(FetchDescriptor<DeskBooking>())
                .first { $0.day == Day(2026, 8, 12) }
        )
        let plan = try #require(
            try BookingStore.recordPlanned(
                day: Day(2026, 8, 20), officeID: SeedData.brusselsID,
                today: Day(2026, 8, 13), in: context
            )
        )

        var marked: [UUID] = []
        var forgotten: [UUID] = []
        let booked = HomeScreen.answerNo(
            .booking(desk),
            mark: { marked.append($0.id) },
            forget: { forgotten.append($0.id) }
        )
        #expect(booked == .written)
        #expect(marked == [desk.id])
        #expect(forgotten.isEmpty, "a booked day is not deleted for having gone unused")

        let intended = HomeScreen.answerNo(
            .planned(plan),
            mark: { marked.append($0.id) },
            forget: { forgotten.append($0.id) }
        )
        #expect(intended == .written)
        #expect(forgotten == [plan.id])
        #expect(marked == [desk.id], "and the plan did not go through the booking's door")
    }

    /// A No that fails is as silent as a Yes that fails, and worse in one way:
    /// the row goes on asking a question the user has already answered.
    @Test("A No whose write throws is reported rather than swallowed")
    func noReportsAThrow() throws {
        let desk = try #require(
            try container.mainContext.fetch(FetchDescriptor<DeskBooking>())
                .first { $0.day == Day(2026, 8, 12) }
        )
        let answer = HomeScreen.answerNo(
            .booking(desk),
            mark: { _ in throw StoreRefused() },
            forget: { _ in Issue.record("a booking is not a plan") }
        )
        guard case .failed(let why) = answer else {
            Issue.record("a thrown write is a failure: \(answer)")
            return
        }
        #expect(why.contains("12 August"))
        #expect(why.contains("the store would not save"))
    }

    /// The three reasons the store has, each said in terms of what is on the
    /// day. Only the middle one is reachable from a row's Yes; the others are
    /// written out so a future guard cannot land the user on a sentence that
    /// explains nothing.
    @Test("The refusal names what is on the day, not merely that something is")
    func refusalExplainsItself() throws {
        let context = container.mainContext
        let day = Day(2026, 8, 12)
        let today = Day(2026, 8, 13)

        // Nothing recorded at all: the fallback, and the only case with no
        // reason to give.
        #expect(
            HomeScreen.refusal(day: day, officeID: SeedData.colemanID, attendance: []) ==
            "12 August could not be recorded. Nothing was added."
        )

        // Half a day in the other building — the same refusal, said with the
        // fraction that is actually there rather than assuming a whole one.
        try BookingStore.recordAttendance(
            day: day, officeID: SeedData.brusselsID, source: .manual,
            fraction: 0.5, today: today, in: context
        )
        let half = try context.fetch(FetchDescriptor<AttendanceDay>())
        #expect(
            HomeScreen.refusal(day: day, officeID: SeedData.colemanID, attendance: half) ==
            "12 August already has half a day recorded at another office, and a whole "
            + "day here would take it over one. Remove that day first if it is wrong."
        )

        // And the same office, which is a different sentence: nothing is over
        // any limit, the day is simply already there.
        try BookingStore.recordAttendance(
            day: day, officeID: SeedData.colemanID, source: .manual,
            fraction: 0.5, today: today, in: context
        )
        let both = try context.fetch(FetchDescriptor<AttendanceDay>())
        #expect(
            HomeScreen.refusal(day: day, officeID: SeedData.colemanID, attendance: both) ==
            "12 August is already recorded at this office. Nothing was added."
        )
    }

    /// A delete has no refusal to report — nothing declines one — so all it
    /// needed was somewhere for the throw to land. The sentence has to name
    /// which of the three records failed, because the dialog that offers two of
    /// them is the reason this screen has a choice at all.
    @Test("A delete that fails names the record it could not remove")
    func deletionFailureNamesTheRecord() throws {
        let context = container.mainContext
        let desk = try #require(
            try context.fetch(FetchDescriptor<DeskBooking>())
                .first { $0.day == Day(2026, 8, 12) }
        )
        let attended = try #require(
            try context.fetch(FetchDescriptor<AttendanceDay>())
                .first { $0.day == Day(2026, 8, 3) }
        )
        let plan = try #require(
            try BookingStore.recordPlanned(
                day: Day(2026, 8, 20), officeID: SeedData.brusselsID,
                today: Day(2026, 8, 13), in: context
            )
        )

        #expect(
            HomeScreen.deletionFailure(.booking(desk), StoreRefused()) ==
            "The desk booking for 12 August couldn't be removed: the store would not save."
        )
        #expect(
            HomeScreen.deletionFailure(.attended(attended), StoreRefused()) ==
            "The day in the office for 3 August couldn't be removed: the store would not save."
        )
        #expect(
            HomeScreen.deletionFailure(.planned(plan), StoreRefused()) ==
            "The planned day for 20 August couldn't be removed: the store would not save."
        )
    }
}

/// A store call that will not save. Carries its own sentence so the tests above
/// can assert that the reason reaches the user rather than only that some
/// message was produced.
private struct StoreRefused: LocalizedError {
    var errorDescription: String? { "the store would not save" }
}

/// The screen itself, drawn.
///
/// Every rule above is a `static` asserted without a screen, which is how this
/// file wants it — but a `static` that is never reached from `body` is a rule
/// the screen does not follow, and nothing above could tell the difference. The
/// cards that only exist in one state of the store are the same problem: the
/// empty month, the question on an unanswered day, the met strip.
///
/// These tests read the real clock, because the screen does: it opens on
/// `Day.today.month_` and there is no seam for a date. So each one builds its
/// state relative to `Day.today` rather than naming a date, and asserts the
/// helper that decides which card is drawn before drawing it — a render on its
/// own would prove only that the screen does not crash.
@Suite("The home screen, drawn")
@MainActor
struct HomeScreenRenderTests {

    /// In a window and made key. A `UIHostingController` laid out on its own
    /// never evaluates `body`, so the same test written without this measures
    /// nothing at all while passing.
    private func render(_ container: ModelContainer) -> UIView {
        let host = UIHostingController(
            rootView: NavigationStack { HomeScreen() }
                .environment(CaptureCoordinator(context: container.mainContext))
                .modelContainer(container)
        )
        let window = ArrivalPreviewRenderTests.renderWindow()
        window.rootViewController = host
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        let drawn = host.view!
        // See ArrivalPreviewRenderTests.dismantle: a window left key outlives
        // the container it was handed, and its `@Query` is still subscribed
        // when a later suite saves. The view is held first, so what it drew
        // survives to be asserted on.
        ArrivalPreviewRenderTests.dismantle(window, holding: container)
        return drawn
    }

    private func entries(in context: ModelContext, month: Month) throws -> [HomeScreen.Entry] {
        HomeScreen.entries(
            bookings: try context.fetch(FetchDescriptor<DeskBooking>()),
            attendance: try context.fetch(FetchDescriptor<AttendanceDay>()),
            planned: try context.fetch(FetchDescriptor<PlannedDay>()),
            in: month
        )
    }

    /// The ordinary screen: a gauge, a split between two buildings, and a row
    /// per record. The split is the one card with a condition on it — two
    /// offices or more — and this is the state that satisfies it.
    @Test("The seeded month draws its gauge, its split between two offices, and its rows")
    func theSeededMonthDraws() throws {
        let container = try Store.makeInMemoryContainer(seeded: true)
        let context = container.mainContext
        let month = Day.today.month_
        let snapshot = try QuotaService.snapshot(for: month, today: .today, in: context)

        let shares = HomeScreen.officeShares(
            offices: try context.fetch(FetchDescriptor<Office>()),
            attendedByOffice: snapshot.attendedByOffice
        )
        #expect(shares.count == 2, "both buildings were worked in, so the bar has two segments")
        #expect(
            shares.reduce(0) { $0 + $1.days } == snapshot.result.attended,
            "and the bar is the gauge's own number divided, not a second count of the month"
        )
        // Six rows for eight records: the 5th and the 6th were booked *and*
        // worked, and one day at one office is one row however many records
        // describe it.
        #expect(try entries(in: context, month: month).count == 6)
        #expect(
            HomeScreen.targetExplanation(snapshot.result)
                .hasPrefix("Target \(snapshot.result.target)"),
            "the line under the dial names the number the dial is measured against"
        )

        let view = render(container)
        #expect(view.bounds.width == 393, "it laid out at the size it was given")
        #expect(!view.subviews.isEmpty)
    }

    /// The success strip, which is the one state of the four that says the month
    /// is over as far as the target is concerned. Twelve days is more than the
    /// target can ever be — it is capped at eight before leave takes any of it
    /// away — so this is `.met` on whatever date the suite runs.
    @Test("A month worked past its target draws the met strip rather than a shortfall")
    func aMetMonthDraws() throws {
        let container = try Store.makeInMemoryContainer(seeded: true)
        let context = container.mainContext
        let month = Day.today.month_
        for day in month.days.prefix(12) {
            context.insert(
                AttendanceDay(day: day, officeID: SeedData.colemanID, source: .manual)
            )
        }
        try context.save()

        let result = try QuotaService.snapshot(for: month, today: .today, in: context).result
        #expect(result.attended >= Double(result.target))
        #expect(result.standing == .met, "which is the branch the success strip is behind")
        #expect(result.shortfall == 0)

        #expect(!render(container).subviews.isEmpty)
    }

    /// The question, and the label it replaces.
    ///
    /// A planned day the month has walked past has nowhere to keep an answer, so
    /// its row drops the "Planned" label and asks instead. A plan that is still
    /// current keeps the label. Both rows are drawn by the same call, which is
    /// why they are set up on one screen: the argument that differs is the one
    /// this is about.
    @Test("A planned day gone by asks its question, and one still current keeps its label")
    func theQuestionDraws() throws {
        let container = try Store.makeInMemoryContainer(seeded: true)
        let context = container.mainContext
        let month = Day.today.month_
        // A third building, so neither plan collides with a seeded booking —
        // `entries` drops a planned day that a desk already speaks for, and the
        // point here is the two planned rows.
        let amsterdam = Office(
            name: "Amsterdam", address: "", postcode: "",
            colourHex: OfficeColours.palette[2]
        )
        context.insert(amsterdam)

        let past = try #require(
            month.days.last { $0 < .today },
            "the month needs a day behind today for the question to be asked on"
        )
        // Inserted rather than recorded: `recordPlanned` refuses the past, which
        // is the point — this state is reached by a plan the month walked past.
        let gone = PlannedDay(day: past, officeID: amsterdam.id)
        let current = PlannedDay(day: .today, officeID: amsterdam.id)
        context.insert(gone)
        context.insert(current)
        try context.save()

        let attendance = try context.fetch(FetchDescriptor<AttendanceDay>())
        #expect(
            HomeScreen.isUnanswered(.planned(gone), attendance: attendance, today: .today),
            "so its row asks rather than claiming a day nobody has confirmed"
        )
        #expect(
            !HomeScreen.isUnanswered(.planned(current), attendance: attendance, today: .today),
            "today is still being worked — the arrival alert and the nudge have it"
        )
        let rows = try entries(in: context, month: month)
        #expect(rows.filter { $0.officeID == amsterdam.id }.count == 2)

        #expect(!render(container).subviews.isEmpty)
    }

    /// Two different empties, and they are different on purpose: no offices at
    /// all is a setup problem with a way out of it, and an empty month is just
    /// an empty month.
    @Test("A store with no offices offers to add one; an empty month only says it is empty")
    func theEmptyStatesDraw() throws {
        let bare = try Store.makeInMemoryContainer(seeded: false)
        #expect(try bare.mainContext.fetchCount(FetchDescriptor<Office>()) == 0)
        #expect(try entries(in: bare.mainContext, month: Day.today.month_).isEmpty)
        #expect(!render(bare).subviews.isEmpty)

        // Offices kept, records cleared — the state a wipe of scope `.records`
        // leaves behind, and the one where the card must not offer to add an
        // office that is already there.
        let emptied = try Store.makeInMemoryContainer(seeded: true)
        let context = emptied.mainContext
        for booking in try context.fetch(FetchDescriptor<DeskBooking>()) {
            context.delete(booking)
        }
        for day in try context.fetch(FetchDescriptor<AttendanceDay>()) { context.delete(day) }
        for day in try context.fetch(FetchDescriptor<PlannedDay>()) { context.delete(day) }
        try context.save()

        #expect(try context.fetchCount(FetchDescriptor<Office>()) == 2)
        #expect(try entries(in: context, month: Day.today.month_).isEmpty)
        // And with nothing recorded there is nothing to divide, so the split
        // card goes with it rather than drawing an empty bar.
        let snapshot = try QuotaService.snapshot(for: Day.today.month_, today: .today, in: context)
        #expect(
            HomeScreen.officeShares(
                offices: try context.fetch(FetchDescriptor<Office>()),
                attendedByOffice: snapshot.attendedByOffice
            ).isEmpty
        )
        #expect(!render(emptied).subviews.isEmpty)
    }
}
