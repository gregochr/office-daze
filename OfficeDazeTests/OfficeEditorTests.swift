import CoreLocation
import Foundation
import SwiftData
import SwiftUI
import Testing
import UIKit
@testable import OfficeDaze

/// The office editor is a form, and a form is not what is worth testing about
/// it. What is worth testing is the three rules it applies on the way out: what
/// an alias list means when two things write it, what deleting a building does
/// to the days recorded against it, and what a swatch is called out loud. All
/// three lived inside a view with no coverage at all, which is how they came to
/// be wrong.
@Suite("The office editor's rules")
@MainActor
struct OfficeEditorTests {

    let container: ModelContainer

    init() throws {
        container = try Store.makeInMemoryContainer(seeded: true)
    }

    private func office(_ id: UUID) throws -> Office {
        try #require(
            try container.mainContext.fetch(FetchDescriptor<Office>()).first { $0.id == id }
        )
    }

    // MARK: Aliases

    /// The bug this rule exists for. The editor loads an empty alias list, a
    /// shared screenshot opens the capture sheet over it, the user answers
    /// "which office is this?", and then taps Save on the screen underneath —
    /// which used to write its own snapshot back over the answer.
    @Test("An alias taught while the editor was open survives the editor's save")
    func aliasTaughtWhileOpenSurvives() {
        let merged = OfficeEditorScreen.mergedAliases(
            stored: ["Coleman, London"], onScreen: [], loaded: []
        )
        #expect(merged == ["Coleman, London"], "the screen had nothing to say about it")
    }

    /// The other half, and the reason the list is editable at all: deleting a
    /// row means "ask me about that name again", and it has to actually delete.
    @Test("A row the user swiped away is removed, and only that row")
    func deletionIsHonoured() {
        let merged = OfficeEditorScreen.mergedAliases(
            stored: ["Coleman, London", "03, Coleman"],
            onScreen: ["03, Coleman"],
            loaded: ["Coleman, London", "03, Coleman"]
        )
        #expect(merged == ["03, Coleman"])
    }

    /// Both at once, which is the case a whole-array write cannot express: the
    /// user deleted one name on screen while a capture added another behind it.
    @Test("A deletion and a capture's answer in the same window each stand")
    func deletionAndAdditionCoexist() {
        let merged = OfficeEditorScreen.mergedAliases(
            stored: ["Old wording", "Coleman, London"],
            onScreen: [],
            loaded: ["Old wording"]
        )
        #expect(merged == ["Coleman, London"])
    }

    /// The merge only ever removes. `CaptureCoordinator.remember` strips a name
    /// off every other office when it teaches it to one — a building name means
    /// one building — so a name that has left this office's list while the
    /// editor was open has left it on purpose, and putting it back would make
    /// both offices claim it, which the matcher reads as ambiguous and answers
    /// by asking the question again.
    @Test("An alias another office has since claimed is not put back")
    func mergeNeverResurrects() {
        let merged = OfficeEditorScreen.mergedAliases(
            stored: [], onScreen: ["Coleman, London"], loaded: ["Coleman, London"]
        )
        #expect(merged.isEmpty)
    }

    /// The same rule against a real store, in the order the two writers
    /// actually run in — and carried through to the thing the alias is for.
    @Test("The alias the sheet was told about still answers the next capture")
    func aliasSurvivesAgainstTheStore() throws {
        let context = container.mainContext
        let coleman = try office(SeedData.colemanID)
        let brussels = try office(SeedData.brusselsID)

        // The editor opens on Coleman and snapshots what it finds. Nothing is
        // swiped away on this screen, so what is on screen stays what loaded.
        let loaded = coleman.aliases
        let onScreen = loaded
        #expect(loaded.isEmpty, "the seeded offices have been asked nothing")

        // A screenshot is shared in while the editor is up. The sheet asks and
        // is told Coleman, which is what `CaptureCoordinator.remember` writes:
        // the printed name onto the office named, and off any other office.
        brussels.aliases.removeAll { OfficeMatcher.matches("Coleman, London", $0) }
        coleman.aliases.append("Coleman, London")
        try context.save()

        // The user taps Save, which is this line and nothing else.
        coleman.aliases = OfficeEditorScreen.mergedAliases(
            stored: coleman.aliases, onScreen: onScreen, loaded: loaded
        )
        try context.save()

        let stored = try office(SeedData.colemanID)
        #expect(stored.aliases == ["Coleman, London"])
        #expect(try office(SeedData.brusselsID).aliases.isEmpty, "one name, one building")

        // And the point of all of it: the next capture of the same document
        // does not ask again.
        let candidates = try context.fetch(FetchDescriptor<Office>()).map {
            OfficeMatcher.Candidate(
                id: $0.id, name: $0.name, postcode: $0.postcode,
                address: $0.address, aliases: $0.aliases
            )
        }
        #expect(
            OfficeMatcher.match("Coleman, London", against: candidates)?.id
                == SeedData.colemanID
        )
    }

    // MARK: Deleting an office

    /// Nothing cascades — the models point at each other by UUID — so every row
    /// that named the office has to be dealt with by hand. The one that must
    /// not be deleted is attendance: it is the only record that a day was ever
    /// worked on prem, and the gauge counts it whether the building still
    /// exists or not.
    @Test("Deleting an office keeps the days worked there and stops them naming it")
    func deletingUnlinksAttendance() throws {
        let context = container.mainContext
        let brussels = try office(SeedData.brusselsID)

        // A day planned at each office, and an alert already delivered at each.
        context.insert(PlannedDay(day: Day(2026, 8, 20), officeID: SeedData.brusselsID))
        context.insert(PlannedDay(day: Day(2026, 8, 21), officeID: SeedData.colemanID))
        context.insert(ArrivalAlert(
            day: Day(2026, 8, 4), officeID: SeedData.brusselsID, deliveredAt: .now
        ))
        context.insert(ArrivalAlert(
            day: Day(2026, 8, 5), officeID: SeedData.colemanID, deliveredAt: .now
        ))
        try context.save()

        let attendedBefore = try QuotaService.snapshot(
            for: SeedData.month, today: Day(2026, 8, 13), in: context
        ).result.attended

        let removal = try OfficeEditorScreen.removeOffice(brussels, in: context)

        // What it says it did, per model. Brussels has one of each in the seed.
        #expect(removal == OfficeEditorScreen.Removal(
            plannedDaysDeleted: 1,
            arrivalAlertsDeleted: 1,
            attendanceDaysUnlinked: 1,
            bookingsKept: 1
        ))

        #expect(try context.fetchCount(FetchDescriptor<Office>()) == 1)

        // The day worked at Brussels on the 4th stands, and no longer claims a
        // building that is not there.
        let attendance = try context.fetch(FetchDescriptor<AttendanceDay>())
        #expect(attendance.count == 4, "no day worked is deleted with the building")
        let fourth = try #require(attendance.first { $0.day == Day(2026, 8, 4) })
        #expect(fourth.officeID == nil)

        // The gauge and the bar under it: the total is untouched, and the bar
        // no longer has a share to draw for an office that is gone.
        let after = try QuotaService.snapshot(
            for: SeedData.month, today: Day(2026, 8, 13), in: context
        )
        #expect(after.result.attended == attendedBefore)
        #expect(after.attendedByOffice[SeedData.brusselsID] == nil)
        #expect(after.attendedByOffice[SeedData.colemanID] == 3, "Coleman's days are its own")
    }

    /// The dialog promises the desk bookings stay; the days planned there do
    /// not, because `PlannedDay.officeID` cannot be unlinked and a day intended
    /// at a deleted building would go on inflating the forecast while rendering
    /// as no office at all.
    @Test("Deleting an office keeps its bookings and drops what was planned there")
    func deletingKeepsBookingsAndDropsPlans() throws {
        let context = container.mainContext
        context.insert(PlannedDay(day: Day(2026, 8, 20), officeID: SeedData.brusselsID))
        try context.save()

        let forecastBefore = try QuotaService.snapshot(
            for: SeedData.month, today: Day(2026, 8, 13), in: context
        ).result.forecast

        try OfficeEditorScreen.removeOffice(try office(SeedData.brusselsID), in: context)

        let bookings = try context.fetch(FetchDescriptor<DeskBooking>())
        #expect(bookings.count == 4, "a desk reserved is still a desk reserved")
        #expect(
            bookings.contains { $0.officeID == SeedData.brusselsID },
            "kept, pointing nowhere, which is what the row already renders"
        )
        #expect(try context.fetchCount(FetchDescriptor<PlannedDay>()) == 0)

        let after = try QuotaService.snapshot(
            for: SeedData.month, today: Day(2026, 8, 13), in: context
        )
        #expect(
            after.result.forecast < forecastBefore,
            "the day intended at a building that is gone stops being forecast"
        )
    }

    /// The negative, and the one that says the rule reads its argument: this
    /// is the office *not* being deleted, and everything of its must survive
    /// intact — the earlier version of the fix that deleted by month rather
    /// than by office would fail here and nowhere else.
    @Test("Deleting one office leaves every row belonging to the other alone")
    func deletingIsScopedToTheOffice() throws {
        let context = container.mainContext
        context.insert(PlannedDay(day: Day(2026, 8, 21), officeID: SeedData.colemanID))
        context.insert(ArrivalAlert(
            day: Day(2026, 8, 5), officeID: SeedData.colemanID, deliveredAt: .now
        ))
        try context.save()

        try OfficeEditorScreen.removeOffice(try office(SeedData.brusselsID), in: context)

        let planned = try context.fetch(FetchDescriptor<PlannedDay>())
        #expect(planned.map(\.officeID) == [SeedData.colemanID])
        let alerts = try context.fetch(FetchDescriptor<ArrivalAlert>())
        #expect(alerts.map(\.officeID) == [SeedData.colemanID])

        let stillNamed = try context.fetch(FetchDescriptor<AttendanceDay>())
            .filter { $0.officeID == SeedData.colemanID }
        #expect(stillNamed.count == 3, "Coleman's days still name Coleman")
        #expect(try office(SeedData.colemanID).name == "Coleman")
    }

    /// An office nobody ever used. Nothing to strand, and the count says so
    /// rather than the caller having to trust that it looked.
    @Test("Deleting an office nothing points at reports that it touched nothing")
    func deletingAnUnusedOffice() throws {
        let context = container.mainContext
        let spare = Office(
            name: "Spare", address: "1 Nowhere", postcode: "",
            colourHex: OfficeColours.palette[2]
        )
        context.insert(spare)
        try context.save()

        let removal = try OfficeEditorScreen.removeOffice(spare, in: context)
        #expect(removal == OfficeEditorScreen.Removal(
            plannedDaysDeleted: 0, arrivalAlertsDeleted: 0,
            attendanceDaysUnlinked: 0, bookingsKept: 0
        ))
        #expect(try context.fetchCount(FetchDescriptor<Office>()) == 2, "the seeded two")
        #expect(try context.fetchCount(FetchDescriptor<AttendanceDay>()) == 4)
        #expect(try context.fetchCount(FetchDescriptor<DeskBooking>()) == 4)
    }

    // MARK: Colour names

    /// Six buttons that all announced "Office colour" made the only control
    /// that assigns an office's colour unusable without sight — and the colour
    /// is the sole channel tying a booking row to its building.
    @Test("Each of the six swatches says which colour it is, and no two agree")
    func everySwatchIsNamed() {
        let names = OfficeColours.palette.map(OfficeEditorScreen.colourName)
        #expect(names == ["Teal", "Indigo", "Amber", "Purple", "Green", "Red"])
        #expect(Set(names).count == OfficeColours.palette.count, "no two swatches sound alike")
    }

    /// Stored hexes are compared case-insensitively everywhere else — `taken`
    /// in the picker does it too — so a lower-cased hex from an older store
    /// must not fall through to the unknown-colour name.
    @Test("A colour stored in lower case is still the colour it is")
    func colourNamesIgnoreCase() {
        #expect(OfficeEditorScreen.colourName("#0a7a6e") == "Teal")
    }

    /// The negative. Anything that is not one of the six gets a name that says
    /// so, rather than an empty announcement or a hex read out digit by digit.
    @Test("A colour outside the palette says it is not one of the six")
    func unknownColoursAreNamedAsSuch() {
        #expect(OfficeEditorScreen.colourName("#123456") == "Custom colour")
        #expect(OfficeEditorScreen.colourName("") == "Custom colour")
    }

    // MARK: Which colours are still free

    /// An office keeps its own colour. Greying out the swatch the office is
    /// already wearing would make its current colour the one thing it could not
    /// be, and the ring drawn round it would sit on a disabled button.
    @Test("Editing an office sees every colour but its own as free")
    func anOfficeKeepsItsOwnColour() throws {
        let offices = try container.mainContext.fetch(FetchDescriptor<Office>())
        let seenFromColeman = OfficeEditorScreen.takenColours(
            among: offices, excluding: SeedData.colemanID
        )
        #expect(seenFromColeman == [OfficeColours.palette[1]], "Brussels' indigo, and not its own teal")
        #expect(!OfficeEditorScreen.isTaken(OfficeColours.palette[0], by: seenFromColeman))
    }

    /// Adding one: both seeded colours are spoken for, and the screen opens on
    /// the next one down the palette rather than on a twin of an existing dot.
    @Test("Adding an office sees both seeded colours taken and opens on the third")
    func addingAnOfficeSeesBothTaken() throws {
        let offices = try container.mainContext.fetch(FetchDescriptor<Office>())
        let taken = OfficeEditorScreen.takenColours(among: offices, excluding: nil)
        #expect(Set(taken) == Set(OfficeColours.palette.prefix(2)))
        #expect(OfficeColours.next(after: taken) == OfficeColours.palette[2], "amber")

        // What the picker actually asks, swatch by swatch, and what VoiceOver
        // therefore hears: two names spoken for, four free.
        let spokenFor = OfficeColours.palette
            .filter { OfficeEditorScreen.isTaken($0, by: taken) }
            .map(OfficeEditorScreen.colourName)
        #expect(spokenFor == ["Teal", "Indigo"])
    }

    /// A store written by an older build holds lower-case hexes.
    /// `OfficeColours.next` folds case; the picker's own "already used" check
    /// has to fold it too, or the second office is offered the indigo the first
    /// is wearing and the dot beside a booking stops telling them apart.
    @Test("A colour taken in lower case is still taken")
    func takenColoursIgnoreCase() {
        #expect(OfficeEditorScreen.isTaken("#5856D6", by: ["#5856d6"]))
        #expect(!OfficeEditorScreen.isTaken("#5856D6", by: ["#0a7a6e"]), "and only that one")
        #expect(!OfficeEditorScreen.isTaken("#5856D6", by: []))
    }

    // MARK: What a swatch says out loud

    /// The whole of what the picker announces, swatch by swatch, in the order
    /// it draws them. Six buttons that all said "Office colour" made the one
    /// control that assigns an office's colour unusable without sight, and a
    /// disabled swatch that said nothing at all was indistinguishable from one
    /// that had simply failed to respond to the tap.
    @Test("Every swatch names its colour, says if it is spoken for, and one is selected")
    func swatchesAnnounceThemselves() throws {
        let offices = try container.mainContext.fetch(FetchDescriptor<Office>())
        let taken = OfficeEditorScreen.takenColours(among: offices, excluding: nil)
        let swatches = OfficeEditorScreen.swatches(
            taken: taken, selected: OfficeColours.palette[2]
        )

        #expect(swatches.map(\.hex) == OfficeColours.palette, "the palette's own order")
        #expect(
            swatches.map(\.accessibilityLabel)
                == ["Teal", "Indigo", "Amber", "Purple", "Green", "Red"]
        )
        #expect(swatches.map(\.accessibilityValue) == [
            "Already used by another office", "Already used by another office",
            "", "", "", "",
        ])
        #expect(
            swatches.filter(\.isSelected).map(\.accessibilityLabel) == ["Amber"],
            "exactly one ring, and it is the colour this office is wearing"
        )
    }

    /// The negative: with nothing taken, no swatch may claim to be spoken for —
    /// a value that fired regardless of the argument would sound the same on
    /// every screen and mean nothing on any of them.
    @Test("With no other office there is nothing to say about any swatch but its name")
    func swatchesSayNothingExtraWhenEverythingIsFree() {
        let swatches = OfficeEditorScreen.swatches(
            taken: [], selected: OfficeColours.palette[0]
        )
        #expect(swatches.allSatisfy { !$0.isTaken })
        #expect(swatches.allSatisfy { $0.accessibilityValue.isEmpty })
        #expect(swatches.filter(\.isSelected).count == 1)
    }

    /// A colour the office is wearing in lower case still gets the ring. Folded
    /// here for the same reason as everywhere else a stored hex is compared —
    /// otherwise the picker shows no selection at all and looks as though the
    /// office has no colour set.
    @Test("The swatch an office is wearing is ringed whatever case it was stored in")
    func selectionIgnoresCase() {
        let swatches = OfficeEditorScreen.swatches(taken: [], selected: "#8e44ad")
        #expect(swatches.filter(\.isSelected).map(\.accessibilityLabel) == ["Purple"])
    }

    /// A colour outside the six rings nothing rather than ringing the first —
    /// the picker has no swatch for it, and a ring on a colour the office is
    /// not wearing would be a lie about what tapping Save would keep.
    @Test("An office wearing a colour outside the six has no swatch ringed")
    func aColourOutsideThePaletteRingsNothing() {
        let swatches = OfficeEditorScreen.swatches(taken: [], selected: "#123456")
        #expect(swatches.allSatisfy { !$0.isSelected })
        #expect(swatches.count == 6, "and the six are still offered")
    }

    // MARK: What Save will accept

    /// A name is the only field the app cannot do without: the offices list,
    /// the booking row and the arrival alert all print it.
    @Test("Save is dead until the office has a name, and a name is not spaces")
    func saveNeedsAName() {
        #expect(!OfficeEditorScreen.canSave(name: "", saving: false))
        #expect(!OfficeEditorScreen.canSave(name: "   ", saving: false))
        // Pasteable, if not typeable — a `TextField` submits on return. A name
        // of one newline used to pass an emptiness check that trimmed only
        // spaces, and then rendered as a blank row everywhere in the app.
        #expect(!OfficeEditorScreen.canSave(name: "\n", saving: false))
        #expect(!OfficeEditorScreen.canSave(name: " \n ", saving: false))
        #expect(OfficeEditorScreen.canSave(name: "London", saving: false))
        #expect(OfficeEditorScreen.canSave(name: "  London  ", saving: false))
    }

    /// The geocode is a network round trip, which is long enough to tap Save
    /// twice. The second tap would run while the first had not yet set
    /// `created`, so both saves would insert — two offices for one building,
    /// each with its own colour and its own perimeter.
    @Test("Save is closed for the duration of a save already running")
    func saveIsClosedWhileSaving() {
        #expect(!OfficeEditorScreen.canSave(name: "London", saving: true))
    }

    /// Deliberately allowed, and worth pinning because it looks like an
    /// oversight. Two offices may honestly share a name; the colour rule keeps
    /// them apart on screen, and the matcher's answer to an ambiguous name is
    /// to ask rather than to file the booking under the wrong building. The
    /// cost of allowing it is a question, and it is asserted here so that
    /// anyone who later adds a blocking rule can see what they are trading.
    @Test("A name another office already has is allowed, and costs a question")
    func duplicateNamesAreAllowedAndAskAgain() throws {
        #expect(OfficeEditorScreen.canSave(name: "Coleman", saving: false))

        let context = container.mainContext
        context.insert(Office(
            name: "Coleman", address: "Coleman Annexe", postcode: "",
            colourHex: OfficeColours.palette[2]
        ))
        try context.save()

        let candidates = try context.fetch(FetchDescriptor<Office>()).map {
            OfficeMatcher.Candidate(
                id: $0.id, name: $0.name, postcode: $0.postcode,
                address: $0.address, aliases: $0.aliases
            )
        }
        #expect(
            OfficeMatcher.match("Coleman", against: candidates) == nil,
            "two offices that both look right is when guessing does the most damage"
        )
        // And the office that is not ambiguous still resolves, so the cost is
        // confined to the name that was duplicated.
        #expect(
            OfficeMatcher.match("Brussels", against: candidates)?.id == SeedData.brusselsID
        )
    }

    // MARK: The perimeter the stepper cannot bound

    /// `Stepper(in: 20...500)` bounds what its buttons can reach and nothing
    /// else. A radius that arrives already outside that range — from a store
    /// written by another version — used to be read into the form, shown as
    /// "Perimeter · 0m", and written straight back on every save.
    @Test("A perimeter is held inside the range the stepper offers")
    func perimeterIsClamped() {
        #expect(OfficeEditorScreen.perimeter(0) == 20, "a perimeter never crossed is no alert at all")
        #expect(OfficeEditorScreen.perimeter(-40) == 20)
        #expect(OfficeEditorScreen.perimeter(19.9) == 20)
        #expect(OfficeEditorScreen.perimeter(900) == 500)
    }

    /// The negative, and the reason this is a function rather than one `min`
    /// inside a `max`: a radius already in range must come through untouched,
    /// or every office silently moves to 20m.
    @Test("A perimeter already in range is left exactly as it was")
    func perimeterInRangeIsUntouched() {
        #expect(OfficeEditorScreen.perimeter(20) == 20)
        #expect(OfficeEditorScreen.perimeter(50) == 50)
        #expect(OfficeEditorScreen.perimeter(275) == 275)
        #expect(OfficeEditorScreen.perimeter(500) == 500)
    }

    /// NaN propagates through both `min` and `max` rather than being clamped by
    /// either, so it would sail through the pair intact and reach CoreLocation.
    @Test("A perimeter that is not a number falls back to the default one")
    func perimeterHandlesNonsense() {
        #expect(OfficeEditorScreen.perimeter(.nan) == 50)
        #expect(OfficeEditorScreen.perimeter(.infinity) == 50)
        #expect(OfficeEditorScreen.perimeter(-.infinity) == 50)
    }

    // MARK: The one line that says the geocoder found the right building

    @Test("Coordinates print to four places, keeping the sign of a western one")
    func coordinatesArePrinted() {
        #expect(
            OfficeEditorScreen.coordinatesText(latitude: 51.5172, longitude: -0.0893)
                == "51.5172, -0.0893"
        )
        #expect(
            OfficeEditorScreen.coordinatesText(latitude: 50.856789, longitude: 4.356712)
                == "50.8568, 4.3567",
            "four places is about eleven metres — finer than the smallest perimeter"
        )
    }
}

/// A geocoder that answers only for an address it was actually given.
///
/// Keyed by the query `Geocoding.query` builds, rather than answering the same
/// coordinate to anything asked, because the whole of what `applySave` decides
/// is whether the geocoder *found the address it was handed* — a stand-in that
/// answered regardless of input would make "saved with coordinates" and "saved
/// with the wrong building's coordinates" the same test. Every ask is recorded
/// with the postcode and address that came with it, so the rule about *when*
/// the geocoder is asked at all can be asserted too.
@MainActor
final class RecordingGeocoder {

    struct Ask: Equatable {
        var postcode: String
        var address: String
    }

    /// What Apple would know, by the query it would be sent.
    var known: [String: CLLocationCoordinate2D] = [:]
    private(set) var asks: [Ask] = []

    func coordinates(postcode: String, address: String) async -> CLLocationCoordinate2D? {
        asks.append(Ask(postcode: postcode, address: address))
        guard let query = Geocoding.query(postcode: postcode, address: address) else {
            // The same answer the real one gives when there is nothing worth
            // asking about, and by the same rule.
            return nil
        }
        return known[query]
    }
}

/// Saving an office, which is the one place in this screen that can fail — and
/// where failing is a normal answer rather than an error.
@Suite("The office editor saves")
@MainActor
struct OfficeEditorSaveTests {

    let container: ModelContainer
    let geocoder = RecordingGeocoder()

    init() throws {
        container = try Store.makeInMemoryContainer(seeded: true)
    }

    private var context: ModelContext { container.mainContext }

    private func offices() throws -> [Office] {
        try context.fetch(FetchDescriptor<Office>())
    }

    private func office(_ id: UUID) throws -> Office {
        try #require(try offices().first { $0.id == id })
    }

    /// The form as a user would have left it, with only the fields a test cares
    /// about spelled out.
    private func draft(
        name: String = "Zurich",
        address: String = "Bahnhofstrasse 1",
        postcode: String = "8001",
        colourHex: String = OfficeColours.palette[2],
        radius: Double = 50,
        alertEnabled: Bool = true,
        aliases: [String] = [],
        loadedAliases: [String] = []
    ) -> OfficeEditorScreen.Draft {
        OfficeEditorScreen.Draft(
            name: name, address: address, postcode: postcode, colourHex: colourHex,
            radius: radius, alertEnabled: alertEnabled,
            aliases: aliases, loadedAliases: loadedAliases
        )
    }

    private func save(
        _ draft: OfficeEditorScreen.Draft, to editing: Office? = nil
    ) async -> OfficeEditorScreen.Saved {
        await OfficeEditorScreen.applySave(
            draft, to: editing, in: context, geocode: geocoder.coordinates
        )
    }

    // MARK: An address that resolves

    @Test("An address the geocoder can place is saved at the point it gave back")
    func aResolvedAddressIsSavedWithItsCoordinates() async throws {
        geocoder.known["8001, Bahnhofstrasse 1, Zurich"] =
            CLLocationCoordinate2D(latitude: 47.3717, longitude: 8.5390)

        let saved = await save(draft(
            name: "  Zurich  ", address: " Bahnhofstrasse 1, Zurich ", postcode: " 8001 "
        ))

        #expect(saved.outcome == .saved, "nothing to tell the user about")
        #expect(saved.office.isLocated)
        #expect(saved.office.latitude == 47.3717)
        #expect(saved.office.longitude == 8.5390)
        // Trimmed on the way in, and trimmed before the geocoder sees it — the
        // untrimmed pair would be a different query and a cache miss on Apple's
        // side for a building it already knows.
        #expect(saved.office.name == "Zurich")
        #expect(geocoder.asks == [
            RecordingGeocoder.Ask(postcode: "8001", address: "Bahnhofstrasse 1, Zurich")
        ])
        #expect(try offices().count == 3)
    }

    // MARK: An address that does not

    /// The rule the alert exists to soften: an office the geocoder cannot place
    /// is still an office. It just cannot be monitored.
    @Test("An address the geocoder cannot place is still saved, and says so")
    func anUnlocatableAddressIsStillSaved() async throws {
        let saved = await save(draft(name: "Nowhere", address: "qqzz", postcode: ""))

        #expect(saved.outcome == .couldNotLocate)
        #expect(!saved.office.isLocated, "0,0 is the Atlantic, which is the absence")
        #expect(geocoder.asks == [RecordingGeocoder.Ask(postcode: "", address: "qqzz")])

        // Written, not held back. The office is in the store with its name and
        // its colour, and a booking can be filed against it today.
        let stored = try #require(try offices().first { $0.name == "Nowhere" })
        #expect(stored.colourHex == OfficeColours.palette[2])
        #expect(try offices().count == 3)
    }

    /// The documented rule, and the reason the screen holds on to what it
    /// created: the user is still on this screen, looking at the alert, and the
    /// address they correct belongs to the office that was just written.
    @Test("A second Save after the alert corrects that office rather than adding another")
    func asecondSaveCorrectsTheSameOffice() async throws {
        let first = await save(draft(name: "Zurich", address: "Banhofstrase 1", postcode: ""))
        #expect(first.outcome == .couldNotLocate)
        let id = first.office.id

        // The user adds the city, which is exactly what the alert told them to
        // do, and taps Save again — with `editing` now the office the first
        // save created.
        geocoder.known["Bahnhofstrasse 1, Zurich"] =
            CLLocationCoordinate2D(latitude: 47.3717, longitude: 8.5390)
        let second = await save(
            draft(name: "Zurich", address: "Bahnhofstrasse 1, Zurich", postcode: ""),
            to: first.office
        )

        #expect(second.outcome == .saved)
        #expect(second.office.id == id, "the same building, corrected")
        #expect(second.office.isLocated)
        #expect(try offices().count == 3, "one office was added, not two")
        #expect(try office(id).latitude == 47.3717)

        // Both attempts went to the geocoder, and the second went with the
        // corrected address rather than the one that had already failed.
        #expect(geocoder.asks.map(\.address) == ["Banhofstrase 1", "Bahnhofstrasse 1, Zurich"])
    }

    /// The negative of the alert. An office with the arrival alert switched off
    /// does not need coordinates at all, so failing to find it is not worth
    /// stopping the user over.
    @Test("An office with the alert off is not told that it could not be found")
    func alertOffMeansNoComplaint() async throws {
        let saved = await save(draft(name: "Nowhere", address: "qqzz", alertEnabled: false))

        #expect(saved.outcome == .saved, "the screen closes")
        #expect(!saved.office.isLocated)
        #expect(!saved.office.alertEnabled)
        #expect(geocoder.asks.count == 1, "still looked up — the toggle may come back on")
    }

    /// A failed geocode on an office that already had coordinates must not
    /// clear them. The old point is stale, but a stale perimeter round the
    /// right city is worth more than none at all — and 0,0 would silently turn
    /// the alert off for good.
    @Test("A geocode that fails leaves the coordinates the office already had")
    func aFailedGeocodeKeepsTheOldPoint() async throws {
        let coleman = try office(SeedData.colemanID)
        let saved = await save(
            draft(
                name: "Coleman", address: "63 Coleman Street, Lundon",
                postcode: "EC2R 5BB", colourHex: coleman.colourHex
            ),
            to: coleman
        )

        #expect(geocoder.asks.count == 1, "it did ask — the address changed")
        #expect(saved.office.latitude == 51.5172, "and kept what it had when the answer was no")
        #expect(saved.office.longitude == -0.0893)
        #expect(saved.outcome == .saved, "still located, so there is nothing to warn about")
    }

    // MARK: When the geocoder is asked at all

    /// A geocode is a network round trip and coordinates do not rot. The bug
    /// this guards was the opposite of a saving: `target` *is* the stored
    /// office when editing, so a before/after comparison made after the write
    /// compared a value with itself and never re-geocoded anything.
    @Test("An address that has not changed is not looked up again")
    func anUnchangedAddressIsNotLookedUp() async throws {
        let coleman = try office(SeedData.colemanID)
        let saved = await save(
            draft(
                name: "Coleman", address: coleman.address, postcode: coleman.postcode,
                colourHex: OfficeColours.palette[4], radius: 200
            ),
            to: coleman
        )

        #expect(geocoder.asks.isEmpty, "only the colour and the perimeter changed")
        #expect(saved.office.latitude == 51.5172, "and the point it had is the point it has")
        #expect(saved.office.radiusMetres == 200)
        #expect(saved.office.colourHex == OfficeColours.palette[4])
    }

    @Test("A corrected address on an office that was already located is looked up again")
    func aCorrectedAddressIsLookedUpAgain() async throws {
        geocoder.known["EC2R 5BB, 63 Coleman Street, London EC2"] =
            CLLocationCoordinate2D(latitude: 51.5180, longitude: -0.0880)
        let coleman = try office(SeedData.colemanID)

        let saved = await save(
            draft(
                name: "Coleman", address: "63 Coleman Street, London EC2",
                postcode: "EC2R 5BB", colourHex: coleman.colourHex
            ),
            to: coleman
        )

        #expect(geocoder.asks == [
            RecordingGeocoder.Ask(postcode: "EC2R 5BB", address: "63 Coleman Street, London EC2")
        ])
        #expect(saved.office.latitude == 51.5180, "the perimeter moved with the address")
        #expect(saved.office.longitude == -0.0880)
    }

    /// The other half of the same condition: an office with nowhere to draw a
    /// perimeter is retried on every save, unchanged address or not, because
    /// the last failure may only have been a lost signal.
    @Test("An office that still has no coordinates is looked up again anyway")
    func anUnlocatedOfficeIsRetried() async throws {
        let first = await save(draft(name: "Zurich", address: "Bahnhofstrasse 1", postcode: ""))
        #expect(first.outcome == .couldNotLocate)

        // Nothing typed the second time. The address is the same one that
        // failed, and it is asked again all the same.
        geocoder.known["Bahnhofstrasse 1"] =
            CLLocationCoordinate2D(latitude: 47.3717, longitude: 8.5390)
        let second = await save(
            draft(name: "Zurich", address: "Bahnhofstrasse 1", postcode: ""),
            to: first.office
        )

        #expect(geocoder.asks.count == 2)
        #expect(second.outcome == .saved)
        #expect(second.office.isLocated, "the signal came back")
    }

    // MARK: The perimeter, on the way to the store

    /// The clamp, through the whole save rather than on its own: an office
    /// whose stored radius is nonsense comes out of a save with a radius the
    /// region monitor can use.
    @Test("A perimeter of nothing is saved as the smallest one on offer")
    func aZeroPerimeterIsSavedAsTheSmallest() async throws {
        let coleman = try office(SeedData.colemanID)
        let saved = await save(
            draft(
                name: "Coleman", address: coleman.address, postcode: coleman.postcode,
                colourHex: coleman.colourHex, radius: 0
            ),
            to: coleman
        )

        #expect(saved.office.radiusMetres == 20)
        #expect(try office(SeedData.colemanID).radiusMetres == 20, "and that is what the store holds")
    }

    // MARK: Aliases, through a real save

    /// The wave-2 defect, end to end this time: the capture sheet is presented
    /// over whatever is pushed, so it can teach the office a name while the
    /// editor is sitting on a snapshot of the list from before.
    @Test("An alias a capture taught mid-edit survives the save that follows it")
    func anAliasTaughtMidEditSurvives() async throws {
        let coleman = try office(SeedData.colemanID)
        // The editor opened before any of this and found nothing.
        let loaded = coleman.aliases
        #expect(loaded.isEmpty)

        // A shared screenshot, a question, an answer.
        coleman.aliases.append("Coleman, London")
        try context.save()

        let saved = await save(
            draft(
                name: "Coleman", address: coleman.address, postcode: coleman.postcode,
                colourHex: coleman.colourHex, aliases: loaded, loadedAliases: loaded
            ),
            to: coleman
        )

        #expect(saved.office.aliases == ["Coleman, London"])
        #expect(try office(SeedData.colemanID).aliases == ["Coleman, London"])
    }

    /// And the deletion still has to land, or the row the user swiped away
    /// comes back on the next save and the sheet stops asking about a name they
    /// wanted to be asked about again.
    @Test("A row swiped away in the editor is gone from the store after the save")
    func aSwipedAliasIsRemoved() async throws {
        let coleman = try office(SeedData.colemanID)
        coleman.aliases = ["Coleman, London", "03, Coleman"]
        try context.save()

        let saved = await save(
            draft(
                name: "Coleman", address: coleman.address, postcode: coleman.postcode,
                colourHex: coleman.colourHex,
                aliases: ["03, Coleman"],
                loadedAliases: ["Coleman, London", "03, Coleman"]
            ),
            to: coleman
        )

        #expect(saved.office.aliases == ["03, Coleman"])
        #expect(try office(SeedData.colemanID).aliases == ["03, Coleman"])
    }
}

/// What the editor does to the perimeters iOS is watching.
///
/// `save()` and `delete()` are each two things: the store write, tested above
/// and beside it, and one `arrival.refreshRegions()`. This suite is that pair
/// run together against a recording location manager, because the whole of the
/// wave-1 defect was that the second half was missing — and a perimeter iOS was
/// never told about looks exactly like one it is watching.
@Suite("The office editor's perimeters")
@MainActor
struct OfficeEditorRegionTests {

    let container: ModelContainer
    let manager = RecordingLocationManager()
    let monitor: ArrivalMonitor

    init() throws {
        let container = try Store.makeInMemoryContainer(seeded: true)
        let ledger = ArrivalLedger(context: container.mainContext)
        ledger.post = { _ in }
        ledger.withdraw = { _ in }
        self.container = container
        monitor = ArrivalMonitor(
            ledger: ledger, context: container.mainContext, manager: manager
        )
        // Always, reported the way iOS reports it: the manager's own status and
        // the delegate callback. This registers the two seeded offices.
        manager.authorizationStatus = .authorizedAlways
        monitor.authorizationChanged(to: .authorizedAlways)
    }

    private var context: ModelContext { container.mainContext }

    private func office(_ id: UUID) throws -> Office {
        try #require(
            try context.fetch(FetchDescriptor<Office>()).first { $0.id == id }
        )
    }

    private func draft(
        _ office: Office, radius: Double, alertEnabled: Bool = true
    ) -> OfficeEditorScreen.Draft {
        OfficeEditorScreen.Draft(
            name: office.name, address: office.address, postcode: office.postcode,
            colourHex: office.colourHex, radius: radius, alertEnabled: alertEnabled,
            aliases: office.aliases, loadedAliases: office.aliases
        )
    }

    /// The office being saved is already located and its address is unchanged,
    /// so no geocode is due — and a stand-in that answered one anyway would be
    /// asserting something this suite is not about. It records the calls all the
    /// same, so a save that unexpectedly reached for the network fails here.
    private let geocoder = RecordingGeocoder()

    @Test("Both seeded offices are watched to begin with")
    func theSeedIsWatched() {
        #expect(manager.watching == [
            SeedData.colemanID.uuidString, SeedData.brusselsID.uuidString,
        ])
    }

    /// The widened perimeter that used to stay at its old radius until the app
    /// process next started, which can be days.
    @Test("Widening a perimeter re-registers it at the radius that was saved")
    func wideningAPerimeterIsRegistered() async throws {
        let brussels = try office(SeedData.brusselsID)
        #expect(manager.perimeter(SeedData.brusselsID.uuidString)?.radius == 50)

        _ = await OfficeEditorScreen.applySave(
            draft(brussels, radius: 300), to: brussels, in: context,
            geocode: geocoder.coordinates
        )
        monitor.refreshRegions()

        let watched = try #require(manager.perimeter(SeedData.brusselsID.uuidString))
        #expect(watched.radius == 300)
        #expect(watched.latitude == 50.8568, "round the same building")
        #expect(watched.longitude == 4.3567)
        #expect(watched.notifyOnEntry && !watched.notifyOnExit)
        #expect(geocoder.asks.isEmpty, "nothing about the address changed")
    }

    /// The direction that used to go on firing: turning the alert off left iOS
    /// watching the perimeter, and the alert arrived anyway.
    @Test("Turning an office's alert off stops iOS watching it")
    func turningTheAlertOffTearsItDown() async throws {
        let brussels = try office(SeedData.brusselsID)

        _ = await OfficeEditorScreen.applySave(
            draft(brussels, radius: 50, alertEnabled: false), to: brussels,
            in: context, geocode: geocoder.coordinates
        )
        monitor.refreshRegions()

        #expect(manager.watching == [SeedData.colemanID.uuidString])
        #expect(manager.stopped.contains(SeedData.brusselsID.uuidString))
    }

    /// A new office is not watched until something asks for the rebuild, and
    /// nothing else in the app does between one cold launch and the next.
    @Test("A newly added office is watched from the moment it is saved")
    func aNewOfficeIsWatched() async throws {
        let geocoder = RecordingGeocoder()
        geocoder.known["8001, Bahnhofstrasse 1"] =
            CLLocationCoordinate2D(latitude: 47.3717, longitude: 8.5390)

        let saved = await OfficeEditorScreen.applySave(
            OfficeEditorScreen.Draft(
                name: "Zurich", address: "Bahnhofstrasse 1", postcode: "8001",
                colourHex: OfficeColours.palette[2], radius: 120,
                alertEnabled: true, aliases: [], loadedAliases: []
            ),
            to: nil, in: context, geocode: geocoder.coordinates
        )
        monitor.refreshRegions()

        let watched = try #require(manager.perimeter(saved.office.id.uuidString))
        #expect(watched.latitude == 47.3717)
        #expect(watched.longitude == 8.5390)
        #expect(watched.radius == 120)
        #expect(manager.watching.count == 3)
    }

    /// An office the geocoder could not place has no point to draw a perimeter
    /// around, so there is nothing to watch — and registering 0,0 would put a
    /// perimeter in the Atlantic.
    @Test("An office that could not be located is not watched at all")
    func anUnlocatedOfficeIsNotWatched() async throws {
        let geocoder = RecordingGeocoder()
        let saved = await OfficeEditorScreen.applySave(
            OfficeEditorScreen.Draft(
                name: "Nowhere", address: "qqzz", postcode: "",
                colourHex: OfficeColours.palette[2], radius: 50,
                alertEnabled: true, aliases: [], loadedAliases: []
            ),
            to: nil, in: context, geocode: geocoder.coordinates
        )
        monitor.refreshRegions()

        #expect(saved.outcome == .couldNotLocate)
        #expect(!manager.watching.contains(saved.office.id.uuidString))
        #expect(manager.watching.count == 2, "the two seeded ones, and no third")
    }

    /// A stored radius of nothing reaches CoreLocation as a perimeter that can
    /// never be crossed, so the alert stops existing while the settings row goes
    /// on saying it is on. The clamp is what stands between the two.
    @Test("An office whose stored perimeter is nothing is watched at 20 metres")
    func aZeroPerimeterIsWatchedAtTheSmallest() async throws {
        let brussels = try office(SeedData.brusselsID)
        brussels.radiusMetres = 0
        try context.save()

        // The editor is opened on it, which is what loads the radius into the
        // form, and saved without the user touching the stepper.
        _ = await OfficeEditorScreen.applySave(
            draft(brussels, radius: OfficeEditorScreen.perimeter(brussels.radiusMetres)),
            to: brussels, in: context, geocode: geocoder.coordinates
        )
        monitor.refreshRegions()

        #expect(manager.perimeter(SeedData.brusselsID.uuidString)?.radius == 20)
    }

    /// Nothing else in the app ever tells CoreLocation to stop. A deleted
    /// office's region goes on waking the app, and the wake-up reaches
    /// `ArrivalLedger.handleEntry`, which finds no office and returns
    /// `.disabled` — so the cost is invisible battery rather than a wrong
    /// alert, which is exactly why it would never have been noticed.
    @Test("Deleting an office stops iOS watching the building it deleted")
    func deletingTearsThePerimeterDown() throws {
        try OfficeEditorScreen.removeOffice(try office(SeedData.brusselsID), in: context)
        monitor.refreshRegions()

        #expect(manager.watching == [SeedData.colemanID.uuidString])
        #expect(manager.stopped.contains(SeedData.brusselsID.uuidString))
        #expect(
            manager.perimeter(SeedData.colemanID.uuidString)?.radius == 50,
            "and the office that stayed is still watched, at its own radius"
        )
    }
}

/// The form itself, drawn.
///
/// Every rule above is a `static` tested without a screen, which leaves one
/// thing they cannot say between them: that the form those rules feed actually
/// builds, and that its four conditional sections are included when they should
/// be. What a drawn `Form` will admit to from outside is its height, so that is
/// what these compare — never against a number, which would be a screenshot
/// test in disguise, but against the same form drawn without the section.
///
/// A hosting controller on its own is not enough — SwiftUI does not evaluate
/// `body` until the view is in a key window that has been laid out, and the
/// same test written without that measures nothing at all.
@Suite("The office editor draws")
@MainActor
struct OfficeEditorRenderTests {

    let container: ModelContainer
    let manager = RecordingLocationManager()
    let monitor: ArrivalMonitor

    init() throws {
        let container = try Store.makeInMemoryContainer(seeded: true)
        let ledger = ArrivalLedger(context: container.mainContext)
        ledger.post = { _ in }
        ledger.withdraw = { _ in }
        self.container = container
        // Supplied because the screen takes it from the environment, and an
        // environment lookup that finds nothing traps. Behind the recorder, so
        // no test run ever creates a real `CLLocationManager`.
        monitor = ArrivalMonitor(
            ledger: ledger, context: container.mainContext, manager: manager
        )
    }

    /// Tall on purpose: a `Form` is a scrolling collection view and only
    /// realises the cells that fit, so a 852pt window would leave the sections
    /// below the fold unbuilt and every comparison here measuring the same
    /// screenful twice.
    private func render(_ view: some View) async -> UIView {
        let host = UIHostingController(
            rootView: view.modelContainer(container).environment(monitor)
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 2400))
        window.rootViewController = host
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        // The screen loads its fields in a `.task`, which lands a turn of the
        // main actor later. Without this the form is drawn from the empty
        // defaults rather than from the office it was opened on.
        for _ in 0..<20 { await Task.yield() }
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        let drawn = host.view!
        // See ArrivalPreviewRenderTests.dismantle: a window left key outlives
        // the container it was handed, and its `@Query` is still subscribed
        // when a later suite saves. The view is held first, so what it drew
        // survives to be asserted on.
        ArrivalPreviewRenderTests.dismantle(window, holding: container)
        return drawn
    }

    /// How tall the form laid itself out, which is the one thing the drawn tree
    /// will tell us about which sections it decided to include.
    private func drawnHeight(in view: UIView) -> CGFloat {
        var tallest: CGFloat = 0
        func walk(_ view: UIView) {
            if let scroller = view as? UIScrollView {
                tallest = max(tallest, scroller.contentSize.height)
            }
            for sub in view.subviews { walk(sub) }
        }
        walk(view)
        return tallest
    }

    private func office(_ id: UUID) throws -> Office {
        try #require(
            try container.mainContext.fetch(FetchDescriptor<Office>()).first { $0.id == id }
        )
    }

    /// Adding, which is the shape with the least in it: no Location section,
    /// because there is no office to describe yet, and no Delete.
    @Test("Adding an office draws the form, opening on the next free colour")
    func addingDraws() async throws {
        let view = await render(NavigationStack { OfficeEditorScreen() })

        #expect(view.bounds.width == 393, "it laid out at the size it was given")
        #expect(drawnHeight(in: view) > 0, "and the form drew something")

        // What the body decided, asserted where it can be: the two seeded
        // colours are spoken for, so the picker opens on the third, and Save
        // is dead until a name is typed.
        let taken = OfficeEditorScreen.takenColours(
            among: try container.mainContext.fetch(FetchDescriptor<Office>()), excluding: nil
        )
        #expect(OfficeColours.next(after: taken) == OfficeColours.palette[2])
        #expect(!OfficeEditorScreen.canSave(name: "", saving: false))
        #expect(
            OfficeEditorScreen.swatches(taken: taken, selected: OfficeColours.palette[2])
                .filter(\.isTaken).map(\.accessibilityLabel) == ["Teal", "Indigo"]
        )
    }

    /// The two sections that exist only for an office that is already there.
    /// Their absence while adding is the reason `editing` is not `office`, and
    /// a form that quietly dropped them would look identical from a screenshot.
    @Test("Opening on an office draws the sections an office it has not saved cannot have")
    func editingDrawsMoreThanAdding() async throws {
        let coleman = try office(SeedData.colemanID)
        let adding = await render(NavigationStack { OfficeEditorScreen() })
        let editing = await render(NavigationStack { OfficeEditorScreen(office: coleman) })

        #expect(
            drawnHeight(in: editing) > drawnHeight(in: adding),
            "the Location section and the Delete button are drawn for a saved office only"
        )
        // And the line the Location section prints, which is the only
        // confirmation anywhere that the geocoder found the right building.
        #expect(coleman.isLocated)
        #expect(
            OfficeEditorScreen.coordinatesText(
                latitude: coleman.latitude, longitude: coleman.longitude
            ) == "51.5172, -0.0893"
        )
    }

    /// The alias section is drawn only when there is something in it — an empty
    /// one inviting you to type a name by hand would be asking for the one
    /// thing the capture sheet already collects for itself. It is also the
    /// proof that the screen's `.task` ran: the rows come off the office.
    @Test("The names a capture taught this office are drawn, and only when there are some")
    func aliasSectionDrawsWhenThereIsSomethingInIt() async throws {
        let brussels = try office(SeedData.brusselsID)
        #expect(brussels.aliases.isEmpty, "the seeded offices have been asked nothing")
        let bare = await render(NavigationStack { OfficeEditorScreen(office: brussels) })

        brussels.aliases = ["Brussels, Roi Albert II", "02, Brussels"]
        try container.mainContext.save()
        let aliased = await render(NavigationStack { OfficeEditorScreen(office: brussels) })

        #expect(
            drawnHeight(in: aliased) > drawnHeight(in: bare),
            "two rows and a header that were not there before"
        )
    }

    /// An office the geocoder could not place keeps its Location section rather
    /// than losing it: the section disappearing was the only sign that the
    /// perimeter did not exist, and a paragraph saying so is longer than the
    /// one line of coordinates it replaces.
    @Test("An office that could not be located draws the warning, not a pair of coordinates")
    func anUnlocatedOfficeDrawsItsWarning() async throws {
        let brussels = try office(SeedData.brusselsID)
        brussels.latitude = 0
        brussels.longitude = 0
        try container.mainContext.save()
        #expect(!brussels.isLocated, "0,0 is the Atlantic, which is the absence")
        let unlocated = await render(NavigationStack { OfficeEditorScreen(office: brussels) })
        #expect(!unlocated.subviews.isEmpty, "the section is still drawn, not dropped")

        brussels.latitude = 50.8568
        brussels.longitude = 4.3567
        try container.mainContext.save()
        #expect(brussels.isLocated)
        let located = await render(NavigationStack { OfficeEditorScreen(office: brussels) })
        #expect(!located.subviews.isEmpty)

        // Asserted on what the section prints rather than on how tall it came
        // out. Height is a proxy for content, and a bad one: both renders here
        // fill the same 791-point form, so a comparison of the two passes or
        // fails on layout rather than on the branch it means to be about — and
        // it would go on passing if the warning were replaced by any other
        // paragraph of the same length.
        #expect(
            OfficeEditorScreen.coordinatesText(latitude: 50.8568, longitude: 4.3567)
                == "50.8568, 4.3567",
            "a located office prints the pair the geocoder found"
        )
        #expect(
            OfficeEditorScreen.coordinatesText(latitude: 0, longitude: 0) == "0.0000, 0.0000",
            "and 0,0 formats as a pair too, which is exactly why the screen must decide on isLocated rather than on this string"
        )
    }
}
