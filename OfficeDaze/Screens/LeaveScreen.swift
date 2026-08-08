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

    private var attendedDays: Set<Day> { Self.attendedDays(from: attendance, in: month) }

    private var fractions: [Day: Double] { Self.fractions(from: leave, in: month) }

    private var result: Quota.Result {
        Self.result(month: month, fractions: fractions, attendance: attendance)
    }

    /// The three derivations the grid is drawn from, as functions of their rows
    /// rather than as closures over `@Query`.
    ///
    /// A screen's `@Query` can only be read by rendering the screen, and a
    /// rendered SwiftUI view on iOS 26 draws into a display list with no UIViews
    /// and — without VoiceOver actually running — no accessibility tree either,
    /// so a test can watch the body execute and still not see a single one of
    /// these answers. Taking the rows as arguments is what makes "which days did
    /// August's grid think were attended" a question with an answer, and these
    /// are the same three that wave 1 had to stop recomputing per cell.
    static func attendedDays(from attendance: [AttendanceDay], in month: Month) -> Set<Day> {
        Set(attendance.filter { month.contains($0.day) }.map(\.day))
    }

    /// Day to fraction. Summed rather than overwritten so two half rows for one
    /// day read as a whole day rather than the last one written.
    static func fractions(from leave: [LeaveDay], in month: Month) -> [Day: Double] {
        leave
            .filter { $0.kind != .bankHoliday && month.contains($0.day) }
            .reduce(into: [:]) { $0[$1.day, default: 0] += $1.fraction }
    }

    /// Bank holidays are deliberately not passed as leave: `Quota` derives them
    /// itself and has already taken them out of working days, so handing them
    /// over again would deduct the same day twice. That is also why `fractions`
    /// filters `.bankHoliday` rows out on the way in.
    static func result(
        month: Month,
        fractions: [Day: Double],
        attendance: [AttendanceDay],
        today: Day = .today
    ) -> Quota.Result {
        Quota.calculate(.init(
            month: month,
            leave: fractions.map { Quota.DayFraction($0.key, $0.value) },
            attendance: attendance
                .filter { month.contains($0.day) }
                .map { Quota.DayFraction($0.day, $0.fraction) },
            today: today
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
    private var canStepBack: Bool { Self.canStepBack(from: month, in: context) }

    /// Fails open. A store that will not answer is a store that knows of no
    /// records, and the honest floor for "no records" is today's month — but
    /// refusing to move at all on a read error would strand someone in whatever
    /// month they were standing in, which is a worse answer than letting them
    /// step back into an empty grid.
    static func canStepBack(from month: Month, in context: ModelContext) -> Bool {
        guard let recorded = try? Store.recordedDays(in: context) else { return true }
        return MonthRange.canStepBack(from: month, recorded: recorded, today: .today)
    }

    private var monthStepper: some View {
        HStack {
            stepButton(Self.step(months: -1), months: -1, enabled: canStepBack)
            Spacer(minLength: 8)
            Text(month.text)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Palette.text)
            Spacer(minLength: 8)
            stepButton(Self.step(months: 1), months: 1)
        }
        .font(.system(size: 17))
        .foregroundStyle(Palette.tertiary)
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
    }

    /// These two chevrons are the only way to change month on this screen, and
    /// as bare 17pt glyphs under `.buttonStyle(.plain)` they were a ~20×17pt
    /// target — the button gets exactly its content's bounds, so a near miss
    /// landed on the card behind and did nothing. The frame goes *inside* the
    /// label, where it widens the hit region, rather than outside it, where it
    /// would only move the button about. `Metrics.minimumRow` is the same 44pt
    /// floor every tappable row in the app already honours.
    ///
    /// The label matters as much as the size: without it VoiceOver reads the SF
    /// Symbol name, so the control that moves you through the year announces
    /// itself as "chevron.left".
    ///
    /// The glyph and the words come from `step(months:)` as a pair rather than
    /// as two literals typed at each call site, because the failure this label
    /// exists to prevent is the two chevrons ending up saying the same thing —
    /// and two literals in two places is exactly how that happens.
    private func stepButton(
        _ step: (symbol: String, label: String), months: Int, enabled: Bool = true
    ) -> some View {
        Button { month = month.adding(months: months) } label: {
            Image(systemName: step.symbol)
                .opacity(enabled ? 1 : 0.3)
                .frame(minWidth: Metrics.minimumRow, minHeight: Metrics.minimumRow)
                .contentShape(Rectangle())
        }
        .disabled(!enabled)
        .accessibilityLabel(step.label)
    }

    /// Which glyph each chevron draws and what VoiceOver says instead of it.
    ///
    /// Without the label VoiceOver reads the SF Symbol name, so the control that
    /// moves you through the year announces itself as "chevron.left" — which
    /// names a shape, not a destination, and is identical in kind to the "Office
    /// colour" sameness this review started from.
    nonisolated static func step(months: Int) -> (symbol: String, label: String) {
        months < 0 ? ("chevron.left", "Previous month") : ("chevron.right", "Next month")
    }

    /// Indexed rather than `id: \.self`, because "T" and "S" each appear twice
    /// and `ForEach` requires identifiers unique across the collection — with
    /// duplicates SwiftUI logs an identity warning and the diffing behaviour
    /// for the colliding elements is undefined, on the one row whose job is to
    /// line seven letters up against seven columns.
    ///
    /// Hidden from VoiceOver: seven single letters read out between the month
    /// and the grid are noise, and the cells below now name their own dates.
    private var weekdayHeadings: some View {
        HStack(spacing: 4) {
            ForEach(Array(["M", "T", "W", "T", "F", "S", "S"].enumerated()), id: \.offset) { _, day in
                Text(day)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
        .accessibilityHidden(true)
    }

    /// Weeks start on Monday — `Day.calendar` is set that way, and a working
    /// week that starts on Sunday puts the weekend in the middle of the grid.
    ///
    /// The three collections are read into locals once here and threaded down
    /// as `LeaveCell` values. They used to be computed properties that the cell
    /// builder re-read: `bankHolidays` twice per cell and `attendedDays` three
    /// times, which on a 31-day month meant 62 full `englandAndWales(year:)`
    /// derivations — each one several `Month.days` builds and a few hundred
    /// Calendar operations — for a grid whose contents cannot change halfway
    /// through drawing it. Booking a fortnight off is a dozen taps, and every
    /// tap saves the context, invalidates the `@Query` and re-runs `body`.
    private var grid: some View {
        let days = month.days
        let leading = Self.leadingBlanks(before: days.first!)
        let holidays = bankHolidays
        let attended = attendedDays
        let booked = fractions
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 4) {
            ForEach(0..<leading, id: \.self) { _ in Color.clear.frame(height: 40) }
            ForEach(days, id: \.self) { day in
                cell(LeaveCell(
                    day: day,
                    fraction: booked[day],
                    bankHolidays: holidays,
                    attended: attended
                ))
            }
        }
    }

    /// How many empty squares the 1st is pushed along by.
    ///
    /// `Day.weekday` is Foundation's 1 = Sunday, and the grid's first column is
    /// Monday, so the shift is +5 and not −1. Getting it wrong by one moves
    /// every date in the month under the wrong letter — a grid that is still
    /// perfectly plausible to look at, which is why it is worth an assertion
    /// rather than an eyeball.
    nonisolated static func leadingBlanks(before first: Day) -> Int {
        (first.weekday + 5) % 7
    }

    /// The state itself lives in `LeaveCell`; this only paints it. Everything a
    /// sighted user reads off the background colour is also said in words on
    /// the button and marked with a glyph under the date, because colour alone
    /// is a channel a colourblind user does not have and VoiceOver cannot read.
    private func cell(_ cell: LeaveCell) -> some View {
        Button {
            Self.toggle(cell, leave: leave, in: context)
        } label: {
            VStack(spacing: 1) {
                Text("\(cell.day.day)")
                    .font(.system(size: 15, weight: cell.fraction != nil ? .semibold : .regular))
                    .monospacedDigit()
                // Always present, so the dates sit on one line across the grid
                // whether or not their day carries a marker.
                Text(cell.marker ?? "")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(height: 10)
            }
            .foregroundStyle(Self.foreground(cell))
            .frame(maxWidth: .infinity)
            .frame(height: 40)
            .background(Self.background(cell))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!cell.isEnabled)
        .accessibilityLabel(cell.accessibilityLabel)
        .accessibilityValue(cell.accessibilityValue)
        .accessibilityHint(cell.accessibilityHint)
    }

    /// Leave wins over the ground it sits on, in both channels: a day booked off
    /// and later attended is drawn as leave, because leave is what the tap acts
    /// on, and drawing it green would say the cell does nothing.
    static func foreground(_ cell: LeaveCell) -> Color {
        if cell.fraction != nil { return Palette.warningText }
        switch cell.ground {
        case .attended: return Palette.successText
        case .bankHoliday, .weekend: return Palette.tertiary
        case .working: return Palette.text
        }
    }

    static func background(_ cell: LeaveCell) -> Color {
        if let fraction = cell.fraction {
            // A half day is the same amber at half strength — the same thing,
            // less of it. The strength is the decorative half of the signal;
            // the "½" marker is the half that survives without colour.
            return Palette.warningSurface.opacity(fraction >= 1 ? 1 : 0.5)
        }
        switch cell.ground {
        case .attended: return Palette.successSurface
        case .bankHoliday, .weekend: return Palette.hairline.opacity(0.6)
        case .working: return .clear
        }
    }

    /// `result` is a computed property that runs a whole `Quota.calculate` —
    /// which derives the year's bank holidays and re-sums the leave — so it is
    /// read once into a local here and handed to `explanation`. It used to be
    /// read eight times to draw this one card.
    private var target: some View {
        let result = self.result
        return Card(padding: EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16)) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Target \(result.target) for \(month.text)")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Palette.text)
                Text(Self.explanation(result))
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
    nonisolated static func explanation(_ result: Quota.Result) -> String {
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
            + "prem are already outside the count, so they can't be booked off. "
            // The last sentence is the screen saying out loud what the cell now
            // allows: a day booked off in advance and then turned up for keeps
            // its leave, and the only place that leave can be taken off is
            // here. Without it the amber cell looks like one of the days the
            // sentence before has just called untappable.
            + "A day you were on prem can still have leave taken off it."
        )
        .font(.system(size: 13))
        .lineSpacing(3)
        .foregroundStyle(Palette.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
    }

    /// Half days survive, whole days lose the ".0". `2.5 days' leave` and
    /// `2 days' leave` both have to come out of the same sentence.
    nonisolated static func number(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...1)))
    }

    /// The cell decided what the tap does; this only carries it out. In
    /// particular the "what" is not recomputed from `fractions` here — the cell
    /// on screen and the write it performs have to agree, and the day whose
    /// leave can only be cleared is exactly the case where recomputing the
    /// cycle would book leave the screen refuses to offer.
    static func toggle(_ cell: LeaveCell, leave: [LeaveDay], in context: ModelContext) {
        let existing = leave.filter { $0.kind != .bankHoliday && $0.day == cell.day }
        // The rows are replaced rather than edited: a day that somehow holds
        // two of them collapses to one on the next tap.
        existing.forEach(context.delete)
        if case .book(let fraction) = cell.tap {
            context.insert(LeaveDay(day: cell.day, fraction: fraction, kind: .annual))
        }
        try? context.save()
    }
}

/// One square of the leave grid: what the day is, and what tapping it does.
///
/// Pulled out of the view as a pure value for two reasons. The states are
/// carried on screen almost entirely by a background colour, and a colour is
/// the one thing a test cannot ask a SwiftUI view about — so the decision is
/// made here, where it can be asserted on, and the view is left painting it.
/// And the rule that a day may not be *given* leave is not the same rule as a
/// day may not have its leave *taken back*; conflating the two is what made a
/// day booked off and later attended into an amber cell that would not clear.
nonisolated struct LeaveCell: Equatable {

    /// What the day is underneath any leave booked on it.
    ///
    /// Leave sits on top of this rather than replacing it, because the two are
    /// independent facts recorded by different parts of the app: nothing stops
    /// `BookingStore.recordAttendance` writing an attendance row for a day the
    /// holiday calendar already has leave on, and when that happens the screen
    /// has to keep saying both.
    enum Ground: Equatable {
        case working
        case attended
        case bankHoliday
        case weekend
    }

    /// What a tap on the cell writes.
    enum Tap: Equatable {
        /// Replace the day's leave with this fraction — 1 for a whole day off,
        /// 0.5 for a half.
        case book(Double)
        /// Delete the day's leave rows.
        case clear
        /// Nothing to do; the cell is disabled.
        case inert
    }

    let day: Day
    let ground: Ground
    /// Leave already booked on the day: 1 for a whole day, 0.5 for a half, nil
    /// for none. Summed across rows by the caller, so two halves read as one.
    let fraction: Double?

    init(day: Day, fraction: Double?, bankHolidays: Set<Day>, attended: Set<Day>) {
        self.day = day
        self.fraction = fraction
        // Attended first: a Saturday that was worked and recorded is a day you
        // were there, and saying "weekend" about it would be answering a
        // different question than the one the cell is being asked.
        // swiftlint:disable statement_position
        // The rule wants `} else`, which is right for statements and wrong for
        // an if-expression: cuddling these puts four branches on one 155-column
        // line. One branch per line is the whole point of the form.
        self.ground =
            if attended.contains(day) { .attended }
            else if bankHolidays.contains(day) { .bankHoliday }
            else if day.isWeekend { .weekend }
            else { .working }
        // swiftlint:enable statement_position
    }

    /// A day leave can be *added* to — the same rule as `LeaveCycle.editable`,
    /// which is where the reasoning lives.
    var isBookable: Bool { ground == .working }

    /// Leave that exists can always be taken back, whatever the day has since
    /// become. This is the whole fix for the stuck amber cell: the old code
    /// disabled the button for any day that was not bookable, so a day booked
    /// off in advance and then recorded as attended — geofence, evening nudge,
    /// or "Day in the office" — was drawn in leave amber, refused every tap,
    /// and went on lowering the month's target from a screen that offered no
    /// way to remove it. Stated for every unbookable ground rather than just
    /// for `.attended`, so leave stranded on a day that later became a bank
    /// holiday cannot reintroduce the same trap in a different flavour.
    var tap: Tap {
        guard isBookable else { return fraction == nil ? .inert : .clear }
        return LeaveCycle.next(after: fraction).map(Tap.book) ?? .clear
    }

    var isEnabled: Bool { tap != .inert }

    /// The date in words. The grid gives a sighted user the month from the
    /// stepper above it; a VoiceOver user swiping cell by cell has no such
    /// header, so each cell carries its own month.
    var accessibilityLabel: String { day.dayAndMonth }

    /// Everything the background colour says, said. A whole day and a half day
    /// differ on screen only by the opacity of the same amber, which is the
    /// hardest of these to see and the easiest to state.
    var accessibilityValue: String {
        let underneath = switch ground {
        case .working: "No leave"
        case .attended: "On prem"
        case .bankHoliday: "Bank holiday"
        case .weekend: "Weekend"
        }
        guard let fraction else { return underneath }
        let booked = fraction >= 1 ? "Whole day's leave" : "Half day's leave"
        // Both facts, in the order the screen ranks them: the leave is what the
        // cell is drawn as and what a tap acts on, the ground is why it will go
        // no further round the cycle.
        return isBookable ? booked : "\(booked), \(underneath.lowercased())"
    }

    /// Named after what happens, not after the gesture, because the cycle's
    /// next step is not guessable from the cell and "clear" on an attended day
    /// is the one action the screen's own key text does not describe.
    var accessibilityHint: String {
        switch tap {
        case .book(let fraction): fraction >= 1 ? "Double tap to book the day off"
                                                : "Double tap to make it a half day"
        case .clear: "Double tap to clear the leave"
        case .inert: ""
        }
    }

    /// The non-colour channel. A glyph under the date, so whole leave, half
    /// leave and a day on prem are told apart by shape rather than by hue —
    /// which is the difference between a grid a colourblind user can read and
    /// one they cannot.
    var marker: String? {
        if let fraction { return fraction >= 1 ? "●" : "½" }
        return ground == .attended ? "✓" : nil
    }
}
