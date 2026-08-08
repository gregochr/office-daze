import Foundation
import SwiftData
import SwiftUI
import Testing
import UIKit
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

/// What the screen derives from its rows, and how it lays them out.
///
/// The suite above is about one square. This one is about the other half of the
/// file: the three derivations the grid is drawn from, the arithmetic that
/// places the 1st under the right letter, the sentence under the target, and
/// the write a tap performs. All of it reachable without a screen, which is why
/// `LeaveScreen` hands these out as `static`s taking their rows as arguments.
@Suite("The leave grid's own arithmetic")
@MainActor
struct LeaveScreenDerivationTests {

    let container: ModelContainer
    let august = Month(year: 2026, month: 8)

    init() throws {
        container = try Store.makeInMemoryContainer()
    }

    var context: ModelContext { container.mainContext }

    @discardableResult
    func insertLeave(_ day: Day, _ fraction: Double = 1, kind: LeaveKind = .annual) -> LeaveDay {
        let row = LeaveDay(day: day, fraction: fraction, kind: kind)
        context.insert(row)
        return row
    }

    func leaveRows() throws -> [LeaveDay] {
        try context.fetch(FetchDescriptor<LeaveDay>())
    }

    // MARK: The three derivations

    /// Two attendance rows for one date collapse to one day — the grid draws a
    /// square per date, and a set is what says so. A neighbouring month's row
    /// must not tick a cell this month does not have.
    @Test("Attended days are this month's dates, each counted once")
    func attendedDaysAreDedupedAndScopedToTheMonth() {
        let fifth = Day(2026, 8, 5)
        let rows = [
            AttendanceDay(day: fifth, officeID: UUID(), source: .manual, fraction: 1),
            AttendanceDay(day: fifth, officeID: UUID(), source: .manual, fraction: 1),
            AttendanceDay(day: Day(2026, 8, 6), officeID: UUID(), source: .manual, fraction: 0.5),
            AttendanceDay(day: Day(2026, 7, 31), officeID: UUID(), source: .manual, fraction: 1),
            AttendanceDay(day: Day(2026, 9, 1), officeID: UUID(), source: .manual, fraction: 1),
        ]
        #expect(
            LeaveScreen.attendedDays(from: rows, in: august) == [fifth, Day(2026, 8, 6)],
            "one square per date, and only August's"
        )
        #expect(LeaveScreen.attendedDays(from: [], in: august).isEmpty)
    }

    /// Summed rather than overwritten, and bank-holiday rows kept out.
    ///
    /// The filter is not tidiness: `Quota` derives bank holidays itself and has
    /// already taken them out of the working days, so a `.bankHoliday` row
    /// reaching the fractions would deduct the same day a second time and drop
    /// the month's target below what the user is actually owed.
    @Test("Leave fractions sum per day, and bank-holiday rows are not leave")
    func fractionsSumAndExcludeBankHolidays() {
        let fifth = Day(2026, 8, 5)
        let rows = [
            LeaveDay(day: fifth, fraction: 0.5),
            LeaveDay(day: fifth, fraction: 0.5),
            LeaveDay(day: Day(2026, 8, 31), fraction: 1, kind: .bankHoliday),
            LeaveDay(day: Day(2026, 8, 12), fraction: 1, kind: .sick),
            LeaveDay(day: Day(2026, 7, 6), fraction: 1),
        ]
        let fractions = LeaveScreen.fractions(from: rows, in: august)

        #expect(fractions[fifth] == 1, "two halves are a whole, not the last one written")
        #expect(fractions[Day(2026, 8, 31)] == nil, "a bank holiday is not leave taken")
        #expect(fractions[Day(2026, 8, 12)] == 1, "sick leave is still leave")
        #expect(fractions[Day(2026, 7, 6)] == nil, "and July is not this grid")
        #expect(fractions.count == 2)
    }

    /// The target the card reports, from the rows the grid is holding — and the
    /// double-deduction the filter above exists to stop, asserted as a number.
    @Test("The target falls as leave is booked, and a bank holiday does not lower it twice")
    func resultReflectsTheLeaveOnTheGrid() {
        let none = LeaveScreen.result(
            month: august, fractions: [:], attendance: [], today: Day(2026, 8, 1)
        )
        #expect(none.target == 8, "the full month asks for eight")
        #expect(none.leaveTaken == 0)

        // Five days' leave is the first whole block, which takes two off.
        let week = Dictionary(
            uniqueKeysWithValues: (3...7).map { (Day(2026, 8, $0), 1.0) }
        )
        let after = LeaveScreen.result(
            month: august, fractions: week, attendance: [], today: Day(2026, 8, 1)
        )
        #expect(after.leaveTaken == 5)
        #expect(after.relief == 2)
        #expect(after.target == 6)

        // The bank holiday is already out of the working days, so passing it as
        // leave as well would show up here as a target lower again.
        let holiday = LeaveScreen.result(
            month: august, fractions: [Day(2026, 8, 31): 1],
            attendance: [], today: Day(2026, 8, 1)
        )
        #expect(
            holiday.workingDays == none.workingDays,
            "the working days already excluded it"
        )
    }

    // MARK: Laying the month out

    /// The 1st of a month lands under the letter its weekday names, and getting
    /// this wrong by one shifts every date in the grid under the wrong column —
    /// a calendar that still looks perfectly plausible, which is why it is
    /// worth an assertion rather than a glance.
    @Test("The first of the month is pushed along to its own weekday column")
    func leadingBlanksPlaceTheFirst() {
        // A month beginning on each day of the week, Monday first. Verified
        // against the real calendar rather than asserted from the formula, so
        // the test cannot restate the bug.
        let firsts: [(Day, Int)] = [
            (Day(2026, 6, 1), 0),  // Monday
            (Day(2026, 9, 1), 1),  // Tuesday
            (Day(2026, 7, 1), 2),  // Wednesday
            (Day(2026, 1, 1), 3),  // Thursday
            (Day(2026, 5, 1), 4),  // Friday
            (Day(2026, 8, 1), 5),  // Saturday
            (Day(2026, 2, 1), 6),  // Sunday
        ]
        for (first, expected) in firsts {
            #expect(
                LeaveScreen.leadingBlanks(before: first) == expected,
                "\(first) is a \(Day.calendar.weekdaySymbols[first.weekday - 1])"
            )
            #expect((0...6).contains(LeaveScreen.leadingBlanks(before: first)))
        }
    }

    /// Every date in a year lands in the column its own weekday owns — the
    /// blanks and the dates have to agree for the whole grid, not just the 1st.
    @Test("Across a whole year, no month starts in a column that is not its weekday")
    func leadingBlanksAgreeWithTheWeekdayAllYear() {
        for month in 1...12 {
            let first = Day(2026, month, 1)
            let blanks = LeaveScreen.leadingBlanks(before: first)
            // Column 0 is Monday, so the column index and Foundation's weekday
            // (1 = Sunday) must describe the same day.
            let mondayBased = (first.weekday + 5) % 7
            #expect(blanks == mondayBased)
            #expect(Day(2026, month, 1 + (7 - blanks) % 7).isMonday || blanks == 0)
        }
    }

    /// The two chevrons are the only way through the year, and the failure this
    /// pairing prevents is both of them announcing the same destination.
    @Test("The two month chevrons point opposite ways and say so differently")
    func theStepButtonsDiffer() {
        let back = LeaveScreen.step(months: -1)
        let forward = LeaveScreen.step(months: 1)

        #expect(back == ("chevron.left", "Previous month"))
        #expect(forward == ("chevron.right", "Next month"))
        #expect(back.symbol != forward.symbol)
        #expect(back.label != forward.label, "VoiceOver must not read the same words for both")
        #expect(!back.label.contains("chevron"), "a destination, not a shape")
        #expect(!forward.label.contains("chevron"))
        // Any step back is the back chevron, however far.
        #expect(LeaveScreen.step(months: -12) == back)
        #expect(LeaveScreen.step(months: 12) == forward)
        #expect(LeaveScreen.step(months: 0) == forward, "zero is not a step back")
    }

    /// Stepping back stops where the gauge stops, so the two screens agree on
    /// how far the history goes.
    @Test("Stepping back stops at the earliest month the store knows about")
    func stepBackStopsWithTheRecords() throws {
        // An empty store: the floor is this month, so there is nowhere back.
        #expect(
            LeaveScreen.canStepBack(from: Day.today.month_, in: context) == false,
            "an empty store has no history to step into"
        )
        #expect(
            LeaveScreen.canStepBack(from: Day.today.month_.adding(months: 1), in: context),
            "and next month can always come back to this one"
        )

        // A record two months back moves the floor to it.
        insertLeave(Day.today.month_.adding(months: -2).days[0])
        try context.save()
        #expect(LeaveScreen.canStepBack(from: Day.today.month_, in: context))
        #expect(
            LeaveScreen.canStepBack(from: Day.today.month_.adding(months: -2), in: context) == false,
            "and it stops on the month that record is in"
        )
    }

    // MARK: What the card says

    /// Three branches, and the middle one is the reason the sentence exists: a
    /// user with four days booked wants to know why the target is still 8, and
    /// "the first 2 come off at 5 days" is the answer.
    @Test("The explanation names the leave booked and the block it has not reached")
    func explanationCoversItsThreeBranches() {
        func sentence(leave: Double) -> String {
            LeaveScreen.explanation(LeaveScreen.result(
                month: august,
                fractions: leave == 0 ? [:] : [Day(2026, 8, 3): leave],
                attendance: [], today: Day(2026, 8, 1)
            ))
        }

        let noLeave = sentence(leave: 0)
        #expect(noLeave == "8 days a month, across 20 working days. Every 5 days' leave takes 2 off.")

        // Booked, but short of the first block: named, with the threshold.
        let short = LeaveScreen.explanation(LeaveScreen.result(
            month: august,
            fractions: Dictionary(uniqueKeysWithValues: (3...6).map { (Day(2026, 8, $0), 1.0) }),
            attendance: [], today: Day(2026, 8, 1)
        ))
        #expect(short.contains("4 days' leave booked so far"))
        #expect(short.contains("the first 2 come off at 5 days"))

        // Past the block: the relief is stated as a subtraction.
        let relieved = LeaveScreen.explanation(LeaveScreen.result(
            month: august,
            fractions: Dictionary(uniqueKeysWithValues: (3...7).map { (Day(2026, 8, $0), 1.0) }),
            attendance: [], today: Day(2026, 8, 1)
        ))
        #expect(relieved == "8 days a month less 2 for 5 days' leave, across 20 working days.")

        #expect(Set([noLeave, short, relieved]).count == 3, "three branches, three sentences")
    }

    /// A day's leave, not a days' leave. The apostrophe moves, and a half day
    /// takes the plural because "0.5 day's" is not English either way round.
    @Test("One day's leave reads as one day's, and a half as half")
    func explanationGetsItsApostropheRight() {
        func sentence(_ leave: Double) -> String {
            LeaveScreen.explanation(LeaveScreen.result(
                month: august, fractions: [Day(2026, 8, 3): leave],
                attendance: [], today: Day(2026, 8, 1)
            ))
        }
        #expect(sentence(1).contains("1 day's leave"))
        #expect(sentence(2).contains("2 days' leave"))
        #expect(sentence(0.5).contains("0.5 days' leave"))
    }

    /// Whole days lose the trailing zero and halves keep their digit, in one
    /// sentence that has to hold both.
    @Test("Leave counts print as 2 and 2.5, never 2.0")
    func numberDropsTheZeroButKeepsTheHalf() {
        #expect(LeaveScreen.number(2) == "2")
        #expect(LeaveScreen.number(2.5) == "2.5")
        #expect(LeaveScreen.number(0) == "0")
        #expect(LeaveScreen.number(0.5) == "0.5")
        #expect(LeaveScreen.number(10) == "10")
        // Not "2.50" — one fraction digit at most, and none when it is whole.
        #expect(!LeaveScreen.number(2).contains("."))
    }

    // MARK: The colours, which only repeat what the words already say

    /// Leave wins over the ground in both channels. A day booked off and later
    /// attended is drawn as leave, because leave is what the tap acts on and
    /// drawing it green would say the cell does nothing — which is the bug the
    /// suite above exists for, in its visual half.
    @Test("Leave is painted over whatever the day underneath it was")
    func leaveOutranksItsGround() {
        let day = Day(2026, 8, 5)
        let holidays: Set<Day> = [Day(2026, 8, 31)]
        func cell(fraction: Double?, attended: Set<Day> = []) -> LeaveCell {
            LeaveCell(day: day, fraction: fraction, bankHolidays: holidays, attended: attended)
        }

        #expect(LeaveScreen.foreground(cell(fraction: 1)) == Palette.warningText)
        #expect(
            LeaveScreen.foreground(cell(fraction: 1, attended: [day])) == Palette.warningText,
            "attended underneath, still drawn as the leave the tap will clear"
        )
        #expect(LeaveScreen.foreground(cell(fraction: nil, attended: [day])) == Palette.successText)
        #expect(LeaveScreen.foreground(cell(fraction: nil)) == Palette.text)

        let weekend = LeaveCell(
            day: Day(2026, 8, 8), fraction: nil, bankHolidays: holidays, attended: []
        )
        let holiday = LeaveCell(
            day: Day(2026, 8, 31), fraction: nil, bankHolidays: holidays, attended: []
        )
        #expect(LeaveScreen.foreground(weekend) == Palette.tertiary)
        #expect(LeaveScreen.foreground(holiday) == Palette.tertiary)
    }

    /// A half day is the same amber at half strength — the same thing, less of
    /// it. That is the decorative half of the signal; the "½" marker asserted
    /// in the suite above is the half that survives without colour.
    @Test("A half day is the whole day's colour at half strength")
    func backgroundsFollowTheState() {
        let day = Day(2026, 8, 5)
        let holidays: Set<Day> = [Day(2026, 8, 31)]
        func cell(_ d: Day, fraction: Double? = nil, attended: Set<Day> = []) -> LeaveCell {
            LeaveCell(day: d, fraction: fraction, bankHolidays: holidays, attended: attended)
        }

        // Compared against `.opacity(1)` rather than the bare colour: SwiftUI's
        // `Color` equality keeps the modifier, so a full-strength amber built
        // through `.opacity(1)` is `100% #FFF8E8FF` and does not equal
        // `#FFF8E8FF`. They render identically; only `==` can tell them apart.
        #expect(
            LeaveScreen.background(cell(day, fraction: 1)) == Palette.warningSurface.opacity(1)
        )
        #expect(
            LeaveScreen.background(cell(day, fraction: 0.5))
                == Palette.warningSurface.opacity(0.5)
        )
        #expect(
            LeaveScreen.background(cell(day, fraction: 1))
                != LeaveScreen.background(cell(day, fraction: 0.5)),
            "the two are told apart by more than the marker"
        )
        #expect(
            LeaveScreen.background(cell(day, attended: [day])) == Palette.successSurface
        )
        #expect(LeaveScreen.background(cell(day)) == .clear, "a free working day is unpainted")
        #expect(
            LeaveScreen.background(cell(Day(2026, 8, 8))) == Palette.hairline.opacity(0.6)
        )
        #expect(
            LeaveScreen.background(cell(Day(2026, 8, 31))) == Palette.hairline.opacity(0.6)
        )
    }

    // MARK: What a tap writes

    @Test("Booking a day off writes one annual row for it")
    func tappingAFreeDayBooksIt() throws {
        let day = Day(2026, 8, 5)
        let cell = LeaveCell(day: day, fraction: nil, bankHolidays: [], attended: [])
        #expect(cell.tap == .book(1))

        LeaveScreen.toggle(cell, leave: try leaveRows(), in: context)

        let rows = try leaveRows()
        #expect(rows.count == 1)
        #expect(rows[0].day == day)
        #expect(rows[0].fraction == 1)
        #expect(rows[0].kind == .annual)
    }

    @Test("Tapping a booked day makes it a half, and tapping again clears it")
    func theCycleIsWrittenThrough() throws {
        let day = Day(2026, 8, 5)
        func cellNow() throws -> LeaveCell {
            LeaveCell(
                day: day,
                fraction: LeaveScreen.fractions(from: try leaveRows(), in: august)[day],
                bankHolidays: [], attended: []
            )
        }

        LeaveScreen.toggle(try cellNow(), leave: try leaveRows(), in: context)
        #expect(try leaveRows().map(\.fraction) == [1])

        LeaveScreen.toggle(try cellNow(), leave: try leaveRows(), in: context)
        #expect(try leaveRows().map(\.fraction) == [0.5], "one row replaced, not two rows held")

        LeaveScreen.toggle(try cellNow(), leave: try leaveRows(), in: context)
        #expect(try leaveRows().isEmpty, "and back to nothing")
    }

    /// The negative that matters most: a bank-holiday row is not the user's
    /// leave and a tap must not delete it. It is how `Quota` knows the day is
    /// already off, and losing it would quietly raise the month's target.
    @Test("Clearing leave off a day leaves that day's bank-holiday row alone")
    func toggleDoesNotTouchBankHolidayRows() throws {
        let day = Day(2026, 8, 31)
        insertLeave(day, 1, kind: .bankHoliday)
        insertLeave(day, 0.5, kind: .annual)
        try context.save()

        let cell = LeaveCell(day: day, fraction: 0.5, bankHolidays: [day], attended: [])
        #expect(cell.tap == .clear)
        LeaveScreen.toggle(cell, leave: try leaveRows(), in: context)

        let rows = try leaveRows()
        #expect(rows.count == 1)
        #expect(rows[0].kind == .bankHoliday, "the day is still known to be a holiday")
        #expect(LeaveScreen.fractions(from: rows, in: august)[day] == nil, "and holds no leave")
    }

    /// A day that somehow carries two rows collapses to one on the next tap,
    /// rather than leaving a stray behind that keeps counting.
    @Test("A day holding two leave rows is replaced by one, not added to")
    func duplicateRowsCollapse() throws {
        let day = Day(2026, 8, 5)
        insertLeave(day, 0.5)
        insertLeave(day, 0.5)
        try context.save()
        #expect(try leaveRows().count == 2)

        // Two halves read as a whole day, so the cycle offers the half.
        let cell = LeaveCell(day: day, fraction: 1, bankHolidays: [], attended: [])
        #expect(cell.tap == .book(0.5))
        LeaveScreen.toggle(cell, leave: try leaveRows(), in: context)

        #expect(try leaveRows().map(\.fraction) == [0.5], "one row, at what the cell offered")
    }

    /// An inert tap writes nothing at all. The cell already refuses these, but
    /// the write is what would actually deduct the day, so it is asserted here
    /// too rather than trusted to the button's `disabled`.
    @Test("A tap the cell calls inert changes no row")
    func anInertTapWritesNothing() throws {
        let saturday = Day(2026, 8, 8)
        let cell = LeaveCell(day: saturday, fraction: nil, bankHolidays: [], attended: [])
        #expect(cell.tap == .inert)

        LeaveScreen.toggle(cell, leave: try leaveRows(), in: context)
        #expect(try leaveRows().isEmpty, "a weekend cannot be booked off")
    }

    // MARK: The screen itself

    /// The body, run for real over a store with something in it.
    ///
    /// Nothing is asserted about what it drew, and that is deliberate rather
    /// than lazy: on iOS 26 a rendered SwiftUI view is a display list with no
    /// UIViews and, without VoiceOver running, no accessibility tree — so there
    /// is nothing here a test could truthfully read. What this proves is what
    /// only a render can prove: that `body` and every branch it reaches build
    /// and execute over real rows. A `ForEach` whose identity breaks, a
    /// `LazyVGrid` handed a negative blank count, a `Card` whose insets stop
    /// compiling against the design system — those fail here and nowhere else.
    /// Every *answer* the screen gives is asserted above, without a screen.
    @Test("The screen builds over a month with leave, attendance and a bank holiday in it")
    func theScreenDraws() async throws {
        let container = try Store.makeInMemoryContainer(seeded: true)
        let context = container.mainContext
        context.insert(LeaveDay(day: Day(2026, 8, 3), fraction: 1))
        context.insert(LeaveDay(day: Day(2026, 8, 4), fraction: 0.5))
        context.insert(LeaveDay(day: Day(2026, 8, 31), fraction: 1, kind: .bankHoliday))
        context.insert(AttendanceDay(day: Day(2026, 8, 5), officeID: SeedData.colemanID, source: .manual, fraction: 1))
        try context.save()

        let before = try context.fetchCount(FetchDescriptor<LeaveDay>())

        let host = UIHostingController(
            rootView: NavigationStack { LeaveScreen(month: Month(year: 2026, month: 8)) }
                .modelContainer(container)
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.rootViewController = host
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        ArrivalPreviewRenderTests.dismantle(window, holding: container)

        #expect(
            try context.fetchCount(FetchDescriptor<LeaveDay>()) == before,
            "drawing the grid books nobody's holiday"
        )
    }

    /// The other month the grid has to survive: nothing booked, nothing
    /// attended, and a first that falls on a Sunday so the row of blanks is at
    /// its longest.
    @Test("The screen builds for an empty month whose first is a Sunday")
    func theScreenDrawsAnEmptyMonth() async throws {
        let container = try Store.makeInMemoryContainer()
        #expect(LeaveScreen.leadingBlanks(before: Day(2026, 2, 1)) == 6, "the widest gap there is")

        let host = UIHostingController(
            rootView: NavigationStack { LeaveScreen(month: Month(year: 2026, month: 2)) }
                .modelContainer(container)
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.rootViewController = host
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        ArrivalPreviewRenderTests.dismantle(window, holding: container)

        #expect(try container.mainContext.fetchCount(FetchDescriptor<LeaveDay>()) == 0)
    }
}

