import Testing
@testable import OfficeDaze

/// The leave grid's whole state machine, without the grid.
///
/// `LeaveCell` exists so these can be asked at all: on screen the difference
/// between a whole day off, a half day off and a day on prem is the fill of a
/// rounded rectangle, and no test can read a colour out of a SwiftUI view. What
/// each of these asserts is the sentence the cell would say and the write a tap
/// would make — which is also, not by accident, exactly what a VoiceOver user
/// hears.
@Suite("Leave grid cell")
struct LeaveScreenTests {

    // August 2026: the 5th is a Wednesday, the 8th a Saturday, and the 31st is
    // the summer bank holiday.
    let wednesday = Day(2026, 8, 5)
    let thursday = Day(2026, 8, 6)
    let saturday = Day(2026, 8, 8)
    let bankHoliday = Day(2026, 8, 31)

    /// Every cell in these tests knows the real August bank holiday, so a test
    /// that means "an ordinary working day" cannot accidentally get one.
    func cell(_ day: Day, fraction: Double? = nil, attended: Set<Day> = []) -> LeaveCell {
        LeaveCell(
            day: day,
            fraction: fraction,
            bankHolidays: [bankHoliday],
            attended: attended
        )
    }

    /// The regression. Book 5 August off in advance, then turn up — the
    /// geofence, the evening nudge or "Day in the office" writes an attendance
    /// row for the same day — and the cell went on being drawn in leave amber
    /// while refusing every tap, with the leave still lowering the month's
    /// target and no way to remove it from the screen that owns it.
    @Test("Leave booked first and attendance recorded second can still be cleared")
    func attendedDayKeepsItsClearPath() {
        let whole = cell(wednesday, fraction: 1, attended: [wednesday])
        #expect(whole.isEnabled)
        #expect(whole.tap == .clear)
        #expect(whole.accessibilityValue == "Whole day's leave, on prem")
        #expect(whole.accessibilityHint == "Double tap to clear the leave")

        // A half day is the same story: the cycle would take it to nothing
        // anyway, but it must not be the disabled path that gets there.
        let half = cell(wednesday, fraction: 0.5, attended: [wednesday])
        #expect(half.isEnabled)
        #expect(half.tap == .clear)
        #expect(half.accessibilityValue == "Half day's leave, on prem")
    }

    /// The negative half of the same rule, and the reason the guard exists at
    /// all: a day you were on prem for is history, and clearing leave off it
    /// must not turn into a way to book leave onto it.
    @Test("A day on prem with no leave on it still cannot be booked off")
    func attendedDayCannotBeBooked() {
        let attended = cell(wednesday, attended: [wednesday])
        #expect(!attended.isBookable)
        #expect(!attended.isEnabled)
        #expect(attended.tap == .inert)
        #expect(attended.accessibilityValue == "On prem")
        #expect(attended.accessibilityHint.isEmpty)
    }

    /// Stated for weekends and bank holidays too, not only for attended days.
    /// Leave can reach one of these — a row seeded or imported, or a day booked
    /// off before it was known to be a holiday — and when it does, the same
    /// trap would close in a different flavour.
    @Test("Leave stranded on a weekend or a bank holiday is clearable, and neither can be booked")
    func leaveOnDaysThatAreAlreadyOff() {
        #expect(cell(saturday, fraction: 1).tap == .clear)
        #expect(cell(saturday, fraction: 1).isEnabled)
        #expect(cell(bankHoliday, fraction: 0.5).tap == .clear)
        #expect(cell(bankHoliday, fraction: 0.5).isEnabled)

        // With nothing on them they stay inert — booking them off would deduct
        // the same day twice.
        #expect(cell(saturday).tap == .inert)
        #expect(cell(bankHoliday).tap == .inert)
        #expect(cell(saturday).accessibilityValue == "Weekend")
        #expect(cell(bankHoliday).accessibilityValue == "Bank holiday")
    }

    @Test("A working day cycles a whole day, then a half, then nothing")
    func theCycle() {
        #expect(cell(wednesday).tap == .book(1))
        #expect(cell(wednesday, fraction: 1).tap == .book(0.5))
        #expect(cell(wednesday, fraction: 0.5).tap == .clear)

        #expect(cell(wednesday).accessibilityHint == "Double tap to book the day off")
        #expect(cell(wednesday, fraction: 1).accessibilityHint == "Double tap to make it a half day")
    }

    /// The two rules are meant to be the same rule. `LeaveCycle.editable` is
    /// where the reasoning lives, and this holds the cell to it across a whole
    /// month rather than on the three days the other tests happen to pick.
    @Test("A booking is offered on exactly the days LeaveCycle calls editable")
    func bookableAgreesWithLeaveCycle() {
        let attended: Set<Day> = [thursday, saturday]
        let holidays: Set<Day> = [bankHoliday]
        for day in Month(year: 2026, month: 8).days {
            let subject = LeaveCell(
                day: day, fraction: nil, bankHolidays: holidays, attended: attended
            )
            let editable = LeaveCycle.editable(
                day: day, bankHolidays: holidays, attended: attended
            )
            #expect(subject.isBookable == editable, "\(day)")
            // And nothing else can produce a booking: an unbookable day is
            // inert or clears, never books.
            if case .book = subject.tap { #expect(editable, "\(day) booked while not editable") }
        }
    }

    /// The grid's states differed only by fill colour: amber, amber at half
    /// strength, green, grey. Two of those pairs are a coin flip for a
    /// colourblind user and all four are invisible to VoiceOver, so each state
    /// now carries a glyph and a sentence of its own.
    @Test("Whole leave, half leave and a day on prem are told apart without colour")
    func statesAreDistinguishableWithoutColour() {
        let whole = cell(wednesday, fraction: 1)
        let half = cell(wednesday, fraction: 0.5)
        let attended = cell(wednesday, attended: [wednesday])
        let free = cell(wednesday)

        #expect(whole.marker == "●")
        #expect(half.marker == "½")
        #expect(attended.marker == "✓")
        #expect(free.marker == nil)

        let spoken = [whole, half, attended, free].map(\.accessibilityValue)
        #expect(spoken == ["Whole day's leave", "Half day's leave", "On prem", "No leave"])
        #expect(Set(spoken).count == spoken.count)
    }

    /// A sighted user reads the month off the stepper above the grid. Someone
    /// swiping cell by cell has no header, so "5" alone would place the day in
    /// no month at all.
    @Test("Each cell names its own date, month included")
    func cellsCarryTheirMonth() {
        #expect(cell(wednesday).accessibilityLabel == "5 August")
        #expect(cell(bankHoliday).accessibilityLabel == "31 August")
    }
}

