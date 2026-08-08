import CoreLocation
import SwiftData
import SwiftUI

/// Not drawn in the mock, so this is a standard form: name, address, postcode,
/// a colour from the fixed six, the perimeter, and the alert toggle.
struct OfficeEditorScreen: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    /// Every field on this screen is one the region monitor reads — the
    /// coordinates, the perimeter and the alert toggle — and this is the only
    /// screen that writes them. Taken the same way `SettingsScreen` takes it.
    @Environment(ArrivalMonitor.self) private var arrival
    @Query(sort: \Office.name) private var offices: [Office]

    /// Nil when adding. Editing writes straight through to the model on save
    /// rather than as you type, so backing out leaves the office alone.
    var office: Office?

    @State private var name = ""
    @State private var address = ""
    @State private var postcode = ""
    @State private var colourHex = OfficeColours.palette[0]
    @State private var radius: Double = 50
    @State private var alertEnabled = true
    @State private var aliases: [String] = []
    /// The alias list as it was when this screen opened. Kept because the
    /// difference between it and `aliases` — the rows the user swiped away — is
    /// the only part of the list this screen is entitled to write. See
    /// `mergedAliases`.
    @State private var loadedAliases: [String] = []
    @State private var loaded = false
    @State private var saving = false
    @State private var confirmingDelete = false
    @State private var couldNotLocate = false
    /// Set only by a save that did not reach the store. Non-nil holds the
    /// screen open, and it is deliberately not `couldNotLocate`: that alert
    /// describes an office that exists and cannot be watched, this one an
    /// office that is not there at all. See `saveFailure`.
    @State private var failure: String?
    /// The office a first save created, when this screen was opened to add
    /// one. Saving again has to correct that row rather than insert a second.
    @State private var created: Office?

    /// The row being edited, once there is one.
    private var editing: Office? { office ?? created }

    private var isNew: Bool { office == nil }

    private var canSave: Bool { Self.canSave(name: name, saving: saving) }

    /// Colours already spoken for by *other* offices — an office keeps its own.
    private var takenColours: [String] {
        Self.takenColours(among: offices, excluding: office?.id)
    }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $name)
                    .textInputAutocapitalization(.words)
                TextField("Address", text: $address)
                    .textInputAutocapitalization(.words)
                TextField("Postcode (optional)", text: $postcode)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
            } footer: {
                Text(
                    "The address and postcode are looked up together, once, when you save — "
                    + "so the perimeter still works with no signal. The postcode is its own "
                    + "field because a UK one locates a building on its own; where it does "
                    + "not, leave it out and let the address do the work."
                )
            }

            // Only when there is something to show. An empty section inviting
            // you to add a name by hand would be asking for the one thing the
            // capture sheet already collects for itself.
            if !aliases.isEmpty {
                Section {
                    ForEach(aliases, id: \.self) { Text($0) }
                        .onDelete { aliases.remove(atOffsets: $0) }
                } header: {
                    Text("Also known as")
                } footer: {
                    Text(
                        "What the booking system calls this building. Remembered from the "
                        + "last time a capture asked which office it was, so it does not ask "
                        + "again — delete one to be asked afresh."
                    )
                }
            }

            Section("Colour") {
                colourPicker
            }

            Section {
                Toggle("Arrival alert", isOn: $alertEnabled)
                Stepper(
                    "Perimeter · \(Int(radius))m",
                    value: $radius, in: 20...500, step: 10
                )
            } footer: {
                Text(ArrivalCopy.officeEditor)
            }

            // `editing`, not `office`: after a first save that could not be
            // located, this is the section the user has been sent back to look
            // at, and it has to describe the row that was just written.
            if let editing {
                Section("Location") {
                    if editing.isLocated {
                        LabeledContent(
                            "Coordinates",
                            value: Self.coordinatesText(
                                latitude: editing.latitude, longitude: editing.longitude
                            )
                        )
                    } else {
                        // Shown rather than hidden. An office with no
                        // coordinates has no perimeter, and the section
                        // disappearing was the only sign of it.
                        Text(
                            "This address could not be found, so there is no perimeter and "
                            + "the arrival alert cannot fire. Adding the city usually fixes it."
                        )
                        .font(.system(size: 14))
                        .foregroundStyle(Palette.warningText)
                    }
                }
            }

            if !isNew {
                Section {
                    Button("Delete office", role: .destructive) { confirmingDelete = true }
                }
            }
        }
        .navigationTitle(isNew ? "Add office" : "Edit office")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { Task { await save() } }
                    .disabled(!canSave)
            }
        }
        .task {
            guard !loaded else { return }
            loaded = true
            if let office {
                name = office.name
                address = office.address
                postcode = office.postcode
                colourHex = office.colourHex
                radius = Self.perimeter(office.radiusMetres)
                alertEnabled = office.alertEnabled
                aliases = office.aliases
                loadedAliases = office.aliases
            } else {
                // The next free colour, so two offices are never the same. All
                // six taken falls back to the first rather than blocking a new
                // office over a colour.
                colourHex = OfficeColours.next(after: takenColours) ?? OfficeColours.palette[0]
            }
        }
        .confirmationDialog(
            "Delete this office?",
            isPresented: $confirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { delete() }
        } message: {
            // Says what happens to all three things that point at the office,
            // because two of them are counted. The days worked there are the
            // only record that they were worked, so they stay and go on
            // counting; the days merely intended there do not survive the
            // building they were intended at.
            Text(
                "Its desk bookings stay, and the days you worked there still count toward "
                + "the month — but neither will name an office any more. Days planned there "
                + "are removed."
            )
        }
        .alert("Saved, but not located", isPresented: $couldNotLocate) {
            // Stay, so the address can be corrected while it is still in front
            // of you.
            Button("Edit address", role: .cancel) {}
            Button("Done") { dismiss() }
        } message: {
            Text("\(name) is saved, but the address could not be found on the map, so the arrival alert will not fire for it. Adding the city — or the country — usually fixes it.")
        }
        // A second alert rather than more words in the first. "Saved, but not
        // located" is a promise that the office is in the list, and a write
        // that never reached the store cannot borrow it — a user who read that
        // sentence after a failed save would go looking for a row that is not
        // there. The screen stays open behind this one, so what was typed is
        // still on screen to be saved again.
        .alert(
            "Not saved",
            isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(failure ?? "")
        }
    }

    private var colourPicker: some View {
        HStack(spacing: 14) {
            ForEach(Self.swatches(taken: takenColours, selected: colourHex)) { swatch in
                Button {
                    colourHex = swatch.hex
                } label: {
                    Circle()
                        .fill(Color(officeHex: swatch.hex))
                        .frame(width: 26, height: 26)
                        .opacity(swatch.isTaken ? 0.25 : 1)
                        .overlay {
                            if swatch.isSelected {
                                Circle().strokeBorder(Palette.text.opacity(0.4), lineWidth: 2)
                                    .frame(width: 34, height: 34)
                            }
                        }
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
                .disabled(swatch.isTaken)
                .accessibilityLabel(swatch.accessibilityLabel)
                .accessibilityValue(swatch.accessibilityValue)
                .accessibilityAddTraits(swatch.isSelected ? [.isSelected] : [])
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func save() async {
        saving = true
        defer { saving = false }

        // Whether this save is the one that inserts has to be read now: after
        // `applySave` returns there is a `created` office either way, and the
        // question "was there one before?" can no longer be asked.
        let wasNew = editing == nil
        let saved = await Self.applySave(
            Draft(
                name: name, address: address, postcode: postcode,
                colourHex: colourHex, radius: radius, alertEnabled: alertEnabled,
                aliases: aliases, loadedAliases: loadedAliases
            ),
            to: editing, in: context
        )

        if wasNew {
            // Held, so a second Save after the not-located alert corrects this
            // office rather than inserting another one beside it. Held after a
            // failed save too, and for the same reason: the row is still
            // pending in the context, so a retry that forgot about it would
            // insert a twin and the save that finally worked would write both.
            created = saved.office
        }

        // What was written is now what the section shows, so an alias taught
        // by a capture while this screen was open appears rather than staying
        // invisible until the screen is reopened — and it becomes the baseline
        // for any further deletion, so saving twice does not re-delete a name
        // that has already gone.
        aliases = saved.office.aliases
        loadedAliases = saved.office.aliases

        // The perimeters iOS watches are rebuilt from the store, and this is
        // the only screen that changes what the store says about them. Without
        // this call `refreshRegions` runs at launch and on an authorization
        // change and nowhere else, so a new office is not watched, a corrected
        // address goes on alerting at the old building, a widened perimeter
        // stays at its old radius, and an alert switched off goes on firing —
        // each of them until the process next starts, which may be days. The
        // rebuild is wholesale and at most six regions, so calling it on every
        // save costs nothing and cannot drift out of step with the store.
        //
        // Called even when the write did not land. The context still holds what
        // this screen put in it, and every `@Query` in the app is already
        // drawing the office from there — leaving CoreLocation out would make
        // the perimeters the one view of the store that disagreed, and the next
        // launch reconciles either way.
        arrival.refreshRegions()

        switch saved.outcome {
        case .saved:
            dismiss()
        case .couldNotLocate:
            couldNotLocate = true
        case .failed(let why):
            // Not dismissed. Dismissing on a write that did not land is the
            // whole of the bug this case exists for.
            failure = why
        }
    }

    private func delete() {
        guard let office else { return }
        switch Self.applyDelete(office, in: context) {
        case .removed:
            // The direction that matters more than adding one: nothing else
            // ever tells CoreLocation to stop. A deleted office's region goes
            // on waking the app, and the wake-up reaches
            // `ArrivalLedger.handleEntry`, which looks the office up, does not
            // find it, and returns `.disabled` — so the cost is invisible
            // battery rather than a wrong alert, which is exactly why it would
            // never have been noticed.
            arrival.refreshRegions()
            dismiss()
        case .failed(let why):
            // Not dismissed, and the perimeters are left alone: an office still
            // in the store is an office still worth watching.
            failure = why
        }
    }
}

#Preview("Add") {
    // The monitor comes from the app's root in the real thing. Supplied here
    // because saving reads it, and an environment lookup that finds nothing is
    // a crash rather than a no-op — a preview that dies on Save would be a
    // worse way to learn that than this line is to read.
    //
    // The `try!` is the documented exception the lint config names: an
    // in-memory container built from the app's own schema can only throw if
    // that schema does not load, which the real app would not have launched
    // with either. `try?` would trade a stack trace naming the model that
    // broke for a blank canvas that says nothing at all.
    // swiftlint:disable:next force_try
    let container = try! Store.makeInMemoryContainer(seeded: true)
    let context = container.mainContext
    return NavigationStack { OfficeEditorScreen() }
        .modelContainer(container)
        .environment(ArrivalMonitor(ledger: ArrivalLedger(context: context), context: context))
}
