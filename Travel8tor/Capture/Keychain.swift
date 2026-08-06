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
    private static let service = "com.thegregorysonline.officedaze"

    static var apiKey: String? {
        get { read() }
        set {
            if let newValue, !newValue.isEmpty { write(newValue) } else { delete() }
        }
    }

    private static func query(_ extra: [String: Any] = [:]) -> [String: Any] {
        var base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        base.merge(extra) { _, new in new }
        return base
    }

    private static func read() -> String? {
        let request = query([
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ])
        var item: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func write(_ value: String) {
        let data = Data(value.utf8)
        // Update in place if it is already there; SecItemAdd fails with
        // errSecDuplicateItem otherwise.
        let updated = SecItemUpdate(
            query() as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        guard updated != errSecSuccess else { return }

        SecItemAdd(query([
            kSecValueData as String: data,
            // The key is only ever needed while the app is in the foreground
            // reading a screenshot, so it does not need to survive a locked
            // device — and this attribute keeps it out of iCloud backups.
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]) as CFDictionary, nil)
    }

    private static func delete() {
        SecItemDelete(query() as CFDictionary)
    }
}
