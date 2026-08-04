import Foundation
import Testing
@testable import Travel8tor

@Suite("Day and Month")
struct DayTests {

    @Test("August 2026 has 21 weekdays")
    func augustWeekdays() {
        #expect(Month(year: 2026, month: 8).days.count == 31)
        #expect(Month(year: 2026, month: 8).weekdays.count == 21)
        #expect(Day(2026, 8, 1).isWeekend) // a Saturday
    }

    @Test("Ordering is calendar ordering")
    func ordering() {
        #expect(Day(2026, 9, 7) < Day(2026, 9, 11))
        #expect(Day(2026, 8, 31) < Day(2026, 9, 1))
        #expect(Day(2025, 12, 31) < Day(2026, 1, 1))
        #expect(!(Day(2026, 9, 7) < Day(2026, 9, 7)))
    }

    @Test("Day arithmetic crosses month and year boundaries")
    func arithmetic() {
        #expect(Day(2026, 8, 31).adding(days: 1) == Day(2026, 9, 1))
        #expect(Day(2026, 12, 31).adding(days: 1) == Day(2027, 1, 1))
        #expect(Day(2026, 3, 1).adding(days: -1) == Day(2026, 2, 28))
        #expect(Day(2026, 9, 7).days(until: Day(2026, 9, 11)) == 4)
    }

    @Test("The day of an instant depends on the zone you ask from")
    func zoneSensitivity() {
        let london = TimeZone(identifier: "Europe/London")!
        let brussels = TimeZone(identifier: "Europe/Brussels")!

        // The Eurostar arrives 20:05 Brussels time, which is 19:05 in London.
        // Same day either way.
        let arrival = Day(2026, 9, 7).at(20, 5, in: brussels)
        #expect(Day(of: arrival, in: brussels) == Day(2026, 9, 7))
        #expect(Day(of: arrival, in: london) == Day(2026, 9, 7))

        // A half past midnight arrival is not.
        let lateArrival = Day(2026, 9, 8).at(0, 30, in: brussels)
        #expect(Day(of: lateArrival, in: brussels) == Day(2026, 9, 8))
        #expect(Day(of: lateArrival, in: london) == Day(2026, 9, 7))
    }

    @Test("Round-tripping a wall-clock time preserves it in its own zone")
    func wallClockRoundTrip() {
        let brussels = TimeZone(identifier: "Europe/Brussels")!
        let instant = Day(2026, 9, 7).at(20, 5, in: brussels)

        var calendar = Day.calendar
        calendar.timeZone = brussels
        let parts = calendar.dateComponents([.hour, .minute], from: instant)
        #expect(parts.hour == 20)
        #expect(parts.minute == 5)
    }
}
