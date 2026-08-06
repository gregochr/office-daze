import PhotosUI
import SwiftData
import SwiftUI

/// The gauge, the month's split by office, and every booking in it.
struct HomeScreen: View {
    @Environment(\.modelContext) private var context
    @Environment(CaptureCoordinator.self) private var capture

    @Query(sort: \Office.name) private var offices: [Office]
    @Query(sort: \DeskBooking.date) private var bookings: [DeskBooking]
    @Query private var attendance: [AttendanceDay]

    /// Which month the gauge is showing. Starts on today's, and the stepper
    /// moves it — the store holds every month at once, so this is the only
    /// state the screen needs.
    @State private var month = Day.today.month_

    /// Cleared as soon as it is read. The picker only reports a *change*, so
    /// leaving the last choice in place would make picking the same photo twice
    /// in a row do nothing the second time.
    @State private var photo: PhotosPickerItem?

    /// The booking row currently swiped open, if any. One at a time, which is
    /// why it lives here rather than in each row.
    @State private var openRow: UUID?

    /// Which kind of manual entry the header's menu is adding, if any.
    @State private var adding: ManualEntry?

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

        var id: UUID {
            switch self {
            case .booking(let booking): booking.id
            case .attended(let day): day.id
            }
        }

        var day: Day {
            switch self {
            case .booking(let booking): booking.day
            case .attended(let record): record.day
            }
        }
    }

    private var monthBookings: [DeskBooking] {
        bookings.filter { month.contains($0.day) }
    }

    private var monthEntries: [Entry] {
        Self.entries(bookings: bookings, attendance: attendance, in: month)
    }

    /// The month's list: every booking, plus every day on prem that no booking
    /// accounts for.
    ///
    /// Static so the one rule worth getting right can be tested — a day that is
    /// both booked and attended must produce one row, not two. It is matched on
    /// day and office, the same pairing `isAttended` uses, so the two cannot
    /// disagree about which days are already covered.
    static func entries(
        bookings: [DeskBooking], attendance: [AttendanceDay], in month: Month
    ) -> [Entry] {
        let booked = bookings.filter { month.contains($0.day) }
        let unbooked = attendance.filter { record in
            month.contains(record.day)
                && !booked.contains { $0.day == record.day && $0.officeID == record.officeID }
        }
        return (booked.map(Entry.booking) + unbooked.map(Entry.attended))
            .sorted { $0.day < $1.day }
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
        // The library hands back bytes, not a file, so this is the one intake
        // that has to convert before the coordinator can use it.
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
        .onChange(of: photo) { _, chosen in
            guard let chosen else { return }
            photo = nil
            Task {
                guard let data = try? await chosen.loadTransferable(type: Data.self) else {
                    capture.failed(.unreadableImage)
                    return
                }
                await capture.receive(photo: data)
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
                        Text(targetExplanation(result))
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
            StatusStrip(
                tone: .warning,
                leading: "\(number(result.shortfall)) \(result.shortfall == 1 ? "day" : "days") to go",
                trailing: "\(result.daysToRun) working \(result.daysToRun == 1 ? "day" : "days") left"
            )
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

    /// `Target 7 — 8 days pro-rated for 3 days' leave`. The one line that says
    /// where the number came from, because a target that moves without
    /// explanation reads as a bug.
    private func targetExplanation(_ result: Quota.Result) -> String {
        guard result.leaveTaken > 0 else {
            return "Target \(result.target) — 8 days a month"
        }
        let days = number(result.leaveTaken)
        let noun = result.leaveTaken == 1 ? "day's" : "days'"
        return "Target \(result.target) — 8 days pro-rated for \(days) \(noun) leave"
    }

    private func number(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...1)))
    }

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
            SectionHeader(title: "This month") {
                HStack(spacing: 16) {
                    Menu {
                        Button("Desk booking") { adding = .booking }
                        Button("Day in the office") { adding = .attendance }
                    } label: {
                        Text("+ Manually")
                    }
                    PhotosPicker(selection: $photo, matching: .images) {
                        Text("+ From image")
                    }
                }
                .font(.system(size: 15))
                .foregroundStyle(Palette.tint)
            }
            if monthEntries.isEmpty {
                emptyBookings
            } else {
                RowStack(items: monthEntries, inset: 38) { entry in
                    SwipeToDelete(id: entry.id, open: $openRow) {
                        delete(entry)
                    } content: {
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
                            attendedRow(record)
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

    /// A day on prem with no desk behind it. Says so where the desk id would
    /// be, rather than leaving a gap that reads as a booking half-read.
    private func attendedRow(_ record: AttendanceDay) -> some View {
        let office = offices.first { $0.id == record.officeID }
        return HStack(spacing: 13) {
            OfficeDot(colourHex: office?.colourHex ?? "")
            VStack(alignment: .leading, spacing: 3) {
                Text(record.day.mediumText)
                    .font(.system(size: 16))
                    .foregroundStyle(Palette.text)
                Text("\(office?.name ?? "Unknown office") · no desk booked")
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text("Attended")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Palette.met)
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
