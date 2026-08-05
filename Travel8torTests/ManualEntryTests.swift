import Foundation
import SwiftData
import Testing
@testable import Travel8tor

@Suite("Manual entry")
struct ManualEntryTests {

    func deskDraft() -> ManualEntry.Draft {
        var draft = ManualEntry.Draft()
        draft.kind = .desk
        draft.placeName = "Ropemaker Place"
        draft.deskCity = "London"
        draft.deskID = "3C-114"
        draft.startsAt = Day(2026, 9, 11).at(9, 0, in: TimeDisplay.uk)
        draft.endsAt = Day(2026, 9, 11).at(17, 0, in: TimeDisplay.uk)
        return draft
    }

    @Test("A blank optional field is absent, not unreadable")
    func blankIsNotUnsure() throws {
        // The amber flag means the machine could not read something. A person
        // who left the floor box empty knows it is empty; reporting that back
        // as a fault would make the flag mean two things at once.
        var draft = deskDraft()
        draft.floor = ""
        draft.deskZone = ""

        let parsed = try #require(ManualEntry.booking(from: draft))
        #expect(parsed.unsureFields.isEmpty)
        let desk = try #require(parsed.detail.deskDetail)
        #expect(desk.floor == nil, "absent, not an empty string")
        #expect(desk.zone == nil)
    }

    @Test("Manual provenance outranks everything, so typing over a capture wins")
    func provenance() throws {
        let parsed = try #require(ManualEntry.booking(from: deskDraft()))
        #expect(parsed.provenance == .manual)
        #expect(parsed.provenance > .pass)
        #expect(!parsed.costedCall, "nothing was sent to the model, so nothing was spent")
    }

    @Test("Required fields are named rather than silently refused")
    func requiredFields() {
        var draft = ManualEntry.Draft()
        draft.kind = .desk
        #expect(ManualEntry.missing(draft) == ["BUILDING", "DESK"])
        #expect(ManualEntry.validate(draft) == .missing(["BUILDING", "DESK"]))
        #expect(ManualEntry.booking(from: draft) == nil)

        draft.kind = .rail
        #expect(ManualEntry.missing(draft) == ["OPERATOR", "FROM", "TO"])

        draft.kind = .stay
        #expect(ManualEntry.missing(draft) == ["HOTEL"])
    }

    @Test("An end before the start is refused")
    func backwards() {
        var draft = deskDraft()
        draft.endsAt = draft.startsAt.addingTimeInterval(-3600)
        #expect(ManualEntry.validate(draft) == .endsBeforeStart)
        #expect(ManualEntry.booking(from: draft) == nil)
    }

    @Test("A rail leg with no city typed falls back to the station table")
    func citiesFromStations() throws {
        // The grouping rule works on cities, not stations: King's Cross and
        // St Pancras are both London, and that is what makes the Eurostar read
        // as leaving the London week rather than starting a new one.
        var draft = ManualEntry.Draft()
        draft.kind = .rail
        draft.operatorName = "Eurostar"
        draft.originStation = "St Pancras"
        draft.destStation = "Brussels Midi"
        draft.endsAt = draft.startsAt.addingTimeInterval(7200)

        let rail = try #require(ManualEntry.booking(from: draft)?.detail.railDetail)
        #expect(rail.originCity == "London")
        #expect(rail.destCity == "Brussels")
    }

    @Test("A foreign zone is carried, so the display rule can add the UK time")
    func foreignZone() throws {
        var draft = deskDraft()
        draft.kind = .stay
        draft.hotelName = "Hotel Sablon"
        draft.stayCity = "Brussels"
        draft.zoneID = "Europe/Brussels"

        let parsed = try #require(ManualEntry.booking(from: draft))
        #expect(parsed.startZoneID == "Europe/Brussels")
        // Never a bare time for an event abroad.
        #expect(TimeDisplay.inline(parsed.startsAt, in: parsed.startZone).contains("UK"))
    }
}

@Suite("Place resolution")
@MainActor
struct PlaceResolverTests {

    let container: ModelContainer

    init() throws {
        container = try Store.makeInMemoryContainer(seeded: true)
    }

    func desk(_ name: String, city: String = "London") -> DeskDetail {
        DeskDetail(
            placeID: UUID(), placeName: name, city: city,
            floor: nil, zone: nil, deskID: "4A-002", hours: nil
        )
    }

    @Test("A building already known keeps its id rather than gaining a twin")
    func adoptsExistingID() throws {
        // Two Places for one building means two perimeters and an arrival that
        // fires against the wrong one.
        let (resolved, created) = PlaceResolver.resolve(
            desk("Ropemaker Place"), in: container.mainContext
        )
        #expect(resolved.placeID == SeedData.ropemakerPlaceID)
        #expect(created == nil)
        #expect(try container.mainContext.fetchCount(FetchDescriptor<Place>()) == 1)
    }

    @Test("The match is fuzzy, because a pass and a screengrab spell it differently")
    func fuzzyMatch() {
        let (resolved, _) = PlaceResolver.resolve(
            desk("ropemaker pl"), in: container.mainContext
        )
        #expect(resolved.placeID == SeedData.ropemakerPlaceID)
    }

    @Test("A new building is created and handed back to be located")
    func createsNew() throws {
        let (resolved, created) = PlaceResolver.resolve(
            desk("Broadgate Tower", city: "London"),
            address: "20 Primrose St", in: container.mainContext
        )
        let place = try #require(created)
        #expect(place.id == resolved.placeID)
        #expect(place.address == "20 Primrose St")
        #expect(place.latitude == 0, "not located yet — that is a network call away")
        #expect(try container.mainContext.fetchCount(FetchDescriptor<Place>()) == 2)
    }

    @Test("Locating fills the coordinates and leaves a read address alone")
    func locating() async throws {
        let (_, created) = PlaceResolver.resolve(
            desk("Broadgate Tower"), address: "20 Primrose St", in: container.mainContext
        )
        let place = try #require(created)

        let located = await PlaceResolver.locate(place) { _ in
            .init(latitude: 51.5205, longitude: -0.0806, address: "SOMEWHERE ELSE", postcode: "EC2A 2EW")
        }
        #expect(located)
        #expect(place.latitude == 51.5205)
        #expect(place.postcode == "EC2A 2EW")
        #expect(place.address == "20 Primrose St", "a read address beats an inferred one")
    }

    @Test("A building the geocoder cannot find is still a building")
    func geocodeFailureIsNotAnError() async throws {
        let (_, created) = PlaceResolver.resolve(desk("Nowhere House"), in: container.mainContext)
        let place = try #require(created)

        let located = await PlaceResolver.locate(place) { _ in nil }
        #expect(!located)
        #expect(place.latitude == 0)
        #expect(place.name == "Nowhere House", "still listed, simply without a perimeter")
    }
}

@Suite("Geocoding")
struct GeocodeTests {

    @Test("The query is built from what a capture actually gives")
    func query() {
        #expect(
            Geocode.query(name: "Ropemaker Place", address: "25 Ropemaker St", city: "London")
                == "25 Ropemaker St, Ropemaker Place, London"
        )
        #expect(Geocode.query(name: "Ropemaker Place", address: nil, city: "London")
            == "Ropemaker Place, London")
        #expect(Geocode.query(name: "Ropemaker Place", address: nil, city: nil)
            == "Ropemaker Place")
    }

    @Test("A part repeated is asked for once")
    func deduplicatesParts() {
        // Asking the geocoder for the same string twice pushes it toward no
        // result at all.
        #expect(Geocode.query(name: "London", address: nil, city: "london") == "London")
    }

    @Test("A UK postcode is read back out of the full address")
    func postcode() {
        #expect(
            Geocode.postcode(in: "25 Ropemaker St, London EC2Y 9LY, United Kingdom") == "EC2Y 9LY"
        )
        #expect(Geocode.postcode(in: "1 Some Rd, Manchester M1 1AE, UK") == "M1 1AE")
        #expect(Geocode.postcode(in: "Buckingham Palace, London SW1A 1AA") == "SW1A 1AA")
    }

    @Test("A foreign address yields no postcode rather than a wrong one")
    func foreignAddress() {
        // The pattern is UK-shaped on purpose, like the rest of the app. An
        // absent field beats a plausible wrong one.
        #expect(Geocode.postcode(in: "Rue de Rollebeek 12, 1000 Bruxelles, Belgium") == nil)
        #expect(Geocode.postcode(in: "1600 Pennsylvania Ave NW, Washington, DC 20500") == nil)
    }
}

@Suite("City matching")
struct CityMatchTests {

    @Test("London is a city here, not a hotel-name noise word")
    func londonIsNotNoise() {
        // Dedupe.normaliseName drops "london" so that "Ropewalk Hotel London"
        // and "The Ropewalk" match. Running a *city* through it would leave the
        // empty string, and every London building would fail to match every
        // other one.
        #expect(Dedupe.normaliseName("London").isEmpty, "the reason this needs its own comparison")
        #expect(PlaceResolver.sameCity("London", "london"))
        #expect(!PlaceResolver.sameCity("London", "Brussels"))
    }

    @Test("An unread city is not a mismatch")
    func blankCityMatches() {
        // A capture that could not read the city should still land in the
        // building it names.
        #expect(PlaceResolver.sameCity("", "London"))
        #expect(PlaceResolver.sameCity("London", ""))
    }
}

@Suite("Manual entry, committed")
@MainActor
struct ManualCommitTests {

    let container: ModelContainer
    let coordinator: CaptureCoordinator

    init() throws {
        container = try Store.makeInMemoryContainer(seeded: true)
        coordinator = CaptureCoordinator(context: container.mainContext)
        // Nothing in this suite reaches Apple's geocoder.
        coordinator.geocoder = { _ in .init(latitude: 51.5, longitude: -0.08, address: nil, postcode: "EC2A 2EW") }
    }

    func draft(building: String, desk: String, on day: Day) -> ManualEntry.Draft {
        var draft = ManualEntry.Draft()
        draft.kind = .desk
        draft.placeName = building
        draft.deskCity = "London"
        draft.deskID = desk
        draft.startsAt = day.at(9, 0, in: TimeDisplay.uk)
        draft.endsAt = day.at(17, 0, in: TimeDisplay.uk)
        return draft
    }

    @Test("A typed desk at a known building joins it rather than making a twin")
    func joinsKnownBuilding() throws {
        let parsed = try #require(
            ManualEntry.booking(from: draft(building: "Ropemaker Place", desk: "9Z-001", on: Day(2026, 9, 14)))
        )
        let id = try coordinator.commit(parsed, captureID: nil)

        let booking = try #require(
            try container.mainContext.fetch(FetchDescriptor<Booking>()).first { $0.id == id }
        )
        #expect(booking.detail?.deskDetail?.placeID == SeedData.ropemakerPlaceID)
        #expect(try container.mainContext.fetchCount(FetchDescriptor<Place>()) == 1)
    }

    @Test("Typing over a bad capture corrects it instead of duplicating it")
    func manualBeatsCapture() throws {
        // Desks match on place and date — one desk per day, so a second
        // capture is a change rather than a duplicate.
        let day = Day(2026, 9, 11)
        let existing = try container.mainContext.fetch(FetchDescriptor<Booking>())
            .filter { $0.kind == .desk && $0.anchorDay == day }
        #expect(existing.count == 1, "the seed's Friday desk")

        let parsed = try #require(
            ManualEntry.booking(from: draft(building: "Ropemaker Place", desk: "7B-200", on: day))
        )
        let id = try coordinator.commit(parsed, captureID: nil)

        #expect(id == existing[0].id, "merged into the booking already there")
        let after = try container.mainContext.fetch(FetchDescriptor<Booking>())
            .filter { $0.kind == .desk && $0.anchorDay == day }
        #expect(after.count == 1)
        #expect(after[0].detail?.deskDetail?.deskID == "7B-200", "the typed value wins")
        #expect(after[0].provenance == .manual)
    }

    @Test("A typed desk at a new building creates it and then locates it")
    func createsAndLocatesBuilding() async throws {
        let parsed = try #require(
            ManualEntry.booking(from: draft(building: "Broadgate Tower", desk: "1A-001", on: Day(2026, 9, 14)))
        )
        try coordinator.commit(parsed, captureID: nil)

        let places = try container.mainContext.fetch(FetchDescriptor<Place>())
        let created = try #require(places.first { $0.name == "Broadgate Tower" })
        #expect(!created.isLocated, "the commit does not wait on the network")

        await coordinator.locateNewPlaces()
        #expect(created.isLocated)
        #expect(created.postcode == "EC2A 2EW")
    }
}
