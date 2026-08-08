import Foundation

/// England & Wales bank holidays, derived rather than seeded.
///
/// The data-model document says bank holidays are "seeded, not entered —
/// refreshed yearly". Eight of the nine are pure functions of the year, so we
/// derive them and keep a table for the ones that aren't: royal holidays like
/// the 2022 Jubilee and the 2023 Coronation, and the years a derived holiday
/// was moved off its usual Monday, neither of which any algorithm predicts.
/// That table is the only thing needing a yearly look.
///
/// Scotland and Northern Ireland differ. This is England & Wales only, as
/// specified.
nonisolated enum BankHolidays {

    /// What a year does that the algorithm cannot know: days the government
    /// added, and days it took away.
    ///
    /// `removed` is not symmetry for its own sake. Both adjustments the UK has
    /// actually made in living memory were *moves*, not additions — the 2020
    /// Early May holiday shifted from Monday the 4th to Friday the 8th for VE
    /// Day 75, and the 2022 Spring holiday shifted from Monday 30 May to
    /// Thursday 2 June for the Platinum Jubilee. A table that can only union
    /// cannot say either of those. It leaves the derived day standing beside
    /// the announced one, so the month carries one bank holiday too many and
    /// `Quota.calculate` hands the user a target a day too generous — the
    /// pleasant kind of wrong, which is the kind nobody reports.
    nonisolated struct Adjustment: Sendable {
        var added: [Day] = []
        var removed: [Day] = []
    }

    /// Keyed by year. Add to this when the government announces one; everything
    /// else derives. A *move* is one entry with both halves filled in.
    static let exceptional: [Int: Adjustment] = [
        // VE Day 75: the Early May holiday moved from Monday 4 May.
        2020: Adjustment(added: [Day(2020, 5, 8)], removed: [Day(2020, 5, 4)]),
        // Platinum Jubilee: Spring moved from Monday 30 May to Thursday 2 June,
        // with Friday 3 June added beside it. September's is the State Funeral.
        2022: Adjustment(
            added: [Day(2022, 6, 2), Day(2022, 6, 3), Day(2022, 9, 19)],
            removed: [Day(2022, 5, 30)]
        ),
        // The Coronation, genuinely an addition — nothing moved for it.
        2023: Adjustment(added: [Day(2023, 5, 8)]),
    ]

    /// All England & Wales bank holidays in a year, sorted.
    static func englandAndWales(year: Int) -> [Day] {
        var holidays: [Day] = []

        // Fixed-date holidays get substituted forward when they land on a
        // weekend. Order matters: Christmas Day is placed before Boxing Day so
        // that a Saturday Christmas pushes Boxing Day past its substitute.
        var placed: Set<Day> = []
        func placeFixed(_ day: Day) {
            var candidate = day
            while candidate.isWeekend || placed.contains(candidate) {
                candidate = candidate.adding(days: 1)
            }
            placed.insert(candidate)
            holidays.append(candidate)
        }

        placeFixed(Day(year, 1, 1))       // New Year's Day

        let easterSunday = easter(year: year)
        holidays.append(easterSunday.adding(days: -2))  // Good Friday
        holidays.append(easterSunday.adding(days: 1))   // Easter Monday

        holidays.append(firstMonday(year: year, month: 5))  // Early May
        holidays.append(lastMonday(year: year, month: 5))   // Spring
        holidays.append(lastMonday(year: year, month: 8))   // Summer

        placeFixed(Day(year, 12, 25))     // Christmas Day
        placeFixed(Day(year, 12, 26))     // Boxing Day

        // Subtract before adding, so a move whose announced date happens to
        // collide with a derived one still ends up present rather than
        // cancelled out.
        let adjustment = exceptional[year] ?? Adjustment()
        return Set(holidays)
            .subtracting(adjustment.removed)
            .union(adjustment.added)
            .sorted()
    }

    /// The ones that fall in a given month, on a weekday. A bank holiday on a
    /// weekend has already been substituted forward by the time it gets here,
    /// so this filter is belt and braces.
    static func englandAndWales(in month: Month) -> [Day] {
        englandAndWales(year: month.year)
            .filter { month.contains($0) && $0.isWeekday }
    }

    /// Easter Sunday, by the anonymous Gregorian computus. This is the one piece
    /// of genuinely non-obvious arithmetic in the app; it is 1800 years of
    /// ecclesiastical argument compressed into fifteen lines, and it is correct.
    static func easter(year: Int) -> Day {
        let a = year % 19
        let b = year / 100
        let c = year % 100
        let d = b / 4
        let e = b % 4
        let f = (b + 8) / 25
        let g = (b - f + 1) / 3
        let h = (19 * a + b - d - g + 15) % 30
        let i = c / 4
        let k = c % 4
        let l = (32 + 2 * e + 2 * i - h - k) % 7
        let m = (a + 11 * h + 22 * l) / 451
        let month = (h + l - 7 * m + 114) / 31
        let day = ((h + l - 7 * m + 114) % 31) + 1
        return Day(year, month, day)
    }

    static func firstMonday(year: Int, month: Int) -> Day {
        Month(year: year, month: month).days.first(where: \.isMonday)!
    }

    static func lastMonday(year: Int, month: Int) -> Day {
        Month(year: year, month: month).days.last(where: \.isMonday)!
    }
}
