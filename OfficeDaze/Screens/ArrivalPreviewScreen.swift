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
        Self.selectedOffice(in: offices, selection: officeID)
    }

    private var desk: ArrivalRule.Booking? {
        guard let office else { return nil }
        return Self.desk(at: office, bookings: bookings, today: .today)
    }

    private var content: ArrivalNotifications.Content? {
        Self.content(for: office, bookings: bookings, today: .today, in: context)
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
                    Text(Self.caption(hasDesk: desk != nil))
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
            officeID = Self.openingOfficeID(
                offices: offices, bookings: bookings, today: .today
            )
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
            let lines = Self.cardText(content.body)
            ForEach(lines.details, id: \.self) { line in
                Text(line)
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(.top, 10)
            }
            if let footer = lines.footer {
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

// MARK: - What the preview decides

/// Everything on this screen that is a judgement rather than a layout, pulled
/// out of the view.
///
/// This screen's whole claim is that it shows what the lock screen will show,
/// and a claim like that is worth holding to by test rather than by eye —
/// especially as the only other way to check it is to walk into a building.
/// The view keeps the drawing; the decisions live here.
extension ArrivalPreviewScreen {

    /// Falls back to the first office rather than to nothing: a screen with an
    /// office on it and no selection would show the empty state to someone who
    /// has an office, which is the one reading that is never true.
    static func selectedOffice(in offices: [Office], selection: UUID?) -> Office? {
        offices.first { $0.id == selection } ?? offices.first
    }

    /// The office the screen opens on — one with a desk booked today, because
    /// that is the case the alert exists for rather than the empty one.
    ///
    /// The booked office has to be one that still exists. Deleting a building
    /// deliberately leaves its desk bookings behind pointing nowhere — see
    /// `OfficeEditorScreen.removeOffice`, which keeps them and lets the row read
    /// "Unknown office" — so today's booking can name an id no segment of the
    /// picker carries. Selecting it left the segmented control drawn with
    /// nothing selected while `selectedOffice` fell back to the first office and
    /// the card below showed *that* building's alert: two controls on one screen
    /// disagreeing about which office is being previewed, on the default path,
    /// with no way back except tapping a segment.
    static func openingOfficeID(
        offices: [Office], bookings: [DeskBooking], today: Day
    ) -> UUID? {
        let known = Set(offices.map(\.id))
        let booked = bookings
            .first { $0.day == today && known.contains($0.officeID) }?
            .officeID
        return booked ?? offices.first?.id
    }

    /// Today's booking at that office, if there is one — which is exactly the
    /// question `ArrivalRule.decide` asks when the perimeter is crossed, put in
    /// the same projection so the copy below is built from the same shape.
    static func desk(
        at office: Office, bookings: [DeskBooking], today: Day
    ) -> ArrivalRule.Booking? {
        bookings
            .first { $0.officeID == office.id && $0.day == today }
            .map {
                ArrivalRule.Booking(
                    id: $0.id, officeID: $0.officeID, day: $0.day,
                    deskID: $0.deskID, floor: $0.floor, zone: $0.zone
                )
            }
    }

    /// The alert, built the way `ArrivalLedger.deliver` builds it: same
    /// function, same snapshot, same month name. If these two ever drift the
    /// screen is a mock-up rather than a preview, which is the one thing it
    /// must not be.
    static func content(
        for office: Office?, bookings: [DeskBooking], today: Day, in context: ModelContext
    ) -> ArrivalNotifications.Content? {
        guard let office else { return nil }
        let snapshot = try? QuotaService.snapshot(
            for: today.month_, today: today, in: context
        )
        return ArrivalNotifications.content(
            officeName: office.name,
            desk: desk(at: office, bookings: bookings, today: today),
            attended: snapshot?.result.attended ?? 0,
            target: snapshot?.result.target ?? 0,
            monthName: monthName(today.month_),
            alreadyRecorded: snapshot?.attendedDays.contains(today) ?? false
        )
    }

    /// `August`, from `August 2026`. The alert has one line to say which month
    /// the count is for and the year is not in doubt.
    static func monthName(_ month: Month) -> String {
        String(month.text.split(separator: " ").first ?? "")
    }

    /// The sentence under the card. With a desk it explains when the alert
    /// repeats; without one it explains why an alert arrives at all, which is
    /// the question that screen state actually raises.
    static func caption(hasDesk: Bool) -> String {
        hasDesk
            ? ArrivalCopy.preview
            : "No desk booked today, so the alert offers to record the day anyway."
    }

    /// The alert body, split into the lines drawn as body text and the one
    /// drawn small under a hairline.
    struct CardText: Equatable {
        var details: [String]
        var footer: String?
    }

    /// A footer only when there is a line above for the hairline to separate it
    /// from.
    ///
    /// Taking `last` unconditionally was wrong for a one-line body, and a
    /// one-line body is ordinary: a desk whose floor and zone were both
    /// unreadable has nothing to say but the day count, and turning up with
    /// nothing booked on a day already recorded elsewhere says only "No desk
    /// booked today." Both drew that single line at 13pt and 45% white under a
    /// rule with nothing above it — a footnote where iOS draws body text. On the
    /// one screen whose entire job is to be what the lock screen shows, that is
    /// the preview being wrong about the thing it previews.
    static func cardText(_ body: String) -> CardText {
        let lines = body.split(separator: "\n").map(String.init)
        guard lines.count > 1 else { return CardText(details: lines, footer: nil) }
        return CardText(details: Array(lines.dropLast()), footer: lines.last)
    }
}
