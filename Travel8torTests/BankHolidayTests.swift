import Testing
@testable import Travel8tor

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

    @Test("Every derived holiday falls on a weekday")
    func noneOnWeekends() {
        for year in 2024...2035 {
            for holiday in BankHolidays.englandAndWales(year: year) {
                #expect(holiday.isWeekday, "\(holiday) is a weekend")
            }
        }
    }
}
