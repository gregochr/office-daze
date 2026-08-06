import Foundation

/// One Claude Haiku call: a screenshot in, an array of bookings out.
///
/// Raw `URLSession` rather than an SDK because Anthropic ships no official
/// Swift SDK — this is the documented path for a language without one. The
/// request is the Messages API: `x-api-key`, `anthropic-version`, and a JSON
/// body.
nonisolated struct HaikuClient {

    /// Haiku is the design's own choice — cheapest model that reads a table
    /// reliably, and the volume here is under fifteen calls a month.
    static let model = "claude-haiku-4-5"

    /// Enough for a table of a dozen bookings with room to spare. Not lower:
    /// hitting the cap truncates the JSON mid-object and the whole capture is
    /// wasted, which costs more than the headroom does.
    static let maxTokens = 8192

    let apiKey: String
    var session: URLSession = .shared

    struct Usage: Hashable, Sendable {
        var inputTokens = 0
        var outputTokens = 0
    }

    func extract(image: Data, mediaType: String, today: Day) async throws -> ([ParsedBooking], Usage) {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONSerialization.data(withJSONObject: body(
            image: image, mediaType: mediaType, today: today
        ))
        // The call takes a couple of seconds; a minute is generous and still
        // finite, so a dead network surfaces as a failure rather than a sheet
        // that spins forever.
        request.timeoutInterval = 60

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw CaptureError.network(error.localizedDescription)
        }

        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw CaptureError.httpStatus(http.statusCode, Self.errorMessage(data))
        }
        return try Self.decode(data)
    }

    // MARK: Request

    private func body(image: Data, mediaType: String, today: Day) -> [String: Any] {
        [
            "model": Self.model,
            "max_tokens": Self.maxTokens,
            "system": Self.systemPrompt,
            // Structured outputs: the response is constrained to the schema, so
            // there is no "the model wrapped it in prose" failure mode and no
            // regex fishing for a JSON object.
            "output_config": ["format": ["type": "json_schema", "schema": Self.schema]],
            "messages": [[
                "role": "user",
                "content": [
                    [
                        "type": "image",
                        "source": [
                            "type": "base64",
                            "media_type": mediaType,
                            "data": image.base64EncodedString(),
                        ],
                    ],
                    ["type": "text", "text": Self.userPrompt(today: today)],
                ],
            ]],
        ]
    }

    static let systemPrompt = """
    You read desk-booking confirmations and return them as structured data.

    The single most important rule: NEVER INFER A VALUE. If a field is not \
    legibly present in the image, return null for it and add its name to \
    unsureFields. Do not calculate it, do not deduce it from context, do not \
    supply a plausible default, and do not repeat a value from a different \
    field or a different row. A named unreadable field is a correct answer; a \
    guessed value is a wrong one, and it is worse than a blank because nobody \
    downstream can tell it apart from a real reading.

    These documents come in three layouts, and all three must be read.

    The first is a table of several reservations. Return one entry per \
    reservation row, in the order printed. The date is normally a group \
    heading above a run of rows, not a column within them. Carry that heading \
    down to every row beneath it, until the next heading. A row whose date you \
    cannot establish this way has a null date and "date" in unsureFields.

    The second is a confirmation message for one reservation, with its details \
    set out as labelled fields — building, floor, desk number, date — rather \
    than as a table. That is a single booking for a single day: return an \
    array of exactly one entry, and never spread it across a range of dates. \
    Its date is often a full timestamp, "2026-08-25 09:00:00 CEST". The \
    calendar date there is the booking's date and the clock time is its start \
    time; the end time is not stated anywhere, so it is null and named — the \
    app fills in the end of the working day itself, and an invented one would \
    be indistinguishable from a real reading.

    The third is the reservation's own page in the booking system, headed \
    "Reservation for CO03C117" with its details in labelled blocks — Location, \
    Buildings, Time details, Shift details. It describes one reservation: \
    return an array of exactly one entry. Two things about it are unlike the \
    others. The desk id is in that heading and there is no separate desk field \
    anywhere on the page, so read it from the heading; and both ends of the \
    booking are printed in full, "Starts 2026-09-07 08:00 Europe/London" and \
    "Ends 2026-09-07 17:00", so read both and take the date from the start. \
    Such a page also carries a reservation number like WRES1946519 and a \
    duration like "9 Hours". Neither is a desk id, a floor or a time, and \
    neither belongs anywhere in the output.

    Skip any row whose status is not "Confirmed". Cancelled, pending and \
    waitlisted rows are not bookings and must not appear in the output. A \
    document that states no status at all is a confirmation of what it \
    describes — read it, do not skip it.

    Desk identifiers often encode the building and floor together — CO03C407 \
    is Coleman, floor 03, desk C407. Do not take them apart: return the desk \
    id exactly as printed, and read the floor from its own separate field. If \
    there is no separate floor field, floor is null and named.

    A desk identifier always begins with two letters, the site code, and never \
    with a digit. The CO of CO03C407 is the letter O, not a zero. A desk id \
    you were about to return as C003C407, or with any digit among its first \
    two characters, is that pair of letters misread — correct it before you \
    return it. This is the one place you may override what the pixels appear \
    to say, because the two characters are known to be letters and no reading \
    of them as digits can be right.

    Give the office exactly as printed, including the city if it is shown \
    (for example "03, Coleman, London" is office "Coleman, London"). A single \
    confirmation usually prints it as a building on its own — "Building: \
    Coleman" is office "Coleman", with no city added.

    Times are wall-clock as printed, "08:00", with no timezone conversion. \
    This app has no timezone handling; a booking on the 5th is on the 5th.
    """

    static func userPrompt(today: Day) -> String {
        """
        Extract every confirmed desk booking in this document. Today's date is \
        \(today) — use it only to resolve a year that is genuinely absent from \
        a date that is otherwise legible, never to invent a date.
        """
    }

    /// The response schema. Every object closes `additionalProperties` and
    /// lists every property in `required` — structured outputs rejects a
    /// schema that does not.
    ///
    /// The nullable fields are four `anyOf` unions inside one booking object.
    /// The previous version of this app hit the API's cap on union-typed
    /// parameters at 34 of them; four is not close, so these stay honestly
    /// nullable rather than using the empty-string dodge that cost was worth.
    ///
    /// Computed rather than a stored static: `[String: Any]` is not Sendable,
    /// and this is built once per capture — a handful of dictionary literals.
    static var schema: [String: Any] {
        func nullableString(_ description: String) -> [String: Any] {
            [
                "anyOf": [["type": "string"], ["type": "null"]],
                "description": description,
            ]
        }
        let booking: [String: Any] = [
            "type": "object",
            "properties": [
                "office": nullableString("Office as printed, including city."),
                "date": nullableString(
                    "Booking date as YYYY-MM-DD, from the group heading above the row, "
                    + "from the confirmation's own date field, or from the start of a "
                    + "reservation page's time details."
                ),
                "deskId": nullableString(
                    "Desk identifier exactly as printed — which on a reservation page is "
                    + "in the heading rather than in a labelled field. Always begins with "
                    + "two letters, never a digit. Never a reservation number."
                ),
                "floor": nullableString("Floor, from its own field — never split out of the desk id."),
                "zone": nullableString("Zone within the floor, or null."),
                "startTime": nullableString("Start of the booking as printed, e.g. 08:00."),
                "endTime": nullableString("End of the booking as printed, e.g. 17:00."),
                "unsureFields": [
                    "type": "array",
                    "items": ["type": "string"],
                    "description": "Names of every field you could not read. Must match the null fields.",
                ],
            ],
            "required": [
                "office", "date", "deskId", "floor", "zone",
                "startTime", "endTime", "unsureFields",
            ],
            "additionalProperties": false,
        ]
        return [
            "type": "object",
            "properties": [
                "bookings": [
                    "type": "array",
                    "items": booking,
                    "description":
                        "Every confirmed booking in the document, in the order printed. "
                        + "One entry per row for a table; a single-reservation confirmation "
                        + "is an array of exactly one, for the one day it names.",
                ]
            ],
            "required": ["bookings"],
            "additionalProperties": false,
        ]
    }

    // MARK: Response

    static func decode(_ data: Data) throws -> ([ParsedBooking], Usage) {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CaptureError.modelReturnedNothingUsable("the response was not JSON")
        }

        // A refusal is a successful HTTP 200 with an empty content array, so it
        // has to be checked before reading content rather than caught as an
        // error.
        if root["stop_reason"] as? String == "refusal" { throw CaptureError.refused }

        let usageJSON = root["usage"] as? [String: Any] ?? [:]
        let usage = Usage(
            inputTokens: usageJSON["input_tokens"] as? Int ?? 0,
            outputTokens: usageJSON["output_tokens"] as? Int ?? 0
        )

        if root["stop_reason"] as? String == "max_tokens" {
            throw CaptureError.modelReturnedNothingUsable("the response was cut short")
        }

        let blocks = root["content"] as? [[String: Any]] ?? []
        guard let text = blocks.first(where: { $0["type"] as? String == "text" })?["text"] as? String
        else {
            throw CaptureError.modelReturnedNothingUsable("no text block in the response")
        }

        // With output_config.format the text block is the JSON object itself.
        guard let decoded = try? JSONDecoder().decode(
            CapturedResponse.self, from: Data(text.utf8)
        ) else {
            throw CaptureError.modelReturnedNothingUsable("could not decode the extraction")
        }

        // Rows that could not be read at all are dropped rather than thrown:
        // most of a table beats none of it. An empty document is still a
        // failure, because there is nothing to review.
        let parsed = decoded.bookings.compactMap { $0.parsed() }
        guard !parsed.isEmpty else {
            throw CaptureError.modelReturnedNothingUsable(
                decoded.bookings.isEmpty
                    ? "no bookings in the document"
                    : "no booking had both a readable date and a desk"
            )
        }
        return (parsed, usage)
    }

    static func errorMessage(_ data: Data) -> String {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = root["error"] as? [String: Any],
              let message = error["message"] as? String else { return "unknown error" }
        return message
    }
}
