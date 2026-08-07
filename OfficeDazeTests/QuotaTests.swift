import Testing
@testable import OfficeDaze

@Suite("Quota")
struct QuotaTests {

    let august = Month(year: 2026, month: 8)

    /// The handoff's worked example: 21 weekdays less the bank holiday is 20,
    /// minus three days' leave is 17. Three days is not a whole block of five,
    /// so the target stays at 8 — the mock was drawn against the pro-rate it
    /// replaced, which put it at 7.
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

        // Three days is short of a block, so nothing comes off.
        #expect(result.relief == 0)
        #expect(result.target == 8)

        // The gauge: 2 attended, 2 forecast, centre reads 4.
        #expect(result.attended == 2)
        #expect(result.forecast == 2)
        #expect(result.attended + result.forecast == 4)

        // The footer: 4 days to go, 18 working days left.
        #expect(result.shortfall == 4)
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
        #expect(result.target == 8)      // half a day is nowhere near a block
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

    /// "4 days to go" was the gap and nothing else, so a month with four days
    /// already lined up read exactly like a month with nothing arranged at all.
    @Test("The amber strip says what is booked, not only what is missing")
    func shortfallCopy() {
        // September's shape: nothing attended, four days lined up, eight
        // needed.
        let behind = Quota.calculate(.init(
            month: Month(year: 2026, month: 9),
            deskBookingDays: [Day(2026, 9, 7)],
            plannedDays: Set([8, 9, 10].map { Day(2026, 9, $0) }),
            today: Day(2026, 8, 31)
        ))
        #expect(behind.standing == .behind)
        let text = HomeScreen.shortfallText(behind)
        #expect(text.leading == "4 more days to book", "names the action, not just the gap")
        #expect(text.trailing == "4 booked · 22 days left")

        // One day reads as a day.
        let nearly = Quota.calculate(.init(
            month: Month(year: 2026, month: 9),
            attendance: (1...7).map { .init(Day(2026, 9, $0)) },
            today: Day(2026, 9, 8)
        ))
        #expect(HomeScreen.shortfallText(nearly).leading == "1 more day to book")
        #expect(
            HomeScreen.shortfallText(nearly).trailing.hasPrefix("none booked"),
            "nothing lined up says so rather than reading as zero of something"
        )
    }

    /// The app is entirely about a deadline, and the remaining month used to
    /// appear only in the trailing half of the amber strip — so on track or met
    /// it vanished, which is exactly when you want to know whether you can stop.
    @Test("The date line says where the month is, in every state")
    func dateLine() {
        let result = Quota.calculate(.init(month: august, today: Day(2026, 8, 4)))
        #expect(
            HomeScreen.dateLine(result, month: august, today: Day(2026, 8, 4))
                == "4 August · 18 working days left"
        )

        // A month you are not inside has no deadline to be counting down to,
        // so it says how big it was rather than how much of it is left.
        let september = Month(year: 2026, month: 9)
        let ahead = Quota.calculate(.init(month: september, today: Day(2026, 8, 4)))
        #expect(
            HomeScreen.dateLine(ahead, month: september, today: Day(2026, 8, 4))
                == "22 working days"
        )

        // One day is a day.
        let last = Quota.calculate(.init(month: august, today: Day(2026, 8, 27)))
        #expect(
            HomeScreen.dateLine(last, month: august, today: Day(2026, 8, 27))
                == "27 August · 1 working day left"
        )
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

    /// The fourth state, and the only red in the app. "Behind" was two facts
    /// wearing one colour: short with three weeks to go is an errand, and short
    /// by more days than the month has left is a different sentence entirely.
    @Test("Short by more days than are left is unreachable, not merely behind")
    func unreachable() {
        // 27 August, a Thursday. Two working days left including today (the
        // 31st is the bank holiday), one day attended, eight needed.
        let result = Quota.calculate(.init(
            month: august,
            attendance: [.init(Day(2026, 8, 3))],
            today: Day(2026, 8, 27)
        ))
        #expect(result.daysAvailable == 2, "today and Friday")
        #expect(result.standing == .unreachable)

        // The same month a fortnight earlier is short by exactly as much and is
        // not a crisis: there is still room. This is the case the old bands got
        // backwards — they read a fortnight of normality as red and the last
        // week of an unreachable month as amber.
        let early = Quota.calculate(.init(
            month: august,
            attendance: [.init(Day(2026, 8, 3))],
            today: Day(2026, 8, 6)
        ))
        #expect(early.shortfall == early.shortfall, "same shortfall")
        #expect(early.standing == .behind)
    }

    /// `daysToRun` excludes today, and testing reachability against it would
    /// call a month lost on a morning it could still be finished.
    @Test("The last working day still counts as a day it can be done in")
    func todayIsStillAvailable() {
        // Friday 28 August: the last working day of the month, seven attended,
        // one still needed. It is reachable, by going in today.
        let result = Quota.calculate(.init(
            month: august,
            attendance: (3...11).filter { $0 != 8 && $0 != 9 }.map { .init(Day(2026, 8, $0)) },
            today: Day(2026, 8, 28)
        ))
        #expect(result.attended == 7)
        #expect(result.daysToRun == 0, "nothing after today")
        #expect(result.daysAvailable == 1, "today")
        #expect(result.standing == .behind, "reachable, if you go in")
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

    @Test("Half days still add up to eligible days")
    func halfDayArithmetic() {
        // Three days off with one of them a half: eligible becomes 17.5, and
        // 2.5 days is still short of the first block.
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
        #expect(result.target == 8)
    }

    // MARK: Blocks of five

    /// The rule, one row at a time. August has 20 working days, so nothing here
    /// runs into the clamp — this is the block arithmetic on its own.
    @Test(
        "Every whole five days' leave takes two days off the target",
        arguments: [
            (0.0, 0.0, 8), (1.0, 0.0, 8), (4.0, 0.0, 8), (4.5, 0.0, 8),
            (5.0, 2.0, 6), (5.5, 2.0, 6), (9.5, 2.0, 6),
            (10.0, 4.0, 4), (14.0, 4.0, 4),
            (15.0, 6.0, 2), (20.0, 8.0, 0),
        ]
    )
    func blocksOfFive(leave: Double, relief: Double, target: Int) {
        // Laid down as whole and half days from the 3rd, which is a Monday, so
        // the run never lands on a weekend or the bank holiday on the 31st.
        let wholeDays = Int(leave)
        var fractions = august.weekdays.prefix(wholeDays).map { Quota.DayFraction($0) }
        if leave > Double(wholeDays) {
            fractions.append(.init(august.weekdays[wholeDays], 0.5))
        }

        let result = Quota.calculate(.init(
            month: august, leave: fractions, today: Day(2026, 8, 1)
        ))

        #expect(result.leaveTaken == leave)
        #expect(result.relief == relief)
        #expect(result.target == target, "\(leave) days' leave")
    }

    /// Four days off used to shave a day under the pro-rate; now it is the
    /// fifth that does the work, and it does two days' worth at once. The step
    /// is the whole point of the rule, so it is worth a test of its own.
    @Test("The fifth day is where the target moves, and it moves by two")
    func theStep() {
        func target(_ days: Int) -> Int {
            Quota.calculate(.init(
                month: august,
                leave: august.weekdays.prefix(days).map { .init($0) },
                today: Day(2026, 8, 1)
            )).target
        }
        #expect(target(4) == 8)
        #expect(target(5) == 6, "not 7 — a block is worth two days")
    }

    /// A month almost entirely on leave has three whole blocks and so a target
    /// of two, against nothing like two days to spend. The days that are left
    /// are the real ceiling.
    @Test("The target never exceeds the days actually left")
    func clampedToEligible() {
        // 19 of August's 20 working days off: 3 blocks, 6 off, target 2 by the
        // block rule — but only one working day remains.
        let result = Quota.calculate(.init(
            month: august,
            leave: august.weekdays.filter { !BankHolidays.englandAndWales(in: august).contains($0) }
                .prefix(19).map { .init($0) },
            today: Day(2026, 8, 1)
        ))
        #expect(result.relief == 6)
        #expect(result.eligible == 1)
        #expect(result.target == 1, "two days cannot be asked of one day")
    }

    /// The explanation under the gauge is the only place the rule is stated, so
    /// it has to hold in all three shapes — including leave that has not moved
    /// anything, which the pro-rate never produced.
    @Test("The target line explains itself in all three states")
    func explanationCopy() {
        func line(_ days: Int) -> String {
            HomeScreen.targetExplanation(Quota.calculate(.init(
                month: august,
                leave: august.weekdays.prefix(days).map { .init($0) },
                today: Day(2026, 8, 1)
            )))
        }
        #expect(line(0) == "Target 8 — 8 days a month")
        #expect(
            line(3) == "Target 8 — 3 days' leave; 5 days takes 2 off",
            "leave that has moved nothing still has to be visible"
        )
        #expect(line(5) == "Target 6 — 8 days less 2 for 5 days' leave")
        #expect(line(1).contains("1 day's leave"), "one day is singular")
    }
}
