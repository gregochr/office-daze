import Foundation

/// The dial's arithmetic, with no SwiftUI in it.
///
/// Pulled out of the view because angles are the easiest thing here to get
/// quietly wrong — an arc that starts a few degrees off still looks like a
/// gauge — and because pinning the needle at maximum is a rule, not a drawing
/// detail.
///
/// All angles are degrees clockwise from east (3 o'clock), which is where
/// SwiftUI's `Path.addArc` starts from too. The arc runs 240°, opening at the
/// bottom: from 150° (lower left) round to 390° (lower right).
nonisolated enum GaugeMetrics {

    static let startAngle: Double = 150
    static let sweep: Double = 240

    // The drawing is laid out in a fixed 256×196 box and scaled to fit, so
    // these are the mock's own numbers rather than fractions of the frame.
    static let boxSize = CGSize(width: 256, height: 196)
    static let centre = CGPoint(x: 128, y: 128)
    static let bandRadius: Double = 110
    static let bandWidth: Double = 5
    static let valueRadius: Double = 94
    static let valueWidth: Double = 20
    static let tickInnerRadius: Double = 116
    static let tickOuterRadius: Double = 124
    static let tickWidth: Double = 2
    static let needleLength: Double = 76
    static let needleWidth: Double = 3
    static let pivotRadius: Double = 6

    /// Where the threshold bands change colour, as a fraction of the target.
    static let closeThreshold: Double = 0.5
    static let metThreshold: Double = 0.85

    /// Which colour the value arc and the needle take.
    ///
    /// Note this is *not* simply the band the needle happens to sit in. The
    /// bands change to green at 85% of target, but the value arc only goes
    /// green once the target is actually met — 6 of 7 is 86% of the way round
    /// and still amber in the design, because six days is not eight days
    /// pro-rated to seven. Green means done.
    enum Level: Sendable {
        case behind, close, met
    }

    static func level(attended: Double, target: Int) -> Level {
        guard target > 0 else { return .met }
        let fraction = attended / Double(target)
        if fraction >= 1 { return .met }
        return fraction >= closeThreshold ? .close : .behind
    }

    /// How far round the arc the value sits, 0 to 1.
    ///
    /// Clamped at 1: the needle pins at maximum rather than running past the
    /// end of the dial, and the overshoot is shown as its own label. A dial
    /// whose needle can leave the scale is not telling you anything.
    static func fraction(attended: Double, target: Int) -> Double {
        guard target > 0 else { return 1 }
        return min(1, max(0, attended / Double(target)))
    }

    /// Days over target, or zero. The `Over · +2` label.
    static func overshoot(attended: Double, target: Int) -> Double {
        max(0, attended - Double(target))
    }

    /// The angle at a given fraction of the way round. The needle and the end
    /// of the value arc are the same angle, which is what makes the needle look
    /// attached to the arc rather than laid over it.
    static func angle(at fraction: Double) -> Double {
        startAngle + sweep * fraction
    }

    /// One tick per whole day, 0 to target inclusive. A month with no target
    /// gets the two ends and nothing between, rather than a division by zero.
    static func tickAngles(target: Int) -> [Double] {
        guard target > 0 else { return [startAngle, startAngle + sweep] }
        return (0...target).map { angle(at: Double($0) / Double(target)) }
    }
}
