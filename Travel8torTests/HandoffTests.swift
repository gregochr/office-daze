import Foundation
import SwiftData
import Testing
import UserNotifications
@testable import Travel8tor

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

    /// The point of the whole screen: leave moves the target.
    @Test("Booking a day off lowers the target")
    func leaveMovesTheTarget() {
        let august = Month(year: 2026, month: 8)
        let none = Quota.calculate(.init(month: august, today: Day(2026, 8, 4)))
        #expect(none.target == 8)

        let three = Quota.calculate(.init(
            month: august,
            leave: [
                .init(Day(2026, 8, 17)), .init(Day(2026, 8, 18)), .init(Day(2026, 8, 19)),
            ],
            today: Day(2026, 8, 4)
        ))
        #expect(three.target == 7, "8 × 17 ÷ 20 = 6.8")
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

    @Test("All three conditions, or nothing")
    func conditions() {
        #expect(EveningNudge.shouldNudge(input()))
        #expect(!EveningNudge.shouldNudge(input(working: false)), "a weekend")
        #expect(!EveningNudge.shouldNudge(input(booked: true)), "already booked")
        #expect(!EveningNudge.shouldNudge(input(shortfall: 0)), "month already met")
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
            officeName: "Ropemaker Place",
            address: "25 Ropemaker St, London EC2Y 9LY",
            floor: floor, zone: zone,
            day: Day(2026, 8, 5),
            startTime: start, endTime: end
        )
    }

    /// Natural case, deliberately: this string leaves the app and lands in a
    /// calendar beside meetings other people wrote.
    @Test("The title reads as a calendar entry, not an app label")
    func title() {
        #expect(CalendarWriter.title(entry()) == "Desk 3C-114 · Ropemaker Place")
        #expect(
            CalendarWriter.location(entry())
                == "Ropemaker Place, 25 Ropemaker St, London EC2Y 9LY"
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
