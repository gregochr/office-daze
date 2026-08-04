import Foundation
import Security

/// The Anthropic API key lives here and nowhere else — not in source, not in
/// Info.plist, not in a build setting. Those all end up in the built app or in
/// git; the Keychain ends up in neither.
///
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`: readable in the
/// background after the first unlock (so a capture triggered from the share
/// sheet works), and never included in a backup or migrated to a new device.
/// A leaked backup shouldn't carry a live API key.
nonisolated enum Keychain {

    enum Item: String {
        case anthropicAPIKey = "anthropic-api-key"
    }

    private static let service = "com.thegregorysonline.travel8tor"

    static func set(_ value: String, for item: Item) throws {
        let data = Data(value.utf8)

        // SecItemUpdate can't create, SecItemAdd can't replace — delete first
        // rather than branching on whether it already exists.
        SecItemDelete(query(for: item) as CFDictionary)

        var attributes = query(for: item)
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.status(status) }
    }

    static func get(_ item: Item) -> String? {
        var lookup = query(for: item)
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        guard SecItemCopyMatching(lookup as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    static func remove(_ item: Item) {
        SecItemDelete(query(for: item) as CFDictionary)
    }

    static func has(_ item: Item) -> Bool {
        get(item)?.isEmpty == false
    }

    private static func query(for item: Item) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: item.rawValue,
        ]
    }

    enum KeychainError: LocalizedError {
        case status(OSStatus)

        var errorDescription: String? {
            switch self {
            case .status(let code):
                "KEYCHAIN ERROR \(code): \(SecCopyErrorMessageString(code, nil) as String? ?? "UNKNOWN")"
            }
        }
    }
}
