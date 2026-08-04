import SwiftData
import SwiftUI

/// Screen 4b — the one screen where the theme earns itself. A target acquired
/// at 50m, desk number sized to be read at a glance.
///
/// The design shows this on the lock screen. A `UNNotification` cannot be
/// styled, so the notification carries the same words and this is what opening
/// it lands on — the full readout, at the size the design intends.
struct ArrivalScreen: View {
    let placeID: UUID
    let bookingID: UUID?
    let day: Day

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var places: [Place]
    @Query private var bookings: [Booking]

    @State private var confirmed = false
    private let copy = Copy.shared

    private var place: Place? { places.first { $0.id == placeID } }
    private var desk: DeskDetail? {
        bookings.first { $0.id == bookingID }?.detail?.deskDetail
    }

    var body: some View {
        ScreenBackground {
            VStack(spacing: 0) {
                clock
                Spacer(minLength: 0)
                panel
                    .padding(.horizontal, 14)
                footnote
                    .padding(.top, 16)
                    .padding(.horizontal, 14)
                Spacer(minLength: 0)
                actions
                    .padding(.horizontal, 14)
                    .padding(.bottom, 34)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .navigationBarBackButtonHidden()
    }

    private var clock: some View {
        VStack(spacing: 6) {
            Text("\(day.weekdayAbbreviation) \(String(format: "%02d", day.day)) \(String(day.monthName.prefix(3)))")
                .t8(.lockDate)
                .foregroundStyle(Palette.boneSecondary)
            Text(TimeDisplay.local(.now, in: TimeDisplay.uk))
                .t8(.clock)
                .foregroundStyle(Palette.bone)
                .monospacedDigit()
        }
        .padding(.top, 74)
    }

    private var panel: some View {
        HUDPanel(
            border: Palette.rail.opacity(0.45),
            fill: Palette.rail.opacity(0.07),
            ticks: true,
            padding: EdgeInsets(top: 16, leading: 16, bottom: 17, trailing: 16)
        ) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 9) {
                    Rectangle().fill(Palette.rail).frame(width: 7, height: 7)
                    Text(copy(.targetAcquired))
                        .t8(.appTitle)
                        .foregroundStyle(Palette.rail)
                    Spacer(minLength: 8)
                    Text("\(Int(place?.radiusMetres ?? 50))m")
                        .t8(.tripSpan)
                        .foregroundStyle(Palette.bone.opacity(0.4))
                }

                if let place {
                    Text("\(place.name.uppercased()) ▪ \(place.postcode.uppercased())")
                        .t8(.lockDetail)
                        .foregroundStyle(Palette.bone.opacity(0.55))
                        .padding(.top, 14)
                }

                // The desk id is the hero — this is the number you need at the
                // barrier, and it is sized to be read without stopping.
                BracketedFigure(
                    text: desk?.deskID.uppercased() ?? "NO DESK",
                    figureStyle: .alertFigure,
                    bracketStyle: .bracketHuge,
                    figureColour: Palette.desk,
                    bracketColour: Palette.rail.opacity(0.5)
                )
                .padding(.top, 12)

                if !whereabouts.isEmpty {
                    HStack(spacing: 18) {
                        ForEach(whereabouts, id: \.self) { item in
                            Text(item)
                        }
                    }
                    .t8(.lockDetail)
                    .foregroundStyle(Palette.bone.opacity(0.55))
                    .padding(.top, 14)
                }

                Text(countLine)
                    .t8(.lockNote)
                    .foregroundStyle(Palette.bone.opacity(0.45))
                    .padding(.top, 13)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(alignment: .top) {
                        Rectangle()
                            .fill(Palette.rail.opacity(0.25))
                            .frame(height: Metrics.hairline)
                    }
                    .padding(.top, 14)
            }
        }
    }

    private var whereabouts: [String] {
        var items: [String] = []
        if let floor = desk?.floor { items.append(Abbreviate.level(floor)) }
        if let zone = desk?.zone { items.append("ZONE \(zone.uppercased())") }
        return items
    }

    private var countLine: String {
        guard let snapshot = try? QuotaService.snapshot(
            for: day.month_, today: day, in: context
        ) else { return "" }
        let attended = Int(snapshot.result.attended.rounded()) + (confirmed ? 0 : 1)
        let target = snapshot.result.target
        let state = confirmed
            ? copy(.terminated)
            : (desk == nil ? "NOT BOOKED" : copy(.terminated))
        return "DAY \(String(format: "%02d", attended)) OF \(String(format: "%02d", target)) ▪ \(state)"
    }

    /// The fire-once rule, said out loud. The design puts it on the screen
    /// because it is the behaviour people most need to trust.
    private var footnote: some View {
        Text(
            confirmed
                ? "LOGGED FOR \(stamp). NO RE-FIRE ON RE-ENTRY."
                : "SINGLE DISCHARGE. NOTHING IS RECORDED UNTIL YOU CONFIRM."
        )
        .t8(.lockFootnote)
        .foregroundStyle(Palette.bone.opacity(0.24))
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
    }

    private var stamp: String {
        String(format: "%02d.%02d.%02d", day.day, day.month, day.year % 100)
    }

    /// The offer. Nothing has moved the count before this is tapped.
    @ViewBuilder
    private var actions: some View {
        if confirmed {
            OutlinedAction(title: "CLOSE") { dismiss() }
        } else {
            HStack(spacing: 9) {
                OutlinedAction(title: "NOT TODAY") { dismiss() }
                SolidAction(title: copy(.confirmArrival), fill: Palette.desk) {
                    // The ledger, not the monitor: confirming needs no
                    // location manager.
                    ArrivalLedger(context: context)
                        .confirmAttendance(placeID: placeID, bookingID: bookingID, day: day)
                    confirmed = true
                }
            }
        }
    }
}

nonisolated extension T8Font {
    static let lockDate = T8Font(12, tracking: 0.20)
    static let lockDetail = T8Font(11, tracking: 0.12)
    static let lockNote = T8Font(10.5, tracking: 0.07, lineHeight: 1.5)
    static let lockFootnote = T8Font(10, tracking: 0.09, lineHeight: 1.7)
    static let bracketHuge = T8Font(30)
}
