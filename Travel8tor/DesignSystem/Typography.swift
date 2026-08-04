import SwiftUI

/// Space Mono throughout, at the sizes and tracking the design specifies.
///
/// CSS gives tracking in `em` — a fraction of the font size. SwiftUI's
/// `.tracking()` takes points. The conversion lives in one place here rather
/// than being done by hand at forty call sites.
nonisolated struct T8Font: Hashable, Sendable {
    let size: CGFloat
    let bold: Bool
    /// As authored in the design, in em.
    let trackingEm: CGFloat
    /// Line height as a multiple of size, where the design sets one.
    let lineHeightMultiple: CGFloat?

    init(_ size: CGFloat, bold: Bool = false, tracking: CGFloat = 0, lineHeight: CGFloat? = nil) {
        self.size = size
        self.bold = bold
        self.trackingEm = tracking
        self.lineHeightMultiple = lineHeight
    }

    var font: Font {
        .custom(bold ? T8Fonts.bold : T8Fonts.regular, size: size)
    }

    var tracking: CGFloat { trackingEm * size }
}

/// PostScript names, verified against the name table of the bundled files.
/// These are not the file names and not the family name — `Font.custom` wants
/// the PostScript name.
nonisolated enum T8Fonts {
    static let regular = "SpaceMono-Regular"
    static let bold = "SpaceMono-Bold"
    static let family = "Space Mono"
}

nonisolated extension T8Font {
    // Chrome
    /// `T8 ▪ ATTENDANCE PROTOCOL`
    static let appTitle = T8Font(10, bold: true, tracking: 0.20)
    /// `← RETURN`, `← TARGETS`
    static let back = T8Font(10, bold: true, tracking: 0.18)
    /// `▸ INBOUND`, `▸ SEPTEMBER`, `KILL COUNT ▪ AUGUST`
    static let kicker = T8Font(9, bold: true, tracking: 0.22)
    /// `03 LEFT ALIVE`
    static let panelLabel = T8Font(10, bold: true, tracking: 0.14)
    /// `18 DAYS TO RUN`
    static let panelNote = T8Font(10, tracking: 0.10)

    // Cards
    /// `[RAIL] LNER`, `[DESK] TERMINATES 1`
    static let typeCode = T8Font(9, bold: true, tracking: 0.16)
    /// `DURHAM → KGX`, `ROPEMAKER PL`
    static let rowTitle = T8Font(13, bold: true, tracking: 0.04)
    /// `06:40`, `3C-114`
    static let rowFigure = T8Font(15, bold: true)
    /// `PLAT 2`, `CCH B`, `SEAT 12`
    static let meta = T8Font(10, tracking: 0.08)
    /// Prose inside explanatory panels.
    static let body = T8Font(10, tracking: 0.06, lineHeight: 1.5)

    // Trip card
    /// `LONDON WEEK`
    static let tripTitle = T8Font(11, bold: true, tracking: 0.14)
    /// `07–11.09`
    static let tripSpan = T8Font(10)

    // Gauge readout
    /// `TERMINATED`, `FORECAST`, `TARGET`
    static let readoutLabel = T8Font(10, tracking: 0.12)
    static let readoutFigure = T8Font(14, bold: true)

    // Day gutter
    /// `WED`
    static let gutterWeekday = T8Font(9)
    /// `05`
    static let gutterDay = T8Font(18, bold: true, lineHeight: 1.15)

    // Figures
    /// The bracket glyphs around a hero figure.
    static let bracket = T8Font(22)
    static let bracketLarge = T8Font(28)
    /// The gauge centre, `04`.
    static let displayFigure = T8Font(30, bold: true, tracking: -0.01)
    /// The desk screen's hero id, `3C-114`.
    static let heroFigure = T8Font(42, bold: true, tracking: -0.01)
    /// The arrival alert's desk id.
    static let alertFigure = T8Font(46, bold: true, tracking: -0.01)
    /// The lock-screen clock.
    static let clock = T8Font(66, bold: true)
}

extension View {
    /// Applies size, weight and tracking together. Using `.font()` alone would
    /// silently drop the tracking, which is most of what makes the type read as
    /// instrumentation.
    nonisolated func t8(_ style: T8Font) -> some View {
        font(style.font).tracking(style.tracking)
    }

    /// Almost all interface text is upper case — place names, station names and
    /// desk ids included.
    nonisolated func t8Upper(_ style: T8Font) -> some View {
        t8(style).textCase(.uppercase)
    }
}
