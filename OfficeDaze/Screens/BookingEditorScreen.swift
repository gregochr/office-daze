import SwiftData
import SwiftUI

/// Typing a booking in by hand — from the `Add` button, and in stage 4 from a
/// capture that could not be read.
///
/// It saves through `BookingStore.upsert` like every other path, so typing a
/// booking for a day that already has one corrects that booking rather than
/// adding a second. Manual outranks capture, so the typed version wins.
struct BookingEditorScreen: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Office.name) private var offices: [Office]

    var booking: DeskBooking?

    @State private var officeID: UUID?
    @State private var date = Day.today.startOfDayUTC
    @State private var deskID = ""
    @State private var floor = ""
    @State private var zone = ""
    @State private var startTime = ""
    @State private var endTime = ""
    @State private var loaded = false

    private var isNew: Bool { booking == nil }

    private var canSave: Bool {
        officeID != nil && !deskID.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        Form {
            Section {
                Picker("Office", selection: $officeID) {
                    Text("Choose").tag(UUID?.none)
                    ForEach(offices) { office in
                        Text(office.name).tag(UUID?.some(office.id))
                    }
                }
                DatePicker(
                    "Date", selection: $date, displayedComponents: .date
                )
                TextField("Desk", text: $deskID)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
            }

            Section {
                TextField("Floor", text: $floor)
                TextField("Zone", text: $zone)
                TextField("From", text: $startTime)
                    .keyboardType(.numbersAndPunctuation)
                TextField("Until", text: $endTime)
                    .keyboardType(.numbersAndPunctuation)
            } header: {
                Text("Optional")
            } footer: {
                Text("A field left blank is stored as absent, not as unreadable — it will not be flagged for checking.")
            }

            if !isNew {
                Section {
                    Button("Delete booking", role: .destructive) { delete() }
                }
            }
        }
        .navigationTitle(isNew ? "Add booking" : "Edit booking")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }.disabled(!canSave)
            }
        }
        .task {
            guard !loaded else { return }
            loaded = true
            if let booking {
                officeID = booking.officeID
                date = booking.day.startOfDayUTC
                deskID = booking.deskID
                floor = booking.floor ?? ""
                zone = booking.zone ?? ""
                startTime = booking.startTime ?? ""
                endTime = booking.endTime ?? ""
            } else if offices.count == 1 {
                officeID = offices.first?.id
            }
        }
    }

    private func save() {
        guard let officeID else { return }
        // A blank field is an absence, not an unreadable one: nothing typed by
        // hand is ever flagged for checking, because the person typing knows
        // what they left out.
        let candidate = BookingMerge.Candidate(
            officeID: officeID,
            day: Day(of: date),
            deskID: deskID.trimmingCharacters(in: .whitespaces),
            floor: floor.blankAsNil,
            zone: zone.blankAsNil,
            startTime: startTime.blankAsNil,
            endTime: endTime.blankAsNil,
            source: .manual,
            unsureFields: []
        )
        // Editing a booking's date or office can move it onto a day that
        // already has one. Deleting first keeps the merge from finding this
        // very row and merging it with itself.
        if let booking { context.delete(booking) }
        try? BookingStore.upsert(candidate, in: context)
        dismiss()
    }

    private func delete() {
        guard let booking else { return }
        context.delete(booking)
        try? context.save()
        dismiss()
    }
}

extension String {
    /// Whitespace-only is an absence too.
    var blankAsNil: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

#Preview {
    NavigationStack { BookingEditorScreen() }
        .modelContainer(try! Store.makeInMemoryContainer(seeded: true))
}
