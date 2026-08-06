import Foundation

/// One rule, because there is only one kind of booking: **match on office plus
/// date**.
///
/// One desk per office per day. A second capture for the same office and date
/// is a *change*, not a duplicate — the desk was moved, or the first read was
/// wrong — so it updates the existing row rather than adding another. Get this
/// wrong and re-sharing the same screenshot doubles the month.
///
/// A pure function over a projection rather than a method on the SwiftData
/// model, so the rule can be tested without a store.
nonisolated enum BookingMerge {

    /// Everything the rule needs off a booking, and nothing else.
    struct Candidate: Equatable, Sendable {
        var officeID: UUID
        var day: Day
        var deskID: String
        var floor: String?
        var zone: String?
        var startTime: String?
        var endTime: String?
        var source: BookingSource
        var unsureFields: [String]

        init(
            officeID: UUID,
            day: Day,
            deskID: String,
            floor: String? = nil,
            zone: String? = nil,
            startTime: String? = nil,
            endTime: String? = nil,
            source: BookingSource,
            unsureFields: [String] = []
        ) {
            self.officeID = officeID
            self.day = day
            self.deskID = deskID
            self.floor = floor
            self.zone = zone
            self.startTime = startTime
            self.endTime = endTime
            self.source = source
            self.unsureFields = unsureFields
        }
    }

    static func matches(_ a: Candidate, _ b: Candidate) -> Bool {
        a.officeID == b.officeID && a.day == b.day
    }

    /// The row that should be kept when an incoming booking matches a stored
    /// one.
    ///
    /// `manual` wins: a booking typed by hand is the user correcting the
    /// machine, and letting the next screenshot overwrite it would undo the
    /// correction. Where the winner has nothing, the loser's value fills the
    /// gap — which is how a re-share of a clearer screenshot completes a
    /// half-read booking instead of replacing it with another half-read one.
    ///
    /// `chosen` is the capture sheet having asked. That heuristic exists for
    /// when nobody is there to answer; once the user has been shown both desks
    /// and picked this one, it is an answer and not a guess, and a rule that
    /// overruled it would make the question a lie.
    static func merge(
        incoming: Candidate, into stored: Candidate, chosen: Bool = false
    ) -> Candidate {
        let incomingWins = chosen || incoming.source == .manual || stored.source != .manual
        var winner = incomingWins ? incoming : stored
        let loser = incomingWins ? stored : incoming

        // A desk id is never empty on a stored booking, so this only fires when
        // the winner is an incoming record the model could not fully read.
        if winner.deskID.isEmpty { winner.deskID = loser.deskID }
        winner.floor = winner.floor ?? loser.floor
        winner.zone = winner.zone ?? loser.zone
        winner.startTime = winner.startTime ?? loser.startTime
        winner.endTime = winner.endTime ?? loser.endTime

        // A field that has just been filled in is no longer unsure. Dropping it
        // from the list is what clears the "needs checking" marker.
        winner.unsureFields = winner.unsureFields.filter { !filled($0, in: winner) }
        return winner
    }

    private static func filled(_ field: String, in candidate: Candidate) -> Bool {
        switch field {
        case "deskId": !candidate.deskID.isEmpty
        case "floor": candidate.floor != nil
        case "zone": candidate.zone != nil
        case "startTime": candidate.startTime != nil
        case "endTime": candidate.endTime != nil
        default: false
        }
    }
}
