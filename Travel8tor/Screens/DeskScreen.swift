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

    /// Whatever the last handoff said. Nil until one is tapped — the design
    /// shows two bare buttons and this only appears when there is something to
    /// report.
    @State private var handoff: (text: String, problem: Bool)?

    private var booking: Booking? { bookings.first { $0.id == bookingID } }

    var body: some View {
        ScreenScaffold {
            if let booking, let desk = booking.detail?.deskDetail {
                VStack(alignment: .leading, spacing: 0) {
                    panel(booking, desk)
                    actions(booking, desk).padding(.top, 11)
                    if let handoff {
                        handoffStrip(handoff).padding(.top, 9)
                    }
                    effectOnCount(booking, desk).padding(.top, 20)
                }
                #if DEBUG
                // `-screen desk -tap calendar` runs the action a finger would.
                // There is no way to drive a tap from the command line, and an
                // action that has only ever been read is an action untested.
                .task { await runDebugTap(booking, desk) }
                #endif
            }
        }
    }

    #if DEBUG
    private func runDebugTap(_ booking: Booking, _ desk: DeskDetail) async {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-tap"), index + 1 < arguments.count
        else { return }
        let place = places.first { $0.id == desk.placeID }
        switch arguments[index + 1] {
        case "calendar": await addToCalendar(booking, desk, place)
        case "directions":
            guard let place else { return }
            handoff = Directions.open(
                name: place.name, latitude: place.latitude, longitude: place.longitude,
                // Not the real opener: launching Maps would replace the screen
                // being screenshotted.
                opener: { _ in }
            ).message.map { ($0, true) }
        default: break
        }
    }
    #endif

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

    private func actions(_ booking: Booking, _ desk: DeskDetail) -> some View {
        let place = places.first { $0.id == desk.placeID }
        let written = booking.calendarEventID != nil

        return HStack(spacing: 9) {
            OutlinedAction(title: "DIRECTIONS") {
                guard let place else {
                    handoff = ("NO BUILDING RECORD FOR THIS DESK.", true)
                    return
                }
                let outcome = Directions.open(
                    name: place.name, latitude: place.latitude, longitude: place.longitude
                )
                handoff = outcome.message.map { ($0, true) }
            }
            OutlinedAction(
                title: written ? "IN CALENDAR" : "CALENDAR",
                // Brightness carries status here as it does everywhere: an
                // action already taken reads at a lower strength.
                border: written ? Palette.rail.opacity(0.18) : Palette.railBorder
            ) {
                Task { await addToCalendar(booking, desk, place) }
            }
        }
    }

    private func addToCalendar(_ booking: Booking, _ desk: DeskDetail, _ place: Place?) async {
        // A desk with no end time is not an event. The never-guess rule again:
        // rather than inventing a finish, say what is missing.
        guard let endsAt = booking.endsAt else {
            handoff = ("NO FINISH TIME READ FOR THIS DESK.", true)
            return
        }

        let (outcome, eventID) = await CalendarWriter.add(
            .init(
                deskID: desk.deskID,
                placeName: desk.placeName,
                address: place?.address,
                postcode: place?.postcode,
                floor: desk.floor,
                startsAt: booking.startsAt,
                endsAt: endsAt,
                timeZone: booking.endZone ?? booking.startZone
            ),
            existingEventID: booking.calendarEventID
        )

        if let eventID, outcome == .added {
            booking.calendarEventID = eventID
            try? context.save()
        }
        handoff = (outcome.message, outcome.isProblem)
    }

    private func handoffStrip(_ handoff: (text: String, problem: Bool)) -> some View {
        let colour = handoff.problem ? Palette.desk : Palette.stay
        return HStack(spacing: 9) {
            Rectangle().fill(colour).frame(width: 6, height: 6)
            Text(handoff.text)
                .t8(.offline)
                .foregroundStyle(colour)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 11)
        .padding(.horizontal, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(colour.opacity(0.06))
        .overlay { Rectangle().strokeBorder(colour.opacity(0.35), lineWidth: Metrics.hairline) }
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
