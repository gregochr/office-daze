import Foundation

/// The design shows short forms in lists and full names on detail screens —
/// `DURHAM → KGX` on a card, `DURHAM` and `KING'S CROSS` on the ticket;
/// `ROPEMAKER PL` on a card, `ROPEMAKER PLACE` on the desk screen.
///
/// A captured booking may carry a station code already, in which case that
/// wins. This table is the fallback, and the fallback of the fallback is the
/// name itself — never a truncation that could read as a different station.
nonisolated enum Abbreviate {

    static let stationCodes: [String: String] = [
        "king's cross": "KGX",
        "london king's cross": "KGX",
        "st pancras": "STP",
        "st pancras international": "STP",
        "london st pancras": "STP",
        "brussels midi": "MIDI",
        "bruxelles-midi": "MIDI",
        "brussels-midi": "MIDI",
        "paris nord": "PNO",
        "gare du nord": "PNO",
    ]

    /// `code` is whatever the booking source supplied; it always wins.
    static func station(_ name: String, code: String? = nil) -> String {
        if let code, !code.isEmpty { return code.uppercased() }
        if let known = stationCodes[name.lowercased()] { return known }
        return name.uppercased()
    }

    /// `L3` → `LEVEL 3`. Floors arrive already prefixed as often as not, and
    /// `LEVEL L3` reads as a typo.
    static func level(_ floor: String) -> String {
        let trimmed = floor.trimmingCharacters(in: .whitespaces).uppercased()
        let stripped = trimmed.hasPrefix("L") && trimmed.dropFirst().allSatisfy(\.isNumber)
            ? String(trimmed.dropFirst())
            : trimmed
        // A floor that is already a word ("MEZZANINE", "GROUND") stands alone.
        return stripped.allSatisfy(\.isNumber) ? "LEVEL \(stripped)" : stripped
    }

    /// `L3` → `3`. The bare figure, for the Live Activity's `L / Z` cell, where
    /// the label already says which is which and `L3 / C` reads as a stutter.
    static func floorFigure(_ floor: String) -> String {
        let trimmed = floor.trimmingCharacters(in: .whitespaces).uppercased()
        return trimmed.hasPrefix("L") && trimmed.dropFirst().allSatisfy(\.isNumber)
            ? String(trimmed.dropFirst())
            : trimmed
    }

    private static let placeSuffixes: [String: String] = [
        "PLACE": "PL", "STREET": "ST", "ROAD": "RD", "AVENUE": "AVE",
        "SQUARE": "SQ", "BUILDING": "BLDG", "HOUSE": "HSE", "COURT": "CT",
    ]

    /// `Ropemaker Place` → `ROPEMAKER PL`. Only the trailing word is
    /// abbreviated, so `Place Farm Road` doesn't lose its first word.
    static func place(_ name: String) -> String {
        var words = name.uppercased().split(separator: " ").map(String.init)
        guard let last = words.last, let short = placeSuffixes[last] else {
            return name.uppercased()
        }
        words[words.count - 1] = short
        return words.joined(separator: " ")
    }
}
