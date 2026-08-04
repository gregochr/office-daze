import Foundation

// Swift has no LocalDate. Foundation gives you `Date` (an instant, like
// java.time.Instant) and `DateComponents` (a loose bag of optional fields), but
// nothing in between. Trips start and end on *days* — no time, no zone — so we
// build the type.
//
// `nonisolated` appears on every type in Domain/. The project sets
// SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor, which makes types main-actor bound
// unless they say otherwise. That's right for UI and for SwiftData, and wrong
// for pure functions, which should be callable from anywhere — including a
// background parse in stage 4.

/// A calendar date with no time and no time zone.
nonisolated struct Day: Hashable, Comparable, Codable, Sendable, CustomStringConvertible {
    let year: Int
    let month: Int
    let day: Int

    init(_ year: Int, _ month: Int, _ day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    /// All day arithmetic runs through one fixed calendar. Not `Calendar.current`
    /// — that follows the device's locale and zone, and would make the same
    /// booking group differently depending on where the phone is.
    static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.firstWeekday = 2 // Monday, so "last Monday in August" is unambiguous
        return c
    }()

    /// The day an instant falls on, as seen from a given zone. The zone matters:
    /// the 20:05 arrival in Brussels is still Monday in London, but a 00:30
    /// arrival would not be.
    init(of instant: Date, in zone: TimeZone) {
        var c = Day.calendar
        c.timeZone = zone
        let parts = c.dateComponents([.year, .month, .day], from: instant)
        self.init(parts.year!, parts.month!, parts.day!)
    }

    /// Midnight UTC on this day. The canonical `Date` for storage — see Store/.
    var startOfDayUTC: Date {
        Day.calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    /// An instant on this day at a wall-clock time in a given zone.
    /// `Day(2026, 9, 7).at(17, 04, in: london)` is the Eurostar departure.
    func at(_ hour: Int, _ minute: Int, in zone: TimeZone) -> Date {
        var c = Day.calendar
        c.timeZone = zone
        return c.date(from: DateComponents(
            year: year, month: month, day: day, hour: hour, minute: minute
        ))!
    }

    /// 1 = Sunday … 7 = Saturday, matching Foundation.
    var weekday: Int {
        Day.calendar.component(.weekday, from: startOfDayUTC)
    }

    var isWeekend: Bool { weekday == 1 || weekday == 7 }
    var isWeekday: Bool { !isWeekend }

    var isMonday: Bool { weekday == 2 }

    func adding(days: Int) -> Day {
        let moved = Day.calendar.date(byAdding: .day, value: days, to: startOfDayUTC)!
        return Day(of: moved, in: Day.calendar.timeZone)
    }

    /// Days from this day to `other`, exclusive of this one.
    func days(until other: Day) -> Int {
        Day.calendar.dateComponents(
            [.day], from: startOfDayUTC, to: other.startOfDayUTC
        ).day!
    }

    var month_: Month { Month(year: year, month: month) }

    // `<` is all Comparable needs; Swift derives <=, >, >= from it. Tuples of
    // Comparable values compare lexicographically, which is exactly right here.
    static func < (a: Day, b: Day) -> Bool {
        (a.year, a.month, a.day) < (b.year, b.month, b.day)
    }

    /// ISO 8601, so debug output and test failures are readable.
    var description: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }
}

/// A year and a month. The quota is calculated per month, so it needs a type.
nonisolated struct Month: Hashable, Comparable, Codable, Sendable, CustomStringConvertible {
    let year: Int
    let month: Int

    init(year: Int, month: Int) {
        self.year = year
        self.month = month
    }

    var days: [Day] {
        let first = Day(year, month, 1)
        let range = Day.calendar.range(of: .day, in: .month, for: first.startOfDayUTC)!
        return range.map { Day(year, month, $0) }
    }

    var weekdays: [Day] { days.filter(\.isWeekday) }

    func contains(_ day: Day) -> Bool {
        day.year == year && day.month == month
    }

    static func < (a: Month, b: Month) -> Bool {
        (a.year, a.month) < (b.year, b.month)
    }

    var description: String { String(format: "%04d-%02d", year, month) }
}
