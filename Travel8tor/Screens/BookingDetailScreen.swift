import SwiftData
import SwiftUI

/// One booking: the desk number large enough to read at a glance, where it is,
/// and whether the day was actually attended.
struct BookingDetailScreen: View {
    @Environment(\.modelContext) private var context
    @Query private var offices: [Office]
    @Query private var attendance: [AttendanceDay]

    let booking: DeskBooking

    private var office: Office? {
        offices.first { $0.id == booking.officeID }
    }

    private var attended: AttendanceDay? {
        attendance.first { $0.day == booking.day && $0.officeID == booking.officeID }
    }

    private var isPast: Bool { booking.day <= .today }

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
                // Add to calendar arrives with the rest of the handoff's stage
                // 6, and "view original" needs a capture to have an original —
                // both are deliberately absent rather than dead.
            }
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
