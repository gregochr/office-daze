import SwiftData
import SwiftUI

/// The bottom sheet the whole capture happens in — parsing, confirming, or
/// failing. One sheet for all three so the flow never flashes between
/// presentations.
struct CaptureSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Office.name) private var offices: [Office]

    let coordinator: CaptureCoordinator

    @State private var chosenOffice: UUID?
    @State private var manualEntry = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Metrics.cardGap) {
                    switch coordinator.phase {
                    case .idle:
                        Color.clear.frame(height: 1)
                    case .parsing(let step):
                        parsing(step)
                    case .review:
                        if let booking = coordinator.current { review(booking) }
                    case .failed(let error):
                        failure(error)
                    }
                }
                .padding(.horizontal, Metrics.screenPadding)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .background(Palette.ground)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { coordinator.abort(); dismiss() }
                }
            }
        }
        .onChange(of: isFinished) { _, finished in
            if finished { dismiss() }
        }
        .sheet(isPresented: $manualEntry) {
            NavigationStack { BookingEditorScreen() }
        }
    }

    private var isFinished: Bool {
        if case .idle = coordinator.phase { return true }
        return false
    }

    private var title: String {
        switch coordinator.phase {
        case .parsing: "Reading"
        case .review: "Confirm"
        case .failed: "Couldn't read it"
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
                Text("Reading your screenshot")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Palette.text)
                    .padding(.top, 16)
                Text("This usually takes a couple of seconds")
                    .font(.system(size: 14))
                    .foregroundStyle(Palette.secondary)
                    .padding(.top, 4)

                VStack(alignment: .leading, spacing: 14) {
                    checklistRow("Screenshot received", .received, step)
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
    private func checklistRow(
        _ title: String, _ step: CaptureCoordinator.Step, _ current: CaptureCoordinator.Step
    ) -> some View {
        HStack(spacing: 11) {
            Group {
                if step < current {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Palette.met)
                } else if step == current {
                    Circle()
                        .strokeBorder(Palette.tint, lineWidth: 2)
                        .frame(width: 17, height: 17)
                } else {
                    Circle()
                        .strokeBorder(Palette.tertiary, lineWidth: 1.5)
                        .frame(width: 17, height: 17)
                }
            }
            .font(.system(size: 18))
            .frame(width: 20)

            Text(title)
                .font(.system(size: 15))
                .foregroundStyle(step <= current ? Palette.text : Palette.secondary)
        }
    }

    // MARK: Review

    private func review(_ booking: ParsedBooking) -> some View {
        let matched = coordinator.matchedOffice(for: booking)
        let officeID = matched?.id ?? chosenOffice
        return VStack(spacing: Metrics.cardGap) {
            header
            if matched == nil { officePicker(booking) }
            fields(booking, office: matched)
            actions(booking, officeID: officeID)
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
                    ForEach(Array(coordinator.segments.enumerated()), id: \.offset) { index, saved in
                        Capsule()
                            .fill(segmentColour(index: index, saved: saved, at: position.number - 1))
                            .frame(height: 4)
                    }
                }
            }
            .padding(.horizontal, 4)
        }
    }

    private func segmentColour(index: Int, saved: Bool, at current: Int) -> Color {
        if saved { return Palette.met }
        return index == current ? Palette.tint : Palette.hairline
    }

    /// No match means the sheet asks. It never creates an office — a silently
    /// invented one gets its own perimeter, and the user finds out when the
    /// arrival alert doesn't fire.
    private func officePicker(_ booking: ParsedBooking) -> some View {
        Card(padding: EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16)) {
            VStack(alignment: .leading, spacing: 10) {
                Text(booking.officeName.map { "Which office is \"\($0)\"?" }
                     ?? "Which office is this?")
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

    private func fields(_ booking: ParsedBooking, office: Office?) -> some View {
        Card {
            VStack(spacing: 0) {
                DetailRow(
                    label: "Office",
                    value: office?.name ?? booking.officeName,
                    needsChecking: booking.unsureFields.contains("office") && office == nil
                )
                RowDivider()
                DetailRow(label: "Date", value: booking.day.longText)
                RowDivider()
                DetailRow(label: "Desk", value: booking.deskID)
                RowDivider()
                DetailRow(
                    label: "Floor", value: booking.floor,
                    needsChecking: booking.unsureFields.contains("floor")
                )
                RowDivider()
                DetailRow(
                    label: "Hours", value: hours(booking),
                    needsChecking: booking.unsureFields.contains("startTime")
                        || booking.unsureFields.contains("endTime")
                )
            }
        }
    }

    private func hours(_ booking: ParsedBooking) -> String? {
        switch (booking.startTime, booking.endTime) {
        case (let start?, let end?): "\(start) – \(end)"
        case (let start?, nil): start
        case (nil, let end?): "until \(end)"
        case (nil, nil): nil
        }
    }

    private func actions(_ booking: ParsedBooking, officeID: UUID?) -> some View {
        HStack(spacing: 10) {
            Button("Skip") {
                chosenOffice = nil
                coordinator.advance()
            }
            .buttonStyle(.bordered)
            .tint(Palette.secondary)

            Button(coordinator.isLast ? "Save and finish" : "Save and next") {
                guard let officeID else { return }
                chosenOffice = nil
                coordinator.save(booking, to: officeID)
            }
            .buttonStyle(.borderedProminent)
            .tint(Palette.tint)
            .disabled(officeID == nil)
        }
        .controlSize(.large)
        .frame(maxWidth: .infinity)
    }

    // MARK: Failure

    /// Never a silent drop, and never a bounce back to the home screen: the
    /// error replaces the card in place and offers both ways forward.
    private func failure(_ error: CaptureError) -> some View {
        VStack(spacing: Metrics.cardGap) {
            Card(padding: EdgeInsets(top: 18, leading: 16, bottom: 18, trailing: 16)) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Couldn't read that screenshot")
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
                    ActionRow(title: "Try again", centred: true) {
                        Task { await coordinator.retry() }
                    }
                    RowDivider(inset: 0)
                    ActionRow(title: "Enter manually", centred: true) {
                        manualEntry = true
                    }
                }
            }
        }
    }
}
