import Foundation
import SwiftData

/// Which building a captured desk booking belongs to.
///
/// `Extracted` has to invent a `placeID` because it has no store to look in —
/// it produces a fresh UUID and leaves a comment saying so. This is where that
/// gets resolved: a booking at a building already known adopts its id, and a
/// booking at a new one creates the `Place` and geocodes it once.
///
/// It matters more than it looks. The geofence, the arrival ledger and the
/// desk screen's address line all key off `Place.id`; a second Place for the
/// same building means two perimeters and an arrival that fires against the
/// wrong one.
@MainActor
enum PlaceResolver {

    /// An existing building whose name and city match, fuzzily. `Dedupe`'s
    /// normaliser is reused deliberately — "Ropemaker Place" from a pass and
    /// "Ropemaker Pl" from a screengrab are the same door.
    static func existing(named name: String, city: String, among places: [Place]) -> Place? {
        places.first { place in
            Dedupe.fuzzyEqual(place.name, name) && sameCity(place.city, city)
        }
    }

    /// Cities are compared plainly, *not* through `Dedupe.normaliseName`.
    ///
    /// That normaliser drops the noise words hotels sprinkle around their name
    /// — and "london" is one of them, because "Ropewalk Hotel London" and "The
    /// Ropewalk" are the same property. Run a city through it and London
    /// normalises to the empty string, so every London building fails to match
    /// every other one and the store fills up with twins.
    static func sameCity(_ a: String, _ b: String) -> Bool {
        let x = a.lowercased().filter(\.isLetter)
        let y = b.lowercased().filter(\.isLetter)
        // An unknown city is not a mismatch: a capture that could not read one
        // should still land in the building it names.
        return x.isEmpty || y.isEmpty || x == y
    }

    /// Resolves the desk's `placeID` against the store, creating the building
    /// if it is new. Returns the detail to store and the `Place` that needs
    /// geocoding, if any.
    ///
    /// Geocoding is deliberately *not* done here: this runs inside the commit,
    /// which must not wait on the network. The caller geocodes afterwards and
    /// the building simply has no perimeter until it does.
    static func resolve(
        _ desk: DeskDetail, address: String? = nil, in context: ModelContext
    ) -> (detail: DeskDetail, created: Place?) {
        let places = (try? context.fetch(FetchDescriptor<Place>())) ?? []

        if let match = existing(named: desk.placeName, city: desk.city, among: places) {
            var resolved = desk
            resolved.placeID = match.id
            return (resolved, nil)
        }

        let place = Place(
            id: desk.placeID,
            name: desk.placeName,
            city: desk.city,
            // Never a guess. An address the capture did not read is empty here
            // and gets filled by the geocoder or not at all.
            address: address ?? "",
            postcode: "",
            latitude: 0,
            longitude: 0
        )
        context.insert(place)
        return (desk, place)
    }

    /// Fills in the coordinates, and the address and postcode if they were not
    /// read. Runs after the commit, off the critical path.
    ///
    /// A failure leaves the building exactly as it was: nameable, listable, and
    /// without a perimeter. The arrival settings screen already says so.
    @discardableResult
    static func locate(
        _ place: Place,
        using resolver: @Sendable (String) async -> Geocode.Located? = Geocode.live
    ) async -> Bool {
        let query = Geocode.query(
            name: place.name,
            address: place.address.isEmpty ? nil : place.address,
            city: place.city.isEmpty ? nil : place.city
        )
        guard let located = await resolver(query) else { return false }

        place.latitude = located.latitude
        place.longitude = located.longitude
        // Only fill what is empty: an address the capture actually read beats
        // one the geocoder inferred from a building name.
        if place.address.isEmpty, let address = located.address { place.address = address }
        if place.postcode.isEmpty, let postcode = located.postcode { place.postcode = postcode }
        return true
    }
}
