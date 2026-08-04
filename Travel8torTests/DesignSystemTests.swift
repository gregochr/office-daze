import Foundation
import SwiftUI
import Testing
import UIKit
@testable import Travel8tor

@Suite("Design system")
struct DesignSystemTests {

    /// Bundling a font is three things that can each fail silently: the file has
    /// to be copied into the bundle, listed in UIAppFonts, and referred to by
    /// its PostScript name. If any is wrong, iOS falls back to the system font
    /// and nothing complains — the app just stops looking like the design.
    @Test("Space Mono is registered under the names the code uses")
    @MainActor
    func fontsAreRegistered() {
        #expect(UIFont(name: T8Fonts.regular, size: 12) != nil, "regular not registered")
        #expect(UIFont(name: T8Fonts.bold, size: 12) != nil, "bold not registered")

        let registered = UIFont.fontNames(forFamilyName: T8Fonts.family)
        #expect(registered.contains(T8Fonts.regular))
        #expect(registered.contains(T8Fonts.bold))
    }

    /// `Bundle.main` under a unit-test bundle with a TEST_HOST is the host app,
    /// which is exactly the bundle the fonts have to be copied into.
    @Test("The font files are actually in the app bundle")
    func fontFilesArePresent() {
        for name in ["SpaceMono-Regular", "SpaceMono-Bold"] {
            #expect(
                Bundle.main.url(forResource: name, withExtension: "ttf") != nil,
                "\(name).ttf is not in the app bundle"
            )
        }
    }

    @Test("Tracking converts from em to points against the font size")
    func trackingConversion() {
        // 0.22em at 9pt is 1.98pt. Getting this wrong is invisible in code
        // review and obvious on screen.
        #expect(T8Font.kicker.tracking == 9 * 0.22)
        #expect(T8Font.rowFigure.tracking == 0)
        #expect(T8Font.displayFigure.tracking == 30 * -0.01)
    }

    @Test("Emphasis maps to the documented opacities")
    func emphasisLevels() {
        #expect(Emphasis.full.rawValue == 1.0)
        #expect(Emphasis.pending.rawValue == 0.5)
        #expect(Emphasis.inactive.rawValue == 0.3)
    }

    @Test("Every booking kind has its own colour")
    func typeColours() {
        let colours = BookingKind.allCases.map { Palette.colour(for: $0) }
        #expect(Set(colours.map { String(describing: $0) }).count == BookingKind.allCases.count)
    }

    @Test("Every Terminator label has a plain-English pair")
    func copyPairs() {
        for label in T8Label.allCases {
            #expect(!label.terminator.isEmpty)
            #expect(!label.plain.isEmpty)
            #expect(label.terminator != label.plain, "\(label) has no real alternative")
        }
        #expect(Copy.resolve(.leftAlive, terminator: true) == "LEFT ALIVE")
        #expect(Copy.resolve(.leftAlive, terminator: false) == "STILL TO BOOK")
    }

    @Test("Corner ticks stay inside the panel bounds")
    func ticksAreInset() {
        let rect = CGRect(x: 0, y: 0, width: 200, height: 100)
        let bounds = CornerTicks().path(in: rect).boundingRect
        // Stroked at 2pt about a path inset by 1pt, the ink lands exactly on
        // the panel edge and never outside it.
        #expect(bounds.minX >= rect.minX + Metrics.tickWeight / 2 - 0.001)
        #expect(bounds.minY >= rect.minY + Metrics.tickWeight / 2 - 0.001)
        #expect(bounds.maxX <= rect.maxX - Metrics.tickWeight / 2 + 0.001)
        #expect(bounds.maxY <= rect.maxY - Metrics.tickWeight / 2 + 0.001)
    }

    @Test("There are eight tick marks, one pair per corner")
    func tickCount() {
        var segments = 0
        CornerTicks().path(in: CGRect(x: 0, y: 0, width: 100, height: 100))
            .forEach { element in
                if case .line = element { segments += 1 }
            }
        #expect(segments == 8)
    }
}

@Suite("Time zone display")
struct TimeDisplayTests {
    let london = TimeZone(identifier: "Europe/London")!
    let brussels = TimeZone(identifier: "Europe/Brussels")!

    @Test("A UK event renders bare")
    func ukIsBare() {
        let departure = Day(2026, 9, 7).at(17, 4, in: london)
        #expect(TimeDisplay.local(departure, in: london) == "17:04")
        #expect(TimeDisplay.ukEquivalent(departure, in: london) == nil)
        #expect(TimeDisplay.inline(departure, in: london) == "17:04")
    }

    @Test("A foreign event never renders bare")
    func foreignAlwaysCarriesUK() {
        let arrival = Day(2026, 9, 7).at(20, 5, in: brussels)
        #expect(TimeDisplay.local(arrival, in: brussels) == "20:05")
        #expect(TimeDisplay.ukEquivalent(arrival, in: brussels) == "19:05 UK")
        #expect(TimeDisplay.inline(arrival, in: brussels) == "20:05 (19:05 UK)")

        let (time, uk) = TimeDisplay.stacked(arrival, in: brussels)
        #expect(time == "20:05")
        #expect(uk == "19:05 UK")
    }

    @Test("The local time leads and the UK time follows, never the reverse")
    func neverInverted() {
        // The Thursday return: 17:52 Brussels, 16:52 UK. The design shows
        // 17:52 with 16:52 UK beneath — the departure is in Brussels, so
        // Brussels time is the headline.
        let departure = Day(2026, 9, 10).at(17, 52, in: brussels)
        let inline = TimeDisplay.inline(departure, in: brussels)
        #expect(inline.hasPrefix("17:52"))
        #expect(inline.contains("16:52 UK"))
        #expect(!inline.hasPrefix("16:52"))
    }

    @Test("Journey duration matches the ticket screen")
    func duration() {
        let departure = Day(2026, 9, 7).at(17, 4, in: london)
        let arrival = Day(2026, 9, 7).at(20, 5, in: brussels)
        #expect(TimeDisplay.duration(from: departure, to: arrival) == "2h01")

        let durham = Day(2026, 8, 5).at(6, 40, in: london)
        let kgx = Day(2026, 8, 5).at(9, 33, in: london)
        #expect(TimeDisplay.duration(from: durham, to: kgx) == "2h53")
    }

    @Test("Spans and stamps format as the design shows them")
    func stamps() {
        #expect(TimeDisplay.span(Day(2026, 9, 7), Day(2026, 9, 11)) == "07–11.09")
        #expect(TimeDisplay.dayStamp(Day(2026, 8, 5)) == "WED 05.08")
        #expect(Day(2026, 9, 7).weekdayAbbreviation == "MON")
        #expect(Month(year: 2026, month: 8).name == "AUGUST")
        #expect(Month(year: 2026, month: 8).shortName == "AUG 26")
    }
}

@Suite("Gauge arithmetic")
struct GaugeRingTests {

    @Test("Arcs are fractions of the target, and the centre is their sum")
    func fractions() {
        // The mock: 2 attended, 2 forecast, target 7. Its dasharray of
        // "71.8 251" against a 251.3 circumference is 2/7.
        let gauge = GaugeRing(attended: 2, forecast: 2, target: 7)
        #expect(abs(gauge.attendedFraction - 2.0 / 7.0) < 0.0001)
        #expect(abs(gauge.forecastFraction - 2.0 / 7.0) < 0.0001)
        #expect(gauge.centreFigure == "04")
    }

    @Test("Arcs never overrun the ring")
    func clamping() {
        // Twelve attended against a target of 7 fills the ring and leaves no
        // room for forecast, rather than wrapping round a second time.
        let over = GaugeRing(attended: 12, forecast: 3, target: 7)
        #expect(over.attendedFraction == 1)
        #expect(over.forecastFraction == 0)

        let mixed = GaugeRing(attended: 6, forecast: 4, target: 7)
        #expect(mixed.attendedFraction + mixed.forecastFraction == 1)
    }

    @Test("A target of zero draws nothing rather than dividing by zero")
    func zeroTarget() {
        let gauge = GaugeRing(attended: 0, forecast: 0, target: 0)
        #expect(gauge.attendedFraction == 0)
        #expect(gauge.forecastFraction == 0)
        #expect(gauge.centreFigure == "00")
    }

    @Test("Half-days round to the nearest whole in the centre figure")
    func halfDays() {
        #expect(GaugeRing(attended: 1.5, forecast: 1, target: 7).centreFigure == "03")
    }
}
