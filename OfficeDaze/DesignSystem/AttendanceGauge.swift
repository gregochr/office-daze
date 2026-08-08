import SwiftUI

/// The month at a glance: a fixed 0–8 scale with the days stacked along it.
///
/// It replaced a banded speedometer, and the reason is worth keeping: that dial
/// said "behind" in colour by three different rules six millimetres apart, and
/// none of them was the thing you wanted to know. Fixed fractions of the target
/// cannot be right for a count that accumulates toward a month-end deadline —
/// on the 2nd, nought of eight is normal; on the 28th, four of eight is a
/// crisis — so the red band was on screen for the first fortnight of every
/// month, when nothing was wrong. A warning that is correct by default is a
/// warning you stop reading.
///
/// So there is no judgement on the dial at all. It is an inventory: solid means
/// counted, tint means promised, empty means owed, hatched means not owed. The
/// one rule to learn is that the arc has to reach the marker, and it is the same
/// rule in every month. Judgement lives in the strip underneath, once, from
/// `Quota.Standing`.
///
/// Drawn at a fixed `GaugeMetrics.boxSize`, so the mock's radii can be used
/// verbatim rather than re-derived as fractions of the frame. Everything about
/// angles lives in `GaugeMetrics`; this file only turns those into strokes.
struct AttendanceGauge: View {
    let attended: Double
    /// Days booked ahead and not yet worked. The number the old dial left out
    /// entirely — it was a phrase in the strip, arguing with the arc above it.
    var booked: Double = 0
    let target: Int

    private var segments: [GaugeMetrics.Segment] {
        GaugeMetrics.segments(attended: attended, booked: booked, target: target)
    }

    private var overshoot: Double { GaugeMetrics.overshoot(attended: attended, target: target) }

    var body: some View {
        ZStack {
            Canvas { context, _ in draw(in: &context) }
                .frame(
                    width: GaugeMetrics.boxSize.width,
                    height: GaugeMetrics.boxSize.height
                )

            // The reading sits inside the open bottom of the arc. Text rather
            // than Canvas so it stays selectable to VoiceOver's rotor and picks
            // up tabular figures for free.
            VStack(spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(Self.number(attended))
                        .font(.system(size: 40, weight: .bold))
                        .monospacedDigit()
                        .kerning(-1.2)
                        .foregroundStyle(Palette.text)
                    Text("of \(target)")
                        .font(.system(size: 17))
                        .foregroundStyle(Palette.secondary)
                }
                // The second half of the reading, and the reason the dial no
                // longer needs a sentence underneath arguing with it.
                if let ahead {
                    Text(ahead)
                        .font(.system(size: 13))
                        .monospacedDigit()
                        .foregroundStyle(Palette.tint)
                }
            }
            // Sized to the dial's own box, not to whatever the card offers.
            // Left to expand, the end labels drift inward and land on the arc.
            .frame(
                width: GaugeMetrics.boxSize.width,
                height: GaugeMetrics.boxSize.height,
                alignment: .bottom
            )
            .padding(.bottom, 4)

            // The two ends of the scale — 0 and 8, never the target. The target
            // is the marker on the arc, and putting it here as well was what
            // let a hard month and an easy one draw an identical dial.
            HStack {
                Text("0")
                Spacer()
                Text(Self.number(GaugeMetrics.scale))
            }
            .font(.system(size: 12))
            .foregroundStyle(Palette.tertiary)
            .padding(.horizontal, 12)
            .frame(
                width: GaugeMetrics.boxSize.width,
                height: GaugeMetrics.boxSize.height,
                alignment: .bottom
            )
            .padding(.bottom, 50)
        }
        .frame(width: GaugeMetrics.boxSize.width, height: GaugeMetrics.boxSize.height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Attendance")
        .accessibilityValue(accessibilityValue)
    }

    /// `+3 booked`, or `+1 over` once the target is passed. Never both: past
    /// the target, what is still booked ahead is no longer the news.
    private var ahead: String? {
        if overshoot > 0 { return "+\(Self.number(overshoot)) over" }
        guard booked > 0 else { return nil }
        return "+\(Self.number(booked)) booked"
    }

    private var accessibilityValue: String {
        var parts = ["\(Self.number(attended)) of \(target) days"]
        if booked > 0 { parts.append("\(Self.number(booked)) booked ahead") }
        if overshoot > 0 { parts.append("\(Self.number(overshoot)) over target") }
        let off = GaugeMetrics.scale - Double(target)
        if off > 0 { parts.append("\(Self.number(off)) off the target for leave") }
        return parts.joined(separator: ", ")
    }

    static func number(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...1)))
    }

    // MARK: Drawing

    /// The Canvas is pinned to `GaugeMetrics.boxSize`, so it is drawn in the
    /// mock's own 256×208 coordinates and no `size` is passed in.
    ///
    /// There used to be a `context.scaleBy(size.width / boxSize.width)` here,
    /// under a comment saying the dial shrank to fit a small phone. It never
    /// did: the Canvas, the label overlays and the enclosing ZStack are all
    /// framed at `boxSize`, so the factor was structurally 1 and the shrinking
    /// was a promise the code could not keep. It is deleted rather than made
    /// real because it does not need to be real — the narrowest phone iOS 26
    /// supports is 375pt, which leaves 311pt of card interior after the
    /// screen and card padding, against a 256pt box. If that ever stops being
    /// true, scaling the context is not enough on its own: the two label
    /// overlays are positioned in `boxSize` too, so they would have to be
    /// driven from a measured width at the same time, or they will drift onto
    /// the arc.
    private func draw(in context: inout GraphicsContext) {
        drawSegments(&context)
        drawTicks(&context)
        drawMarker(&context)
    }

    private func drawSegments(_ context: inout GraphicsContext) {
        for segment in segments {
            let path = arc(
                from: GaugeMetrics.fraction(days: segment.from),
                to: GaugeMetrics.fraction(days: segment.to)
            )
            context.stroke(
                path,
                with: .color(colour(segment.part)),
                lineWidth: GaugeMetrics.valueWidth
            )
            if segment.part == .off { hatch(&context, over: path) }
        }
    }

    private func colour(_ part: GaugeMetrics.Part) -> Color {
        switch part {
        case .attended: Palette.gaugeAttended
        case .booked: Palette.gaugeBooked
        case .gap: Palette.gaugeGap
        case .off: Palette.gaugeOff
        }
    }

    /// Diagonals clipped to the segment's own stroked shape. Hatching rather
    /// than a fourth grey because these days are excluded rather than merely
    /// empty, and one more shade of grey would not say the difference.
    private func hatch(_ context: inout GraphicsContext, over path: Path) {
        let shape = path.strokedPath(StrokeStyle(lineWidth: GaugeMetrics.valueWidth))
        var lines = Path()
        let box = shape.boundingRect.insetBy(dx: -GaugeMetrics.valueWidth, dy: -GaugeMetrics.valueWidth)
        var x = box.minX - box.height
        while x < box.maxX {
            lines.move(to: CGPoint(x: x, y: box.maxY))
            lines.addLine(to: CGPoint(x: x + box.height, y: box.minY))
            x += 6
        }
        context.drawLayer { layer in
            layer.clip(to: shape)
            layer.stroke(lines, with: .color(Palette.gaugeHatch), lineWidth: 1.5)
        }
    }

    /// One per whole day, outside the arc. They must not overlap it — a tick
    /// crossing the arc reads as a gap in it.
    private func drawTicks(_ context: inout GraphicsContext) {
        for angle in GaugeMetrics.tickAngles() {
            let radians = Angle(degrees: angle).radians
            var path = Path()
            path.move(to: point(radius: GaugeMetrics.tickInnerRadius, radians: radians))
            path.addLine(to: point(radius: GaugeMetrics.tickOuterRadius, radians: radians))
            context.stroke(
                path, with: .color(Palette.tick), lineWidth: GaugeMetrics.tickWidth
            )
        }
    }

    /// Where the hatching starts, and the whole rule the dial is teaching:
    /// everything left of this has to be filled.
    private func drawMarker(_ context: inout GraphicsContext) {
        let radians = Angle(
            degrees: GaugeMetrics.angle(at: GaugeMetrics.markerFraction(target: target))
        ).radians
        let inner = GaugeMetrics.valueRadius - GaugeMetrics.valueWidth / 2 - GaugeMetrics.markerOverhang
        let outer = GaugeMetrics.valueRadius + GaugeMetrics.valueWidth / 2 + GaugeMetrics.markerOverhang
        var path = Path()
        path.move(to: point(radius: inner, radians: radians))
        path.addLine(to: point(radius: outer, radians: radians))
        context.stroke(
            path,
            with: .color(Palette.text),
            style: StrokeStyle(lineWidth: GaugeMetrics.markerWidth, lineCap: .round)
        )
    }

    // MARK: Geometry

    private func arc(from: Double, to: Double) -> Path {
        var path = Path()
        path.addArc(
            center: GaugeMetrics.centre,
            radius: GaugeMetrics.valueRadius,
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

/// The states from the review, so the dial can be judged on its own before it
/// is embedded in anything. The point of the fixed scale is that these are
/// comparable with each other — the same day is the same width in all of them.
#Preview("Four states") {
    let states: [(String, Double, Double, Int)] = [
        ("Can't reach it · 2 of 8, +1 booked", 2, 1, 8),
        ("On track · 3 of 6, +3 booked", 3, 3, 6),
        ("Target met · 6 of 6", 6, 0, 6),
        ("Over · 7 of 6", 7, 1, 6),
    ]
    return ScrollView {
        VStack(spacing: Metrics.cardGap) {
            ForEach(states, id: \.0) { title, attended, booked, target in
                VStack(spacing: 2) {
                    Text(title)
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.secondary)
                    AttendanceGauge(attended: attended, booked: booked, target: target)
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
        AttendanceGauge(attended: 4.5, booked: 1, target: 7)
        AttendanceGauge(attended: 0, booked: 0, target: 8)
    }
    .padding(Metrics.screenPadding)
    .background(Palette.ground)
}
