import Foundation

/// The six office colours, and the rule that no two offices share one.
///
/// Colour is the only thing that varies between offices, so it has to be
/// unambiguous: the dot beside a booking is how you tell London from Brussels
/// at a glance, and two offices in the same teal would make the dot decorative
/// rather than informative.
nonisolated enum OfficeColours {

    /// Fixed and ordered. Assigned on creation, in order, skipping any already
    /// taken — so the first office is always teal and the second always indigo.
    static let palette: [String] = [
        "#0A7A6E", "#5856D6", "#D2691E", "#8E44AD", "#2FA36B", "#C0392B",
    ]

    /// The next free colour, or nil once all six are spoken for. Nil rather
    /// than wrapping round: a seventh office would silently twin an existing
    /// one, and the caller should have to decide what to do about that.
    static func next(after taken: [String]) -> String? {
        let used = Set(taken.map { $0.uppercased() })
        return palette.first { !used.contains($0.uppercased()) }
    }
}
