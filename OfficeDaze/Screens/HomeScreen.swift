import SwiftData
import SwiftUI

/// The gauge, the month's split by office, and every booking in it.
struct HomeScreen: View {
    @Environment(\.modelContext) private var context
    @Environment(CaptureCoordinator.self) private var capture

    @Query(sort: \Office.name) private var offices: [Office]
    @Query(sort: \DeskBooking.date) private var bookings: [DeskBooking]
    @Query private var attendance: [AttendanceDay]
    @Query private var planned: [PlannedDay]

    /// Which month the gauge is showing. Starts on today's, and the stepper
    /// moves it — the store holds every month at once, so this is the only
    /// state the screen needs.
    @State private var month = Day.today.month_

    @State private var camera = false

    /// The booking row currently swiped open, if any. One at a time, which is
    /// why it lives here rather than in each row.
    @State private var openRow: UUID?

    /// Which kind of manual entry the header's menu is adding, if any.
    @State private var adding: ManualEntry?

    /// The booking a swipe sent to the editor, if any.
    @State private var editing: DeskBooking?

    enum ManualEntry: String, Identifiable {
        case booking, attendance
        var id: String { rawValue }
    }

    /// A row in the month's list.
    ///
    /// Most are desk bookings. The other kind is a day on prem with no desk
    /// behind it — a workshop, a meeting, a visit — which has to appear here or
    /// the gauge counts a day the list below it cannot account for.
    enum Entry: Identifiable {
        case booking(DeskBooking)
        case attended(AttendanceDay)
        case planned(PlannedDay)

        var id: UUID {
            switch self {
            case .booking(let booking): booking.id
            case .attended(let day): day.id
            case .planned(let day): day.id
            }
        }

        var day: Day {
            switch self {
            case .booking(let booking): booking.day
            case .attended(let record): record.day
            case .planned(let record): record.day
            }
        }

        /// The booking behind this row, for the rows that have one.
        var booking: DeskBooking? {
            if case .booking(let booking) = self { return booking }
            return nil
        }
    }

    private var monthBookings: [DeskBooking] {
        bookings.filter { month.contains($0.day) }
    }

    private var monthEntries: [Entry] {
        Self.entries(
            bookings: bookings, attendance: attendance, planned: planned, in: month
        )
    }

    /// The month's list: every booking, plus every day on prem — worked or
    /// intended — that no booking already accounts for.
    ///
    /// Static so the rule worth getting right can be tested: one day at one
    /// office is one row however many records describe it. A booked day speaks
    /// for its own attendance, and a planned day that has since been worked is
    /// spoken for by the attendance. Everything is matched on day and office,
    /// the same pairing `isAttended` uses, so no two parts of this screen can
    /// disagree about which days are already covered.
    static func entries(
        bookings: [DeskBooking], attendance: [AttendanceDay],
        planned: [PlannedDay], in month: Month
    ) -> [Entry] {
        let booked = bookings.filter { month.contains($0.day) }
        func isBooked(_ day: Day, _ officeID: UUID?) -> Bool {
            booked.contains { $0.day == day && $0.officeID == officeID }
        }

        let attended = attendance.filter {
            month.contains($0.day) && !isBooked($0.day, $0.officeID)
        }
        let intended = planned.filter { record in
            month.contains(record.day)
                && !isBooked(record.day, record.officeID)
                // Turning up is what converts it. The attendance row is the
                // truer record of the same day, so the plan stops being shown.
                && !attended.contains {
                    $0.day == record.day && $0.officeID == record.officeID
                }
        }
        return (
            booked.map(Entry.booking)
                + attended.map(Entry.attended)
                + intended.map(Entry.planned)
        ).sorted { $0.day < $1.day }
    }

    private var snapshot: QuotaService.Snapshot? {
        try? QuotaService.snapshot(for: month, today: .today, in: context)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                gaugeCard
                // Two or more, because this exists to split the month between
                // offices. With one there is nothing to split: the bar would be
                // one colour end to end, saying the number the gauge has just
                // said with a name on it.
                let shares = officeShares
                if shares.count > 1 {
                    officeSplit(shares).padding(.top, Metrics.cardGap)
                }
                bookingsSection.padding(.top, Metrics.sectionGap)
            }
            .padding(.horizontal, Metrics.screenPadding)
            .padding(.top, 6)
            .padding(.bottom, 30)
        }
        .background(Palette.ground)
        .navigationTitle("Office Daze")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    SettingsScreen()
                } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("Settings")
            }
        }
        // Sheets rather than pushes: a NavigationLink inside a Menu does not
        // reliably push, and the capture flow already presents the booking
        // editor this way.
        .sheet(item: $adding) { which in
            NavigationStack {
                switch which {
                case .booking: BookingEditorScreen()
                case .attendance: AttendanceEditorScreen()
                }
            }
        }
        // The same editor the menu opens, handed the row that was swiped —
        // a sheet rather than a push for the reason above.
        .sheet(item: $editing) { booking in
            NavigationStack { BookingEditorScreen(booking: booking) }
        }
        .fullScreenCover(isPresented: $camera) {
            // Full screen, because a camera in a card with the app showing
            // round the edges is a viewfinder you have to aim through.
            BookingScanner { data in
                Task { await capture.receive(photo: data) }
            }
        }
    }

    // MARK: The gauge

    private var gaugeCard: some View {
        Card(padding: EdgeInsets(top: 12, leading: 16, bottom: 16, trailing: 16)) {
            VStack(spacing: 0) {
                monthStepper
                AttendanceGauge(
                    attended: snapshot?.result.attended ?? 0,
                    booked: snapshot?.result.forecast ?? 0,
                    target: snapshot?.result.target ?? 0
                )
                .padding(.top, 2)
                if let result = snapshot?.result {
                    // Where the month is, permanently. The app is entirely
                    // about a deadline, and the only place the remaining month
                    // appeared was the trailing half of the amber strip — which
                    // rendered in one state out of four, so on track or met it
                    // vanished. That is exactly when you want to know whether
                    // you can stop, or whether the days you have booked still
                    // have room to land.
                    Text(Self.dateLine(result, month: month, today: .today))
                        .font(.system(size: 13))
                        .monospacedDigit()
                        .foregroundStyle(Palette.secondary)
                        .padding(.top, 6)
                    shortfallStrip(result).padding(.top, 10)
                    // Tapping the sentence opens the thing it explains. The
                    // target moves because of leave, so leave is where the
                    // explanation should lead — and it is the best answer in
                    // the app to "why has my target moved", which is worth more
                    // than twelve-point grey with nothing saying it is a link.
                    NavigationLink {
                        LeaveScreen(month: month)
                    } label: {
                        HStack(spacing: 3) {
                            Text(Self.targetExplanation(result))
                                .font(.system(size: 13))
                                .foregroundStyle(Palette.tint)
                                .multilineTextAlignment(.center)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Palette.tint.opacity(0.6))
                        }
                        .padding(.top, 11)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// Back stops at the first month with anything in it; forward does not stop
    /// at all. See `MonthRange` for why the two directions differ.
    private var canStepBack: Bool {
        guard let recorded = try? Store.recordedDays(in: context) else { return true }
        return MonthRange.canStepBack(from: month, recorded: recorded, today: .today)
    }

    private var isThisMonth: Bool { month == Day.today.month_ }

    private var monthStepper: some View {
        HStack {
            stepButton("chevron.left", enabled: canStepBack) {
                month = month.adding(months: -1)
            }
            Spacer(minLength: 8)
            // The way home. Step to December and getting back was four taps on
            // a chevron; the month name is the obvious thing to press and did
            // nothing. Dimmed rather than hidden when you are already here, so
            // the stepper keeps its shape and the name does not move.
            Button {
                month = Day.today.month_
            } label: {
                Text(month.text)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(isThisMonth ? Palette.text : Palette.tint)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 8)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isThisMonth)
            .accessibilityLabel(isThisMonth ? month.text : "\(month.text), back to this month")
            Spacer(minLength: 8)
            stepButton("chevron.right") { month = month.adding(months: 1) }
        }
    }

    /// A chevron that does nothing says so by fading rather than by
    /// disappearing: the stepper keeps its shape, and the month title stays
    /// centred between two arrows rather than sliding across the card at the
    /// edge of the range.
    private func stepButton(
        _ symbol: String, enabled: Bool = true, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(Palette.tertiary)
                .opacity(enabled ? 1 : 0.3)
                .padding(.vertical, 6)
                .padding(.horizontal, 10)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    /// `4 August · 18 working days left`, and the second half of the sentence
    /// the dial is telling. Another month is not a deadline you are inside, so
    /// it says how big it was rather than how much of it is left.
    static func dateLine(_ result: Quota.Result, month: Month, today: Day) -> String {
        guard month == today.month_ else {
            return "\(result.workingDays) working days"
        }
        let left = result.daysToRun == 1 ? "1 working day left" : "\(result.daysToRun) working days left"
        return "\(today.dayAndMonth) · \(left)"
    }

    /// All the judgement in the app, in one strip, from `Quota.Standing`.
    ///
    /// Four states rather than three. "On track" loses its green: green claimed
    /// the month was done when it was only arranged, which is the same
    /// conflation the whole AttendanceDay / DeskBooking split exists to
    /// prevent. And red now means something — the target cannot be reached this
    /// month — rather than being on screen for the first fortnight of every one.
    @ViewBuilder
    private func shortfallStrip(_ result: Quota.Result) -> some View {
        switch result.standing {
        case .met:
            StatusStrip(tone: .success, leading: "Target met", dot: true)
        case _ where month < Day.today.month_:
            // A month that has finished is not a warning, whatever it came to.
            // Every state below is written in the present tense about a
            // deadline you are still inside, and "Can't reach 8 this month"
            // under the heading July is both wrong and the app's one red — on
            // screen for every month you ever fell short in.
            StatusStrip(
                tone: .neutral,
                leading: "Fell \(number(Double(result.target) - result.attended)) short",
                trailing: "\(number(result.attended)) of \(result.target)"
            )
        case .onTrack:
            StatusStrip(
                tone: .neutral,
                leading: "On track",
                trailing: "\(number(result.forecast)) booked"
            )
        case .behind:
            let text = Self.shortfallText(result)
            StatusStrip(tone: .warning, leading: text.leading, trailing: text.trailing)
        case .unreachable:
            StatusStrip(
                tone: .danger,
                leading: "Can't reach \(result.target) this month",
                trailing: Self.daysLeftText(result)
            )
        }
    }

    static func daysLeftText(_ result: Quota.Result) -> String {
        result.daysAvailable == 1 ? "1 day left" : "\(result.daysAvailable) days left"
    }

    /// `Target 6 — 8 days less 2 for 5 days' leave`. The one line that says
    /// where the number came from, because a target that moves without
    /// explanation reads as a bug.
    ///
    /// Leave too small to have moved anything gets a sentence of its own. The
    /// old pro-rate shifted the number a little for every day booked, so the
    /// leave was always visible in the result; blocks of five mean four days
    /// off change nothing at all, and a line that then says only "8 days a
    /// month" reads as though the four days were never recorded.
    static func targetExplanation(_ result: Quota.Result) -> String {
        let target = "Target \(result.target)"
        guard result.leaveTaken > 0 else { return "\(target) — 8 days a month" }
        let days = "\(number(result.leaveTaken)) \(result.leaveTaken == 1 ? "day's" : "days'") leave"
        guard result.relief > 0 else { return "\(target) — \(days); 5 days takes 2 off" }
        return "\(target) — 8 days less \(number(result.relief)) for \(days)"
    }

    /// The amber strip's two halves.
    ///
    /// "4 days to go" gave the size of the gap and said nothing about what was
    /// already arranged, so a month with four days lined up and four still to
    /// find read exactly like one with nothing at all. The leading half now
    /// names the action that closes the gap, and the trailing half says what is
    /// already counted toward it — and how much month is left to do it in,
    /// which is the half that matters when the two numbers stop fitting.
    ///
    /// "Booked" covers planned days too. They are distinguished on their own
    /// rows, where the difference is actionable; in a one-line summary of what
    /// is lined up, it is not.
    static func shortfallText(_ result: Quota.Result) -> (leading: String, trailing: String) {
        let short = number(result.shortfall)
        let leading = "\(short) more \(result.shortfall == 1 ? "day" : "days") to book"
        let lined = result.forecast == 0
            ? "none booked"
            : "\(number(result.forecast)) booked"
        return (leading, "\(lined) · \(result.daysToRun) days left")
    }

    static func number(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...1)))
    }

    private func number(_ value: Double) -> String { Self.number(value) }

    // MARK: Offices

    /// How the gauge's own number divides between the buildings.
    ///
    /// It was two cards reading "London 3" and "Brussels 1" — three what, and
    /// two cards read as two independent facts when they are one figure split
    /// in two. A single bar says the true thing: this is the same number, and
    /// this is where it went. The days are named, because a bare number on a
    /// card was the other half of the problem.
    private func officeSplit(_ shares: [(office: Office, days: Double)]) -> some View {
        let total = shares.reduce(0) { $0 + $1.days }
        return Card(padding: EdgeInsets(top: 13, leading: 14, bottom: 13, trailing: 14)) {
            VStack(alignment: .leading, spacing: 9) {
                GeometryReader { proxy in
                    HStack(spacing: 2) {
                        ForEach(shares, id: \.office.id) { share in
                            Capsule()
                                .fill(Color(officeHex: share.office.colourHex))
                                .frame(width: max(4, proxy.size.width * share.days / total))
                        }
                    }
                }
                .frame(height: 10)

                // Wrapping rather than one line: six offices is the palette's
                // limit and four already overflow a narrow phone.
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 130), alignment: .leading)],
                    alignment: .leading,
                    spacing: 6
                ) {
                    ForEach(shares, id: \.office.id) { share in
                        HStack(spacing: 6) {
                            OfficeDot(colourHex: share.office.colourHex)
                            Text(share.office.name)
                                .font(.system(size: 13))
                                .foregroundStyle(Palette.rowLabel)
                                .lineLimit(1)
                            Text(Self.dayCount(share.days))
                                .font(.system(size: 13, weight: .medium))
                                .monospacedDigit()
                                .foregroundStyle(Palette.text)
                        }
                    }
                }
            }
        }
    }

    /// Offices with days against them this month, biggest first. An office with
    /// nothing recorded has no share of the figure and no segment in the bar.
    private var officeShares: [(office: Office, days: Double)] {
        offices
            .map { ($0, snapshot?.attendedByOffice[$0.id] ?? 0) }
            .filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
    }

    static func dayCount(_ days: Double) -> String {
        "\(number(days)) \(days == 1 ? "day" : "days")"
    }

    // MARK: Bookings

    private var bookingsSection: some View {
        VStack(spacing: 8) {
            // One plus, three labelled ways in.
            //
            // It was two unlabelled icons side by side, and a camera in a list
            // header reads as "photograph this list" rather than "read a
            // booking off a screen". The menu labels were already written and
            // already good; they just could not be seen until something was
            // pressed. Scanning goes first because it is the fastest way in —
            // the confirmation is nearly always on a monitor in front of you,
            // and there is not even a shutter to press.
            SectionHeader(title: "This month") {
                Menu {
                    Button("Scan a booking", systemImage: "camera") { camera = true }
                    Button("Desk booking", systemImage: "square.and.pencil") {
                        adding = .booking
                    }
                    Button("Day in the office", systemImage: "building.2") {
                        adding = .attendance
                    }
                } label: {
                    headerIcon("plus")
                }
                .accessibilityLabel("Add")
                .foregroundStyle(Palette.tint)
            }
            if monthEntries.isEmpty {
                emptyBookings
            } else {
                RowStack(items: monthEntries, inset: 38) { entry in
                    SwipeActions(
                        id: entry.id,
                        open: $openRow,
                        // Only a booking has anything to edit. An attendance
                        // record is a day and an office, and the screen that
                        // takes those can only add another one.
                        edit: entry.booking.map { booking in { editing = booking } },
                        delete: { delete(entry) }
                    ) {
                        VStack(spacing: 0) {
                            switch entry {
                            case .booking(let booking):
                                HStack(spacing: 0) {
                                    NavigationLink {
                                        BookingDetailScreen(booking: booking)
                                    } label: {
                                        bookingRow(booking)
                                    }
                                    .buttonStyle(.plain)
                                    // Outside the link, because it goes
                                    // somewhere else: an amber dot that only
                                    // said "something here could not be read"
                                    // left the fixing four taps away.
                                    if booking.needsChecking {
                                        checkingButton(booking)
                                    }
                                }
                            case .attended(let record):
                                // No detail screen: there is no desk, no floor
                                // and no hours to show. The row is the whole
                                // record.
                                deskless(
                                    officeID: record.officeID, day: record.day,
                                    status: "Attended", tone: Palette.met
                                )
                            case .planned(let record):
                                deskless(
                                    officeID: record.officeID, day: record.day,
                                    status: unanswered(entry) ? nil : "Planned",
                                    tone: Palette.secondary
                                )
                            }
                            if unanswered(entry) { wereYouThere(entry) }
                        }
                    }
                }
            }
        }
    }

    /// Two different empties. No offices at all is a setup problem and says so;
    /// an empty month is just an empty month.
    private var emptyBookings: some View {
        Card(padding: EdgeInsets(top: 18, leading: 16, bottom: 18, trailing: 16)) {
            VStack(spacing: 10) {
                Text(offices.isEmpty
                     ? "Add an office before booking a desk."
                     : "Nothing recorded for \(month.text).")
                    .font(.system(size: 15))
                    .foregroundStyle(Palette.secondary)
                    .multilineTextAlignment(.center)
                if offices.isEmpty {
                    NavigationLink("Add office") { OfficeEditorScreen() }
                        .font(.system(size: 16))
                        .foregroundStyle(Palette.tint)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: The question the app has to ask

    /// A day gone by that nothing has been said about.
    ///
    /// Attendance is the only record that a day was worked on prem — there is
    /// no other copy — and every route into it needs the user to act. One of
    /// those routes is a geofence, and a geofence that does not fire (phone
    /// off, Always quietly dropped, a different entrance, fifty metres too
    /// tight) leaves a day worked, booked, and counting for nothing, with
    /// nothing anywhere saying so. This is the question that catches it, put
    /// where the user is already looking.
    ///
    /// Yesterday and earlier, not today: today is still being worked, and the
    /// arrival alert and the evening nudge both have it covered.
    ///
    /// Static so the rule can be tested without a screen. The three cases are
    /// not symmetric: a day already attended is answered, a booking carries its
    /// own answer once given, and a planned day has nowhere to keep one — which
    /// is why answering it no deletes it.
    static func isUnanswered(
        _ entry: Entry, attendance: [AttendanceDay], today: Day
    ) -> Bool {
        guard entry.day < today else { return false }
        func recorded(_ day: Day, _ officeID: UUID?) -> Bool {
            attendance.contains { $0.day == day && $0.officeID == officeID }
        }
        switch entry {
        case .attended:
            return false
        case .booking(let booking):
            return !booking.notAttended && !recorded(booking.day, booking.officeID)
        case .planned(let record):
            return !recorded(record.day, record.officeID)
        }
    }

    private func unanswered(_ entry: Entry) -> Bool {
        Self.isUnanswered(entry, attendance: attendance, today: .today)
    }

    /// One tap, no navigation. A day is either counted or it is not, and the
    /// answer is worth exactly two buttons.
    private func wereYouThere(_ entry: Entry) -> some View {
        HStack(spacing: 10) {
            Text("Were you there?")
                .font(.system(size: 14))
                .foregroundStyle(Palette.warningText)
            Spacer(minLength: 8)
            answerButton("Yes", weight: .semibold) { answerYes(entry) }
            answerButton("No", weight: .regular) { answerNo(entry) }
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity)
        .background(Palette.warningSurface)
    }

    private func answerButton(
        _ title: String, weight: Font.Weight, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: weight))
                .foregroundStyle(Palette.warningText)
                .padding(.vertical, 5)
                .padding(.horizontal, 14)
                .background(Palette.card.opacity(0.7))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func answerYes(_ entry: Entry) {
        switch entry {
        case .booking(let booking):
            try? BookingStore.recordAttendance(
                day: booking.day, officeID: booking.officeID,
                source: .manual, bookingID: booking.id, in: context
            )
        case .planned(let record):
            try? BookingStore.recordAttendance(
                day: record.day, officeID: record.officeID,
                source: .manual, in: context
            )
        case .attended:
            break
        }
        answered()
    }

    /// A booking keeps its row and stops asking — the desk was reserved, which
    /// happened whether or not the day was. An intention that came to nothing
    /// leaves no trace worth keeping: it only ever counted toward the forecast,
    /// and the forecast is days ahead.
    private func answerNo(_ entry: Entry) {
        switch entry {
        case .booking(let booking):
            try? BookingStore.markNotAttended(booking, in: context)
        case .planned(let record):
            try? BookingStore.deletePlanned(record, in: context)
        case .attended:
            break
        }
        answered()
    }

    /// The evening nudge may already be holding a question about the day just
    /// answered — its content is decided while the app is awake and fires hours
    /// later. Re-deciding here is what withdraws it.
    private func answered() {
        NudgeScheduler.refresh(in: context)
    }

    private func bookingRow(_ booking: DeskBooking) -> some View {
        let office = offices.first { $0.id == booking.officeID }
        let attended = isAttended(booking)
        return HStack(spacing: 13) {
            OfficeDot(colourHex: office?.colourHex ?? "")
            VStack(alignment: .leading, spacing: 3) {
                Text(booking.day.mediumText)
                    .font(.system(size: 16))
                    .foregroundStyle(Palette.text)
                Text("\(office?.name ?? "Unknown office") · \(booking.deskID)")
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            // Nothing while the question is up: the question is the status, and
            // "Booked" beside it reads as a settled fact when the whole point is
            // that the day is still open.
            if let status = bookingStatus(booking, attended: attended) {
                Text(status)
                    .font(.system(size: 12, weight: attended ? .semibold : .regular))
                    .foregroundStyle(attended ? Palette.met : Palette.secondary)
            }
        }
        .padding(.vertical, 13)
        .padding(.leading, 16)
        .padding(.trailing, booking.needsChecking ? 4 : 16)
        .frame(minHeight: Metrics.minimumRow)
        .contentShape(Rectangle())
    }

    /// The marker, and a way to act on it. It opens the editor on the field
    /// that could not be read — the never-guess rule is the app's best idea,
    /// and following it up deserves better than row, detail, Edit, then hunt
    /// for which of five fields is blank.
    private func checkingButton(_ booking: DeskBooking) -> some View {
        Button {
            editing = booking
        } label: {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 15))
                .foregroundStyle(Palette.close)
                .padding(.vertical, 13)
                .padding(.horizontal, 14)
                .frame(minHeight: Metrics.minimumRow)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            "Check \(BookingEditorScreen.unreadFieldNames(booking.unsureFields))"
        )
    }

    private func bookingStatus(_ booking: DeskBooking, attended: Bool) -> String? {
        if attended { return "Attended" }
        if booking.notAttended { return "Not attended" }
        return unanswered(.booking(booking)) ? nil : "Booked"
    }

    /// An icon on its own is a small target, so it carries a tappable frame
    /// around it rather than only its own glyph.
    private func headerIcon(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 17))
            .frame(width: 36, height: 30)
            .contentShape(Rectangle())
    }

    /// A day on prem with no desk behind it, worked or intended. Says so where
    /// the desk id would be, rather than leaving a gap that reads as a booking
    /// half-read.
    private func deskless(
        officeID: UUID?, day: Day, status: String?, tone: Color
    ) -> some View {
        let office = offices.first { $0.id == officeID }
        return HStack(spacing: 13) {
            OfficeDot(colourHex: office?.colourHex ?? "")
            VStack(alignment: .leading, spacing: 3) {
                Text(day.mediumText)
                    .font(.system(size: 16))
                    .foregroundStyle(Palette.text)
                Text("\(office?.name ?? "Unknown office") · no desk booked")
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if let status {
                Text(status)
                    .font(.system(size: 12, weight: tone == Palette.met ? .semibold : .regular))
                    .foregroundStyle(tone)
            }
        }
        .padding(.vertical, 13)
        .padding(.horizontal, 16)
        .frame(minHeight: Metrics.minimumRow)
        .contentShape(Rectangle())
    }

    private func delete(_ entry: Entry) {
        switch entry {
        case .booking(let booking):
            // The booking only. Attendance is the record that the day was
            // worked, and it outlives the desk.
            try? BookingStore.delete(booking, in: context)
        case .attended(let record):
            try? BookingStore.deleteAttendance(record, in: context)
        case .planned(let record):
            try? BookingStore.deletePlanned(record, in: context)
        }
    }

    /// Attendance is its own record, not a flag on the booking — you can book
    /// and not go. Matching on day and office is what ties the two together.
    private func isAttended(_ booking: DeskBooking) -> Bool {
        attendance.contains { $0.day == booking.day && $0.officeID == booking.officeID }
    }
}

#Preview {
    let container = try! Store.makeInMemoryContainer(seeded: true)
    return NavigationStack { HomeScreen() }
        .modelContainer(container)
        .environment(CaptureCoordinator(context: container.mainContext))
}
