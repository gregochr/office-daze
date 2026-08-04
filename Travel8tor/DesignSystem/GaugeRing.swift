import SwiftUI

/// The attendance ring: a track, an attended arc, a forecast arc that follows
/// it, and a decorative dashed circle inside.
///
/// The arcs are fractions of `target`, not of the month — at 2 attended against
/// a target of 7 the solid arc covers two sevenths, which is what the mock's
/// `stroke-dasharray="71.8 251"` works out to.
struct GaugeRing: View {
    let attended: Double
    let forecast: Double
    let target: Int
    /// The figure in the centre. Attended plus forecast, per the design.
    var centreFigure: String {
        String(format: "%02d", Int((attended + forecast).rounded()))
    }

    /// Internal rather than private so the arithmetic behind the arcs is
    /// testable — the arcs themselves are not.
    var attendedFraction: Double {
        guard target > 0 else { return 0 }
        return min(1, attended / Double(target))
    }

    var forecastFraction: Double {
        guard target > 0 else { return 0 }
        return min(1 - attendedFraction, forecast / Double(target))
    }

    var body: some View {
        ZStack {
            // Track. `inset(by:)` + `stroke` rather than `strokeBorder`, which
            // insets by half the line width on its own — mixing the two draws
            // the track and the arcs on different radii, which is visible as a
            // step where the amber meets the track.
            Circle()
                .inset(by: trackInset)
                .stroke(Palette.railTrack, lineWidth: Metrics.ringStroke)

            // Attended, at full strength
            arc(from: 0, to: attendedFraction, colour: Palette.desk)

            // Forecast, following it, in the lighter tone. A booked desk is not
            // an attended day and must not read as one.
            arc(
                from: attendedFraction,
                to: attendedFraction + forecastFraction,
                colour: Palette.desk.opacity(0.32)
            )

            // Decoration, not data.
            Circle()
                .inset(by: Metrics.ringSize / 2 - Metrics.ringInnerRadius)
                .stroke(Palette.railDashed, style: StrokeStyle(lineWidth: 1, dash: [2, 6]))

            BracketedFigure(text: centreFigure)
        }
        .frame(width: Metrics.ringSize, height: Metrics.ringSize)
    }

    /// A 96pt box with a 40pt centreline radius: inset 8 from the 48pt edge.
    private var trackInset: CGFloat { Metrics.ringSize / 2 - Metrics.ringRadius }

    private func arc(from: Double, to: Double, colour: Color) -> some View {
        Circle()
            .inset(by: trackInset)
            .trim(from: from, to: max(from, to))
            .stroke(colour, style: StrokeStyle(lineWidth: Metrics.ringStroke, lineCap: .butt))
            // SwiftUI trims from 3 o'clock; the design starts at 12.
            .rotationEffect(.degrees(-90))
    }
}

/// A `LABEL ────── figure` row, as used in the gauge readout and the effect-on-
/// count panels.
struct ReadoutRow: View {
    let label: String
    let figure: String
    var figureColour: Color = Palette.bone
    var divider: Bool = false

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .t8(.readoutLabel)
                .foregroundStyle(Palette.boneSecondary)
            Spacer(minLength: 8)
            Text(figure)
                .t8(.readoutFigure)
                .foregroundStyle(figureColour)
                .monospacedDigit()
        }
        .padding(.top, divider ? 9 : 0)
        .overlay(alignment: .top) {
            if divider {
                Rectangle().fill(Palette.rail.opacity(0.2)).frame(height: Metrics.hairline)
            }
        }
    }
}

/// The footer strip beneath the gauge: `03 LEFT ALIVE` and `18 DAYS TO RUN` on
/// a `rail` fill inside a stronger border.
struct FooterStrip: View {
    let leading: String
    let trailing: String

    var body: some View {
        HStack {
            Text(leading)
                .t8(.panelLabel)
                .foregroundStyle(Palette.rail)
            Spacer(minLength: 8)
            Text(trailing)
                .t8(.panelNote)
                .foregroundStyle(Palette.rail.opacity(0.7))
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 11)
        .background(Palette.railFill)
        .overlay { Rectangle().strokeBorder(Palette.railBorderStrong, lineWidth: Metrics.hairline) }
    }
}
