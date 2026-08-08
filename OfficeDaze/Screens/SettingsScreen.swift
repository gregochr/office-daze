import CoreLocation
import SwiftData
import SwiftUI

/// The Keychain, as far as this screen is concerned: read it, write it, forget
/// it.
///
/// An environment value rather than the defaulted closures the statics below
/// used to carry, because a default is only reachable from a call site that
/// omits it — and `body` was exactly such a call site. `.task` read the real
/// Keychain and `.onChange(of: apiKey)` wrote back through it, so merely
/// rendering this screen put the developer's live, billable Anthropic key in
/// the path of the run: one read of it, and one rewrite. That is why this
/// screen had no render coverage at all until now. With the seam a test hands
/// in its own store and `body` has no way to reach the real one, so the
/// defaults are gone from `write`, `reload` and `wipe` as well: `real` below is
/// now the only line in the settings screen that names `Keychain`, and a call
/// site that wants the true one has to say so.
///
/// `nonisolated` for the reason `AlertReadiness` is: an environment key's
/// `defaultValue` is read without an actor, and a `KeychainAccess.real` bound
/// to the main actor could not supply it.
nonisolated struct KeychainAccess: Sendable {
    var read: @Sendable () -> String?
    var write: @Sendable (String) -> Bool
    var forget: @Sendable () -> Void

    static let real = KeychainAccess(
        read: { Keychain.apiKey },
        write: { Keychain.store($0) },
        forget: { Keychain.apiKey = nil }
    )
}

extension EnvironmentValues {
    @Entry var keychain = KeychainAccess.real
}

/// Everything that is set up once and then left alone: the offices, the key,
/// the reminder.
///
/// Offices used to have a screen of their own off the home toolbar, which gave
/// the app's least-visited list its most prominent link. It is a section here
/// instead, behind the cog, and the toolbar slot it vacated is the cog itself.
///
/// Every line this screen prints is decided by a `static` below rather than
/// inline in `body`. That is not tidiness: each of them is a claim about
/// something the user cannot otherwise check — whether the key is stored,
/// whether the alert will fire, what a delete would take — and a claim made
/// inside a `View` cannot be tested, which is precisely how the key row came to
/// say "Key saved" on the strength of what was in its own text field.
struct SettingsScreen: View {
    @Environment(\.modelContext) private var context
    @Environment(ArrivalMonitor.self) private var arrival
    @Environment(\.keychain) private var keychain
    @Query(sort: \Office.name) private var offices: [Office]
    @Query private var captures: [Capture]
    @Query private var leave: [LeaveDay]

    @State private var apiKey = ""
    /// What the Keychain says it holds — not what the field says it was given.
    @State private var key = KeyState()
    @State private var loaded = false
    @State private var confirmingWipe = false
    @State private var nudgeEnabled = false
    @State private var nudgeTime = Date()

    private var keyRow: KeyRow {
        Self.keyRow(key, lastUsed: Self.lastSuccessfulUse(in: captures))
    }

    var body: some View {
        Form {
            Section {
                if !arrival.canMonitor && !offices.isEmpty { permissionRow }
                ForEach(offices) { office in
                    NavigationLink {
                        OfficeEditorScreen(office: office)
                    } label: {
                        officeRow(office)
                    }
                }
                NavigationLink("Add office") { OfficeEditorScreen() }
                    .foregroundStyle(Palette.tint)
                // Beneath the offices because it is a property of them: the
                // alert fires on their perimeters, and each row above says
                // whether its own will. On the home screen it sat under the
                // month's bookings, which is the one thing it has nothing to do
                // with — and it was permanent furniture on the screen you open
                // every day, for something you look at once when setting up.
                if !offices.isEmpty {
                    NavigationLink("Preview arrival alert") { ArrivalPreviewScreen() }
                        .foregroundStyle(Palette.tint)
                }
            } header: {
                Text("Offices")
            } footer: {
                Text(ArrivalCopy.officesSection)
            }

            Section {
                NavigationLink {
                    LeaveScreen()
                } label: {
                    LabeledContent(
                        "Holiday calendar",
                        value: Self.leaveSummary(leave, in: Day.today.month_)
                    )
                }
            } header: {
                Text("Leave")
            } footer: {
                Text("Every whole five days off takes two days off the month's target: four days change nothing, the fifth drops eight to six, and ten days drop it to four. Weekends and bank holidays are outside the count already, so booking one off costs nothing and gains nothing.")
            }

            Section {
                SecureField("sk-ant-…", text: $apiKey)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onChange(of: apiKey) { _, new in
                        // Only what the user typed. `.task` below loads the
                        // stored key into this field, and SwiftUI delivers that
                        // assignment here exactly as it delivers a keystroke —
                        // so opening Settings rewrote the key it had just read.
                        // Invisible while securityd agrees and a lie when it
                        // does not: a refused rewrite put "Key not saved — the
                        // Keychain refused it. Try typing it again." under a key
                        // that was stored, intact, and that the user had not
                        // touched.
                        guard Self.shouldWrite(typed: new, stored: key.stored) else { return }
                        // Written straight through: there is no Save button to
                        // forget, and the Keychain is the only copy. What comes
                        // back is what the Keychain then holds, which is the
                        // only thing the row below is entitled to report.
                        key = Self.write(new, store: keychain.write, readBack: keychain.read)
                    }
                // The field saves on every keystroke into a store nothing can
                // read back, so there was no way to tell a saved key from a
                // typo until a capture failed at the moment the key was needed.
                // This says which of the two it is, and when it last worked.
                HStack(spacing: 8) {
                    Image(systemName: keyRow.symbol)
                        .font(.system(size: 14))
                        .foregroundStyle(Self.colour(keyRow.tone))
                    Text(keyRow.text)
                        .font(.system(size: 13))
                        .foregroundStyle(
                            keyRow.tone == .alarm ? Palette.warningText : Palette.secondary
                        )
                }
            } header: {
                Text("Anthropic API key")
            } footer: {
                Text("Stored in the iOS Keychain — never in the app's settings, and never in a backup. Reading an image sends it to Anthropic to be read by Claude, and costs about a penny; everything else in the app works without a key.")
            }

            Section {
                Toggle("Evening reminder", isOn: $nudgeEnabled)
                    .onChange(of: nudgeEnabled) { _, new in
                        NudgeScheduler.isEnabled = new
                        // The reminder needs notifications and needs nothing
                        // else — not location, not an office. Asking here is the
                        // only way it gets asked for at all by a user who tracks
                        // attendance by hand: the permission row below the
                        // offices is the app's other call site, and it is not
                        // rendered when there are no offices.
                        if new {
                            Task { await arrival.requestNotificationAuthorization() }
                        }
                        NudgeScheduler.refresh(in: context)
                    }
                if nudgeEnabled {
                    DatePicker(
                        "Time", selection: $nudgeTime, displayedComponents: .hourAndMinute
                    )
                    .onChange(of: nudgeTime) { _, new in
                        // The screen no longer names a calendar at all. It used
                        // to read the picker through `Day.calendar`, which is
                        // pinned to UTC, so a user choosing 18:00 in BST stored
                        // 17 and the reminder arrived at five.
                        NudgeScheduler.time = NudgeScheduler.components(from: new)
                        NudgeScheduler.refresh(in: context)
                    }
                    if !arrival.notificationsAllowed {
                        Text("Notifications are off for Office Daze, so this reminder can't arrive. Turn them on in iOS Settings.")
                            .font(.system(size: 13))
                            .foregroundStyle(Palette.warningText)
                    }
                }
            } header: {
                Text("Reminder")
            } footer: {
                Text("One notification, and only when all three are true: tomorrow is a working day, nothing is booked, and the month is still short. A reminder that fires when the month is already met is a reminder you switch off.")
            }

            Section("This month") {
                let cost = Self.cost(of: captures, in: Day.today.month_)
                LabeledContent("Screenshots read", value: "\(cost.read)")
                LabeledContent("Tokens in", value: cost.inputTokens.formatted())
                LabeledContent("Tokens out", value: cost.outputTokens.formatted())
            }

            Section {
                Button("Delete data…", role: .destructive) { confirmingWipe = true }
            } footer: {
                Text("A booking can be captured again in seconds. An office is a name, an address and a perimeter you typed in yourself, so it goes only if you say so. Attendance is the only record that a day was worked on prem — there is no other copy, under either choice.")
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            // Not behind `loaded`: permission can be revoked in iOS Settings
            // while this screen is merely backgrounded, and the whole point of
            // the row above is that the app stops claiming an alert works when
            // it does not.
            await arrival.refreshNotificationStatus()
            guard !loaded else { return }
            loaded = true
            key = Self.reload(readBack: keychain.read)
            apiKey = key.stored ?? ""
            nudgeEnabled = NudgeScheduler.isEnabled
            // The other half of the pair above. Both ends now read the device's
            // clock, so what the picker shows is what the trigger will match.
            //
            // No migration for a time stored under the old code, deliberately.
            // The stored number was the user's chosen hour minus their UTC
            // offset *at the moment they chose it*, and that offset is not
            // recoverable: a UK user who set the reminder in January stored the
            // hour correctly, one who set it in July stored it an hour early,
            // and both look identical here. Correcting by the current offset
            // would therefore move the winter user's reminder to an hour they
            // never asked for. The fix makes the picker tell the truth instead —
            // it now shows the time the reminder has actually been arriving at,
            // which is visible, self-explanatory, and one drag from right.
            nudgeTime = NudgeScheduler.pickerDate(for: NudgeScheduler.time)
        }
        // Two destructive choices rather than one, because they are not the
        // same size of loss: the bookings are disposable and the offices are
        // not.
        .confirmationDialog(
            "Delete what?", isPresented: $confirmingWipe, titleVisibility: .visible
        ) {
            Button("Bookings, attendance and leave", role: .destructive) { wipe(.records) }
            Button(Self.everythingTitle(officeCount: offices.count), role: .destructive) {
                wipe(.everything)
            }
        } message: {
            Text("Attendance is the only record that a day was worked on prem — there is no other copy.")
        }
    }

    private func wipe(_ scope: Store.Scope) {
        key = Self.wipe(
            scope, in: context, arrival: arrival,
            forgetSecret: keychain.forget, readKey: keychain.read
        )
        // The field is showing a key that, under `.everything`, no longer
        // exists — see `SettingsScreen.wipe`.
        apiKey = key.stored ?? ""
    }

    // MARK: Offices

    private func officeRow(_ office: Office) -> some View {
        HStack(spacing: 12) {
            OfficeDot(colourHex: office.colourHex, size: 11)
            VStack(alignment: .leading, spacing: 3) {
                Text(office.name)
                    .foregroundStyle(Palette.text)
                Text(fullAddress(office))
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.secondary)
                Text(Self.readiness(office, arrival: arrival).text)
                    .font(.system(size: 13))
                    // Green for an alert that will fire, and only that. The
                    // toggle being on is not the same thing, and colouring by
                    // the toggle put "Alert needs location access" in the
                    // reassuring colour.
                    .foregroundStyle(
                        Self.readiness(office, arrival: arrival).willFire
                            ? Palette.met : Palette.secondary
                    )
            }
        }
        .padding(.vertical, 2)
    }

    /// The alert cannot fire without Always, so the list says so rather than
    /// showing "Alert on" against a perimeter iOS will never wake us for.
    private var permissionRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(Self.permissionText(arrival.authorization))
                .font(.system(size: 14))
                .foregroundStyle(Palette.warningText)
            Button(Self.grantTitle(arrival.authorization)) {
                if Self.opensSettings(arrival.authorization) {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                } else {
                    arrival.requestAuthorization()
                }
            }
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(Palette.warningText)
        }
        .padding(.vertical, 2)
        .listRowBackground(Palette.warningSurface)
    }
}

// MARK: - What the screen decides

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

    /// Deletes, then puts back in step everything that was computed from the
    /// records that no longer exist — and answers with the key row's new state.
    ///
    /// It answers rather than returning nothing because `.everything` takes the
    /// Anthropic key with it (see `Store.wipe`), and a screen that kept showing
    /// "Key saved · last used 4 August" over an empty Keychain would be making
    /// the same claim from state that this row was rewritten to stop making.
    /// The regions matter just as much: iOS goes on monitoring a perimeter for
    /// a deleted office until something tells it not to.
    @discardableResult
    static func wipe(
        _ scope: Store.Scope,
        in context: ModelContext,
        arrival: ArrivalMonitor,
        defaults: UserDefaults = .standard,
        forgetSecret: () -> Void,
        readKey: () -> String?,
        refreshNudge: (ModelContext) -> Void = { NudgeScheduler.refresh(in: $0) }
    ) -> KeyState {
        try? Store.wipe(
            context, scope: scope, defaults: defaults, forgetSecret: forgetSecret
        )
        arrival.refreshRegions()
        refreshNudge(context)
        return reload(readBack: readKey)
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

/// `63 Coleman Street, London EC2R 5BB`.
///
/// The postcode is a separate field because the geocoder wants it on its own,
/// but people type it into the address line as well. Appending it regardless
/// gives `… 1210 Brussels 1210`, so a postcode already in the address is left
/// where it is.
func fullAddress(_ office: Office) -> String {
    let postcode = office.postcode.trimmingCharacters(in: .whitespaces)
    guard !postcode.isEmpty,
          !office.address.localizedCaseInsensitiveContains(postcode) else {
        return office.address
    }
    return office.address.isEmpty ? postcode : "\(office.address) \(postcode)"
}
