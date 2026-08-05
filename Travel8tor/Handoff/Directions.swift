import CoreLocation
import Foundation
import MapKit

/// The desk screen's DIRECTIONS action — a handoff to Maps, not a map.
///
/// Drawing a map inside Travel8tor would mean a `MKMapView` in the middle of a
/// screen whose entire visual language is hard rectangles and Space Mono, and
/// it would be worse at directions than Maps is. The building's coordinates are
/// already on the `Place` because the geofence needs them, so this costs one
/// call.
@MainActor
enum Directions {

    enum Outcome: Equatable {
        case opened
        /// The building has never been geocoded, so there is nothing to open.
        case noCoordinates

        var message: String? {
            switch self {
            case .opened: nil
            case .noCoordinates: "NO COORDINATES FOR THIS BUILDING YET."
            }
        }
    }

    /// Walking, not driving. The desk is in a city building reached from a
    /// station; the default of driving would be wrong nearly every time.
    @discardableResult
    static func open(
        name: String, latitude: Double, longitude: Double,
        opener: (MKMapItem) -> Void = { $0.openInMaps(launchOptions: [
            MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeWalking
        ]) }
    ) -> Outcome {
        // 0,0 is the Atlantic. It is what an ungeocoded Place holds, and
        // handing it to Maps would silently open the middle of the ocean.
        guard latitude != 0 || longitude != 0 else { return .noCoordinates }

        let item = MKMapItem(
            location: CLLocation(latitude: latitude, longitude: longitude),
            address: nil
        )
        item.name = name
        opener(item)
        return .opened
    }
}
