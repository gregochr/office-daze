import SwiftUI

// MARK: - Scanlines

/// `repeating-linear-gradient(0deg, rgba(255,60,35,.05) 0 1px, transparent 1px 3px)`
///
/// A `Canvas` rather than a tiled image: no asset to ship, and it stays crisp at
/// any scale. It should read as texture, not stripes.
struct ScanlineOverlay: View {
    var body: some View {
        Canvas(opaque: false) { context, size in
            let line = Color(hex: 0xFF3C23, opacity: 0.05)
            var y: CGFloat = 0
            while y < size.height {
                context.fill(
                    Path(CGRect(x: 0, y: y, width: size.width, height: Metrics.scanlineThickness)),
                    with: .color(line)
                )
                y += Metrics.scanlinePeriod
            }
        }
        .allowsHitTesting(false)
    }
}

/// Every screen sits on this: near-black, scanlined, edge to edge.
struct ScreenBackground<Content: View>: View {
    var raised: Bool = false
    @ViewBuilder var content: () -> Content

    var body: some View {
        ZStack {
            (raised ? Palette.groundRaised : Palette.ground).ignoresSafeArea()
            ScanlineOverlay().ignoresSafeArea()
            content()
        }
    }
}

// MARK: - Corner ticks

/// Eight short L-shaped marks, one pair at each corner, drawn *inside* the
/// panel bounds — hence the half-weight inset, so a 2pt stroke centred on the
/// path doesn't hang half of itself outside the border.
nonisolated struct CornerTicks: Shape {
    var length: CGFloat = Metrics.tickLength
    var weight: CGFloat = Metrics.tickWeight

    func path(in rect: CGRect) -> Path {
        let i = weight / 2
        let minX = rect.minX + i, maxX = rect.maxX - i
        let minY = rect.minY + i, maxY = rect.maxY - i

        var path = Path()
        for (x, dx) in [(minX, length), (maxX, -length)] {
            for (y, dy) in [(minY, length), (maxY, -length)] {
                path.move(to: CGPoint(x: x, y: y))
                path.addLine(to: CGPoint(x: x + dx, y: y))
                path.move(to: CGPoint(x: x, y: y))
                path.addLine(to: CGPoint(x: x, y: y + dy))
            }
        }
        return path
    }
}

// MARK: - Panel

/// A bordered rectangle, optionally with corner ticks and a fill.
///
/// `Rectangle` everywhere, never `RoundedRectangle`. No rounded corners
/// anywhere is deliberate and load-bearing for the theme.
struct HUDPanel<Content: View>: View {
    var border: Color = Palette.railBorder
    var borderWidth: CGFloat = Metrics.hairline
    var fill: Color = .clear
    var ticks: Bool = false
    var tickColour: Color = Palette.rail
    var padding: EdgeInsets = EdgeInsets(
        top: Metrics.panelPaddingTop,
        leading: Metrics.panelPaddingH,
        bottom: Metrics.panelPaddingBottom,
        trailing: Metrics.panelPaddingH
    )
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(fill)
            .overlay { Rectangle().strokeBorder(border, lineWidth: borderWidth) }
            .overlay {
                if ticks {
                    CornerTicks().stroke(tickColour, lineWidth: Metrics.tickWeight)
                }
            }
    }
}

// MARK: - Small type pieces

/// `▸ INBOUND`, `▸ SEPTEMBER`, `▸ TARGET DERIVATION`
struct SectionKicker: View {
    let text: String
    var colour: Color = Palette.boneTertiary
    var marker: Bool = true

    var body: some View {
        Text(marker ? "▸ \(text)" : text)
            .t8(.kicker)
            .foregroundStyle(colour)
    }
}

/// `← RETURN`, `← TARGETS`. The design uses this instead of a system nav bar.
struct BackLabel: View {
    let text: String

    var body: some View {
        Text("← \(text)")
            .t8(.back)
            .foregroundStyle(Palette.railBack)
    }
}

/// A hero figure in brackets: `[ 3C-114 ]`. Brackets sit in `rail` at 0.6 and a
/// smaller size than the figure they wrap.
struct BracketedFigure: View {
    let text: String
    var figureStyle: T8Font = .displayFigure
    var bracketStyle: T8Font = .bracket
    var figureColour: Color = Palette.bone
    var bracketColour: Color = Palette.railBracket

    var body: some View {
        HStack(alignment: .center, spacing: 4) {
            Text("[").t8(bracketStyle).foregroundStyle(bracketColour)
            Text(text).t8(figureStyle).foregroundStyle(figureColour).monospacedDigit()
            Text("]").t8(bracketStyle).foregroundStyle(bracketColour)
        }
    }
}

/// The header rule beneath `T8 ▪ ATTENDANCE PROTOCOL`.
struct HUDRule: View {
    var colour: Color = Palette.railRule

    var body: some View {
        Rectangle()
            .fill(colour)
            .frame(height: Metrics.hairline)
    }
}
