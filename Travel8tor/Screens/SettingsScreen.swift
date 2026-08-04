import SwiftUI

/// Where the API key goes in. The field is a `SecureField` and the value goes
/// straight to the Keychain — it is never held in `@AppStorage`, never written
/// to UserDefaults, and never logged.
struct SettingsScreen: View {
    @State private var key: String = ""
    @State private var stored: Bool = Keychain.has(.anthropicAPIKey)
    @State private var message: String?

    private let copy = Copy.shared

    var body: some View {
        ScreenScaffold(backTitle: "CONFIG") {
            ScreenTitleBlock(title: "CONFIG")
        } content: {
            VStack(alignment: .leading, spacing: 0) {
                SectionKicker(text: "MODEL ACCESS")
                    .padding(.bottom, 10)

                VStack(alignment: .leading, spacing: 0) {
                    Text(stored ? "KEY STORED IN KEYCHAIN" : "NO KEY STORED")
                        .t8(.incompleteHeader)
                        .foregroundStyle(stored ? Palette.stay : Palette.desk)

                    Text(explanation)
                        .t8(.panelBody)
                        .foregroundStyle(Palette.bone.opacity(0.55))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 10)

                    SecureField("", text: $key, prompt: Text("sk-ant-…").foregroundStyle(Palette.bone.opacity(0.28)))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.custom(T8Fonts.regular, size: 12))
                        .foregroundStyle(Palette.bone)
                        .padding(.vertical, 11)
                        .padding(.horizontal, 12)
                        .background(Palette.ground)
                        .overlay {
                            Rectangle().strokeBorder(
                                Palette.rail.opacity(0.3), lineWidth: Metrics.hairline
                            )
                        }
                        .padding(.top, 14)

                    HStack(spacing: 9) {
                        SolidAction(title: "STORE KEY", fill: Palette.desk) { store() }
                        if stored {
                            OutlinedAction(title: "REMOVE") { remove() }
                        }
                    }
                    .padding(.top, 11)

                    if let message {
                        Text(message)
                            .t8(.panelBody)
                            .foregroundStyle(Palette.stay)
                            .padding(.top, 10)
                    }
                }
                .padding(15)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay {
                    Rectangle().strokeBorder(Palette.railBorder, lineWidth: Metrics.hairline)
                }

                SectionKicker(text: "COPY MODE")
                    .padding(.top, 20)
                    .padding(.bottom, 10)
                copyModeRow
            }
        }
    }

    private var explanation: String {
        """
        USED ONLY TO READ SCREENSHOTS AND PDFS. PASS FILES ARE PARSED ON DEVICE \
        AND NEED NO KEY. THE KEY IS HELD IN THE KEYCHAIN, NOT IN THE APP BUNDLE \
        OR ITS SETTINGS, AND IS NOT INCLUDED IN BACKUPS.
        """
    }

    private var copyModeRow: some View {
        Button {
            Copy.shared.terminator.toggle()
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(Copy.shared.terminator ? "TERMINATOR" : "PLAIN ENGLISH")
                        .t8(.rowAction)
                        .foregroundStyle(Palette.bone)
                    Text("SWITCHES EVERY LABEL IN THE APP")
                        .t8(.rowActionNote)
                        .foregroundStyle(Palette.bone.opacity(0.4))
                }
                Spacer(minLength: 0)
                Rectangle()
                    .fill(Copy.shared.terminator ? Palette.rail : Palette.bone.opacity(0.2))
                    .frame(width: 14, height: 14)
            }
            .padding(.vertical, 14)
            .padding(.horizontal, 15)
            .overlay {
                Rectangle().strokeBorder(Palette.rail.opacity(0.25), lineWidth: Metrics.hairline)
            }
        }
        .buttonStyle(.plain)
    }

    private func store() {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try Keychain.set(trimmed, for: .anthropicAPIKey)
            key = ""
            stored = true
            message = "STORED. SCREENSHOT AND PDF CAPTURE IS NOW AVAILABLE."
        } catch {
            message = (error as? LocalizedError)?.errorDescription ?? "COULD NOT STORE THE KEY."
        }
    }

    private func remove() {
        Keychain.remove(.anthropicAPIKey)
        stored = false
        message = "REMOVED."
    }
}
