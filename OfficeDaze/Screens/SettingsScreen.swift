import SwiftData
import SwiftUI

/// Not in the mock, but capture cannot work without somewhere to put the API
/// key, and the key must not live in the repository or in a build setting.
struct SettingsScreen: View {
    @Environment(\.modelContext) private var context
    @Query private var captures: [Capture]

    @State private var apiKey = ""
    @State private var loaded = false
    @State private var confirmingWipe = false
    @State private var nudgeEnabled = false
    @State private var nudgeTime = Date()

    private var thisMonth: [Capture] {
        let month = Day.today.month_
        return captures.filter { month.contains(Day(of: $0.receivedAt)) }
    }

    var body: some View {
        Form {
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
                Text("Stored in the iOS Keychain — never in the app's settings, and never in a backup. Reading a screenshot costs about a penny; everything else in the app works without a key.")
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
                Button("Delete everything", role: .destructive) { confirmingWipe = true }
            } footer: {
                Text("Offices, bookings, attendance and leave. Attendance is the only record that a day was worked on prem — there is no other copy.")
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
        .confirmationDialog(
            "Delete everything?", isPresented: $confirmingWipe, titleVisibility: .visible
        ) {
            Button("Delete everything", role: .destructive) { try? Store.wipe(context) }
        }
    }
}
