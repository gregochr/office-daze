import SwiftData
import SwiftUI

/// One booking: the desk number large enough to read at a glance, where it is,
/// and whether the day was actually attended.
struct BookingDetailScreen: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var offices: [Office]
    @Query private var attendance: [AttendanceDay]
    @Query private var bookings: [DeskBooking]

    let booking: DeskBooking

    /// Deleting from the editor pops one level, which lands back here — on a
    /// booking that no longer exists, still showing its desk number as though
    /// it did. A screen about a row that is gone has nothing to say, so it
    /// leaves too, whoever did the deleting and from wherever.
    private var stillExists: Bool {
        bookings.contains { $0.id == booking.id }
    }

    private var office: Office? {
        offices.first { $0.id == booking.officeID }
    }

    private var attended: AttendanceDay? {
        attendance.first { $0.day == booking.day && $0.officeID == booking.officeID }
    }

    @State private var calendarOutcome: CalendarWriter.Outcome?
    /// Set only by a write that did not land, or one the store refused. The
    /// screen stays exactly where it is behind the alert, because everything
    /// the sentence talks about — the day, the office, the row that is still
    /// asking — is on it.
    @State private var failure: String?

    var body: some View {
        ScrollView {
            VStack(spacing: Metrics.cardGap) {
                headline
                if booking.needsChecking { unread }
                fields
                switch Self.standing(
                    attendedVia: attended?.source, day: booking.day, today: .today
                ) {
                case .attended(let text):
                    StatusStrip(tone: .success, leading: text, dot: true)
                case .offerAttendance:
                    recordAttendance
                case .tooEarlyToSay:
                    EmptyView()
                }
                actions
            }
            .padding(.horizontal, Metrics.screenPadding)
            .padding(.top, 6)
            .padding(.bottom, 30)
        }
        .background(Palette.ground)
        // The office, not the desk. The desk id is already the hero at 44pt,
        // and a nav bar repeating it says nothing the screen has not said.
        .navigationTitle(office?.name ?? "Booking")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink("Edit") { BookingEditorScreen(booking: booking) }
            }
        }
        // Same shape as the attendance editor's: one place a write that did not
        // land says so, whichever write it was. A second, different way of
        // reporting a failure on the same screen would be a second thing to
        // keep right.
        .alert(
            "Not saved",
            isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(failure ?? "")
        }
        .onChange(of: stillExists) { _, exists in
            if !exists { dismiss() }
        }
    }

    private var headline: some View {
        Card(padding: EdgeInsets(top: 20, leading: 18, bottom: 20, trailing: 18)) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 9) {
                    OfficeDot(colourHex: office?.colourHex ?? "")
                    Text(office?.name ?? "Unknown office")
                        .font(.system(size: 14))
                        .foregroundStyle(Palette.rowLabel)
                }
                Text(booking.deskID)
                    .font(.system(size: 44, weight: .bold))
                    .kerning(-1.3)
                    .foregroundStyle(Palette.text)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                    .padding(.top, 12)
                Text(booking.day.longText)
                    .font(.system(size: 15))
                    .foregroundStyle(Palette.text)
                    .padding(.top, 10)
                if let office, !fullAddress(office).isEmpty {
                    Text(fullAddress(office))
                        .font(.system(size: 14))
                        .foregroundStyle(Palette.secondary)
                        .padding(.top, 4)
                }
            }
        }
    }

    /// Names what could not be read, and goes straight to it.
    ///
    /// Never guessing is the best idea in the app, and a row that only said
    /// something was missing left the user to work out which of five fields it
    /// was. The strip says, and tapping it opens the editor with the cursor
    /// already there.
    private var unread: some View {
        NavigationLink {
            BookingEditorScreen(booking: booking)
        } label: {
            StatusStrip(
                tone: .warning,
                leading: "\(named) couldn't be read",
                trailing: "Fill it in"
            )
        }
        .buttonStyle(.plain)
    }

    private var named: String {
        Self.sentenceCased(BookingEditorScreen.unreadFieldNames(booking.unsureFields))
    }

    /// The first letter, and only the first.
    ///
    /// `.capitalized` is the obvious call and the wrong one: the names arrive
    /// as a list — "floor and zone", "floor, zone and hours" — and title-casing
    /// the lot gives "Floor And Zone". The strip is a sentence about what could
    /// not be read, not a heading.
    static func sentenceCased(_ text: String) -> String {
        "\(text.prefix(1).uppercased())\(text.dropFirst())"
    }

    private var fields: some View {
        Card {
            VStack(spacing: 0) {
                DetailRow(
                    label: "Floor", value: booking.floor,
                    needsChecking: booking.unsureFields.contains("floor")
                )
                RowDivider()
                DetailRow(
                    label: "Zone", value: booking.zone,
                    needsChecking: booking.unsureFields.contains("zone")
                )
                RowDivider()
                DetailRow(
                    label: "Hours", value: booking.hoursText,
                    needsChecking: booking.unsureFields.contains("startTime")
                        || booking.unsureFields.contains("endTime")
                )
            }
        }
    }

    /// The geofence offers and the user confirms — and so does this. A day you
    /// booked is not a day you went.
    private var recordAttendance: some View {
        Card {
            ActionRow(title: "I was here on \(booking.day.mediumText)", centred: true) {
                answerTheQuestion()
            }
        }
    }

    /// A tap that lands says nothing and needs to say nothing: the row it was
    /// on is replaced by the green "Attended" strip, because `attended` now
    /// finds a row. Only the two ways it does not land speak.
    private func answerTheQuestion() {
        switch Self.record(
            day: booking.day, officeID: booking.officeID, bookingID: booking.id,
            attend: { day, officeID, bookingID in
                try BookingStore.recordAttendance(
                    day: day, officeID: officeID,
                    source: .manual, bookingID: bookingID, in: context
                ) != nil
            }
        ) {
        case .recorded:
            break
        case .refused:
            failure = Self.refusal(
                day: booking.day, officeID: booking.officeID,
                attendance: attendance, offices: offices
            )
        case .failed(let why):
            failure = why
        }
    }

    private var actions: some View {
        Card {
            VStack(spacing: 0) {
                ActionRow(
                    title: "Directions", enabled: Self.directionsURL(for: office) != nil
                ) {
                    openDirections()
                }
                RowDivider(inset: 0)
                ActionRow(
                    title: Self.calendarTitle(outcome: calendarOutcome, hasEvent: hasEvent),
                    enabled: Self.calendarRowEnabled(
                        outcome: calendarOutcome, hasEvent: hasEvent
                    )
                ) {
                    Task { await addToCalendar() }
                }
                // "View original" needs a capture to have an original, so it
                // only appears when there is one.
            }
        }
    }

    private var hasEvent: Bool { Self.hasEvent(booking.calendarEventID) }

    /// Whether this booking is already in the calendar.
    ///
    /// An empty string counts as absent, because that is what
    /// `CalendarWriter.write` counts it as. A row that disagreed with the
    /// writer would go grey over a booking the writer would happily have
    /// written, and there would be nothing on screen to explain why.
    static func hasEvent(_ identifier: String?) -> Bool {
        !(identifier ?? "").isEmpty
    }

    /// What the calendar row says.
    ///
    /// The row used to promise "Update calendar event" once the identifier was
    /// set, and there was never an update behind it. The app asks for
    /// write-only access, `event(withIdentifier:)` is a read, and a write-only
    /// grant answers nil — so the update branch in `CalendarWriter` could not
    /// run and every further tap wrote a twin event. The writer now refuses a
    /// booking that already has an identifier, and the row has to stop inviting
    /// the user into that refusal: once the event exists it says so, and
    /// `calendarRowEnabled` greys it.
    ///
    /// `.updated` stays because the day the app asks for full access it becomes
    /// reachable and correct — see `CalendarWriter.Outcome`.
    ///
    /// `.failed` carries the reason and this renders it. Fixed copy — "Couldn't
    /// add to calendar" — told the user that something went wrong and refused
    /// to say what, which is the silent-failure habit this whole screen is
    /// being audited for. Both producers of the message hand back a complete
    /// user-facing sentence (`CalendarWriter.alreadyWritten`, or an error's
    /// `localizedDescription`), so it is shown as written rather than glued
    /// behind a prefix that would argue with it. An empty message is the one
    /// case where the fixed copy is still better than the truth, because a row
    /// with no text on it looks broken rather than informative.
    static func calendarTitle(outcome: CalendarWriter.Outcome?, hasEvent: Bool) -> String {
        switch outcome {
        case .added: "Added to calendar"
        case .updated: "Calendar updated"
        case .denied: "Calendar access refused"
        case .failed(let message):
            message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Couldn't add to calendar"
                : message
        // Written once already, from an earlier visit to this screen.
        case nil: hasEvent ? "Added to calendar" : "Add to calendar"
        }
    }

    /// A tap that can do something, and no tap that cannot.
    ///
    /// A booking with an event is done: tapping again reaches
    /// `CalendarWriter`'s refusal and writes nothing, so the row is not offered
    /// in the first place. `.denied` and a genuine failure stay tappable — a
    /// permission granted in Settings, or a calendar that was busy, both make
    /// the next tap the one that works.
    static func calendarRowEnabled(outcome: CalendarWriter.Outcome?, hasEvent: Bool) -> Bool {
        switch outcome {
        case .added, .updated: false
        case .denied, .failed, nil: !hasEvent
        }
    }

    /// One event per booking, and no second tap that pretends otherwise.
    ///
    /// The identifier is stored so the writer can refuse — not so it can
    /// update. Under write-only access an event this app wrote is one it can
    /// no longer find; see `CalendarWriter.write`.
    private func addToCalendar() async {
        guard let office else { return }
        let outcome = await CalendarWriter.write(
            CalendarWriter.Entry(
                deskID: booking.deskID,
                officeName: office.name,
                address: fullAddress(office),
                floor: booking.floor,
                zone: booking.zone,
                day: booking.day,
                startTime: booking.startTime,
                endTime: booking.endTime
            ),
            existingEventID: booking.calendarEventID
        )
        calendarOutcome = outcome
        // Straight assignment: a refused or failed write is already named on
        // the row itself by `calendarTitle`, and `remember` answers those with
        // nil rather than saying the same thing twice in an alert.
        failure = Self.remember(
            outcome,
            save: { identifier in
                booking.calendarEventID = identifier
                try context.save()
            }
        )
    }

    // MARK: What the screen decides

    /// What the tap on "I was here" did.
    ///
    /// `refused` is the case that had no way of being seen.
    /// `BookingStore.recordAttendance` answers a write it will not make by
    /// returning nil rather than by throwing, so a `try?` in statement position
    /// flattened a refusal, an error and a success into one line that did
    /// nothing and said nothing. The compiler had no complaint to make about
    /// it, which is why it outlived the eight of its kind that were warned on.
    enum Recorded: Equatable {
        case recorded
        case refused
        case failed(String)
    }

    /// Records the booking's day as one that was worked.
    ///
    /// The store call arrives as a closure because the two branches this exists
    /// to separate are branches SwiftData will not take on request: a disk that
    /// throws, and a refusal that is not an error at all. It is handed the day,
    /// the office and the booking id rather than closing over them, so a test
    /// can say *which* booking was recorded — the id is what clears
    /// `notAttended` on the row, and answering for the wrong one would be as
    /// silent as answering for none.
    static func record(
        day: Day,
        officeID: UUID,
        bookingID: UUID,
        attend: (Day, UUID, UUID) throws -> Bool
    ) -> Recorded {
        do {
            return try attend(day, officeID, bookingID) ? .recorded : .refused
        } catch {
            return .failed(
                "\(day.dayAndMonth) couldn't be recorded: \(error.localizedDescription). Nothing was saved."
            )
        }
    }

    /// Why the store refused, said in terms of what is actually on that day.
    ///
    /// The store returns nil and no reason, and the reason reachable from this
    /// screen is exactly the one the row cannot see. "I was here" is offered
    /// because *this* office holds nothing for the day — `attended` looks no
    /// further than this booking's office — while `recordAttendance` refuses
    /// any day whose recorded fractions already add to one, wherever they were
    /// recorded. So the reachable refusal is a day already worked somewhere
    /// else, and until this sentence existed the tap left the row still asking
    /// the question it had just been answered.
    static func refusal(
        day: Day, officeID: UUID, attendance: [AttendanceDay], offices: [Office]
    ) -> String {
        let onTheDay = attendance.filter { $0.day == day }
        // The race: the query has not caught up with a row this office already
        // holds. Rare, and it must not fall through to the sentence below,
        // which would blame a building the user was never at.
        if onTheDay.contains(where: { $0.officeID == officeID }) {
            return "\(day.dayAndMonth) is already recorded at this office. Nothing was added."
        }
        let elsewhere = onTheDay.filter { $0.officeID != officeID }
        if !elsewhere.isEmpty {
            return "\(day.dayAndMonth) is already recorded \(at(elsewhere, in: offices)), and a whole day more would take it over one. Remove that day first if it is wrong."
        }
        return "\(day.dayAndMonth) couldn't be recorded. Nothing was added."
    }

    /// Names the building rather than saying "somewhere else", because the
    /// user's next move is to go and look at that day, and "somewhere else" is
    /// not a place you can go and look. Two are possible — a morning at one
    /// site and an afternoon at another add to a whole day — and an office the
    /// user has since deleted has no name to give, which is why the anonymous
    /// wording survives as the fallback rather than as the only option.
    private static func at(_ rows: [AttendanceDay], in offices: [Office]) -> String {
        var names: [String] = []
        for row in rows {
            guard let name = offices.first(where: { $0.id == row.officeID })?.name else { continue }
            if !names.contains(name) { names.append(name) }
        }
        guard let last = names.last else { return "at another office" }
        if names.count == 1 { return "at \(last)" }
        return "at \(names.dropLast().joined(separator: ", ")) and \(last)"
    }

    /// Stores the identifier of an event that is already in the user's
    /// calendar, and says so when it cannot.
    ///
    /// This is the save that must not fail quietly. By the time it runs the
    /// event has been written; the identifier is the only thing that stops this
    /// screen offering to write it again, because `hasEvent` is how the row
    /// decides. A `try?` here left a booking with an event in the calendar and
    /// no memory of it, and the twin that `CalendarWriter`'s refusal exists to
    /// prevent got written by the next tap with nothing on screen having ever
    /// said why.
    ///
    /// `.denied` and `.failed` return nil rather than a sentence: nothing was
    /// written, so there is nothing to remember, and the row already says what
    /// happened in its own title.
    static func remember(
        _ outcome: CalendarWriter.Outcome,
        save: (String) throws -> Void
    ) -> String? {
        switch outcome {
        case .added(let identifier), .updated(let identifier):
            do {
                try save(identifier)
                return nil
            } catch {
                return "The event is in your calendar, but this booking couldn't record that it is: \(error.localizedDescription). If it offers to add it again, don't — that would write a second copy."
            }
        case .denied, .failed:
            return nil
        }
    }

    /// What the day itself has to say, once you know whether it was worked.
    ///
    /// Three states rather than two. A day still ahead is neither attended nor
    /// something to put an "I was here" under — offering it would let the user
    /// record a day that has not happened, which is the exact conflation the
    /// AttendanceDay / DeskBooking split exists to prevent.
    ///
    /// The confirmation names how the day was recorded, because the two are not
    /// equally trustworthy: the geofence saw the user arrive, and "by hand" is
    /// somebody remembering. A row that flattened them would hide which of the
    /// eight days are hearsay.
    enum Standing: Equatable {
        case attended(String)
        case offerAttendance
        case tooEarlyToSay
    }

    static func standing(
        attendedVia source: AttendanceSource?, day: Day, today: Day
    ) -> Standing {
        if let source {
            return .attended(
                "Attended — confirmed \(source == .geofence ? "on arrival" : "by hand")"
            )
        }
        return isPast(day, today: today) ? .offerAttendance : .tooEarlyToSay
    }

    /// The day you are standing in counts as past.
    ///
    /// `<` rather than `<=` would be the reading of "past" that hides the
    /// commonest case there is: the arrival alert fires in the morning and the
    /// user answers it hours before the day is over, so today is precisely the
    /// day "I was here" has to be offerable on. `today` is a parameter so a
    /// test can pin one — the device's day is not something a test may assume.
    static func isPast(_ day: Day, today: Day) -> Bool { day <= today }

    private func openDirections() {
        guard let url = Self.directionsURL(for: office) else { return }
        UIApplication.shared.open(url)
    }

    /// Both whether the Directions row works and where it goes, from one
    /// function, so the two cannot disagree: a live-looking row that opened
    /// nothing when tapped is a silent failure, and a grey one over a perfectly
    /// good address is a feature that has quietly gone missing.
    ///
    /// An office at 0,0 is one the geocoder could not find, not one in the
    /// Atlantic — see `Office.isLocated`.
    static func directionsURL(for office: Office?) -> URL? {
        guard let office, office.isLocated else { return nil }
        return directionsURL(
            latitude: office.latitude, longitude: office.longitude, name: office.name
        )
    }

    /// Apple Maps rather than a web link: it is on every device this runs on,
    /// and it hands straight to walking directions.
    ///
    /// Built through `URLComponents` and never by interpolating into a string.
    /// The office name is not ours — the user types it, and the capture sheet
    /// writes it from whatever a model read off a screenshot — and it lands in
    /// a query *value*. The obvious hand-rolled encoding,
    /// `addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)`, is
    /// the wrong set for that: `urlQueryAllowed` is the set legal *anywhere*
    /// in a query string, so it deliberately leaves `&` and `=` alone. An
    /// office called "Bar & Grill" truncates the name at the ampersand and
    /// turns the rest into junk parameters, and one called
    /// "Coleman&dirflg=d" appends a real Apple Maps parameter and quietly
    /// changes the travel mode the app opens in. `URLQueryItem` escapes for
    /// the position the value actually occupies, which is the only encoder
    /// that can be right here.
    ///
    /// https rather than http: the Maps app claims the URL so nothing goes
    /// over the wire today, but if it ever fell through to Safari the
    /// plaintext scheme would be a needless liability.
    static func directionsURL(latitude: Double, longitude: Double, name: String) -> URL? {
        var components = URLComponents(string: "https://maps.apple.com/")
        components?.queryItems = [
            URLQueryItem(name: "daddr", value: "\(latitude),\(longitude)"),
            URLQueryItem(name: "q", value: name),
        ]
        return components?.url
    }
}
