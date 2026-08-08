import SwiftData
import SwiftUI

/// The gauge, the month's split by office, and every booking in it.
///
/// The screen is three files, split where it already divided itself. This one
/// holds the state, the body, and the two cards that report the month;
/// `HomeScreen+List.swift` holds the list underneath and every write its rows
/// make; `HomeScreen+Rules.swift` holds the decisions both of them ask for,
/// static and answerable without a screen.
struct HomeScreen: View {
    // Most of the state below is not `private`, which is what the split cost:
    // an extension in another file cannot see a private member, and the rows
    // that read this state live in HomeScreen+List.swift. Nothing outside the
    // screen touches any of it. The members still marked private are the ones
    // only this file reads, so the difference is the honest record of which
    // state the list is entitled to — keep it that way when moving code across.
    @Environment(\.modelContext) var context
    @Environment(CaptureCoordinator.self) private var capture

    @Query(sort: \Office.name) var offices: [Office]
    @Query(sort: \DeskBooking.date) private var bookings: [DeskBooking]
    @Query var attendance: [AttendanceDay]
    @Query private var planned: [PlannedDay]

    /// Which month the gauge is showing. Starts on today's, and the stepper
    /// moves it — the store holds every month at once, so this is the only
    /// state the screen needs.
    @State var month = Day.today.month_

    @State var camera = false

    /// Which kind of manual entry the header's menu is adding, if any.
    @State var adding: ManualEntry?

    /// The booking a row's menu sent to the editor, if any.
    @State var editing: DeskBooking?

    /// The booking whose row was told to delete when the row is holding two
    /// records — the desk and the day worked. Set means the dialog is up
    /// asking which of the two was meant. See `deletion(for:attendance:)`.
    @State var choosingDelete: DeskBooking?

    /// Set only by a write that did not land — one the store refused, or one
    /// that threw. Non-nil puts the alert up. See `Answer`.
    @State var failure: String?

    enum ManualEntry: String, Identifiable {
        case booking, attendance
        var id: String { rawValue }
    }

    // A `monthBookings` used to sit here, filtering the desk bookings to the
    // month. Nothing read it: `entries` does that filtering itself, and has to,
    // because the rule it exists for is which *other* records a booked day
    // speaks for. A second, subtly different month filter beside it was an
    // invitation to answer the same question two ways.

    var monthEntries: [Entry] {
        Self.entries(
            bookings: bookings, attendance: attendance, planned: planned, in: month
        )
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
}

#Preview {
    // The preview has nowhere to put a failure and nothing to show without a
    // container: an in-memory store that will not build is a broken preview
    // either way, and a crash names the line while an `if let` would render an
    // empty screen and leave you looking for the reason.
    // swiftlint:disable:next force_try
    let container = try! Store.makeInMemoryContainer(seeded: true)
    return NavigationStack { HomeScreen() }
        .modelContainer(container)
        .environment(CaptureCoordinator(context: container.mainContext))
}
