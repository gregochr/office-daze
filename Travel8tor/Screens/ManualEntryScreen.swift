import SwiftData
import SwiftUI

/// Typing a booking in by hand. Reached from the capture failure's ENTER
/// MANUALLY, and from the `+` on Targets for a booking that was never going to
/// come from a screenshot at all.
///
/// It commits through exactly the same path a capture does — dedupe, place
/// resolution, regrouping — so typing over a bad capture corrects it rather
/// than adding a duplicate. `manual` outranks every other provenance, so the
/// typed version wins and the capture's empty fields are filled from it.
struct ManualEntryScreen: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    let coordinator: CaptureCoordinator
    /// Called after a successful commit. The failure path uses it to tear down
    /// the confirm screen underneath, which would otherwise still be showing
    /// the parse that has just been superseded by hand.
    var onCommit: () -> Void = {}

    @State private var draft = ManualEntry.Draft()
    @State private var problem: ManualEntry.Problem?

    private let copy = Copy.shared

    var body: some View {
        ScreenScaffold(backTitle: "CANCEL") {
            ScreenTitleBlock(title: "BY HAND", subtitle: "PROVENANCE ▪ MANUAL")
        } content: {
            VStack(alignment: .leading, spacing: 0) {
                kindSelector

                VStack(spacing: 8) {
                    switch draft.kind {
                    case .rail: railFields
                    case .desk: deskFields
                    case .stay: stayFields
                    }
                }
                .padding(.top, 16)

                if let problem {
                    problemStrip(problem).padding(.top, 12)
                }

                SolidAction(title: copy(.acquireTarget), fill: Palette.desk) { commit() }
                    .padding(.top, 14)

                Text(note)
                    .t8(.panelBody)
                    .foregroundStyle(Palette.bone.opacity(0.4))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 14)
            }
        }
    }

    private var note: String {
        """
        A FIELD LEFT BLANK IS STORED AS ABSENT, NOT AS UNREADABLE — NO AMBER \
        FLAG. THE FLAG MEANS THE MACHINE COULD NOT READ SOMETHING, AND HERE \
        THERE IS NO MACHINE.
        """
    }

    // MARK: Kind

    private var kindSelector: some View {
        HStack(spacing: 8) {
            ForEach(ManualEntry.Kind.allCases, id: \.rawValue) { kind in
                SquareRadio(
                    title: kind.title,
                    selected: draft.kind == kind,
                    colour: Palette.colour(for: BookingKind(rawValue: kind.rawValue) ?? .desk)
                ) {
                    draft.kind = kind
                    problem = nil
                }
            }
        }
    }

    // MARK: Fields

    private var railFields: some View {
        Group {
            FieldRow(label: "OPERATOR", value: $draft.operatorName, placeholder: "LNER", required: true)
            FieldRow(label: "FROM", value: $draft.originStation, placeholder: "DURHAM", required: true)
            FieldRow(label: "TO", value: $draft.destStation, placeholder: "KING'S CROSS", required: true)
            // Cities, not stations: the grouping rule works on cities, and
            // King's Cross and St Pancras are both London. Left blank, the
            // station table fills them in.
            FieldRow(label: "FROM CITY", value: $draft.originCity, placeholder: "FROM THE STATION")
            FieldRow(label: "TO CITY", value: $draft.destCity, placeholder: "FROM THE STATION")
            DateRow(label: "DEPARTS", value: $draft.startsAt, components: [.date, .hourAndMinute])
            DateRow(label: "ARRIVES", value: $draft.endsAt, components: [.date, .hourAndMinute])
            zoneRow
            FieldRow(label: "PLATFORM", value: $draft.platform)
            FieldRow(label: "COACH", value: $draft.coach)
            FieldRow(label: "SEAT", value: $draft.seat)
            FieldRow(label: "REF", value: $draft.railRef)
        }
    }

    private var deskFields: some View {
        Group {
            FieldRow(label: "BUILDING", value: $draft.placeName, placeholder: "ROPEMAKER PLACE", required: true)
            FieldRow(label: "CITY", value: $draft.deskCity, placeholder: "LONDON")
            FieldRow(label: "DESK", value: $draft.deskID, placeholder: "3C-114", required: true)
            DateRow(label: "FROM", value: $draft.startsAt, components: [.date, .hourAndMinute])
            DateRow(label: "UNTIL", value: $draft.endsAt, components: [.date, .hourAndMinute])
            FieldRow(label: "FLOOR", value: $draft.floor, placeholder: "L3")
            FieldRow(label: "ZONE", value: $draft.deskZone, placeholder: "C")
            FieldRow(label: "HOURS", value: $draft.hours, placeholder: "09–17")
        }
    }

    private var stayFields: some View {
        Group {
            FieldRow(label: "HOTEL", value: $draft.hotelName, placeholder: "THE ROPEWALK", required: true)
            FieldRow(label: "CITY", value: $draft.stayCity, placeholder: "LONDON")
            FieldRow(label: "ADDRESS", value: $draft.address)
            DateRow(label: "CHECK-IN", value: $draft.startsAt, components: [.date, .hourAndMinute])
            DateRow(label: "CHECK-OUT", value: $draft.endsAt, components: [.date, .hourAndMinute])
            zoneRow
            FieldRow(label: "NIGHTS", value: $draft.nights, keyboard: .numberPad)
            FieldRow(label: "REF", value: $draft.stayRef)
        }
    }

    /// Only two zones are ever needed in practice, and offering a list of four
    /// hundred would be worse than offering the two. Anything else is a capture
    /// away, where the model reads the zone off the ticket.
    private var zoneRow: some View {
        HStack(spacing: 8) {
            ForEach(["Europe/London", "Europe/Brussels", "Europe/Paris"], id: \.self) { id in
                SquareRadio(
                    title: id.replacingOccurrences(of: "Europe/", with: "").uppercased(),
                    selected: draft.zoneID == id,
                    colour: Palette.stay
                ) {
                    draft.zoneID = id
                }
            }
        }
    }

    // MARK: Commit

    private func problemStrip(_ problem: ManualEntry.Problem) -> some View {
        HStack(spacing: 9) {
            Rectangle().fill(Palette.desk).frame(width: 6, height: 6)
            Text(problem.message)
                .t8(.offline)
                .foregroundStyle(Palette.desk)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 11)
        .padding(.horizontal, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.desk.opacity(0.08))
        .overlay { Rectangle().strokeBorder(Palette.desk, lineWidth: Metrics.hairline) }
    }

    private func commit() {
        if let found = ManualEntry.validate(draft) {
            problem = found
            return
        }
        guard let parsed = ManualEntry.booking(from: draft) else { return }

        // No captureID: there is no original to retain, because nothing was
        // captured. The Capture record exists to make "view original" work and
        // to count model calls, and this cost neither.
        try? coordinator.commit(parsed, captureID: nil)
        dismiss()
        onCommit()
        Task { await coordinator.locateNewPlaces() }
    }
}
