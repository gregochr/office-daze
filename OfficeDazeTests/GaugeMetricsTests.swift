import Foundation
import Testing
@testable import OfficeDaze

/// The slot row is the centrepiece of the home screen, and what fills each slot
/// is a rule rather than a look, so the segments and the slots are pinned here
/// rather than judged by eye.
@Suite("Gauge metrics")
struct GaugeMetricsTests {

    /// The parts of every slot, one letter a part, so a row reads the way it
    /// draws: `AAAABBGG` is four worked, two booked, two still to find.
    private func row(attended: Double, booked: Double = 0, target: Int) -> String {
        GaugeMetrics.slots(attended: attended, booked: booked, target: target)
            .map { shares in
                shares.map { share in
                    switch share.part {
                    case .attended: "A"
                    case .booked: "B"
                    case .gap: "G"
                    case .off: "O"
                    }
                }
                .joined()
            }
            .joined(separator: " ")
    }

    /// Always eight — never the pro-rated target, and never nine.
    @Test("The row is eight slots whatever the target")
    func alwaysEight() {
        for target in 0...8 {
            #expect(GaugeMetrics.slots(attended: 3, booked: 2, target: target).count == 8)
        }
        #expect(GaugeMetrics.slots(attended: 12, booked: 4, target: 8).count == 8, "never nine")
    }

    /// The acceptance case: from eight down to four, `8 − target` hatched at the
    /// far end. And the reason the row is fixed — the same days against target
    /// eight and target six are visibly different cards, where the dial drew
    /// them identically but for one label.
    @Test("What leave took off is hatched at the far end, for every target from eight to four")
    func hatchingIsTheRelief() {
        #expect(row(attended: 2, booked: 1, target: 8) == "A A B G G G G G")
        #expect(row(attended: 2, booked: 1, target: 7) == "A A B G G G G O")
        #expect(row(attended: 2, booked: 1, target: 6) == "A A B G G G O O")
        #expect(row(attended: 2, booked: 1, target: 5) == "A A B G G O O O")
        #expect(row(attended: 2, booked: 1, target: 4) == "A A B G O O O O")
        #expect(
            row(attended: 4, booked: 2, target: 8) != row(attended: 4, booked: 2, target: 6),
            "a hard month and an easy one are different cards"
        )
    }

    /// Sorted by state, not by date: whatever order the days fell in, the row is
    /// worked, then booked, then still to find, then off.
    @Test("The slots are a tally in state order, not a calendar")
    func stateOrder() {
        let parts = GaugeMetrics.slots(attended: 3, booked: 2, target: 7).flatMap { $0.map(\.part) }
        #expect(parts == [.attended, .attended, .attended, .booked, .booked, .gap, .gap, .off])
    }

    /// The design's worked example: five days' leave, so two days off the
    /// target. Three attended, three booked, nothing left to find.
    @Test("The four segments lay end to end and sum to eight")
    func segments() {
        let segments = GaugeMetrics.segments(attended: 3, booked: 3, target: 6)
        #expect(segments.map(\.part) == [.attended, .booked, .off])
        #expect(segments.map(\.days) == [3, 3, 2])
        #expect(segments.first?.from == 0)
        #expect(segments.last?.to == 8, "the row is always full")

        // Laid end to end, with no gaps between them.
        for (a, b) in zip(segments, segments.dropFirst()) {
            #expect(a.to == b.from)
        }
    }

    /// Days you did not owe. Surplus below eight runs on into the hatching
    /// rather than pushing the row past its end.
    @Test("Surplus runs past the target and eats into the hatching")
    func surplus() {
        #expect(row(attended: 7, target: 6) == "A A A A A A A O")
        #expect(row(attended: 5, booked: 2, target: 6) == "A A A A A B B O")
        #expect(GaugeMetrics.overshoot(attended: 7, target: 6) == 1)
    }

    /// Beyond eight the row is capped and the verdict line carries the rest —
    /// a ninth slot would be a tally that can leave its own frame.
    @Test("Nine attended is eight worked slots, and one over")
    func capsAtEight() {
        #expect(row(attended: 9, target: 8) == "A A A A A A A A")
        #expect(GaugeMetrics.overshoot(attended: 9, target: 8) == 1)

        let huge = GaugeMetrics.segments(attended: 11, booked: 2, target: 6)
        #expect(huge.map(\.days) == [8])
        #expect(huge.first?.part == .attended, "booked ahead has nowhere left to go")
        #expect(GaugeMetrics.overshoot(attended: 11, target: 6) == 5)
    }

    /// A month entirely on leave has a target of zero: nothing owed, everything
    /// hatched. Nothing here may divide by it.
    @Test("A target of zero hatches the whole row")
    func emptyTarget() {
        #expect(row(attended: 0, target: 0) == "O O O O O O O O")
    }

    @Test("Nothing attended is an empty row, not a full one")
    func nothingAttended() {
        #expect(row(attended: 0, target: 8) == "G G G G G G G G")
    }

    /// Attendance is recorded in halves. Rounding up would draw half a day
    /// nobody worked; rounding down would hide one that was. So the half splits
    /// its slot, and everything after it moves along by half a slot too.
    @Test("A half day splits a slot rather than rounding")
    func halfDays() {
        #expect(row(attended: 3.5, target: 7) == "A A A AG G G G O")
        #expect(row(attended: 4.5, booked: 2, target: 7) == "A A A A AB B BG O")

        let split = GaugeMetrics.slots(attended: 3.5, booked: 0, target: 7)[3]
        #expect(split.map(\.fraction) == [0.5, 0.5])

        // Every slot is exactly full, halves included.
        for shares in GaugeMetrics.slots(attended: 4.5, booked: 2, target: 7) {
            #expect(shares.reduce(0) { $0 + $1.fraction } == 1)
        }
    }

    /// The second figure, `6 of 7 planned`. The booked half is the quota's
    /// forecast, which already holds today's desk until the day is out.
    @Test("Planned is what is worked plus what is booked")
    func planned() {
        #expect(GaugeMetrics.planned(attended: 4, booked: 2) == 6)
        #expect(GaugeMetrics.planned(attended: 4.5, booked: 2) == 6.5)
        #expect(GaugeMetrics.planned(attended: 0, booked: 0) == 0)
    }

    /// VoiceOver gets one stop for the whole row, and it reads the two figures:
    /// eight stops saying "filled" would be a calendar it could not date.
    @Test("The row is read out as its two figures")
    func spoken() {
        #expect(AttendanceGauge.spoken(attended: 4, booked: 2, target: 7) == "4 days done, 6 of 7 planned")
        #expect(AttendanceGauge.spoken(attended: 1, booked: 0, target: 8) == "1 day done, 1 of 8 planned")
        #expect(AttendanceGauge.spoken(attended: 4.5, booked: 2, target: 7) == "4.5 days done, 6.5 of 7 planned")
    }
}
