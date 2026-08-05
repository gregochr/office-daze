import ActivityKit
import Foundation

/// Starts, updates and ends the Live Activity. App side only — the widget
/// extension draws and does nothing else.
///
/// Everything here is local. `Activity.request` with `pushType: nil` needs no
/// APNs token, no `aps-environment` entitlement and no paid membership; the
/// only declaration involved is `NSSupportsLiveActivities` in Info.plist, which
/// is a plist key rather than a capability.
///
/// The design's "DISCHARGED 09:12. SILENT SINCE." line is not rendered. It sits
/// outside the panel in the mock, on the lock screen proper — a description of
/// what the system is doing with a dismissed alert, not something an app can
/// draw. The behaviour it describes is real; the caption isn't ours to print.
@MainActor
enum DeskActivityController {

    /// Whether the system will accept an activity at all. False when the user
    /// has switched Live Activities off for Travel8tor in Settings — which is a
    /// silent no-op unless something checks.
    static var available: Bool {
        ActivityAuthorizationInfo().areActivitiesEnabled
    }

    /// Screen 5d. Started once, on the arrival that also posts the alert, and
    /// left alone until the desk booking's end time.
    ///
    /// `staleDate` is what makes it go quiet rather than linger: past it the
    /// system dims the activity, and `dismissalPolicy: .after` removes it. No
    /// timer of ours, and nothing to survive being killed.
    @discardableResult
    static func start(
        placeName: String,
        day: Day,
        deskID: String,
        floor: String?,
        zone: String?,
        heldUntil: String?,
        dayNumber: Int,
        target: Int,
        endsAt: Date?
    ) -> Bool {
        guard available else { return false }

        // One at a time. A second entry on the same day would otherwise stack
        // two identical panels on the lock screen.
        guard Activity<DeskActivityAttributes>.activities.isEmpty else { return false }

        let attributes = DeskActivityAttributes(
            placeName: placeName, day: day.description
        )
        let state = DeskActivityAttributes.ContentState(
            deskID: deskID, floor: floor, zone: zone,
            heldUntil: heldUntil, dayNumber: dayNumber, target: target
        )

        do {
            _ = try Activity.request(
                attributes: attributes,
                content: ActivityContent(state: state, staleDate: endsAt),
                pushType: nil
            )
            return true
        } catch {
            // A refusal is not an error worth surfacing: the notification has
            // already been delivered and carries the same information.
            return false
        }
    }

    /// Raises the day count on a live activity — the confirmation that follows
    /// the alert moves the figure the panel is showing.
    static func recount(dayNumber: Int, target: Int) async {
        for activity in Activity<DeskActivityAttributes>.activities {
            var state = activity.content.state
            state.dayNumber = dayNumber
            state.target = target
            await activity.update(
                ActivityContent(state: state, staleDate: activity.content.staleDate)
            )
        }
    }

    /// Ends anything left over from another day. Called at launch so an
    /// activity the app was killed before it could retire — its stale date
    /// having passed while nothing was running — does not outlive the booking
    /// it describes.
    static func endAll(olderThan day: Day = .today) async {
        for activity in Activity<DeskActivityAttributes>.activities
        where activity.attributes.day != day.description {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    /// Ends every activity, today's included. For the erase: a panel on the
    /// lock screen naming a desk in a building that has just been deleted is
    /// the app contradicting itself.
    static func endEverything() async {
        for activity in Activity<DeskActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }
}
