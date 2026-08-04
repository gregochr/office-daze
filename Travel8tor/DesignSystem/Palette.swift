import SwiftUI

/// The six colours, and the derived values expressed as opacity on them.
///
/// Two rules from the design brief that the API here tries to make hard to
/// break:
///
///   Booking *type* is what colour encodes — rail red, desk amber, stay cyan.
///   *Status* is carried by brightness, not hue: confirmed at full strength,
///   pending at roughly 0.5, inactive at 0.3. So there is no `.pendingColour`;
///   there is `Palette.rail.status(.pending)`.
nonisolated enum Palette {

    // MARK: Base

    /// Screen background.
    static let ground = Color(hex: 0x080605)
    /// Sheets and elevated panels.
    static let groundRaised = Color(hex: 0x0C0908)
    /// Rail bookings, primary chrome, rules and borders.
    static let rail = Color(hex: 0xFF3B24)
    /// Desk bookings, warnings, the progress gauge.
    static let desk = Color(hex: 0xFFB020)
    /// Hotel stays, informational states.
    static let stay = Color(hex: 0x45C2D4)
    /// Primary data and readouts.
    static let bone = Color(hex: 0xEDE4E0)

    // MARK: Derived — bone

    /// Secondary text.
    static let boneSecondary = bone.opacity(0.45)
    /// Metadata rows inside cards.
    static let boneMeta = bone.opacity(0.5)
    /// Tertiary, disabled, and the day-gutter weekday.
    static let boneTertiary = bone.opacity(0.35)

    // MARK: Derived — rail chrome

    /// The rule beneath the header.
    static let railRule = rail.opacity(0.28)
    /// Standard panel border.
    static let railBorder = rail.opacity(0.3)
    /// Trip-card border, a step quieter.
    static let railBorderQuiet = rail.opacity(0.26)
    /// Emphasis border — the footer strip, the arrival panel.
    static let railBorderStrong = rail.opacity(0.4)
    /// Panel fill behind an emphasis border.
    static let railFill = rail.opacity(0.09)
    /// The nested-leg note's fill.
    static let railFillQuiet = rail.opacity(0.07)
    /// The child-trip block's fill in trip detail.
    static let railFillFaint = rail.opacity(0.045)
    /// Gauge ring track.
    static let railTrack = rail.opacity(0.16)
    /// The decorative dashed inner circle.
    static let railDashed = rail.opacity(0.22)
    /// Section kickers over a panel.
    static let railKicker = rail.opacity(0.75)
    /// Back-navigation label.
    static let railBack = rail.opacity(0.75)
    /// Bracket glyphs around a hero figure.
    static let railBracket = rail.opacity(0.6)

    // MARK: Type colours

    static func colour(for kind: BookingKind) -> Color {
        switch kind {
        case .rail: rail
        case .desk: desk
        case .stay: stay
        }
    }
}

/// Brightness carries status. A booking that is confirmed reads at full
/// strength; one still pending reads at half; an inactive one at 0.3.
nonisolated enum Emphasis: Double {
    case full = 1.0
    case pending = 0.5
    case inactive = 0.3
}

extension Color {
    /// `Palette.desk.status(.pending)` — the amber forecast arc, and the
    /// FORECAST figure beside it.
    nonisolated func status(_ emphasis: Emphasis) -> Color {
        opacity(emphasis.rawValue)
    }

    /// 0xRRGGBB. SwiftUI has no hex initialiser, and the design is specified in
    /// hex, so translating by hand at each call site would be a place for typos
    /// to hide.
    nonisolated init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}
