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
                TextField("Postcode", text: $postcode)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
            } footer: {
                Text("The postcode is geocoded once when you save, so the perimeter works with no signal.")
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
                Text("The alert fires once a day per office, and shows your desk number.")
            }

            if let office, office.isLocated {
                Section("Location") {
                    LabeledContent(
                        "Coordinates",
                        value: String(format: "%.4f, %.4f", office.latitude, office.longitude)
                    )
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

        let target = office ?? Office(
            name: "", address: "", postcode: "", colourHex: colourHex
        )
        target.name = name.trimmingCharacters(in: .whitespaces)
        target.address = address.trimmingCharacters(in: .whitespaces)
        target.postcode = postcode.trimmingCharacters(in: .whitespaces)
        target.colourHex = colourHex
        target.radiusMetres = radius
        target.alertEnabled = alertEnabled

        // Only when the address has actually changed, or on a first save. A
        // geocode is a network round trip and the coordinates do not rot.
        let addressChanged = office == nil
            || office?.postcode != target.postcode
            || office?.address != target.address
        if addressChanged || !target.isLocated {
            if let point = await Geocoding.coordinates(
                postcode: target.postcode, address: target.address
            ) {
                target.latitude = point.latitude
                target.longitude = point.longitude
            }
        }

        if office == nil { context.insert(target) }
        try? context.save()
        dismiss()
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
