import Foundation
import SwiftData
import Testing
@testable import OfficeDaze

/// The capture from the bytes landing to the last booking being filed.
///
/// Driven entirely through the coordinator's own interface with the extractor
/// stubbed — which is what that closure exists for — so the phase machine, the
/// retry rule and the writes are exercised without a network call or a sheet.
@Suite("The capture coordinator")
@MainActor
struct CaptureCoordinatorTests {

    let container: ModelContainer
    let coordinator: CaptureCoordinator
    /// What the extractor was handed, on every call.
    let sent = Sent()

    init() throws {
        container = try Store.makeInMemoryContainer(seeded: true)
        coordinator = CaptureCoordinator(context: container.mainContext)
        // The deliberate half second on the parsing sheet is for a person
        // reading it. `parsingFloorIsHeld` is the one test that pays it.
        coordinator.parsingFloor = .zero
    }

    /// Nothing reaches the network — and every argument that would have gone
    /// over it is kept.
    ///
    /// The stub used to be `{ _, _, _ in }`, which is the reason this exists.
    /// Two of the extractor's three arguments were unobserved by the whole
    /// suite, so sending the original 12MP camera frame instead of the prepared
    /// one — the exact 400 `PhotoImport` was written to fix — left every test
    /// green, and so would anchoring the model's date resolution to 2020.
    func stub(_ bookings: [ParsedBooking]) {
        coordinator.extractor = { [sent] data, mediaType, today in
            sent.record(data, mediaType, today)
            return (bookings, CaptureSamples.usage)
        }
    }

    /// The same recording, for a stub that fails instead.
    func stub(throwing error: CaptureError) {
        coordinator.extractor = { [sent] data, mediaType, today in
            sent.record(data, mediaType, today)
            throw error
        }
    }

    /// A real PNG, because the intake decodes what it is given before it sends
    /// anything — a placeholder string now fails at the door, which is the
    /// point of it.
    var image: Data { CaptureSamples.pixel }

    func bookings() throws -> [DeskBooking] {
        try container.mainContext.fetch(FetchDescriptor<DeskBooking>())
    }

    /// A building name no rule can match to the seeded offices, so the sheet
    /// has to ask — which is the only way an alias is ever written.
    func unknownOffice(_ name: String = "Ropemaker Place") -> [ParsedBooking] {
        [ParsedBooking(
            officeName: name, day: Day(2026, 8, 4), deskID: "RP01A100",
            floor: "01", zone: nil, startTime: "08:00", endTime: "17:00",
            unsureFields: ["zone"]
        )]
    }

    func office(_ id: UUID) throws -> Office {
        try #require(
            try container.mainContext.fetch(FetchDescriptor<Office>()).first { $0.id == id }
        )
    }

    // MARK: Reviewing

    @Test("A table is reviewed one booking at a time, in the order printed")
    func reviewsInOrder() async throws {
        stub(CaptureSamples.colemanWeek)
        await coordinator.receive(data: image, filename: "week.png")

        #expect(coordinator.current?.deskID == "CO03A424")
        #expect(coordinator.position?.number == 1)
        #expect(coordinator.position?.total == 3)
        #expect(coordinator.isLast == false)
        #expect(coordinator.segments == [false, false, false])
    }

    /// A counter reading "1 of 1" is noise, so a single booking has no
    /// position at all and the sheet hides the header on that.
    @Test("A single booking has no counter")
    func singleBookingHasNoCounter() async {
        stub(CaptureSamples.one)
        await coordinator.receive(data: image, filename: "one.png")

        #expect(coordinator.position == nil)
        #expect(coordinator.isLast)
    }

    @Test("Saving files the booking and moves to the next")
    func savingAdvances() async throws {
        stub(CaptureSamples.colemanWeek)
        await coordinator.receive(data: image, filename: "week.png")
        let first = try #require(coordinator.current)
        let before = try bookings().count

        coordinator.save(first, to: SeedData.colemanID)

        #expect(try bookings().count == before + 1)
        #expect(coordinator.current?.deskID == "CO03C407", "moved on")
        #expect(coordinator.segments == [true, false, false], "and the bar says so")
    }

    /// Skip is a save that writes nothing. From the coordinator's side the two
    /// are the same event: this booking is done with.
    @Test("Skipping writes nothing and moves on")
    func skippingWritesNothing() async throws {
        stub(CaptureSamples.colemanWeek)
        await coordinator.receive(data: image, filename: "week.png")
        let before = try bookings().count

        coordinator.advance()

        #expect(try bookings().count == before)
        #expect(coordinator.current?.deskID == "CO03C407")
        #expect(coordinator.segments == [false, false, false])
    }

    /// Each save writes immediately rather than batching, so abandoning the
    /// sheet halfway keeps what is already filed.
    @Test("A capture abandoned halfway keeps what was already saved")
    func partialCaptureIsKept() async throws {
        stub(CaptureSamples.colemanWeek)
        await coordinator.receive(data: image, filename: "week.png")
        let before = try bookings().count
        coordinator.save(try #require(coordinator.current), to: SeedData.colemanID)

        coordinator.abort()

        #expect(coordinator.isActive == false)
        #expect(coordinator.canRetry == false)
        #expect(try bookings().count == before + 1, "the first one stayed")
    }

    @Test("The last booking ends the capture")
    func lastBookingFinishes() async {
        stub(CaptureSamples.one)
        await coordinator.receive(data: image, filename: "one.png")

        coordinator.advance()

        #expect(coordinator.isActive == false, "which is what dismisses the sheet")
    }

    // MARK: Offices

    @Test("An office is matched by name, or the sheet is left to ask")
    func matchesTheOffice() async throws {
        stub(CaptureSamples.colemanWeek)
        await coordinator.receive(data: image, filename: "week.png")
        let booking = try #require(coordinator.current)

        #expect(coordinator.matchedOffice(for: booking)?.id == SeedData.colemanID)

        var elsewhere = booking
        elsewhere.officeName = "Somewhere Else"
        #expect(
            coordinator.matchedOffice(for: elsewhere) == nil,
            "a silently invented office gets its own perimeter and never fires"
        )
    }

    /// The whole point: answer the question once and it stops being asked. An
    /// office saved as "Coleman" and a booking system printing "Ropemaker
    /// Place" share nothing for a rule to work on, so the answer is the only
    /// thing that can connect them.
    @Test("The office the sheet had to ask about is remembered")
    func remembersTheAnswer() async throws {
        stub(unknownOffice())
        await coordinator.receive(data: image, filename: "one.png")
        let booking = try #require(coordinator.current)
        #expect(coordinator.matchedOffice(for: booking) == nil, "nothing to go on yet")

        coordinator.save(booking, to: SeedData.colemanID)

        #expect(try office(SeedData.colemanID).aliases == ["Ropemaker Place"])
        #expect(
            coordinator.matchedOffice(for: booking)?.id == SeedData.colemanID,
            "the next capture of this name does not ask"
        )
    }

    /// Only the answers worth keeping. A name the rules already handle would
    /// fill the office's list with what it is called anyway.
    @Test("A name that already matched is not remembered")
    func remembersNothingItAlreadyKnew() async throws {
        stub(CaptureSamples.colemanWeek)
        await coordinator.receive(data: image, filename: "week.png")
        let booking = try #require(coordinator.current)

        coordinator.save(booking, to: SeedData.colemanID)

        #expect(try office(SeedData.colemanID).aliases.isEmpty)
    }

    /// A building name means one building. Two offices claiming it is a
    /// question the matcher will not answer, so it asks — and the answer takes
    /// the name off the other one, which is what stops it asking a third time.
    @Test("Answering an ambiguous name takes it off the other office")
    func theNewestAnswerStands() async throws {
        try office(SeedData.brusselsID).aliases = ["Ropemaker Place"]
        try office(SeedData.colemanID).aliases = ["Ropemaker Place"]
        try container.mainContext.save()

        stub(unknownOffice())
        await coordinator.receive(data: image, filename: "one.png")
        let booking = try #require(coordinator.current)
        #expect(coordinator.matchedOffice(for: booking) == nil, "two claims; ask")

        coordinator.save(booking, to: SeedData.colemanID)

        #expect(try office(SeedData.brusselsID).aliases.isEmpty)
        #expect(try office(SeedData.colemanID).aliases == ["Ropemaker Place"])
        #expect(coordinator.matchedOffice(for: booking)?.id == SeedData.colemanID)
    }

    /// The floor in front of the name varies row to row, and an alias taught by
    /// one row that did not hold for the next would be no better than typing it.
    @Test("The remembered name holds when the floor is printed in front of it")
    func theAnswerSurvivesAFloorPrefix() async throws {
        stub(unknownOffice())
        await coordinator.receive(data: image, filename: "one.png")
        coordinator.save(try #require(coordinator.current), to: SeedData.colemanID)

        let later = try #require(unknownOffice("01, Ropemaker Place").first)
        #expect(coordinator.matchedOffice(for: later)?.id == SeedData.colemanID)
    }

    /// "Level 5" is every word a noise word or a number, so it tokenised to
    /// nothing and matched no alias — not even the one just written for it.
    /// The sheet asked again on the next capture and `remember` appended a
    /// second copy, then a third: an answer given ten times, stored ten times,
    /// and never once used.
    @Test("An office name made of noise words is remembered once and asked about once")
    func anUntokenisableNameIsStillRemembered() async throws {
        stub(unknownOffice("Level 5"))
        await coordinator.receive(data: image, filename: "one.png")
        let first = try #require(coordinator.current)
        #expect(coordinator.matchedOffice(for: first) == nil, "nothing to go on yet")

        coordinator.save(first, to: SeedData.colemanID)
        #expect(try office(SeedData.colemanID).aliases == ["Level 5"])

        // The same document again, which is what a re-share is.
        stub(unknownOffice("Level 5"))
        await coordinator.receive(data: image, filename: "one.png")
        let second = try #require(coordinator.current)
        #expect(
            coordinator.matchedOffice(for: second)?.id == SeedData.colemanID,
            "the answer is used rather than asked for again"
        )

        coordinator.save(second, to: SeedData.colemanID)
        #expect(try office(SeedData.colemanID).aliases == ["Level 5"], "and stored once, not twice")
    }

    @Test("The day's existing booking is found, so the sheet can name it")
    func findsTheExistingBooking() {
        #expect(
            coordinator.existingBooking(day: Day(2026, 8, 5), officeID: SeedData.colemanID)?
                .deskID == "3C-114"
        )
        #expect(
            coordinator.existingBooking(day: Day(2026, 8, 7), officeID: SeedData.colemanID)
                == nil
        )
    }

    /// The confirmation has to outrank the source heuristic, or the dialog is a
    /// lie in the one case that most needs it to be true: 12 August is seeded
    /// as a booking typed by hand, which a capture would otherwise lose to.
    @Test("A confirmed replacement overwrites a booking entered by hand")
    func confirmedReplacementWins() async throws {
        stub([replacement])
        await coordinator.receive(data: image, filename: "one.png")

        coordinator.save(try #require(coordinator.current), to: SeedData.colemanID, chosen: true)

        #expect(try storedOnTheTwelfth().deskID == "CO03Z999")
    }

    @Test("Without that confirmation the hand-typed booking stands")
    func unconfirmedLeavesManualAlone() async throws {
        stub([replacement])
        await coordinator.receive(data: image, filename: "one.png")

        coordinator.save(try #require(coordinator.current), to: SeedData.colemanID)

        #expect(try storedOnTheTwelfth().deskID == "3C-121")
    }

    private var replacement: ParsedBooking {
        ParsedBooking(
            officeName: "Coleman", day: Day(2026, 8, 12), deskID: "CO03Z999",
            floor: nil, zone: nil, startTime: nil, endTime: "17:00", unsureFields: []
        )
    }

    private func storedOnTheTwelfth() throws -> DeskBooking {
        try #require(try bookings().first { $0.day == Day(2026, 8, 12) })
    }

    // MARK: Failure and retry

    /// Retry repeats the model call, not the conversion — which is why the
    /// bytes are prepared before `lastInput` is set.
    @Test("A failed call is surfaced, and retrying repeats only the call")
    func failureThenRetry() async throws {
        coordinator.extractor = { [sent] data, mediaType, today in
            sent.record(data, mediaType, today)
            if sent.calls == 1 { throw CaptureError.network("offline") }
            return (CaptureSamples.one, CaptureSamples.usage)
        }
        await coordinator.receive(data: image, filename: "one.png")

        #expect(failure() == .network("offline"))
        #expect(coordinator.canRetry, "the image decoded, so there is something to send again")

        await coordinator.retry()

        #expect(coordinator.current?.deskID == "CO03C407")
        #expect(sent.calls == 2)
        #expect(
            sent.images == [image, image],
            "the same prepared bytes both times — the retry is the call, not the conversion"
        )
    }

    /// The extension is only good for the error message; what the bytes are is
    /// ImageIO's answer. Nothing was ever sent, so nothing can be sent again —
    /// which is what hides the retry that could only fail the same way twice.
    @Test("Bytes that are not an image never reach the model, and offer no retry")
    func unreadableFile() async {
        stub(CaptureSamples.one)
        await coordinator.receive(data: Data("not an image".utf8), filename: "note.pdf")

        #expect(failure() == .unsupportedFile("pdf"))
        #expect(coordinator.canRetry == false)
    }

    @Test("A photo with no filename behind it says only that it was not an image")
    func unreadablePhoto() async {
        await coordinator.receive(photo: Data())

        #expect(failure() == .unreadableImage)
        #expect(coordinator.canRetry == false)
    }

    @Test("A failure raised before any conversion offers no retry either")
    func failedOutright() {
        coordinator.failed(.noAPIKey)

        #expect(failure() == .noAPIKey)
        #expect(coordinator.canRetry == false)
    }

    /// The filename said JPEG and the bytes are a PNG. The bytes win, which is
    /// the whole of the fix for the 400 a photographed confirmation returned.
    @Test("The media type sent is the bytes', not the filename's")
    func mediaTypeFollowsTheBytes() async {
        stub(CaptureSamples.one)
        await coordinator.receive(data: image, filename: "screenshot.jpg")

        #expect(sent.mediaType == "image/png")
    }

    /// The other two arguments, which nothing used to look at. A 12MP frame is
    /// downsized before it is sent, because the API discards the extra pixels
    /// and refuses the request outright past 10MB encoded — so sending the
    /// original is a call that fails, every time, on the exact input the
    /// conversion was written for. The date is the model's only anchor for a
    /// screenshot printing "5 Aug" with no year on it.
    @Test("The model is handed the prepared image and today, not the original and not a fixed day")
    func theExtractorGetsThePreparedImageAndToday() async throws {
        let original = TestImage.make(width: 4000, height: 3000, type: .jpeg)
        stub(CaptureSamples.one)

        await coordinator.receive(data: original, filename: "photo.jpg")

        let posted = try #require(sent.image)
        #expect(posted != original, "the camera frame itself never goes over the wire")
        #expect(posted.count < original.count)
        let size = try #require(TestImage.dimensions(posted))
        #expect(size.width == PhotoImport.maxEdge, "cut to the long edge the API downsizes to")
        #expect(sent.mediaType == "image/jpeg")
        #expect(sent.today == Day.today, "the day it is where the phone is, not a hardcoded one")
    }

    /// And where the two are identical the exact bytes are knowable, so they
    /// are asserted rather than described: a small PNG is already acceptable at
    /// an acceptable size, so it passes through untouched.
    @Test("An image that needs no conversion reaches the model byte for byte")
    func anAcceptableImageIsSentUnchanged() async {
        stub(CaptureSamples.one)
        await coordinator.receive(data: image, filename: "one.png")

        #expect(sent.image == CaptureSamples.pixel)
        #expect(sent.calls == 1, "one capture, one call")
    }

    // MARK: The capture record

    /// The image itself is deliberately not kept. Nothing in the app reads
    /// `Capture.asset` — the "view original" screen it was for was never built
    /// — so keeping it retained a photograph of the user's employer's booking
    /// system, in the container and in every iCloud backup, for the life of the
    /// install, with no way to see or remove one. Asserted as `nil` rather than
    /// left unasserted, because the previous `!= nil` would have passed just as
    /// happily on a placeholder, a thumbnail or the response JSON.
    @Test("A capture is recorded with its cost, and without the picture")
    func recordsTheCapture() async throws {
        stub(CaptureSamples.one)
        await coordinator.receive(data: image, filename: "one.png")

        let captures = try container.mainContext.fetch(FetchDescriptor<Capture>())
        #expect(captures.count == 1)
        #expect(captures.first?.status == .parsed)
        #expect(captures.first?.inputTokens == CaptureSamples.usage.inputTokens)
        #expect(captures.first?.outputTokens == CaptureSamples.usage.outputTokens)
        #expect(
            captures.first?.asset == nil,
            "an image nothing can display is a photograph of a workplace kept for nothing"
        )
    }

    /// Recorded too, or the monthly count would only ever show what worked.
    @Test("A failed capture is recorded as failed")
    func recordsTheFailure() async throws {
        stub(throwing: .refused)
        await coordinator.receive(data: image, filename: "one.png")

        let captures = try container.mainContext.fetch(FetchDescriptor<Capture>())
        #expect(captures.count == 1)
        #expect(captures.first?.status == .failed)
        #expect(captures.first?.inputTokens == 0, "nothing came back to be charged for")
        #expect(captures.first?.asset == nil, "and a capture of the wrong thing is not kept either")
    }

    /// The one phase that could be entered with nothing in it. `HaikuClient`
    /// refuses an empty parse of its own accord, so no shipping path reaches
    /// this — which is the reason it was worth pinning: the coordinator took the
    /// extractor's word for it, and any second extractor (a cache, an on-device
    /// pass, a stub in somebody's branch) returning `[]` put the user in front
    /// of a sheet titled "Confirm" holding no booking, no Save and no Skip, with
    /// Cancel the only way out. Stubbed here precisely because that is the only
    /// way to stand where the next extractor will.
    @Test("A parse that came back with no bookings is a failure, not an empty review")
    func anEmptyParseNeverBecomesAReview() async throws {
        stub([])

        await coordinator.receive(data: image, filename: "one.png")

        #expect(failure() == .modelReturnedNothingUsable("no bookings in the document"))
        #expect(coordinator.current == nil)
        #expect(coordinator.segments.isEmpty, "and no progress bar with no segments in it")
        #expect(coordinator.position == nil)
        #expect(coordinator.canRetry, "the bytes are still good; a second reading may not be")
        #expect(sent.calls == 1)

        let captures = try container.mainContext.fetch(FetchDescriptor<Capture>())
        #expect(captures.count == 1)
        #expect(captures.first?.status == .failed)
        #expect(
            captures.first?.inputTokens == CaptureSamples.usage.inputTokens,
            "the call was made and billed, so the month's cost has to count it"
        )
        #expect(captures.first?.outputTokens == CaptureSamples.usage.outputTokens)
    }

    /// The other half of that guard: one booking is not none, and the refusal
    /// above must not have been bought by refusing everything.
    @Test("A parse with a single booking in it still reaches the review")
    func aSingleBookingIsNotRefused() async throws {
        stub(CaptureSamples.one)

        await coordinator.receive(data: image, filename: "one.png")

        #expect(failure() == nil)
        #expect(coordinator.current?.deskID == "CO03C407")
        let captures = try container.mainContext.fetch(FetchDescriptor<Capture>())
        #expect(captures.first?.status == .parsed)
    }

    /// A fast parse blinked the sheet from Reading to Confirm with nothing
    /// legible in between, and the user arrived at a filled-in form without
    /// having seen where it came from.
    @Test("A parse faster than the eye still shows the sheet it happened in")
    func parsingFloorIsHeld() async throws {
        coordinator.parsingFloor = .milliseconds(300)
        stub(CaptureSamples.one)

        let started = ContinuousClock.now
        await coordinator.receive(data: image, filename: "one.png")
        #expect(ContinuousClock.now - started >= .milliseconds(300))
        #expect(coordinator.current != nil, "and it still ends up at the review")
    }

    /// Bad news is a screen to read and act on, not an animation to sit
    /// through — so the wait is inside the success path only. Asserted as an
    /// upper bound on the clock this would be a flaky test: the suite runs in
    /// parallel and every one of these is main-actor bound, so wall time here
    /// measures contention as much as anything the coordinator did. A lower
    /// bound is safe, which is why the floor above is tested and its absence
    /// here is only asserted by outcome.
    @Test("A failure still arrives at the error screen with a floor set")
    func failuresReachTheErrorScreen() async throws {
        coordinator.parsingFloor = .milliseconds(300)
        stub(throwing: .refused)
        await coordinator.receive(data: image, filename: "one.png")
        #expect(failure() == .refused)
    }

    /// The floor turned a rare race into a reliable one: half a second in which
    /// Cancel dismisses the sheet and the run then wakes up and fills it again,
    /// with bookings from a capture the user has already walked away from.
    /// Gated rather than timed: the suite runs in parallel and every test in it
    /// is main-actor bound, so "sleep a bit, then cancel" cancels at an
    /// unpredictable point. The extractor here holds the run at its suspension
    /// point until the test has cancelled, which is the state the bug needs.
    @Test("A capture cancelled while a run is in flight stays cancelled")
    func abortDuringTheFloorStaysAborted() async throws {
        coordinator.parsingFloor = .milliseconds(400)
        let entered = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        coordinator.extractor = { [sent] data, mediaType, today in
            sent.record(data, mediaType, today)
            entered.continuation.yield()
            for await _ in release.stream { break }
            return (CaptureSamples.one, CaptureSamples.usage)
        }

        let running = Task { await coordinator.receive(data: image, filename: "one.png") }
        for await _ in entered.stream { break }
        coordinator.abort()
        release.continuation.yield()

        await running.value
        #expect(!coordinator.isActive, "the sheet does not come back")
        #expect(coordinator.current == nil)
        #expect(
            try container.mainContext.fetchCount(FetchDescriptor<Capture>()) == 0,
            "and an abandoned run records nothing"
        )
    }

    /// The same cancellation one suspension point earlier — and the one the
    /// generation guard did not cover. The sheet is on screen, with a live
    /// Cancel button, from the moment the bytes land; the re-encode of a 12MP
    /// frame runs off-actor underneath it for a few hundred milliseconds. A
    /// Cancel landing in that window used to be undone by the preparation
    /// finishing: `lastInput` was re-armed, the model call went out and was
    /// paid for, and the sheet slid back up holding a capture the user had
    /// walked away from. Held at the preparation rather than timed, for the
    /// same reason the test above holds the extractor.
    @Test("A capture cancelled while its image is still being prepared stays cancelled")
    func abortDuringPreparationStaysAborted() async throws {
        let entered = AsyncStream<Void>.makeStream()
        // A semaphore rather than a stream on this side: the preparer is the
        // synchronous, off-actor half, so it blocks its own thread and leaves
        // the main actor free to run `abort()` — which is the state the bug
        // needs.
        let release = DispatchSemaphore(value: 0)
        coordinator.preparer = { data in
            entered.continuation.yield()
            release.wait()
            return (data, "image/png")
        }
        stub(CaptureSamples.one)

        let running = Task { await coordinator.receive(photo: image) }
        for await _ in entered.stream { break }
        coordinator.abort()
        release.signal()

        await running.value
        #expect(!coordinator.isActive, "the sheet the user dismissed does not come back")
        #expect(coordinator.current == nil)
        #expect(sent.calls == 0, "and no API call is spent on a capture that was cancelled")
        #expect(coordinator.canRetry == false, "nothing re-armed the retry either")
        #expect(try container.mainContext.fetchCount(FetchDescriptor<Capture>()) == 0)
    }

    /// The other half of that guard: a preparation nobody cancelled still ends
    /// up at the review, or the fix above would be indistinguishable from
    /// breaking the intake outright.
    @Test("A preparation that is left alone still reaches the review")
    func preparationUninterruptedStillArrives() async throws {
        let prepared = Counter()
        coordinator.preparer = { data in
            prepared.count += 1
            return (data, "image/png")
        }
        stub(CaptureSamples.one)

        await coordinator.receive(photo: image)

        #expect(prepared.count == 1)
        #expect(coordinator.current?.deskID == "CO03C407")
    }

    /// The dialog asks which of two desks to keep, and used to withhold the one
    /// thing that decides it.
    @Test("The clash dialog says where the desk it is asking about came from")
    func clashNamesItsSource() async throws {
        // The seeded 5 August booking came from a capture; the 12th was typed.
        let typed = try #require(try bookings().first { $0.day == Day(2026, 8, 12) })
        #expect(coordinator.provenance(of: typed) == "entered by hand")
        #expect(
            CaptureSheet.clashMessage(existing: "3C-114", provenance: "entered by hand")
                == "This day already has desk 3C-114 at this office, entered by hand. "
                    + "Only one desk is kept per office per day."
        )

        // A capture whose original is still on file dates itself.
        stub([ParsedBooking(
            officeName: "Coleman", day: Day(2026, 8, 20), deskID: "3C-200",
            floor: "Level 3", zone: "C", startTime: nil, endTime: nil,
            unsureFields: []
        )])
        await coordinator.receive(data: image, filename: "one.png")
        coordinator.save(try #require(coordinator.current), to: SeedData.colemanID)

        let captured = try #require(try bookings().first { $0.day == Day(2026, 8, 20) })
        let provenance = try #require(coordinator.provenance(of: captured))
        #expect(provenance.hasPrefix("read from an image on "))
    }

    // MARK: The share sheet

    /// The intake the class exists for — iOS launches the app holding the
    /// shared file — and the one no test drove. Everything else went in through
    /// `receive(data:filename:)`, which skips the security-scoped access, the
    /// read, and the failure branch below.
    @Test("A file shared into the app is read from its URL")
    func receivesAFileFromItsURL() async throws {
        stub(CaptureSamples.one)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID()).png")
        try CaptureSamples.pixel.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        await coordinator.receive(url: url)

        #expect(coordinator.current?.deskID == "CO03C407")
        #expect(sent.image == CaptureSamples.pixel, "the file's own bytes, not a stand-in")
    }

    /// iOS copies the shared document into `Documents/Inbox` and the copy is
    /// ours to delete — nothing else in the app ever would. Left behind, every
    /// screenshot a user shares stays in the container, and in every iCloud
    /// backup, for the life of the install: `Store.wipe` reaches the database
    /// and not the filesystem, so "Delete data → Everything" does not touch it.
    @Test("The copy iOS made in the inbox is deleted once its bytes are read")
    func theInboxCopyIsDeleted() async throws {
        let inbox = try FileManager.default.url(
            for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ).appendingPathComponent("Inbox", isDirectory: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let url = inbox.appendingPathComponent("\(UUID()).png")
        try CaptureSamples.pixel.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        stub(CaptureSamples.one)
        await coordinator.receive(url: url)

        #expect(coordinator.current != nil, "the bytes were read before it went")
        #expect(FileManager.default.fileExists(atPath: url.path) == false)
    }

    /// And only that copy. The guard is on the inbox path rather than on
    /// "whatever arrived", because a document opened in place belongs to the
    /// app that holds it, and deleting one would be deleting the user's file
    /// out of somebody else's app.
    @Test("A file that is not an inbox copy is left where it is")
    func aFileOutsideTheInboxSurvives() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID()).png")
        try CaptureSamples.pixel.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        stub(CaptureSamples.one)
        await coordinator.receive(url: url)

        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(CaptureCoordinator.isInboxCopy(url) == false)
        #expect(
            CaptureCoordinator.isInboxCopy(
                URL(fileURLWithPath: "/var/mobile/Containers/Data/App/X/Documents/Inbox/a.png")
            )
        )
    }

    /// A file that cannot be read at all says so. It used to name a file type
    /// that does not exist — "Office Daze can't read a .FILE file" — because
    /// the message was assembled out of an extension that was not there.
    @Test("A URL with nothing readable behind it does not invent a file type")
    func anUnreadableURLNamesNoFormat() async {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)

        await coordinator.receive(url: missing)

        #expect(failure() == .unreadableImage)
        #expect(coordinator.canRetry == false, "nothing was ever sent, so nothing can be resent")
    }

    /// The format is only the diagnosis when it is a format we have no decoder
    /// for. A PDF says so by name; a truncated PNG is not evidence that PNG is
    /// unreadable, and telling someone the app cannot read its commonest input
    /// sends them off to type the booking in by hand.
    @Test("A corrupt file in a format we do read is not called an unsupported format")
    func aCorruptSupportedFileIsNotBlamedOnItsFormat() async {
        stub(CaptureSamples.one)

        await coordinator.receive(data: Data("truncated".utf8), filename: "screenshot.png")
        #expect(failure() == .unreadableImage)

        await coordinator.receive(data: Data("truncated".utf8), filename: "PHOTO.HEIC")
        #expect(failure() == .unreadableImage, "case is not a format")

        await coordinator.receive(data: Data("not an image".utf8), filename: "booking.pdf")
        #expect(failure() == .unsupportedFile("pdf"), "and a PDF really is the wrong format")

        #expect(sent.calls == 0, "none of the three reached the model")
    }

    // MARK: A write that did not land

    /// The `saved` set drives the green segments and the sheet's advance, so a
    /// swallowed write was drawn to the user as a completed one: three capsules
    /// filled, the sheet dismissed, and the bookings were not there at the next
    /// launch with nothing having said so.
    @Test("A booking that could not be written is not shown as saved")
    func aFailedWriteIsSurfaced() async throws {
        stub(CaptureSamples.colemanWeek)
        await coordinator.receive(data: image, filename: "week.png")
        let booking = try #require(coordinator.current)
        let before = try bookings().count

        let attempted = Attempted()
        coordinator.writeBooking = { candidate, captureID, chosen in
            attempted.record(candidate, captureID, chosen)
            throw StoreFailure.diskFull
        }

        coordinator.save(booking, to: SeedData.colemanID)

        #expect(coordinator.segments.isEmpty, "no segment turned green")
        #expect(coordinator.current == nil, "and the sheet did not move on")
        if case .failed(.couldNotSave) = coordinator.phase {} else {
            Issue.record("the failure has to reach the screen the user is looking at")
        }
        #expect(try bookings().count == before, "nothing was written")
        #expect(coordinator.canRetry == false, "retrying reruns the call, which is not the problem")
        // The double is not blind: the write it was asked to make is the one
        // the sheet was showing.
        #expect(attempted.candidates.count == 1)
        #expect(attempted.candidates.first?.officeID == SeedData.colemanID)
        #expect(attempted.candidates.first?.day == booking.day)
        #expect(attempted.candidates.first?.deskID == booking.deskID)
        #expect(attempted.candidates.first?.source == .capture)
        #expect(attempted.chosen == [false])
    }

    /// The same double, succeeding, so the assertions above are about the
    /// failure and not about having replaced the write at all.
    @Test("A booking that was written is what the sheet asked for")
    func aSuccessfulWriteCarriesTheAnswer() async throws {
        stub(CaptureSamples.colemanWeek)
        await coordinator.receive(data: image, filename: "week.png")
        let booking = try #require(coordinator.current)

        let attempted = Attempted()
        coordinator.writeBooking = { candidate, captureID, chosen in
            attempted.record(candidate, captureID, chosen)
        }

        coordinator.save(booking, to: SeedData.colemanID, chosen: true)

        #expect(coordinator.segments == [true, false, false])
        #expect(coordinator.current?.deskID == "CO03C407", "and the sheet moved on")
        #expect(attempted.candidates.first?.deskID == "CO03A424")
        #expect(attempted.candidates.first?.unsureFields == booking.unsureFields)
        #expect(attempted.chosen == [true], "the clash dialog's answer is carried through")
        let capture = try #require(
            try container.mainContext.fetch(FetchDescriptor<Capture>()).first
        )
        #expect(
            attempted.captureIDs == [capture.id],
            "and the booking is tied to the capture it was read from"
        )
    }

    // MARK: Helpers

    /// The phase's error, or nil — `Phase` is not Equatable, and matching it in
    /// every test is noise.
    private func failure() -> CaptureError? {
        guard case .failed(let error) = coordinator.phase else { return nil }
        return error
    }

    /// `nonisolated` because one of its users is the preparer, which runs off
    /// the main actor by design — counting calls there is the point.
    nonisolated final class Counter: @unchecked Sendable {
        var count = 0
    }

    /// What the write was asked to do, so a double that refuses it still has to
    /// have been asked for the right thing.
    final class Attempted {
        private(set) var candidates: [BookingMerge.Candidate] = []
        private(set) var captureIDs: [UUID?] = []
        private(set) var chosen: [Bool] = []

        func record(_ candidate: BookingMerge.Candidate, _ captureID: UUID?, _ chosen: Bool) {
            candidates.append(candidate)
            captureIDs.append(captureID)
            self.chosen.append(chosen)
        }
    }

    /// A store that refuses, which is the one thing an in-memory container will
    /// not do on request.
    enum StoreFailure: Error { case diskFull }

    /// Every argument the extractor was handed, in order, so a test can assert
    /// on any of them. A fake that answers the same thing whatever it is given
    /// verifies nothing about what crosses the boundary it stands in for.
    final class Sent: @unchecked Sendable {
        private(set) var images: [Data] = []
        private(set) var mediaTypes: [String] = []
        private(set) var days: [Day] = []

        var calls: Int { images.count }
        var image: Data? { images.last }
        var mediaType: String? { mediaTypes.last }
        var today: Day? { days.last }

        func record(_ image: Data, _ mediaType: String, _ today: Day) {
            images.append(image)
            mediaTypes.append(mediaType)
            days.append(today)
        }
    }
}
