import SwiftData
import SwiftUI

/// The incomplete-data case. The header bar is `stay` cyan because it is a
/// stay, but the panel border is `desk` amber because fields are missing —
/// type is hue, and the amber is a separate claim laid over it.
///
/// Unknown values render `??:??`. Never a guess, never a blank.
struct StayScreen: View {
    let bookingID: UUID

    @Query private var bookings: [Booking]
    @Query private var captures: [Capture]

    private let copy = Copy.shared

    private var booking: Booking? { bookings.first { $0.id == bookingID } }

    var body: some View {
        ScreenScaffold {
            if let booking, let stay = booking.detail?.stayDetail {
                VStack(alignment: .leading, spacing: 0) {
                    panel(booking, stay)
                    if booking.hasUnreadableFields {
                        incompletePanel(booking).padding(.top, 12)
                    }
                    provenanceFooter(booking).padding(.top, 11)
                }
            }
        }
    }

    private func panel(_ booking: Booking, _ stay: StayDetail) -> some View {
        VStack(spacing: 0) {
            DetailHeaderBar(
                typeCode: "[STAY] \(stay.nights == 1 ? "1 NIGHT" : "\(stay.nights) NIGHTS")",
                stamp: TimeDisplay.dayStamp(booking.anchorDay),
                colour: Palette.stay
            )

            VStack(alignment: .leading, spacing: 0) {
                Text(stay.hotelName.uppercased())
                    .t8(.screenTitle)
                    .foregroundStyle(Palette.bone)

                if let address = stay.address {
                    Text(address.uppercased())
                        .t8(.panelBody)
                        .foregroundStyle(Palette.boneSecondary)
                        .padding(.top, 6)
                }

                CellGrid(cells: [
                    timeCell("CHECK IN", stay.checkIn, booking.startZone),
                    timeCell("CHECK OUT", stay.checkOut, booking.endZone ?? booking.startZone),
                ])
                .padding(.top, 16)
            }
            .padding(.vertical, 18)
            .padding(.horizontal, 16)
        }
        // Amber when something could not be read, cyan when it is all there.
        .overlay {
            Rectangle().strokeBorder(
                booking.hasUnreadableFields
                    ? Palette.desk.opacity(0.5)
                    : Palette.stay.opacity(0.4),
                lineWidth: Metrics.hairline
            )
        }
    }

    private func timeCell(_ label: String, _ instant: Date?, _ zone: TimeZone) -> CellGrid.Cell {
        guard let instant else {
            return .init(label: label, value: BookingPresentation.unread, colour: Palette.desk)
        }
        return .init(label: label, value: TimeDisplay.local(instant, in: zone))
    }

    private func incompletePanel(_ booking: Booking) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("⚠ \(copy(.dataIncomplete)) ▪ \(String(format: "%02d", booking.unsureFields.count)) FIELDS")
                .t8(.incompleteHeader)
                .foregroundStyle(Palette.desk)

            Text(explanation(booking))
                .t8(.panelBody)
                .foregroundStyle(Palette.bone.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)
                .padding(.bottom, 14)

            VStack(spacing: 8) {
                ForEach(booking.unsureFields, id: \.self) { field in
                    HStack(spacing: 10) {
                        Text(fieldLabel(field))
                            .t8(.fieldLabel)
                            .foregroundStyle(Palette.bone.opacity(0.4))
                            .frame(width: 82, alignment: .leading)
                        // Editing lands with capture, in stage 4.
                        Text("TAP TO SET")
                            .t8(.fieldValue)
                            .foregroundStyle(Palette.bone.opacity(0.28))
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 10)
                    .padding(.horizontal, 12)
                    .overlay {
                        Rectangle().strokeBorder(Palette.desk.opacity(0.5), lineWidth: Metrics.hairline)
                    }
                }
            }

            SolidAction(title: "COMMIT").padding(.top, 14)
        }
        .padding(.top, 15)
        .padding(.horizontal, 15)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.desk.opacity(0.08))
        .overlay { Rectangle().strokeBorder(Palette.desk, lineWidth: Metrics.hairline) }
    }

    /// Says what happened, not just that something is missing — the design's
    /// "SCREENGRAB CUT OFF BELOW ROOM LINE. NO VALUES INFERRED."
    private func explanation(_ booking: Booking) -> String {
        let source = switch booking.provenance {
        case .screengrab: "SCREENGRAB CUT OFF BELOW ROOM LINE."
        case .email: "EMAIL DID NOT STATE THESE FIELDS."
        case .pass: "PASS FILE OMITTED THESE FIELDS."
        case .manual: "NOT ENTERED."
        }
        return "\(source) NO VALUES INFERRED."
    }

    private func fieldLabel(_ field: String) -> String {
        switch field {
        case "checkIn": "CHECK-IN"
        case "checkOut": "CHECK-OUT"
        case "bookingRef": "REF"
        case "hotelName": "HOTEL"
        case "address": "ADDRESS"
        default: field.uppercased()
        }
    }

    private func provenanceFooter(_ booking: Booking) -> some View {
        let capture = captures.first { $0.id == booking.captureID }
        let stamp = capture.map {
            let day = Day(of: $0.receivedAt, in: TimeDisplay.uk)
            return String(format: " %02d.%02d", day.day, day.month)
        } ?? ""

        return VStack(alignment: .leading, spacing: 8) {
            Group {
                if booking.hasUnreadableFields {
                    Text("SOURCE ▪ \(booking.provenance.rawValue.uppercased())\(stamp) ▪ CONFIDENCE ")
                        + Text("LOW").foregroundColor(Palette.desk)
                        + Text(" ON \(String(format: "%02d", booking.unsureFields.count)) FIELDS")
                } else {
                    Text("SOURCE ▪ \(booking.provenance.rawValue.uppercased())\(stamp) ▪ ALL FIELDS READ")
                }
            }
            .t8(.provenance)
            .foregroundStyle(Palette.boneSecondary)
            .fixedSize(horizontal: false, vertical: true)

            if capture != nil {
                Text("VIEW ORIGINAL")
                    .t8(.provenance)
                    .foregroundStyle(Palette.stay)
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay { Rectangle().strokeBorder(Palette.rail.opacity(0.22), lineWidth: Metrics.hairline) }
    }
}

nonisolated extension T8Font {
    static let incompleteHeader = T8Font(10, bold: true, tracking: 0.18)
    static let fieldLabel = T8Font(9, tracking: 0.13)
    static let fieldValue = T8Font(12, bold: true)
    static let provenance = T8Font(10, tracking: 0.05, lineHeight: 1.6)
}
