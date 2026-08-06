import Foundation

// Swift has no LocalDate. Foundation gives you `Date` (an instant, like
// java.time.Instant) and `DateComponents` (a loose bag of optional fields), but
// nothing in between. A desk booking is for a *day* — no time, no zone — so we
// build the type.
//
// `nonisolated` appears on every type in Domain/. The project sets
// SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor, which makes types main-actor bound
// unless they say otherwise. That's right for UI and for SwiftData, and wrong
// for pure functions, which should be callable from anywhere.

/// A calendar date. There is no timezone handling in this app: a desk on the
/// 12th is a desk on the 12th, wherever the phone happens to be.
nonisolated struct Day: Hashable, Comparable, Codable, Sendable, CustomStringConvertible {
    let year: Int
    let month: Int
    let day: Int

    init(_ year: Int, _ month: Int, _ day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    /// All day arithmetic runs through one fixed calendar, not
    /// `Calendar.current` — that follows the device's locale and zone, and
    /// would make the same booking file under a different day abroad.
    static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.firstWeekday = 2 // Monday, so "last Monday in August" is unambiguous
        return c
    }()

    /// The day an instant falls on. Only used at the two edges — reading the
    /// clock, and reading a `Date` back out of SwiftData.
    init(of instant: Date) {
        let parts = Day.calendar.dateComponents([.year, .month, .day], from: instant)
        self.init(parts.year!, parts.month!, parts.day!)
    }

    /// Midnight UTC on this day. The canonical `Date` for storage — see Store/.
    var startOfDayUTC: Date {
        Day.calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    nonisolated static var today: Day { Day(of: .now) }

    /// 1 = Sunday … 7 = Saturday, matching Foundation.
    var weekday: Int {
        Day.calendar.component(.weekday, from: startOfDayUTC)
    }

    var isWeekend: Bool { weekday == 1 || weekday == 7 }
    var isWeekday: Bool { !isWeekend }
    var isMonday: Bool { weekday == 2 }

    func adding(days: Int) -> Day {
        Day(of: Day.calendar.date(byAdding: .day, value: days, to: startOfDayUTC)!)
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

    /// `Wednesday 5 August`, the booking detail's date line.
    var longText: String { formatted("EEEE d MMMM") }

    /// `Wed 5 August`, the bookings list.
    var mediumText: String { formatted("EEE d MMMM") }

    private func formatted(_ template: String) -> String {
        let f = DateFormatter()
        f.calendar = Day.calendar
        f.timeZone = Day.calendar.timeZone
        f.locale = Locale(identifier: "en_GB")
        f.dateFormat = template
        return f.string(from: startOfDayUTC)
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

    func adding(months: Int) -> Month {
        let moved = Day.calendar.date(
            byAdding: .month, value: months, to: Day(year, month, 1).startOfDayUTC
        )!
        let parts = Day.calendar.dateComponents([.year, .month], from: moved)
        return Month(year: parts.year!, month: parts.month!)
    }

    static func < (a: Month, b: Month) -> Bool {
        (a.year, a.month) < (b.year, b.month)
    }

    var description: String { String(format: "%04d-%02d", year, month) }

    /// `August 2026`, the month stepper.
    var text: String {
        let f = DateFormatter()
        f.calendar = Day.calendar
        f.timeZone = Day.calendar.timeZone
        f.locale = Locale(identifier: "en_GB")
        f.dateFormat = "MMMM yyyy"
        return f.string(from: Day(year, month, 1).startOfDayUTC)
    }
}
