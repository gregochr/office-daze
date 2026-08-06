import Foundation
import Testing
@testable import Travel8tor

/// One desk per office per day. Re-sharing the same screenshot must not double
/// the month, and typing a booking in by hand must not be undone by the next
/// capture.
@Suite("Booking merge")
struct BookingMergeTests {

    let london = UUID()
    let brussels = UUID()

    func booking(
        _ office: UUID, _ day: Day, desk: String = "3C-114",
        floor: String? = "Level 3", zone: String? = "C",
        start: String? = "09:00", end: String? = "17:00",
        source: BookingSource = .capture, unsure: [String] = []
    ) -> BookingMerge.Candidate {
        .init(
            officeID: office, day: day, deskID: desk, floor: floor, zone: zone,
            startTime: start, endTime: end, source: source, unsureFields: unsure
        )
    }

    @Test("Office plus date is the whole match rule")
    func matching() {
        let day = Day(2026, 8, 5)
        // Same office, same day, different desk — the desk was moved, and this
        // is a change to one booking rather than two bookings.
        #expect(BookingMerge.matches(
            booking(london, day, desk: "3C-114"),
            booking(london, day, desk: "3C-121")
        ))
        #expect(!BookingMerge.matches(booking(london, day), booking(brussels, day)))
        #expect(!BookingMerge.matches(booking(london, day), booking(london, day.adding(days: 1))))
    }

    @Test("A second capture updates the desk rather than adding a booking")
    func captureOverCapture() {
        let merged = BookingMerge.merge(
            incoming: booking(london, Day(2026, 8, 5), desk: "3C-121"),
            into: booking(london, Day(2026, 8, 5), desk: "3C-114")
        )
        #expect(merged.deskID == "3C-121", "the newer read wins")
    }

    @Test("Manual wins, because it is the user correcting the machine")
    func manualOutranksCapture() {
        let stored = booking(london, Day(2026, 8, 5), desk: "3C-999", source: .manual)
        let merged = BookingMerge.merge(
            incoming: booking(london, Day(2026, 8, 5), desk: "3C-114"), into: stored
        )
        #expect(merged.deskID == "3C-999")
        #expect(merged.source == .manual)
    }

    @Test("A manual booking overwrites a captured one")
    func manualOverwritesCapture() {
        let merged = BookingMerge.merge(
            incoming: booking(london, Day(2026, 8, 5), desk: "3C-999", source: .manual),
            into: booking(london, Day(2026, 8, 5), desk: "3C-114")
        )
        #expect(merged.deskID == "3C-999")
    }

    @Test("Empty fields on the winner are filled from the loser")
    func fillsGaps() {
        // A clearer second screenshot completes a half-read booking rather than
        // replacing it with another half-read one.
        let merged = BookingMerge.merge(
            incoming: booking(
                london, Day(2026, 8, 5), floor: nil, zone: "C", end: nil,
                unsure: ["floor", "endTime"]
            ),
            into: booking(london, Day(2026, 8, 5), floor: "Level 3", zone: nil, end: "17:00")
        )
        #expect(merged.floor == "Level 3")
        #expect(merged.zone == "C")
        #expect(merged.endTime == "17:00")
    }

    @Test("A field filled by the merge stops needing checking")
    func clearsTheMarker() {
        let merged = BookingMerge.merge(
            incoming: booking(london, Day(2026, 8, 5), floor: nil, unsure: ["floor"]),
            into: booking(london, Day(2026, 8, 5), floor: "Level 3")
        )
        #expect(merged.floor == "Level 3")
        #expect(merged.unsureFields.isEmpty, "the amber marker clears when the gap is filled")
    }

    @Test("A field neither record could read stays flagged")
    func keepsTheMarkerWhenStillUnread() {
        let merged = BookingMerge.merge(
            incoming: booking(london, Day(2026, 8, 5), zone: nil, unsure: ["zone"]),
            into: booking(london, Day(2026, 8, 5), zone: nil)
        )
        #expect(merged.zone == nil)
        #expect(merged.unsureFields == ["zone"], "absent, and still named — never guessed")
    }
}

@Suite("Office colours")
struct OfficeColourTests {

    @Test("Colours are handed out in order")
    func inOrder() {
        #expect(OfficeColours.next(after: []) == "#0A7A6E")
        #expect(OfficeColours.next(after: ["#0A7A6E"]) == "#5856D6")
    }

    @Test("No two offices share a colour")
    func neverReused() {
        var taken: [String] = []
        for _ in 0..<OfficeColours.palette.count {
            let next = OfficeColours.next(after: taken)
            #expect(next != nil)
            taken.append(next!)
        }
        #expect(Set(taken).count == OfficeColours.palette.count)
        // A seventh office has no colour left. Nil rather than wrapping round,
        // so the caller has to decide rather than silently twinning an office.
        #expect(OfficeColours.next(after: taken) == nil)
    }
}
