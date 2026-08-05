import ActivityKit
import Foundation

/// Screen 5d — the Live Activity's payload.
///
/// Compiled into both the app and the widget extension. The app starts and ends
/// the activity; the extension renders it. Nothing is shared between them at
/// runtime except this struct, which ActivityKit itself carries across — no App
/// Group, and so nothing here needs a paid entitlement.
///
/// `ActivityAttributes` splits into two halves and the split matters:
/// `ContentState` is the part that may change while the activity is live, and
/// everything outside it is fixed for the activity's lifetime. The building
/// cannot change once you have arrived at it; the day count can, if the desk
/// screen's confirmation lands after the alert.
nonisolated struct DeskActivityAttributes: ActivityAttributes {

    nonisolated struct ContentState: Codable, Hashable, Sendable {
        var deskID: String
        var floor: String?
        var zone: String?
        /// Already formatted — `17:00`. Formatting happens app-side so the one
        /// `TimeDisplay` implementation stays the only one.
        var heldUntil: String?
        var dayNumber: Int
        var target: Int

        /// `3 / C`, or as much of it as was read. Never a guess: a floor the
        /// capture could not read is absent here rather than filled in.
        var floorZone: String? {
            let parts = [floor.map(Abbreviate.floorFigure), zone?.uppercased()]
                .compactMap { $0 }
            return parts.isEmpty ? nil : parts.joined(separator: " / ")
        }

        /// `DAY 03/07`.
        var dayCount: String {
            String(format: "DAY %02d/%02d", dayNumber, target)
        }
    }

    /// `ROPEMAKER PLACE`.
    var placeName: String
    /// The day the activity belongs to, as `Day.description`. Carried so a
    /// stale activity left over from yesterday is identifiable.
    var day: String
}
