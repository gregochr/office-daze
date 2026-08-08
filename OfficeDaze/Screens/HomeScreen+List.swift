import SwiftUI

/// The month's list — the section under the gauge, the rows in it, and the
/// writes a row can make.
///
/// Separate from HomeScreen.swift because it is the half of the screen with a
/// different job: the cards at the top *report* the month, and everything here
/// *changes* it. Every write the screen performs — answering "Were you there?",
/// deleting a row, taking a day back off the gauge — is in this file, next to
/// the row that offers it, so the tap and what it saves can be read together.
/// The rules those writes follow are in HomeScreen+Rules.swift, static and
/// testable; this file is the wiring between them and the buttons.
///
/// The state it reads is declared in HomeScreen.swift without `private`, which
/// is the one thing the split cost: a `private` member is invisible to an
/// extension in another file. The queries the list never touches kept theirs.
extension HomeScreen {

    var bookingsSection: some View {
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
                        delete: { deleteRequested(entry) },
                        // Named rather than trailing. With two closures already
                        // passed by label, braces hanging off the closing
                        // parenthesis read as though they finished `delete:`,
                        // and the row's whole appearance would be sitting
                        // inside what looks like the delete action.
                        content: { row(entry) }
                    )
                }
            }
        }
    }

    /// One row, whichever kind of record is behind it, with the question
    /// underneath when the day has gone by unanswered.
    private func row(_ entry: Entry) -> some View {
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
                    // Outside the link, because it goes somewhere else: an
                    // amber dot that only said "something here could not be
                    // read" left the fixing four taps away.
                    if booking.needsChecking {
                        checkingButton(booking)
                    }
                }
            case .attended(let record):
                // No detail screen: there is no desk, no floor and no hours to
                // show. The row is the whole record.
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

    // MARK: The rows

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

    /// Attendance is its own record, not a flag on the booking — you can book
    /// and not go. Matching on day and office is what ties the two together.
    private func isAttended(_ booking: DeskBooking) -> Bool {
        Self.attendanceRecord(for: booking, in: attendance) != nil
    }

    // MARK: The question the app has to ask

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

    // MARK: Taking a row away

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
    func removeAttendance(from booking: DeskBooking) {
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

    func delete(_ entry: Entry) {
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
}
