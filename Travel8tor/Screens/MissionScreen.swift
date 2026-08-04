import SwiftData
import SwiftUI

/// The month, five columns wide, Monday to Friday. Weekends are absent because
/// they are not days the target is about.
struct MissionScreen: View {
    @Environment(\.modelContext) private var context
    @State private var month = Day.today.month_

    private let copy = Copy.shared
    private let today = Day.today

    private var snapshot: QuotaService.Snapshot? {
        try? QuotaService.snapshot(for: month, today: today, in: context)
    }

    var body: some View {
        ScreenScaffold(backTitle: copy(.targets)) {
            ScreenTitleBlock(title: copy(.theMission)) {
                monthStepper
            }
        } content: {
            if let snapshot {
                VStack(alignment: .leading, spacing: 0) {
                    grid(snapshot)
                    legend.padding(.top, 14)
                    derivation(snapshot).padding(.top, 20)
                    logLeaveRow.padding(.top, 11)
                    shortfallPanel(snapshot).padding(.top, 11)
                }
            }
        }
    }

    private var monthStepper: some View {
        HStack(spacing: 12) {
            Button { month = step(month, by: -1) } label: {
                Text("‹").t8(.stepper).foregroundStyle(Palette.boneSecondary)
            }
            Text(month.shortName)
                .t8(.stepper)
                .foregroundStyle(Palette.bone)
                .monospacedDigit()
            Button { month = step(month, by: 1) } label: {
                Text("›").t8(.stepper).foregroundStyle(Palette.boneSecondary)
            }
        }
        .buttonStyle(.plain)
    }

    private func step(_ month: Month, by delta: Int) -> Month {
        let total = month.year * 12 + (month.month - 1) + delta
        return Month(year: total / 12, month: total % 12 + 1)
    }

    // MARK: Grid

    private func grid(_ snapshot: QuotaService.Snapshot) -> some View {
        let cells = MissionGrid.cells(.init(
            month: month,
            attended: snapshot.attendedDays,
            deskBookingDays: snapshot.deskBookingDays,
            leave: Set(snapshot.leaveDays),
            today: today
        ))

        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 5), count: 5), spacing: 5) {
            ForEach(["MON", "TUE", "WED", "THU", "FRI"], id: \.self) { name in
                Text(name)
                    .t8(.gridHeader)
                    .foregroundStyle(Palette.bone.opacity(0.3))
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 4)
            }
            ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
                if let cell {
                    dayCell(cell)
                } else {
                    Color.clear.aspectRatio(1, contentMode: .fit)
                }
            }
        }
    }

    private func dayCell(_ cell: MissionGrid.Cell) -> some View {
        // `Color.clear` is flexible, so it takes the full column width and
        // `aspectRatio` then fixes the height to match. Putting `aspectRatio`
        // on the VStack instead sizes it from the text's intrinsic height —
        // which is small, and makes the tagged rows taller than the rest.
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                VStack(spacing: 3) {
                    Text(cell.figure)
                        .t8(.gridFigure)
                        .foregroundStyle(figureColour(cell.state))
                        .monospacedDigit()
                    if let tag = tag(cell.state) {
                        Text(tag)
                            .t8(.gridTag)
                            .foregroundStyle(tagColour(cell.state))
                    }
                }
            }
            .background(fill(cell.state))
            .overlay { Rectangle().strokeBorder(border(cell.state), lineWidth: Metrics.hairline) }
    }

    private func fill(_ state: MissionGrid.State) -> Color {
        switch state {
        case .attended: Palette.desk
        case .booked: Palette.desk.opacity(0.16)
        default: .clear
        }
    }

    private func border(_ state: MissionGrid.State) -> Color {
        switch state {
        case .attended: Palette.desk
        case .booked: Palette.desk.opacity(0.55)
        case .leave: Palette.stay.opacity(0.45)
        case .bankHoliday: Palette.rail.opacity(0.3)
        case .ordinary: Palette.rail.opacity(0.2)
        }
    }

    private func figureColour(_ state: MissionGrid.State) -> Color {
        switch state {
        case .attended: Palette.ground
        case .booked: Palette.desk
        case .leave: Palette.stay
        case .bankHoliday: Palette.rail.opacity(0.55)
        case .ordinary: Palette.bone.opacity(0.4)
        }
    }

    private func tag(_ state: MissionGrid.State) -> String? {
        switch state {
        case .attended: copy(.attendedTag)
        case .booked: copy(.bookedTag)
        case .leave: "LEAVE"
        case .bankHoliday: "BANK"
        case .ordinary: nil
        }
    }

    private func tagColour(_ state: MissionGrid.State) -> Color {
        state == .attended ? Palette.ground.opacity(0.7) : figureColour(state).opacity(0.8)
    }

    private var legend: some View {
        HStack(spacing: 12) {
            legendItem(copy(.terminated), fill: Palette.desk, border: Palette.desk)
            legendItem("PENDING", fill: Palette.desk.opacity(0.16), border: Palette.desk.opacity(0.55))
            legendItem("LEAVE", fill: .clear, border: Palette.stay.opacity(0.45))
            Spacer(minLength: 0)
        }
    }

    private func legendItem(_ title: String, fill: Color, border: Color) -> some View {
        HStack(spacing: 6) {
            Rectangle()
                .fill(fill)
                .frame(width: 9, height: 9)
                .overlay { Rectangle().strokeBorder(border, lineWidth: Metrics.hairline) }
            Text(title)
                .t8(.legend)
                .foregroundStyle(Palette.bone.opacity(0.4))
        }
    }

    // MARK: Derivation and the rest

    private func derivation(_ snapshot: QuotaService.Snapshot) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            SectionKicker(text: "TARGET DERIVATION", colour: Palette.bone.opacity(0.4))
            DerivationPanel(
                lines: MissionGrid.derivation(snapshot.result, leave: snapshot.leaveDays)
                    .enumerated()
                    .map { index, line in
                        let isTarget = index == MissionGrid.derivation(
                            snapshot.result, leave: snapshot.leaveDays
                        ).count - 1
                        let isLeave = line.label.hasPrefix("LEAVE")
                        return DerivationPanel.Line(
                            label: line.label,
                            value: line.value,
                            labelColour: isTarget ? Palette.desk : Palette.boneSecondary,
                            valueColour: isTarget
                                ? Palette.desk
                                : (isLeave ? Palette.stay : Palette.bone)
                        )
                    }
            )
        }
        .padding(.top, 7)
    }

    private var logLeaveRow: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text("LOG ANNUAL LEAVE")
                    .t8(.rowAction)
                    .foregroundStyle(Palette.bone)
                Text("LOWERS THE MONTH'S TARGET")
                    .t8(.rowActionNote)
                    .foregroundStyle(Palette.bone.opacity(0.4))
            }
            Spacer(minLength: 0)
            // Writing leave lands in stage 6 with settings.
            Text("+")
                .font(.custom(T8Fonts.regular, size: 18))
                .foregroundStyle(Palette.bone.opacity(0.4))
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 15)
        .overlay { Rectangle().strokeBorder(Palette.rail.opacity(0.25), lineWidth: Metrics.hairline) }
    }

    private func shortfallPanel(_ snapshot: QuotaService.Snapshot) -> some View {
        let result = snapshot.result
        let shortfall = Int(result.shortfall.rounded())

        return VStack(alignment: .leading, spacing: 9) {
            Text("\(String(format: "%02d", shortfall)) \(copy(.leftAlive)) ▪ \(String(format: "%02d", result.daysToRun)) DAYS TO RUN")
                .t8(.incompleteHeader)
                .foregroundStyle(Palette.rail)
            Text(prose(shortfall: shortfall, daysToRun: result.daysToRun))
                .t8(.panelBody)
                .foregroundStyle(Palette.bone.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.rail.opacity(0.08))
        .overlay { Rectangle().strokeBorder(Palette.rail.opacity(0.45), lineWidth: Metrics.hairline) }
    }

    /// The figure is your own record, not your employer's. So the prose says
    /// what is left to do, and never claims compliance.
    private func prose(shortfall: Int, daysToRun: Int) -> String {
        if shortfall == 0 {
            return "TARGET MET. NOTHING FURTHER REQUIRED THIS MONTH."
        }
        if shortfall > daysToRun {
            return "NOT ACHIEVABLE. \(shortfall) DAYS REQUIRED, \(daysToRun) WORKING DAYS REMAIN."
        }
        let word = shortfall == 1 ? "ONE REMAINING DAY REQUIRES A DESK" : "\(shortfall) REMAINING DAYS REQUIRE DESKS"
        return "STILL ACHIEVABLE. \(word). EVENING NUDGE ARMED FOR ANY DAY WITH NO BOOKING."
    }
}

nonisolated extension T8Font {
    static let stepper = T8Font(11, bold: true)
    static let gridHeader = T8Font(8.5, tracking: 0.12)
    static let gridFigure = T8Font(13, bold: true)
    static let gridTag = T8Font(6.5, tracking: 0.08)
    static let legend = T8Font(9, tracking: 0.08)
    static let rowAction = T8Font(11, bold: true, tracking: 0.10)
    static let rowActionNote = T8Font(9.5, tracking: 0.06)
}
