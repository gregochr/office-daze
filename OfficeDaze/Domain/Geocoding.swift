import CoreLocation
import Foundation

/// Turns a postcode into coordinates, once, when an office is saved.
///
/// Once, and stored — not at monitor time. Region monitoring starts when the
/// app launches in the background after a region crossing, which is exactly
/// when there may be no network; an office whose perimeter depended on a
/// geocode at that moment would silently stop firing.
nonisolated enum Geocoding {

    /// Nil when the postcode means nothing to Apple, which is a normal answer
    /// rather than an error — the office still saves, it just cannot be
    /// monitored until the address is corrected.
    static func coordinates(postcode: String, address: String) async -> CLLocationCoordinate2D? {
        let query = [postcode, address]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
        guard !query.isEmpty else { return nil }

        let placemarks = try? await CLGeocoder().geocodeAddressString(query)
        return placemarks?.first?.location?.coordinate
    }
}
