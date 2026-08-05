import Foundation
import SwiftData

/// Assembles `Quota.Inputs` from the store. The arithmetic stays in `Quota`;
/// this only knows how to fetch.
@MainActor
enum QuotaService {

    struct Snapshot {
        let month: Month
        let result: Quota.Result
        let leaveDays: [Day]
        /// Day to fraction, for the grid — a half-day reads differently there.
        let leaveFractions: [Day: Double]
        let attendedDays: Set<Day>
        let deskBookingDays: Set<Day>
    }

    static func snapshot(for month: Month, today: Day, in context: ModelContext) throws -> Snapshot {
        // Bank-holiday rows are excluded: they are derived from the calendar and
        // already removed from working days, so counting them as leave would
        // deduct the same day twice.
        let leave = try context.fetch(FetchDescriptor<LeaveDay>())
            .filter { $0.kind != .bankHoliday && month.contains($0.day) }

        let attendance = try context.fetch(FetchDescriptor<AttendanceDay>())
            .filter { month.contains($0.day) }

        let deskDays = try context.fetch(FetchDescriptor<Booking>())
            .filter { $0.kind == .desk && $0.detail?.deskDetail?.countsToQuota == true }
            .map(\.anchorDay)
            .filter { month.contains($0) }

        let result = Quota.calculate(.init(
            month: month,
            leave: leave.map { Quota.DayFraction($0.day, $0.fraction) },
            attendance: attendance.map { Quota.DayFraction($0.day, $0.fraction) },
            deskBookingDays: Set(deskDays),
            today: today
        ))

        return Snapshot(
            month: month,
            result: result,
            leaveDays: leave.map(\.day).sorted(),
            // Two rows for one day would be a bug elsewhere, but summing rather
            // than overwriting keeps a half plus a half reading as a full day.
            leaveFractions: leave.reduce(into: [:]) { $0[$1.day, default: 0] += $1.fraction },
            attendedDays: Set(attendance.map(\.day)),
            deskBookingDays: Set(deskDays)
        )
    }
}

extension Day {
    /// The current day, in UK time. The quota is about UK working days, so the
    /// day boundary is the UK one even when the phone is abroad — otherwise a
    /// late Brussels evening would roll the count over early.
    ///
    /// `nonisolated` because it is a clock reading and nothing more — the
    /// project defaults every declaration to the main actor, which would
    /// otherwise stop a plain struct using it as a default value.
    nonisolated static var today: Day { Day(of: .now, in: TimeDisplay.uk) }
}
