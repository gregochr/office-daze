import SwiftUI

/// The Grafana-style speedometer: attended days against a pro-rated target.
///
/// Drawn in `GaugeMetrics.boxSize` and scaled to whatever it is given, so the
/// mock's radii can be used verbatim rather than re-derived as fractions of the
/// frame. Everything the dial knows about angles lives in `GaugeMetrics`;
/// this file only turns those into strokes.
struct AttendanceGauge: View {
    let attended: Double
    let target: Int

    private var fraction: Double { GaugeMetrics.fraction(attended: attended, target: target) }
    private var level: GaugeMetrics.Level { GaugeMetrics.level(attended: attended, target: target) }
    private var overshoot: Double { GaugeMetrics.overshoot(attended: attended, target: target) }

    private var valueColour: Color {
        switch level {
        case .behind: Palette.behind
        case .close: Palette.close
        case .met: Palette.met
        }
    }

    var body: some View {
        ZStack {
            Canvas { context, size in draw(in: &context, size: size) }
                .frame(
                    width: GaugeMetrics.boxSize.width,
                    height: GaugeMetrics.boxSize.height
                )

            // The reading sits below the pivot, inside the open bottom of the
            // arc. Text rather than Canvas so it stays selectable to
            // VoiceOver's rotor and picks up tabular figures for free.
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(attended.formatted(.number.precision(.fractionLength(0...1))))
                    .font(.system(size: 40, weight: .bold))
                    .monospacedDigit()
                    .kerning(-1.2)
                    .foregroundStyle(level == .met ? Palette.met : Palette.text)
                Text("of \(target)")
                    .font(.system(size: 17))
                    .foregroundStyle(Palette.secondary)
            }
            // Sized to the dial's own box, not to whatever the card offers.
            // Left to expand, the end labels drift inward and land on the arc.
            .frame(
                width: GaugeMetrics.boxSize.width,
                height: GaugeMetrics.boxSize.height,
                alignment: .bottom
            )
            .padding(.bottom, 6)

            // The two ends of the scale, small enough not to compete with the
            // reading, and outboard of where the arc reaches.
            HStack {
                Text("0")
                Spacer()
                Text("\(target)")
            }
            .font(.system(size: 12))
            .foregroundStyle(Palette.tertiary)
            .padding(.horizontal, 12)
            .frame(
                width: GaugeMetrics.boxSize.width,
                height: GaugeMetrics.boxSize.height,
                alignment: .bottom
            )
            .padding(.bottom, 38)
        }
        .frame(width: GaugeMetrics.boxSize.width, height: GaugeMetrics.boxSize.height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Attendance")
        .accessibilityValue(accessibilityValue)
    }

    private var accessibilityValue: String {
        let days = attended.formatted(.number.precision(.fractionLength(0...1)))
        if overshoot > 0 {
            return "\(days) of \(target) days, "
                + "\(overshoot.formatted(.number.precision(.fractionLength(0...1)))) over target"
        }
        return "\(days) of \(target) days"
    }

    // MARK: Drawing

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        // The mock's coordinates are 256 wide; honour whatever width we are
        // given so the dial can shrink on a small phone without re-deriving
        // every radius.
        let scale = size.width / GaugeMetrics.boxSize.width
        context.scaleBy(x: scale, y: scale)

        drawBands(&context)
        drawTrack(&context)
        drawValueArc(&context)
        drawTicks(&context)
        drawNeedle(&context)
    }

    /// Red to half the target, amber to 85%, green above — fixed thresholds,
    /// drawn outside the value arc so they read as the scale rather than as
    /// part of the reading.
    private func drawBands(_ context: inout GraphicsContext) {
        let stops: [(Double, Double, Color)] = [
            (0, GaugeMetrics.closeThreshold, Palette.behind),
            (GaugeMetrics.closeThreshold, GaugeMetrics.metThreshold, Palette.close),
            (GaugeMetrics.metThreshold, 1, Palette.met),
        ]
        for (from, to, colour) in stops {
            context.stroke(
                arc(radius: GaugeMetrics.bandRadius, from: from, to: to),
                with: .color(colour),
                lineWidth: GaugeMetrics.bandWidth
            )
        }
    }

    private func drawTrack(_ context: inout GraphicsContext) {
        context.stroke(
            arc(radius: GaugeMetrics.valueRadius, from: 0, to: 1),
            with: .color(Palette.hairline),
            lineWidth: GaugeMetrics.valueWidth
        )
    }

    private func drawValueArc(_ context: inout GraphicsContext) {
        guard fraction > 0 else { return }
        context.stroke(
            arc(radius: GaugeMetrics.valueRadius, from: 0, to: fraction),
            with: .color(valueColour),
            lineWidth: GaugeMetrics.valueWidth
        )
    }

    /// One per whole day, outside the bands. They must not overlap the arcs —
    /// a tick crossing the value arc reads as a gap in it.
    private func drawTicks(_ context: inout GraphicsContext) {
        for angle in GaugeMetrics.tickAngles(target: target) {
            let radians = Angle(degrees: angle).radians
            var path = Path()
            path.move(to: point(radius: GaugeMetrics.tickInnerRadius, radians: radians))
            path.addLine(to: point(radius: GaugeMetrics.tickOuterRadius, radians: radians))
            context.stroke(
                path, with: .color(Palette.tick), lineWidth: GaugeMetrics.tickWidth
            )
        }
    }

    private func drawNeedle(_ context: inout GraphicsContext) {
        let radians = Angle(degrees: GaugeMetrics.angle(at: fraction)).radians
        var needle = Path()
        needle.move(to: GaugeMetrics.centre)
        needle.addLine(to: point(radius: GaugeMetrics.needleLength, radians: radians))
        context.stroke(
            needle,
            with: .color(Palette.text),
            style: StrokeStyle(lineWidth: GaugeMetrics.needleWidth, lineCap: .round)
        )

        let pivot = GaugeMetrics.pivotRadius
        context.fill(
            Path(ellipseIn: CGRect(
                x: GaugeMetrics.centre.x - pivot, y: GaugeMetrics.centre.y - pivot,
                width: pivot * 2, height: pivot * 2
            )),
            with: .color(Palette.text)
        )
    }

    // MARK: Geometry

    private func arc(radius: Double, from: Double, to: Double) -> Path {
        var path = Path()
        path.addArc(
            center: GaugeMetrics.centre,
            radius: radius,
            startAngle: .degrees(GaugeMetrics.angle(at: from)),
            endAngle: .degrees(GaugeMetrics.angle(at: to)),
            clockwise: false
        )
        return path
    }

    private func point(radius: Double, radians: Double) -> CGPoint {
        CGPoint(
            x: GaugeMetrics.centre.x + radius * cos(radians),
            y: GaugeMetrics.centre.y + radius * sin(radians)
        )
    }
}

// MARK: - Previews

/// The four states from the design, so the dial can be judged on its own before
/// it is embedded in anything.
#Preview("Four states") {
    let states: [(String, Double, Int)] = [
        ("Behind", 1, 7), ("Close", 6, 7), ("Met", 7, 7), ("Over · +2", 9, 7),
    ]
    return ScrollView {
        VStack(spacing: Metrics.cardGap) {
            ForEach(states, id: \.0) { title, attended, target in
                VStack(spacing: 2) {
                    Text(title)
                        .font(.system(size: 13))
                        .foregroundStyle(
                            attended >= Double(target) ? Palette.met : Palette.secondary
                        )
                    AttendanceGauge(attended: attended, target: target)
                }
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity)
                .background(Palette.card)
                .clipShape(RoundedRectangle(cornerRadius: Metrics.cardRadius))
            }
        }
        .padding(Metrics.screenPadding)
    }
    .background(Palette.ground)
}

#Preview("Half days and an empty month") {
    VStack(spacing: Metrics.cardGap) {
        AttendanceGauge(attended: 4.5, target: 7)
        AttendanceGauge(attended: 0, target: 8)
    }
    .padding(Metrics.screenPadding)
    .background(Palette.ground)
}
