import SwiftUI

/// The grouped-list vocabulary, built by hand rather than with `List`.
///
/// `List` would give the separators and the row insets for free, but not the
/// gauge card, the two coloured strips or the office cards — and mixing a List
/// with free-standing cards on one scroll view fights the framework the whole
/// way. A ScrollView of white rounded rectangles is what the design draws, and
/// it is less code than bending `List` into the same shape.

/// A white rounded card. The building block of every screen.
struct Card<Content: View>: View {
    var padding: EdgeInsets = EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0)
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.card)
            .clipShape(RoundedRectangle(cornerRadius: Metrics.cardRadius))
    }
}

/// The office colour dot. The only place colour carries meaning outside the
/// gauge, so it is worth having exactly one of.
struct OfficeDot: View {
    let colourHex: String
    var size: CGFloat = 9

    var body: some View {
        Circle()
            .fill(Color(officeHex: colourHex))
            .frame(width: size, height: size)
    }
}

/// `BOOKINGS` with an optional trailing action.
struct SectionHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title.uppercased())
                .font(.system(size: 13))
                .kerning(0.26)
                .foregroundStyle(Palette.secondary)
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 4)
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(_ title: String) {
        self.init(title: title) { EmptyView() }
    }
}

/// A label on the left, a value on the right. The Floor / Zone / Hours rows.
///
/// A field the model could not read shows the amber marker and no value —
/// never a guess, and never a blank that could be mistaken for one.
struct DetailRow: View {
    let label: String
    let value: String?
    var needsChecking = false

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 16))
                .foregroundStyle(Palette.rowLabel)
            Spacer(minLength: 8)
            if needsChecking {
                Text("Needs checking")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Palette.warningText)
                    .padding(.vertical, 3)
                    .padding(.horizontal, 8)
                    .background(Palette.warningSurface)
                    .clipShape(Capsule())
            } else {
                Text(value ?? "—")
                    .font(.system(size: 16))
                    .foregroundStyle(value == nil ? Palette.tertiary : Palette.text)
            }
        }
        .padding(.vertical, 13)
        .padding(.horizontal, 16)
        .frame(minHeight: Metrics.minimumRow)
    }
}

/// A full-width tappable row in the tint colour. `Directions`, `Add office`.
struct ActionRow: View {
    let title: String
    var centred = false
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 16))
                .foregroundStyle(enabled ? Palette.tint : Palette.tertiary)
                .frame(maxWidth: .infinity, alignment: centred ? .center : .leading)
                .padding(.vertical, 14)
                .padding(.horizontal, 16)
                .frame(minHeight: Metrics.minimumRow)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

/// The hairline between rows inside a card. Inset to the row's own padding, as
/// a grouped list's is.
struct RowDivider: View {
    var inset: CGFloat = 16

    var body: some View {
        Rectangle()
            .fill(Palette.hairline)
            .frame(height: 1)
            .padding(.leading, inset)
    }
}

/// Stacks rows into a card with hairlines between them and none at the ends.
struct RowStack<Item: Identifiable, Row: View>: View {
    let items: [Item]
    var inset: CGFloat = 16
    @ViewBuilder var row: (Item) -> Row

    var body: some View {
        Card {
            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    row(item)
                    if index < items.count - 1 { RowDivider(inset: inset) }
                }
            }
        }
    }
}

/// The amber shortfall strip and the green confirmation, which are the same
/// shape in two colours.
struct StatusStrip: View {
    enum Tone { case warning, success }

    let tone: Tone
    let leading: String
    var trailing: String?
    var dot = false

    private var surface: Color { tone == .warning ? Palette.warningSurface : Palette.successSurface }
    private var text: Color { tone == .warning ? Palette.warningText : Palette.successText }

    var body: some View {
        HStack(spacing: 10) {
            if dot {
                Circle().fill(Palette.met).frame(width: 8, height: 8)
            }
            Text(leading)
                .font(.system(size: tone == .warning ? 14 : 14, weight: dot ? .regular : .semibold))
                .foregroundStyle(text)
            Spacer(minLength: 10)
            if let trailing {
                Text(trailing)
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.warningSecondary)
            }
        }
        .padding(.vertical, tone == .warning ? 11 : 14)
        .padding(.horizontal, tone == .warning ? 13 : 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(surface)
        .clipShape(RoundedRectangle(cornerRadius: tone == .warning ? Metrics.pillRadius : Metrics.cardRadius))
    }
}
