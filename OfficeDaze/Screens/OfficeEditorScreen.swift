import SwiftData
import SwiftUI

/// Not drawn in the mock, so this is a standard form: name, address, postcode,
/// a colour from the fixed six, the perimeter, and the alert toggle.
struct OfficeEditorScreen: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
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
    @State private var loaded = false
    @State private var saving = false
    @State private var confirmingDelete = false
    @State private var couldNotLocate = false
    /// The office a first save created, when this screen was opened to add
    /// one. Saving again has to correct that row rather than insert a second.
    @State private var created: Office?

    /// The row being edited, once there is one.
    private var editing: Office? { office ?? created }

    private var isNew: Bool { office == nil }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && !saving
    }

    /// Colours already spoken for by *other* offices — an office keeps its own.
    private var takenColours: [String] {
        offices.filter { $0.id != office?.id }.map(\.colourHex)
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
                Text("The address and postcode are looked up together, once, when you save — so the perimeter still works with no signal. The postcode is its own field because a UK one locates a building on its own; where it does not, leave it out and let the address do the work.")
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
                            value: String(format: "%.4f, %.4f", editing.latitude, editing.longitude)
                        )
                    } else {
                        // Shown rather than hidden. An office with no
                        // coordinates has no perimeter, and the section
                        // disappearing was the only sign of it.
                        Text("This address could not be found, so there is no perimeter and the arrival alert cannot fire. Adding the city usually fixes it.")
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
                radius = office.radiusMetres
                alertEnabled = office.alertEnabled
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
            Text("Its desk bookings stay, but they will no longer name an office.")
        }
        .alert("Saved, but not located", isPresented: $couldNotLocate) {
            // Stay, so the address can be corrected while it is still in front
            // of you.
            Button("Edit address", role: .cancel) {}
            Button("Done") { dismiss() }
        } message: {
            Text("\(name) is saved, but the address could not be found on the map, so the arrival alert will not fire for it. Adding the city — or the country — usually fixes it.")
        }
    }

    private var colourPicker: some View {
        HStack(spacing: 14) {
            ForEach(OfficeColours.palette, id: \.self) { hex in
                let taken = takenColours.contains { $0.caseInsensitiveCompare(hex) == .orderedSame }
                Button {
                    colourHex = hex
                } label: {
                    Circle()
                        .fill(Color(officeHex: hex))
                        .frame(width: 26, height: 26)
                        .opacity(taken ? 0.25 : 1)
                        .overlay {
                            if colourHex == hex {
                                Circle().strokeBorder(Palette.text.opacity(0.4), lineWidth: 2)
                                    .frame(width: 34, height: 34)
                            }
                        }
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
                .disabled(taken)
                .accessibilityLabel(taken ? "Colour already used" : "Office colour")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func save() async {
        saving = true
        defer { saving = false }

        // Read before anything is written. When editing, `target` *is* the
        // stored office, so comparing the two afterwards compares a value with
        // itself and always says nothing changed — which is why correcting an
        // address on an already-located office never re-geocoded it.
        let before = editing.map { [$0.postcode, $0.address] }

        let target = editing ?? Office(
            name: "", address: "", postcode: "", colourHex: colourHex
        )
        target.name = name.trimmingCharacters(in: .whitespaces)
        target.address = address.trimmingCharacters(in: .whitespaces)
        target.postcode = postcode.trimmingCharacters(in: .whitespaces)
        target.colourHex = colourHex
        target.radiusMetres = radius
        target.alertEnabled = alertEnabled

        // Only when the address has actually changed, or while there is still
        // nowhere to draw a perimeter. A geocode is a network round trip and
        // coordinates do not rot.
        if before != [target.postcode, target.address] || !target.isLocated {
            if let point = await Geocoding.coordinates(
                postcode: target.postcode, address: target.address
            ) {
                target.latitude = point.latitude
                target.longitude = point.longitude
            }
        }

        if editing == nil {
            context.insert(target)
            // Held, so a second Save after the not-located alert corrects this
            // office rather than inserting another one beside it.
            created = target
        }
        try? context.save()

        // The office saves either way — one the geocoder cannot place is still
        // an office, it just cannot be monitored. But it is worth saying so
        // now rather than leaving it to be inferred from a line in the list a
        // week later, and only when the alert was actually asked for: an
        // office with the alert off does not need coordinates at all.
        if alertEnabled && !target.isLocated {
            couldNotLocate = true
        } else {
            dismiss()
        }
    }

    private func delete() {
        guard let office else { return }
        context.delete(office)
        try? context.save()
        dismiss()
    }
}

#Preview("Add") {
    NavigationStack { OfficeEditorScreen() }
        .modelContainer(try! Store.makeInMemoryContainer(seeded: true))
}
