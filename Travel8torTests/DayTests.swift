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
    }

    @Test("Month arithmetic steps the gauge's month picker")
    func monthArithmetic() {
        #expect(Month(year: 2026, month: 8).adding(months: 1) == Month(year: 2026, month: 9))
        #expect(Month(year: 2026, month: 12).adding(months: 1) == Month(year: 2027, month: 1))
        #expect(Month(year: 2026, month: 1).adding(months: -1) == Month(year: 2025, month: 12))
    }

    /// The day a booking files under does not move with the phone. There is no
    /// timezone handling in this app, and a `Date` read back out of the store
    /// must come back as the day it went in as — wherever the device is.
    @Test("A day survives the round trip through storage")
    func storageRoundTrip() {
        for day in [Day(2026, 8, 5), Day(2026, 1, 1), Day(2026, 12, 31)] {
            #expect(Day(of: day.startOfDayUTC) == day)
        }
    }

    @Test("Dates read the way the screens print them")
    func formatting() {
        #expect(Day(2026, 8, 5).longText == "Wednesday 5 August")
        #expect(Day(2026, 8, 5).mediumText == "Wed 5 August")
        #expect(Month(year: 2026, month: 8).text == "August 2026")
        #expect(Day(2026, 8, 5).description == "2026-08-05")
    }
}
