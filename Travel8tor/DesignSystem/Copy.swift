import Foundation
import Observation

/// Every Terminator label is one of a matched pair, resolved through a single
/// boolean. The joke is the design; this is the escape hatch if it wears thin.
nonisolated enum T8Label: String, CaseIterable, Sendable {
    case targets, killCount, theMission, terminated, forecast, leftAlive
    case acquireTarget, targetAcquired, subRoute, dataIncomplete
    // Beyond the README's table, which is a sample rather than the full set —
    // these appear on cards and in the month grid and need pairs too.
    case counts, attendedTag, bookedTag, effectOnCount
    // Arrival, stage 5.
    case confirmArrival, logThisDay, arrivalTrigger

    var terminator: String {
        switch self {
        case .targets: "TARGETS"
        case .killCount: "KILL COUNT"
        case .theMission: "THE MISSION"
        case .terminated: "TERMINATED"
        case .forecast: "FORECAST"
        case .leftAlive: "LEFT ALIVE"
        case .acquireTarget: "ACQUIRE TARGET"
        case .targetAcquired: "TARGET ACQUIRED"
        case .subRoute: "SUB-ROUTE"
        case .dataIncomplete: "DATA INCOMPLETE"
        case .counts: "TERMINATES"
        case .attendedTag: "KILL"
        case .bookedTag: "PEND"
        case .effectOnCount: "EFFECT ON KILL COUNT"
        case .confirmArrival: "CLAIM THE KILL"
        case .logThisDay: "LOG THE DAY AND CLAIM THE KILL?"
        case .arrivalTrigger: "ARRIVAL TRIGGER"
        }
    }

    var plain: String {
        switch self {
        case .targets: "UPCOMING"
        case .killCount: "OFFICE DAYS"
        case .theMission: "MONTH"
        case .terminated: "ATTENDED"
        case .forecast: "BOOKED"
        case .leftAlive: "STILL TO BOOK"
        case .acquireTarget: "ADD BOOKING"
        case .targetAcquired: "YOU'VE ARRIVED"
        case .subRoute: "NESTED TRIP"
        case .dataIncomplete: "NEEDS CHECKING"
        case .counts: "COUNTS"
        case .attendedTag: "IN"
        case .bookedTag: "BOOKED"
        case .effectOnCount: "EFFECT ON OFFICE DAYS"
        case .confirmArrival: "LOG THIS DAY"
        case .logThisDay: "RECORD TODAY AS AN OFFICE DAY?"
        case .arrivalTrigger: "ARRIVAL ALERT"
        }
    }
}

/// `@Observable` is the modern replacement for `ObservableObject` + `@Published`.
/// The macro rewrites stored properties so SwiftUI can track *which* ones a
/// given view actually read, and re-render only those views — rather than every
/// view observing the object, which is what the old protocol did.
@Observable
final class Copy {
    static let shared = Copy()

    private static let defaultsKey = "heistCopy"

    var terminator: Bool {
        didSet { UserDefaults.standard.set(terminator, forKey: Self.defaultsKey) }
    }

    private init() {
        // `object(forKey:)` rather than `bool(forKey:)` because the latter
        // returns false for "never set", which would silently ship the app in
        // plain mode on first launch.
        terminator = UserDefaults.standard.object(forKey: Self.defaultsKey) as? Bool ?? true
    }

    /// `callAsFunction` lets the call site read `copy(.leftAlive)` rather than
    /// `copy.resolve(.leftAlive)`. Worth it for something used this often.
    func callAsFunction(_ label: T8Label) -> String {
        terminator ? label.terminator : label.plain
    }

    /// For tests and previews, which must not touch the shared instance.
    static func resolve(_ label: T8Label, terminator: Bool) -> String {
        terminator ? label.terminator : label.plain
    }
}
