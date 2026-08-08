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

    /// What the right-hand side says, which is the only decision in the row.
    ///
    /// Three states and not two: an em dash for a field nobody has filled in is
    /// not the same as the amber marker for one the model could not read, and
    /// collapsing them would tell the user a guess is a fact — the rule the
    /// whole capture path is built around.
    enum Display: Equatable {
        /// The amber "Needs checking" pill, and no value at all.
        case marker
        case text(String)
        /// The em dash, in the tertiary grey so it does not read as content.
        case missing
    }

    /// The flag wins over the value it accompanies. A field that came back
    /// unsure may still carry the model's best reading, and showing it beside
    /// the marker would put a number on the screen the app has already said it
    /// does not trust.
    static func display(value: String?, needsChecking: Bool) -> Display {
        if needsChecking { return .marker }
        guard let value else { return .missing }
        return .text(value)
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 16))
                .foregroundStyle(Palette.rowLabel)
            Spacer(minLength: 8)
            switch Self.display(value: value, needsChecking: needsChecking) {
            case .marker:
                Text("Needs checking")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Palette.warningText)
                    .padding(.vertical, 3)
                    .padding(.horizontal, 8)
                    .background(Palette.warningSurface)
                    .clipShape(Capsule())
            case .text(let value):
                Text(value)
                    .font(.system(size: 16))
                    .foregroundStyle(Palette.text)
            case .missing:
                Text("—")
                    .font(.system(size: 16))
                    .foregroundStyle(Palette.tertiary)
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
                    if Self.hasDivider(after: index, of: items.count) {
                        RowDivider(inset: inset)
                    }
                }
            }
        }
    }

    /// Between rows and never at the ends. A hairline under the last row draws
    /// a line across a card with nothing beneath it, which is precisely the
    /// tell that a hand-built list is not a `List`.
    static func hasDivider(after index: Int, of count: Int) -> Bool {
        index < count - 1
    }
}

/// The shortfall strip, the green confirmation, and the two states between
/// them — one shape in four colours.
///
/// This is where all the judgement in the app lives, and the only place any of
/// it does. The gauge above it is an inventory; red here means the target
/// cannot be reached this month, and nothing else in the app is red.
struct StatusStrip: View {
    /// `CaseIterable` so a test can hold every tone to the rule rather than the
    /// four that happened to be written down — a fifth tone added without its
    /// own colours would otherwise wear another one's silently.
    enum Tone: CaseIterable { case warning, success, neutral, danger }

    let tone: Tone
    let leading: String
    var trailing: String?
    var dot = false

    static func surface(_ tone: Tone) -> Color {
        switch tone {
        case .warning: Palette.warningSurface
        case .success: Palette.successSurface
        case .neutral: Palette.neutralSurface
        case .danger: Palette.dangerSurface
        }
    }

    static func text(_ tone: Tone) -> Color {
        switch tone {
        case .warning: Palette.warningText
        case .success: Palette.successText
        case .neutral: Palette.neutralText
        case .danger: Palette.dangerText
        }
    }

    /// Follows the tone. It was amber whatever the strip was, which only went
    /// unnoticed while the green strip had nothing on its right.
    static func secondary(_ tone: Tone) -> Color {
        switch tone {
        case .warning: Palette.warningSecondary
        case .success: Palette.successText
        case .neutral: Palette.secondary
        case .danger: Palette.dangerText.opacity(0.75)
        }
    }

    /// The two loud states keep the card shape and the roomier padding; the two
    /// quiet ones are a pill under the dial.
    static func isLoud(_ tone: Tone) -> Bool { tone == .success || tone == .danger }

    private var surface: Color { Self.surface(tone) }
    private var text: Color { Self.text(tone) }
    private var secondary: Color { Self.secondary(tone) }
    private var isLoud: Bool { Self.isLoud(tone) }

    var body: some View {
        HStack(spacing: 10) {
            if dot {
                Circle().fill(Palette.met).frame(width: 8, height: 8)
            }
            Text(leading)
                .font(.system(size: 14, weight: dot ? .regular : .semibold))
                .foregroundStyle(text)
            Spacer(minLength: 10)
            if let trailing {
                Text(trailing)
                    .font(.system(size: 13))
                    .foregroundStyle(secondary)
            }
        }
        // One line, shrinking a little rather than truncating. The strip now
        // carries three numbers on a narrow phone, and half a sentence is
        // worse than a slightly smaller whole one.
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .padding(.vertical, isLoud ? 14 : 11)
        .padding(.horizontal, isLoud ? 16 : 13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(surface)
        .clipShape(
            RoundedRectangle(cornerRadius: isLoud ? Metrics.cardRadius : Metrics.pillRadius)
        )
    }
}
