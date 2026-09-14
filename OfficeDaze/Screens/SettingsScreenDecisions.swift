import CoreLocation
import SwiftData
import SwiftUI

// MARK: - What the screen decides

/// Every claim `SettingsScreen` makes, worked out where it can be tested.
///
/// Separate from `SettingsScreen.swift` only because the two halves are read for
/// different reasons and had grown past being one sitting between them. The
/// other file is the layout — which section holds what, in what order. This one
/// is the reasoning: whether the key is stored, whether the alert will fire,
/// what a delete would take, what this month's reading cost. Splitting on that
/// line rather than at some midpoint keeps each file answering one question,
/// and it is the same line the screen's doc comment already draws — a claim
/// made inside a `View` cannot be tested, which is why none of this is in one.
///
/// Nothing here is private to the layout, so nothing had to change to move: the
/// statics were already `static` for the testing reason, and `SettingsScreenTests`
/// calls them by the same names it always did.
extension SettingsScreen {

    // MARK: What this month read

    /// How many images were read this month, whatever became of them.
    ///
    /// `receivedAt` is a real instant, not a day written through the storage
    /// codec, so it is read back with `Day(localOf:)`. Through `Day(of:)` a
    /// capture taken at 00:30 on the 1st anywhere east of Greenwich was still
    /// the previous month in UTC, and this month's count silently omitted it.
    ///
    /// Every capture counts: a reading that found nothing was still a reading,
    /// and a count that hid the failures would hide exactly the ones worth
    /// knowing about.
    static func reads(
        of captures: [Capture], in month: Month, zone: TimeZone = .autoupdatingCurrent
    ) -> Int {
        captures.count { month.contains(Day(localOf: $0.receivedAt, in: zone)) }
    }

    // MARK: Leave

    /// The row opens on this month, so this is the month it counts. Bank
    /// holidays are excluded for the reason they are everywhere else: they are
    /// derived from the calendar rather than booked, and they are already
    /// outside the working days the target is built from.
    static func leaveSummary(_ leave: [LeaveDay], in month: Month) -> String {
        let days = leave
            .filter { $0.kind != .bankHoliday && month.contains($0.day) }
            .reduce(0) { $0 + $1.fraction }
        guard days > 0 else { return "None this month" }
        let count = days.formatted(.number.precision(.fractionLength(0...1)))
        return "\(count) \(days == 1 ? "day" : "days") this month"
    }

    // MARK: Deleting

    /// The destructive button names what it would take, because the two scopes
    /// are not the same size of loss and the offices are the half that cannot
    /// be captured again.
    static func everythingTitle(officeCount: Int) -> String {
        guard officeCount > 0 else { return "Everything" }
        return "Everything, including \(officeCount) \(officeCount == 1 ? "office" : "offices")"
    }

    /// What a delete did: the reason, if it did not land.
    ///
    /// Said out loud, which is the half that used to be thrown away.
    struct Wiped: Equatable {
        /// Non-nil only for a delete that did not land. Nil is the ordinary
        /// case, and it is silent on purpose: a delete that works is confirmed
        /// by the emptied screen behind it, and an alert saying so would be one
        /// more tap on the way out of a destructive flow.
        var failure: String?
    }

    /// Deletes, then puts back in step everything that was computed from the
    /// records that no longer exist — and answers with the reason when the
    /// records turn out to still exist.
    ///
    /// The regions are why the reconciliation matters: iOS goes on monitoring
    /// a perimeter for a deleted office until something tells it not to.
    ///
    /// `erase` is a parameter for the reason `record`'s two store calls are:
    /// the branch that had never been taken is the one where the delete throws,
    /// and SwiftData will not throw on request. The default is the real thing.
    @discardableResult
    static func wipe(
        _ scope: Store.Scope,
        in context: ModelContext,
        arrival: ArrivalMonitor,
        defaults: UserDefaults = .standard,
        refreshNudge: (ModelContext) -> Void = { NudgeScheduler.refresh(in: $0) },
        erase: (Store.Scope, ModelContext, UserDefaults) throws -> Void
            = { try Store.wipe($1, scope: $0, defaults: $2) }
    ) -> Wiped {
        var failure: String?
        do {
            try erase(scope, context, defaults)
        } catch {
            failure = deleteFailure(scope, error)
        }
        // Both of these still run when the delete threw, and that is the
        // deliberate answer rather than the incidental one. Neither is a
        // celebration of a delete that happened; both are reconciliations, and
        // what they reconcile against is whatever the store now holds. A throw
        // says the delete did not finish, not that it did not start — so the
        // records that did go are gone, and skipping these two would leave iOS
        // waking the app at a deleted office's perimeter and tonight's reminder
        // naming a desk that no longer exists, with nothing left on any later
        // screen to trigger a rebuild. Running them against a store that was
        // not emptied costs nothing: they re-register the offices that are
        // still there and re-decide the reminder from the bookings that are
        // still there, which is exactly right for a store in that state.
        arrival.refreshRegions()
        refreshNudge(context)
        return Wiped(failure: failure)
    }

    /// Why the delete is being reported rather than assumed, in terms of what
    /// the user still has.
    ///
    /// It refuses to say "nothing was deleted" even though on today's
    /// `Store.wipe` a throw does leave the store untouched — the deletes are
    /// staged model by model and only the save commits them. That is one
    /// autosave away from being false, and the direction to be wrong in is the
    /// one that has the user check rather than the one that has them trust.
    /// Named by scope, because the two deletes take different things.
    static func deleteFailure(_ scope: Store.Scope, _ error: Error) -> String {
        let kept = scope == .everything
            ? "Some of your data, and your offices, are still here."
            : "Some of your bookings, attendance and leave are still here."
        return "The delete didn't finish: \(error.localizedDescription). \(kept) Nothing is safely gone — try again."
    }

    // MARK: Permission

    /// Every condition the alert actually depends on. The ladder itself lives in
    /// `AlertReadiness`, where it can be tested; a `View` cannot be. This is the
    /// wiring — which office's fields, and which of the monitor's two
    /// permissions go where — and getting *that* wrong prints a green line just
    /// as readily as the ladder did.
    ///
    /// The last argument is the one that stopped this row answering from
    /// intent. Everything else here is a setting the user chose; `isWatched` is
    /// the only thing asked of CoreLocation, and it is what makes the missing
    /// `refreshRegions` call visible. Without it the row read the toggle and
    /// the two permissions, all three of which were perfectly true while no
    /// perimeter had been registered at all — so the office the user had just
    /// added, or just moved, said "Alert on · 50m" for days.
    static func readiness(_ office: Office, arrival: ArrivalMonitor) -> AlertReadiness {
        .of(
            alertEnabled: office.alertEnabled,
            canMonitor: arrival.canMonitor,
            notificationsAllowed: arrival.notificationsAllowed,
            isLocated: office.isLocated,
            radiusMetres: office.radiusMetres,
            isWatched: arrival.monitoredOfficeIDs.contains(office.id)
        )
    }

    /// A refusal and an unanswered prompt are different situations with
    /// different remedies, and only one of them can be fixed from inside the
    /// app — so they do not get the same sentence.
    static func permissionText(_ status: CLAuthorizationStatus) -> String {
        opensSettings(status)
            ? "Location access is off — the arrival alert can't fire"
            : "The arrival alert needs \"Always\" location access"
    }

    static func grantTitle(_ status: CLAuthorizationStatus) -> String {
        switch status {
        case .denied, .restricted: "Open Settings"
        case .authorizedWhenInUse: "Allow Always"
        default: "Allow"
        }
    }

    /// Whether the button has to leave the app. iOS will not raise a prompt
    /// that has already been refused, so a button that called
    /// `requestAuthorization` here would do nothing at all, for ever, with no
    /// way for the user to tell that from the permission simply not working.
    static func opensSettings(_ status: CLAuthorizationStatus) -> Bool {
        status == .denied || status == .restricted
    }
}
