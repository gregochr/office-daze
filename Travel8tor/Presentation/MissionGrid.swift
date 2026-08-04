import Foundation

/// The month grid on The Mission: five columns, Monday to Friday, one cell per
/// weekday. Weekends are not shown at all — they are not days you could be on
/// prem, so they are not days the target is about.
nonisolated enum MissionGrid {

    enum State: String, Sendable {
        /// Turned up. The only state that counts toward the eight.
        case attended
        /// A desk booked for a future day. Shows as forecast, converts on the day.
        case booked
        case leave
        case bankHoliday
        case ordinary
    }

    struct Cell: Identifiable, Sendable {
        let day: Day
        let state: State
        var id: Day { day }

        var figure: String { String(format: "%02d", day.day) }
    }

    struct Input: Sendable {
        let month: Month
        let attended: Set<Day>
        let deskBookingDays: Set<Day>
        let leave: Set<Day>
        let today: Day
    }

    /// `nil` is a blank cell — the padding before the first weekday, so the
    /// 1st lands in the right column.
    static func cells(_ input: Input) -> [Cell?] {
        let bankHolidays = Set(BankHolidays.englandAndWales(in: input.month))
        let weekdays = input.month.weekdays

        var out: [Cell?] = []
        if let first = weekdays.first {
            // weekday 2 is Monday, so Monday is column 0 and Friday column 4.
            out.append(contentsOf: Array(repeating: nil, count: first.weekday - 2))
        }

        for day in weekdays {
            let state: State
            if input.attended.contains(day) {
                state = .attended
            } else if bankHolidays.contains(day) {
                state = .bankHoliday
            } else if input.leave.contains(day) {
                state = .leave
            } else if input.deskBookingDays.contains(day), day > input.today {
                state = .booked
            } else {
                state = .ordinary
            }
            out.append(Cell(day: day, state: state))
        }
        return out
    }

    /// The `▸ TARGET DERIVATION` panel, line by line, so the arithmetic is
    /// visible rather than asserted. Nothing here is stored; it is all derived
    /// from the same `Quota.Result` the gauge uses.
    struct DerivationLine: Identifiable, Sendable {
        let label: String
        let value: String
        var id: String { label }
    }

    static func derivation(_ result: Quota.Result, leave: [Day]) -> [DerivationLine] {
        var lines = [
            DerivationLine(label: "WORKING DAYS", value: String(format: "%02d", result.workingDays))
        ]

        if result.leaveTaken > 0 {
            let taken = result.leaveTaken
            let amount = taken == taken.rounded()
                ? String(format: "−%02d", Int(taken))
                : String(format: "−%.1f", taken)
            lines.append(DerivationLine(label: "LEAVE \(dayRanges(leave))", value: amount))
        }

        // `8 × 17 ÷ 20` and the unrounded 6.8, so the rounding is visible.
        let exact = result.workingDays == 0
            ? 0
            : Quota.baseTarget * result.eligible / Double(result.workingDays)
        lines.append(DerivationLine(
            label: "\(Int(Quota.baseTarget)) × \(trim(result.eligible)) ÷ \(result.workingDays)",
            value: trim((exact * 10).rounded() / 10)
        ))
        lines.append(DerivationLine(label: "TARGET", value: String(format: "%02d", result.target)))
        return lines
    }

    /// `17–19`, or `03, 17–19` — consecutive days collapse into a range.
    static func dayRanges(_ days: [Day]) -> String {
        let sorted = days.sorted()
        guard !sorted.isEmpty else { return "" }

        var runs: [[Day]] = [[sorted[0]]]
        for day in sorted.dropFirst() {
            if let last = runs.last?.last, last.adding(days: 1) == day {
                runs[runs.count - 1].append(day)
            } else {
                runs.append([day])
            }
        }

        return runs.map { run in
            run.count == 1
                ? String(format: "%02d", run[0].day)
                : String(format: "%02d–%02d", run[0].day, run[run.count - 1].day)
        }
        .joined(separator: ", ")
    }

    private static func trim(_ value: Double) -> String {
        value == value.rounded()
            ? String(Int(value))
            : String(format: "%g", value)
    }
}
