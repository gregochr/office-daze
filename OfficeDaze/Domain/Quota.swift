import Foundation

/// The monthly on-premises calculation.
///
///     workingDays = weekdays(month) − bankHolidays(month)
///     eligible    = workingDays − sum(leave.fraction)
///     relief      = floor(leave ÷ 5) × 2
///     target      = clamp(8 − relief, 0 ... eligible)
///     attended    = sum(attendance.fraction)   // counts
///     forecast    = desk bookings and planned days after today  // does not
///     shortfall   = max(0, target − attended − forecast)
///
/// Derived on read, never stored. Nothing in here is authored data.
nonisolated enum Quota {

    /// Eight days a month, before leave.
    static let baseTarget: Double = 8

    /// Leave comes off the target in whole blocks: every five days off takes
    /// two days with it, and anything short of five takes nothing.
    ///
    /// This replaced a proportional pro-rate, `8 × eligible ÷ workingDays`,
    /// which moved the target by a fraction of a day for every day booked and
    /// so moved it by a whole day at an arbitrary point — the fourth day off in
    /// one month, the third in another, depending on how many working days the
    /// month happened to have. A block is a rule you can hold in your head: the
    /// fifth day off is the one that matters, and it is worth two.
    static let leaveBlock: Double = 5
    static let blockRelief: Double = 2

    struct DayFraction: Hashable, Sendable {
        let day: Day
        /// 1.0 or 0.5 — a half-day off is still a day you could be on prem.
        let fraction: Double

        init(_ day: Day, _ fraction: Double = 1.0) {
            self.day = day
            self.fraction = fraction
        }
    }

    struct Inputs: Sendable {
        let month: Month
        /// Annual and sick leave. Bank holidays are *not* passed in here — they
        /// are derived and already removed from working days, so including them
        /// would deduct the same day twice.
        let leave: [DayFraction]
        let attendance: [DayFraction]
        /// Days with a desk booking that counts to quota. Only those strictly
        /// after `today` and not already attended become forecast.
        let deskBookingDays: Set<Day>
        /// Days intended on prem with no desk — a workshop, a meeting. They
        /// forecast exactly as a booking does, and a day that is both booked
        /// and planned counts once.
        let plannedDays: Set<Day>
        let today: Day

        init(
            month: Month,
            leave: [DayFraction] = [],
            attendance: [DayFraction] = [],
            deskBookingDays: Set<Day> = [],
            plannedDays: Set<Day> = [],
            today: Day
        ) {
            self.month = month
            self.leave = leave
            self.attendance = attendance
            self.deskBookingDays = deskBookingDays
            self.plannedDays = plannedDays
            self.today = today
        }
    }

    /// What the month amounts to.
    ///
    /// The distinction that matters is between *met* and *on track*, and a
    /// shortfall of zero does not tell them apart: shortfall subtracts the
    /// forecast, so four days attended with four more booked reaches zero
    /// without a fifth day having been worked. Attendance is the only thing
    /// that counts toward the eight — a booking is an intention, and an
    /// intention is not a day on prem, which is the whole reason the two are
    /// separate entities. Calling that "Target met" claimed the second as the
    /// first, beside a dial reading `4 of 8` that said the opposite in the same
    /// card.
    /// Four states rather than three, because "behind" was two facts wearing
    /// one colour. Being short with three weeks to go is an errand; being short
    /// with more days needed than the month has left is the only thing in this
    /// app worth a red, and it shows up perhaps twice a year.
    enum Standing: Hashable, Sendable {
        /// The days worked reach the target on their own.
        case met
        /// Not yet, but everything needed is already booked.
        case onTrack
        /// Short even with every booking honoured, and still reachable.
        case behind
        /// Short by more days than there are left to work.
        case unreachable
    }

    struct Result: Hashable, Sendable {
        let bankHolidays: [Day]
        let workingDays: Int
        let leaveTaken: Double
        let eligible: Double
        /// Days taken off the base target by leave — always a multiple of two,
        /// and zero until the fifth day is booked. The screens explain the
        /// target with this rather than recomputing the rule.
        let relief: Double
        let target: Int
        let attended: Double
        let forecast: Double
        let shortfall: Double
        /// Working days left in the month *after* today. The gauge footer's
        /// "18 DAYS TO RUN".
        ///
        /// Exclusive of today, which the mock's own numbers force: on 4 August
        /// 2026 it reads 18, and 4 August inclusive would be 19. It is also the
        /// same boundary `forecast` uses, so the two figures can't disagree
        /// about whether today is still in play.
        let daysToRun: Int
        /// Days the target could still be met on: working days from today
        /// onward, less the ones already worked and the ones booked off.
        ///
        /// Not `daysToRun`, which excludes today. The difference is the whole
        /// last working day of the month, and testing reachability against
        /// `daysToRun` would call a month unreachable on a morning it could
        /// still be finished — a red that is wrong by default, which is exactly
        /// what the bands were retired for.
        let daysAvailable: Int

        var standing: Standing {
            if attended >= Double(target) { return .met }
            guard shortfall > 0 else { return .onTrack }
            return Double(target) - attended > Double(daysAvailable) ? .unreachable : .behind
        }
    }

    static func calculate(_ input: Inputs) -> Result {
        let month = input.month
        let bankHolidays = BankHolidays.englandAndWales(in: month)
        let bankHolidaySet = Set(bankHolidays)

        let workingDaySet = Set(month.weekdays).subtracting(bankHolidaySet)
        let workingDays = workingDaySet.count

        // Leave only counts where it lands on a working day. Booking the Friday
        // of the August bank holiday weekend off does not lower the target.
        let leaveTaken = input.leave
            .filter { workingDaySet.contains($0.day) }
            .reduce(0) { $0 + $1.fraction }

        let eligible = Double(workingDays) - leaveTaken

        // Whole blocks only, so four days off changes nothing and the fifth
        // takes two. `leaveTaken` is always a multiple of a half day, which is
        // exact in binary, so the floor needs no tolerance.
        let relief = (leaveTaken / leaveBlock).rounded(.down) * blockRelief

        // Clamped to the days actually left, or a month spent almost entirely
        // on leave would still ask for days there is no room for: 19 working
        // days all booked off is three whole blocks, which takes the target to
        // two rather than to nothing.
        let target = Int(min(max(0, baseTarget - relief), max(0, eligible)).rounded(.down))

        let attended = input.attendance
            .filter { month.contains($0.day) }
            .reduce(0) { $0 + $1.fraction }
        let attendedDays = Set(input.attendance.map(\.day))

        // Forecast is what is intended ahead and not yet turned up for, whether
        // a desk was reserved or not. A day already attended is not forecast —
        // it has converted. Unioned, so a day both booked and planned is one
        // day rather than two.
        let forecast = Double(
            input.deskBookingDays.union(input.plannedDays)
                .filter { workingDaySet.contains($0) }
                .filter { $0 > input.today }
                .subtracting(attendedDays)
                .count
        )

        let shortfall = max(0, Double(target) - attended - forecast)

        let daysToRun = workingDaySet.filter { $0 > input.today }.count

        // Today counts here where it does not in `daysToRun`: a day still being
        // worked is a day the target can still be met on. A half-day of leave
        // leaves half a day available and is counted as a whole, which errs
        // toward saying the month is still reachable — the right direction for
        // a figure whose only job is to decide whether to show a red.
        let leaveDays = Set(input.leave.filter { $0.fraction >= 1 }.map(\.day))
        let daysAvailable = workingDaySet
            .filter { $0 >= input.today }
            .subtracting(attendedDays)
            .subtracting(leaveDays)
            .count

        return Result(
            bankHolidays: bankHolidays,
            workingDays: workingDays,
            leaveTaken: leaveTaken,
            eligible: eligible,
            relief: relief,
            target: target,
            attended: attended,
            forecast: forecast,
            shortfall: shortfall,
            daysToRun: daysToRun,
            daysAvailable: daysAvailable
        )
    }
}
