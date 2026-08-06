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
                // Two or more, because these exist to split the month between
                // offices. With one there is nothing to split: the card says
                // the same number the gauge has just said, with a name on it.
                if offices.count > 1 {
                    officeCards.padding(.top, Metrics.cardGap)
                }
                bookingsSection.padding(.top, Metrics.sectionGap)
                if !offices.isEmpty {
                    NavigationLink("Preview arrival alert") { ArrivalPreviewScreen() }
                        .font(.system(size: 14))
                        .foregroundStyle(Palette.tint)
                        .padding(.top, 16)
                        .padding(.vertical, 13)
                }
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
                    target: snapshot?.result.target ?? 0
                )
                .padding(.top, 2)
                if let result = snapshot?.result {
                    shortfallStrip(result).padding(.top, 4)
                    // Tapping the sentence opens the thing it explains. The
                    // target moves because of leave, so leave is where the
                    // explanation should lead.
                    NavigationLink {
                        LeaveScreen(month: month)
                    } label: {
                        Text(Self.targetExplanation(result))
                            .font(.system(size: 12))
                            .foregroundStyle(Palette.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.top, 11)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var monthStepper: some View {
        HStack {
            stepButton("chevron.left") { month = month.adding(months: -1) }
            Spacer(minLength: 8)
            Text(month.text)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Palette.text)
            Spacer(minLength: 8)
            stepButton("chevron.right") { month = month.adding(months: 1) }
        }
    }

    private func stepButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(Palette.tertiary)
                .padding(.vertical, 6)
                .padding(.horizontal, 10)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func shortfallStrip(_ result: Quota.Result) -> some View {
        switch result.standing {
        case .behind:
            let text = Self.shortfallText(result)
            StatusStrip(tone: .warning, leading: text.leading, trailing: text.trailing)
        case .met:
            StatusStrip(tone: .success, leading: "Target met", dot: true)
        case .onTrack:
            // The gauge says 4 of 8; on its own that reads as behind. This is
            // the line that explains why it is not — and it names the bookings
            // it is counting on, because "on track" resting on four
            // reservations is a different fact from four days worked.
            StatusStrip(
                tone: .success,
                leading: "On track",
                trailing: "\(number(result.forecast)) more booked",
                dot: true
            )
        }
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

    private var officeCards: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 130), spacing: 10)],
            spacing: 10
        ) {
            ForEach(offices) { office in
                Card(padding: EdgeInsets(top: 13, leading: 14, bottom: 13, trailing: 14)) {
                    VStack(alignment: .leading, spacing: 7) {
                        HStack(spacing: 7) {
                            OfficeDot(colourHex: office.colourHex)
                            Text(office.name)
                                .font(.system(size: 13))
                                .foregroundStyle(Palette.rowLabel)
                                .lineLimit(1)
                        }
                        Text(number(snapshot?.attendedByOffice[office.id] ?? 0))
                            .font(.system(size: 22, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(Palette.text)
                    }
                }
            }
        }
    }

    // MARK: Bookings

    private var bookingsSection: some View {
        VStack(spacing: 8) {
            // Two ways in, named for what they are rather than for one "Add"
            // that hides the interesting half. The picker is the only route to
            // capture that does not go through the share sheet.
            // Two icons rather than two labels: the pencil writes one down, the
            // camera reads one off a screen. Both are one tap from the list
            // they add to, which is worth more here than the words were —
            // "+ Manually" and "+ From image" together took most of the row.
            SectionHeader(title: "This month") {
                HStack(spacing: 6) {
                    Menu {
                        Button("Desk booking") { adding = .booking }
                        Button("Day in the office") { adding = .attendance }
                    } label: {
                        headerIcon("square.and.pencil")
                    }
                    .accessibilityLabel("Add a booking or a day by hand")

                    // The confirmation is nearly always on a monitor in front
                    // of you, so holding the phone up to it is the shortest way
                    // in — there is not even a shutter to press. A screenshot
                    // already in the library still arrives through the iOS
                    // share sheet.
                    Button {
                        camera = true
                    } label: {
                        headerIcon("camera")
                    }
                    .accessibilityLabel("Scan a booking")
                }
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
                        switch entry {
                        case .booking(let booking):
                            NavigationLink {
                                BookingDetailScreen(booking: booking)
                            } label: {
                                bookingRow(booking)
                            }
                            .buttonStyle(.plain)
                        case .attended(let record):
                            // No detail screen: there is no desk, no floor and
                            // no hours to show. The row is the whole record.
                            deskless(
                                officeID: record.officeID, day: record.day,
                                status: "Attended", tone: Palette.met
                            )
                        case .planned(let record):
                            deskless(
                                officeID: record.officeID, day: record.day,
                                status: "Planned", tone: Palette.secondary
                            )
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
            if booking.needsChecking {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.close)
            }
            Text(attended ? "Attended" : "Booked")
                .font(.system(size: 12, weight: attended ? .semibold : .regular))
                .foregroundStyle(attended ? Palette.met : Palette.secondary)
        }
        .padding(.vertical, 13)
        .padding(.horizontal, 16)
        .frame(minHeight: Metrics.minimumRow)
        .contentShape(Rectangle())
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
        officeID: UUID?, day: Day, status: String, tone: Color
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
            Text(status)
                .font(.system(size: 12, weight: tone == Palette.met ? .semibold : .regular))
                .foregroundStyle(tone)
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
