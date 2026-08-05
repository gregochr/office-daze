import Foundation
import SwiftData
import Testing
@testable import Travel8tor

// MARK: - A real .pkpass, built in the test

/// Writes a stored (uncompressed) ZIP containing one file. Enough to exercise
/// the archive reader end to end without checking a binary fixture into git.
func makeZip(named name: String, contents: Data) -> Data {
    var data = Data()
    let nameBytes = Data(name.utf8)
    let crc = crc32(contents)

    func u16(_ value: UInt16) -> Data {
        Data([UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF)])
    }
    func u32(_ value: UInt32) -> Data {
        Data([
            UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF),
            UInt8(value >> 16 & 0xFF), UInt8(value >> 24 & 0xFF),
        ])
    }

    // Local file header
    let localOffset = data.count
    data.append(u32(0x0403_4B50))
    data.append(u16(20))                      // version needed
    data.append(u16(0))                       // flags
    data.append(u16(0))                       // method: stored
    data.append(u16(0)); data.append(u16(0))  // mod time, mod date
    data.append(u32(crc))
    data.append(u32(UInt32(contents.count)))  // compressed
    data.append(u32(UInt32(contents.count)))  // uncompressed
    data.append(u16(UInt16(nameBytes.count)))
    data.append(u16(0))                       // extra length
    data.append(nameBytes)
    data.append(contents)

    // Central directory
    let centralOffset = data.count
    data.append(u32(0x0201_4B50))
    data.append(u16(20)); data.append(u16(20))
    data.append(u16(0)); data.append(u16(0))
    data.append(u16(0)); data.append(u16(0))
    data.append(u32(crc))
    data.append(u32(UInt32(contents.count)))
    data.append(u32(UInt32(contents.count)))
    data.append(u16(UInt16(nameBytes.count)))
    data.append(u16(0)); data.append(u16(0))  // extra, comment
    data.append(u16(0)); data.append(u16(0))  // disk, internal attrs
    data.append(u32(0))                       // external attrs
    data.append(u32(UInt32(localOffset)))
    data.append(nameBytes)
    let centralSize = data.count - centralOffset

    // End of central directory
    data.append(u32(0x0605_4B50))
    data.append(u16(0)); data.append(u16(0))
    data.append(u16(1)); data.append(u16(1))
    data.append(u32(UInt32(centralSize)))
    data.append(u32(UInt32(centralOffset)))
    data.append(u16(0))                       // comment length
    return data
}

func crc32(_ data: Data) -> UInt32 {
    var table = [UInt32](repeating: 0, count: 256)
    for index in 0..<256 {
        var value = UInt32(index)
        for _ in 0..<8 {
            value = value & 1 == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1
        }
        table[index] = value
    }
    var crc: UInt32 = 0xFFFF_FFFF
    for byte in data {
        crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
    }
    return crc ^ 0xFFFF_FFFF
}

let eurostarPassJSON = """
{
  "formatVersion": 1,
  "passTypeIdentifier": "pass.com.eurostar.ticket",
  "serialNumber": "XKR48821",
  "organizationName": "Eurostar",
  "description": "Eurostar ticket",
  "relevantDate": "2026-09-07T17:04:00+01:00",
  "expirationDate": "2026-09-07T20:05:00+02:00",
  "boardingPass": {
    "transitType": "PKTransitTypeTrain",
    "primaryFields": [
      {"key": "origin", "label": "London", "value": "St Pancras"},
      {"key": "destination", "label": "Brussels", "value": "Brussels Midi"}
    ],
    "secondaryFields": [
      {"key": "coach", "label": "Coach", "value": "09"},
      {"key": "seat", "label": "Seat", "value": 51}
    ],
    "backFields": [
      {"key": "bookingRef", "label": "Booking reference", "value": "XKR48821"}
    ]
  }
}
"""

@Suite("Zip archive")
struct ZipArchiveTests {

    @Test("Reads an entry back out of a stored archive")
    func roundTrip() throws {
        let payload = Data(eurostarPassJSON.utf8)
        let zip = makeZip(named: "pass.json", contents: payload)

        let entries = try ZipArchive.entries(in: zip)
        #expect(entries.map(\.name) == ["pass.json"])
        #expect(try ZipArchive.extract("pass.json", from: zip) == payload)
    }

    @Test("A missing entry is reported, not guessed at")
    func missingEntry() {
        let zip = makeZip(named: "manifest.json", contents: Data("{}".utf8))
        #expect(throws: CaptureError.missingPassJSON) {
            try ZipArchive.extract("pass.json", from: zip)
        }
    }

    @Test("Something that isn't a zip is rejected rather than misread")
    func notAZip() {
        #expect(throws: CaptureError.notAZip) {
            try ZipArchive.entries(in: Data(repeating: 0x41, count: 512))
        }
        #expect(throws: CaptureError.notAZip) {
            try ZipArchive.entries(in: Data())
        }
    }
}

@Suite("Pass parsing")
struct PassParserTests {

    @Test("A Eurostar pass parses with no model call")
    func eurostar() throws {
        let zip = makeZip(named: "pass.json", contents: Data(eurostarPassJSON.utf8))
        let parsed = try PassParser.parse(passFile: zip)

        #expect(parsed.kind == .rail)
        #expect(parsed.provenance == .pass)
        #expect(parsed.confidence == .high)
        #expect(!parsed.costedCall, "a pass file is free — no model call")

        let rail = try #require(parsed.detail.railDetail)
        #expect(rail.operatorName == "Eurostar")
        #expect(rail.originStation == "St Pancras")
        #expect(rail.destStation == "Brussels Midi")
        #expect(rail.coach == "09")
        #expect(rail.seat == "51", "a numeric JSON value still reads as a seat")
        #expect(rail.bookingRef == "XKR48821")

        // Cities and zones are derived from the stations, not from the offset:
        // +01:00 is London in summer and Brussels in winter.
        #expect(rail.originCity == "London")
        #expect(rail.destCity == "Brussels")
        #expect(parsed.startZoneID == "Europe/London")
        #expect(parsed.endZoneID == "Europe/Brussels")

        // 17:04 London, 20:05 Brussels — the design's ticket screen.
        #expect(TimeDisplay.local(parsed.startsAt, in: parsed.startZone) == "17:04")
        let arrival = try #require(parsed.endsAt)
        #expect(TimeDisplay.local(arrival, in: try #require(parsed.endZone)) == "20:05")
        #expect(TimeDisplay.duration(from: parsed.startsAt, to: arrival) == "2h01")
    }

    @Test("A field the pass omits is named, never invented")
    func missingFieldsAreNamed() throws {
        let zip = makeZip(named: "pass.json", contents: Data(eurostarPassJSON.utf8))
        let parsed = try PassParser.parse(passFile: zip)

        // The pass carries no platform — Eurostar assigns one on the day.
        #expect(parsed.detail.railDetail?.platform == nil)
        #expect(parsed.unsureFields.contains("platform"))
        #expect(!parsed.unsureFields.contains("coach"), "coach was present")
        #expect(!parsed.unsureFields.contains("seat"))
    }

    @Test("A pass with no departure time fails rather than assuming one")
    func noDeparture() {
        let json = """
        {"organizationName":"LNER","boardingPass":{"transitType":"PKTransitTypeTrain",
        "primaryFields":[{"key":"origin","value":"Durham"},{"key":"destination","value":"KGX"}]}}
        """
        let zip = makeZip(named: "pass.json", contents: Data(json.utf8))
        #expect(throws: CaptureError.malformedPass("no departure time")) {
            try PassParser.parse(passFile: zip)
        }
    }

    @Test("A non-transit pass is refused rather than mangled into a booking")
    func notABoardingPass() {
        let json = #"{"organizationName":"Costa","storeCard":{"primaryFields":[]}}"#
        let zip = makeZip(named: "pass.json", contents: Data(json.utf8))
        #expect(throws: CaptureError.malformedPass("pass is not a boarding pass")) {
            try PassParser.parse(passFile: zip)
        }
    }

    @Test("ISO offsets are read for the zone fallback")
    func offsets() {
        #expect(PassParser.isoOffset("2026-09-07T17:04:00+01:00") == 3600)
        #expect(PassParser.isoOffset("2026-09-07T20:05:00+02:00") == 7200)
        #expect(PassParser.isoOffset("2026-01-07T09:00:00-05:00") == -18_000)
        #expect(PassParser.isoOffset("2026-09-07T16:04:00Z") == 0)
        #expect(PassParser.isoOffset("nonsense") == nil)
    }
}

@Suite("Model extraction")
struct ExtractedTests {

    /// The wire shape the model returns, as JSON, so the test exercises the
    /// same decode path a real response takes.
    func decode(_ json: String) throws -> Extracted {
        try JSONDecoder().decode(Extracted.self, from: Data(json.utf8))
    }

    @Test("The Ropewalk case: an unread check-in stores nothing and is named")
    func unreadCheckIn() throws {
        let extracted = try decode("""
        {"kind":"stay","confidence":"low","unsureFields":["checkIn","bookingRef"],
         "rail":null,"desk":null,
         "stay":{"hotelName":"The Ropewalk","address":"41 Rivington St","city":"London",
                 "checkIn":null,"checkOut":"2026-09-11T11:00:00+01:00",
                 "zone":"Europe/London","nights":1,"bookingRef":null}}
        """)
        let parsed = try extracted.parsed(today: Day(2026, 8, 4))

        #expect(parsed.kind == .stay)
        #expect(parsed.confidence == .low)
        #expect(parsed.detail.stayDetail?.checkIn == nil, "nothing stored for an unread field")
        #expect(parsed.detail.stayDetail?.bookingRef == nil)
        #expect(parsed.unsureFields.contains("checkIn"))
        #expect(parsed.unsureFields.contains("bookingRef"))

        // Even with the clock unreadable, the booking is filed under the right
        // night — check-out minus the nights.
        #expect(Day(of: parsed.startsAt, in: parsed.startZone) == Day(2026, 9, 10))
    }

    @Test("A value beside its own name in unsureFields is discarded")
    func namedFieldsAreDiscarded() throws {
        // The model was told to omit what it couldn't read. If it names a field
        // *and* supplies a value, the value is exactly the plausible guess the
        // design forbids storing — so it is dropped rather than trusted.
        let extracted = try decode("""
        {"kind":"stay","confidence":"low","unsureFields":["checkIn"],
         "rail":null,"desk":null,
         "stay":{"hotelName":"The Ropewalk","address":null,"city":"London",
                 "checkIn":"2026-09-10T15:00:00+01:00","checkOut":"2026-09-11T11:00:00+01:00",
                 "zone":"Europe/London","nights":1,"bookingRef":null}}
        """)
        let parsed = try extracted.parsed(today: Day(2026, 8, 4))
        #expect(parsed.detail.stayDetail?.checkIn == nil, "a named field's value is not stored")
    }

    @Test("A null field the model forgot to name is named anyway")
    func nullFieldsAreNamed() throws {
        let extracted = try decode("""
        {"kind":"rail","confidence":"high","unsureFields":[],
         "desk":null,"stay":null,
         "rail":{"operatorName":"LNER","originStation":"Durham","destStation":"King's Cross",
                 "originCity":"Durham","destCity":"London",
                 "departsAt":"2026-09-07T06:40:00+01:00","departZone":"Europe/London",
                 "arrivesAt":"2026-09-07T09:33:00+01:00","arriveZone":"Europe/London",
                 "platform":"2","coach":null,"seat":null,"bookingRef":"LNR44120","checkInBy":null}}
        """)
        let parsed = try extracted.parsed(today: Day(2026, 8, 4))

        // The model returned an empty unsureFields but left coach and seat
        // null. The amber count has to be the truth, so they are named here.
        #expect(parsed.unsureFields.contains("coach"))
        #expect(parsed.unsureFields.contains("seat"))
        #expect(!parsed.unsureFields.contains("platform"))
        #expect(parsed.detail.railDetail?.platform == "2")
    }

    @Test("An unreadable departure fails rather than inventing a time")
    func noDeparture() throws {
        let extracted = try decode("""
        {"kind":"rail","confidence":"low","unsureFields":["departsAt"],
         "desk":null,"stay":null,
         "rail":{"operatorName":"LNER","originStation":"Durham","destStation":"KGX",
                 "originCity":"Durham","destCity":"London",
                 "departsAt":null,"departZone":null,"arrivesAt":null,"arriveZone":null,
                 "platform":null,"coach":null,"seat":null,"bookingRef":null,"checkInBy":null}}
        """)
        #expect(throws: CaptureError.self) {
            try extracted.parsed(today: Day(2026, 8, 4))
        }
    }

    @Test("The model's zone identifier wins; the offset is the fallback")
    func zoneResolution() throws {
        let extracted = try decode("""
        {"kind":"desk","confidence":"high","unsureFields":[],
         "rail":null,"stay":null,
         "desk":{"placeName":"Ropemaker Place","address":"25 Ropemaker St","city":"London",
                 "date":"2026-09-11T09:00:00+01:00","zone":null,
                 "floor":"L3","deskID":"3C-118","hours":"09-17"}}
        """)
        let parsed = try extracted.parsed(today: Day(2026, 8, 4))
        // No zone from the model, but a known city — the identifier beats the
        // offset because only the identifier survives a DST boundary.
        #expect(parsed.startZoneID == "Europe/London")
        #expect(parsed.detail.deskDetail?.deskID == "3C-118")
    }

    @Test("A refusal is surfaced, not silently empty")
    func refusal() {
        let json = #"{"stop_reason":"refusal","content":[],"usage":{}}"#
        #expect(throws: CaptureError.self) {
            try HaikuClient.decode(Data(json.utf8), today: Day(2026, 8, 4))
        }
    }

    @Test("Token counts are read off the response for the cost record")
    func usage() throws {
        let inner = """
        {"bookings":[
         {"kind":"stay","confidence":"high","unsureFields":[],"rail":null,"desk":null,
          "stay":{"hotelName":"Hotel Sablon","address":null,"city":"Brussels",
                  "checkIn":"2026-09-07T21:00:00+02:00","checkOut":"2026-09-10T11:00:00+02:00",
                  "zone":"Europe/Brussels","nights":3,"bookingRef":null}}]}
        """
        let envelope: [String: Any] = [
            "content": [["type": "text", "text": inner]],
            "usage": ["input_tokens": 1234, "output_tokens": 210],
        ]
        let data = try JSONSerialization.data(withJSONObject: envelope)

        let (batch, usage) = try HaikuClient.decode(data, today: Day(2026, 8, 4))
        #expect(usage.inputTokens == 1234)
        #expect(usage.outputTokens == 210)
        let parsed = try #require(batch.bookings.first)
        #expect(parsed.detail.stayDetail?.hotelName == "Hotel Sablon")
        #expect(parsed.startZoneID == "Europe/Brussels")
        #expect(parsed.costedCall, "a model call is costed")
    }
}

/// A screenshot of a desk system is a table, and every row of it is a booking.
/// Reading one and dropping the rest would look like a successful capture.
@Suite("Several bookings in one document")
struct BatchTests {

    /// The Coleman week, as the desk system prints it: same building, same
    /// hours, one row per day.
    func table(rows: [(day: Int, desk: String)]) -> String {
        let bookings = rows.map { row in
            """
            {"kind":"desk","confidence":"high","unsureFields":[],"rail":null,"stay":null,
             "desk":{"placeName":"Coleman","address":"","city":"London",
                     "date":"2026-08-\(String(format: "%02d", row.day))T08:00:00+01:00",
                     "zone":"Europe/London","floor":"03","deskID":"\(row.desk)",
                     "hours":"08:00-17:00"}}
            """
        }
        return "{\"bookings\":[\(bookings.joined(separator: ","))]}"
    }

    func decode(_ json: String) throws -> ExtractedBatch {
        try JSONDecoder().decode(ExtractedBatch.self, from: Data(json.utf8))
    }

    @Test("Every row of the table becomes its own booking")
    func rowsAreBookings() throws {
        let json = table(rows: [
            (4, "CO03A424"), (5, "CO03C407"), (6, "CO03D211"),
        ])
        let batch = try decode(json).parsed(today: Day(2026, 8, 4))

        #expect(batch.bookings.count == 3, "three rows, three bookings")
        #expect(batch.unreadable.isEmpty)
        #expect(
            batch.bookings.compactMap { $0.detail.deskDetail?.deskID }
                == ["CO03A424", "CO03C407", "CO03D211"],
            "in the order printed"
        )
        // Same building three days running is three bookings, not one. Nothing
        // here may collapse them; the desk changes and so does the day.
        #expect(Set(batch.bookings.map(\.startsAt)).count == 3)
    }

    @Test("A single booking is a list of one, not a special case")
    func oneRow() throws {
        let batch = try decode(table(rows: [(5, "CO03C407")])).parsed(today: Day(2026, 8, 4))
        #expect(batch.bookings.count == 1)
        #expect(batch.unreadable.isEmpty)
    }

    @Test("An unreadable row is carried, not allowed to sink the readable ones")
    func partialTable() throws {
        // Three-quarters of a table beats none of it: what read is committed,
        // and the row that didn't is reported once the rest are through.
        let json = """
        {"bookings":[
         {"kind":"desk","confidence":"high","unsureFields":["date"],"rail":null,"stay":null,
          "desk":{"placeName":"Coleman","address":"","city":"London","date":"",
                  "zone":"Europe/London","floor":"03","deskID":"CO03A424","hours":""}},
         {"kind":"desk","confidence":"high","unsureFields":[],"rail":null,"stay":null,
          "desk":{"placeName":"Coleman","address":"","city":"London",
                  "date":"2026-08-06T08:00:00+01:00","zone":"Europe/London",
                  "floor":"03","deskID":"CO03D211","hours":"08:00-17:00"}}]}
        """
        let batch = try decode(json).parsed(today: Day(2026, 8, 4))

        #expect(batch.bookings.count == 1)
        #expect(batch.bookings.first?.detail.deskDetail?.deskID == "CO03D211")
        #expect(batch.unreadable.count == 1, "the cut-off row is reported, not dropped silently")
    }

    @Test("A document with nothing readable in it is still a failure")
    func nothingReadable() throws {
        let json = """
        {"bookings":[
         {"kind":"desk","confidence":"low","unsureFields":["date","deskID"],
          "rail":null,"stay":null,
          "desk":{"placeName":"Coleman","address":"","city":"London","date":"",
                  "zone":"","floor":"","deskID":"","hours":""}}]}
        """
        #expect(throws: CaptureError.self) {
            try decode(json).parsed(today: Day(2026, 8, 4))
        }
    }

    @Test("An empty list is a failure rather than a silent success")
    func emptyList() throws {
        #expect(throws: CaptureError.self) {
            try decode(#"{"bookings":[]}"#).parsed(today: Day(2026, 8, 4))
        }
    }
}

@Suite("The extraction schema")
struct SchemaTests {

    /// Structured outputs reject a schema whose objects don't set
    /// `additionalProperties: false` and list every property in `required`.
    /// Getting that wrong is a 400 at the worst possible moment.
    @Test("Every object is closed and fully required")
    func schemaIsWellFormed() throws {
        func check(_ node: Any, path: String) {
            guard let object = node as? [String: Any] else { return }

            if object["type"] as? String == "object" {
                let properties = object["properties"] as? [String: Any] ?? [:]
                #expect(object["additionalProperties"] as? Bool == false, "\(path) is open")
                let required = Set(object["required"] as? [String] ?? [])
                #expect(required == Set(properties.keys), "\(path) does not require every property")
                for (key, value) in properties { check(value, path: "\(path).\(key)") }
            }
            for branch in object["anyOf"] as? [Any] ?? [] { check(branch, path: path) }
        }
        check(HaikuClient.schema, path: "root")
    }

    @Test("The schema is JSON-serialisable")
    func serialisable() throws {
        // It goes over the wire inside a request body — a non-serialisable
        // value here would be a runtime crash at capture time.
        #expect(JSONSerialization.isValidJSONObject(HaikuClient.schema))
        _ = try JSONSerialization.data(withJSONObject: HaikuClient.schema)
    }

    /// `properties.bookings.items` — the shape one booking takes inside the
    /// list the root now returns.
    var bookingItem: [String: Any]? {
        let root = HaikuClient.schema["properties"] as? [String: Any]
        let bookings = root?["bookings"] as? [String: Any]
        return bookings?["items"] as? [String: Any]
    }

    @Test("The root returns a list, so a table is not silently truncated to its first row")
    func rootIsAList() throws {
        let bookings = try #require(
            (HaikuClient.schema["properties"] as? [String: Any])?["bookings"] as? [String: Any]
        )
        #expect(bookings["type"] as? String == "array")
        #expect(bookingItem?["type"] as? String == "object")
        #expect(HaikuClient.userPrompt(today: Day(2026, 8, 5)).contains("every booking"))
        #expect(HaikuClient.systemPrompt.contains("one row per day"))
    }

    @Test("Every kind is offered and the never-guess rule is in the prompt")
    func promptAndKinds() {
        let kinds = (bookingItem?["properties"] as? [String: Any])?["kind"] as? [String: Any]
        #expect(Set(kinds?["enum"] as? [String] ?? []) == ["rail", "desk", "stay"])
        #expect(HaikuClient.systemPrompt.contains("NEVER INFER A VALUE"))
        #expect(HaikuClient.systemPrompt.contains("unsureFields"))
    }

    /// The 400 that cost a commit to find: structured outputs cap the number of
    /// union-typed parameters, and nesting the booking inside an array must not
    /// have multiplied them.
    @Test("Wrapping the booking in a list adds no union types")
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
}

@Suite("Confirm screen fields")
struct ConfirmFieldsTests {

    /// The Ropewalk as the model returns it: the check-in time is unreadable,
    /// but the night it covers is not.
    var ropewalk: ParsedBooking {
        ParsedBooking(
            detail: .stay(StayDetail(
                hotelName: "The Ropewalk", address: "41 Rivington St", city: "London",
                checkIn: nil,
                checkOut: Day(2026, 9, 11).at(11, 0, in: TimeDisplay.uk),
                nights: 1, bookingRef: nil
            )),
            startsAt: Day(2026, 9, 10).at(19, 30, in: TimeDisplay.uk),
            startZoneID: "Europe/London",
            endsAt: Day(2026, 9, 11).at(11, 0, in: TimeDisplay.uk),
            endZoneID: "Europe/London",
            unsureFields: ["checkIn", "bookingRef"],
            provenance: .screengrab, confidence: .low
        )
    }

    @Test("The amber count matches the amber boxes")
    func countMatchesBoxes() {
        let fields = ConfirmFields.fields(for: ropewalk)
        // The banner reads "02 OF 07 FIELDS UNREADABLE", so exactly two rows
        // must render amber — a mismatch reads as a bug in the count.
        #expect(fields.count == 7)
        #expect(fields.filter(\.unreadable).count == ropewalk.unsureFields.count)
    }

    @Test("The night is readable even when the check-in time is not")
    func nightIsNotFlagged() {
        let fields = ConfirmFields.fields(for: ropewalk)
        let night = fields.first { $0.label == "NIGHT OF" }
        let checkIn = fields.first { $0.label == "CHECK-IN" }

        #expect(night?.unreadable == false, "the night comes from check-out minus the nights")
        #expect(night?.value == "THU 10.09")
        #expect(checkIn?.unreadable == true)
        #expect(checkIn?.value == "??:??", "a time is never blank, always the placeholder")
    }

    @Test("An unreadable field is never blank")
    func neverBlank() {
        for field in ConfirmFields.fields(for: ropewalk) where field.unreadable {
            #expect(!field.value.isEmpty)
        }
    }

    @Test("A complete pass shows no amber at all")
    func completePassIsClean() throws {
        let zip = makeZip(named: "pass.json", contents: Data(eurostarPassJSON.utf8))
        let parsed = try PassParser.parse(passFile: zip)
        let fields = ConfirmFields.fields(for: parsed)

        // The pass has no platform, so that one row is amber — and only it.
        let amber = fields.filter(\.unreadable).map(\.label)
        #expect(amber == ["PLATFORM"])
        #expect(fields.first { $0.label == "COACH" }?.value == "09")
        #expect(fields.first { $0.label == "DEPARTS" }?.value == "17:04")
    }
}

@Suite("API key check")
struct APIKeyCheckTests {

    /// Shaped like a real key: the prefix, then enough characters that length
    /// is not what is being tested.
    let plausible = "sk-ant-api03-" + String(repeating: "A", count: 95)

    @Test("A key-shaped string passes")
    func accepts() {
        #expect(APIKeyCheck.validate(plausible) == nil)
        // Whitespace from a paste is trimmed, not rejected.
        #expect(APIKeyCheck.validate("  \(plausible)\n") == nil)
    }

    @Test("The masked key the console shows after the fact is caught by name")
    func catchesMasked() {
        // The likeliest way to arrive at a 401: copying what the console
        // displays once you navigate back to it, rather than at creation.
        #expect(APIKeyCheck.validate("sk-ant-api03-abc…xyz") == .masked)
        #expect(APIKeyCheck.validate("sk-ant-api03-abc...xyz") == .masked)
    }

    @Test("Masked is reported before wrong-prefix, since a masked key has the prefix")
    func maskedBeatsPrefix() {
        // "That does not look like an API key" would be a misleading thing to
        // say about a string that is unmistakably a masked one.
        let masked = "sk-ant-…QAA7"
        #expect(APIKeyCheck.validate(masked) == .masked)
        #expect(APIKeyCheck.validate(masked) != .wrongPrefix)
    }

    @Test("Something that is not a key at all is refused")
    func catchesNonKey() {
        #expect(APIKeyCheck.validate("") == .empty)
        #expect(APIKeyCheck.validate("   ") == .empty)
        // A key's *name* rather than the key.
        #expect(APIKeyCheck.validate("travel8tor-key") == .wrongPrefix)
    }

    @Test("A truncated paste is caught and its length named")
    func catchesTruncation() {
        #expect(APIKeyCheck.validate("sk-ant-api03-tooshort") == .tooShort(21))
        // The message says the number, so the cause is diagnosable.
        #expect(APIKeyCheck.Problem.tooShort(21).message.contains("21"))
    }

    @Test("The fingerprint identifies a key without disclosing it")
    func fingerprint() {
        let print = APIKeyCheck.fingerprint(plausible)
        #expect(print.hasPrefix("sk-ant-…"))
        #expect(print.contains("108 CHARS"))
        // The body of the key never appears.
        #expect(!print.contains(String(repeating: "A", count: 10)))
    }

    @Test("Every problem says something, upper case but for the literal prefix")
    func messages() {
        let problems: [APIKeyCheck.Problem] = [.empty, .wrongPrefix, .masked, .tooShort(5)]
        for problem in problems {
            #expect(!problem.message.isEmpty)
            // The interface shouts, but `sk-ant-` is quoted verbatim: printing
            // it as SK-ANT- would be telling the user to look for the wrong
            // thing. Everything that is not that literal is upper case.
            let prose = problem.message.replacingOccurrences(of: APIKeyCheck.prefix, with: "")
            #expect(prose == prose.uppercased())
        }
    }
}

@Suite("Schema limits")
struct SchemaLimitTests {

    /// The API's ceiling on union-typed parameters. Exceeding it is a 400 at
    /// call time, not a compile error, so only a test catches it before a
    /// capture does.
    static let unionLimit = 16

    /// Counts properties whose type is a union — either `anyOf` or a type
    /// array — the way the API's own error message counts them.
    static func unionCount(_ schema: [String: Any]) -> Int {
        var found = 0

        func walk(_ node: Any) {
            guard let object = node as? [String: Any] else { return }
            if object["anyOf"] != nil { found += 1 }
            if object["type"] is [Any] { found += 1 }
            if let properties = object["properties"] as? [String: Any] {
                for value in properties.values { walk(value) }
            }
            if let items = object["items"] { walk(items) }
            for case let nested as [[String: Any]] in [object["anyOf"] as Any] {
                for branch in nested { walk(branch) }
            }
        }

        walk(schema)
        return found
    }

    @Test("The schema stays under the API's union limit")
    func underTheUnionLimit() {
        // This is a real failure, found on a phone: thirty-one nullable strings
        // plus three nullable detail objects came to 34 against a limit of 16,
        // and every capture died with a 400. Nullable strings became plain
        // strings where the empty string means "could not read".
        let count = Self.unionCount(HaikuClient.schema)
        #expect(
            count <= Self.unionLimit,
            "\(count) union-typed parameters; the API refuses more than \(Self.unionLimit)"
        )
    }

    @Test("An empty string from the model is an absence, not a value")
    func blankIsAbsence() throws {
        // The schema asks for "" rather than null on unreadable text. That
        // decision must not escape the mapping: nothing downstream should ever
        // see a blank where it expects a missing value.
        let json = """
        {"kind":"desk","confidence":"high","unsureFields":[],
         "desk":{"placeName":"Ropemaker Place","address":"","city":"London",
                 "date":"2026-09-11T09:00:00+01:00","zone":"Europe/London",
                 "floor":"","deskID":"3C-118","hours":"  "}}
        """
        let extracted = try JSONDecoder().decode(Extracted.self, from: Data(json.utf8))
        let parsed = try extracted.parsed(today: Day(2026, 9, 1))
        let desk = try #require(parsed.detail.deskDetail)

        #expect(desk.floor == nil, "an empty string is an absence")
        #expect(desk.hours == nil, "whitespace only is an absence too")
        #expect(desk.deskID == "3C-118")
        // And the blanks are named, so the amber flag still counts them.
        #expect(Set(parsed.unsureFields).isSuperset(of: ["floor", "hours"]))
    }
}

@Suite("Transient failures")
struct RetryTests {

    @Test("Overload and rate-limiting are retried")
    func retriesTransient() {
        // 529 is the API asking you to come back. Giving up on the first one
        // throws away a screenshot the user has already gone to the trouble
        // of sharing.
        #expect(HaikuClient.isTransient(529))
        #expect(HaikuClient.isTransient(429))
        #expect(HaikuClient.isTransient(500))
        #expect(HaikuClient.isTransient(503))
    }

    @Test("A fact about the request is not retried")
    func doesNotRetryTerminal() {
        // A bad schema or a bad key will be just as bad the second time, and
        // retrying only makes the user wait to hear it.
        #expect(!HaikuClient.isTransient(400))
        #expect(!HaikuClient.isTransient(401))
        #expect(!HaikuClient.isTransient(403))
        #expect(!HaikuClient.isTransient(404))
        #expect(!HaikuClient.isTransient(200))
    }

    @Test("The API's own retry-after wins over the backoff")
    func honoursRetryAfter() {
        #expect(HaikuClient.backoff(attempt: 1, retryAfter: "5") == .seconds(5))
        // Capped, so a wild value cannot hang the capture screen.
        #expect(HaikuClient.backoff(attempt: 1, retryAfter: "9999") == .seconds(30))
        // Nonsense is ignored rather than treated as zero.
        #expect(HaikuClient.backoff(attempt: 1, retryAfter: "soon") == .seconds(1))
        #expect(HaikuClient.backoff(attempt: 1, retryAfter: "0") == .seconds(1))
    }

    @Test("Without a retry-after it backs off exponentially")
    func exponentialBackoff() {
        #expect(HaikuClient.backoff(attempt: 1, retryAfter: nil) == .seconds(1))
        #expect(HaikuClient.backoff(attempt: 2, retryAfter: nil) == .seconds(2))
        // Three attempts total, so the waits are 1s and 2s and no more.
        #expect(HaikuClient.maxAttempts == 3)
    }
}
