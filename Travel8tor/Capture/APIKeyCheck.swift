import Foundation

/// Whether what was pasted into the settings screen can possibly be an API key.
///
/// This exists because of a real failure: a key that is truncated, or copied
/// from the console's *masked* display rather than at the moment of creation,
/// looks identical to a good one in a `SecureField` — dots either way — and the
/// app cheerfully reported `KEY STORED IN KEYCHAIN`. The first sign anything
/// was wrong came later, as a 401 in the middle of a capture, at which point
/// the store and the paste are far enough apart to look unrelated.
///
/// None of this proves a key is *valid* — only the API can say that. It catches
/// the shapes that cannot possibly be, at the moment they are pasted.
nonisolated enum APIKeyCheck {

    static let prefix = "sk-ant-"

    /// Deliberately well below a real key's length. The point is to catch an
    /// obvious truncation, not to encode a format that Anthropic is free to
    /// change — a floor that guesses too high would reject good keys later.
    static let plausibleMinimum = 40

    enum Problem: Equatable {
        case empty
        case wrongPrefix
        /// The console shows `sk-ant-api03-abc…xyz` once you navigate back to
        /// it. Copying that is the single most likely way to arrive here.
        case masked
        case tooShort(Int)

        var message: String {
            switch self {
            case .empty:
                "NOTHING TO STORE."
            case .wrongPrefix:
                "THAT DOES NOT LOOK LIKE AN API KEY — THEY BEGIN sk-ant-."
            case .masked:
                """
                THAT IS THE MASKED KEY THE CONSOLE SHOWS AFTER THE FACT, NOT \
                THE KEY. THE FULL VALUE IS DISPLAYED ONCE, WHEN IT IS CREATED.
                """
            case .tooShort(let count):
                "TOO SHORT AT \(count) CHARACTERS. THE PASTE WAS PROBABLY CUT OFF."
            }
        }
    }

    static func validate(_ raw: String) -> Problem? {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.isEmpty { return .empty }
        // Checked before the prefix, because a masked key still starts with it
        // and "wrong prefix" would be a misleading thing to say about it.
        if key.contains("…") || key.contains("...") { return .masked }
        if !key.hasPrefix(prefix) { return .wrongPrefix }
        if key.count < plausibleMinimum { return .tooShort(key.count) }
        return nil
    }

    /// `sk-ant-…QAA7 ▪ 108 CHARS`. Enough to tell two keys apart and to see at a
    /// glance that a short one is short, without putting the secret on screen.
    static func fingerprint(_ key: String) -> String {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let tail = String(trimmed.suffix(4))
        return "\(prefix)…\(tail) ▪ \(trimmed.count) CHARS"
    }
}
