import CoreLocation
import Foundation
import Observation

/// The location permission, as something a screen can watch rather than
/// something it reads once and then believes forever.
///
/// The arrival settings screen used to do `CLLocationManager().authorizationStatus`
/// inside a `.task`. That is a single reading taken as the screen appears, and
/// it is wrong within seconds of being right: grant the permission and the
/// panel carries on offering ASK FOR ACCESS, because nothing told it. The same
/// applies to changing the setting in Settings.app and coming back.
///
/// `CLLocationManager` only calls its delegate on the instance that owns it, so
/// observing means holding a manager rather than making one per reading.
@Observable
@MainActor
final class LocationAuthorization: NSObject, CLLocationManagerDelegate {

    private let manager = CLLocationManager()

    private(set) var status: CLAuthorizationStatus

    override init() {
        status = manager.authorizationStatus
        super.init()
        manager.delegate = self
    }

    /// Ask for When In Use first and escalate to Always only once that is
    /// granted. Asking for Always cold gets denied — iOS shows the harsher
    /// prompt, people decline, and there is no second chance.
    func request() {
        switch status {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse: manager.requestAlwaysAuthorization()
        default: break
        }
    }

    /// Whether there is any point offering a button at all.
    var isSettled: Bool { status == .authorizedAlways }

    /// Denied and restricted cannot be undone from inside the app: iOS only
    /// prompts once, so the only route left is Settings.app.
    var mustUseSettings: Bool {
        status == .denied || status == .restricted || status == .authorizedWhenInUse
    }

    /// Re-reads the status. For coming back from Settings.app, where the
    /// delegate callback is not guaranteed to have fired while suspended.
    func refresh() {
        status = manager.authorizationStatus
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        // The manager parameter is deliberately not captured: CLLocationManager
        // is not Sendable, and `self.manager` is the same object already
        // isolated to this actor.
        Task { @MainActor in self.refresh() }
    }
}
