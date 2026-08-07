import Foundation

/// The dial's arithmetic, with no SwiftUI in it.
///
/// Pulled out of the view because angles are the easiest thing here to get
/// quietly wrong — an arc that starts a few degrees off still looks like a
/// gauge — and because the segment arithmetic is a rule rather than a drawing
/// detail: the four parts always sum to eight, whatever the month.
///
/// All angles are degrees clockwise from east (3 o'clock), which is where
/// SwiftUI's `Path.addArc` starts from too. The arc runs 240°, opening at the
/// bottom: from 150° (lower left) round to 390° (lower right).
///
/// **The scale is fixed at eight — the base target, never the pro-rated one.**
/// That is what makes two months comparable: a month with five days' leave and
/// a month with none draw the same dial at the same rate, and the difference
/// between them is drawn rather than left to the end label. The pro-rating is
/// the hatched segment; the target is a mark on the scale, not the scale.
nonisolated enum GaugeMetrics {

    static let startAngle: Double = 150
    static let sweep: Double = 240

    /// The dial always runs 0 to 8, whatever this month's target is.
    static var scale: Double { Quota.baseTarget }

    // The drawing is laid out in a fixed 256×208 box and scaled to fit, so
    // these are the mock's own numbers rather than fractions of the frame.
    static let boxSize = CGSize(width: 256, height: 208)
    static let centre = CGPoint(x: 128, y: 128)
    static let valueRadius: Double = 94
    static let valueWidth: Double = 20
    static let tickInnerRadius: Double = 116
    static let tickOuterRadius: Double = 124
    static let tickWidth: Double = 2
    /// The target mark, drawn across the arc rather than outside it: it is a
    /// line on the scale, and everything left of it has to be filled.
    static let markerWidth: Double = 2.5
    static let markerOverhang: Double = 4

    /// What a stretch of the arc is saying.
    ///
    /// Colour has one job each and no judgement in any of them: solid means
    /// counted, tint means promised, empty means owed, hatched means not owed.
    /// There is no red, amber or green anywhere on the dial — it is an
    /// inventory, and the judgement lives in the strip underneath.
    enum Part: Sendable {
        /// Days worked. The only thing that counts.
        case attended
        /// Days booked ahead — the same currency, not yet earned.
        case booked
        /// The gap between the two and the target. Empty track.
        case gap
        /// `8 − target`: what leave took off. Hatched, so it reads as excluded
        /// rather than merely empty.
        case off
    }

    /// A stretch of the arc, in days from the start of the scale.
    struct Segment: Equatable, Sendable {
        let part: Part
        let from: Double
        let to: Double

        var days: Double { to - from }
    }

    /// The four segments, laid end to end, always summing to eight.
    ///
    /// Surplus runs on past the target marker and eats into the hatching, which
    /// is the right picture — days you did not owe. Beyond eight the arc is
    /// capped and the label carries the rest: a dial that can leave its own
    /// scale is not telling you anything.
    static func segments(attended: Double, booked: Double, target: Int) -> [Segment] {
        let scale = scale
        let worked = min(scale, max(0, attended))
        let promised = min(scale - worked, max(0, booked))
        let rest = scale - worked - promised
        // What is still to find: the distance from what is arranged to the
        // target, and never more than the arc has left.
        let gap = min(rest, max(0, Double(target) - worked - promised))
        let off = rest - gap

        var cursor: Double = 0
        return [(Part.attended, worked), (.booked, promised), (.gap, gap), (.off, off)]
            .compactMap { part, days in
                guard days > 0 else { return nil }
                defer { cursor += days }
                return Segment(part: part, from: cursor, to: cursor + days)
            }
    }

    /// Where the target mark sits, as a fraction of the arc. This is the one
    /// rule to learn — the arc has to reach the mark — and it is the same rule
    /// in every month.
    static func markerFraction(target: Int) -> Double {
        fraction(days: Double(target))
    }

    /// How far round the arc a number of days sits, 0 to 1.
    static func fraction(days: Double) -> Double {
        min(1, max(0, days / scale))
    }

    /// Days over target, or zero. The `+1 over` label.
    static func overshoot(attended: Double, target: Int) -> Double {
        max(0, attended - Double(target))
    }

    /// The angle at a given fraction of the way round.
    static func angle(at fraction: Double) -> Double {
        startAngle + sweep * fraction
    }

    /// One tick per whole day, 0 through 8 inclusive. Fixed, like the scale —
    /// the ticks are days, and a day is the same size in every month.
    static func tickAngles() -> [Double] {
        (0...Int(scale)).map { angle(at: fraction(days: Double($0))) }
    }
}
