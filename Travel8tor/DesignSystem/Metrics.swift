import CoreGraphics

/// Spacing, borders and sizes, from the design brief's geometry section.
///
/// The single most important value here is the one that isn't: there is no
/// corner radius. Every panel, button, chip and toggle is a hard rectangle,
/// and that is load-bearing for the theme rather than an oversight.
nonisolated enum Metrics {

    // Screen
    static let screenPadding: CGFloat = 16
    static let headerPadding: CGFloat = 18
    /// The header sits below the status bar rather than in a nav bar.
    static let headerTopInset: CGFloat = 56

    // Borders
    static let hairline: CGFloat = 1
    /// Panel emphasis border.
    static let border: CGFloat = 2
    /// The leading type-edge on a booking card.
    static let typeEdge: CGFloat = 3

    // Corner ticks
    static let tickLength: CGFloat = 12
    static let tickWeight: CGFloat = 2

    // Cards
    static let cardPaddingV: CGFloat = 11
    static let cardPaddingH: CGFloat = 12
    /// Gap between stacked cards in one day group.
    static let cardGap: CGFloat = 7
    /// Gap between day groups.
    static let dayGroupGap: CGFloat = 9
    /// Space between the metadata items on a card.
    static let metaGap: CGFloat = 14

    // Day gutter
    static let gutterWidth: CGFloat = 32
    /// Narrowed a step inside a nested child trip.
    static let gutterWidthNested: CGFloat = 26
    static let gutterGap: CGFloat = 11

    // Panels
    static let panelPaddingTop: CGFloat = 18
    static let panelPaddingH: CGFloat = 16
    static let panelPaddingBottom: CGFloat = 16

    // Gauge
    static let ringSize: CGFloat = 96
    static let ringStroke: CGFloat = 4
    static let ringRadius: CGFloat = 40
    static let ringInnerRadius: CGFloat = 34

    // Nested trip block
    static let nestedInset: CGFloat = 8
    static let nestedPadding: CGFloat = 12

    // Scanline
    static let scanlinePeriod: CGFloat = 3
    static let scanlineThickness: CGFloat = 1
}
