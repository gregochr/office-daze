import SwiftData
import SwiftUI

/// Departure-board logic taken literally. The app never renders a barcode —
/// the pass lives in Wallet and this screen holds the readable detail and links
/// across to it.
struct TicketScreen: View {
    let bookingID: UUID

    @Query private var bookings: [Booking]

    private var booking: Booking? { bookings.first { $0.id == bookingID } }

    var body: some View {
        ScreenScaffold {
            if let booking, let rail = booking.detail?.railDetail {
                VStack(alignment: .leading, spacing: 11) {
                    panel(booking, rail)
                    if let reference = rail.bookingRef {
                        referenceRow(reference)
                    }
                    WalletHandoffRow()
                    OfflineStrip()
                }
            }
        }
    }

    private func panel(_ booking: Booking, _ rail: RailDetail) -> some View {
        VStack(spacing: 0) {
            DetailHeaderBar(
                typeCode: "[RAIL] \(rail.operatorName.uppercased())",
                stamp: TimeDisplay.dayStamp(booking.anchorDay),
                colour: Palette.rail
            )

            VStack(alignment: .leading, spacing: 0) {
                journey(booking, rail)
                CellGrid(cells: cells(booking, rail))
                    .padding(.top, 20)
            }
            .padding(.top, 20)
            .padding(.horizontal, 16)
            .padding(.bottom, 18)
        }
        .overlay { Rectangle().strokeBorder(Palette.rail.opacity(0.35), lineWidth: Metrics.hairline) }
    }

    private func journey(_ booking: Booking, _ rail: RailDetail) -> some View {
        let departure = TimeDisplay.stacked(booking.startsAt, in: booking.startZone)
        let arrivalZone = booking.endZone ?? booking.startZone
        let arrival = booking.endsAt.map { TimeDisplay.stacked($0, in: arrivalZone) }

        return HStack(alignment: .top, spacing: 10) {
            endpoint(
                time: departure.time, uk: departure.uk,
                station: rail.originStation.uppercased(), alignment: .leading
            )
            Spacer(minLength: 0)
            if let endsAt = booking.endsAt {
                Text(TimeDisplay.duration(from: booking.startsAt, to: endsAt))
                    .t8(.tripSpan.bolded)
                    .foregroundStyle(Palette.rail.opacity(0.65))
                    .padding(.top, 11)
                Spacer(minLength: 0)
            }
            if let arrival {
                endpoint(
                    time: arrival.time, uk: arrival.uk,
                    station: rail.destStation.uppercased(), alignment: .trailing
                )
            }
        }
    }

    /// The UK line sits directly beneath the figure, in `desk` — never above
    /// it, and never instead of it.
    private func endpoint(
        time: String, uk: String?, station: String, alignment: HorizontalAlignment
    ) -> some View {
        VStack(alignment: alignment, spacing: 0) {
            Text(time)
                .t8(.ticketFigure)
                .foregroundStyle(Palette.bone)
                .monospacedDigit()
            if let uk {
                Text(uk)
                    .t8(.panelBody)
                    .foregroundStyle(Palette.desk.opacity(0.7))
                    .monospacedDigit()
                    .padding(.top, 3)
            }
            Text(station)
                .t8(.ticketStation)
                .foregroundStyle(Palette.bone.opacity(0.6))
                .padding(.top, 8)
        }
    }

    /// Eurostar needs a gate-by time and has no platform until the day; a
    /// domestic ticket has a platform and no gate. The grid follows the
    /// booking rather than being one fixed shape with blanks in it.
    private func cells(_ booking: Booking, _ rail: RailDetail) -> [CellGrid.Cell] {
        var cells: [CellGrid.Cell] = []
        if let checkInBy = rail.checkInBy {
            if let coach = rail.coach { cells.append(.init(label: "COACH", value: coach)) }
            if let seat = rail.seat { cells.append(.init(label: "SEAT", value: seat)) }
            cells.append(.init(
                label: "GATE BY",
                value: TimeDisplay.local(checkInBy, in: booking.startZone),
                colour: Palette.desk
            ))
        } else {
            cells.append(.init(
                label: "PLAT",
                value: rail.platform.map { $0.count == 1 ? "0\($0)" : $0 }
                    ?? BookingPresentation.unread,
                colour: rail.platform == nil ? Palette.desk : Palette.bone
            ))
            if let coach = rail.coach { cells.append(.init(label: "COACH", value: coach)) }
            if let seat = rail.seat { cells.append(.init(label: "SEAT", value: seat)) }
        }
        return cells
    }

    private func referenceRow(_ reference: String) -> some View {
        HStack {
            Text("REF")
                .t8(.cellLabel)
                .foregroundStyle(Palette.bone.opacity(0.4))
            Text(reference)
                .t8(.walletTitle)
                .foregroundStyle(Palette.bone)
            Spacer(minLength: 8)
            Button {
                UIPasteboard.general.string = reference
            } label: {
                Text("COPY")
                    .t8(.action)
                    .foregroundStyle(Palette.stay)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .overlay { Rectangle().strokeBorder(Palette.rail.opacity(0.25), lineWidth: Metrics.hairline) }
    }
}
