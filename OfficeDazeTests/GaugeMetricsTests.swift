import Foundation
import Testing
@testable import OfficeDaze

/// The dial is the centrepiece and the fiddliest thing in the app, so its
/// angles and its segments are pinned here rather than judged by eye.
@Suite("Gauge metrics")
struct GaugeMetricsTests {

    @Test("The arc opens at the bottom, 240° from lower left to lower right")
    func sweep() {
        // 150° and 390° clockwise from east: symmetric about straight down,
        // leaving a 120° gap at the bottom for the reading to sit in.
        #expect(GaugeMetrics.angle(at: 0) == 150)
        #expect(GaugeMetrics.angle(at: 1) == 390)
        #expect(GaugeMetrics.angle(at: 0.5) == 270, "half way is straight up")
    }

    /// The one thing that makes two months comparable. A target of six and a
    /// target of eight used to draw an identical dial with a different end
    /// label, so a hard month and an easy one filled at the same rate.
    @Test("The scale is always eight, whatever this month's target is")
    func fixedScale() {
        #expect(GaugeMetrics.scale == 8)
        #expect(GaugeMetrics.fraction(days: 4) == 0.5)
        #expect(GaugeMetrics.fraction(days: 8) == 1)
        // The same three days sit at the same angle in both months.
        #expect(GaugeMetrics.fraction(days: 3) == 0.375)
        #expect(GaugeMetrics.markerFraction(target: 6) == 0.75)
        #expect(GaugeMetrics.markerFraction(target: 8) == 1)
    }

    /// The design's worked example: August 2026, five days' leave, so two days
    /// off the target. Three attended, three booked, nothing left to find.
    @Test("The four segments lay end to end and sum to eight")
    func segments() {
        let segments = GaugeMetrics.segments(attended: 3, booked: 3, target: 6)
        #expect(segments.map(\.part) == [.attended, .booked, .off])
        #expect(segments.map(\.days) == [3, 3, 2])
        #expect(segments.first?.from == 0)
        #expect(segments.last?.to == 8, "the arc is always full")

        // Laid end to end, with no gaps between them.
        for (a, b) in zip(segments, segments.dropFirst()) {
            #expect(a.to == b.from)
        }
    }

    /// A month with something still to find. The gap is the distance from what
    /// is arranged to the target, and the hatching is what leave took off.
    @Test("The gap is what is owed and the hatching is what is not")
    func gapAndOff() {
        let short = GaugeMetrics.segments(attended: 2, booked: 1, target: 8)
        #expect(short.map(\.part) == [.attended, .booked, .gap])
        #expect(short.map(\.days) == [2, 1, 5], "nothing hatched: no leave, no relief")

        let relieved = GaugeMetrics.segments(attended: 1, booked: 1, target: 4)
        #expect(relieved.map(\.part) == [.attended, .booked, .gap, .off])
        #expect(relieved.map(\.days) == [1, 1, 2, 4])
    }

    /// Days you did not owe. The right picture is the arc running on past the
    /// marker into the hatching, not a needle pinned at the end of a scale.
    @Test("Surplus runs past the marker and eats into the hatching")
    func surplus() {
        let over = GaugeMetrics.segments(attended: 7, booked: 1, target: 6)
        #expect(over.map(\.part) == [.attended, .booked])
        #expect(over.map(\.days) == [7, 1])
        #expect(GaugeMetrics.overshoot(attended: 7, target: 6) == 1)
    }

    /// Beyond eight the arc is capped and the label carries the rest — a dial
    /// that can leave its own scale is not telling you anything.
    @Test("The arc stops at eight however good the month was")
    func capsAtEight() {
        let huge = GaugeMetrics.segments(attended: 11, booked: 2, target: 6)
        #expect(huge.map(\.days) == [8])
        #expect(huge.first?.part == .attended)
        #expect(GaugeMetrics.overshoot(attended: 11, target: 6) == 5)
        #expect(GaugeMetrics.fraction(days: 11) == 1)
    }

    /// A month entirely on leave has a target of zero: nothing owed, everything
    /// hatched. Nothing here may divide by it.
    @Test("A target of zero hatches the whole arc rather than dividing by it")
    func emptyTarget() {
        let none = GaugeMetrics.segments(attended: 0, booked: 0, target: 0)
        #expect(none.map(\.part) == [.off])
        #expect(none.map(\.days) == [8])
        #expect(GaugeMetrics.markerFraction(target: 0) == 0)
    }

    @Test("Nothing attended is an empty arc, not a full one")
    func nothingAttended() {
        let empty = GaugeMetrics.segments(attended: 0, booked: 0, target: 8)
        #expect(empty.map(\.part) == [.gap])
        #expect(empty.map(\.days) == [8])
    }

    @Test("Half days take half a segment")
    func halfDays() {
        let half = GaugeMetrics.segments(attended: 3.5, booked: 0, target: 7)
        #expect(half.map(\.days) == [3.5, 3.5, 1])
        #expect(half.map(\.part) == [.attended, .gap, .off])
        #expect(GaugeMetrics.angle(at: GaugeMetrics.fraction(days: 4)) == 270)
    }

    /// The ticks are days, and a day is the same width in every month — which
    /// is the fixed scale restated, and the reason they no longer take a
    /// target.
    @Test("Nine ticks, one per whole day, evenly spaced")
    func ticks() {
        let ticks = GaugeMetrics.tickAngles()
        #expect(ticks.count == 9, "0 through 8 inclusive")
        #expect(ticks.first == 150)
        #expect(ticks.last == 390)
        let gaps = zip(ticks, ticks.dropFirst()).map { $1 - $0 }
        #expect(gaps.allSatisfy { abs($0 - 30) < 0.0001 })
    }
}
