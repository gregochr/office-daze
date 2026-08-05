import Foundation

nonisolated enum Confidence: String, Codable, Sendable {
    case high, low
}

/// What both capture paths produce. The pass path fills it exactly; the model
/// path fills it with whatever it could read and names the rest.
///
/// The invariant that matters: a field named in `unsureFields` has no stored
/// value. Nothing downstream re-derives it, and the amber flag depends on it.
nonisolated struct ParsedBooking: Hashable, Sendable {
    var detail: BookingDetail
    var startsAt: Date
    var startZoneID: String
    var endsAt: Date?
    var endZoneID: String?
    var unsureFields: [String]
    var provenance: Provenance
    var confidence: Confidence
    /// A desk capture's building address, when the source printed one. It is
    /// not on `DeskDetail` because it belongs to the `Place`, not the booking —
    /// this carries it as far as `PlaceResolver` and no further.
    var placeAddress: String? = nil

    var kind: BookingKind { detail.kind }

    /// A model call costs money; a pass file does not, and neither does typing
    /// it in. The capture sheet shows this as `1 CALL` or `FREE`.
    var costedCall: Bool { provenance != .pass && provenance != .manual }
}

nonisolated enum CaptureError: LocalizedError, Equatable {
    case unsupportedFile(String)
    case notAZip
    case missingPassJSON
    case malformedPass(String)
    case noAPIKey
    case network(String)
    case httpStatus(Int, String)
    case modelReturnedNothingUsable(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedFile(let ext): "TRAVEL8TOR CANNOT READ A .\(ext.uppercased()) FILE."
        case .notAZip: "THAT PASS FILE IS NOT A VALID .PKPASS ARCHIVE."
        case .missingPassJSON: "THE PASS FILE CONTAINS NO PASS.JSON."
        case .malformedPass(let why): "PASS.JSON COULD NOT BE READ: \(why.uppercased())"
        case .noAPIKey: "NO API KEY. ADD ONE IN SETTINGS TO READ SCREENSHOTS AND PDFS."
        case .network(let why): "NETWORK FAILED: \(why.uppercased())"
        case .httpStatus(let code, let why): "MODEL CALL FAILED (\(code)): \(why.uppercased())"
        case .modelReturnedNothingUsable(let why): "MODEL RETURNED NOTHING USABLE: \(why.uppercased())"
        }
    }

    /// Whether offering manual entry is the sensible next step. Every failure
    /// offers it — the design is explicit that a parse failure is never a
    /// silent drop.
    var offersManualEntry: Bool { true }
}
