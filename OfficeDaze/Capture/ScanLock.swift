import Foundation

/// Watches the text the camera is reading and says when the frame is worth a
/// model call.
///
/// The split it exists to enforce: on-device recognition decides *when*, one
/// Claude call decides *what*. Recognition is free and runs at frame rate;
/// a capture is around 0.4p, so a call per frame would be several pounds a
/// minute. Nothing here tries to read the booking itself — the group-heading
/// dates, the two-letter site code and the rule against inventing a value are
/// the prompt's job, and a regex reimplementation of them is how you get a
/// booking that is confidently wrong.
///
/// The one real risk is firing on the wrong frame, so the bar is deliberately
/// high: a desk id in the site's own shape, a word that only a booking
/// document would carry, and both holding still for three frames. A user
/// panning across a desk finds the shutter goes off mid-sweep otherwise.
struct ScanLock {

    /// Frames the same desk id has to survive before firing. One frame fires
    /// mid-pan on whatever happened to be sharp; too many and the phone has to
    /// be held still long enough that you may as well have pressed a button.
    static let framesToSettle = 3

    /// Words that only a booking document carries. Required alongside the desk
    /// id rather than instead of it: eight characters in the right shape can
    /// turn up on a badge or a parcel label, and the pairing is what makes the
    /// match confident enough to spend a call on. All three layouts the prompt
    /// knows about carry at least one — the table its statuses, the single
    /// confirmation its building, the reservation page its heading.
    private static let cues = [
        "RESERVATION", "CONFIRMED", "BOOKING", "BUILDING", "DESK", "FLOOR",
    ]

    private var candidate: String?
    private var streak = 0
    private(set) var isLocked = false

    /// The desk id the frame settled on, once, or nil to keep looking.
    ///
    /// Returning it only on the frame that crosses the line is the whole
    /// debounce: the caller cannot fire twice because it is never told twice.
    mutating func observe(_ text: String) -> String? {
        guard !isLocked else { return nil }

        guard let found = Self.candidate(in: text) else {
            candidate = nil
            streak = 0
            return nil
        }
        // Counted on the desk id rather than the whole frame's text, because
        // the surrounding text jitters between frames — a row half out of
        // shot, a word the recogniser drops — and a streak that resets on any
        // of that would never reach three.
        if found == candidate {
            streak += 1
        } else {
            candidate = found
            streak = 1
        }

        guard streak >= Self.framesToSettle else { return nil }
        isLocked = true
        return found
    }

    /// The user got there first. True if this is the tap that fires.
    ///
    /// A document whose wording none of the cues match would otherwise leave a
    /// viewfinder that never goes off and offers no way to make it — a dead
    /// end with only Cancel out of it. Latching here rather than firing
    /// directly is what stops the frames still arriving from spending a second
    /// call on top of the tap's.
    mutating func lockNow() -> Bool {
        guard !isLocked else { return false }
        isLocked = true
        return true
    }

    /// The capture the lock asked for never happened. Back to looking, rather
    /// than a viewfinder that has quietly stopped scanning.
    mutating func reset() {
        candidate = nil
        streak = 0
        isLocked = false
    }

    // MARK: Reading the frame

    /// The desk id in this frame, if it is a frame worth firing on.
    static func candidate(in text: String) -> String? {
        let upper = text.uppercased()
        guard cues.contains(where: upper.contains) else { return nil }
        return deskID(in: upper)
    }

    /// Two letters for the site, digits for the floor, then the desk itself —
    /// CO03C117. The leading pair is letters always, which is what keeps a
    /// date, a postcode or a reservation number like WRES1946519 from
    /// matching: each fails at the very first thing the pattern asks for.
    ///
    /// The word boundaries matter as much as the shape. Without them the tail
    /// of a longer token qualifies, and a locked-on scanner that fired on the
    /// second half of a serial number would be worse than no scanner.
    private static func deskID(in uppercased: String) -> String? {
        uppercased.firstMatch(of: /\b[A-Z]{2}\d{2}[A-Z]?\d{2,4}\b/).map(\.output)
            .map(String.init)
    }
}
