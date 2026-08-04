import SwiftData
import SwiftUI

/// The desk id is the hero. Below it, what this booking would do to the month's
/// count — which is forecast, not attendance: booking a desk doesn't move the
/// eight, turning up does.
struct DeskScreen: View {
    let bookingID: UUID

    @Environment(\.modelContext) private var context
    @Query private var bookings: [Booking]
    @Query private var places: [Place]

    private let copy = Copy.shared
    private let today = Day.today

    private var booking: Booking? { bookings.first { $0.id == bookingID } }

    var body: some View {
        ScreenScaffold {
            if let booking, let desk = booking.detail?.deskDetail {
                VStack(alignment: .leading, spacing: 0) {
                    panel(booking, desk)
                    actions.padding(.top, 11)
                    effectOnCount(booking, desk).padding(.top, 20)
                }
            }
        }
    }

    private func panel(_ booking: Booking, _ desk: DeskDetail) -> some View {
        let place = places.first { $0.id == desk.placeID }

        return VStack(spacing: 0) {
            DetailHeaderBar(
                typeCode: headerCode(booking, desk),
                stamp: TimeDisplay.dayStamp(booking.anchorDay),
                colour: Palette.desk
            )

            VStack(alignment: .leading, spacing: 0) {
                BracketedFigure(
                    text: desk.deskID.uppercased(),
                    figureStyle: .heroFigure,
                    bracketStyle: .bracketLarge,
                    figureColour: Palette.bone,
                    bracketColour: Palette.desk.opacity(0.5)
                )

                Text(desk.placeName.uppercased())
                    .t8(.placeName)
                    .foregroundStyle(Palette.bone)
                    .padding(.top, 14)

                if let place {
                    Text("\(place.address.uppercased()) ▪ \(place.postcode.uppercased())")
                        .t8(.panelBody)
                        .foregroundStyle(Palette.boneSecondary)
                        .padding(.top, 5)
                }

                CellGrid(
                    cells: [
                        .init(label: "FLOOR", value: desk.floor ?? BookingPresentation.unread),
                        .init(label: "ZONE", value: desk.zone ?? BookingPresentation.unread),
                        .init(label: "HOURS", value: desk.hours ?? BookingPresentation.unread),
                    ],
                    border: Palette.desk.opacity(0.3)
                )
                .padding(.top, 18)
            }
            .padding(.top, 20)
            .padding(.horizontal, 16)
            .padding(.bottom, 18)
        }
        .overlay { Rectangle().strokeBorder(Palette.desk.opacity(0.4), lineWidth: Metrics.hairline) }
    }

    private func headerCode(_ booking: Booking, _ desk: DeskDetail) -> String {
        guard desk.countsToQuota else { return "[DESK] NO COUNT" }
        let target = (try? QuotaService.snapshot(
            for: booking.anchorDay.month_, today: today, in: context
        ))?.result.target
        let suffix = target.map { " OF \(String(format: "%02d", $0))" } ?? ""
        return "[DESK] \(copy(.counts)) 1\(suffix)"
    }

    private var actions: some View {
        HStack(spacing: 9) {
            // Both land in stage 6 — Maps handoff and the calendar write.
            OutlinedAction(title: "DIRECTIONS")
            OutlinedAction(title: "CALENDAR")
        }
    }

    @ViewBuilder
    private func effectOnCount(_ booking: Booking, _ desk: DeskDetail) -> some View {
        let month = booking.anchorDay.month_
        if desk.countsToQuota,
           let snapshot = try? QuotaService.snapshot(for: month, today: today, in: context) {
            let result = snapshot.result
            VStack(alignment: .leading, spacing: 10) {
                SectionKicker(text: copy(.effectOnCount))
                DerivationPanel(lines: [
                    .init(
                        label: "\(month.name) TARGET",
                        value: String(format: "%02d", result.target)
                    ),
                    .init(
                        label: copy.terminator ? "INCLUDING THIS KILL" : "INCLUDING THIS DAY",
                        value: String(format: "%02d", Int((result.attended + result.forecast).rounded()))
                    ),
                    .init(
                        label: copy(.leftAlive),
                        value: String(format: "%02d", Int(result.shortfall.rounded())),
                        labelColour: Palette.rail,
                        valueColour: Palette.rail
                    ),
                ])
            }
        }
    }
}

nonisolated extension T8Font {
    static let placeName = T8Font(13, bold: true, tracking: 0.08)
}
