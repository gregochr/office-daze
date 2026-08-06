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
        }
        .confirmationDialog(
            "Delete everything?", isPresented: $confirmingWipe, titleVisibility: .visible
        ) {
            Button("Delete everything", role: .destructive) { try? Store.wipe(context) }
        }
    }
}
