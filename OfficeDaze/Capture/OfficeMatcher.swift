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
        /// Names this office has already been identified by, from the sheet
        /// having asked once and been told.
        var aliases: [String] = []
    }

    /// The office name as the booking system prints it — `Coleman, London` —
    /// matched against what the user typed when they added the office.
    ///
    /// Deliberately conservative. A wrong match files a booking under the wrong
    /// building, which is worse than asking.
    static func match(_ printed: String?, against offices: [Candidate]) -> Candidate? {
        guard let printed = printed?.trimmingCharacters(in: .whitespacesAndNewlines),
              !printed.isEmpty, !offices.isEmpty else { return nil }

        // Before any rule, because an alias is not a heuristic that happened to
        // fire — it is the user having been asked this exact question and
        // having answered it. Two offices claiming the same name is the one
        // case it does not settle, and that asks again.
        let claiming = offices.filter { office in
            office.aliases.contains { Self.matches(printed, $0) }
        }
        if claiming.count == 1 { return claiming.first }
        if claiming.count > 1 { return nil }

        // A postcode is unambiguous when it appears, so it goes first — but
        // only when one office claims it. `first(where:)` here was the single
        // rule in this file that would pick among several, and the app's own
        // model invites the case it picked wrongly in: two offices in one
        // building ("Coleman, London" and "Coleman Annexe") share a postcode,
        // and whichever the fetch happened to return first won.
        //
        // Several claims fall through to the name rule rather than returning
        // nil, because that rule can still tell them apart — "Coleman Annexe,
        // EC2V 7NQ" names the annexe — and where it cannot it refuses on its
        // own terms. Returning here would have thrown away a correct answer to
        // avoid a wrong one.
        let byPostcode = offices.filter {
            !$0.postcode.isEmpty && printed.localizedCaseInsensitiveContains($0.postcode)
        }
        if byPostcode.count == 1 { return byPostcode.first }

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

    /// Whether two printed names are the same name.
    ///
    /// Compared as token sets rather than as strings, because the same building
    /// is printed with a floor in front of it on some rows and not on others —
    /// "03, Coleman, London" and "Coleman, London" are one answer, and an alias
    /// that had to be taught twice would not feel taught at all.
    /// Some real names tokenise to nothing at all: `tokens("Level 5")`,
    /// `tokens("The Building")` and `tokens("Office")` are all empty, because
    /// every word in them is either noise or a number. The old rule answered
    /// false for those against *any* alias, including a byte-identical one — so
    /// an office column printed `Level 5` could never be recognised however
    /// often it was taught, `CaptureCoordinator.remember` appended the alias
    /// again on every capture, and the sheet asked the same question forever
    /// off an ever-growing list. When there is nothing to compare as tokens,
    /// compare the names as names.
    static func matches(_ printed: String, _ alias: String) -> Bool {
        let printedTokens = tokens(printed), aliasTokens = tokens(alias)
        guard !printedTokens.isEmpty, !aliasTokens.isEmpty else {
            return printed.trimmingCharacters(in: .whitespacesAndNewlines).compare(
                alias.trimmingCharacters(in: .whitespacesAndNewlines),
                options: [.caseInsensitive, .diacriticInsensitive]
            ) == .orderedSame
        }
        return printedTokens == aliasTokens
    }

    /// Lower-cased words, punctuation dropped, accents folded, and the noise
    /// words a booking system pads a building name with removed.
    ///
    /// Folded because an office typed as "Zurich" and printed as "Zürich" is
    /// one building, and a diacritic is not a reason to ask a question.
    private static func tokens(_ text: String) -> Set<String> {
        let noise: Set<String> = ["the", "office", "building", "floor", "level"]
        return Set(
            text.folding(options: .diacriticInsensitive, locale: nil)
                .lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count > 1 && !noise.contains($0) && Int($0) == nil }
        )
    }
}
