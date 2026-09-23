import SwiftUI

/// The design has no theme. It should look like a well-built system app,
/// because that is the point — so these are the system's own greys, named, plus
/// the few places colour is allowed to appear.
///
/// Literal hex rather than semantic system colours (`.systemGroupedBackground`
/// and friends) because the handoff specifies exact values and the app is
/// light-only. If it ever grows a dark mode, this is the one file to change.
enum Palette {
    static let ground = Color(hex: 0xF2F2F7)
    static let card = Color.white
    static let hairline = Color(hex: 0xEFEFF4)
    static let text = Color(hex: 0x1C1C1E)
    static let secondary = Color(hex: 0x8E8E93)
    static let tertiary = Color(hex: 0xC7C7CC)
    /// Every interactive label.
    static let tint = Color(hex: 0x0A7A6E)

    /// The row label grey, a shade darker than `secondary`.
    static let rowLabel = Color(hex: 0x636366)

    /// The eight slots, and the whole of them: one hue plus greys, and no
    /// judgement in any of them. Solid is worked, tint is promised, grey is
    /// still to find, hatched is what leave took off. A status colour here puts
    /// back the problem the dial's bands had — "behind" said in colour by three
    /// different rules on one card.
    static let gaugeAttended = tint
    static let gaugeBooked = Color(hex: 0x9FCDC7)
    static let gaugeGap = Color(hex: 0xEBEBF0)
    static let gaugeOff = Color(hex: 0xEDEDF2)
    static let gaugeHatch = Color(hex: 0xD5D5DC)

    /// The verdict line under the slots, and nowhere else: the month card's one
    /// green and its one red. The red means the target cannot be reached this
    /// month — not that you are behind. It shows up perhaps twice a year, and
    /// when it does it is a fact rather than a mood.
    ///
    /// They replace `met`, `close` and `behind`, the dial's green, amber and
    /// red bands, and are named for the line they belong to because `met` had
    /// already been borrowed by screens that were not about the target.
    static let verdictMet = Color(hex: 0x1B6B47)
    static let verdictUnreachable = Color(hex: 0xA32126)

    /// The scan bar's top edge. A shade darker than `hairline`, because it is
    /// drawn over rows scrolling under it rather than between two of them.
    static let barHairline = Color(hex: 0xE4E4E9)

    /// Something done and holding: a day attended, a booking filed, an alert
    /// that will fire. The tint, named for what it means here — teal is the
    /// only accent in the app, and the green this replaced said the same thing
    /// as the attended slot in a second colour.
    static let settled = tint
    /// The ground under settled things — the success strip, an attended day in
    /// the leave calendar: the tint at 10% over white, so it reads as the same
    /// teal rather than as a new colour.
    static let settledSurface = Color(hex: 0xE6F2F0)

    static let warningSurface = Color(hex: 0xFFF8E8)
    static let warningText = Color(hex: 0x8A5A00)
    static let warningSecondary = Color(hex: 0xA98033)
}

extension Color {
    nonisolated init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }

    /// An office's stored `colourHex`, as `#0A7A6E`. Falls back to the tint
    /// rather than failing: a dot with no colour is worse than the wrong one,
    /// and the value only ever comes from our own fixed palette.
    nonisolated init(officeHex: String) {
        let digits = officeHex.hasPrefix("#") ? String(officeHex.dropFirst()) : officeHex
        guard let value = UInt32(digits, radix: 16), digits.count == 6 else {
            self.init(hex: 0x0A7A6E)  // the tint, spelled out so this stays nonisolated
            return
        }
        self.init(hex: value)
    }
}

/// Card radius 14, inner pills 10, buttons 12. Screen padding 16.
nonisolated enum Metrics {
    static let cardRadius: CGFloat = 14
    static let pillRadius: CGFloat = 10
    static let buttonRadius: CGFloat = 12
    static let screenPadding: CGFloat = 16
    static let cardGap: CGFloat = 14
    static let sectionGap: CGFloat = 22
    /// Every tappable row is at least this tall.
    static let minimumRow: CGFloat = 44
}
