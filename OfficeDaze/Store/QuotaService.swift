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
            attendedByOffice: attendance.reduce(into: [:]) { totals, row in
                guard let officeID = row.officeID else { return }
                totals[officeID, default: 0] += row.fraction
            },
            bookedDays: Set(bookedDays)
        )
    }
}
