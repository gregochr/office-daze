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

    func entry(
        floor: String? = "Level 3", zone: String? = "C",
        start: String? = "09:00", end: String? = "17:00"
    ) -> CalendarWriter.Entry {
        .init(
            deskID: "3C-114",
            officeName: "Coleman",
            address: "63 Coleman Street, London EC2R 5BB",
            floor: floor, zone: zone,
            day: Day(2026, 8, 5),
            startTime: start, endTime: end
        )
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

    @Test("Wall-clock times become the event's span")
    func span() {
        let span = CalendarWriter.span(entry())
        #expect(!span.isAllDay)
        #expect(span.end.timeIntervalSince(span.start) == 8 * 3600)
    }

    /// A guessed 09:00 start would be a guess in somebody's calendar, so an
    /// unread time becomes an all-day event instead.
    @Test("Unread or nonsense times become an all-day event, never a guess")
    func allDayWhenUnread() {
        #expect(CalendarWriter.span(entry(start: nil, end: nil)).isAllDay)
        #expect(CalendarWriter.span(entry(start: "09:00", end: nil)).isAllDay)
        #expect(CalendarWriter.span(entry(start: "09:00", end: "08:00")).isAllDay, "ends first")
        #expect(CalendarWriter.span(entry(start: "9am", end: "5pm")).isAllDay)
    }

    @Test("Times are parsed strictly")
    func minutes() {
        #expect(CalendarWriter.minutes("08:00") == 480)
        #expect(CalendarWriter.minutes("17:30") == 1050)
        #expect(CalendarWriter.minutes("24:00") == nil)
        #expect(CalendarWriter.minutes("8") == nil)
        #expect(CalendarWriter.minutes(nil) == nil)
    }
}
