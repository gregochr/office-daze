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

    /// Which defaults to read and write. `.standard` in the app; a throwaway
    /// suite in tests, so a test that switches the fire rate does not leave it
    /// switched for the next run of the app on the same simulator.
    private let defaults: UserDefaults

    var enabled: Bool {
        didSet { defaults.set(enabled, forKey: Key.enabled) }
    }

    var fireRate: FireRate {
        didSet { defaults.set(fireRate.rawValue, forKey: Key.fireRate) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // `object(forKey:)` rather than `bool(forKey:)`, which cannot tell
        // "never set" from "set to false".
        enabled = defaults.object(forKey: Key.enabled) as? Bool ?? true
        fireRate = defaults.string(forKey: Key.fireRate)
            .flatMap(FireRate.init(rawValue:)) ?? .firstArrivalOnly
    }
}
