import SwiftUI

/// The coloured header bar at the top of every detail screen: type code on the
/// left, date on the right, both in `ground` on the type colour.
struct DetailHeaderBar: View {
    let typeCode: String
    let stamp: String
    let colour: Color

    var body: some View {
        HStack {
            Text(typeCode)
                .t8(.typeCode10)
                .foregroundStyle(Palette.ground)
            Spacer(minLength: 8)
            Text(stamp)
                .t8(.panelNote.bolded)
                .foregroundStyle(Palette.ground)
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 13)
        .frame(maxWidth: .infinity)
        .background(colour)
    }
}

/// The two- or three-cell bordered grid: `PLAT` / `COACH` / `SEAT`,
/// `FLOOR` / `ZONE` / `HOURS`, `CHECK IN` / `CHECK OUT`.
struct CellGrid: View {
    struct Cell: Identifiable {
        let label: String
        let value: String
        var colour: Color = Palette.bone
        var id: String { label }
    }

    let cells: [Cell]
    var border: Color = Palette.rail.opacity(0.25)

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(cells.enumerated()), id: \.element.id) { index, cell in
                VStack(alignment: .leading, spacing: 6) {
                    Text(cell.label)
                        .t8(.cellLabel)
                        .foregroundStyle(Palette.bone.opacity(0.4))
                    Text(cell.value)
                        .t8(.cellValue)
                        .foregroundStyle(cell.colour)
                        .monospacedDigit()
                }
                .padding(.vertical, 10)
                .padding(.horizontal, 11)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .trailing) {
                    if index < cells.count - 1 {
                        Rectangle().fill(border).frame(width: Metrics.hairline)
                    }
                }
            }
        }
        .overlay { Rectangle().strokeBorder(border, lineWidth: Metrics.hairline) }
    }
}

/// An outlined, centred action — `DIRECTIONS`, `CALENDAR`.
struct OutlinedAction: View {
    let title: String
    var border: Color = Palette.railBorder
    var action: () -> Void = {}

    var body: some View {
        Button(action: action) {
            Text(title)
                .t8(.action)
                .foregroundStyle(Palette.bone)
                .padding(12)
                .frame(maxWidth: .infinity)
                .overlay { Rectangle().strokeBorder(border, lineWidth: Metrics.hairline) }
        }
        .buttonStyle(.plain)
    }
}

/// A solid action — `COMMIT`, `ACQUIRE TARGET`. Text in `ground` on the fill.
struct SolidAction: View {
    let title: String
    var fill: Color = Palette.desk
    var action: () -> Void = {}

    var body: some View {
        Button(action: action) {
            Text(title)
                .t8(.solidAction)
                .foregroundStyle(Palette.ground)
                .padding(12)
                .frame(maxWidth: .infinity)
                .background(fill)
        }
        .buttonStyle(.plain)
    }
}

/// A `LABEL ─── value` list inside a bordered panel, with hairlines between
/// rows. Used for the effect-on-count readout and the target derivation.
struct DerivationPanel: View {
    struct Line: Identifiable {
        let label: String
        let value: String
        var labelColour: Color = Palette.boneSecondary
        var valueColour: Color = Palette.bone
        var id: String { label }
    }

    let lines: [Line]
    var border: Color = Palette.rail.opacity(0.25)

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                HStack {
                    Text(line.label).foregroundStyle(line.labelColour)
                    Spacer(minLength: 8)
                    Text(line.value).foregroundStyle(line.valueColour).monospacedDigit()
                }
                .t8(.derivation)
                .padding(.top, index == 0 ? 0 : 9)
                .padding(.bottom, index == lines.count - 1 ? 0 : 9)
                .overlay(alignment: .bottom) {
                    if index < lines.count - 1 {
                        Rectangle().fill(Palette.rail.opacity(0.16)).frame(height: Metrics.hairline)
                    }
                }
            }
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 15)
        .overlay { Rectangle().strokeBorder(border, lineWidth: Metrics.hairline) }
    }
}

/// `CACHED ▪ OPENS WITH NO SIGNAL` — the offline confirmation strip. Earned by
/// the store being local, not by a cache layer.
struct OfflineStrip: View {
    var text: String = "CACHED ▪ OPENS WITH NO SIGNAL"

    var body: some View {
        HStack(spacing: 9) {
            Rectangle().fill(Palette.stay).frame(width: 6, height: 6)
            Text(text)
                .t8(.offline)
                .foregroundStyle(Palette.stay)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 11)
        .padding(.horizontal, 13)
        .background(Palette.stay.opacity(0.06))
        .overlay { Rectangle().strokeBorder(Palette.stay.opacity(0.35), lineWidth: Metrics.hairline) }
    }
}

/// The Wallet handoff row. The app never renders a barcode; the pass lives in
/// Wallet and this links across to it.
struct WalletHandoffRow: View {
    var action: () -> Void = {}

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ZStack {
                    Rectangle().fill(Palette.bone).frame(width: 38, height: 38)
                    Image(systemName: "wallet.bifold")
                        .font(.system(size: 18, weight: .regular))
                        .foregroundStyle(Palette.ground)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("OPEN PASS IN WALLET")
                        .t8(.walletTitle)
                        .foregroundStyle(Palette.bone)
                    Text("BARCODE HELD BY WALLET")
                        .t8(.meta)
                        .foregroundStyle(Palette.bone.opacity(0.4))
                }
                Spacer(minLength: 0)
                Text("→")
                    .t8(.rowFigure)
                    .foregroundStyle(Palette.rail.opacity(0.6))
            }
            .padding(.vertical, 13)
            .padding(.horizontal, 14)
            .overlay { Rectangle().strokeBorder(Palette.rail.opacity(0.25), lineWidth: Metrics.hairline) }
        }
        .buttonStyle(.plain)
    }
}

nonisolated extension T8Font {
    /// Header-bar type code, a step larger than the card one.
    static let typeCode10 = T8Font(10, bold: true, tracking: 0.16)
    static let cellLabel = T8Font(9, tracking: 0.14)
    static let cellValue = T8Font(18, bold: true)
    static let action = T8Font(10.5, bold: true, tracking: 0.12)
    static let solidAction = T8Font(11, bold: true, tracking: 0.14)
    static let derivation = T8Font(11, tracking: 0.06)
    static let offline = T8Font(10, tracking: 0.07, lineHeight: 1.5)
    static let walletTitle = T8Font(11.5, bold: true, tracking: 0.08)
    /// Detail-screen titles: `THE MISSION`, `LONDON WEEK`, `THE ROPEWALK`.
    static let screenTitle = T8Font(20, bold: true, tracking: 0.06)
    static let screenSubtitle = T8Font(10, tracking: 0.14)
    /// The ticket's departure and arrival figures.
    static let ticketFigure = T8Font(32, bold: true)
    static let ticketStation = T8Font(11, bold: true, tracking: 0.11)
    /// Detail-screen body copy inside a panel.
    static let panelBody = T8Font(10.5, tracking: 0.04, lineHeight: 1.6)

    var bolded: T8Font {
        T8Font(size, bold: true, tracking: trackingEm, lineHeight: lineHeightMultiple)
    }
}
