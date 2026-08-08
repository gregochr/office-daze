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

    /// Everything the form holds, as one value.
    ///
    /// It exists so "what does this editor open showing?" is a question with an
    /// answer, asked of a function rather than of a rendered screen. The
    /// pre-fill was seven assignments inside a `.task` before, which is seven
    /// chances to read the wrong field off the booking and no way to notice.
    struct Draft: Equatable {
        var officeID: UUID?
        var date: Date
        var deskID: String = ""
        var floor: String = ""
        var zone: String = ""
        var startTime: String = ""
        var endTime: String = ""
        /// The field the cursor lands in, or nil to leave the keyboard down.
        var focused: Field?
    }

    /// What the editor opens showing.
    ///
    /// Editing shows the booking. Adding shows today, and picks the office only
    /// when there is exactly one — offering a default among several would put a
    /// building in the form that the user never chose, and Save is enabled the
    /// moment a desk is typed.
    static func draft(
        for booking: DeskBooking?,
        offices: [Office],
        today: Day = .today,
        in timeZone: TimeZone = .autoupdatingCurrent
    ) -> Draft {
        guard let booking else {
            return Draft(
                officeID: offices.count == 1 ? offices.first?.id : nil,
                date: today.localNoon(in: timeZone)
            )
        }
        return Draft(
            officeID: booking.officeID,
            date: booking.day.localNoon(in: timeZone),
            deskID: booking.deskID,
            floor: booking.floor ?? "",
            zone: booking.zone ?? "",
            startTime: booking.startTime ?? "",
            endTime: booking.endTime ?? "",
            // Straight into the field the capture could not read. Only the
            // first: a keyboard opening on a screen the user has not
            // finished looking at is worth it for one obvious next action
            // and no more.
            focused: initialFocus(booking.unsureFields)
        )
    }

    /// The first unread field the editor knows how to put a cursor in.
    ///
    /// `compactMap` before `first`, not `first` then `map`: a name the model
    /// emitted that this screen has no field for — a schema that grew a key
    /// while the editor did not — must be stepped over rather than swallow the
    /// focus, or the amber marker leads to a keyboard on nothing.
    static func initialFocus(_ unsureFields: [String]) -> Field? {
        unsureFields.compactMap(Field.init(unsureField:)).first
    }

    @FocusState private var focused: Field?

    @State private var officeID: UUID?
    /// `localNoon` rather than `startOfDayUTC`: the picker below renders this
    /// instant in the device's zone, and midnight UTC on the 5th is the
    /// evening of the 4th anywhere west of Greenwich.
    @State private var date = Day.today.localNoon()
    @State private var deskID = ""
    @State private var floor = ""
    @State private var zone = ""
    @State private var startTime = ""
    @State private var endTime = ""
    @State private var loaded = false
    /// Set only by a write that did not land. Non-nil holds the screen open.
    @State private var failure: String?

    private var isNew: Bool { booking == nil }

    /// An office and a desk. Everything else on this form is optional by
    /// design, and a booking with no desk number is not a booking — it is the
    /// thing `AttendanceDay` exists to be instead.
    static func canSave(officeID: UUID?, deskID: String) -> Bool {
        officeID != nil && !deskID.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var canSave: Bool { Self.canSave(officeID: officeID, deskID: deskID) }

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
        // Stays open behind the alert. The whole point of not dismissing on a
        // failed write is that everything typed is still on screen when the
        // user taps Save again.
        .alert(
            "Not saved",
            isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(failure ?? "")
        }
        .task {
            guard !loaded else { return }
            loaded = true
            let draft = Self.draft(for: booking, offices: offices)
            officeID = draft.officeID
            date = draft.date
            deskID = draft.deskID
            floor = draft.floor
            zone = draft.zone
            startTime = draft.startTime
            endTime = draft.endTime
            focused = draft.focused
        }
    }

    private var unread: [String] { booking?.unsureFields ?? [] }

    /// What the form's contents mean as a booking.
    ///
    /// A blank field is an absence, not an unreadable one: nothing typed by
    /// hand is ever flagged for checking, because the person typing knows what
    /// they left out. That is why `unsureFields` leaves empty regardless of
    /// what the booking arrived carrying — editing a capture's amber row is
    /// precisely the act of answering it.
    static func candidate(
        officeID: UUID,
        date: Date,
        deskID: String,
        floor: String,
        zone: String,
        startTime: String,
        endTime: String,
        in timeZone: TimeZone = .autoupdatingCurrent
    ) -> BookingMerge.Candidate {
        BookingMerge.Candidate(
            officeID: officeID,
            day: Day(localOf: date, in: timeZone),
            deskID: deskID.trimmingCharacters(in: .whitespaces),
            floor: floor.blankAsNil,
            zone: zone.blankAsNil,
            startTime: startTime.blankAsNil,
            endTime: endTime.blankAsNil,
            source: .manual,
            unsureFields: []
        )
    }

    /// A write the screen made, and the only thing that decides whether it may
    /// close.
    enum Outcome: Equatable {
        case written
        case failed(String)

        /// The screen closes on a write that landed and on nothing else.
        var mayDismiss: Bool { self == .written }

        var message: String? {
            if case .failed(let why) = self { return why }
            return nil
        }
    }

    /// Saves, and says whether the screen may close.
    ///
    /// The store call arrives as a closure because the branch this exists to
    /// get right is the one SwiftData will not take on request: a refused
    /// write. It used to be spelled `try?` followed by an unconditional
    /// `dismiss()`, which meant a full disk or a refused save closed the editor
    /// exactly as a successful one did — the user watched the screen slide
    /// away, believed the desk was booked, and found out at the next launch, or
    /// on the day, standing in an office with no desk.
    static func save(
        _ candidate: BookingMerge.Candidate,
        through write: (BookingMerge.Candidate) throws -> Void
    ) -> Outcome {
        do {
            try write(candidate)
            return .written
        } catch {
            return .failed(
                "That booking couldn't be saved: \(error.localizedDescription). "
                + "Nothing was recorded for \(candidate.day.dayAndMonth) — what you typed is still here, so Save can be tried again."
            )
        }
    }

    /// The same rule for the other write. Its own message because the two
    /// failures leave the store in opposite states, and telling someone their
    /// deletion failed with the word "saved" is worse than saying nothing.
    static func delete(through remove: () throws -> Void) -> Outcome {
        do {
            try remove()
            return .written
        } catch {
            return .failed(
                "That booking couldn't be deleted: \(error.localizedDescription). It is still there."
            )
        }
    }

    private func save() {
        guard let officeID else { return }
        let candidate = Self.candidate(
            officeID: officeID,
            date: date,
            deskID: deskID,
            floor: floor,
            zone: zone,
            startTime: startTime,
            endTime: endTime
        )
        // An edit cannot upsert in place — the merge would find the very row
        // being edited and merge it with itself — so it goes through
        // `replace`, which deletes first and carries across everything the
        // candidate does not describe. The answer to "were you there?" is one
        // of those things; it is carried there, not here.
        let outcome = Self.save(candidate) { candidate in
            if let booking {
                try BookingStore.replace(booking, with: candidate, in: context)
            } else {
                try BookingStore.upsert(candidate, in: context)
            }
        }
        if outcome.mayDismiss { dismiss() } else { failure = outcome.message }
    }

    /// Through the store, not straight at the context: the attendance row for
    /// this day holds the booking's id, and deleting the row out from under it
    /// leaves that pointing at nothing. `BookingStore.delete` clears the link
    /// and keeps the day, which is the whole rule — you can be somewhere
    /// without a desk still being reserved for you.
    ///
    /// This dismiss only pops back to the detail screen. That screen sees the
    /// booking has gone and dismisses in turn, which is what carries the user
    /// out to the list. It is also why a failed delete must not dismiss: the
    /// detail screen would find the booking still there and stay, leaving the
    /// user on a screen they had just watched a Delete tap apparently work on.
    private func delete() {
        guard let booking else { return }
        let outcome = Self.delete {
            try BookingStore.delete(booking, in: context)
        }
        if outcome.mayDismiss { dismiss() } else { failure = outcome.message }
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
