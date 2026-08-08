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
                Text("The address and postcode are looked up together, once, when you save — so the perimeter still works with no signal. The postcode is its own field because a UK one locates a building on its own; where it does not, leave it out and let the address do the work.")
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
                    Text("What the booking system calls this building. Remembered from the last time a capture asked which office it was, so it does not ask again — delete one to be asked afresh.")
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
            Text("Its desk bookings stay, and the days you worked there still count toward the month — but neither will name an office any more. Days planned there are removed.")
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

    /// One swatch, as the picker draws and announces it.
    ///
    /// A value rather than three expressions inside the `ForEach` because what
    /// this control says out loud is the part of it that was wrong, and a
    /// `View` cannot be asked what it said. The colour is not decoration: the
    /// dot is the only thing that tells a London booking from a Brussels one in
    /// the list and in the split bar. Six buttons all announcing "Office
    /// colour" therefore made the one control that assigns that meaning
    /// unusable without sight — you could hear that there were six and not
    /// which was which, nor which one you were on.
    nonisolated struct Swatch: Identifiable, Equatable, Sendable {
        var hex: String
        /// Another office is already wearing it, so it is dimmed and disabled.
        var isTaken: Bool
        var isSelected: Bool

        var id: String { hex }

        var accessibilityLabel: String { colourName(hex) }

        /// Why the button will not respond. Silence here — the previous
        /// behaviour — left a disabled swatch indistinguishable from one that
        /// simply did not react to the tap.
        var accessibilityValue: String {
            isTaken ? "Already used by another office" : ""
        }
    }

    /// The six, in the palette's own order, each knowing whether it is free and
    /// whether it is the one this office is wearing.
    ///
    /// Selection is left to the `.isSelected` trait rather than folded into the
    /// label. The ring the picker draws is the sighted version of exactly that,
    /// and saying "selected" inside the label would have VoiceOver read it as
    /// part of the colour's name.
    nonisolated static func swatches(taken: [String], selected: String) -> [Swatch] {
        OfficeColours.palette.map { hex in
            Swatch(
                hex: hex,
                isTaken: isTaken(hex, by: taken),
                // Folded, like every other comparison of a stored hex: an
                // office wearing a lower-cased indigo from an older store would
                // otherwise have no swatch ringed at all, and the picker would
                // look as though it had no colour set.
                isSelected: hex.caseInsensitiveCompare(selected) == .orderedSame
            )
        }
    }

    /// What to call each of the six, in the palette's own order.
    ///
    /// Here rather than beside the palette because this is the only place in
    /// the app that has to say a colour out loud — `OfficeDot` draws it and
    /// names the office instead. If a second caller ever needs these, they
    /// belong in `OfficeColours` next to the hexes they describe, so the two
    /// lists cannot drift apart.
    nonisolated static func colourName(_ hex: String) -> String {
        let names = ["Teal", "Indigo", "Amber", "Purple", "Green", "Red"]
        guard let index = OfficeColours.palette.firstIndex(where: {
            $0.caseInsensitiveCompare(hex) == .orderedSame
        }), index < names.count else {
            // Not reachable from this picker, which only ever offers the six.
            // It is reachable from a stored office written by a version whose
            // palette had a seventh colour in it, and an unnamed swatch that
            // announces nothing at all is worse than one that admits it does
            // not know the name.
            return "Custom colour"
        }
        return names[index]
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

    /// What deleting an office comes to, and the last of this screen's
    /// swallowed writes.
    ///
    /// A `static` taking its store call, for the same reason `applySave` is
    /// one: the branch worth the most here is the one that only runs when the
    /// store refuses, and SwiftData cannot be asked to refuse on demand.
    ///
    /// The failure it exists for is the worst on this screen. `removeOffice`
    /// deletes the office's planned days, arrival alerts and bookings *before*
    /// it saves, so a throw leaves every one of those deletions sitting in the
    /// context. The old `_ = try?` then dismissed, and the next successful save
    /// anywhere in the app committed the lot — the office back in the list with
    /// its bookings quietly gone.
    ///
    /// Rolled back rather than reported and left, unlike `applySave`: there the
    /// pending change is what the user typed and is still looking at, so
    /// discarding it would throw their work away. Here it is a deletion they
    /// have just been told did not happen, and leaving it armed is how it
    /// happens anyway.
    static func applyDelete(
        _ office: Office,
        in context: ModelContext,
        remove: (Office, ModelContext) throws -> Removal = { try removeOffice($0, in: $1) }
    ) -> Deleted {
        let name = office.name
        do {
            // The count of what was stranded is for the tests, not for here.
            _ = try remove(office, context)
            return .removed
        } catch {
            context.rollback()
            return .failed(
                "\(name) couldn't be deleted: \(error.localizedDescription). Nothing was removed."
            )
        }
    }

    nonisolated enum Deleted: Equatable, Sendable {
        case removed
        /// Not deleted, and nothing of it removed either. The sentence is what
        /// the user is told.
        case failed(String)
    }

    // MARK: Rules

    /// Whether Save is offered.
    ///
    /// A name and nothing else, because a name is the only field the rest of
    /// the app cannot do without: the offices list, the booking row and the
    /// arrival alert all print it, and a blank one leaves a row you cannot tell
    /// from the next. Everything else is allowed to be missing — an address the
    /// geocoder never sees still gives an office you can file bookings against.
    ///
    /// Newlines count as blank alongside spaces. A `TextField` submits on
    /// return so one cannot be typed, but it can be pasted, and a name of "\n"
    /// passes an emptiness check that only trims spaces and then renders as a
    /// blank row everywhere in the app. `Geocoding.query` already trims the
    /// wider set, so this was the odd one out.
    ///
    /// `saving` closes the door for the duration of the geocode, which is a
    /// network round trip and therefore long enough to tap Save again. Without
    /// it the second tap starts a second `applySave` while `created` is still
    /// nil, and the user gets two offices for one building — each with its own
    /// colour and its own perimeter.
    ///
    /// Deliberately no duplicate-name rule. Two offices may honestly share a
    /// name, the colour rule already keeps them apart on screen, and
    /// `OfficeMatcher` answers an ambiguous name by asking rather than by
    /// misfiling — so the cost of allowing it is a question, while the cost of
    /// refusing it is a Save button that is dead with no explanation.
    nonisolated static func canSave(name: String, saving: Bool) -> Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !saving
    }

    /// The perimeter to work with, held inside the range the stepper offers.
    ///
    /// The `in: 20...500` on the `Stepper` bounds what its two buttons can
    /// reach; it does nothing to a value that arrives already outside them.
    /// This screen is the only writer of `radiusMetres`, so the only way out of
    /// range is a store written by another version of the app — and the editor
    /// would then read that value, show "Perimeter · 0m", and write it straight
    /// back on save, for ever. A radius of 0 is a perimeter that is never
    /// crossed, so the arrival alert simply stops existing while the settings
    /// row goes on saying it is on; a negative one is not a shape
    /// `CLCircularRegion` is defined for at all.
    ///
    /// Clamped rather than refused: an office is not worth blocking over a
    /// number the user never typed and cannot see the origin of.
    nonisolated static func perimeter(_ metres: Double) -> Double {
        // NaN first and by itself. `min`/`max` propagate it rather than
        // clamping it, so a NaN radius would sail through both and reach
        // CoreLocation intact.
        guard metres.isFinite else { return 50 }
        return min(max(metres, 20), 500)
    }

    /// Colours already spoken for, as seen from the office being edited.
    ///
    /// `excluding` is the office's own id, not a flag: an office keeps its own
    /// colour, and a picker that greyed out the swatch the office is already
    /// wearing would make its current colour the one thing it could not be.
    /// Nil while adding, when every other office's colour is taken.
    static func takenColours(among offices: [Office], excluding id: UUID?) -> [String] {
        offices.filter { $0.id != id }.map(\.colourHex)
    }

    /// Whether a swatch is already another office's.
    ///
    /// Compared case-insensitively because the palette's hexes are upper-case
    /// and a store written by an older build holds lower-case ones —
    /// `OfficeColours.next` folds case for the same reason. A byte comparison
    /// would offer "#5856D6" as free to a second office while the first was
    /// wearing "#5856d6", and two offices in the same indigo make the dot
    /// beside a booking decorative rather than informative.
    nonisolated static func isTaken(_ hex: String, by taken: [String]) -> Bool {
        taken.contains { $0.caseInsensitiveCompare(hex) == .orderedSame }
    }

    /// The stored coordinates, as the Location section prints them.
    ///
    /// Four decimal places is about eleven metres — finer than the smallest
    /// perimeter on offer, and coarse enough that the line is readable. Printed
    /// at all because it is the only confirmation anywhere in the app that the
    /// geocoder found the building the user meant, and a pair a few degrees out
    /// is the difference between the alert firing and never firing again.
    nonisolated static func coordinatesText(latitude: Double, longitude: Double) -> String {
        String(format: "%.4f, %.4f", latitude, longitude)
    }

    // MARK: Saving

    /// Everything the form holds, as values.
    ///
    /// A struct rather than eight arguments so that what a save consists of is
    /// one thing that can be handed about — and so the rule below can be run
    /// against a real store with no screen around it. The geocode is the reason
    /// it has to be: it is the one step in this screen that can fail, the
    /// failure is a normal answer rather than an error, and every consequence
    /// of it — the office saving anyway, the alert, the second Save correcting
    /// the first — was unreachable while the whole thing lived in a `View`.
    nonisolated struct Draft: Equatable, Sendable {
        var name: String
        var address: String
        var postcode: String
        var colourHex: String
        var radius: Double
        var alertEnabled: Bool
        /// The alias rows as the list shows them now, and as it showed them
        /// when the screen opened. The difference between the two is the only
        /// part of the list this screen is entitled to write — see
        /// `mergedAliases`.
        var aliases: [String]
        var loadedAliases: [String]
    }

    /// What the save left the user looking at.
    nonisolated enum Outcome: Equatable, Sendable {
        /// Written, and there is nothing further to say about it.
        case saved
        /// Written, but the geocoder could not place it and the alert was asked
        /// for — so the screen stays up and says so.
        case couldNotLocate
        /// Not written. The store would not take it, and the sentence is what
        /// the user is told.
        ///
        /// A case of its own rather than a flag on `couldNotLocate`, because
        /// the two are opposite claims about whether the office exists: one is
        /// a building in the list that cannot be watched, the other is no
        /// building at all. Conflating them would send someone to correct an
        /// address on a row that was never written.
        case failed(String)
    }

    /// The row that was written, and what it left the user looking at. The
    /// office comes back because the screen has to hold on to it: it is what a
    /// second Save corrects, and what the alias section redraws from.
    struct Saved {
        var office: Office
        var outcome: Outcome
    }

    /// Write the form to the store, geocoding if there is any point, and say
    /// which of the two ways it ended.
    ///
    /// `editing` is the row to correct, or nil to insert one. It is the
    /// screen's `office ?? created`, not its `office`: after a first save that
    /// could not be located the user is still on this screen looking at the
    /// alert, and a second Save has to correct the office the first one wrote
    /// rather than put a second building beside it.
    ///
    /// The geocoder is a parameter for the obvious reason — a test cannot ask
    /// Apple where a street is, and the two answers it can give are the whole
    /// of what this function decides between.
    ///
    /// The save is a parameter for the same reason and a worse one: a disk that
    /// will not take the write is not a state SwiftData can be asked to enter,
    /// so the branch that reports it was unreachable and therefore untested.
    /// This line was `try? context.save()`, which read a store that refused the
    /// office exactly as it read one that took it.
    static func applySave(
        _ draft: Draft,
        to editing: Office?,
        in context: ModelContext,
        geocode: @MainActor (_ postcode: String, _ address: String) async
            -> CLLocationCoordinate2D? = { await Geocoding.coordinates(postcode: $0, address: $1) },
        save: @MainActor (ModelContext) throws -> Void = { try $0.save() }
    ) async -> Saved {
        // Read before anything is written. When editing, `target` *is* the
        // stored office, so comparing the two afterwards compares a value with
        // itself and always says nothing changed — which is why correcting an
        // address on an already-located office never re-geocoded it.
        let before = editing.map { [$0.postcode, $0.address] }

        let target = editing ?? Office(
            name: "", address: "", postcode: "", colourHex: draft.colourHex
        )
        target.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        target.address = draft.address.trimmingCharacters(in: .whitespacesAndNewlines)
        target.postcode = draft.postcode.trimmingCharacters(in: .whitespacesAndNewlines)
        target.colourHex = draft.colourHex
        target.radiusMetres = perimeter(draft.radius)
        target.alertEnabled = draft.alertEnabled
        // The user's deletions only, applied to whatever the store holds now —
        // never the screen's snapshot written back whole. See `mergedAliases`
        // for why this one field cannot be treated like the others.
        target.aliases = mergedAliases(
            stored: target.aliases, onScreen: draft.aliases, loaded: draft.loadedAliases
        )

        // Only when the address has actually changed, or while there is still
        // nowhere to draw a perimeter. A geocode is a network round trip and
        // coordinates do not rot.
        if before != [target.postcode, target.address] || !target.isLocated {
            if let point = await geocode(target.postcode, target.address) {
                target.latitude = point.latitude
                target.longitude = point.longitude
            }
        }

        if editing == nil { context.insert(target) }
        do {
            try save(context)
        } catch {
            // Reported ahead of `couldNotLocate` when both went wrong. An
            // office that was never written cannot honestly be called saved but
            // unlocatable, and that alert would send the user off to correct an
            // address on a row that does not exist.
            //
            // The pending row is deliberately left in the context rather than
            // rolled back. `rollback()` would discard every other unsaved
            // change on the main context, and it would hand the screen back a
            // model that is no longer registered — `created`, the alias section
            // and the Location section all read it — so instead the row stays
            // pending and the second Save the alert asks for corrects it rather
            // than inserting a twin beside it.
            return Saved(
                office: target,
                outcome: .failed(
                    saveFailure(name: target.name, isNew: editing == nil, error: error)
                )
            )
        }

        // The office saves either way — one the geocoder cannot place is still
        // an office, it just cannot be monitored. But it is worth saying so now
        // rather than leaving it to be inferred from a line in the list a week
        // later, and only when the alert was actually asked for: an office with
        // the alert off does not need coordinates at all.
        return Saved(
            office: target,
            outcome: draft.alertEnabled && !target.isLocated ? .couldNotLocate : .saved
        )
    }

    /// What the user is told when the write did not reach the store.
    ///
    /// It names the office, because this alert can arrive over a form that has
    /// been open long enough for the user to have forgotten which building they
    /// were on, and it repeats the store's own reason, because "could not be
    /// saved" on its own gives them nothing to act on — a full disk is
    /// something they can fix.
    ///
    /// The two halves differ because what was lost differs. An office that was
    /// being added is simply not there, and the user finds that out by looking
    /// at the list. An office that was being corrected is still in the list
    /// wearing its old address, which is the more dangerous of the two: the
    /// perimeter goes on watching the old building and the arrival alert goes
    /// on firing there, so the sentence has to say so rather than leave it to
    /// be discovered a week later at the wrong front door.
    nonisolated static func saveFailure(name: String, isNew: Bool, error: Error) -> String {
        let reason = sentence(error.localizedDescription)
        return isNew
            ? "\(name) could not be saved: \(reason) It is not in your offices — try Save again."
            : "The changes to \(name) could not be saved: \(reason) The stored office is still as it was, so the arrival alert is still watching the old address — try Save again."
    }

    /// The store's reason, ended so that what follows it reads as a new
    /// sentence rather than running into it.
    ///
    /// `localizedDescription` usually ends in a full stop and is not obliged
    /// to. Appending one unconditionally gives "The disk is full.. It is not in
    /// your offices"; appending none gives one sentence that runs on through
    /// the advice. An empty description gets a sentence of its own, so the
    /// colon above is never followed by nothing.
    private nonisolated static func sentence(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last else { return "No reason was given." }
        return ".!?".contains(last) ? trimmed : trimmed + "."
    }

    /// The alias list to write back: whatever the store holds now, minus the
    /// rows the user swiped away on this screen.
    ///
    /// Every other field here is a straight read-modify-write, and for every
    /// other field that is right — this screen is their only writer. Aliases
    /// have a second one. Answering the capture sheet's "Which office is …?"
    /// appends the printed name to the office it names and saves, and that
    /// sheet is presented from the window's root, so it covers whatever is
    /// pushed — a screenshot shared into the app opens it without the editor
    /// being touched at all. Writing the screen's snapshot back whole therefore
    /// discarded an answer the user had just given, and the next capture of the
    /// same document asked the same question again, which is the one thing the
    /// alias mechanism exists to prevent.
    ///
    /// Deletions are matched by exact string rather than through
    /// `OfficeMatcher.matches`. The looser comparison would also strike out a
    /// differently-printed name for the same building, and `remember` already
    /// refuses to add one the office holds an equivalent of — so the list
    /// cannot hold two token-equal names, and loose matching could only ever
    /// remove something the user did not point at.
    nonisolated static func mergedAliases(
        stored: [String], onScreen: [String], loaded: [String]
    ) -> [String] {
        let removed = Set(loaded).subtracting(onScreen)
        return stored.filter { !removed.contains($0) }
    }

    /// What deleting an office did to the rows that pointed at it. Returned so
    /// the rule can be asserted on rather than inferred from four fetches.
    nonisolated struct Removal: Equatable, Sendable {
        var plannedDaysDeleted: Int
        var arrivalAlertsDeleted: Int
        var attendanceDaysUnlinked: Int
        var bookingsKept: Int
    }

    /// Delete an office and settle the rows that named it.
    ///
    /// Entities point at each other by UUID rather than through SwiftData
    /// relationships, so there is nothing to cascade or nullify: deleting the
    /// `Office` row on its own left four models holding an id that resolves to
    /// nothing, and two of those four are counted. `QuotaService` filters
    /// attendance and planned days by month and not by office, so the gauge
    /// went on counting a deleted building's days while `HomeScreen`'s split
    /// bar — which maps over the offices that still exist — quietly dropped
    /// them, and the two figures in the same card stopped adding up.
    ///
    /// Each of the four gets the answer it deserves rather than one blanket
    /// rule:
    ///
    /// - `AttendanceDay` is unlinked, not deleted. It is the only record that a
    ///   day was ever worked on prem and there is no other copy of it, so
    ///   deleting a building must not delete the days. `officeID` is already
    ///   optional, for the day you turn up somewhere unrecorded, and that is
    ///   what this now is.
    /// - `PlannedDay` is deleted. Its `officeID` is not optional so it cannot be
    ///   unlinked, and an intention to be at a building the user has just
    ///   removed is not an intention the forecast should keep counting.
    /// - `ArrivalAlert` is deleted. It is only the ledger of what this office's
    ///   perimeter has already said today, and there is no perimeter now.
    /// - `DeskBooking` is kept and left pointing nowhere, which is what the
    ///   confirmation dialog promises and what the row already renders as
    ///   "Unknown office".
    ///
    /// A static function taking its context, so the rule can be tested without
    /// the screen around it. Its natural home is `BookingStore`, beside the
    /// other mutators that end in one explicit save.
    @discardableResult
    static func removeOffice(_ office: Office, in context: ModelContext) throws -> Removal {
        let id = office.id
        // Fetched whole and filtered in memory, as `QuotaService` and
        // `CaptureCoordinator.remember` already do. `Models.swift` says why:
        // only primitive stored properties work reliably inside `#Predicate`,
        // and a month's rows for six offices is not a scan worth the risk.
        let planned = try context.fetch(FetchDescriptor<PlannedDay>())
            .filter { $0.officeID == id }
        let alerts = try context.fetch(FetchDescriptor<ArrivalAlert>())
            .filter { $0.officeID == id }
        let attendance = try context.fetch(FetchDescriptor<AttendanceDay>())
            .filter { $0.officeID == id }
        let bookings = try context.fetch(FetchDescriptor<DeskBooking>())
            .filter { $0.officeID == id }

        for row in planned { context.delete(row) }
        for row in alerts { context.delete(row) }
        for row in attendance { row.officeID = nil }
        context.delete(office)
        // One save for the whole thing. A save per model would leave the store
        // holding an office whose planned days had already gone if the second
        // one failed.
        try context.save()

        return Removal(
            plannedDaysDeleted: planned.count,
            arrivalAlertsDeleted: alerts.count,
            attendanceDaysUnlinked: attendance.count,
            bookingsKept: bookings.count
        )
    }
}

#Preview("Add") {
    // The monitor comes from the app's root in the real thing. Supplied here
    // because saving reads it, and an environment lookup that finds nothing is
    // a crash rather than a no-op — a preview that dies on Save would be a
    // worse way to learn that than this line is to read.
    let container = try! Store.makeInMemoryContainer(seeded: true)
    let context = container.mainContext
    return NavigationStack { OfficeEditorScreen() }
        .modelContainer(container)
        .environment(ArrivalMonitor(ledger: ArrivalLedger(context: context), context: context))
}
