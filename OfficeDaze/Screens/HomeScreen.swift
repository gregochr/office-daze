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

    /// Which kind of manual entry the header's menu is adding, if any.
    @State private var adding: ManualEntry?

    /// The booking a row's menu sent to the editor, if any.
    @State private var editing: DeskBooking?

    /// The booking whose row was told to delete when the row is holding two
    /// records — the desk and the day worked. Set means the dialog is up
    /// asking which of the two was meant. See `deletion(for:attendance:)`.
    @State private var choosingDelete: DeskBooking?

    /// Set only by a write that did not land — one the store refused, or one
    /// that threw. Non-nil puts the alert up. See `Answer`.
    @State private var failure: String?

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

        /// Which building the row is about. Every kind of row has one, and it
        /// is half of the day-and-office pairing everything on this screen
        /// matches on — including the sentence that has to explain a refusal.
        var officeID: UUID? {
            switch self {
            case .booking(let booking): booking.officeID
            case .attended(let record): record.officeID
            case .planned(let record): record.officeID
            }
        }

        /// The booking behind this row, for the rows that have one.
        var booking: DeskBooking? {
            if case .booking(let booking) = self { return booking }
            return nil
        }
    }

    // A `monthBookings` used to sit here, filtering the desk bookings to the
    // month. Nothing read it: `entries` does that filtering itself, and has to,
    // because the rule it exists for is which *other* records a booked day
    // speaks for. A second, subtly different month filter beside it was an
    // invitation to answer the same question two ways.

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

    /// The attendance record that speaks for a booking's day, if there is one.
    ///
    /// Matched on day *and* office, the pairing `entries` and `isAttended` both
    /// use, so no two parts of this screen can disagree about which record a
    /// row is standing for. A day worked at the other building is a different
    /// row's record, and removing it from this one would delete something this
    /// row never showed.
    static func attendanceRecord(
        for booking: DeskBooking, in attendance: [AttendanceDay]
    ) -> AttendanceDay? {
        attendance.first { $0.day == booking.day && $0.officeID == booking.officeID }
    }

    /// What a row's Delete means, once you know what is behind the row.
    ///
    /// A booked day that was also turned up for is two records under one row.
    /// That single row is deliberate — see `entries` — but it cost the
    /// attendance its only delete: `deleteAttendance` has one caller in the
    /// app, this screen's `.attended` row, and `entries` never emits one for a
    /// booked day. Nothing else reached it either. The detail screen's
    /// "Attended — confirmed" strip is a label, and `recordAttendance` refuses
    /// a second row for the same day and office, so a mis-tapped "I'm here" on
    /// a booked day — the likeliest mis-tap there is, since a booked day is
    /// exactly the day the arrival alert fires on — went on counting toward the
    /// eight with no way in the app to take it back.
    ///
    /// So Delete on such a row asks which record it means rather than silently
    /// taking the desk. Every other row holds one record and still deletes
    /// without a question: an extra tap on every delete would be a worse trade
    /// than the one this buys.
    enum Deletion {
        /// One record behind the row. Delete means it, and acts.
        case record
        /// A booking, and the attendance for the same day at the same office.
        case bookingOrAttendance(AttendanceDay)
    }

    static func deletion(for entry: Entry, attendance: [AttendanceDay]) -> Deletion {
        guard let booking = entry.booking,
              let record = attendanceRecord(for: booking, in: attendance)
        else { return .record }
        return .bookingOrAttendance(record)
    }

    private var snapshot: QuotaService.Snapshot? {
        try? QuotaService.snapshot(for: month, today: .today, in: context)
    }

    var body: some View {
        // Read once, then threaded down. `snapshot` is a computed property over
        // four unfiltered fetches, so every syntactic mention of it was another
        // four — and `officeShares` mentioned it inside a map over the offices,
        // which made the bill scale with how many buildings you have. One body
        // pass now costs one snapshot rather than four plus one per office.
        let snapshot = self.snapshot
        ScrollView {
            VStack(spacing: 0) {
                gaugeCard(snapshot)
                // Two or more, because this exists to split the month between
                // offices. With one there is nothing to split: the bar would be
                // one colour end to end, saying the number the gauge has just
                // said with a name on it.
                let shares = Self.officeShares(
                    offices: offices,
                    attendedByOffice: snapshot?.attendedByOffice ?? [:]
                )
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
        // A booked day that was also worked is two records under one row, and
        // Delete has to say which of them it means. Titled rather than silent,
        // because both answers are destructive and the difference between them
        // is the whole point: one loses the desk, the other loses the day off
        // the gauge.
        .confirmationDialog(
            "Delete what?",
            isPresented: Binding(
                get: { choosingDelete != nil },
                set: { if !$0 { choosingDelete = nil } }
            ),
            titleVisibility: .visible,
            presenting: choosingDelete
        ) { booking in
            Button("The desk booking", role: .destructive) {
                // Let go of the row first. The dialog is presenting this
                // booking, and the next line deletes it out from under it.
                choosingDelete = nil
                delete(.booking(booking))
            }
            // Worded as the menu that adds one words it — you added a "Day in
            // the office", so that is the thing you are taking away.
            Button("The day in the office", role: .destructive) {
                choosingDelete = nil
                removeAttendance(from: booking)
            }
        } message: { _ in
            Text("The desk and the day worked are separate records. Removing the day takes it off the gauge and leaves the booking.")
        }
        // Where a write that did not happen is said out loud. Every button on
        // this screen that changes the store routes its refusals and its throws
        // here; before it, all of them were `try?` and a tap that did nothing
        // was indistinguishable from a tap that worked.
        .alert(
            "Not saved",
            isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(failure ?? "")
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

    /// Takes the snapshot rather than reading it: the card mentions it four
    /// times, and as a property each mention was four fetches of its own.
    private func gaugeCard(_ snapshot: QuotaService.Snapshot?) -> some View {
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
        // Formatted once. `Month.text` builds a DateFormatter and a Locale and
        // parses a format string on every call, and the label and the
        // accessibility label are the same words — so asking twice paid for the
        // most expensive routine operation in Foundation to get an answer we
        // already had.
        let title = month.text
        return HStack {
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
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(isThisMonth ? Palette.text : Palette.tint)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 8)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isThisMonth)
            .accessibilityLabel(isThisMonth ? title : "\(title), back to this month")
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
    ///
    /// Handed the already-computed split rather than reaching back for
    /// `snapshot`: the map runs once per office, and a property read inside it
    /// re-ran the whole four-fetch snapshot each time round — the one place in
    /// the screen where the cost of a re-render grew with the user's data.
    /// Taking it as a parameter is what makes that impossible to reintroduce,
    /// and it makes the ordering rule testable without a store.
    static func officeShares(
        offices: [Office], attendedByOffice: [UUID: Double]
    ) -> [(office: Office, days: Double)] {
        offices
            .map { ($0, attendedByOffice[$0.id] ?? 0) }
            .filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
    }

    static func dayCount(_ days: Double) -> String {
        "\(number(days)) \(days == 1 ? "day" : "days")"
    }

    // MARK: Bookings

    /// The heading over the list has to name the month the list is showing.
    ///
    /// It was the literal "This month" over rows the stepper moves freely in
    /// both directions, so two chevrons forward the heading claimed October's
    /// bookings were this month's — while the empty state four lines below it
    /// got the same question right. `SectionHeader` uppercases, so a stepped
    /// month reads OCTOBER 2026, in the style of the headings around it.
    static func bookingsTitle(month: Month, today: Day) -> String {
        month == today.month_ ? "This month" : month.text
    }

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
            SectionHeader(title: Self.bookingsTitle(month: month, today: .today)) {
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
                    RowMenu(
                        // Only a booking has anything to edit. An attendance
                        // record is a day and an office, and the screen that
                        // takes those can only add another one.
                        edit: entry.booking.map { booking in { editing = booking } },
                        delete: { deleteRequested(entry) }
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

    /// What answering a row's question did.
    ///
    /// `refused` is the case that used to be invisible, and it is why this is an
    /// enum rather than a `try?`. `recordAttendance` answers a write it will not
    /// make by *returning nil*, not by throwing, so `try?` on it flattened three
    /// different outcomes — written, declined, and thrown — into the same silent
    /// nothing, and the screen went on to `answered()` as though the day had
    /// been counted.
    ///
    /// The reachable decline is a day whose recorded fractions already total a
    /// whole day at another office. The question is still asked on such a row,
    /// because `isUnanswered` matches on this row's own office, so Yes was live,
    /// wrote nothing, said nothing, and left the row asking.
    enum Answer: Equatable {
        case written
        case refused
        case failed(String)
        /// Nothing to answer. `.attended` rows never ask the question, so this
        /// is unreachable from the buttons; it exists so the switch below has
        /// somewhere honest to put that case rather than reporting a success.
        case nothing
    }

    /// Yes: the day was worked. The store call arrives as a closure for the
    /// reason `AttendanceEditorScreen.record` takes its two — the outcome worth
    /// getting right is a refusal, and a refusal is a branch SwiftData will not
    /// take on request.
    ///
    /// The closure is handed the booking's id for a booked day and nil for a
    /// planned one, which is the difference between an attendance row that knows
    /// which desk it belongs to and one that floats free.
    static func answerYes(
        _ entry: Entry, record: (Day, UUID?, UUID?) throws -> Bool
    ) -> Answer {
        let bookingID: UUID?
        switch entry {
        case .booking(let booking): bookingID = booking.id
        case .planned: bookingID = nil
        case .attended: return .nothing
        }
        do {
            return try record(entry.day, entry.officeID, bookingID) ? .written : .refused
        } catch {
            return .failed(
                "\(entry.day.dayAndMonth) couldn't be recorded: \(error.localizedDescription). Nothing was saved."
            )
        }
    }

    /// No. A booking keeps its row and stops asking — the desk was reserved,
    /// which happened whether or not the day was. An intention that came to
    /// nothing leaves no trace worth keeping: it only ever counted toward the
    /// forecast, and the forecast is days ahead.
    ///
    /// Two closures rather than one, because those are two different writes to
    /// two different records and the branch between them is the rule above. A
    /// single closure would let a booking be deleted where it should have been
    /// marked and nothing here would notice.
    ///
    /// Neither call can decline, so there is no `refused` on this side — only a
    /// throw, which used to be swallowed and left the row asking a question the
    /// user had already answered.
    static func answerNo(
        _ entry: Entry,
        mark: (DeskBooking) throws -> Void,
        forget: (PlannedDay) throws -> Void
    ) -> Answer {
        do {
            switch entry {
            case .booking(let booking):
                try mark(booking)
            case .planned(let record):
                try forget(record)
            case .attended:
                return .nothing
            }
            return .written
        } catch {
            return .failed(
                "\(entry.day.dayAndMonth) couldn't be answered: \(error.localizedDescription). Nothing was saved."
            )
        }
    }

    /// Why the store refused a Yes, said in terms of what is actually on that
    /// day. The store answers with nil and no reason; every reason it has is
    /// visible from the rows this screen already holds.
    ///
    /// Only the middle sentence is reachable from a row's Yes button — the first
    /// describes a day this row would not be asking about, and the last is the
    /// reason we do not have. They are written out anyway because a fallback
    /// that says "could not be recorded" and nothing else is what the user gets
    /// if a future guard is added to the store and nobody updates this.
    static func refusal(
        day: Day, officeID: UUID?, attendance: [AttendanceDay]
    ) -> String {
        if attendance.contains(where: { $0.day == day && $0.officeID == officeID }) {
            return "\(day.dayAndMonth) is already recorded at this office. Nothing was added."
        }
        let elsewhere = attendance.filter { $0.day == day }.reduce(0) { $0 + $1.fraction }
        if elsewhere > 0 {
            return "\(day.dayAndMonth) already has \(amount(elsewhere)) recorded at another office, and a whole day here would take it over one. Remove that day first if it is wrong."
        }
        return "\(day.dayAndMonth) could not be recorded. Nothing was added."
    }

    /// `half a day` / `a whole day`, so the sentence above reads as English
    /// rather than as a decimal. Exact rather than approximate: the attendance
    /// editor's picker offers exactly those two fractions and every other writer
    /// in the app records 1.0, so there is no third value to round.
    static func amount(_ fraction: Double) -> String {
        fraction < 1 ? "half a day" : "a whole day"
    }

    /// Every delete on this screen can only fail by throwing — nothing declines
    /// a delete — so all it needs is somewhere for the throw to land. Silence
    /// left the row sitting there with no reason given, which reads as a tap
    /// that missed rather than as a save that failed.
    static func deletionFailure(_ entry: Entry, _ error: Error) -> String {
        let what = switch entry {
        case .booking: "The desk booking"
        case .attended: "The day in the office"
        case .planned: "The planned day"
        }
        return "\(what) for \(entry.day.dayAndMonth) couldn't be removed: \(error.localizedDescription)."
    }

    private func answerYes(_ entry: Entry) {
        settle(
            Self.answerYes(entry) { day, officeID, bookingID in
                try BookingStore.recordAttendance(
                    day: day, officeID: officeID, source: .manual,
                    bookingID: bookingID, in: context
                ) != nil
            },
            entry
        )
    }

    private func answerNo(_ entry: Entry) {
        settle(
            Self.answerNo(
                entry,
                mark: { try BookingStore.markNotAttended($0, in: context) },
                forget: { try BookingStore.deletePlanned($0, in: context) }
            ),
            entry
        )
    }

    /// One landing place for both buttons, so a refusal and a throw are treated
    /// the same way whichever of them produced it — and so `answered()` runs
    /// only when something was actually written. It used to run unconditionally,
    /// which withdrew the evening nudge for a day that had not been recorded:
    /// the question disappeared from the one place left that would have asked it
    /// again.
    private func settle(_ answer: Answer, _ entry: Entry) {
        switch answer {
        case .written:
            answered()
        case .refused:
            failure = Self.refusal(
                day: entry.day, officeID: entry.officeID, attendance: attendance
            )
        case .failed(let why):
            failure = why
        case .nothing:
            break
        }
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

    /// The row's Delete, before it is known what Delete means. A row standing
    /// for two records asks; every other row acts.
    private func deleteRequested(_ entry: Entry) {
        switch Self.deletion(for: entry, attendance: attendance) {
        case .record:
            delete(entry)
        case .bookingOrAttendance:
            choosingDelete = entry.booking
        }
    }

    /// Takes the day off the gauge without touching the desk.
    ///
    /// It deletes the record rather than storing a no. `notAttended` is the
    /// booking's own answer and it is already false here, so with the record
    /// gone the row returns to asking "Were you there?" and can be answered
    /// again — including at a half day, which is otherwise uncorrectable, since
    /// `recordAttendance` refuses a second row for the same day and office.
    /// Presuming the answer was no would take that back: a mis-tapped Yes is
    /// not the same statement as a day that was not worked.
    private func removeAttendance(from booking: DeskBooking) {
        guard let record = Self.attendanceRecord(for: booking, in: attendance) else { return }
        do {
            try BookingStore.deleteAttendance(record, in: context)
        } catch {
            failure = Self.deletionFailure(.attended(record), error)
            return
        }
        // The day is an open question again, and the evening nudge may be
        // holding one that was decided while it was not.
        answered()
    }

    private func delete(_ entry: Entry) {
        do {
            switch entry {
            case .booking(let booking):
                // The booking only. Attendance is the record that the day was
                // worked, and it outlives the desk.
                try BookingStore.delete(booking, in: context)
            case .attended(let record):
                try BookingStore.deleteAttendance(record, in: context)
            case .planned(let record):
                try BookingStore.deletePlanned(record, in: context)
            }
        } catch {
            failure = Self.deletionFailure(entry, error)
        }
    }

    /// Attendance is its own record, not a flag on the booking — you can book
    /// and not go. Matching on day and office is what ties the two together.
    private func isAttended(_ booking: DeskBooking) -> Bool {
        Self.attendanceRecord(for: booking, in: attendance) != nil
    }
}

#Preview {
    let container = try! Store.makeInMemoryContainer(seeded: true)
    return NavigationStack { HomeScreen() }
        .modelContainer(container)
        .environment(CaptureCoordinator(context: container.mainContext))
}
