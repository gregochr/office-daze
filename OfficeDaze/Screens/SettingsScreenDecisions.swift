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

    // MARK: The key

    /// The Keychain's side of the key field: what it holds, and whether the
    /// last write to it landed.
    ///
    /// Both halves are needed. `stored` alone cannot tell a refused write from
    /// a key that was never typed, and the user has to be told which of those
    /// two they are looking at — a silently refused write sends them to a
    /// capture that says "No API key yet. Add one in Settings", from a Settings
    /// screen that says the key is there.
    struct KeyState: Equatable {
        var stored: String?
        var writeFailed = false
    }

    /// The line under the key field.
    enum KeyRow: Equatable {
        case missing
        case notSaved
        case savedUnused
        case saved(lastUsed: Day)

        enum Tone: Equatable { case good, alarm, quiet }
    }

    /// Writes what was typed and reports what the Keychain holds afterwards.
    ///
    /// The read-back is the point. The row used to be derived from `apiKey` —
    /// the text field's own contents — so it turned green on the first
    /// character typed, before anything had been stored, and stayed green when
    /// the write failed outright. Asking the Keychain what it now holds is the
    /// only answer that is about the key rather than about the keyboard.
    ///
    /// Two ways to fail and both are reported: securityd refusing the write,
    /// and a write it accepted whose value did not come back. The second cannot
    /// be provoked from a test against the real Keychain, which is exactly why
    /// the check is here rather than assumed away.
    /// Whether a change in the field is a change worth storing.
    ///
    /// The field is not only typed into: `.task` fills it from the Keychain on
    /// open, and `wipe` empties it when the key has been deleted. Both arrive
    /// at `.onChange` indistinguishable from a keystroke, and both used to be
    /// written straight back — the first rewriting a key nobody had touched,
    /// the second clearing one that was already gone.
    ///
    /// Compared against what the Keychain last said it held rather than against
    /// the previous field value, because those differ in the case that matters:
    /// after a refused write the field holds the new key and the Keychain still
    /// holds the old one, so retyping the same characters has to be attempted
    /// again rather than dismissed as "no change".
    static func shouldWrite(typed: String, stored: String?) -> Bool {
        typed != stored ?? ""
    }

    static func write(
        _ typed: String,
        store: (String) -> Bool,
        readBack: () -> String?
    ) -> KeyState {
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        // An empty field is a revocation, and a revoked key reads back as
        // nothing — so nothing is the success case there, not a failure.
        let expected: String? = trimmed.isEmpty ? nil : trimmed
        let accepted = store(trimmed)
        let stored = readBack()
        return KeyState(stored: stored, writeFailed: !accepted || stored != expected)
    }

    /// The state to open on, and to return to after anything that could have
    /// changed the key behind the screen's back.
    static func reload(readBack: () -> String?) -> KeyState {
        KeyState(stored: readBack(), writeFailed: false)
    }

    /// `Key saved · last used 4 August`, or the reason capture is off.
    ///
    /// Last use comes from the captures themselves rather than from anything
    /// stored for the purpose — a parsed capture is proof the key worked, which
    /// is the fact worth reporting, and the token counters below already prove
    /// the plumbing exists.
    ///
    /// A failed write outranks a stored key, including a stored *older* key: the
    /// user's last action was to type a new one, and "Key saved" against a
    /// keystroke that did not save is the lie this row exists to stop telling.
    static func keyRow(
        _ state: KeyState, lastUsed: Date?, zone: TimeZone = .autoupdatingCurrent
    ) -> KeyRow {
        guard !state.writeFailed else { return .notSaved }
        guard let stored = state.stored,
              !stored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .missing
        }
        guard let lastUsed else { return .savedUnused }
        // Local, not UTC: this is a stored instant being shown to a person, and
        // "last used 4 August" for something they did at half past midnight on
        // the 5th is simply wrong to them.
        return .saved(lastUsed: Day(localOf: lastUsed, in: zone))
    }

    /// The most recent capture the model actually read. A pending one has not
    /// come back yet and a failed one is not proof of anything, least of all of
    /// a working key — a 401 is a failed capture.
    static func lastSuccessfulUse(in captures: [Capture]) -> Date? {
        captures.filter { $0.status == .parsed }.map(\.receivedAt).max()
    }

    // MARK: What this month's reading cost

    struct CaptureCost: Equatable {
        var read = 0
        var inputTokens = 0
        var outputTokens = 0
    }

    /// `receivedAt` is a real instant, not a day written through the storage
    /// codec, so it is read back with `Day(localOf:)`. Through `Day(of:)` a
    /// capture taken at 00:30 on the 1st anywhere east of Greenwich was still
    /// the previous month in UTC, and this month's count silently omitted it.
    ///
    /// Every capture counts, whatever became of it: a call that came back
    /// unparseable was still charged for, and a cost summary that hid the
    /// failures would understate the bill by exactly the calls the user would
    /// most want to know about.
    static func cost(
        of captures: [Capture], in month: Month, zone: TimeZone = .autoupdatingCurrent
    ) -> CaptureCost {
        captures
            .filter { month.contains(Day(localOf: $0.receivedAt, in: zone)) }
            .reduce(into: CaptureCost()) { cost, capture in
                cost.read += 1
                cost.inputTokens += capture.inputTokens
                cost.outputTokens += capture.outputTokens
            }
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

    /// What a delete did: the key row's new state, and the reason if it did not
    /// land.
    ///
    /// Both, rather than one or the other. The key row has to be re-read either
    /// way — a delete that worked took the Anthropic key with it, a delete that
    /// failed left it exactly where it was — and the failure has to be said out
    /// loud, which is the half that used to be thrown away.
    struct Wiped: Equatable {
        var key: KeyState
        /// Non-nil only for a delete that did not land. Nil is the ordinary
        /// case, and it is silent on purpose: a delete that works is confirmed
        /// by the emptied screen behind it, and an alert saying so would be one
        /// more tap on the way out of a destructive flow.
        var failure: String?
    }

    /// Deletes, then puts back in step everything that was computed from the
    /// records that no longer exist — and answers with the key row's new state,
    /// plus the reason when the records turn out to still exist.
    ///
    /// It answers rather than returning nothing because `.everything` takes the
    /// Anthropic key with it (see `Store.wipe`), and a screen that kept showing
    /// "Key saved · last used 4 August" over an empty Keychain would be making
    /// the same claim from state that this row was rewritten to stop making.
    /// The regions matter just as much: iOS goes on monitoring a perimeter for
    /// a deleted office until something tells it not to.
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
        // `@escaping` only because it is now handed on to `erase`, which is
        // itself a parameter — Swift will not let one non-escaping closure
        // parameter be passed to another. Nothing here stores it: it is called
        // once, synchronously, inside the delete it belongs to.
        forgetSecret: @escaping () -> Void,
        readKey: () -> String?,
        refreshNudge: (ModelContext) -> Void = { NudgeScheduler.refresh(in: $0) },
        erase: (Store.Scope, ModelContext, UserDefaults, () -> Void) throws -> Void
            = { try Store.wipe($1, scope: $0, defaults: $2, forgetSecret: $3) }
    ) -> Wiped {
        var failure: String?
        do {
            try erase(scope, context, defaults, forgetSecret)
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
        // Read back rather than assumed, for both scopes. `Store.wipe` reaches
        // for the Keychain only after its save has succeeded, so a delete that
        // threw has certainly not forgotten the key — and the row saying "Key
        // saved" here is the truth, not a leftover.
        return Wiped(key: reload(readBack: readKey), failure: failure)
    }

    /// Why the delete is being reported rather than assumed, in terms of what
    /// the user still has.
    ///
    /// It refuses to say "nothing was deleted" even though on today's
    /// `Store.wipe` a throw does leave the store untouched — the deletes are
    /// staged model by model and only the save commits them. That is one
    /// autosave away from being false, and the direction to be wrong in is the
    /// one that has the user check rather than the one that has them trust.
    /// Naming the key separately under `.everything` because it is the item
    /// here that is not merely private but live and billable, and the only one
    /// that survives deleting the app.
    static func deleteFailure(_ scope: Store.Scope, _ error: Error) -> String {
        let kept = scope == .everything
            ? "Some of your data is still here, and the Anthropic key has not been forgotten."
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

    static func colour(_ tone: KeyRow.Tone) -> Color {
        switch tone {
        case .good: Palette.met
        case .alarm: Palette.warningText
        case .quiet: Palette.secondary
        }
    }
}

extension SettingsScreen.KeyRow {

    var symbol: String {
        switch self {
        case .missing: "exclamationmark.circle"
        case .notSaved: "exclamationmark.triangle.fill"
        case .savedUnused, .saved: "checkmark.circle.fill"
        }
    }

    var tone: Tone {
        switch self {
        case .missing: .quiet
        case .notSaved: .alarm
        case .savedUnused, .saved: .good
        }
    }

    var text: String {
        switch self {
        case .missing: "No key — image reading is off"
        case .notSaved: "Key not saved — the Keychain refused it. Try typing it again."
        case .savedUnused: "Key saved · not used yet"
        case .saved(let day): "Key saved · last used \(day.dayAndMonth)"
        }
    }
}
