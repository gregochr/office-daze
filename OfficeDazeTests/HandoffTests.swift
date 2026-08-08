import EventKit
import Foundation
import SwiftData
import Testing
import UserNotifications
@testable import OfficeDaze

@Suite("Leave")
struct LeaveTests {

    /// Whole days are the common case, so they are one tap and the half is two
    /// — not the other way round.
    @Test("A day cycles none → whole → half → none")
    func cycle() {
        #expect(LeaveCycle.next(after: nil) == 1.0)
        #expect(LeaveCycle.next(after: 1.0) == 0.5)
        #expect(LeaveCycle.next(after: 0.5) == nil)
    }

    /// A weekend and a bank holiday are already outside working days, so
    /// booking one off would deduct the same day twice and quietly lower the
    /// target. A day already attended is history.
    @Test("Days already outside the count cannot be booked off")
    func editability() {
        let bankHoliday = Day(2026, 8, 31)
        let attended = Day(2026, 8, 5)
        let holidays: Set<Day> = [bankHoliday]
        let attendedDays: Set<Day> = [attended]

        #expect(LeaveCycle.editable(
            day: Day(2026, 8, 6), bankHolidays: holidays, attended: attendedDays
        ))
        #expect(!LeaveCycle.editable(
            day: Day(2026, 8, 1), bankHolidays: holidays, attended: attendedDays
        ), "a Saturday")
        #expect(!LeaveCycle.editable(
            day: bankHoliday, bankHolidays: holidays, attended: attendedDays
        ))
        #expect(!LeaveCycle.editable(
            day: attended, bankHolidays: holidays, attended: attendedDays
        ))
    }

    /// The point of the whole screen: leave moves the target. It moves in
    /// blocks of five days, so a week off is what shows up and three days does
    /// not.
    @Test("Booking a week off lowers the target")
    func leaveMovesTheTarget() {
        let august = Month(year: 2026, month: 8)
        func target(_ days: [Int]) -> Int {
            Quota.calculate(.init(
                month: august,
                leave: days.map { .init(Day(2026, 8, $0)) },
                today: Day(2026, 8, 4)
            )).target
        }
        #expect(target([]) == 8)
        #expect(target([17, 18, 19]) == 8, "three days is short of a block")
        #expect(target([17, 18, 19, 20, 21]) == 6, "the working week is a block")
    }
}

/// Three conditions, or it stays quiet. A reminder that fires when the month is
/// already met is a reminder that gets switched off — and then the one that
/// mattered never arrives either.
@Suite("The evening nudge")
struct EveningNudgeTests {

    func input(
        working: Bool = true, booked: Bool = false, shortfall: Double = 3
    ) -> EveningNudge.Input {
        .init(
            tomorrow: Day(2026, 8, 12),
            isWorkingDay: working,
            hasBookingTomorrow: booked,
            shortfall: shortfall
        )
    }

    func unconfirmed() -> EveningNudge.Unconfirmed {
        .init(
            day: Day(2026, 8, 11), officeID: UUID(), officeName: "Coleman",
            bookingID: UUID(), deskID: "3C-114"
        )
    }

    @Test("All three conditions, or nothing")
    func conditions() {
        #expect(EveningNudge.shouldNudge(input()))
        #expect(!EveningNudge.shouldNudge(input(working: false)), "a weekend")
        #expect(!EveningNudge.shouldNudge(input(booked: true)), "already booked")
        #expect(!EveningNudge.shouldNudge(input(shortfall: 0)), "month already met")

        #expect(EveningNudge.decide(input()) == .bookTomorrow)
        #expect(EveningNudge.decide(input(working: false)) == .quiet)
    }

    /// A day worked and never recorded is a fact on its way out of the app —
    /// attendance is the only copy. A day not yet booked is a plan, and plans
    /// keep until the morning.
    @Test("Today unanswered outranks tomorrow unbooked")
    func todayComesFirst() {
        let today = unconfirmed()
        var both = input()
        both.unconfirmedToday = today
        #expect(EveningNudge.decide(both) == .confirmToday(today))

        // And it asks even on the evenings the other branch would stay quiet
        // for: the month being met does not un-work the day.
        var metMonth = input(shortfall: 0)
        metMonth.unconfirmedToday = today
        #expect(EveningNudge.decide(metMonth) == .confirmToday(today))
    }

    /// A question, and the reason for asking. It does not say the day was
    /// worked — the desk was booked, which is a different thing, and assuming
    /// would make the one record the app cannot reconstruct into a guess.
    @Test("The question does not answer itself")
    func confirmCopy() {
        let message = EveningNudge.confirmMessage(unconfirmed())
        #expect(message.title == "Were you at Coleman today?")
        #expect(message.body.contains("Desk 3C-114 was booked for today"))
        #expect(message.body.contains("only counts once you say"))
    }

    /// The buttons have to record from the lock screen, which means the same
    /// user info the arrival alert carries — the handler behind them is the
    /// one that already exists.
    @Test("The question carries what its buttons need to write the record")
    func confirmRequest() {
        let asking = unconfirmed()
        let request = EveningNudge.request(
            at: DateComponents(hour: 18, minute: 0),
            title: "t", body: "b", answering: asking
        )
        let content = request.content
        #expect(content.categoryIdentifier == ArrivalNotifications.Category.nudgeConfirm.rawValue)
        #expect(
            content.userInfo[ArrivalNotifications.UserInfo.bookingID] as? String
                == asking.bookingID.uuidString
        )
        #expect(content.userInfo[ArrivalNotifications.UserInfo.day] as? String == "2026-08-11")
    }

    @Test("The copy says what is true and stops")
    func message() {
        let message = EveningNudge.message(shortfall: 3, tomorrow: Day(2026, 8, 12))
        #expect(message.title == "No desk booked for tomorrow")
        #expect(message.body.contains("3 days still to go"))
        #expect(message.body.contains("Wed 12 August"))

        let one = EveningNudge.message(shortfall: 1, tomorrow: Day(2026, 8, 12))
        #expect(one.body.contains("1 day still"), "singular")
    }

    /// A calendar trigger repeating daily, rather than one scheduled each
    /// evening: the app is not running most evenings, and a schedule that
    /// depends on the app being awake to set it is a schedule that stops.
    @Test("The trigger repeats daily at the chosen time")
    func repeatingTrigger() throws {
        let request = EveningNudge.request(
            at: DateComponents(hour: 18, minute: 30), title: "t", body: "b"
        )
        let trigger = try #require(request.trigger as? UNCalendarNotificationTrigger)
        #expect(trigger.repeats)
        #expect(trigger.dateComponents.hour == 18)
        #expect(trigger.dateComponents.minute == 30)
        #expect(request.identifier == EveningNudge.identifier, "one nudge, replaced not stacked")
    }
}

@Suite("Nudge scheduling")
@MainActor
struct NudgeSchedulerTests {

    let container: ModelContainer

    init() throws {
        container = try Store.makeInMemoryContainer(seeded: true)
        NudgeScheduler.isEnabled = true
    }

    final class Calls: @unchecked Sendable {
        var scheduled: [UNNotificationRequest] = []
        var withdrawn = 0
    }

    func recording() -> Calls {
        let calls = Calls()
        NudgeScheduler.schedule = { calls.scheduled.append($0) }
        NudgeScheduler.withdraw = { calls.withdrawn += 1 }
        return calls
    }

    /// 10 August 2026 is a Monday with no seeded booking, and the month is
    /// short — all three conditions.
    @Test("It schedules when tomorrow is a bare working day and the month is short")
    func schedules() {
        let calls = recording()
        #expect(NudgeScheduler.refresh(today: Day(2026, 8, 9), in: container.mainContext))
        #expect(calls.scheduled.count == 1)
        #expect(calls.scheduled.first?.content.title == "No desk booked for tomorrow")
    }

    /// 11 August has a seeded Brussels booking, so the evening of the 10th has
    /// nothing to say.
    @Test("A booked tomorrow withdraws rather than nudging")
    func withdrawsWhenBooked() {
        let calls = recording()
        #expect(!NudgeScheduler.refresh(today: Day(2026, 8, 10), in: container.mainContext))
        #expect(calls.scheduled.isEmpty)
        #expect(calls.withdrawn == 1)
    }

    @Test("A weekend tomorrow withdraws")
    func withdrawsAtWeekends() {
        let calls = recording()
        // Friday 7 August: tomorrow is a Saturday.
        #expect(!NudgeScheduler.refresh(today: Day(2026, 8, 7), in: container.mainContext))
        #expect(calls.withdrawn == 1)
    }

    /// 12 August has a seeded Coleman booking and no attendance against it —
    /// the day that would otherwise be lost.
    @Test("A day booked and unanswered is asked about instead of tomorrow")
    func asksAboutToday() throws {
        let calls = recording()
        #expect(NudgeScheduler.refresh(today: Day(2026, 8, 12), in: container.mainContext))
        let request = try #require(calls.scheduled.first)
        #expect(request.content.title == "Were you at Coleman today?")
        #expect(
            request.content.categoryIdentifier
                == ArrivalNotifications.Category.nudgeConfirm.rawValue
        )
    }

    /// 5 August is booked and already attended. Nothing left to ask, and the
    /// evening falls back to the branch about tomorrow — which on the 5th has
    /// a desk booked for the 6th, so it says nothing at all.
    @Test("A day already recorded is not asked about")
    func doesNotAskTwice() {
        let calls = recording()
        #expect(!NudgeScheduler.refresh(today: Day(2026, 8, 5), in: container.mainContext))
        #expect(calls.scheduled.isEmpty)
        #expect(calls.withdrawn == 1)
    }

    /// "No" is an answer, not an absence. Without storing it the question comes
    /// back every evening about the same day.
    @Test("An answer of no stops the question")
    func answeredNoStopsAsking() throws {
        let context = container.mainContext
        let booking = try #require(
            try context.fetch(FetchDescriptor<DeskBooking>())
                .first { $0.day == Day(2026, 8, 12) }
        )
        try BookingStore.markNotAttended(booking, in: context)

        let calls = recording()
        #expect(NudgeScheduler.refresh(today: Day(2026, 8, 12), in: context))
        #expect(calls.scheduled.first?.content.title == "No desk booked for tomorrow")
    }

    /// Two offices in one day is unusual but possible, a fetch has no order to
    /// rely on, and testing the wrong booking would decide the whole day was
    /// answered on the strength of the other office's attendance — losing
    /// exactly the day this feature exists to catch.
    @Test("A day with two desks asks about the one still unanswered")
    func picksTheUnansweredDesk() throws {
        let context = container.mainContext
        let today = Day(2026, 8, 12)
        // The 12th already has a Coleman booking. Add Brussels, and record
        // Coleman as attended so only Brussels is still an open question.
        try BookingStore.upsert(
            .init(
                officeID: SeedData.brusselsID, day: today, deskID: "2-099",
                floor: nil, zone: nil, startTime: nil, endTime: nil,
                source: .manual, unsureFields: []
            ),
            in: context
        )
        try BookingStore.recordAttendance(
            day: today, officeID: SeedData.colemanID, source: .manual,
            today: today, in: context
        )

        let calls = recording()
        #expect(NudgeScheduler.refresh(today: today, in: context))
        #expect(calls.scheduled.first?.content.title == "Were you at Brussels today?")
    }

    @Test("Switching it off withdraws whatever was pending")
    func withdrawsWhenDisabled() {
        let calls = recording()
        NudgeScheduler.isEnabled = false
        #expect(!NudgeScheduler.refresh(today: Day(2026, 8, 9), in: container.mainContext))
        #expect(calls.scheduled.isEmpty)
        #expect(calls.withdrawn == 1)
        NudgeScheduler.isEnabled = true
    }
}

@Suite("Calendar writes")
struct CalendarWriterTests {

    /// Both zones are pinned, never `.current`: the arithmetic this suite
    /// guards is right in London in July and wrong in half the world, so a
    /// test that inherits the simulator's zone proves nothing. London for the
    /// two days a year the clocks move, New York for the negative offset where
    /// midnight UTC is the previous evening.
    let london = TimeZone(identifier: "Europe/London")!
    let newYork = TimeZone(identifier: "America/New_York")!

    func entry(
        day: Day = Day(2026, 8, 5),
        floor: String? = "Level 3", zone: String? = "C",
        start: String? = "09:00", end: String? = "17:00"
    ) -> CalendarWriter.Entry {
        .init(
            deskID: "3C-114",
            officeName: "Coleman",
            address: "63 Coleman Street, London EC2R 5BB",
            floor: floor, zone: zone,
            day: day,
            startTime: start, endTime: end
        )
    }

    /// An absolute instant written the way a person would check it — with the
    /// offset spelled out, so the expectation says which wall clock it is.
    func instant(_ iso8601: String) throws -> Date {
        try #require(ISO8601DateFormatter().date(from: iso8601))
    }

    /// Natural case, deliberately: this string leaves the app and lands in a
    /// calendar beside meetings other people wrote.
    @Test("The title reads as a calendar entry, not an app label")
    func title() {
        #expect(CalendarWriter.title(entry()) == "Desk 3C-114 · Coleman")
        #expect(
            CalendarWriter.location(entry())
                == "Coleman, 63 Coleman Street, London EC2R 5BB"
        )
    }

    /// Only what was actually read. A floor the capture could not make out is
    /// absent from the note rather than an empty line.
    @Test("An unread field is left out of the note")
    func notes() {
        let full = CalendarWriter.notes(entry())
        #expect(full.contains("Floor: Level 3"))
        #expect(full.contains("Zone: C"))

        let partial = CalendarWriter.notes(entry(floor: nil, zone: nil))
        #expect(!partial.contains("Floor"))
        #expect(!partial.contains("Zone"))
        #expect(partial.contains("Office Daze"))
    }

    /// The instants, not the gap between them. A duration is true of the right
    /// answer and of every answer an hour either side of it.
    @Test("Wall-clock times become the event's span at the wall clock they say")
    func span() throws {
        let span = CalendarWriter.span(entry(), in: london)
        #expect(!span.isAllDay)
        #expect(try span.start == instant("2026-08-05T09:00:00+01:00"))
        #expect(try span.end == instant("2026-08-05T17:00:00+01:00"))
        #expect(span.end.timeIntervalSince(span.start) == 8 * 3600)
    }

    /// 29 March 2026 is the morning the UK clocks go forward, 25 October the
    /// morning they go back. Reaching 09:00 by adding 9 × 3600 seconds to
    /// midnight lands at 10:00 on the first and 08:00 on the second — an hour
    /// wrong in a calendar entry that says nothing about being a guess.
    @Test("The clocks moving does not move the desk")
    func daylightSaving() throws {
        let spring = CalendarWriter.span(entry(day: Day(2026, 3, 29)), in: london)
        #expect(try spring.start == instant("2026-03-29T09:00:00+01:00"))
        #expect(try spring.end == instant("2026-03-29T17:00:00+01:00"))

        let autumn = CalendarWriter.span(entry(day: Day(2026, 10, 25)), in: london)
        #expect(try autumn.start == instant("2026-10-25T09:00:00+00:00"))
        #expect(try autumn.end == instant("2026-10-25T17:00:00+00:00"))

        // Said the other way round, because this is the form the user sees:
        // the event opens at nine o'clock, whatever the clocks did that night.
        for span in [spring, autumn] {
            #expect(Day.localCalendar(london).component(.hour, from: span.start) == 9)
        }
    }

    /// Midnight UTC on the 5th is eight in the evening on the 4th in New York,
    /// so an all-day event started there files itself on the wrong day — and
    /// the user goes to the office a day early.
    @Test("An all-day event starts at local midnight, so it files on the booked day")
    func allDayStartsLocally() throws {
        let allDay = CalendarWriter.span(entry(start: nil, end: nil), in: newYork)
        #expect(allDay.isAllDay)
        #expect(try allDay.start == instant("2026-08-05T00:00:00-04:00"))
        #expect(allDay.end == allDay.start, "one day, not a span of none")
        #expect(Day(localOf: allDay.start, in: newYork) == Day(2026, 8, 5))
        #expect(allDay.start != entry().day.startOfDayUTC, "storage midnight is not local midnight")

        // The two branches have to agree with each other: whichever one a
        // booking takes, the event belongs to the same day.
        let timed = CalendarWriter.span(entry(), in: newYork)
        #expect(Day(localOf: timed.start, in: newYork) == Day(localOf: allDay.start, in: newYork))
    }

    /// A guessed 09:00 start would be a guess in somebody's calendar, so an
    /// unread time becomes an all-day event instead.
    @Test("Unread or nonsense times become an all-day event, never a guess")
    func allDayWhenUnread() {
        #expect(CalendarWriter.span(entry(start: nil, end: nil), in: london).isAllDay)
        #expect(CalendarWriter.span(entry(start: "09:00", end: nil), in: london).isAllDay)
        #expect(
            CalendarWriter.span(entry(start: "09:00", end: "08:00"), in: london).isAllDay,
            "ends first"
        )
        #expect(CalendarWriter.span(entry(start: "9am", end: "5pm"), in: london).isAllDay)
    }

    @Test("Times are parsed strictly")
    func minutes() {
        #expect(CalendarWriter.minutes("08:00") == 480)
        #expect(CalendarWriter.minutes("17:30") == 1050)
        #expect(CalendarWriter.minutes("24:00") == nil)
        #expect(CalendarWriter.minutes("8") == nil)
        #expect(CalendarWriter.minutes(nil) == nil)
    }

    /// A timed event names its zone, so the hour survives being read in
    /// another one. An all-day event must not: EventKit reads a zone as a
    /// promise that the event has a clock time, and setting one turns
    /// `isAllDay` back off — which is asserted here, because it is the sort of
    /// framework behaviour a tidying edit would undo.
    @Test("A timed event carries the zone it was written in, an all-day one carries none")
    func appliedToTheEvent() throws {
        let store = EKEventStore()

        // New York rather than London, and not because the desk is there: an
        // EKEvent handed a start date adopts the zone the machine is in, so a
        // London expectation on a London simulator would hold whether or not
        // this line was ever written.
        let timed = EKEvent(eventStore: store)
        CalendarWriter.apply(entry(), to: timed, in: newYork)
        #expect(timed.title == "Desk 3C-114 · Coleman")
        #expect(timed.location == "Coleman, 63 Coleman Street, London EC2R 5BB")
        #expect(timed.notes?.contains("Floor: Level 3") == true)
        #expect(!timed.isAllDay)
        #expect(try timed.startDate == instant("2026-08-05T09:00:00-04:00"))
        #expect(timed.timeZone == newYork)

        let allDay = EKEvent(eventStore: store)
        CalendarWriter.apply(entry(start: nil, end: nil), to: allDay, in: newYork)
        #expect(allDay.isAllDay)
        #expect(allDay.timeZone == nil)
    }
}

/// The rule that made the identifier on the booking worth storing, and the one
/// this file could not previously see: write-only access can add an event and
/// can never find it again.
@Suite("Calendar writing")
@MainActor
struct CalendarWriteTests {

    struct CalendarUnavailable: Error, LocalizedError {
        var errorDescription: String? { "The calendar is unavailable." }
    }

    /// Records every argument it is handed rather than nodding at them: the
    /// events it was asked to save are kept whole, so a test asserts what
    /// would have reached the user's calendar and not merely that something
    /// did.
    @MainActor
    final class FakeCalendar: CalendarBackend {
        var grantsAccess = true
        var accessError: Error?
        var saveError: Error?
        var identifier = "EVENT-NEW"

        private(set) var accessRequests = 0
        private(set) var saved: [EKEvent] = []
        private let store = EKEventStore()

        func requestWriteOnlyAccess() async throws -> Bool {
            accessRequests += 1
            if let accessError { throw accessError }
            return grantsAccess
        }

        func makeEvent() -> EKEvent { EKEvent(eventStore: store) }

        func save(_ event: EKEvent) throws -> String {
            if let saveError { throw saveError }
            saved.append(event)
            return identifier
        }
    }

    func entry(day: Day = Day(2026, 8, 5)) -> CalendarWriter.Entry {
        .init(
            deskID: "3C-114", officeName: "Coleman",
            address: "63 Coleman Street, London EC2R 5BB",
            floor: "Level 3", zone: "C", day: day,
            startTime: "09:00", endTime: "17:00"
        )
    }

    let london = TimeZone(identifier: "Europe/London")!

    @Test("A first write saves the booking the user is looking at")
    func addsTheEvent() async throws {
        let calendar = FakeCalendar()
        let outcome = await CalendarWriter.write(
            entry(), existingEventID: nil, in: london, using: calendar
        )
        #expect(outcome == .added("EVENT-NEW"))
        #expect(calendar.accessRequests == 1)

        let event = try #require(calendar.saved.first)
        #expect(calendar.saved.count == 1)
        #expect(event.title == "Desk 3C-114 · Coleman")
        #expect(event.notes?.contains("Zone: C") == true)
        #expect(
            event.startDate
                == ISO8601DateFormatter().date(from: "2026-08-05T09:00:00+01:00")
        )
    }

    /// The one that matters. Write-only access cannot read the event back to
    /// change it, so a second tap used to save a twin — two identical desk
    /// events on one day, and the first one's identifier overwritten, so
    /// nothing in the app could ever find it again.
    @Test("A booking already in the calendar is never written a second time")
    func refusesToWriteATwin() async {
        let calendar = FakeCalendar()
        let outcome = await CalendarWriter.write(
            entry(), existingEventID: "EVENT-1", in: london, using: calendar
        )
        #expect(outcome == .failed(CalendarWriter.alreadyWritten))
        #expect(calendar.saved.isEmpty)
        #expect(calendar.accessRequests == 0, "and it does not ask for access to refuse")
    }

    /// An empty string is not an event. It is what an identifier the calendar
    /// never gave us would look like, and it must not lock the booking out of
    /// the calendar for good.
    @Test("An empty identifier is no identifier")
    func emptyIdentifierStillWrites() async {
        let calendar = FakeCalendar()
        let outcome = await CalendarWriter.write(
            entry(), existingEventID: "", in: london, using: calendar
        )
        #expect(outcome == .added("EVENT-NEW"))
        #expect(calendar.saved.count == 1)
    }

    @Test("Refused access is reported, and nothing is written")
    func deniedAccess() async {
        let calendar = FakeCalendar()
        calendar.grantsAccess = false
        let outcome = await CalendarWriter.write(
            entry(), existingEventID: nil, in: london, using: calendar
        )
        #expect(outcome == .denied)
        #expect(calendar.accessRequests == 1)
        #expect(calendar.saved.isEmpty)
    }

    /// The reason has to reach the user: "Couldn't add to calendar" with no
    /// cause is a dead end for someone whose calendar is managed by their
    /// employer.
    @Test("An access error is carried out, not swallowed")
    func accessThrows() async {
        let calendar = FakeCalendar()
        calendar.accessError = CalendarUnavailable()
        let outcome = await CalendarWriter.write(
            entry(), existingEventID: nil, in: london, using: calendar
        )
        #expect(outcome == .failed("The calendar is unavailable."))
        #expect(calendar.saved.isEmpty)
    }

    /// A failed save must not read as a success, because the caller stores the
    /// returned identifier and would then refuse to ever write the booking.
    @Test("A save that throws is a failure, not a silent success")
    func saveThrows() async {
        let calendar = FakeCalendar()
        calendar.saveError = CalendarUnavailable()
        let outcome = await CalendarWriter.write(
            entry(), existingEventID: nil, in: london, using: calendar
        )
        #expect(outcome == .failed("The calendar is unavailable."))
        #expect(calendar.saved.isEmpty)
    }
}
