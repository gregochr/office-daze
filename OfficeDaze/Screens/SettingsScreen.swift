import SwiftData
import SwiftUI

/// Everything that is set up once and then left alone: the offices and the
/// reminder.
///
/// Offices used to have a screen of their own off the home toolbar, which gave
/// the app's least-visited list its most prominent link. It is a section here
/// instead, behind the cog, and the toolbar slot it vacated is the cog itself.
///
/// Every line this screen prints is decided by a `static` in
/// `SettingsScreenDecisions.swift` rather than inline in `body`. That is not
/// tidiness: each of them is a claim about something the user cannot otherwise
/// check — whether the alert will fire, what a delete would take — and a claim
/// made inside a `View` cannot be tested, which is precisely how a row on this
/// screen once came to report a state it had not checked.
struct SettingsScreen: View {
    @Environment(\.modelContext) private var context
    @Environment(ArrivalMonitor.self) private var arrival
    @Query(sort: \Office.name) private var offices: [Office]
    @Query private var captures: [Capture]
    @Query private var leave: [LeaveDay]

    @State private var loaded = false
    @State private var confirmingWipe = false
    /// Set only by a delete that did not land. Non-nil raises the alert below,
    /// because the alternative — the silence a successful delete makes — reads
    /// as "it worked".
    @State private var wipeFailure: String?
    @State private var nudgeEnabled = false
    @State private var nudgeTime = Date()

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
                Text(
                    "Every two days off takes a day off the month's target: "
                        + "one day changes nothing, the second drops eight to "
                        + "seven, and a week off drops it to six. Weekends and bank "
                        + "holidays are outside the count already, so booking one "
                        + "off costs nothing and gains nothing."
                )
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
                Text(
                    "One notification, and only when all three are true: tomorrow "
                        + "is a working day, nothing is booked, and the month is "
                        + "still short. A reminder that fires when the month is "
                        + "already met is a reminder you switch off."
                )
            }

            Section {
                LabeledContent(
                    "Screenshots read", value: "\(Self.reads(of: captures, in: Day.today.month_))"
                )
            } header: {
                Text("This month")
            } footer: {
                Text(
                    "Every image is read on this phone. Nothing is sent anywhere, "
                        + "nothing is kept, and nothing is billed."
                )
            }

            #if DEBUG
            // The OCR spike's page. Debug builds only, and everything it does
            // is behind its own switch — see `SpikeDump`.
            Section {
                NavigationLink("OCR spike") { SpikeDumpsScreen() }
                    .foregroundStyle(Palette.tint)
            } header: {
                Text("Debug")
            }
            #endif

            Section {
                Button("Delete data…", role: .destructive) { confirmingWipe = true }
            } footer: {
                Text(
                    "A booking can be captured again in seconds. An office is a "
                        + "name, an address and a perimeter you typed in yourself, "
                        + "so it goes only if you say so. Attendance is the only "
                        + "record that a day was worked on prem — there is no other "
                        + "copy, under either choice."
                )
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
        // A delete that threw used to report exactly what a delete that worked
        // reported: the perimeters refreshed, the reminder redone, and not a
        // word on screen. The user was told their data was gone
        // while all of it was still there — which for the one feature in the app
        // whose whole purpose is removing data is the worst direction to be
        // wrong in, because the person who believes it hands the phone on.
        .alert(
            "Not deleted",
            isPresented: Binding(
                get: { wipeFailure != nil }, set: { if !$0 { wipeFailure = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(wipeFailure ?? "")
        }
    }

    private func wipe(_ scope: Store.Scope) {
        wipeFailure = Self.wipe(scope, in: context, arrival: arrival).failure
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
                            ? Palette.settled : Palette.secondary
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
