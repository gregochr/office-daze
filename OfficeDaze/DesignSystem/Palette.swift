import SwiftUI

/// The design has no theme. It should look like a well-built system app,
/// because that is the point — so these are the system's own greys, named, plus
/// the four places colour is allowed to appear.
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
    /// Gauge ticks.
    static let tick = Color(hex: 0xD1D1D6)

    /// The dial, and the whole of it: one hue plus greys, and no judgement in
    /// any of them. Solid is counted, tint is promised, empty is owed, hatched
    /// is not owed. A second colour here puts back the problem the bands had —
    /// four things said in colour by three different rules on one card.
    static let gaugeAttended = tint
    static let gaugeBooked = Color(hex: 0xC2DEDB)
    static let gaugeGap = Color(hex: 0xEFEFF4)
    static let gaugeOff = Color(hex: 0xEDEDF2)
    static let gaugeHatch = Color(hex: 0xCFCFD6)

    /// The destructive swipe, which is iOS's own convention and not a judgement
    /// about the month. Nothing on the gauge is this colour.
    static let behind = Color(hex: 0xE5484D)
    static let close = Color(hex: 0xF5A623)
    static let met = Color(hex: 0x2FA36B)

    static let warningSurface = Color(hex: 0xFFF8E8)
    static let warningText = Color(hex: 0x8A5A00)
    static let warningSecondary = Color(hex: 0xA98033)

    static let successSurface = Color(hex: 0xEAF7F0)
    static let successText = Color(hex: 0x1B6B47)

    /// The one red in the app, and it means the target cannot be reached this
    /// month — not that you are behind. It shows up perhaps twice a year, and
    /// when it does it is a fact rather than a mood.
    static let dangerSurface = Color(hex: 0xFDECEC)
    static let dangerText = Color(hex: 0xA32126)

    /// On track: everything needed is booked and none of it worked yet. Not
    /// green, which would claim the month is done when it is only arranged.
    static let neutralSurface = Color(hex: 0xEFEFF4)
    static let neutralText = Color(hex: 0x3A3A3C)
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
