import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import OfficeDaze

/// The wire shape and its mapping. The never-guess rule lives here — it is
/// enforced in the mapping rather than merely requested in the prompt, so it
/// can be tested without spending a model call.
@Suite("Capture mapping")
struct CaptureMappingTests {

    /// One row of the user's own booking system, as the schema describes it.
    func envelope(_ bookings: String) -> Data {
        Data("""
        {"stop_reason":"end_turn","usage":{"input_tokens":1640,"output_tokens":520},
         "content":[{"type":"text","text":"{\\"bookings\\":[\(bookings)]}"}]}
        """.utf8)
    }

    func row(
        office: String = "\"Coleman, London\"", date: String = "\"2026-08-05\"",
        desk: String = "\"CO03C407\"", floor: String = "\"03\"", zone: String = "null",
        start: String = "\"08:00\"", end: String = "\"17:00\"", unsure: String = "[\\\"zone\\\"]"
    ) -> String {
        """
        {\\"office\\":\(office.replacingOccurrences(of: "\"", with: "\\\"")),\
        \\"date\\":\(date.replacingOccurrences(of: "\"", with: "\\\"")),\
        \\"deskId\\":\(desk.replacingOccurrences(of: "\"", with: "\\\"")),\
        \\"floor\\":\(floor.replacingOccurrences(of: "\"", with: "\\\"")),\
        \\"zone\\":\(zone.replacingOccurrences(of: "\"", with: "\\\"")),\
        \\"startTime\\":\(start.replacingOccurrences(of: "\"", with: "\\\"")),\
        \\"endTime\\":\(end.replacingOccurrences(of: "\"", with: "\\\"")),\
        \\"unsureFields\\":\(unsure)}
        """
    }

    @Test("Every row of the table becomes a booking, in the order printed")
    func tableRows() throws {
        let (bookings, usage) = try HaikuClient.decode(envelope([
            row(date: "\"2026-08-04\"", desk: "\"CO03A424\""),
            row(date: "\"2026-08-05\"", desk: "\"CO03C407\""),
            row(date: "\"2026-08-06\"", desk: "\"CO03D211\""),
        ].joined(separator: ",")))

        #expect(bookings.count == 3, "three rows, three bookings")
        #expect(bookings.map(\.deskID) == ["CO03A424", "CO03C407", "CO03D211"])
        #expect(bookings.map(\.day) == [Day(2026, 8, 4), Day(2026, 8, 5), Day(2026, 8, 6)])
        #expect(usage.inputTokens == 1640)
        #expect(usage.outputTokens == 520)
    }

    /// The other layout the booking system sends: a confirmation email for one
    /// reservation, its details as labelled fields and its date a timestamp
    /// with a timezone the app does not handle. One booking, one day.
    @Test("A single-reservation confirmation becomes one booking on the day it names")
    func singleConfirmation() throws {
        let (bookings, _) = try HaikuClient.decode(envelope(row(
            office: "\"Coleman\"", date: "\"2026-08-25 09:00:00 CEST\"",
            desk: "\"CO03B424\"", floor: "\"03\"", zone: "null",
            start: "\"09:00\"", end: "null", unsure: "[\\\"zone\\\",\\\"endTime\\\"]"
        )))

        #expect(bookings.count == 1, "this layout is one booking, never a range")
        let booking = try #require(bookings.first)
        #expect(booking.day == Day(2026, 8, 25), "the timezone beside it changes nothing")
        #expect(booking.deskID == "CO03B424")
        #expect(booking.floor == "03", "read from its own field, not split off the desk id")
        #expect(booking.officeName == "Coleman", "no city was printed, so none is added")
        #expect(booking.startTime == "09:00")
        #expect(booking.endTime == "17:00", "unprinted, so the working day's end stands in")
        #expect(!booking.unsureFields.contains("endTime"), "a default, not a question")
        #expect(booking.needsChecking, "the zone is still unread")
    }

    /// The end of the day is the one field the app answers for itself: a
    /// confirmation prints when the desk becomes yours and never when it stops.
    @Test("An unread end time defaults to 17:00 rather than being flagged")
    func endTimeDefaults() throws {
        let (fromNull, _) = try HaikuClient.decode(envelope(row(end: "null", unsure: "[]")))
        #expect(fromNull.first?.endTime == "17:00")
        #expect(fromNull.first?.unsureFields.contains("endTime") == false)

        // Even a value the model itself called unread gives way to the default.
        let (fromUnsure, _) = try HaikuClient.decode(envelope(
            row(end: "\"19:00\"", unsure: "[\\\"endTime\\\"]")
        ))
        #expect(fromUnsure.first?.endTime == "17:00")
        #expect(fromUnsure.first?.unsureFields.contains("endTime") == false)
    }

    /// The desk id is `CO03C407` — Coleman, floor 03, desk C407 — and the
    /// prompt forbids taking it apart. The floor comes from its own field.
    @Test("A site-coded desk id is stored whole, and the floor read separately")
    func deskIDIsNotSplit() throws {
        let (bookings, _) = try HaikuClient.decode(envelope(row()))
        let booking = try #require(bookings.first)
        #expect(booking.deskID == "CO03C407")
        #expect(booking.floor == "03")
    }

    /// The never-guess rule, enforced rather than trusted: a value that arrives
    /// beside its own name in unsureFields is exactly the plausible guess the
    /// design forbids storing, so the mapping drops it.
    @Test("A value contradicted by unsureFields is discarded, not stored")
    func honoursUnsureFields() throws {
        let (bookings, _) = try HaikuClient.decode(envelope(
            row(floor: "\"03\"", unsure: "[\\\"floor\\\"]")
        ))
        let booking = try #require(bookings.first)
        #expect(booking.floor == nil, "the model named it unread; the value goes")
        #expect(booking.unsureFields.contains("floor"))
    }

    @Test("A field left blank without being named is still flagged")
    func namesSilentBlanks() throws {
        let (bookings, _) = try HaikuClient.decode(envelope(
            row(zone: "null", start: "null", unsure: "[]")
        ))
        let booking = try #require(bookings.first)
        #expect(booking.zone == nil)
        #expect(booking.unsureFields.contains("zone"))
        #expect(booking.unsureFields.contains("startTime"))
        #expect(booking.needsChecking)
    }

    @Test("A row with no readable date is dropped; the rest of the table survives")
    func partialTable() throws {
        let (bookings, _) = try HaikuClient.decode(envelope([
            row(date: "null", unsure: "[\\\"date\\\"]"),
            row(date: "\"2026-08-06\"", desk: "\"CO03D211\""),
        ].joined(separator: ",")))

        #expect(bookings.count == 1, "most of a table beats none of it")
        #expect(bookings.first?.deskID == "CO03D211")
    }

    @Test("A document with nothing readable is a failure, not an empty success")
    func nothingReadable() {
        #expect(throws: CaptureError.self) {
            try HaikuClient.decode(envelope(row(date: "null", unsure: "[\\\"date\\\"]")))
        }
        #expect(throws: CaptureError.self) {
            try HaikuClient.decode(envelope(""))
        }
    }

    /// A refusal is a successful HTTP 200 with an empty content array, so it
    /// has to be checked before reading content.
    @Test("A refusal is surfaced rather than read as an empty document")
    func refusal() {
        let data = Data(#"{"stop_reason":"refusal","content":[],"usage":{}}"#.utf8)
        #expect(throws: CaptureError.refused) { try HaikuClient.decode(data) }
    }

    @Test("A response cut short by the token cap is a failure, not a partial table")
    func truncated() {
        let data = Data(#"{"stop_reason":"max_tokens","content":[],"usage":{}}"#.utf8)
        #expect(throws: CaptureError.self) { try HaikuClient.decode(data) }
    }

    /// A date the model reformatted is a date we did not read. Guessing at
    /// 05/08/2026 is the day/month coin-flip the app must not make.
    @Test("Only ISO dates are accepted")
    func strictDates() {
        #expect(CapturedBooking.day(from: "2026-08-05") == Day(2026, 8, 5))
        #expect(CapturedBooking.day(from: "2026-08-05T08:00:00+01:00") == Day(2026, 8, 5))
        #expect(CapturedBooking.day(from: "2026-08-25 09:00:00 CEST") == Day(2026, 8, 25))
        #expect(CapturedBooking.day(from: "05/08/2026") == nil)
        #expect(CapturedBooking.day(from: "5 August 2026") == nil)
        #expect(CapturedBooking.day(from: "2026-13-05") == nil)
    }
}

/// Structured outputs rejects a schema whose objects don't close
/// `additionalProperties` and list every property in `required` — getting that
/// wrong is a 400 at the worst possible moment.
@Suite("The extraction schema")
struct SchemaTests {

    @Test("Every object is closed and fully required")
    func wellFormed() {
        func check(_ node: Any, path: String) {
            guard let object = node as? [String: Any] else { return }
            if object["type"] as? String == "object" {
                let properties = object["properties"] as? [String: Any] ?? [:]
                #expect(object["additionalProperties"] as? Bool == false, "\(path)")
                let required = Set(object["required"] as? [String] ?? [])
                #expect(required == Set(properties.keys), "\(path)")
                for (key, value) in properties { check(value, path: "\(path).\(key)") }
            }
            if let items = object["items"] { check(items, path: "\(path)[]") }
            for branch in object["anyOf"] as? [Any] ?? [] { check(branch, path: path) }
        }
        check(HaikuClient.schema, path: "root")
    }

    @Test("The schema is JSON-serialisable")
    func serialisable() throws {
        #expect(JSONSerialization.isValidJSONObject(HaikuClient.schema))
        _ = try JSONSerialization.data(withJSONObject: HaikuClient.schema)
    }

    @Test("The root returns a list, so a table is not truncated to its first row")
    func rootIsAList() throws {
        let bookings = try #require(
            (HaikuClient.schema["properties"] as? [String: Any])?["bookings"] as? [String: Any]
        )
        #expect(bookings["type"] as? String == "array")
    }

    /// The previous version of this app took a 400 for exceeding the API's cap
    /// on union-typed parameters. Four is not close, and this keeps it that way.
    @Test("Nullable fields stay well under the union-type limit")
    func unionCount() {
        func unions(_ node: Any) -> Int {
            guard let object = node as? [String: Any] else { return 0 }
            var count = object["anyOf"] == nil ? 0 : 1
            for value in (object["properties"] as? [String: Any])?.values ?? [:].values {
                count += unions(value)
            }
            for branch in object["anyOf"] as? [Any] ?? [] { count += unions(branch) }
            if let items = object["items"] { count += unions(items) }
            return count
        }
        #expect(unions(HaikuClient.schema) <= 16)
    }

    @Test("The prompt carries the rules the schema cannot express")
    func promptRules() {
        let prompt = HaikuClient.systemPrompt
        #expect(prompt.contains("NEVER INFER A VALUE"))
        #expect(prompt.contains("unsureFields"))
        #expect(prompt.contains("Confirmed"), "non-confirmed rows are skipped")
        #expect(prompt.contains("no status at all"), "a confirmation without a status is read")
        #expect(
            prompt.contains("three layouts"),
            "a table, a single confirmation, and a reservation page"
        )
        #expect(prompt.contains("group heading"), "the date is carried down to each row")
        #expect(
            prompt.contains("array of exactly one entry"),
            "a single confirmation is one day, not a range"
        )
        #expect(prompt.contains("Do not take them apart"), "the desk id is not split")
        #expect(HaikuClient.model == "claude-haiku-4-5")
    }

    /// A photograph of a table starts and ends mid-table. The row at the top of
    /// the frame had its heading cropped away, and the nearest date to it is
    /// the heading below — which belongs to the rows below. Carrying it up
    /// would have filed a real desk on the wrong day, which is the one failure
    /// the review sheet cannot catch, because the booking looks right.
    @Test("The prompt reads only whole rows")
    func promptReadsWholeRows() {
        let prompt = HaikuClient.systemPrompt
        #expect(prompt.contains("Read only whole rows"))
        #expect(
            prompt.contains("Headings carry downwards only"),
            "so a cropped top row does not borrow the heading beneath it"
        )
        #expect(
            prompt.contains("produces no entry at all"),
            "a heading whose rows are below the edge is not a booking"
        )
    }

    /// A photographed screen read CO03C117 as C003C117 — the site letters as
    /// digits. The prefix is always two letters, so this is the one reading the
    /// prompt can overrule without guessing at anything.
    @Test("The prompt knows the site code is letters, never digits")
    func promptFixesTheSitePrefix() {
        let prompt = HaikuClient.systemPrompt
        #expect(prompt.contains("always begins with two letters"))
        #expect(prompt.contains("the letter O, not a zero"))
        #expect(prompt.contains("C003C407"), "the misreading is named, not just the rule")
        #expect(
            prompt.contains("no reading of them as digits can be right"),
            "the override is justified, so it does not read as licence to invent"
        )
    }

    /// The reservation page keeps its desk id in the heading and nowhere else,
    /// and surrounds it with numbers that are not desks.
    @Test("The prompt accounts for the reservation page")
    func promptReadsTheReservationPage() {
        let prompt = HaikuClient.systemPrompt
        #expect(prompt.contains("Reservation for"), "the heading holds the desk id")
        #expect(
            prompt.contains("no separate desk field"),
            "so it must be read from the heading rather than looked for elsewhere"
        )
        #expect(prompt.contains("WRES"), "a reservation number is not a desk id")
        #expect(prompt.contains("9 Hours"), "nor is a duration a time")
        #expect(
            prompt.contains("read both and take the date from the start"),
            "this layout prints a real end time, so nothing is defaulted"
        )
    }

}

/// The conversion in front of the model call. A photographed confirmation came
/// back `400 … image exceeds 10 MB maximum: 11907424 bytes`, and every case
/// here is one of the reasons that happened.
@Suite("Preparing an image for the API")
struct PhotoImportTests {

    @Test("A 12MP frame is cut to the long edge the API downsizes to anyway")
    func oversizedIsResampled() throws {
        let (data, mediaType) = try PhotoImport.prepare(
            makeImage(width: 5712, height: 4284, type: .jpeg)
        )
        #expect(mediaType == "image/jpeg")
        let size = try #require(dimensions(data))
        #expect(size.width == PhotoImport.maxEdge, "the long edge is the one that is capped")
        #expect(size.height == 1176, "and the aspect ratio survives it")
    }

    /// The camera's own format, which the API does not accept at any size.
    @Test("HEIC becomes JPEG")
    func heicIsTranscoded() throws {
        let heic = makeImage(width: 800, height: 600, type: .heic)
        // Encoding HEIC needs an encoder the host may not have. The decode side
        // is what ships and it is the same code either way, so a host without
        // one has nothing to say here rather than something to fail about.
        guard !heic.isEmpty else { return }
        #expect(try PhotoImport.prepare(heic).mediaType == "image/jpeg")
    }

    /// The one that would leave the model a sideways page. The rotation lives
    /// in EXIF, not in the pixels, so a re-encode that ignores it silently
    /// turns a readable confirmation into an unreadable one.
    @Test("A landscape photo's EXIF rotation is baked into the pixels")
    func orientationIsApplied() throws {
        let sideways = makeImage(width: 4000, height: 3000, type: .jpeg, orientation: 6)
        let size = try #require(dimensions(try PhotoImport.prepare(sideways).data))
        #expect(size.height > size.width, "orientation 6 is a quarter turn")
    }

    @Test("An acceptable format at an acceptable size is not touched")
    func smallPNGPassesThrough() throws {
        let png = makeImage(width: 900, height: 600, type: .png)
        let (data, mediaType) = try PhotoImport.prepare(png)
        #expect(mediaType == "image/png")
        #expect(data == png, "a lossy round-trip could only make the text harder to read")
    }

    /// Dimensions alone are not the bound the API rejected on — a screenshot
    /// can sit inside 1568px and still be megabytes of PNG.
    @Test("A within-bounds image that is simply too many bytes is re-encoded")
    func oversizedBytesAreReencoded() throws {
        let noisy = makeImage(width: 1500, height: 1400, type: .png, noisy: true)
        try #require(noisy.count > PhotoImport.maxBytes, "the fixture has to be incompressible")
        let (data, mediaType) = try PhotoImport.prepare(noisy)
        #expect(mediaType == "image/jpeg")
        #expect(data.count < PhotoImport.maxBytes)
    }

    @Test("Bytes that are not an image say so rather than being sent")
    func rubbishThrows() {
        #expect(throws: CaptureError.unreadableImage) {
            try PhotoImport.prepare(Data("screenshot".utf8))
        }
        #expect(throws: CaptureError.unreadableImage) {
            try PhotoImport.prepare(Data())
        }
    }

    // MARK: Fixtures

    /// Flat grey unless `noisy`, which fills the buffer with something that
    /// will not compress — the only way to get a large file at small
    /// dimensions.
    func makeImage(
        width: Int, height: Int, type: UTType, orientation: Int? = nil, noisy: Bool = false
    ) -> Data {
        var pixels = [UInt8](repeating: 128, count: width * height * 4)
        if noisy {
            // xorshift rather than anything periodic: a repeating pattern is
            // exactly what PNG is good at, and the fixture only earns its keep
            // if it refuses to compress.
            var state: UInt64 = 0x2545_F491_4F6C_DD1D
            for index in pixels.indices {
                state ^= state << 13
                state ^= state >> 7
                state ^= state << 17
                pixels[index] = UInt8(truncatingIfNeeded: state)
            }
        }
        let image: CGImage? = pixels.withUnsafeMutableBytes { buffer in
            CGContext(
                data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            )?.makeImage()
        }
        let out = NSMutableData()
        guard let image, let writer = CGImageDestinationCreateWithData(
            out, type.identifier as CFString, 1, nil
        ) else { return Data() }
        var properties: [CFString: Any] = [:]
        if let orientation { properties[kCGImagePropertyOrientation] = orientation }
        CGImageDestinationAddImage(writer, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(writer) else { return Data() }
        return out as Data
    }

    func dimensions(_ data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (width, height)
    }
}

@Suite("Office matching")
struct OfficeMatcherTests {

    let london = OfficeMatcher.Candidate(
        id: UUID(), name: "Coleman", postcode: "EC2R 5BB", address: "London"
    )
    let brussels = OfficeMatcher.Candidate(
        id: UUID(), name: "Brussels", postcode: "1040", address: "Rue de la Loi 42"
    )

    var offices: [OfficeMatcher.Candidate] { [london, brussels] }

    @Test("The office name as printed matches the one the user typed")
    func matchesByName() {
        #expect(OfficeMatcher.match("Coleman, London", against: offices)?.id == london.id)
        #expect(OfficeMatcher.match("coleman", against: offices)?.id == london.id)
        #expect(OfficeMatcher.match("Brussels", against: offices)?.id == brussels.id)
    }

    @Test("A postcode is unambiguous, so it wins")
    func matchesByPostcode() {
        #expect(
            OfficeMatcher.match("Somewhere, EC2R 5BB", against: offices)?.id == london.id
        )
    }

    /// A wrong match files a booking under the wrong building — worse than
    /// asking, so anything short of certain returns nil and the sheet asks.
    @Test("No match, and an ambiguous match, both return nothing")
    func refusesToGuess() {
        #expect(OfficeMatcher.match("Ropemaker Place", against: offices) == nil)
        #expect(OfficeMatcher.match(nil, against: offices) == nil)
        #expect(OfficeMatcher.match("", against: offices) == nil)
        #expect(OfficeMatcher.match("Coleman", against: []) == nil)

        let twins = [
            london,
            OfficeMatcher.Candidate(id: UUID(), name: "Coleman", postcode: "", address: "Leeds"),
        ]
        #expect(OfficeMatcher.match("Coleman", against: twins) == nil, "two look right; ask")
    }

    /// The floor number in "03, Coleman, London" is not a building name.
    @Test("Noise words and floor numbers do not break the match")
    func ignoresNoise() {
        #expect(OfficeMatcher.match("03, Coleman, London", against: offices)?.id == london.id)
        #expect(
            OfficeMatcher.match("The Coleman Building", against: offices)?.id == london.id
        )
    }

    // MARK: What the sheet was told

    /// An office saved as "Euroclear London" shares only the city with a
    /// printed "Coleman, London", so no rule here can match them and the sheet
    /// asks. Once answered, it must stop asking.
    let euroclear = OfficeMatcher.Candidate(
        id: UUID(), name: "Euroclear London", postcode: "", address: "",
        aliases: ["Coleman, London"]
    )

    @Test("A name the sheet was told about matches, where no rule could")
    func matchesByAlias() {
        #expect(OfficeMatcher.match("Coleman, London", against: [euroclear])?.id == euroclear.id)
        #expect(
            OfficeMatcher.match("Coleman, London", against: [brussels]) == nil,
            "an office without the alias is still no match"
        )
    }

    /// The same building prints with a floor in front of it on some rows and
    /// not on others. An alias taught by one row has to hold for the next.
    @Test("An alias is the same answer with the floor in front of it")
    func aliasIgnoresTheFloor() {
        #expect(
            OfficeMatcher.match("03, Coleman, London", against: [euroclear])?.id == euroclear.id
        )
        #expect(
            OfficeMatcher.match("coleman london", against: [euroclear])?.id == euroclear.id
        )
    }

    /// An alias is an answer, not a heuristic — it outranks the name rule that
    /// would otherwise have claimed this printed name for somebody else.
    @Test("An alias beats a name that merely looks right")
    func aliasWinsOverTheNameRule() {
        let taught = OfficeMatcher.Candidate(
            id: UUID(), name: "Euroclear London", postcode: "", address: "",
            aliases: ["Coleman"]
        )
        let matched = OfficeMatcher.match("Coleman", against: [london, taught])
        #expect(matched?.id == taught.id, "the answer wins over the resemblance")
    }

    /// Nothing should ever write this, since remembering strips the name off
    /// every other office. If it happens anyway, asking beats picking one.
    @Test("Two offices claiming one name is still a question")
    func twoClaimsAskAgain() {
        let rival = OfficeMatcher.Candidate(
            id: UUID(), name: "Euroclear Leeds", postcode: "", address: "",
            aliases: ["Coleman, London"]
        )
        #expect(OfficeMatcher.match("Coleman, London", against: [euroclear, rival]) == nil)
    }
}
