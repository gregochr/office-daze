import Testing
@testable import Travel8tor

@Suite("Quota")
struct QuotaTests {

    let august = Month(year: 2026, month: 8)

    /// The design's worked example, reproduced line for line from the
    /// TARGET DERIVATION panel and the gauge.
    @Test("August 2026, as the mock shows it")
    func augustWorkedExample() {
        let result = Quota.calculate(.init(
            month: august,
            leave: [
                .init(Day(2026, 8, 17)),
                .init(Day(2026, 8, 18)),
                .init(Day(2026, 8, 19)),
            ],
            attendance: [
                .init(Day(2026, 8, 3)),
                .init(Day(2026, 8, 4)),
            ],
            deskBookingDays: [Day(2026, 8, 5), Day(2026, 8, 6)],
            today: Day(2026, 8, 4)
        ))

        // WORKING DAYS 20 — 21 weekdays less the 31st.
        #expect(result.bankHolidays == [Day(2026, 8, 31)])
        #expect(result.workingDays == 20)

        // LEAVE 17–19  −03
        #expect(result.leaveTaken == 3)
        #expect(result.eligible == 17)

        // 8 × 17 ÷ 20 = 6.8 → TARGET 07
        #expect(result.target == 7)

        // The gauge: TERMINATED 02, FORECAST 02, centre reads 04.
        #expect(result.attended == 2)
        #expect(result.forecast == 2)
        #expect(result.attended + result.forecast == 4)

        // The footer: 03 LEFT ALIVE, 18 DAYS TO RUN.
        #expect(result.shortfall == 3)
        #expect(result.daysToRun == 18)
    }

    @Test("No leave means the full target")
    func noLeave() {
        let result = Quota.calculate(.init(month: august, today: Day(2026, 8, 1)))
        #expect(result.eligible == 20)
        #expect(result.target == 8)
        #expect(result.shortfall == 8)
    }

    @Test("Half-days are half a day")
    func halfDays() {
        let result = Quota.calculate(.init(
            month: august,
            leave: [.init(Day(2026, 8, 17), 0.5)],
            attendance: [.init(Day(2026, 8, 3), 0.5)],
            today: Day(2026, 8, 4)
        ))
        #expect(result.leaveTaken == 0.5)
        #expect(result.eligible == 19.5)
        #expect(result.target == 8)      // 8 × 19.5 ÷ 20 = 7.8, rounds to 8
        #expect(result.attended == 0.5)
        #expect(result.shortfall == 7.5)
    }

    @Test("Leave on a non-working day does not lower the target")
    func leaveOnBankHolidayOrWeekend() {
        let result = Quota.calculate(.init(
            month: august,
            leave: [
                .init(Day(2026, 8, 31)), // the bank holiday
                .init(Day(2026, 8, 30)), // a Sunday
            ],
            today: Day(2026, 8, 4)
        ))
        // Booking the August bank holiday off is not a day of leave, and
        // deducting it would double-count a day already removed from working
        // days.
        #expect(result.leaveTaken == 0)
        #expect(result.target == 8)
    }

    @Test("Attendance counts, booking does not")
    func attendanceNotBooking() {
        // A booked desk on a day already attended has converted; it must not be
        // counted twice, once as attended and once as forecast.
        let result = Quota.calculate(.init(
            month: august,
            attendance: [.init(Day(2026, 8, 5))],
            deskBookingDays: [Day(2026, 8, 5), Day(2026, 8, 6)],
            today: Day(2026, 8, 4)
        ))
        #expect(result.attended == 1)
        #expect(result.forecast == 1)
    }

    @Test("A desk booked for a past day is not forecast")
    func pastBookingsAreNotForecast() {
        let result = Quota.calculate(.init(
            month: august,
            deskBookingDays: [Day(2026, 8, 3)],
            today: Day(2026, 8, 10)
        ))
        // Booked, not turned up for, and the day has gone. It contributes
        // nothing — which is the point of AttendanceDay being separate.
        #expect(result.forecast == 0)
        #expect(result.attended == 0)
    }

    @Test("A desk booked on the bank holiday is not forecast")
    func bankHolidayBookingIsNotForecast() {
        let result = Quota.calculate(.init(
            month: august,
            deskBookingDays: [Day(2026, 8, 31)],
            today: Day(2026, 8, 4)
        ))
        #expect(result.forecast == 0)
    }

    @Test("Shortfall never goes negative")
    func overAchievement() {
        let result = Quota.calculate(.init(
            month: august,
            attendance: (1...12).map { .init(Day(2026, 8, $0)) },
            today: Day(2026, 8, 20)
        ))
        #expect(result.target == 8)
        #expect(result.shortfall == 0)
    }

    @Test("Whole leave means a target of nothing")
    func everyDayOnLeave() {
        let result = Quota.calculate(.init(
            month: august,
            leave: Month(year: 2026, month: 8).weekdays.map { .init($0) },
            today: Day(2026, 8, 1)
        ))
        #expect(result.eligible == 0)
        #expect(result.target == 0)
        #expect(result.shortfall == 0)
    }

    @Test("Days to run counts down and excludes the bank holiday")
    func daysToRun() {
        #expect(Quota.calculate(.init(month: august, today: Day(2026, 8, 4))).daysToRun == 18)
        #expect(Quota.calculate(.init(month: august, today: Day(2026, 8, 28))).daysToRun == 0)
        #expect(Quota.calculate(.init(month: august, today: Day(2026, 8, 31))).daysToRun == 0)
    }

    @Test("A month with no bank holidays keeps all its weekdays")
    func monthWithoutHolidays() {
        let result = Quota.calculate(.init(
            month: Month(year: 2026, month: 9), today: Day(2026, 9, 1)
        ))
        #expect(result.bankHolidays.isEmpty)
        #expect(result.workingDays == 22)
        #expect(result.target == 8)
    }
}

@Suite("Leave logging")
struct LeaveCycleTests {

    @Test("A day cycles none → full → half → none")
    func cycle() {
        // Whole days are the common case, so they are one tap and the half is
        // two — not the other way round.
        #expect(LeaveCycle.next(after: nil) == 1.0)
        #expect(LeaveCycle.next(after: 1.0) == 0.5)
        #expect(LeaveCycle.next(after: 0.5) == nil)
    }

    @Test("Attended days and bank holidays cannot be given leave")
    func notEditable() {
        // Both would deduct the same day twice: an attended day is history,
        // and a bank holiday is already out of working days.
        #expect(!LeaveCycle.editable(.attended))
        #expect(!LeaveCycle.editable(.bankHoliday))
        #expect(LeaveCycle.editable(.ordinary))
        #expect(LeaveCycle.editable(.booked))
        #expect(LeaveCycle.editable(.leave))
        #expect(LeaveCycle.editable(.halfLeave))
    }

    @Test("The grid distinguishes a half day from a whole one")
    func halfDayShows() throws {
        let cells = MissionGrid.cells(.init(
            month: Month(year: 2026, month: 8),
            attended: [],
            deskBookingDays: [],
            leave: [Day(2026, 8, 17): 1.0, Day(2026, 8, 18): 0.5],
            today: Day(2026, 8, 4)
        ))
        let whole = try #require(cells.compactMap { $0 }.first { $0.day == Day(2026, 8, 17) })
        let half = try #require(cells.compactMap { $0 }.first { $0.day == Day(2026, 8, 18) })
        #expect(whole.state == .leave)
        #expect(half.state == .halfLeave)
        #expect(whole.state.isLeave && half.state.isLeave)
    }

    @Test("Half days move the target by a half")
    func halfDayArithmetic() {
        // August's worked example is three whole days off: 8 × 17 ÷ 20 = 6.8,
        // rounding to 7. Make one of them a half and eligible becomes 17.5.
        let result = Quota.calculate(.init(
            month: Month(year: 2026, month: 8),
            leave: [
                .init(Day(2026, 8, 17), 1.0),
                .init(Day(2026, 8, 18), 1.0),
                .init(Day(2026, 8, 19), 0.5),
            ],
            today: Day(2026, 8, 4)
        ))
        #expect(result.leaveTaken == 2.5)
        #expect(result.eligible == 17.5)
    }
}
