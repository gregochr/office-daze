import SwiftData
import SwiftUI

/// The gauge, the month's split by office, and every booking in it.
struct HomeScreen: View {
    @Environment(\.modelContext) private var context

    @Query(sort: \Office.name) private var offices: [Office]
    @Query(sort: \DeskBooking.date) private var bookings: [DeskBooking]
    @Query private var attendance: [AttendanceDay]

    /// Which month the gauge is showing. Starts on today's, and the stepper
    /// moves it — the store holds every month at once, so this is the only
    /// state the screen needs.
    @State private var month = Day.today.month_

    private var monthBookings: [DeskBooking] {
        bookings.filter { month.contains($0.day) }
    }

    private var snapshot: QuotaService.Snapshot? {
        try? QuotaService.snapshot(for: month, today: .today, in: context)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                gaugeCard
                if !offices.isEmpty {
                    officeCards.padding(.top, Metrics.cardGap)
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
                NavigationLink("Offices") { OfficesScreen() }
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
                    Text(targetExplanation(result))
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.top, 11)
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
        if result.shortfall > 0 {
            StatusStrip(
                tone: .warning,
                leading: "\(number(result.shortfall)) \(result.shortfall == 1 ? "day" : "days") to go",
                trailing: "\(result.daysToRun) working \(result.daysToRun == 1 ? "day" : "days") left"
            )
        } else {
            StatusStrip(tone: .success, leading: "Target met", dot: true)
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
            SectionHeader(title: "Bookings") {
                NavigationLink("Add") { BookingEditorScreen() }
                    .font(.system(size: 15))
                    .foregroundStyle(Palette.tint)
            }
            if monthBookings.isEmpty {
                emptyBookings
            } else {
                RowStack(items: monthBookings, inset: 38) { booking in
                    NavigationLink {
                        BookingDetailScreen(booking: booking)
                    } label: {
                        bookingRow(booking)
                    }
                    .buttonStyle(.plain)
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
                     : "No desk bookings in \(month.text).")
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

    /// Attendance is its own record, not a flag on the booking — you can book
    /// and not go. Matching on day and office is what ties the two together.
    private func isAttended(_ booking: DeskBooking) -> Bool {
        attendance.contains { $0.day == booking.day && $0.officeID == booking.officeID }
    }
}

#Preview {
    NavigationStack { HomeScreen() }
        .modelContainer(try! Store.makeInMemoryContainer(seeded: true))
}
