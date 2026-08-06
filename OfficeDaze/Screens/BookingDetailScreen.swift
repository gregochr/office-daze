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

    private var isPast: Bool { booking.day <= .today }

    @State private var calendarOutcome: CalendarWriter.Outcome?

    var body: some View {
        ScrollView {
            VStack(spacing: Metrics.cardGap) {
                headline
                fields
                if let attended {
                    StatusStrip(
                        tone: .success,
                        leading: "Attended — confirmed \(arrivalText(attended))",
                        dot: true
                    )
                } else if isPast {
                    recordAttendance
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
                ActionRow(title: "Directions", enabled: office?.isLocated == true) {
                    openDirections()
                }
                RowDivider(inset: 0)
                ActionRow(title: calendarTitle) {
                    Task { await addToCalendar() }
                }
                // "View original" needs a capture to have an original, so it
                // only appears when there is one.
            }
        }
    }

    private var calendarTitle: String {
        switch calendarOutcome {
        case .added: "Added to calendar"
        case .updated: "Calendar updated"
        case .denied: "Calendar access refused"
        case .failed: "Couldn't add to calendar"
        // Written once already, from an earlier visit to this screen.
        case nil: booking.calendarEventID == nil ? "Add to calendar" : "Update calendar event"
        }
    }

    /// A second tap updates the event rather than writing a twin — which is the
    /// whole reason the identifier is stored on the booking.
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

    private func arrivalText(_ record: AttendanceDay) -> String {
        record.source == .geofence ? "on arrival" : "by hand"
    }

    private func openDirections() {
        guard let office, office.isLocated else { return }
        let name = office.name.addingPercentEncoding(
            withAllowedCharacters: .urlQueryAllowed
        ) ?? ""
        // Apple Maps rather than a web link: it is on every device this runs
        // on, and it hands straight to walking directions.
        let url = URL(
            string: "http://maps.apple.com/?daddr=\(office.latitude),\(office.longitude)&q=\(name)"
        )
        if let url { UIApplication.shared.open(url) }
    }
}
