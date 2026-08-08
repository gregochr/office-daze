import Foundation
import SwiftData

/// Assembles `Quota.Inputs` from the store. The arithmetic stays in `Quota`;
/// this only knows how to fetch.
@MainActor
enum QuotaService {

    struct Snapshot {
        let month: Month
        let result: Quota.Result
        let attendedDays: Set<Day>
        /// Attended days per office, for the row of office cards. Counted as
        /// fractions, so a half-day shows as a half.
        let attendedByOffice: [UUID: Double]
        let bookedDays: Set<Day>
    }

    static func snapshot(for month: Month, today: Day, in context: ModelContext) throws -> Snapshot {
        // Bank-holiday rows are excluded: they are derived from the calendar and
        // already removed from working days, so counting them as leave would
        // deduct the same day twice.
        let leave = try context.fetch(FetchDescriptor<LeaveDay>())
            .filter { $0.kind != .bankHoliday && month.contains($0.day) }

        let attendance = try context.fetch(FetchDescriptor<AttendanceDay>())
            .filter { month.contains($0.day) }

        let bookedDays = try context.fetch(FetchDescriptor<DeskBooking>())
            .map(\.day)
            .filter { month.contains($0) }

        let plannedDays = try context.fetch(FetchDescriptor<PlannedDay>())
            .map(\.day)
            .filter { month.contains($0) }

        let result = Quota.calculate(.init(
            month: month,
            leave: leave.map { Quota.DayFraction($0.day, $0.fraction) },
            attendance: attendance.map { Quota.DayFraction($0.day, $0.fraction) },
            deskBookingDays: Set(bookedDays),
            plannedDays: Set(plannedDays),
            today: today
        ))

        return Snapshot(
            month: month,
            result: result,
            attendedDays: Set(attendance.map(\.day)),
            attendedByOffice: sharesByOffice(attendance),
            bookedDays: Set(bookedDays)
        )
    }

    /// Attendance split across the offices it was recorded at, on the same
    /// basis `Quota` counts it: a day is worth at most a day.
    ///
    /// The split bar sits directly under the gauge, so the two have to add up.
    /// `Quota.calculate` caps each date's fractions at 1.0, and a plain sum of
    /// the rows here would put more into the bar than the gauge above it shows
    /// — a whole extra day of it, for a date carrying two whole-day rows at two
    /// buildings. `BookingStore.recordAttendance` refuses to write that day now,
    /// so this only arises for rows a previous version let through; the scaling
    /// is what makes those rows harmless rather than visibly contradictory.
    ///
    /// Scaled proportionally rather than given to whichever office is fetched
    /// first: an over-full day is a day whose split nobody actually knows, and
    /// halving it between two buildings is at least symmetrical about the
    /// ambiguity. Rows with no office are left out, as they always were —
    /// turning up somewhere the app has no building for is a day on prem with
    /// no share to give.
    private static func sharesByOffice(_ attendance: [AttendanceDay]) -> [UUID: Double] {
        var shares: [UUID: Double] = [:]
        for (_, rows) in Dictionary(grouping: attendance, by: \.day) {
            let total = rows.reduce(0) { $0 + $1.fraction }
            let scale = total > 1 ? 1 / total : 1
            for row in rows {
                guard let officeID = row.officeID else { continue }
                shares[officeID, default: 0] += row.fraction * scale
            }
        }
        return shares
    }
}
