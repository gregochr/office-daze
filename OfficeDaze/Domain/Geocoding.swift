import CoreLocation
import Foundation

/// Turns a postcode into coordinates, once, when an office is saved.
///
/// Once, and stored — not at monitor time. Region monitoring starts when the
/// app launches in the background after a region crossing, which is exactly
/// when there may be no network; an office whose perimeter depended on a
/// geocode at that moment would silently stop firing.
nonisolated enum Geocoding {

    /// What we hand the geocoder, or nil when there is nothing worth asking.
    ///
    /// Split out from `coordinates` so it can be asserted without a network
    /// call, because the nil case is load-bearing and silent. Drop the
    /// `filter` and an office saved with a blank address and a postcode of
    /// spaces produces the query ", " — non-empty, so it goes to Apple, which
    /// on a vague string will happily answer with *a* placemark somewhere.
    /// `latitude`/`longitude` are then written to a building the user has
    /// never been to, `isLocated` turns true, and `ArrivalMonitor` starts
    /// watching a 50m perimeter around it. The arrival alert simply never
    /// fires again, and nothing on screen says why.
    ///
    /// Postcode first: it is the more precise of the two, and Apple resolves
    /// the pair better in that order than with a free-text address leading.
    static func query(postcode: String, address: String) -> String? {
        let joined = [postcode, address]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
        return joined.isEmpty ? nil : joined
    }

    /// Nil when the postcode means nothing to Apple, which is a normal answer
    /// rather than an error — the office still saves, it just cannot be
    /// monitored until the address is corrected.
    static func coordinates(postcode: String, address: String) async -> CLLocationCoordinate2D? {
        guard let query = query(postcode: postcode, address: address) else { return nil }

        let placemarks = try? await CLGeocoder().geocodeAddressString(query)
        return placemarks?.first?.location?.coordinate
    }
}
