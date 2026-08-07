import SwiftData
import SwiftUI

/// Everything that is set up once and then left alone: the offices, the key,
/// the reminder.
///
/// Offices used to have a screen of their own off the home toolbar, which gave
/// the app's least-visited list its most prominent link. It is a section here
/// instead, behind the cog, and the toolbar slot it vacated is the cog itself.
struct SettingsScreen: View {
    @Environment(\.modelContext) private var context
    @Environment(ArrivalMonitor.self) private var arrival
    @Query(sort: \Office.name) private var offices: [Office]
    @Query private var captures: [Capture]
    @Query private var leave: [LeaveDay]

    @State private var apiKey = ""
    @State private var loaded = false
    @State private var confirmingWipe = false
    @State private var nudgeEnabled = false
    @State private var nudgeTime = Date()

    private var thisMonth: [Capture] {
        let month = Day.today.month_
        return captures.filter { month.contains(Day(of: $0.receivedAt)) }
    }

    /// The row opens on this month, so this is the month it counts. Bank
    /// holidays are excluded for the reason they are everywhere else: they are
    /// derived from the calendar rather than booked, and they are already
    /// outside the working days the target is built from.
    private var leaveSummary: String {
        let month = Day.today.month_
        let days = leave
            .filter { $0.kind != .bankHoliday && month.contains($0.day) }
            .reduce(0) { $0 + $1.fraction }
        guard days > 0 else { return "None this month" }
        let count = days.formatted(.number.precision(.fractionLength(0...1)))
        return "\(count) \(days == 1 ? "day" : "days") this month"
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
                    LabeledContent("Holiday calendar", value: leaveSummary)
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
                        // Written straight through: there is no Save button to
                        // forget, and the Keychain is the only copy.
                        Keychain.apiKey = new.trimmingCharacters(in: .whitespacesAndNewlines)
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
                        NudgeScheduler.refresh(in: context)
                    }
                if nudgeEnabled {
                    DatePicker(
                        "Time", selection: $nudgeTime, displayedComponents: .hourAndMinute
                    )
                    .onChange(of: nudgeTime) { _, new in
                        NudgeScheduler.time = Day.calendar.dateComponents(
                            [.hour, .minute], from: new
                        )
                        NudgeScheduler.refresh(in: context)
                    }
                }
            } header: {
                Text("Reminder")
            } footer: {
                Text("One notification, and only when all three are true: tomorrow is a working day, nothing is booked, and the month is still short. A reminder that fires when the month is already met is a reminder you switch off.")
            }

            Section("This month") {
                LabeledContent("Screenshots read", value: "\(thisMonth.count)")
                LabeledContent(
                    "Tokens in",
                    value: thisMonth.reduce(0) { $0 + $1.inputTokens }.formatted()
                )
                LabeledContent(
                    "Tokens out",
                    value: thisMonth.reduce(0) { $0 + $1.outputTokens }.formatted()
                )
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
            guard !loaded else { return }
            loaded = true
            apiKey = Keychain.apiKey ?? ""
            nudgeEnabled = NudgeScheduler.isEnabled
            var components = NudgeScheduler.time
            components.year = Day.today.year
            components.month = Day.today.month
            components.day = Day.today.day
            nudgeTime = Day.calendar.date(from: components) ?? Date()
        }
        // Two destructive choices rather than one, because they are not the
        // same size of loss: the bookings are disposable and the offices are
        // not.
        .confirmationDialog(
            "Delete what?", isPresented: $confirmingWipe, titleVisibility: .visible
        ) {
            Button("Bookings, attendance and leave", role: .destructive) { wipe(.records) }
            Button(everythingTitle, role: .destructive) { wipe(.everything) }
        } message: {
            Text("Attendance is the only record that a day was worked on prem — there is no other copy.")
        }
    }

    private var everythingTitle: String {
        guard !offices.isEmpty else { return "Everything" }
        return "Everything, including \(offices.count) \(offices.count == 1 ? "office" : "offices")"
    }

    private func wipe(_ scope: Store.Scope) {
        try? Store.wipe(context, scope: scope)
        // Both of these were computed from records that no longer exist. The
        // regions matter most: iOS goes on monitoring a perimeter for a deleted
        // office until something tells it not to.
        arrival.refreshRegions()
        NudgeScheduler.refresh(in: context)
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
                Text(alertText(office))
                    .font(.system(size: 13))
                    // Green for an alert that will fire, and only that. The
                    // toggle being on is not the same thing, and colouring by
                    // the toggle put "Alert needs location access" in the
                    // reassuring colour.
                    .foregroundStyle(willFire(office) ? Palette.met : Palette.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    /// Every condition the alert actually depends on. Anything short of Always
    /// means iOS will not wake us for a crossing, and an office with no
    /// coordinates has no perimeter to cross — whatever the toggle says.
    private func willFire(_ office: Office) -> Bool {
        office.alertEnabled && arrival.canMonitor && office.isLocated
    }

    private func alertText(_ office: Office) -> String {
        guard office.alertEnabled else { return "Alert off" }
        guard arrival.canMonitor else { return "Alert needs location access" }
        guard office.isLocated else { return "Alert on · no location yet" }
        return "Alert on · \(Int(office.radiusMetres))m"
    }

    /// The alert cannot fire without Always, so the list says so rather than
    /// showing "Alert on" against a perimeter iOS will never wake us for.
    private var permissionRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(arrival.authorization == .denied || arrival.authorization == .restricted
                 ? "Location access is off — the arrival alert can't fire"
                 : "The arrival alert needs \"Always\" location access")
                .font(.system(size: 14))
                .foregroundStyle(Palette.warningText)
            Button(grantTitle) {
                if arrival.authorization == .denied || arrival.authorization == .restricted {
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

    private var grantTitle: String {
        switch arrival.authorization {
        case .denied, .restricted: "Open Settings"
        case .authorizedWhenInUse: "Allow Always"
        default: "Allow"
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
