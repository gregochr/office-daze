import Testing
@testable import OfficeDaze

// Swift Testing, not XCTest — `#expect` instead of XCTAssertEqual, and it
// reports the actual values on failure without being told to.

@Suite("Bank holidays, England & Wales")
struct BankHolidayTests {

    @Test("Easter is computed, not tabulated")
    func easterDates() {
        // Spot dates across the Gregorian cycle, each verifiable against a
        // calendar.
        #expect(BankHolidays.easter(year: 2024) == Day(2024, 3, 31))
        #expect(BankHolidays.easter(year: 2025) == Day(2025, 4, 20))
        #expect(BankHolidays.easter(year: 2026) == Day(2026, 4, 5))
        #expect(BankHolidays.easter(year: 2027) == Day(2027, 3, 28))
        #expect(BankHolidays.easter(year: 2038) == Day(2038, 4, 25)) // latest possible
    }

    @Test("The August 2026 bank holiday is the 31st")
    func summer2026() {
        let august = Month(year: 2026, month: 8)
        #expect(BankHolidays.englandAndWales(in: august) == [Day(2026, 8, 31)])
        #expect(Day(2026, 8, 31).isMonday)
    }

    @Test("2026 has the eight standard holidays")
    func fullYear2026() {
        let expected = [
            Day(2026, 1, 1),   // New Year's Day, a Thursday
            Day(2026, 4, 3),   // Good Friday
            Day(2026, 4, 6),   // Easter Monday
            Day(2026, 5, 4),   // Early May
            Day(2026, 5, 25),  // Spring
            Day(2026, 8, 31),  // Summer
            Day(2026, 12, 25), // Christmas, a Friday
            Day(2026, 12, 28), // Boxing Day is Saturday, substituted to Monday
        ]
        #expect(BankHolidays.englandAndWales(year: 2026) == expected)
    }

    @Test("Weekend Christmas substitutes forward without collision")
    func christmasSubstitution() {
        // 2027: Christmas Day is a Saturday, Boxing Day a Sunday. The two
        // substitutes must land on Monday 27th and Tuesday 28th, not both on
        // the Monday.
        let y2027 = BankHolidays.englandAndWales(year: 2027)
        #expect(y2027.contains(Day(2027, 12, 27)))
        #expect(y2027.contains(Day(2027, 12, 28)))

        // 2022: Christmas Day was a Sunday, Boxing Day the Monday. Boxing Day
        // stands; Christmas moves to Tuesday the 27th.
        let y2022 = BankHolidays.englandAndWales(year: 2022)
        #expect(y2022.contains(Day(2022, 12, 26)))
        #expect(y2022.contains(Day(2022, 12, 27)))
    }

    @Test("New Year's Day on a Saturday moves to the Monday")
    func newYearSubstitution() {
        // 1 January 2028 is a Saturday.
        #expect(BankHolidays.englandAndWales(year: 2028).contains(Day(2028, 1, 3)))
        #expect(!BankHolidays.englandAndWales(year: 2028).contains(Day(2028, 1, 1)))
    }

    @Test("One-off royal holidays come from the table, not the algorithm")
    func exceptionalDays() {
        let y2022 = BankHolidays.englandAndWales(year: 2022)
        #expect(y2022.contains(Day(2022, 6, 3)))  // Platinum Jubilee
        #expect(y2022.contains(Day(2022, 9, 19))) // State Funeral
        #expect(BankHolidays.englandAndWales(year: 2023).contains(Day(2023, 5, 8)))
    }

    // The two years the government moved a holiday rather than adding one.
    // They are here as whole-year assertions rather than spot checks because
    // the failure they guard against is an *extra* day, and only a full-year
    // comparison notices a day that should not be there.

    @Test("The 2022 Spring bank holiday is 2 June, and 30 May is not a holiday at all")
    func platinumJubilee2022() {
        let expected = [
            Day(2022, 1, 3),   // New Year's Day is a Saturday, substituted
            Day(2022, 4, 15),  // Good Friday
            Day(2022, 4, 18),  // Easter Monday
            Day(2022, 5, 2),   // Early May
            Day(2022, 6, 2),   // Spring, moved from 30 May for the Jubilee
            Day(2022, 6, 3),   // The extra Jubilee day
            Day(2022, 8, 29),  // Summer
            Day(2022, 9, 19),  // State Funeral
            Day(2022, 12, 26), // Boxing Day, a Monday, stands
            Day(2022, 12, 27), // Christmas Day is a Sunday, substituted past it
        ]
        #expect(BankHolidays.englandAndWales(year: 2022) == expected)

        // The negative half, said out loud: the derived last-Monday-in-May is
        // suppressed, not merely outvoted by the additions.
        #expect(!BankHolidays.englandAndWales(year: 2022).contains(Day(2022, 5, 30)))
        #expect(Day(2022, 5, 30).isMonday, "so the algorithm really would derive it")
    }

    @Test("The 2020 Early May bank holiday is Friday 8 May, not Monday the 4th")
    func veDay2020() {
        let may = Month(year: 2020, month: 5)
        #expect(BankHolidays.englandAndWales(in: may) == [Day(2020, 5, 8), Day(2020, 5, 25)])
        #expect(!BankHolidays.englandAndWales(year: 2020).contains(Day(2020, 5, 4)))
        #expect(Day(2020, 5, 4).isMonday, "so the algorithm really would derive it")
    }

    @Test("A moved holiday leaves the month's working-day count intact")
    func aMoveDoesNotInflateTheMonth() {
        // This is the reason the removal matters. Before `removed` existed,
        // May 2022 carried two bank holidays and June carried one; the truth is
        // one and two, and each month's quota target follows directly from it.
        #expect(BankHolidays.englandAndWales(in: Month(year: 2022, month: 5)) == [Day(2022, 5, 2)])
        #expect(
            BankHolidays.englandAndWales(in: Month(year: 2022, month: 6))
                == [Day(2022, 6, 2), Day(2022, 6, 3)]
        )
        // Spelt out as the counts the quota is built from — May 2022 has 22
        // weekdays and one bank holiday, so 21 working days, and June has 22
        // and two, so 20. The union-only table gave 20 and 21.
        let may = Month(year: 2022, month: 5)
        let june = Month(year: 2022, month: 6)
        #expect(may.weekdays.count - BankHolidays.englandAndWales(in: may).count == 21)
        #expect(june.weekdays.count - BankHolidays.englandAndWales(in: june).count == 20)
    }

    @Test("A year with no entry in the table is untouched by it")
    func unadjustedYear() {
        // The lookup falls back to an empty Adjustment rather than to nil-with-
        // consequences; 2021 needed nothing and must get nothing.
        #expect(BankHolidays.exceptional[2021] == nil)
        #expect(BankHolidays.englandAndWales(year: 2021) == [
            Day(2021, 1, 1),
            Day(2021, 4, 2),
            Day(2021, 4, 5),
            Day(2021, 5, 3),
            Day(2021, 5, 31),
            Day(2021, 8, 30),
            Day(2021, 12, 27), // Christmas Day is a Saturday
            Day(2021, 12, 28), // Boxing Day is pushed past the substitute
        ])
    }

    @Test("Every derived holiday falls on a weekday")
    func noneOnWeekends() {
        for year in 2020...2035 {
            for holiday in BankHolidays.englandAndWales(year: year) {
                #expect(holiday.isWeekday, "\(holiday) is a weekend")
            }
        }
    }
}
