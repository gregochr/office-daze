import Foundation
import Security

/// The Anthropic API key, and nothing else.
///
/// The Keychain rather than UserDefaults or a build setting: a key in
/// UserDefaults is readable from an unencrypted plist in a device backup, and a
/// key in a build setting is a key in the repository. This is the one secret
/// the app holds, and it is worth the twenty lines.
nonisolated enum Keychain {

    private static let account = "anthropic.apiKey"

    /// The service the item is filed under.
    ///
    /// Every call below takes it as a parameter defaulting to this, so that a
    /// test can work inside a service of its own. That is not decoration: the
    /// Keychain is real, process-wide and outlives the test run, so a test that
    /// wrote through the default service would overwrite the developer's live,
    /// billable key on their own simulator and there would be no way to get it
    /// back.
    static let service = "com.thegregorysonline.officedaze"

    /// Reading the key is the app's ordinary access; writing it goes through
    /// `store` instead, because a property setter has nowhere to report a
    /// failure to and this one can fail.
    static var apiKey: String? {
        get { read() }
        set { store(newValue) }
    }

    /// Writes the key — or clears it, for nil or empty — and says whether the
    /// Keychain agreed.
    ///
    /// The return value is the entire point of this function. Both status codes
    /// used to be discarded, so there was no channel at all by which a failed
    /// write could reach the user: Settings said "Key saved" on the strength of
    /// what was in its own text field, and the next capture then said "No API
    /// key yet. Add one in Settings" — sending them back to a screen that
    /// insisted the key was there. A caller that throws this result away is
    /// re-creating that.
    @discardableResult
    static func store(_ value: String?, service: String = Keychain.service) -> Bool {
        guard let value, !value.isEmpty else { return delete(service: service) }
        return write(value, service: service)
    }

    /// The stored key, or nil if there is none. Nil is also what an unreadable
    /// item gives, because to every caller those are the same situation: there
    /// is no key to send.
    static func read(service: String = Keychain.service) -> String? {
        let request = query(service: service, [
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ])
        var item: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// What an update's status means for what to do next.
    ///
    /// Its own function because this is the decision the old code got wrong and
    /// the one that cannot be provoked from a test — you cannot make securityd
    /// answer `errSecInteractionNotAllowed` on demand, but you can pin what the
    /// answer would be taken to mean. The old code compared only against
    /// success and treated *every* other status as "not there yet, add it", so
    /// a genuine failure was retried as an insert whose own failure was then
    /// thrown away too. Only `errSecItemNotFound` actually means the item is
    /// absent; everything else is news, and news gets reported rather than
    /// papered over.
    enum NextStep: Equatable {
        case stored
        case insert
        case failed(OSStatus)
    }

    static func nextStep(afterUpdate status: OSStatus) -> NextStep {
        switch status {
        case errSecSuccess: .stored
        case errSecItemNotFound: .insert
        default: .failed(status)
        }
    }

    private static func query(
        service: String, _ extra: [String: Any] = [:]
    ) -> [String: Any] {
        var base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        base.merge(extra) { _, new in new }
        return base
    }

    private static func write(_ value: String, service: String) -> Bool {
        let data = Data(value.utf8)
        // Update in place if it is already there; SecItemAdd fails with
        // errSecDuplicateItem otherwise.
        let updated = SecItemUpdate(
            query(service: service) as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        switch nextStep(afterUpdate: updated) {
        case .stored:
            return true
        case .failed:
            return false
        case .insert:
            return SecItemAdd(query(service: service, [
                kSecValueData as String: data,
                // The key is only ever needed while the app is in the
                // foreground reading a screenshot, so it does not need to
                // survive a locked device — and this attribute keeps it out of
                // iCloud backups. Note what it does *not* do: a generic
                // password is not purged when the app is deleted, so this item
                // outlives an uninstall and only `store(nil)` actually revokes
                // the key from the device.
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            ]) as CFDictionary, nil) == errSecSuccess
        }
    }

    /// True when there is no key left, which is what the caller asked for —
    /// including when there was none to begin with. `errSecItemNotFound` is the
    /// postcondition already holding, not a failure to report.
    private static func delete(service: String) -> Bool {
        let status = SecItemDelete(query(service: service) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
