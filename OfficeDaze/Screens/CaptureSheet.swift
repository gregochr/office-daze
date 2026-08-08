import SwiftData
import SwiftUI

/// The bottom sheet the whole capture happens in — parsing, confirming, or
/// failing. One sheet for all three so the flow never flashes between
/// presentations.
///
/// Almost everything the sheet decides — which card is up, what the title says,
/// which office the booking will be filed under, whether the primary button
/// saves or asks first — is lifted out as a `static` below. None of it needs a
/// screen to be right or wrong, and while it lived inside `body` none of it
/// could be asserted: the file was the largest untested surface in the app and
/// shipped a header that told a user their screenshot was unreadable when the
/// reading had worked perfectly and the *write* had failed.
struct CaptureSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Office.name) private var offices: [Office]

    let coordinator: CaptureCoordinator

    @State private var chosenOffice: UUID?
    @State private var manualEntry = false
    @State private var confirmingReplace = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Metrics.cardGap) {
                    switch Self.shown(for: coordinator.phase, current: coordinator.current) {
                    case .nothing:
                        Color.clear.frame(height: 1)
                    case .parsing(let step):
                        parsing(step)
                    case .review(let booking):
                        review(booking)
                    case .failure(let error):
                        failure(error)
                    }
                }
                .padding(.horizontal, Metrics.screenPadding)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .background(Palette.ground)
            .navigationTitle(Self.title(for: coordinator.phase))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { coordinator.abort(); dismiss() }
                }
            }
        }
        // The coordinator outlives the sheet, so going idle — the last booking
        // filed, or a cancel from anywhere — is what closes it.
        .onChange(of: coordinator.isActive) { _, active in
            if !active { dismiss() }
        }
        .sheet(isPresented: $manualEntry) {
            NavigationStack { BookingEditorScreen() }
        }
    }

    // MARK: What is on screen

    /// The one card up at any moment.
    ///
    /// A `.review` phase with nothing at its index draws nothing rather than an
    /// empty card under a "Confirm" title — the coordinator only reaches that
    /// state if a parse yields no rows, which `HaikuClient` refuses, and a blank
    /// sheet with a Cancel button is the worst possible way to find out it got
    /// through anyway.
    enum Shown: Equatable {
        case nothing
        case parsing(CaptureCoordinator.Step)
        case review(ParsedBooking)
        case failure(CaptureError)
    }

    static func shown(
        for phase: CaptureCoordinator.Phase, current: ParsedBooking?
    ) -> Shown {
        switch phase {
        case .idle: .nothing
        case .parsing(let step): .parsing(step)
        case .review: current.map(Shown.review) ?? .nothing
        case .failed(let error): .failure(error)
        }
    }

    static func title(for phase: CaptureCoordinator.Phase) -> String {
        switch phase {
        case .parsing: "Reading"
        case .review: "Confirm"
        case .failed(let error): failureTitle(for: error)
        case .idle: ""
        }
    }

    // MARK: Parsing

    private func parsing(_ step: CaptureCoordinator.Step) -> some View {
        Card(padding: EdgeInsets(top: 24, leading: 20, bottom: 24, trailing: 20)) {
            VStack(spacing: 0) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .controlSize(.large)
                    .tint(Palette.tint)
                    .frame(width: 38, height: 38)
                // Named, because the image leaves the phone to be read. Who is
                // doing the reading is the user's business, and a screen that
                // only says "Reading" implies the app is doing it here.
                Text("Reading with Claude AI")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Palette.text)
                    .padding(.top, 16)
                Text("This usually takes a couple of seconds")
                    .font(.system(size: 14))
                    .foregroundStyle(Palette.secondary)
                    .padding(.top, 4)

                VStack(alignment: .leading, spacing: 14) {
                    // "Image", not "Screenshot" — a photo of a screen arrives
                    // here too, and now has its own button on the home screen.
                    checklistRow("Image received", .received, step)
                    checklistRow("Finding the desk details", .finding, step)
                    checklistRow("Matching to an office", .matching, step)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 22)
            }
            .frame(maxWidth: .infinity)
        }
    }

    /// Done, active, or pending — driven by real progress, so a step that
    /// completes instantly simply flashes past rather than being held open to
    /// look busy.
    enum Tick: Equatable {
        case done, active, pending

        /// Whether the step's label is in full black. A step still to come is
        /// grey; the one under way is not, or the checklist would read as
        /// though nothing had started.
        var reached: Bool { self != .pending }
    }

    static func tick(
        _ step: CaptureCoordinator.Step, at current: CaptureCoordinator.Step
    ) -> Tick {
        if step < current { return .done }
        return step == current ? .active : .pending
    }

    private func checklistRow(
        _ title: String, _ step: CaptureCoordinator.Step, _ current: CaptureCoordinator.Step
    ) -> some View {
        let tick = Self.tick(step, at: current)
        return HStack(spacing: 11) {
            Group {
                switch tick {
                case .done:
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Palette.met)
                case .active:
                    Circle()
                        .strokeBorder(Palette.tint, lineWidth: 2)
                        .frame(width: 17, height: 17)
                case .pending:
                    Circle()
                        .strokeBorder(Palette.tertiary, lineWidth: 1.5)
                        .frame(width: 17, height: 17)
                }
            }
            .font(.system(size: 18))
            .frame(width: 20)

            Text(title)
                .font(.system(size: 15))
                .foregroundStyle(tick.reached ? Palette.text : Palette.secondary)
        }
    }

    // MARK: Review

    /// The office this booking will be filed under.
    ///
    /// A match outranks the picker rather than merging with it: when the
    /// matcher answers, the picker is never drawn, so a `chosenOffice` left over
    /// from the previous booking in the table would otherwise decide where this
    /// one went with nothing on screen saying so.
    static func officeToFileUnder(matched: UUID?, chosen: UUID?) -> UUID? {
        matched ?? chosen
    }

    /// The booking already held for this office and day, when it is worth
    /// asking about.
    ///
    /// Re-importing the same desk changes nothing but gaps being filled, and a
    /// confirmation for that is a question with one answer — so only a
    /// *different* desk is a clash. Getting this backwards puts a destructive
    /// dialog in front of every re-share of a table the user has already filed.
    static func clash(with existing: DeskBooking?, incoming deskID: String) -> DeskBooking? {
        guard let existing, existing.deskID != deskID else { return nil }
        return existing
    }

    private func review(_ booking: ParsedBooking) -> some View {
        let matched = coordinator.matchedOffice(for: booking)
        let officeID = Self.officeToFileUnder(matched: matched?.id, chosen: chosenOffice)
        let clash = Self.clash(
            with: officeID.flatMap {
                coordinator.existingBooking(day: booking.day, officeID: $0)
            },
            incoming: booking.deskID
        )
        return VStack(spacing: Metrics.cardGap) {
            header
            if matched == nil { officePicker(booking) }
            if let clash { clashStrip(clash) }
            fields(booking, office: matched)
            actions(booking, officeID: officeID, replacing: clash)
            Text("Saved one at a time, so you can skip any you don't want.")
                .font(.system(size: 13))
                .foregroundStyle(Palette.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private var header: some View {
        // Hidden entirely for a single-booking capture — a counter reading
        // "1 of 1" is noise.
        if let position = coordinator.position {
            VStack(spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Found \(position.total) bookings")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Palette.text)
                    Spacer(minLength: 8)
                    Text("Booking \(position.number) of \(position.total)")
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.secondary)
                }
                HStack(spacing: 4) {
                    let bar = Self.bar(
                        saved: coordinator.segments, current: position.number - 1
                    )
                    ForEach(Array(bar.enumerated()), id: \.offset) { _, segment in
                        Capsule()
                            .fill(Self.colour(of: segment))
                            .frame(height: 4)
                    }
                }
            }
            .padding(.horizontal, 4)
        }
    }

    /// One capsule per booking in the table.
    enum Segment: Equatable { case saved, current, pending }

    /// Saved outranks current, because only a write that landed may be drawn as
    /// one: a booking that failed to save must not keep the highlight that says
    /// "this is the one you are on" *and* pick up the green that says it is
    /// filed.
    static func bar(saved: [Bool], current: Int) -> [Segment] {
        saved.enumerated().map { index, isSaved -> Segment in
            if isSaved { return .saved }
            return index == current ? .current : .pending
        }
    }

    static func colour(of segment: Segment) -> Color {
        switch segment {
        case .saved: Palette.met
        case .current: Palette.tint
        case .pending: Palette.hairline
        }
    }

    /// No match means the sheet asks. It never creates an office — a silently
    /// invented one gets its own perimeter, and the user finds out when the
    /// arrival alert doesn't fire.
    ///
    /// Quoted back verbatim when there is a printed name, because the answer is
    /// only useful if the user can see which string they are teaching.
    static func officeQuestion(printed: String?) -> String {
        printed.map { "Which office is \"\($0)\"?" } ?? "Which office is this?"
    }

    private func officePicker(_ booking: ParsedBooking) -> some View {
        Card(padding: EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16)) {
            VStack(alignment: .leading, spacing: 10) {
                Text(Self.officeQuestion(printed: booking.officeName))
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Palette.text)
                if offices.isEmpty {
                    Text("Add an office first — the booking can't be filed without one.")
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.secondary)
                } else {
                    Picker("Office", selection: $chosenOffice) {
                        Text("Choose").tag(UUID?.none)
                        ForEach(offices) { office in
                            Text(office.name).tag(UUID?.some(office.id))
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(Palette.tint)
                }
            }
        }
    }

    /// One row of the detail card: what it is called, what it says, and whether
    /// it is flagged as unread instead.
    struct Field: Equatable {
        var label: String
        var value: String?
        var needsChecking = false
    }

    /// The five rows, and which of them the model admitted it could not read.
    ///
    /// Office is the exception: a name the model was unsure of is not worth
    /// flagging once the matcher has resolved it anyway, because the row then
    /// shows the office's own stored name and there is nothing left to check.
    /// Hours is the other: it is two fields printed as one, so either being
    /// unread has to flag the row — reading only `startTime` left a booking
    /// ending at a time nobody had read presented as fact.
    static func fieldRows(_ booking: ParsedBooking, office: Office?) -> [Field] {
        [
            Field(
                label: "Office",
                value: office?.name ?? booking.officeName,
                needsChecking: booking.unsureFields.contains("office") && office == nil
            ),
            Field(label: "Date", value: booking.day.longText),
            Field(label: "Desk", value: booking.deskID),
            Field(
                label: "Floor", value: booking.floor,
                needsChecking: booking.unsureFields.contains("floor")
            ),
            Field(
                label: "Hours", value: hours(start: booking.startTime, end: booking.endTime),
                needsChecking: booking.unsureFields.contains("startTime")
                    || booking.unsureFields.contains("endTime")
            ),
        ]
    }

    /// One end, both ends, or neither. `until 17:00` rather than `– 17:00`,
    /// because a dash with nothing in front of it reads as a missing value
    /// rather than as a day that starts whenever you arrive.
    static func hours(start: String?, end: String?) -> String? {
        switch (start, end) {
        case (let start?, let end?): "\(start) – \(end)"
        case (let start?, nil): start
        case (nil, let end?): "until \(end)"
        case (nil, nil): nil
        }
    }

    private func fields(_ booking: ParsedBooking, office: Office?) -> some View {
        Card {
            VStack(spacing: 0) {
                let rows = Self.fieldRows(booking, office: office)
                ForEach(Array(rows.enumerated()), id: \.offset) { index, field in
                    DetailRow(
                        label: field.label, value: field.value,
                        needsChecking: field.needsChecking
                    )
                    if index < rows.count - 1 { RowDivider() }
                }
            }
        }
    }

    /// One desk per office per day, so a re-import is a change rather than a
    /// duplicate — the month cannot double. What it can do is move the desk id
    /// without being asked, which is what this says out loud.
    ///
    /// The provenance on the right is only shown for a desk typed by hand: a
    /// desk that came from a capture is the same kind of record as the one
    /// arriving, so naming its source there would be noise on every re-share.
    static func clashText(deskID: String, source: BookingSource) -> (String, String?) {
        ("Already booked: \(deskID)", source == .manual ? "entered by hand" : nil)
    }

    private func clashStrip(_ existing: DeskBooking) -> some View {
        let (leading, trailing) = Self.clashText(
            deskID: existing.deskID, source: existing.source
        )
        return StatusStrip(tone: .warning, leading: leading, trailing: trailing)
    }

    /// The primary button, which is three buttons wearing one coat.
    struct PrimaryAction: Equatable {
        var title: String
        var enabled: Bool
        /// Whether pressing it opens the replace dialog instead of writing.
        var asksFirst: Bool
    }

    /// Disabled rather than hidden when no office is known yet: the button is
    /// what the user is looking for, and removing it reads as the sheet being
    /// broken rather than as the picker above it being unanswered.
    static func primaryAction(officeID: UUID?, replacing: Bool, isLast: Bool) -> PrimaryAction {
        PrimaryAction(
            title: replacing ? "Replace…" : (isLast ? "Save and finish" : "Save and next"),
            enabled: officeID != nil,
            asksFirst: replacing
        )
    }

    private func actions(
        _ booking: ParsedBooking, officeID: UUID?, replacing existing: DeskBooking?
    ) -> some View {
        let primary = Self.primaryAction(
            officeID: officeID, replacing: existing != nil, isLast: coordinator.isLast
        )
        return HStack(spacing: 10) {
            Button("Skip") {
                chosenOffice = nil
                coordinator.advance()
            }
            .buttonStyle(.bordered)
            .tint(Palette.secondary)

            Button(primary.title) {
                guard primary.enabled else { return }
                if primary.asksFirst {
                    confirmingReplace = true
                } else {
                    save(booking, to: officeID, chosen: false)
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(Palette.tint)
            .disabled(!primary.enabled)
        }
        .controlSize(.large)
        .frame(maxWidth: .infinity)
        .confirmationDialog(
            "\(booking.day.mediumText) is already booked",
            isPresented: $confirmingReplace,
            titleVisibility: .visible
        ) {
            Button("Replace with \(booking.deskID)", role: .destructive) {
                // `chosen` so the answer stands. Without it a booking entered
                // by hand would win the merge and the tap would do nothing.
                save(booking, to: officeID, chosen: true)
            }
            Button("Keep \(existing?.deskID ?? "")", role: .cancel) {
                chosenOffice = nil
                coordinator.advance()
            }
        } message: {
            Text(Self.clashMessage(
                existing: existing?.deskID,
                provenance: existing.flatMap { coordinator.provenance(of: $0) }
            ))
        }
    }

    /// The dialog asks which of two desks to keep, so it has to say where the
    /// one already held came from and when. Without that the question is which
    /// of two identical-looking facts is newer, which the user has no way to
    /// answer — the card above says it, and the dialog covers the card.
    static func clashMessage(existing: String?, provenance: String?) -> String {
        let desk = existing ?? "a desk"
        let source = provenance.map { ", \($0)" } ?? ""
        return "This day already has desk \(desk) at this office\(source). "
            + "Only one desk is kept per office per day."
    }

    private func save(_ booking: ParsedBooking, to officeID: UUID?, chosen: Bool) {
        guard let officeID else { return }
        chosenOffice = nil
        coordinator.save(booking, to: officeID, chosen: chosen)
    }

    // MARK: Failure

    /// What broke, in the sheet's own two words and in its heading.
    ///
    /// Both used to be hard-coded to the reading, which was true of every
    /// failure that could reach this card — until a booking the model had read
    /// perfectly failed to *write*. "Couldn't read that screenshot" then sent
    /// someone off to re-share an image that was never the problem, past the one
    /// offer on the card that could have helped them. The body underneath is
    /// already right, because it comes from the error itself.
    ///
    /// Spelled out case by case rather than defaulted, so a `CaptureError` added
    /// later has to state which half of the pipeline it broke instead of
    /// silently inheriting the reading's wording.
    static func failureTitle(for error: CaptureError) -> String {
        switch error {
        case .couldNotSave: "Couldn't save it"
        case .noAPIKey, .unsupportedFile, .unreadableImage, .network, .httpStatus,
            .modelReturnedNothingUsable, .refused:
            "Couldn't read it"
        }
    }

    static func failureHeader(for error: CaptureError) -> String {
        switch error {
        case .couldNotSave: "Couldn't save that booking"
        case .noAPIKey, .unsupportedFile, .unreadableImage, .network, .httpStatus,
            .modelReturnedNothingUsable, .refused:
            "Couldn't read that screenshot"
        }
    }

    /// Never a silent drop, and never a bounce back to the home screen: the
    /// error replaces the card in place and offers both ways forward.
    private func failure(_ error: CaptureError) -> some View {
        VStack(spacing: Metrics.cardGap) {
            Card(padding: EdgeInsets(top: 18, leading: 16, bottom: 18, trailing: 16)) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(Self.failureHeader(for: error))
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Palette.text)
                    Text(error.errorDescription ?? "Unknown failure")
                        .font(.system(size: 14))
                        .foregroundStyle(Palette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Card {
                VStack(spacing: 0) {
                    // Only when there is something to retry. A photo that never
                    // decoded has no request behind it, and a button that
                    // re-runs nothing is worse than no button.
                    if coordinator.canRetry {
                        ActionRow(title: "Try again", centred: true) {
                            Task { await coordinator.retry() }
                        }
                        RowDivider(inset: 0)
                    }
                    ActionRow(title: "Enter manually", centred: true) {
                        manualEntry = true
                    }
                }
            }
        }
    }
}
