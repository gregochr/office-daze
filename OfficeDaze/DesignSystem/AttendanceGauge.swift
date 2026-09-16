import SwiftUI

/// The month at a glance: eight slots, and the two figures under them.
///
/// It replaced a dial, and the reason is worth keeping: the dial answered
/// neither of the questions actually asked of this card — have I done eight
/// days, and have I got eight days planned. It drew one number three times, as
/// an arc, a needle at the arc's end and a marker, and left the days booked
/// ahead in a caption. Before that it was a banded speedometer whose bands were
/// fixed fractions of the target, so they could not know what day it was:
/// nought of eight on the 2nd read red, and four of eight on the 28th read
/// amber, which is backwards.
///
/// So this is a tally. Eight slots whatever the target, filled in order of
/// state — worked, booked, still to find, and hatched for what leave took off —
/// so eight is small enough to count without a scale. **Not a calendar**: slot
/// three is not a particular day, and nothing here can be tapped. The list
/// below is where days are touched. Judgement lives in the verdict line
/// underneath, once, from `Quota.Standing`.
struct AttendanceGauge: View {
    let attended: Double
    /// Days planned and not yet worked: today if it is booked, and every day
    /// booked ahead. The quota's forecast.
    var booked: Double = 0
    let target: Int

    // The mock's own numbers, rather than fractions of the card.
    private static let slotSpacing: CGFloat = 6
    private static let slotHeight: CGFloat = 46
    private static let slotRadius: CGFloat = 7
    private static let hatchWidth: CGFloat = 2
    /// Measured square to the lines, as the mock's gradient measures it.
    private static let hatchPitch: CGFloat = 6

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: Self.slotSpacing) {
                ForEach(Array(slots.enumerated()), id: \.offset) { _, shares in
                    Self.slot(shares)
                }
            }
            .frame(height: Self.slotHeight)

            HStack(spacing: 10) {
                figure(Palette.gaugeAttended, Self.number(attended), Self.unit(attended) + " done")
                Spacer(minLength: 0)
                figure(Palette.gaugeBooked, "\(Self.number(planned)) of \(target)", "planned")
            }
        }
        // One element, read as the two figures. The slots are the same numbers
        // drawn, and eight stops saying "filled" would be a calendar VoiceOver
        // could not tell the dates of.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.spoken(attended: attended, booked: booked, target: target))
    }

    private var slots: [[GaugeMetrics.Share]] {
        GaugeMetrics.slots(attended: attended, booked: booked, target: target)
    }

    private var planned: Double { GaugeMetrics.planned(attended: attended, booked: booked) }

    /// `4 days done, 6 of 7 planned` — what VoiceOver reads for the whole row.
    static func spoken(attended: Double, booked: Double, target: Int) -> String {
        let planned = GaugeMetrics.planned(attended: attended, booked: booked)
        return "\(number(attended)) \(unit(attended)) done, \(number(planned)) of \(target) planned"
    }

    static func number(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...1)))
    }

    private static func unit(_ days: Double) -> String {
        days == 1 ? "day" : "days"
    }

    /// A swatch in the slot's own fill, then the figure in the text colour and
    /// the words in grey — so the number is what the eye lands on.
    private func figure(_ swatch: Color, _ figure: String, _ words: String) -> some View {
        HStack(spacing: 7) {
            RoundedRectangle(cornerRadius: 3)
                .fill(swatch)
                .frame(width: 10, height: 10)
            Text("\(Text(figure).fontWeight(.semibold).monospacedDigit().foregroundStyle(Palette.text)) \(words)")
                .font(.system(size: 13))
                .foregroundStyle(Palette.secondary)
                .lineLimit(1)
        }
    }

    // MARK: Drawing

    /// One slot. A whole day is one fill; a half day splits the slot where it
    /// ends, so a canvas rather than a filled shape.
    private static func slot(_ shares: [GaugeMetrics.Share]) -> some View {
        Canvas { context, size in
            var x: CGFloat = 0
            for share in shares {
                let rect = CGRect(x: x, y: 0, width: size.width * share.fraction, height: size.height)
                context.fill(Path(rect), with: .color(colour(share.part)))
                if share.part == .off { hatch(&context, in: rect) }
                x = rect.maxX
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: slotRadius))
    }

    private static func colour(_ part: GaugeMetrics.Part) -> Color {
        switch part {
        case .attended: Palette.gaugeAttended
        case .booked: Palette.gaugeBooked
        case .gap: Palette.gaugeGap
        case .off: Palette.gaugeOff
        }
    }

    /// Diagonals at 45°, falling left to right, clipped to the part of the slot
    /// that is off. Hatching rather than a fifth grey because these days are
    /// excluded rather than merely empty, and one more shade of grey would not
    /// say the difference.
    private static func hatch(_ context: inout GraphicsContext, in rect: CGRect) {
        // The pitch is square to the lines, so along the row they are √2 apart.
        let step = hatchPitch * 2.squareRoot()
        var lines = Path()
        var x = rect.minX - rect.height
        while x < rect.maxX {
            lines.move(to: CGPoint(x: x, y: rect.minY))
            lines.addLine(to: CGPoint(x: x + rect.height, y: rect.maxY))
            x += step
        }
        context.drawLayer { layer in
            layer.clip(to: Path(rect))
            layer.stroke(lines, with: .color(Palette.gaugeHatch), lineWidth: hatchWidth)
        }
    }
}

// MARK: - Sample states

/// One row of the sheet of tallies — a caption and the three numbers that draw
/// it.
///
/// A named type rather than a tuple because there are four fields and two of
/// them are `Double`s that mean different things: `(3, 3, 6)` and `(3, 6, 3)`
/// both compile, and the second one is a month that is over target rather than
/// halfway through it. Nothing in a screenshot would say which you had written.
///
/// It lives beside the gauge rather than beside either of its callers because
/// both the Xcode preview below and the `-screen gauge` page in `DebugRouter`
/// draw a sheet of them, and the sheet is a property of the row: eight fixed
/// slots only mean anything if the states are compared with each other.
struct GaugeSample {
    let title: String
    let attended: Double
    let booked: Double
    let target: Int
}

// MARK: - Previews

/// The same days against three targets, so the one thing the fixed eight is for
/// can be seen: a hard month and an easy one are different cards.
#Preview("Targets eight, six and four") {
    let states = [
        GaugeSample(title: "Target 8 · 4 done, 2 booked", attended: 4, booked: 2, target: 8),
        GaugeSample(title: "Target 6 · the same days", attended: 4, booked: 2, target: 6),
        GaugeSample(title: "Target 4 · 2 done, 1 booked", attended: 2, booked: 1, target: 4),
        GaugeSample(title: "Nine done · capped at eight", attended: 9, booked: 0, target: 8),
        GaugeSample(title: "A half day · 4.5 done", attended: 4.5, booked: 2, target: 7),
    ]
    return ScrollView {
        VStack(spacing: Metrics.cardGap) {
            ForEach(states, id: \.title) { state in
                Card(padding: EdgeInsets(top: 12, leading: 16, bottom: 16, trailing: 16)) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(state.title)
                            .font(.system(size: 13))
                            .foregroundStyle(Palette.secondary)
                        AttendanceGauge(
                            attended: state.attended, booked: state.booked, target: state.target
                        )
                    }
                }
            }
        }
        .padding(Metrics.screenPadding)
    }
    .background(Palette.ground)
}
