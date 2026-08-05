import CoreLocation
import Foundation
import MapKit


/// Turning a building name and address into a point on the map.
///
/// A `Place` is worth nothing to the geofence without coordinates, and the
/// design says places are "learned from bookings" — so a captured desk booking
/// at a building we have never seen has to acquire a location from somewhere.
/// This is that somewhere, and it runs once per building rather than per
/// booking.
///
/// Failure is not an error. A building that cannot be geocoded is still a
/// building, still shows on the desk screen, and simply has no perimeter — the
/// arrival settings screen already renders that case.
nonisolated enum Geocode {

    struct Located: Equatable, Sendable {
        var latitude: Double
        var longitude: Double
        var address: String?
        var postcode: String?
    }

    /// `Ropemaker Place, London` — the query, built from what a capture gives
    /// us, which is a building name and a city and rarely more.
    static func query(name: String, address: String?, city: String?) -> String {
        [address, name, city]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            // A name that already contains the address would otherwise be
            // asked for twice, which pushes the geocoder toward no result.
            .reduce(into: [String]()) { out, part in
                if !out.contains(where: { $0.caseInsensitiveCompare(part) == .orderedSame }) {
                    out.append(part)
                }
            }
            .joined(separator: ", ")
    }

    /// The default resolver. Swapped in tests, which must not hit the network —
    /// and which would be at the mercy of Apple's index if they did.
    ///
    /// `MKGeocodingRequest`, not `CLGeocoder`: the latter is deprecated as of
    /// iOS 26. The trade is that MapKit returns an `MKAddress` of two strings
    /// rather than `CLPlacemark`'s structured fields, so the postcode has to be
    /// read back out of the full address.
    static let live: @Sendable (String) async -> Located? = { query in
        await lookUp(query)
    }

    /// The completion-handler form rather than `await request.mapItems`, and
    /// deliberately: neither `MKGeocodingRequest` nor `[MKMapItem]` is Sendable,
    /// and the async property is `nonisolated`, so awaiting it would mean
    /// carrying non-Sendable values across an isolation boundary. MapKit
    /// annotates the callback as running on the UI actor, so unwrapping inside
    /// it is safe and only `Located` — which is Sendable — ever leaves.
    @MainActor
    private static func lookUp(_ query: String) async -> Located? {
        guard !query.isEmpty, let request = MKGeocodingRequest(addressString: query) else {
            return nil
        }
        return await withCheckedContinuation { continuation in
            request.getMapItems { items, _ in
                guard let item = items?.first else {
                    continuation.resume(returning: nil)
                    return
                }
                let coordinate = item.location.coordinate
                continuation.resume(returning: Located(
                    latitude: coordinate.latitude,
                    longitude: coordinate.longitude,
                    address: item.address?.shortAddress,
                    postcode: item.address.flatMap { postcode(in: $0.fullAddress) }
                ))
            }
        }
    }

    /// A UK postcode out of `25 Ropemaker St, London EC2Y 9LY, United Kingdom`.
    ///
    /// UK-shaped on purpose, and it returns nil rather than a guess anywhere
    /// else. The whole app is: England & Wales bank holidays, Europe/London as
    /// the reference zone, eight days a month. A building abroad keeps an empty
    /// postcode, which is the same answer the never-guess rule gives everywhere
    /// else — better an absent field than a plausible wrong one.
    static func postcode(in fullAddress: String) -> String? {
        // Outward code, optional space, inward code: EC2Y 9LY, W1A 1AA, M1 1AE.
        let pattern = /\b([A-Z]{1,2}[0-9][A-Z0-9]?\s?[0-9][A-Z]{2})\b/.ignoresCase()
        guard let match = fullAddress.firstMatch(of: pattern) else { return nil }
        return String(match.1).uppercased()
    }
}
