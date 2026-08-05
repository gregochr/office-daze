import Foundation

/// The same booking arrives twice — the pass on Tuesday, the confirmation email
/// on Wednesday. Matching rules from the data-model document:
///
///   Rail  — bookingRef, else operator + departure instant + origin
///   Stay  — hotel name (fuzzy) + first night
///   Desk  — place + date. One desk per day, so a second capture is a change,
///           not a duplicate.
///
/// On a match, keep the higher provenance — pass > email > screengrab, manual
/// beating everything — and fill its empty fields from the loser. A pass
/// arriving after a screengrab should clear the amber flags the screengrab left.
nonisolated enum Dedupe {

    enum Outcome: Equatable {
        /// Nothing matched; insert as new.
        case insert
        /// Matched an existing booking; replace it with the merged result.
        case merge(into: UUID, result: MergeResult)
    }

    struct MergeResult: Equatable {
        var detail: BookingDetail
        var startsAt: Date
        var startZoneID: String
        var endsAt: Date?
        var endZoneID: String?
        var unsureFields: [String]
        var provenance: Provenance
    }

    /// A booking as the matcher sees it — enough to compare, no persistence.
    struct Candidate: Equatable {
        var id: UUID
        var detail: BookingDetail
        var startsAt: Date
        var startZoneID: String
        var endsAt: Date?
        var endZoneID: String?
        var unsureFields: [String]
        var provenance: Provenance

        var anchorDay: Day {
            Day(of: startsAt, in: TimeZone(identifier: startZoneID) ?? .gmt)
        }
    }

    static func classify(_ incoming: Candidate, against existing: [Candidate]) -> Outcome {
        guard let match = existing.first(where: { matches($0, incoming) }) else { return .insert }
        return .merge(into: match.id, result: merge(winner: match, incoming: incoming))
    }

    // MARK: Matching

    static func matches(_ a: Candidate, _ b: Candidate) -> Bool {
        guard a.detail.kind == b.detail.kind else { return false }

        switch (a.detail, b.detail) {
        case (.rail(let x), .rail(let y)):
            // A shared reference is decisive either way: same ref is the same
            // booking, different refs are different bookings even if the train
            // happens to line up (an outbound and a return can share a time).
            if let left = normalised(x.bookingRef), let right = normalised(y.bookingRef) {
                return left == right
            }
            return x.operatorName.caseInsensitiveCompare(y.operatorName) == .orderedSame
                && abs(a.startsAt.timeIntervalSince(b.startsAt)) < 60
                && sameStation(x.originStation, y.originStation)

        case (.stay(let x), .stay(let y)):
            return fuzzyEqual(x.hotelName, y.hotelName) && a.anchorDay == b.anchorDay

        case (.desk(let x), .desk(let y)):
            // One desk per day per building, so a second capture for the same
            // place and day is a change rather than a duplicate — and the merge
            // below is what applies the change.
            return fuzzyEqual(x.placeName, y.placeName) && a.anchorDay == b.anchorDay

        default:
            return false
        }
    }

    // MARK: Merging

    static func merge(winner existing: Candidate, incoming: Candidate) -> MergeResult {
        // Higher provenance wins the conflict; the loser only fills blanks.
        let keepIncoming = incoming.provenance > existing.provenance
        let primary = keepIncoming ? incoming : existing
        let secondary = keepIncoming ? existing : incoming

        let detail = mergeDetail(primary: primary.detail, secondary: secondary.detail)

        // The amber flags are recomputed from the merged detail rather than
        // carried over: a pass arriving after a screengrab clears the flags the
        // screengrab left, which only works if the flag list is derived, not
        // inherited.
        let unsure = (primary.unsureFields + secondary.unsureFields)
            .reduce(into: [String]()) { seen, name in
                if !seen.contains(name) { seen.append(name) }
            }
            .filter { !isFilled($0, in: detail) }

        return MergeResult(
            detail: detail,
            startsAt: primary.startsAt,
            startZoneID: primary.startZoneID,
            endsAt: primary.endsAt ?? secondary.endsAt,
            endZoneID: primary.endZoneID ?? secondary.endZoneID,
            unsureFields: unsure,
            provenance: max(primary.provenance, secondary.provenance)
        )
    }

    private static func mergeDetail(
        primary: BookingDetail, secondary: BookingDetail
    ) -> BookingDetail {
        switch (primary, secondary) {
        case (.rail(var a), .rail(let b)):
            a.platform = a.platform ?? b.platform
            a.coach = a.coach ?? b.coach
            a.seat = a.seat ?? b.seat
            a.bookingRef = a.bookingRef ?? b.bookingRef
            a.checkInBy = a.checkInBy ?? b.checkInBy
            a.passSerial = a.passSerial ?? b.passSerial
            a.originCode = a.originCode ?? b.originCode
            a.destCode = a.destCode ?? b.destCode
            return .rail(a)

        case (.stay(var a), .stay(let b)):
            a.address = a.address ?? b.address
            a.checkIn = a.checkIn ?? b.checkIn
            a.checkOut = a.checkOut ?? b.checkOut
            a.bookingRef = a.bookingRef ?? b.bookingRef
            return .stay(a)

        case (.desk(var a), .desk(let b)):
            a.floor = a.floor ?? b.floor
            a.hours = a.hours ?? b.hours
            return .desk(a)

        default:
            return primary
        }
    }

    /// Whether the merged detail now has a value for a previously-unsure field.
    static func isFilled(_ name: String, in detail: BookingDetail) -> Bool {
        switch detail {
        case .rail(let rail):
            switch name {
            case "platform": rail.platform != nil
            case "coach": rail.coach != nil
            case "seat": rail.seat != nil
            case "bookingRef": rail.bookingRef != nil
            case "checkInBy": rail.checkInBy != nil
            default: false
            }
        case .stay(let stay):
            switch name {
            case "checkIn": stay.checkIn != nil
            case "checkOut": stay.checkOut != nil
            case "bookingRef": stay.bookingRef != nil
            case "address": stay.address != nil
            default: false
            }
        case .desk(let desk):
            switch name {
            case "floor": desk.floor != nil
            case "hours": desk.hours != nil
            default: false
            }
        }
    }

    // MARK: Comparison helpers

    private static func normalised(_ reference: String?) -> String? {
        guard let reference else { return nil }
        let stripped = reference.uppercased().filter { $0.isLetter || $0.isNumber }
        return stripped.isEmpty ? nil : stripped
    }

    /// Station names arrive as "King's Cross", "London King's Cross", "KGX".
    /// Compare on the normalised form and accept a containment either way.
    static func sameStation(_ a: String, _ b: String) -> Bool {
        let x = normaliseName(a), y = normaliseName(b)
        guard !x.isEmpty, !y.isEmpty else { return false }
        return x == y || x.contains(y) || y.contains(x)
    }

    /// The document's "hotel name (fuzzy)". "The Ropewalk" and "Ropewalk
    /// Hotel London" are the same property; "Hotel Sablon" is not.
    static func fuzzyEqual(_ a: String, _ b: String) -> Bool {
        let x = normaliseName(a), y = normaliseName(b)
        guard !x.isEmpty, !y.isEmpty else { return false }
        return x == y || x.contains(y) || y.contains(x)
    }

    /// Lower-cased, punctuation removed, and the noise words that hotels and
    /// stations sprinkle around their actual name dropped.
    static func normaliseName(_ name: String) -> String {
        let noise: Set<String> = [
            "the", "hotel", "inn", "london", "station", "international", "rail", "by",
        ]
        return name.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { !noise.contains($0) }
            .joined()
    }
}
