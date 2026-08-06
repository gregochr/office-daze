import Foundation

/// Which office a captured booking belongs to.
///
/// No match creates nothing. A silently-invented office would get its own
/// colour, its own perimeter and its own row on the home screen, and the user
/// would find out when the arrival alert failed to fire — so an unmatched
/// booking asks instead.
nonisolated enum OfficeMatcher {

    /// What the rule needs off an `Office`, and nothing else.
    struct Candidate: Equatable, Sendable {
        var id: UUID
        var name: String
        var postcode: String
        var address: String
    }

    /// The office name as the booking system prints it — `Coleman, London` —
    /// matched against what the user typed when they added the office.
    ///
    /// Deliberately conservative. A wrong match files a booking under the wrong
    /// building, which is worse than asking.
    static func match(_ printed: String?, against offices: [Candidate]) -> Candidate? {
        guard let printed = printed?.trimmingCharacters(in: .whitespacesAndNewlines),
              !printed.isEmpty, !offices.isEmpty else { return nil }

        // A postcode is unambiguous when it appears, so it goes first.
        if let byPostcode = offices.first(where: {
            !$0.postcode.isEmpty && printed.localizedCaseInsensitiveContains($0.postcode)
        }) { return byPostcode }

        let parts = tokens(printed)
        guard !parts.isEmpty else { return nil }

        // Every word of the office's name appearing in the printed string, or
        // the reverse — "Coleman" matches "Coleman, London", and an office
        // named "Coleman, London" matches a printed "Coleman".
        let matches = offices.filter { office in
            let name = tokens(office.name)
            guard !name.isEmpty else { return false }
            return name.isSubset(of: parts) || parts.isSubset(of: name)
        }

        // Exactly one, or nothing. Two offices that both look right is the case
        // where guessing does the most damage.
        return matches.count == 1 ? matches.first : nil
    }

    /// Lower-cased words, punctuation dropped, and the noise words a booking
    /// system pads a building name with removed.
    private static func tokens(_ text: String) -> Set<String> {
        let noise: Set<String> = ["the", "office", "building", "floor", "level"]
        return Set(
            text.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count > 1 && !noise.contains($0) && Int($0) == nil }
        )
    }
}
