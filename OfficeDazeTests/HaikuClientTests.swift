import Foundation
import Testing
@testable import OfficeDaze

/// Answers a `URLSession` from a script instead of from the network, and keeps
/// every request it was handed so the test can assert on what actually went
/// out.
///
/// The recording half is not optional. A stub that only scripts the *response*
/// asserts nothing about the request, and the request is where this client's
/// entire job is: three headers, a URL, and a JSON body whose shape the API
/// either recognises or rejects with a 400. Renaming one key in that body is a
/// change no response-only test could see.
///
/// Statics rather than instance state because `URLSession` constructs the
/// protocol itself and there is no seam to hand an instance through — which is
/// why the suites using it are `.serialized`.
nonisolated final class StubTransport: URLProtocol {

    struct Sent {
        var request: URLRequest
        /// Read out of the request separately: `URLSession` hands a
        /// `URLProtocol` the body as a stream and leaves `httpBody` nil, a
        /// detail that otherwise shows up as an assertion mysteriously seeing
        /// no body at all.
        var body: Data
    }

    /// What to answer with. A `Result` so a transport failure — the case that
    /// becomes `CaptureError.network` — is scriptable beside the HTTP ones.
    nonisolated(unsafe) static var answer: Result<(status: Int, body: Data), any Error>
        = .success((200, Data()))

    /// Recorded rather than asserted on in place: `startLoading` runs on
    /// URLSession's own queue, outside the test's task, where `#expect` has no
    /// test to report a failure to.
    nonisolated(unsafe) static var sent: [Sent] = []

    static func reset(answering answer: Result<(status: Int, body: Data), any Error>) {
        sent = []
        self.answer = answer
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.sent.append(Sent(request: request, body: Self.body(of: request)))
        switch Self.answer {
        case .success(let (status, body)):
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let error):
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

/// The app's only network call: what it puts on the wire, and what it makes of
/// what comes back.
///
/// `.serialized` because the transport above is reached through statics — two
/// of these running at once would answer each other's requests.
@Suite("The model call", .serialized)
struct HaikuClientTests {

    /// Obviously not a key. Nothing in this file, or in any failure message it
    /// can produce, is a credential.
    let apiKey = "test-key-not-real"

    /// Bytes that are not text, so an implementation that stringified the image
    /// instead of base64-encoding it could not accidentally match.
    let image = Data((0...255).map { UInt8($0) })

    let today = Day(2026, 8, 4)

    func client(answering answer: Result<(status: Int, body: Data), any Error>) -> HaikuClient {
        StubTransport.reset(answering: answer)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubTransport.self]
        var client = HaikuClient(apiKey: apiKey)
        client.session = URLSession(configuration: configuration)
        return client
    }

    // MARK: What goes out

    @Test("The request is the Messages API call, with the image in it as base64")
    func theRequestOnTheWire() async throws {
        let client = client(answering: .success((200, try envelope(bookings: [row()]))))
        _ = try await client.extract(image: image, mediaType: "image/png", today: today)

        let sent = try #require(StubTransport.sent.first)
        #expect(StubTransport.sent.count == 1, "one call per capture")
        #expect(sent.request.url?.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(sent.request.httpMethod == "POST")
        #expect(sent.request.value(forHTTPHeaderField: "x-api-key") == apiKey)
        #expect(sent.request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        #expect(sent.request.value(forHTTPHeaderField: "content-type") == "application/json")

        let body = try #require(
            try JSONSerialization.jsonObject(with: sent.body) as? [String: Any]
        )
        #expect(body["model"] as? String == "claude-haiku-4-5")
        #expect(body["max_tokens"] as? Int == 8192)
        #expect(body["system"] as? String == HaikuClient.systemPrompt)

        // The key the previous version of this app got a 400 for. `SchemaTests`
        // proves the schema is well formed; this proves it is placed where the
        // API reads it, which is the half a shape check cannot see.
        let format = try #require(
            (body["output_config"] as? [String: Any])?["format"] as? [String: Any]
        )
        #expect(format["type"] as? String == "json_schema")
        #expect(format["schema"] is [String: Any], "the schema travels with the request")

        let messages = try #require(body["messages"] as? [[String: Any]])
        #expect(messages.count == 1)
        #expect(messages.first?["role"] as? String == "user")
        let content = try #require(messages.first?["content"] as? [[String: Any]])

        let imageBlock = try #require(content.first)
        #expect(imageBlock["type"] as? String == "image")
        let source = try #require(imageBlock["source"] as? [String: Any])
        #expect(source["type"] as? String == "base64")
        #expect(source["media_type"] as? String == "image/png", "as prepared, not as guessed")
        let encoded = try #require(source["data"] as? String)
        #expect(
            Data(base64Encoded: encoded) == image,
            "the bytes the caller handed over, byte for byte"
        )

        let textBlock = try #require(content.last)
        #expect(textBlock["type"] as? String == "text")
        #expect(
            (textBlock["text"] as? String)?.contains("2026-08-04") == true,
            "today reaches the model, which is how a year absent from the page is resolved"
        )
    }

    /// The one place the key belongs is the header. A key that also ended up in
    /// the payload would be a second copy of the app's only secret travelling
    /// somewhere nobody audits.
    @Test("The key travels in the header and nowhere else")
    func theKeyIsOnlyInTheHeader() async throws {
        let client = client(answering: .success((200, try envelope(bookings: [row()]))))
        _ = try await client.extract(image: image, mediaType: "image/png", today: today)
        let sent = try #require(StubTransport.sent.first)
        #expect(!String(decoding: sent.body, as: UTF8.self).contains(apiKey))
    }

    /// A different media type has to reach the API, because the API rejects an
    /// image whose declared type is not what the bytes are — and `PhotoImport`
    /// transcodes, so the type is genuinely variable.
    @Test("The media type is the one the import decided on", arguments: [
        "image/png", "image/jpeg",
    ])
    func theMediaTypeIsCarried(_ mediaType: String) async throws {
        let client = client(answering: .success((200, try envelope(bookings: [row()]))))
        _ = try await client.extract(image: image, mediaType: mediaType, today: today)
        let sent = try #require(StubTransport.sent.first)
        let body = try #require(
            try JSONSerialization.jsonObject(with: sent.body) as? [String: Any]
        )
        let content = try #require(
            (body["messages"] as? [[String: Any]])?.first?["content"] as? [[String: Any]]
        )
        #expect((content.first?["source"] as? [String: Any])?["media_type"] as? String == mediaType)
    }

    // MARK: What comes back

    @Test("A well-formed answer becomes bookings and the tokens they cost")
    func aGoodAnswer() async throws {
        let client = client(answering: .success((200, try envelope(bookings: [
            row(date: "2026-08-04", desk: "CO03A424"),
            row(date: "2026-08-05", desk: "CO03C407"),
        ]))))
        let (bookings, usage) = try await client.extract(
            image: image, mediaType: "image/png", today: today
        )
        #expect(bookings.map(\.deskID) == ["CO03A424", "CO03C407"])
        #expect(bookings.map(\.day) == [Day(2026, 8, 4), Day(2026, 8, 5)])
        #expect(usage == HaikuClient.Usage(inputTokens: 1640, outputTokens: 520))
    }

    /// A proxy or a captive portal answers 200 with an HTML page. The status
    /// says everything is fine and the body is not JSON at all.
    @Test("A 200 that is not JSON is a failure, not an empty document")
    func aNonJSONBody() async throws {
        let client = client(answering: .success((200, Data("<html>502 Bad Gateway</html>".utf8))))
        await #expect(throws: CaptureError.modelReturnedNothingUsable("the response was not JSON")) {
            try await client.extract(image: image, mediaType: "image/png", today: today)
        }
    }

    @Test("A refusal arrives as a 200 and is still surfaced as a refusal")
    func aRefusal() async throws {
        let client = client(answering: .success((
            200, try envelope(bookings: nil, stopReason: "refusal")
        )))
        await #expect(throws: CaptureError.refused) {
            try await client.extract(image: image, mediaType: "image/png", today: today)
        }
    }

    @Test("A response cut short by the token cap is a failure, not a partial table")
    func cutShort() async throws {
        let client = client(answering: .success((
            200, try envelope(bookings: nil, stopReason: "max_tokens")
        )))
        await #expect(
            throws: CaptureError.modelReturnedNothingUsable("the response was cut short")
        ) {
            try await client.extract(image: image, mediaType: "image/png", today: today)
        }
    }

    /// The two statuses a real key actually produces: the wrong key, and the
    /// right key used too fast. Both carry the API's own explanation, and it is
    /// the explanation the sheet shows.
    @Test("An HTTP failure carries the API's own message through to the user", arguments: [
        (401, "invalid x-api-key"),
        (429, "Number of requests has exceeded your rate limit"),
    ])
    func httpFailures(_ status: Int, _ message: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: [
            "type": "error", "error": ["type": "error", "message": message],
        ])
        let client = client(answering: .success((status, body)))
        await #expect(throws: CaptureError.httpStatus(status, message)) {
            try await client.extract(image: image, mediaType: "image/png", today: today)
        }
        #expect(StubTransport.sent.count == 1, "the call went out; it was the answer that failed")
    }

    /// A gateway between the app and the API answers in its own vocabulary. The
    /// status is still worth showing even when there is no message to show
    /// beside it.
    @Test("An error body in nobody's shape still reports its status")
    func anUnparseableErrorBody() async throws {
        let client = client(answering: .success((503, Data("<html>upstream</html>".utf8))))
        await #expect(throws: CaptureError.httpStatus(503, "unknown error")) {
            try await client.extract(image: image, mediaType: "image/png", today: today)
        }
    }

    @Test("A dead network is reported as a network failure, with what went wrong")
    func aTransportFailure() async throws {
        let client = client(answering: .failure(URLError(.notConnectedToInternet)))
        let thrown = await #expect(throws: CaptureError.self) {
            try await client.extract(image: image, mediaType: "image/png", today: today)
        }
        guard case .network(let why) = try #require(thrown) else {
            Issue.record("a transport failure is a .network, not \(String(describing: thrown))")
            return
        }
        #expect(!why.isEmpty, "the sheet prints this, so an empty one says nothing")
        #expect(why == URLError(.notConnectedToInternet).localizedDescription)
    }

    // MARK: Where the work happens

    /// Until `extract` was marked `@concurrent` it inherited its caller's
    /// executor — this project builds with `SWIFT_APPROACHABLE_CONCURRENCY`, so
    /// a plain `nonisolated func … async` is `nonisolated(nonsending)` — and
    /// its caller is `CaptureCoordinator.run()`, on the main actor. So the
    /// base64 of the whole image and the JSON serialisation of the string it
    /// produces ran on the thread drawing the sheet.
    ///
    /// What is observable from outside is how long the main actor was
    /// unavailable to anybody else while that happened, so that is what this
    /// measures. The fixture is far larger than `PhotoImport` will ever hand
    /// over, deliberately: it makes the gap between doing that work on the main
    /// thread and doing it anywhere else a wide one rather than a stopwatch
    /// race. Measured on this machine, sixteen megabytes holds the main actor
    /// for 129 ms when the work is on it and for well under a millisecond when
    /// it is not, so the threshold sits three times below the first number and
    /// a hundred times above the second.
    @MainActor
    @Test("The request is built off the main actor, not on the one drawing the sheet")
    func theRequestIsBuiltOffTheMainActor() async throws {
        let large = Data(repeating: 0x7F, count: 16 * 1024 * 1024)
        let client = client(answering: .success((200, try envelope(bookings: [row()]))))

        // Queued on the main actor ahead of the continuation below, so it runs
        // first and whatever it does before its first suspension happens before
        // the main actor comes back to us.
        let call = Task { @MainActor in
            try await client.extract(image: large, mediaType: "image/jpeg", today: today)
        }
        let start = ContinuousClock.now
        await Task.yield()
        let mainActorHeld = ContinuousClock.now - start
        _ = try await call.value

        #expect(
            mainActorHeld < .milliseconds(40),
            "the main actor was busy for \(mainActorHeld) building a request"
        )
    }

    // MARK: Fixtures

    /// The envelope as the API sends it. The extraction is a JSON *string*
    /// inside the text block rather than a nested object, so it is built here
    /// through `JSONSerialization` twice over — by hand, the escaping is the
    /// part that quietly goes wrong and takes the test's meaning with it.
    func envelope(
        bookings: [[String: Any]]?, stopReason: String = "end_turn",
        inputTokens: Int = 1640, outputTokens: Int = 520
    ) throws -> Data {
        var content: [[String: Any]] = []
        if let bookings {
            let extraction = try JSONSerialization.data(withJSONObject: ["bookings": bookings])
            content = [["type": "text", "text": String(decoding: extraction, as: UTF8.self)]]
        }
        return try JSONSerialization.data(withJSONObject: [
            "stop_reason": stopReason,
            "usage": ["input_tokens": inputTokens, "output_tokens": outputTokens],
            "content": content,
        ])
    }

    func row(
        office: String? = "Coleman, London", date: String? = "2026-08-04",
        desk: String? = "CO03A424", floor: String? = "03", zone: String? = nil,
        start: String? = "08:00", end: String? = "17:00", unsure: [String] = ["zone"]
    ) -> [String: Any] {
        // The schema's nullable fields are genuinely null on the wire, and
        // `JSONSerialization` needs `NSNull` to write one — a Swift nil would
        // drop the key entirely, which is a different document.
        func json(_ text: String?) -> Any { if let text { text } else { NSNull() } }
        return [
            "office": json(office),
            "date": json(date),
            "deskId": json(desk),
            "floor": json(floor),
            "zone": json(zone),
            "startTime": json(start),
            "endTime": json(end),
            "unsureFields": unsure,
        ]
    }
}

/// The three shapes of malformed answer that reach `decode` from a live API and
/// had no assertion of their own.
///
/// Every one of them is a real thing the Messages API or something between it
/// and the phone can send, and all three surface to the user as the same
/// sentence with a different clause — so the clause is what these pin.
@Suite("Reading the model's answer")
struct HaikuDecodeTests {

    @Test("A body that is not JSON at all says so")
    func notJSON() {
        #expect(throws: CaptureError.modelReturnedNothingUsable("the response was not JSON")) {
            try HaikuClient.decode(Data("<html>502 Bad Gateway</html>".utf8))
        }
        #expect(throws: CaptureError.modelReturnedNothingUsable("the response was not JSON")) {
            try HaikuClient.decode(Data())
        }
        // Valid JSON, but not an object — the `as? [String: Any]` half of the
        // same guard.
        #expect(throws: CaptureError.modelReturnedNothingUsable("the response was not JSON")) {
            try HaikuClient.decode(Data("[1,2,3]".utf8))
        }
    }

    @Test("A response with no text block in it says so")
    func noTextBlock() {
        let thinkingOnly = Data(#"""
        {"stop_reason":"end_turn","usage":{},"content":[{"type":"thinking","thinking":"…"}]}
        """#.utf8)
        #expect(throws: CaptureError.modelReturnedNothingUsable("no text block in the response")) {
            try HaikuClient.decode(thinkingOnly)
        }
    }

    /// The block the extraction is in is the *text* block, not the first one.
    /// A response that leads with a thinking or tool_use block is the shape
    /// that made `blocks.first(where:)` necessary, and with every fixture
    /// carrying exactly one block there was nothing stopping that being
    /// simplified back to `blocks.first` — after which every real capture
    /// leading with a thinking block fails.
    @Test("A text block behind a thinking block is still the one that is read")
    func findsTheTextBlockBehindAnother() throws {
        // The text block's payload is a JSON *string* holding a whole JSON
        // document, and a JSON string cannot contain a real newline — so the
        // long ones here are folded with `\#` line continuations, which join
        // back to one line and leave the bytes exactly as the API sent them.
        // Dropping a continuation puts a newline inside the string and the
        // fixture stops being JSON, which the decode assertion below catches.
        let leadingThinking = Data(#"""
        {"stop_reason":"end_turn","usage":{"input_tokens":11,"output_tokens":22},"content":[
          {"type":"thinking","thinking":"reading the table"},
          {"type":"text","text":"{\"bookings\":[{\"office\":\"Coleman\",\"date\":\"2026-08-04\",\#
        \"deskId\":\"CO03A424\",\"floor\":\"03\",\"zone\":null,\"startTime\":\"08:00\",\#
        \"endTime\":\"17:00\",\"unsureFields\":[\"zone\"]}]}"}
        ]}
        """#.utf8)
        let (bookings, usage) = try HaikuClient.decode(leadingThinking)
        #expect(bookings.map(\.deskID) == ["CO03A424"])
        #expect(usage == HaikuClient.Usage(inputTokens: 11, outputTokens: 22))
    }

    /// Structured outputs constrains the text block to the schema, so this
    /// should not happen — which is exactly why it needs pinning rather than
    /// trusting. A text block in some other shape is not an empty table.
    @Test("A text block that is not the extraction says so, rather than reading as empty")
    func textThatIsNotTheSchema() {
        let wrongShape = Data(#"""
        {"stop_reason":"end_turn","usage":{},"content":[{"type":"text","text":"{\"rows\":[]}"}]}
        """#.utf8)
        #expect(
            throws: CaptureError.modelReturnedNothingUsable("could not decode the extraction")
        ) {
            try HaikuClient.decode(wrongShape)
        }

        // Not JSON inside the text block either — the other way the same guard
        // is reached, and the one a model without structured outputs would take.
        let prose = Data(#"""
        {"stop_reason":"end_turn","usage":{},"content":[{"type":"text","text":"I see three bookings."}]}
        """#.utf8)
        #expect(
            throws: CaptureError.modelReturnedNothingUsable("could not decode the extraction")
        ) {
            try HaikuClient.decode(prose)
        }
    }

    /// Two different empty results, and the difference is the whole message the
    /// user gets: nothing in the document at all is a bad photograph, whereas
    /// rows that came back unreadable is a photograph of the right thing taken
    /// badly. Asserting only `CaptureError.self` left both arms of that ternary
    /// free to be swapped.
    @Test("An empty table and an unreadable one are told apart")
    func theTwoEmptyResults() {
        let noRows = Data(#"""
        {"stop_reason":"end_turn","usage":{},"content":[{"type":"text","text":"{\"bookings\":[]}"}]}
        """#.utf8)
        #expect(
            throws: CaptureError.modelReturnedNothingUsable("no bookings in the document")
        ) {
            try HaikuClient.decode(noRows)
        }

        // Folded with `\#` continuations for the same reason as above: every
        // field is present and null, which is the point of the fixture, and
        // that is a lot of characters that have to stay on one logical line.
        let nothingReadable = Data(#"""
        {"stop_reason":"end_turn","usage":{},"content":[{"type":"text","text":"{\"bookings\":[\#
        {\"office\":null,\"date\":null,\"deskId\":null,\"floor\":null,\"zone\":null,\#
        \"startTime\":null,\"endTime\":null,\"unsureFields\":[\"date\",\"deskId\"]}]}"}]}
        """#.utf8)
        #expect(
            throws: CaptureError.modelReturnedNothingUsable(
                "no booking had both a readable date and a desk"
            )
        ) {
            try HaikuClient.decode(nothingReadable)
        }
    }

    /// The message is what the sheet shows beside the status code, and it comes
    /// out of a body the app does not control.
    @Test("An API error body gives up its message, and anything else gives up nothing")
    func theErrorMessage() {
        let apiError = Data(#"{"type":"error","error":{"type":"not_found_error","message":"model: nope"}}"#.utf8)
        #expect(HaikuClient.errorMessage(apiError) == "model: nope")
        #expect(HaikuClient.errorMessage(Data("<html>504</html>".utf8)) == "unknown error")
        #expect(HaikuClient.errorMessage(Data(#"{"error":"rate limited"}"#.utf8)) == "unknown error")
        #expect(HaikuClient.errorMessage(Data()) == "unknown error")
    }

    /// Today is in the prompt for one reason and it is a narrow one: a page
    /// that prints "5 Aug" and no year. The date has to actually be in there.
    @Test("The prompt carries today's date, and says what it is for")
    func todayIsInThePrompt() {
        let prompt = HaikuClient.userPrompt(today: Day(2026, 8, 4))
        #expect(prompt.contains("2026-08-04"))
        #expect(
            prompt.contains("never to invent a date"),
            "otherwise it is a licence to fill in every missing date from it"
        )
        #expect(HaikuClient.userPrompt(today: Day(2027, 1, 31)).contains("2027-01-31"))
    }
}
