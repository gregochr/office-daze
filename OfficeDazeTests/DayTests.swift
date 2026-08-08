import Foundation
import Testing
@testable import OfficeDaze

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

    // MARK: The local bridges
    //
    // Every test below names its zone. That is the point of them: the bug they
    // pin was invisible for as long as the suite ran in whatever zone the
    // simulator was set to, which on this machine is the one zone — UTC's
    // neighbour — where the wrong answer and the right one agree in winter.

    static let newYork = TimeZone(identifier: "America/New_York")!
    static let london = TimeZone(identifier: "Europe/London")!
    static let tokyo = TimeZone(identifier: "Asia/Tokyo")!

    /// The regression. A `DatePicker` renders the instant it is given in the
    /// device's zone, so seeding it with midnight UTC showed the day before
    /// anywhere west of Greenwich: open a booking made on the 5th in New York
    /// and the picker read 4 August.
    @Test("The date a picker is seeded with is the day it shows, west of UTC")
    func pickerSeedIsNotAdayEarly() {
        let fifth = Day(2026, 8, 5)
        for zone in [Self.newYork, Self.london, Self.tokyo] {
            #expect(Day(localOf: fifth.localNoon(in: zone), in: zone) == fifth)
        }
        // And concretely, in the zone that used to break: the old bridge put
        // the picker's instant in the previous day.
        let oldWay = Day.localCalendar(Self.newYork)
            .dateComponents([.day], from: fifth.startOfDayUTC).day
        #expect(oldWay == 4, "the bug being fixed: midnight UTC is the 4th in New York")
        let newWay = Day.localCalendar(Self.newYork)
            .dateComponents([.day], from: fifth.localNoon(in: Self.newYork)).day
        #expect(newWay == 5)
    }

    /// `today` is the day it is where the phone is, not where UTC is. In Tokyo
    /// (UTC+9) at 08:00 on the 6th it is still the 5th in UTC; in New York
    /// (UTC-4) at 21:00 on the 5th it is already the 6th.
    @Test("Today is the local day, either side of the UTC boundary")
    func todayIsLocal() {
        // Built in UTC, which is independent of the local bridge under test.
        func utc(_ y: Int, _ m: Int, _ d: Int, _ hour: Int) -> Date {
            Day.calendar.date(from: DateComponents(
                year: y, month: m, day: d, hour: hour
            ))!
        }

        // 2026-08-05 23:00Z is 2026-08-06 08:00 in Tokyo (UTC+9).
        let tokyoMorning = utc(2026, 8, 5, 23)
        #expect(Day(localOf: tokyoMorning, in: Self.tokyo) == Day(2026, 8, 6))
        #expect(Day(of: tokyoMorning) == Day(2026, 8, 5), "the same instant is still the 5th in UTC")

        // 2026-08-06 01:00Z is 2026-08-05 21:00 in New York (UTC-4 in August).
        let newYorkEvening = utc(2026, 8, 6, 1)
        #expect(Day(localOf: newYorkEvening, in: Self.newYork) == Day(2026, 8, 5))
        #expect(Day(of: newYorkEvening) == Day(2026, 8, 6), "the same instant is already the 6th in UTC")
    }

    /// Noon rather than midnight, so a zone with no 00:00 on a spring-forward
    /// day still lands on the right date. Lord Howe and Santiago both skip
    /// midnight; Santiago's is the one a UK team would hit first.
    @Test("A day whose local midnight does not exist still bridges")
    func springForwardMidnight() {
        let santiago = TimeZone(identifier: "America/Santiago")!
        // 2026-09-06 in Santiago begins at 01:00 — 00:00 never happens.
        let day = Day(2026, 9, 6)
        #expect(Day(localOf: day.localNoon(in: santiago), in: santiago) == day)
    }

    @Test("Storage stays on UTC, whatever the device is doing")
    func storageIsUnmovedByZone() {
        // The storage codec is a matched pair and must not acquire a zone.
        for day in [Day(2026, 8, 5), Day(2026, 1, 1), Day(2026, 12, 31)] {
            #expect(Day(of: day.startOfDayUTC) == day)
        }
    }

    // MARK: Validation

    @Test("A date that does not exist is rejected rather than rolled forward")
    func validation() {
        #expect(Day(validating: 2026, 2, 30) == nil)
        #expect(Day(validating: 2026, 13, 1) == nil)
        #expect(Day(validating: 2026, 4, 31) == nil)
        #expect(Day(validating: 2026, 0, 10) == nil)
        #expect(Day(validating: 2026, 8, 0) == nil)
        #expect(Day(validating: 2026, 8, 32) == nil)
        // 2028 is a leap year, 2026 is not.
        #expect(Day(validating: 2026, 2, 29) == nil)
        #expect(Day(validating: 2028, 2, 29) == Day(2028, 2, 29))
        #expect(Day(validating: 2026, 8, 5) == Day(2026, 8, 5))
        #expect(Day(validating: 2026, 12, 31) == Day(2026, 12, 31))
    }

    /// Why validation exists: the unchecked initialiser lets two different
    /// `Day` values agree on the instant they store, so a dedupe keyed on the
    /// stored date matches a row the app would never print.
    @Test("An impossible day would otherwise collide with a real one in storage")
    func impossibleDaysCollideInStorage() {
        let impossible = Day(2026, 2, 30)
        let real = Day(2026, 3, 2)
        #expect(impossible != real)
        #expect(impossible.startOfDayUTC == real.startOfDayUTC, "same row, two identities")
        #expect(Day(validating: 2026, 2, 30) == nil, "which is why it cannot be built from outside")
    }
}
