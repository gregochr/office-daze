import SwiftData
import SwiftUI

/// Screen 7: the arrival alert as it will land on the lock screen.
///
/// A preview rather than a mock-up — it builds the same `ArrivalNotifications`
/// content the geofence will, from the same store, so the copy on this screen
/// is the copy that fires. Worth having: the alert is the whole reason the app
/// exists and it is otherwise only visible by walking into a building.
struct ArrivalPreviewScreen: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Office.name) private var offices: [Office]
    @Query(sort: \DeskBooking.date) private var bookings: [DeskBooking]

    @State private var officeID: UUID?

    private var office: Office? {
        offices.first { $0.id == officeID } ?? offices.first
    }

    /// Today's booking at that office, if there is one — which is exactly the
    /// question the rule asks.
    private var desk: ArrivalRule.Booking? {
        guard let office else { return nil }
        return bookings
            .first { $0.officeID == office.id && $0.day == .today }
            .map {
                ArrivalRule.Booking(
                    id: $0.id, officeID: $0.officeID, day: $0.day,
                    deskID: $0.deskID, floor: $0.floor, zone: $0.zone
                )
            }
    }

    private var content: ArrivalNotifications.Content? {
        guard let office else { return nil }
        let snapshot = try? QuotaService.snapshot(
            for: Day.today.month_, today: .today, in: context
        )
        return ArrivalNotifications.content(
            officeName: office.name,
            desk: desk,
            attended: snapshot?.result.attended ?? 0,
            target: snapshot?.result.target ?? 0,
            monthName: String(Day.today.month_.text.split(separator: " ").first ?? ""),
            alreadyRecorded: snapshot?.attendedDays.contains(.today) ?? false
        )
    }

    var body: some View {
        ScrollView {
            VStack(spacing: Metrics.cardGap) {
                if offices.count > 1 {
                    Picker("Office", selection: $officeID) {
                        ForEach(offices) { office in
                            Text(office.name).tag(UUID?.some(office.id))
                        }
                    }
                    .pickerStyle(.segmented)
                }

                if let content {
                    lockScreenCard(content)
                    Text(
                        desk == nil
                            ? "No desk booked today, so the alert offers to record the day anyway."
                            : ArrivalCopy.preview
                    )
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)

                    // The one setting between this alert and the mornings it
                    // was written for. It sits under the preview because this
                    // is the screen you are on when you wonder why the alert
                    // did not arrive.
                    Card(padding: EdgeInsets(top: 13, leading: 14, bottom: 13, trailing: 14)) {
                        Text(ArrivalCopy.workFocus)
                            .font(.system(size: 13))
                            .foregroundStyle(Palette.rowLabel)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Text("Add an office to see the alert.")
                        .font(.system(size: 15))
                        .foregroundStyle(Palette.secondary)
                }
            }
            .padding(.horizontal, Metrics.screenPadding)
            .padding(.top, 8)
            .padding(.bottom, 30)
        }
        .background(Palette.ground)
        .navigationTitle("Arrival alert")
        .navigationBarTitleDisplayMode(.inline)
        // Defaults to an office with a booking today, so the preview opens on
        // the case the alert exists for rather than the empty one.
        .task {
            guard officeID == nil else { return }
            let booked = bookings.first { $0.day == .today }?.officeID
            officeID = booked ?? offices.first?.id
        }
    }

    /// The one place in the app that isn't the light system palette — a lock
    /// screen is dark, and a preview drawn in white would be a preview of
    /// something else.
    private func lockScreenCard(_ content: ArrivalNotifications.Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Palette.tint)
                    .frame(width: 16, height: 16)
                // No "TIME SENSITIVE" here, though the notification asks to be.
                // iOS draws that label only when the entitlement backs it up,
                // and a personal team cannot have that entitlement — see
                // `ArrivalNotifications.request`. This screen is a preview of
                // what lands, so it shows what lands.
                Text("OFFICE DAZE")
                    .font(.system(size: 12, weight: .medium))
                    .kerning(0.4)
                    .foregroundStyle(.white.opacity(0.55))
                Spacer(minLength: 8)
                Text("now")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.45))
            }

            Text(content.subtitle)
                .font(.system(size: 15))
                .foregroundStyle(.white.opacity(0.6))
                .padding(.top, 14)

            // 46pt, and the reason the whole screen exists: readable at arm's
            // length without unlocking.
            Text(content.title)
                .font(.system(size: 46, weight: .bold))
                .kerning(-1.2)
                .foregroundStyle(.white)
                .minimumScaleFactor(0.5)
                .lineLimit(1)
                .padding(.top, 6)

            // The body is detail lines plus a footer, split explicitly rather
            // than indexed out of a joined string — an overlay rule positioned
            // by offset ended up drawn through the line above it.
            let lines = content.body.split(separator: "\n").map(String.init)
            ForEach(lines.dropLast(), id: \.self) { line in
                Text(line)
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(.top, 10)
            }
            if let footer = lines.last {
                Rectangle()
                    .fill(.white.opacity(0.12))
                    .frame(height: 1)
                    .padding(.top, 14)
                Text(footer)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.45))
                    .padding(.top, 13)
            }

            HStack(spacing: 8) {
                previewButton("I'm here")
                previewButton("Not today")
            }
            .padding(.top, 16)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(hex: 0x1C1C1E))
        .clipShape(RoundedRectangle(cornerRadius: Metrics.cardRadius))
    }

    private func previewButton(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white.opacity(0.85))
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity)
            .background(.white.opacity(0.12))
            .clipShape(Capsule())
    }
}
