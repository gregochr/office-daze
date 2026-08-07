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

    /// Which field a capture could not read.
    ///
    /// The editor opens with the cursor already in it, so the amber marker on
    /// the list is one tap from the thing it is complaining about rather than
    /// four and a hunt.
    enum Field: Hashable {
        case desk, floor, zone, startTime, endTime

        /// The names the model uses in `unsureFields`, which are the schema's
        /// own — this is the one place the two vocabularies meet.
        init?(unsureField: String) {
            switch unsureField {
            case "deskId", "deskID": self = .desk
            case "floor": self = .floor
            case "zone": self = .zone
            case "startTime": self = .startTime
            case "endTime": self = .endTime
            default: return nil
            }
        }

        var label: String {
            switch self {
            case .desk: "Desk"
            case .floor: "Floor"
            case .zone: "Zone"
            case .startTime: "From"
            case .endTime: "Until"
            }
        }
    }

    /// `Zone`, or `Floor and zone` — what could not be read, named. A dot said
    /// only that something could not be.
    static func unreadFieldNames(_ unsureFields: [String]) -> String {
        let names = unsureFields.compactMap { Field(unsureField: $0)?.label.lowercased() }
        guard let first = names.first else { return "this booking" }
        guard names.count > 1 else { return first }
        return names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
    }

    @FocusState private var focused: Field?

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
                    .focused($focused, equals: .desk)
            }

            Section {
                TextField("Floor", text: $floor)
                    .focused($focused, equals: .floor)
                TextField("Zone", text: $zone)
                    .focused($focused, equals: .zone)
                TextField("From", text: $startTime)
                    .keyboardType(.numbersAndPunctuation)
                    .focused($focused, equals: .startTime)
                TextField("Until", text: $endTime)
                    .keyboardType(.numbersAndPunctuation)
                    .focused($focused, equals: .endTime)
            } header: {
                Text("Optional")
            } footer: {
                Text(unread.isEmpty
                     ? "A field left blank is stored as absent, not as unreadable — it will not be flagged for checking."
                     : "\(Self.unreadFieldNames(unread).prefix(1).uppercased())\(Self.unreadFieldNames(unread).dropFirst()) could not be read from the image, so nothing was stored — it was never guessed at.")
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
                // Straight into the field the capture could not read. Only the
                // first: a keyboard opening on a screen the user has not
                // finished looking at is worth it for one obvious next action
                // and no more.
                focused = unread.compactMap(Field.init(unsureField:)).first
            } else if offices.count == 1 {
                officeID = offices.first?.id
            }
        }
    }

    private var unread: [String] { booking?.unsureFields ?? [] }

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
        // An edit cannot upsert in place — the merge would find the very row
        // being edited and merge it with itself — so it goes through
        // `replace`, which deletes first and carries across everything the
        // candidate does not describe.
        if let booking {
            try? BookingStore.replace(booking, with: candidate, in: context)
        } else {
            try? BookingStore.upsert(candidate, in: context)
        }
        dismiss()
    }

    /// Through the store, not straight at the context: the attendance row for
    /// this day holds the booking's id, and deleting the row out from under it
    /// leaves that pointing at nothing. `BookingStore.delete` clears the link
    /// and keeps the day, which is the whole rule — you can be somewhere
    /// without a desk still being reserved for you.
    ///
    /// This dismiss only pops back to the detail screen. That screen sees the
    /// booking has gone and dismisses in turn, which is what carries the user
    /// out to the list.
    private func delete() {
        guard let booking else { return }
        try? BookingStore.delete(booking, in: context)
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
