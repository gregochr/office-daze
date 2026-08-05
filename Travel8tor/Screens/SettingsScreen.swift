import SwiftUI

/// Where the API key goes in. The field is a `SecureField` and the value goes
/// straight to the Keychain — it is never held in `@AppStorage`, never written
/// to UserDefaults, and never logged.
struct SettingsScreen: View {
    @Environment(\.modelContext) private var context

    @State private var key: String = ""
    @State private var stored: Bool = Keychain.has(.anthropicAPIKey)
    @State private var message: String?

    /// The erase is two taps. `armed` is the first one.
    @State private var armed = false
    @State private var wiped: String?

    private let copy = Copy.shared

    var body: some View {
        // The back label names where it goes, not where it is — which is why
        // the arrival screen's says CONFIG and this one says TARGETS.
        ScreenScaffold(backTitle: copy(.targets)) {
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

                SectionKicker(text: "INTAKE")
                    .padding(.top, 20)
                    .padding(.bottom, 10)
                linkRow(
                    to: .manualEntry,
                    title: "ADD A BOOKING BY HAND",
                    note: "FOR ANYTHING THAT WAS NEVER GOING TO BE A SCREENSHOT"
                )

                SectionKicker(text: "ARRIVAL")
                    .padding(.top, 20)
                    .padding(.bottom, 10)
                linkRow(
                    to: .arrivalSettings,
                    title: Copy.shared(.arrivalTrigger),
                    note: "PERIMETER, FIRE RATE, AND THE ONCE-PER-DAY RULE"
                )

                SectionKicker(text: "COPY MODE")
                    .padding(.top, 20)
                    .padding(.bottom, 10)
                copyModeRow

                SectionKicker(text: "DATA")
                    .padding(.top, 20)
                    .padding(.bottom, 10)
                wipeRow
                    #if DEBUG
                    // `-screen settings -tap wipe` arms it without erasing, so
                    // the warning state can be looked at.
                    .task {
                        let arguments = ProcessInfo.processInfo.arguments
                        if let index = arguments.firstIndex(of: "-tap"),
                           index + 1 < arguments.count, arguments[index + 1] == "wipe" {
                            armed = true
                        }
                    }
                    #endif
            }
        }
    }

    /// Arm, then confirm. Two taps rather than a system alert: a confirmation
    /// dialog is a rounded card, and the brief calls the hard rectangle
    /// load-bearing. The armed state is also its own warning, which a dialog
    /// that appears and vanishes is not.
    private var wipeRow: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                if armed { wipe() } else { armed = true }
            } label: {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(armed ? "TAP AGAIN TO ERASE" : "ERASE EVERYTHING")
                            .t8(.rowAction)
                            .foregroundStyle(armed ? Palette.rail : Palette.bone)
                        Text(
                            armed
                                ? "THIS CANNOT BE UNDONE"
                                : "THE SAMPLE MONTH, AND EVERYTHING CAPTURED SINCE"
                        )
                        .t8(.rowActionNote)
                        .foregroundStyle(Palette.bone.opacity(0.4))
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    Rectangle()
                        .fill(armed ? Palette.rail : .clear)
                        .frame(width: 14, height: 14)
                        .overlay {
                            Rectangle().strokeBorder(
                                Palette.rail.opacity(0.5), lineWidth: Metrics.hairline
                            )
                        }
                }
                .padding(.vertical, 14)
                .padding(.horizontal, 15)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(armed ? Palette.rail.opacity(0.08) : .clear)
                .overlay {
                    Rectangle().strokeBorder(
                        armed ? Palette.rail : Palette.rail.opacity(0.25),
                        lineWidth: Metrics.hairline
                    )
                }
            }
            .buttonStyle(.plain)

            if armed {
                Text(wipeWarning)
                    .t8(.panelBody)
                    .foregroundStyle(Palette.bone.opacity(0.5))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)
                Button { armed = false } label: {
                    Text("CANCEL")
                        .t8(.rowAction)
                        .foregroundStyle(Palette.boneSecondary)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.plain)
            }

            if let wiped {
                Text(wiped)
                    .t8(.offline)
                    .foregroundStyle(Palette.stay)
                    .padding(.top, 10)
            }
        }
    }

    /// Says what the wipe cannot reach. Both are things the app has no right to
    /// undo rather than oversights.
    private var wipeWarning: String {
        """
        CALENDAR EVENTS ALREADY WRITTEN STAY IN YOUR CALENDAR — WRITE-ONLY \
        ACCESS CANNOT DELETE THEM. ATTENDANCE RECORDS ARE THE ONLY COPY OF \
        WHICH DAYS YOU WERE ON PREM; THERE IS NO OTHER.
        """
    }

    private func wipe() {
        do {
            try Store.wipe(context)
            // The perimeters were learned from buildings that no longer exist,
            // and the panel on the lock screen describes a booking that has
            // just been deleted.
            ArrivalMonitor(ledger: ArrivalLedger(context: context)).refreshRegions()
            Task { await DeskActivityController.endEverything() }
            armed = false
            wiped = "ERASED. THE STORE IS EMPTY."
        } catch {
            armed = false
            wiped = "COULD NOT ERASE: \(error.localizedDescription.uppercased())"
        }
    }

    private func linkRow(to route: Route, title: String, note: String) -> some View {
        NavigationLink(value: route) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(title)
                        .t8(.rowAction)
                        .foregroundStyle(Palette.bone)
                    Text(note)
                        .t8(.rowActionNote)
                        .foregroundStyle(Palette.bone.opacity(0.4))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Text("→").t8(.rowAction).foregroundStyle(Palette.rail.opacity(0.6))
            }
            .padding(.vertical, 14)
            .padding(.horizontal, 15)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay {
                Rectangle().strokeBorder(Palette.rail.opacity(0.25), lineWidth: Metrics.hairline)
            }
        }
        .buttonStyle(.plain)
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
