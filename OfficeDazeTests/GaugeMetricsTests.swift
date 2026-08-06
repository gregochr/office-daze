import Foundation
import Testing
@testable import OfficeDaze

/// The dial is the centrepiece and the fiddliest thing in the app, so its
/// angles are pinned here rather than judged by eye.
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

    /// The mock draws 4 of 7 with the needle at rotate(377) from twelve
    /// o'clock, which is 377 − 90 = 287 from east.
    @Test("The needle lands where the mock puts it")
    func needleMatchesTheMock() {
        let cases: [(Double, Int, Double)] = [
            (4, 7, 287),   // home screen
            (1, 7, 184),   // behind
            (6, 7, 356),   // close
            (7, 7, 390),   // met
        ]
        for (attended, target, expected) in cases {
            let angle = GaugeMetrics.angle(
                at: GaugeMetrics.fraction(attended: attended, target: target)
            )
            #expect(abs(angle - expected) < 0.6, "\(attended) of \(target)")
        }
    }

    @Test("The needle pins at maximum rather than running past the end")
    func pinsAtMaximum() {
        // A dial whose needle can leave the scale is not telling you anything.
        #expect(GaugeMetrics.fraction(attended: 9, target: 7) == 1)
        #expect(GaugeMetrics.angle(at: GaugeMetrics.fraction(attended: 99, target: 7)) == 390)
        #expect(GaugeMetrics.overshoot(attended: 9, target: 7) == 2, "shown as its own label")
        #expect(GaugeMetrics.overshoot(attended: 7, target: 7) == 0)
    }

    /// Not the band the needle sits in: the bands turn green at 85%, but 6 of 7
    /// is 86% of the way round and still amber in the design. Green means the
    /// target is met, not nearly met.
    @Test("Green means met, not nearly met")
    func levels() {
        #expect(GaugeMetrics.level(attended: 1, target: 7) == .behind)
        #expect(GaugeMetrics.level(attended: 3, target: 7) == .behind, "3/7 is 43%")
        #expect(GaugeMetrics.level(attended: 3.5, target: 7) == .close, "exactly half")
        #expect(GaugeMetrics.level(attended: 6, target: 7) == .close, "86%, and still amber")
        #expect(GaugeMetrics.level(attended: 7, target: 7) == .met)
        #expect(GaugeMetrics.level(attended: 9, target: 7) == .met)
    }

    @Test("One tick per whole day, at both ends and every day between")
    func ticks() {
        let ticks = GaugeMetrics.tickAngles(target: 7)
        #expect(ticks.count == 8, "0 through 7 inclusive")
        #expect(ticks.first == 150)
        #expect(ticks.last == 390)
        // Evenly spaced, or the scale lies about which day the needle is at.
        let gaps = zip(ticks, ticks.dropFirst()).map { $1 - $0 }
        #expect(gaps.allSatisfy { abs($0 - 240.0 / 7) < 0.0001 })
    }

    /// A month entirely on leave has a target of zero. Nothing here may divide
    /// by it.
    @Test("A target of zero does not divide by zero")
    func emptyTarget() {
        #expect(GaugeMetrics.fraction(attended: 0, target: 0) == 1)
        #expect(GaugeMetrics.level(attended: 0, target: 0) == .met)
        #expect(GaugeMetrics.tickAngles(target: 0) == [150, 390])
    }

    @Test("Nothing attended is an empty arc, not a full one")
    func nothingAttended() {
        #expect(GaugeMetrics.fraction(attended: 0, target: 8) == 0)
        #expect(GaugeMetrics.level(attended: 0, target: 8) == .behind)
    }

    @Test("Half days move the needle half a day")
    func halfDays() {
        let half = GaugeMetrics.fraction(attended: 3.5, target: 7)
        #expect(half == 0.5)
        #expect(GaugeMetrics.angle(at: half) == 270)
    }
}
