import CoreLocation
import Foundation
import MapKit

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
    ///
    /// MapKit's `MKGeocodingRequest` rather than `CLGeocoder`, which deprecated
    /// `geocodeAddressString` in iOS 26. Deliberately the same shape as before:
    /// one string in, the first result out, nil for everything else. There are
    /// now three ways to reach that nil — a blank query, a string MapKit will
    /// not build a request from, and a request that fails or comes back with no
    /// results — and all three are the same answer to the caller, because the
    /// caller only ever asked whether this office can be located.
    ///
    /// The failable initialiser is the one genuinely new branch, and it is
    /// refused rather than force-unwrapped: `query` has already filtered out
    /// everything blank, so we do not expect to see it, and a crash on save
    /// would be a far worse answer to an address MapKit dislikes than an office
    /// with no perimeter.
    static func coordinates(postcode: String, address: String) async -> CLLocationCoordinate2D? {
        guard let query = query(postcode: postcode, address: address) else { return nil }
        return await lookUp(query)
    }

    /// `@concurrent` rather than a bare `nonisolated`, and the attribute is what
    /// makes this compile at all. The project builds with
    /// `SWIFT_APPROACHABLE_CONCURRENCY`, so `nonisolated func … async` means
    /// *nonisolated(nonsending)*: the body runs on the caller's executor, which
    /// here is the office editor on the main actor. `MKGeocodingRequest` is not
    /// `Sendable` and its `mapItems` is nonisolated, so a request built in that
    /// inherited context cannot be handed to it — the same reason `CLGeocoder`
    /// needed no such attribute is that Apple marked it `Sendable` and MapKit
    /// has not. Splitting the lookup out rather than marking `coordinates`
    /// itself keeps the isolation of the function callers already await exactly
    /// as it was, and confines the hop to the one call that needs it.
    ///
    /// The request is built here rather than passed in for the same reason: it
    /// has to be created and consumed in one context, and it never crosses.
    @concurrent
    private static func lookUp(_ query: String) async -> CLLocationCoordinate2D? {
        guard let request = MKGeocodingRequest(addressString: query) else { return nil }

        let items = try? await request.mapItems
        return items?.first?.location.coordinate
    }
}
