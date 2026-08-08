import Foundation
import Security
import Testing
@testable import OfficeDaze

/// The app's one secret, against the real Keychain.
///
/// Real rather than faked, because the thing under test *is* securityd's
/// behaviour: that an update on an absent item comes back `errSecItemNotFound`
/// and that an add on a present one comes back `errSecDuplicateItem` is the
/// whole reason `write` has two branches, and a fake would only assert that the
/// author's model of the Keychain matches the author's model of the Keychain.
///
/// Every test works in a service of its own — a UUID, so tests running in
/// parallel cannot see each other's items — and deletes it afterwards. The
/// default service holds a live, billable Anthropic key on the developer's own
/// simulator, and a test that wrote through it would destroy it with no way
/// back. No test in this file names a real key: `"test-key-not-real"` is what
/// goes in, and it is not one.
@Suite("The Keychain")
struct KeychainTests {

    /// A service nobody else is using, cleaned up by `remove`.
    let service = "com.thegregorysonline.officedaze.tests.\(UUID().uuidString)"

    func remove() {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ] as CFDictionary)
    }

    @Test("A key that stores reports that it stored, and reads back as itself")
    func storesAndReadsBack() {
        defer { remove() }
        #expect(Keychain.read(service: service) == nil, "nothing there to begin with")
        #expect(Keychain.store("test-key-not-real", service: service))
        #expect(Keychain.read(service: service) == "test-key-not-real")
    }

    /// The second write takes the `SecItemUpdate` branch and the first takes the
    /// `SecItemAdd` one. If the branches were the wrong way round the add would
    /// come back `errSecDuplicateItem` here and the key would silently stay at
    /// its old value — which is the failure the user cannot see, because the
    /// only symptom is a 401 from a key they thought they had replaced.
    @Test("Replacing a key overwrites it rather than failing as a duplicate")
    func replacesInPlace() {
        defer { remove() }
        #expect(Keychain.store("test-key-not-real", service: service))
        #expect(Keychain.store("test-key-not-real-either", service: service))
        #expect(Keychain.read(service: service) == "test-key-not-real-either")
    }

    /// The report has to be an observation, not an assumption: this is the
    /// assertion that would have caught a write that never landed, which is
    /// exactly what the old `Void` setter could not tell anyone about.
    @Test("What the store reports and what the Keychain holds are the same thing")
    func theReportMatchesReality() {
        defer { remove() }
        let stored = Keychain.store("test-key-not-real", service: service)
        #expect(stored == (Keychain.read(service: service) != nil))
    }

    @Test("Clearing the key removes it, and clearing an absent one is still success")
    func clears() {
        defer { remove() }
        #expect(Keychain.store("test-key-not-real", service: service))
        #expect(Keychain.store(nil, service: service), "the key is gone, which is what was asked")
        #expect(Keychain.read(service: service) == nil)
        #expect(
            Keychain.store(nil, service: service),
            "nothing to remove is the postcondition already holding, not a failure"
        )
    }

    /// Settings clears the field rather than typing nil, so this is the path an
    /// actual revocation takes.
    @Test("An empty string clears the key rather than storing an empty one")
    func emptyClears() {
        defer { remove() }
        #expect(Keychain.store("test-key-not-real", service: service))
        #expect(Keychain.store("", service: service))
        #expect(Keychain.read(service: service) == nil, "an empty key is no key")
    }

    /// The service parameter exists so tests cannot touch the user's key, so it
    /// had better be the thing that actually scopes the item. A parameter that
    /// were dropped on the way to the query would leave every test in this file
    /// writing to the app's own service while appearing to pass.
    @Test("An item stored under one service is invisible under another")
    func theServiceScopesTheItem() {
        let other = "com.thegregorysonline.officedaze.tests.\(UUID().uuidString)"
        defer {
            remove()
            SecItemDelete([
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: other,
            ] as CFDictionary)
        }
        #expect(Keychain.store("test-key-not-real", service: service))
        #expect(Keychain.read(service: other) == nil)
        #expect(Keychain.read(service: service) != nil)
    }

    // MARK: The decision the Keychain will not make for us

    /// Only `errSecItemNotFound` means the item is absent. The old code
    /// compared the update's status against success alone and treated every
    /// other value as "not there yet, add it" — so a real failure was retried
    /// as an insert, and that insert's own status was discarded as well.
    ///
    /// These cannot be provoked from a test: nothing here can make securityd
    /// answer `errSecInteractionNotAllowed`. What can be pinned is what such an
    /// answer would be taken to mean, and that is the half that was wrong.
    @Test("A failing update is reported, not retried as an insert", arguments: [
        errSecInteractionNotAllowed,
        errSecAuthFailed,
        errSecParam,
        errSecDecode,
        errSecNotAvailable,
    ])
    func aFailingUpdateIsNotAnAbsentItem(_ status: OSStatus) {
        #expect(Keychain.nextStep(afterUpdate: status) == .failed(status))
    }

    @Test("An absent item is the one status that means insert")
    func absentMeansInsert() {
        #expect(Keychain.nextStep(afterUpdate: errSecItemNotFound) == .insert)
        #expect(Keychain.nextStep(afterUpdate: errSecSuccess) == .stored)
    }
}
