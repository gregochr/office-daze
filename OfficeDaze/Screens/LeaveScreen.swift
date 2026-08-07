import SwiftData
import SwiftUI

/// The holiday calendar: annual leave as a month grid. Tap a day to cycle it.
///
/// A grid rather than a list of dates because leave comes in runs — three days
/// in the same week — and picking them off a calendar is one gesture per day
/// against three taps in a date picker.
///
/// Two ways in, both landing here: the target line under the gauge, which is
/// the leave's visible effect, and the Settings row, which is where you go
/// when you have a fortnight to book and the gauge is not what you are
/// thinking about.
struct LeaveScreen: View {
    @Environment(\.modelContext) private var context
    @Query private var leave: [LeaveDay]
    @Query private var attendance: [AttendanceDay]

    @State var month: Month = Day.today.month_

    private var bankHolidays: Set<Day> {
        Set(BankHolidays.englandAndWales(in: month))
    }

    private var attendedDays: Set<Day> {
        Set(attendance.filter { month.contains($0.day) }.map(\.day))
    }

    /// Day to fraction. Summed rather than overwritten so two half rows for one
    /// day read as a whole day rather than the last one written.
    private var fractions: [Day: Double] {
        leave
            .filter { $0.kind != .bankHoliday && month.contains($0.day) }
            .reduce(into: [:]) { $0[$1.day, default: 0] += $1.fraction }
    }

    private var result: Quota.Result {
        Quota.calculate(.init(
            month: month,
            leave: fractions.map { Quota.DayFraction($0.key, $0.value) },
            attendance: attendance
                .filter { month.contains($0.day) }
                .map { Quota.DayFraction($0.day, $0.fraction) },
            today: .today
        ))
    }

    var body: some View {
        ScrollView {
            VStack(spacing: Metrics.cardGap) {
                Card(padding: EdgeInsets(top: 12, leading: 12, bottom: 16, trailing: 12)) {
                    VStack(spacing: 0) {
                        monthStepper
                        weekdayHeadings.padding(.top, 12)
                        grid.padding(.top, 6)
                    }
                }
                target
                key
            }
            .padding(.horizontal, Metrics.screenPadding)
            .padding(.top, 6)
            .padding(.bottom, 30)
        }
        .background(Palette.ground)
        .navigationTitle("Holiday calendar")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// The same floor the gauge uses, from the same question, so stepping back
    /// stops on the same month on both screens. See `MonthRange` for why
    /// forward does not stop.
    private var canStepBack: Bool {
        guard let recorded = try? Store.recordedDays(in: context) else { return true }
        return MonthRange.canStepBack(from: month, recorded: recorded, today: .today)
    }

    private var monthStepper: some View {
        HStack {
            Button { month = month.adding(months: -1) } label: {
                Image(systemName: "chevron.left")
                    .opacity(canStepBack ? 1 : 0.3)
            }
            .disabled(!canStepBack)
            Spacer(minLength: 8)
            Text(month.text)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Palette.text)
            Spacer(minLength: 8)
            Button { month = month.adding(months: 1) } label: {
                Image(systemName: "chevron.right")
            }
        }
        .font(.system(size: 17))
        .foregroundStyle(Palette.tertiary)
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
    }

    private var weekdayHeadings: some View {
        HStack(spacing: 4) {
            ForEach(["M", "T", "W", "T", "F", "S", "S"], id: \.self) { day in
                Text(day)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    /// Weeks start on Monday — `Day.calendar` is set that way, and a working
    /// week that starts on Sunday puts the weekend in the middle of the grid.
    private var grid: some View {
        let days = month.days
        let leading = (days.first!.weekday + 5) % 7 // Monday = 0
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 4) {
            ForEach(0..<leading, id: \.self) { _ in Color.clear.frame(height: 40) }
            ForEach(days, id: \.self) { day in cell(day) }
        }
    }

    private func cell(_ day: Day) -> some View {
        let fraction = fractions[day]
        let editable = LeaveCycle.editable(
            day: day, bankHolidays: bankHolidays, attended: attendedDays
        )
        return Button {
            toggle(day)
        } label: {
            Text("\(day.day)")
                .font(.system(size: 15, weight: fraction != nil ? .semibold : .regular))
                .monospacedDigit()
                .foregroundStyle(foreground(day, fraction: fraction, editable: editable))
                .frame(maxWidth: .infinity)
                .frame(height: 40)
                .background(background(day, fraction: fraction))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!editable)
    }

    private func foreground(_ day: Day, fraction: Double?, editable: Bool) -> Color {
        if fraction != nil { return Palette.warningText }
        if attendedDays.contains(day) { return Palette.successText }
        if !editable { return Palette.tertiary }
        return Palette.text
    }

    private func background(_ day: Day, fraction: Double?) -> Color {
        if let fraction {
            // A half day is the same amber at half strength — the same thing,
            // less of it.
            return Palette.warningSurface.opacity(fraction >= 1 ? 1 : 0.5)
        }
        if attendedDays.contains(day) { return Palette.successSurface }
        if bankHolidays.contains(day) || day.isWeekend { return Palette.hairline.opacity(0.6) }
        return .clear
    }

    private var target: some View {
        Card(padding: EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16)) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Target \(result.target) for \(month.text)")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Palette.text)
                Text(explanation)
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Where the target came from, in the one place with room to say it
    /// properly. Leave that has not reached a whole block still gets named,
    /// with the threshold it has not reached — a card that answers "why is it
    /// still 8?" is worth more than one that only reports the number.
    private var explanation: String {
        let working = "across \(result.workingDays) working days"
        guard result.leaveTaken > 0 else {
            return "8 days a month, \(working). Every 5 days' leave takes 2 off."
        }
        let days = "\(number(result.leaveTaken)) "
            + "\(result.leaveTaken == 1 ? "day's" : "days'") leave"
        guard result.relief > 0 else {
            return "8 days a month, \(working). \(days) booked so far — the "
                + "first 2 come off at 5 days."
        }
        return "8 days a month less \(number(result.relief)) for \(days), \(working)."
    }

    private var key: some View {
        Text(
            "Tap a day to book it off — once for a whole day, twice for a half, "
            + "again to clear it. Weekends, bank holidays and days you were on "
            + "prem are already outside the count, so they can't be booked off."
        )
        .font(.system(size: 13))
        .lineSpacing(3)
        .foregroundStyle(Palette.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
    }

    private func number(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...1)))
    }

    private func toggle(_ day: Day) {
        let existing = leave.filter { $0.kind != .bankHoliday && $0.day == day }
        let next = LeaveCycle.next(after: fractions[day])
        // The rows are replaced rather than edited: a day that somehow holds
        // two of them collapses to one on the next tap.
        existing.forEach(context.delete)
        if let next {
            context.insert(LeaveDay(day: day, fraction: next, kind: .annual))
        }
        try? context.save()
    }
}
