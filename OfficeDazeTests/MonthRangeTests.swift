import Testing
@testable import OfficeDaze

/// Stepping back past your first record only ever shows an empty month under an
/// empty gauge, so the back chevron stops. Forward does not, because a month
/// with nothing in it yet is how you arrive at a month you are about to fill.
@Suite("Month range")
struct MonthRangeTests {

    let august = Month(year: 2026, month: 8)
    let today = Day(2026, 8, 6)

    @Test("An empty store cannot step back at all")
    func emptyStore() {
        #expect(MonthRange.earliest(recorded: [Day](), today: today) == august)
        #expect(!MonthRange.canStepBack(from: august, recorded: [Day](), today: today))
    }

    /// The seeded install, which is what a first launch actually looks like:
    /// the sample month is the month you are in, so there is nowhere behind it.
    @Test("The sample month is the floor when it is also this month")
    func seededInstall() {
        let seeded = [Day(2026, 8, 3), Day(2026, 8, 4), Day(2026, 8, 17)]
        #expect(MonthRange.earliest(recorded: seeded, today: today) == august)
        #expect(!MonthRange.canStepBack(from: august, recorded: seeded, today: today))
    }

    @Test("History opens the door as far back as it goes")
    func earlierRecords() {
        let recorded = [Day(2026, 6, 15), Day(2026, 8, 3)]
        #expect(MonthRange.earliest(recorded: recorded, today: today) == Month(year: 2026, month: 6))

        // Every month from the record back to the floor is reachable; the one
        // before it is not.
        #expect(MonthRange.canStepBack(from: august, recorded: recorded, today: today))
        #expect(MonthRange.canStepBack(from: Month(year: 2026, month: 7), recorded: recorded, today: today))
        #expect(!MonthRange.canStepBack(from: Month(year: 2026, month: 6), recorded: recorded, today: today))
    }

    /// Today is a floor, not the answer. A booking made for next month must not
    /// drag the floor forward and strand you above the month you are standing
    /// in — which is what taking the earliest record alone would do.
    @Test("A record ahead of today does not raise the floor")
    func onlyFutureRecords() {
        let ahead = [Day(2026, 11, 2)]
        #expect(MonthRange.earliest(recorded: ahead, today: today) == august)
        #expect(!MonthRange.canStepBack(from: august, recorded: ahead, today: today))
        #expect(MonthRange.canStepBack(from: Month(year: 2026, month: 9), recorded: ahead, today: today))
    }

    @Test("The floor crosses a year boundary")
    func acrossNewYear() {
        let recorded = [Day(2025, 12, 1)]
        let january = Day(2026, 1, 5)
        #expect(MonthRange.earliest(recorded: recorded, today: january) == Month(year: 2025, month: 12))
        #expect(MonthRange.canStepBack(from: Month(year: 2026, month: 1), recorded: recorded, today: january))
        #expect(!MonthRange.canStepBack(from: Month(year: 2025, month: 12), recorded: recorded, today: january))
    }

    /// Nothing stops the right-hand chevron. Stated as a test because the
    /// asymmetry is deliberate and the obvious "fix" is to make it symmetrical.
    @Test("Forward has no floor to hit")
    func forwardIsOpen() {
        let recorded = [Day(2026, 8, 3)]
        // Far enough ahead that any symmetrical bound would have caught it.
        #expect(MonthRange.canStepBack(from: Month(year: 2030, month: 4), recorded: recorded, today: today))
    }
}
