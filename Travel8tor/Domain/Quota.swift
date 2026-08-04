import Foundation

/// The monthly on-premises calculation.
///
///     workingDays = weekdays(month) − bankHolidays(month)
///     eligible    = workingDays − sum(leave.fraction)
///     target      = round(8 × eligible ÷ workingDays)
///     attended    = sum(attendance.fraction)   // counts
///     forecast    = desk bookings after today  // does not
///     shortfall   = max(0, target − attended − forecast)
///
/// Derived on read, never stored. Nothing in here is authored data.
nonisolated enum Quota {

    /// Eight days a month, before pro-rating.
    static let baseTarget: Double = 8

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
        let today: Day

        init(
            month: Month,
            leave: [DayFraction] = [],
            attendance: [DayFraction] = [],
            deskBookingDays: Set<Day> = [],
            today: Day
        ) {
            self.month = month
            self.leave = leave
            self.attendance = attendance
            self.deskBookingDays = deskBookingDays
            self.today = today
        }
    }

    struct Result: Hashable, Sendable {
        let bankHolidays: [Day]
        let workingDays: Int
        let leaveTaken: Double
        let eligible: Double
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

        // Guard against a month with no working days — impossible in practice,
        // but division is division.
        let target = workingDays == 0
            ? 0
            : Int((baseTarget * eligible / Double(workingDays)).rounded())

        let attended = input.attendance
            .filter { month.contains($0.day) }
            .reduce(0) { $0 + $1.fraction }
        let attendedDays = Set(input.attendance.map(\.day))

        // Forecast is what is booked ahead and not yet turned up for. A desk
        // booked for a day already attended is not forecast — it has converted.
        let forecast = Double(
            input.deskBookingDays
                .filter { workingDaySet.contains($0) }
                .filter { $0 > input.today }
                .subtracting(attendedDays)
                .count
        )

        let shortfall = max(0, Double(target) - attended - forecast)

        let daysToRun = workingDaySet.filter { $0 > input.today }.count

        return Result(
            bankHolidays: bankHolidays,
            workingDays: workingDays,
            leaveTaken: leaveTaken,
            eligible: eligible,
            target: target,
            attended: attended,
            forecast: forecast,
            shortfall: shortfall,
            daysToRun: daysToRun
        )
    }
}
