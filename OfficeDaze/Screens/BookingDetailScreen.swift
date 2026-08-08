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
                try? BookingStore.recordAttendance(
                    day: booking.day, officeID: booking.officeID,
                    source: .manual, bookingID: booking.id, in: context
                )
            }
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
        switch outcome {
        case .added(let id), .updated(let id):
            booking.calendarEventID = id
            try? context.save()
        case .denied, .failed:
            break
        }
    }

    // MARK: What the screen decides

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
