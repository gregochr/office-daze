import Testing
@testable import OfficeDaze

@Suite("Quota")
struct QuotaTests {

    let august = Month(year: 2026, month: 8)

    /// The handoff's worked example: 21 weekdays less the bank holiday is 20,
    /// minus three days' leave is 17, and 8 × 17 ÷ 20 = 6.8 rounds to 7.
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

        // 21 weekdays less the 31st.
        #expect(result.bankHolidays == [Day(2026, 8, 31)])
        #expect(result.workingDays == 20)

        // Three days' leave, 17th to 19th.
        #expect(result.leaveTaken == 3)
        #expect(result.eligible == 17)

        // 8 × 17 ÷ 20 = 6.8 → target 7.
        #expect(result.target == 7)

        // The gauge: 2 attended, 2 forecast, centre reads 4.
        #expect(result.attended == 2)
        #expect(result.forecast == 2)
        #expect(result.attended + result.forecast == 4)

        // The footer: 3 days to go, 18 working days left.
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

    /// A workshop you have not been to yet is as good a reason to expect a day
    /// on prem as a desk you have reserved. The target counts days, not desks.
    @Test("A planned day forecasts exactly as a booking does")
    func plannedDaysForecast() {
        let result = Quota.calculate(.init(
            month: august,
            plannedDays: [Day(2026, 8, 20)],
            today: Day(2026, 8, 4)
        ))
        #expect(result.forecast == 1)
        #expect(result.attended == 0, "intending to be somewhere is not having been")
    }

    /// Booked *and* planned is one day on prem, not two — otherwise noting a
    /// workshop on a day you also have a desk would invent a day.
    @Test("A day both booked and planned counts once")
    func plannedAndBookedIsOneDay() {
        let result = Quota.calculate(.init(
            month: august,
            deskBookingDays: [Day(2026, 8, 20)],
            plannedDays: [Day(2026, 8, 20)],
            today: Day(2026, 8, 4)
        ))
        #expect(result.forecast == 1)
    }

    /// Turning up converts it, exactly as it does a booking.
    @Test("A planned day already attended is no longer forecast")
    func plannedThenAttended() {
        let result = Quota.calculate(.init(
            month: august,
            attendance: [.init(Day(2026, 8, 20))],
            plannedDays: [Day(2026, 8, 20)],
            today: Day(2026, 8, 4)
        ))
        #expect(result.attended == 1)
        #expect(result.forecast == 0)
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

    /// Four days in and four booked reaches a shortfall of zero, and the strip
    /// read that as "Target met" beside a dial reading 4 of 8. Days worked are
    /// the only thing that meets the target; the bookings are what makes it
    /// reachable, which is a different sentence.
    @Test("Four attended with four booked is on track, not met")
    func onTrackIsNotMet() {
        let result = Quota.calculate(.init(
            month: august,
            attendance: [3, 4, 5, 6].map { .init(Day(2026, 8, $0)) },
            deskBookingDays: Set([24, 25, 26, 27].map { Day(2026, 8, $0) }),
            today: Day(2026, 8, 6)
        ))
        #expect(result.target == 8)
        #expect(result.attended == 4)
        #expect(result.forecast == 4)
        #expect(result.shortfall == 0, "which is exactly why zero could not be the test")
        #expect(result.standing == .onTrack)
    }

    @Test("Attendance alone is what meets the target")
    func attendedMeetsIt() {
        let result = Quota.calculate(.init(
            month: august,
            attendance: (3...12).map { .init(Day(2026, 8, $0)) },
            today: Day(2026, 8, 20)
        ))
        #expect(result.standing == .met)
    }

    @Test("Short even with every booking honoured is behind")
    func behindEvenWithBookings() {
        let result = Quota.calculate(.init(
            month: august,
            attendance: [.init(Day(2026, 8, 3))],
            deskBookingDays: [Day(2026, 8, 24)],
            today: Day(2026, 8, 6)
        ))
        #expect(result.shortfall == 6)
        #expect(result.standing == .behind)
    }

    /// A month with nothing required is met by having done nothing, which is
    /// the honest answer rather than a shortfall of zero reported as on track.
    @Test("A target of nothing is met, not merely on track")
    func nothingRequiredIsMet() {
        let result = Quota.calculate(.init(
            month: august,
            leave: august.weekdays.map { .init($0) },
            today: Day(2026, 8, 4)
        ))
        #expect(result.target == 0)
        #expect(result.standing == .met)
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

    @Test("Half a day off moves the target by half a day")
    func halfDayArithmetic() {
        // August's worked example is three whole days off: 8 × 17 ÷ 20 = 6.8,
        // rounding to 7. Make one of them a half and eligible becomes 17.5.
        let result = Quota.calculate(.init(
            month: august,
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
