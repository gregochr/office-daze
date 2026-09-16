import Foundation

/// The slot row's arithmetic, with no SwiftUI in it.
///
/// Pulled out of the view because what fills a slot is a rule rather than a
/// drawing detail: the parts always sum to eight, whatever the month, and they
/// are laid out by state rather than by date. `AttendanceGauge` only paints what
/// this decides.
///
/// **The row is always eight long — the base target, never the pro-rated one.**
/// That is what makes two months comparable: a month with five days' leave and
/// a month with none draw eight slots each, and the difference between them is
/// drawn, as hatching at the far end, rather than left to a label.
nonisolated enum GaugeMetrics {

    /// Eight, whatever this month's target is. Never nine: past eight the row
    /// is full and the verdict line carries the surplus.
    static var slotCount: Int { Int(Quota.baseTarget) }

    /// What a stretch of the row is saying.
    ///
    /// Colour has one job each and no judgement in any of them: solid means
    /// counted, tint means promised, grey means owed, hatched means not owed.
    /// There is no red, amber or green anywhere in the row — it is a tally, and
    /// the judgement lives in the verdict line underneath.
    enum Part: Sendable {
        /// Days worked. The only thing that counts.
        case attended
        /// Days booked and not yet worked, today's included — the same
        /// currency, not yet earned.
        case booked
        /// The gap between the two and the target. Still to find.
        case gap
        /// `8 − target`: what leave took off. Hatched, so it reads as excluded
        /// rather than merely empty.
        case off
    }

    /// A stretch of the row, in days from its start.
    struct Segment: Equatable, Sendable {
        let part: Part
        let from: Double
        let to: Double

        var days: Double { to - from }
    }

    /// How much of one slot a part fills, reading left to right.
    struct Share: Equatable, Sendable {
        let part: Part
        let fraction: Double
    }

    /// The four segments, laid end to end, always summing to eight.
    ///
    /// Surplus runs on past the target and eats into the hatching, which is the
    /// right picture — days you did not owe. Beyond eight the row is capped and
    /// the verdict line carries the rest: a ninth slot would be a tally that
    /// can leave its own frame.
    static func segments(attended: Double, booked: Double, target: Int) -> [Segment] {
        let length = Double(slotCount)
        let worked = min(length, max(0, attended))
        let promised = min(length - worked, max(0, booked))
        let rest = length - worked - promised
        // What is still to find: the distance from what is arranged to the
        // target, and never more than the row has left.
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

    /// The eight slots, each as the parts that fill it.
    ///
    /// A whole day fills a slot on its own. Only a half day splits one, because
    /// attendance is recorded in halves: rounding it up would draw half a day
    /// nobody worked, and rounding it down would hide one that was.
    static func slots(attended: Double, booked: Double, target: Int) -> [[Share]] {
        let segments = Self.segments(attended: attended, booked: booked, target: target)
        return (0..<slotCount).map { index in
            let start = Double(index)
            return segments.compactMap { segment in
                let overlap = min(start + 1, segment.to) - max(start, segment.from)
                return overlap > 0 ? Share(part: segment.part, fraction: overlap) : nil
            }
        }
    }

    /// Worked, plus today if it is booked, plus everything booked ahead: the
    /// second figure under the row, `6 of 7 planned`. `booked` is the quota's
    /// forecast, which already holds today until the day is out.
    static func planned(attended: Double, booked: Double) -> Double {
        max(0, attended) + max(0, booked)
    }

    /// Days over target, or zero. The verdict line's `· 1 over`.
    static func overshoot(attended: Double, target: Int) -> Double {
        max(0, attended - Double(target))
    }
}
