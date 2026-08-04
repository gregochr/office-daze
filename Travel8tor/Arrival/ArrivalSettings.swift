import Foundation
import Observation

/// The arrival trigger's user-facing switches, backed by UserDefaults.
///
/// Not the Keychain: none of this is a secret, and it needs to be readable the
/// instant the app is relaunched in the background by a region event.
@Observable
final class ArrivalSettings {
    static let shared = ArrivalSettings()

    private enum Key {
        static let enabled = "arrival.enabled"
        static let fireRate = "arrival.fireRate"
    }

    var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: Key.enabled) }
    }

    var fireRate: FireRate {
        didSet { UserDefaults.standard.set(fireRate.rawValue, forKey: Key.fireRate) }
    }

    private init() {
        // `object(forKey:)` rather than `bool(forKey:)`, which cannot tell
        // "never set" from "set to false".
        enabled = UserDefaults.standard.object(forKey: Key.enabled) as? Bool ?? true
        fireRate = UserDefaults.standard.string(forKey: Key.fireRate)
            .flatMap(FireRate.init(rawValue:)) ?? .firstArrivalOnly
    }
}
