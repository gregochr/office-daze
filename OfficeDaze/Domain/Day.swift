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

    /// The day a *stored* instant falls on. This is one half of the storage
    /// codec, and it is paired with `startOfDayUTC`: what that writes, this
    /// reads back. It is not the right way to ask what day an arbitrary
    /// instant fell on for a person — use `init(localOf:)` for that.
    init(of instant: Date) {
        let parts = Day.calendar.dateComponents([.year, .month, .day], from: instant)
        self.init(parts.year!, parts.month!, parts.day!)
    }

    /// Midnight UTC on this day. The canonical `Date` for storage — see Store/.
    ///
    /// Storage only. Handing this to a `DatePicker`, an `EKEvent` or a
    /// `UNCalendarNotificationTrigger` is a bug: those render in the device's
    /// zone, where midnight UTC on the 5th is the evening of the 4th anywhere
    /// west of Greenwich. `localNoon(in:)` is the bridge to a local API.
    var startOfDayUTC: Date {
        Day.calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    // MARK: The local bridges
    //
    // `Day` is deliberately timezone-free, but three things it has to meet are
    // not: the clock, a `DatePicker`, and a stored instant shown to a person.
    // Those three run through the calls below rather than through the UTC
    // calendar above, so that "today" is the day it is where the phone is.
    //
    // Each takes an explicit zone defaulting to the device's, so a test can
    // pin one instead of inheriting whatever zone the simulator happens to be
    // in — which is what let the off-by-one live here undetected.

    /// The device's calendar. `autoupdatingCurrent` rather than a snapshot, so
    /// a phone carried across a zone boundary re-reads it rather than holding
    /// the zone it launched in.
    static func localCalendar(_ zone: TimeZone = .autoupdatingCurrent) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = zone
        c.firstWeekday = 2
        return c
    }

    /// The day an instant fell on *where the phone is* — which is what a
    /// person means by the day something happened.
    init(localOf instant: Date, in zone: TimeZone = .autoupdatingCurrent) {
        let parts = Day.localCalendar(zone)
            .dateComponents([.year, .month, .day], from: instant)
        self.init(parts.year!, parts.month!, parts.day!)
    }

    /// The `Date` to hand a `DatePicker`, which renders in the device's zone.
    ///
    /// Midday rather than midnight: on a spring-forward day some zones have no
    /// 00:00 at all, and `date(from:)` would answer with the next hour that
    /// exists — an hour is harmless at noon and a date change at midnight.
    func localNoon(in zone: TimeZone = .autoupdatingCurrent) -> Date {
        Day.localCalendar(zone).date(from: DateComponents(
            year: year, month: month, day: day, hour: 12
        ))!
    }

    nonisolated static var today: Day { Day(localOf: .now) }

    /// A day that exists. `init(_:_:_:)` takes the three numbers on trust,
    /// because every one of its callers is a literal or arithmetic that cannot
    /// be wrong; this is for the one place numbers arrive from outside — a
    /// date read off a screenshot by a model.
    ///
    /// Without it, `Day(2026, 2, 30)` is constructible, `==` says it differs
    /// from `Day(2026, 3, 2)`, and `startOfDayUTC` rolls it forward so both
    /// store the same instant. Two Days, one row: the one-desk-per-day rule
    /// then dedupes against a date the app never displays.
    init?(validating year: Int, _ month: Int, _ day: Int) {
        let parts = DateComponents(year: year, month: month, day: day)
        guard parts.isValidDate(in: Day.calendar) else { return nil }
        self.init(year, month, day)
    }

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

    /// `5 August`, the gauge's date line — where the weekday is beside a count
    /// of working days and would read as part of it.
    var dayAndMonth: String { formatted("d MMMM") }

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
