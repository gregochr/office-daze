import Foundation

/// Path B: one Claude Haiku call over an image or PDF, returning strict JSON.
///
/// Raw HTTP rather than an SDK — Anthropic ships no official Swift SDK, and
/// this is one endpoint with one request shape. `URLSession` and `Codable` are
/// the whole dependency list.
///
/// Two things make the never-guess rule enforceable rather than aspirational:
///
///  1. **Structured outputs.** `output_config.format` constrains the response
///     to a JSON schema, so the model cannot return prose, a code fence, or a
///     differently-shaped object. Every optional field is nullable *and*
///     required, so the model has to emit an explicit `null` rather than
///     silently omitting a field it guessed at.
///  2. **The system prompt says it twice**, because the amber flag depends on
///     it: omit what you cannot read and name it in `unsureFields`.
nonisolated struct HaikuClient {

    /// The design brief specifies Haiku, and this is a bounded extraction from
    /// a single image — the cheapest model that does it well. Haiku 4.5
    /// supports structured outputs, which is what the strict-JSON requirement
    /// needs.
    static let model = "claude-haiku-4-5"
    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    static let apiVersion = "2023-06-01"

    var apiKey: String
    var session: URLSession = .shared

    // MARK: Request

    func extract(_ input: CaptureInput) async throws -> (ParsedBooking, Usage) {
        var request = URLRequest(url: HaikuClient.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(HaikuClient.apiVersion, forHTTPHeaderField: "anthropic-version")
        request.timeoutInterval = 60
        request.httpBody = try body(for: input)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw CaptureError.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw CaptureError.network("no HTTP response")
        }
        guard http.statusCode == 200 else {
            throw CaptureError.httpStatus(http.statusCode, HaikuClient.errorMessage(data))
        }

        return try HaikuClient.decode(data, today: input.today)
    }

    private func body(for input: CaptureInput) throws -> Data {
        var content: [[String: Any]] = []

        switch input.payload {
        case .image(let data, let mediaType):
            content.append([
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": mediaType,
                    "data": data.base64EncodedString(),
                ],
            ])
        case .pdf(let data):
            content.append([
                "type": "document",
                "source": [
                    "type": "base64",
                    "media_type": "application/pdf",
                    "data": data.base64EncodedString(),
                ],
            ])
        case .text(let text):
            content.append(["type": "text", "text": text])
        }

        content.append(["type": "text", "text": HaikuClient.userPrompt(today: input.today)])

        let payload: [String: Any] = [
            "model": HaikuClient.model,
            "max_tokens": 2048,
            "system": HaikuClient.systemPrompt,
            "output_config": ["format": ["type": "json_schema", "schema": HaikuClient.schema]],
            "messages": [["role": "user", "content": content]],
        ]

        return try JSONSerialization.data(withJSONObject: payload)
    }

    // MARK: Prompts

    static let systemPrompt = """
    You extract travel bookings from screenshots, photographs and PDFs into \
    structured data. There are three kinds: rail (a train ticket or \
    reservation), desk (an office desk or hot-desk booking), and stay (a hotel \
    or other overnight accommodation).

    The single most important rule: NEVER INFER A VALUE. If a field is not \
    legibly present in the image, set it to null and add its name to \
    unsureFields. Do not calculate it, do not deduce it from context, do not \
    supply a plausible default, and do not repeat a value from a different \
    field. A named unreadable field is a correct answer; a guessed value is a \
    wrong one, and it is worse than a blank because nobody downstream can tell \
    it apart from a real reading.

    Times are the common failure. If a booking shows a check-out time but not a \
    check-in time, checkIn is null and "checkIn" goes in unsureFields — do not \
    assume a standard hotel check-in hour. If a departure time is legible but \
    the arrival is cut off, arrival is null.

    Time zones: give every instant as an ISO 8601 string with an explicit UTC \
    offset, and give the IANA zone identifier separately (for example \
    "Europe/London", "Europe/Brussels"). Determine the zone from the location \
    of the event, not from where the reader might be. If you cannot determine \
    the location, set the zone to null and name it.

    Set confidence to "low" if the image is cropped, blurred, partially \
    obscured, or you are unsure of the booking kind. Otherwise "high".
    """

    static func userPrompt(today: Day) -> String {
        """
        Extract the booking from this document. Today's date is \(today) — use \
        it only to resolve a year that is genuinely absent from a date that is \
        otherwise legible, never to invent a date. Return only the structured \
        object.
        """
    }

    /// Structured-outputs schema. Every object sets `additionalProperties:
    /// false` and lists every property in `required` — the API requires both.
    /// Optional values are expressed as a nullable type rather than by being
    /// absent, which is what forces an explicit null instead of an omission.
    /// Computed rather than a stored global: `[String: Any]` is not Sendable,
    /// and this is built once per capture — a handful of dictionary literals.
    static var schema: [String: Any] {
        func nullableString(_ description: String) -> [String: Any] {
            ["anyOf": [["type": "string"], ["type": "null"]], "description": description]
        }
        func nullableInt(_ description: String) -> [String: Any] {
            ["anyOf": [["type": "integer"], ["type": "null"]], "description": description]
        }
        func object(_ properties: [String: Any]) -> [String: Any] {
            [
                "type": "object",
                "properties": properties,
                "required": Array(properties.keys),
                "additionalProperties": false,
            ]
        }
        func nullable(_ schema: [String: Any]) -> [String: Any] {
            ["anyOf": [schema, ["type": "null"]]]
        }

        let rail = object([
            "operatorName": nullableString("The train operator, e.g. LNER, Eurostar."),
            "originStation": nullableString("Departure station name as printed."),
            "destStation": nullableString("Arrival station name as printed."),
            "originCity": nullableString("City of the departure station."),
            "destCity": nullableString("City of the arrival station."),
            "departsAt": nullableString("ISO 8601 departure instant with UTC offset."),
            "departZone": nullableString("IANA zone at the departure station."),
            "arrivesAt": nullableString("ISO 8601 arrival instant with UTC offset, or null."),
            "arriveZone": nullableString("IANA zone at the arrival station."),
            "platform": nullableString("Platform number, or null if not printed."),
            "coach": nullableString("Coach or carriage, or null."),
            "seat": nullableString("Seat number, or null."),
            "bookingRef": nullableString("Booking reference or PNR, or null."),
            "checkInBy": nullableString("ISO 8601 gate-closing instant, or null."),
        ])

        let desk = object([
            "placeName": nullableString("Building name, e.g. Ropemaker Place."),
            "address": nullableString("Street address, or null."),
            "city": nullableString("City the building is in."),
            "date": nullableString("ISO 8601 date of the booking."),
            "zone": nullableString("IANA zone of the building."),
            "floor": nullableString("Floor or level, or null."),
            "deskZone": nullableString("Zone within the floor, or null."),
            "deskID": nullableString("Desk identifier, e.g. 3C-114."),
            "hours": nullableString("Booked hours as printed, or null."),
        ])

        let stay = object([
            "hotelName": nullableString("Hotel or property name."),
            "address": nullableString("Street address, or null."),
            "city": nullableString("City the property is in."),
            "checkIn": nullableString("ISO 8601 check-in instant, or null if not printed."),
            "checkOut": nullableString("ISO 8601 check-out instant, or null."),
            "zone": nullableString("IANA zone of the property."),
            "nights": nullableInt("Number of nights, or null."),
            "bookingRef": nullableString("Booking reference, or null."),
        ])

        return object([
            "kind": [
                "type": "string", "enum": ["rail", "desk", "stay"],
                "description": "Which kind of booking this is.",
            ],
            "confidence": [
                "type": "string", "enum": ["high", "low"],
                "description": "Low if the document is cropped, blurred or ambiguous.",
            ],
            "unsureFields": [
                "type": "array", "items": ["type": "string"],
                "description": "Names of every field you could not read. Must match the null fields.",
            ],
            "rail": nullable(rail),
            "desk": nullable(desk),
            "stay": nullable(stay),
        ])
    }

    // MARK: Response

    struct Usage: Hashable, Sendable {
        var inputTokens: Int
        var outputTokens: Int
    }

    static func decode(_ data: Data, today: Day) throws -> (ParsedBooking, Usage) {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CaptureError.modelReturnedNothingUsable("response was not JSON")
        }

        if let stop = root["stop_reason"] as? String, stop == "refusal" {
            throw CaptureError.modelReturnedNothingUsable("the model declined this document")
        }

        let usageJSON = root["usage"] as? [String: Any] ?? [:]
        let usage = Usage(
            inputTokens: usageJSON["input_tokens"] as? Int ?? 0,
            outputTokens: usageJSON["output_tokens"] as? Int ?? 0
        )

        // With output_config.format the first text block is the JSON object.
        let blocks = root["content"] as? [[String: Any]] ?? []
        guard let text = blocks.first(where: { $0["type"] as? String == "text" })?["text"] as? String
        else {
            if let stop = root["stop_reason"] as? String, stop == "max_tokens" {
                throw CaptureError.modelReturnedNothingUsable("the response was cut short")
            }
            throw CaptureError.modelReturnedNothingUsable("no text block in the response")
        }

        let extracted: Extracted
        do {
            extracted = try JSONDecoder().decode(Extracted.self, from: Data(text.utf8))
        } catch {
            throw CaptureError.modelReturnedNothingUsable("could not decode the extraction")
        }

        return (try extracted.parsed(today: today), usage)
    }

    static func errorMessage(_ data: Data) -> String {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = root["error"] as? [String: Any],
              let message = error["message"] as? String else { return "unknown error" }
        return message
    }
}
