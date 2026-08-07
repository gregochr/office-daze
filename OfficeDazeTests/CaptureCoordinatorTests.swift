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

    init() throws {
        container = try Store.makeInMemoryContainer(seeded: true)
        coordinator = CaptureCoordinator(context: container.mainContext)
        // The deliberate half second on the parsing sheet is for a person
        // reading it. `parsingFloorIsHeld` is the one test that pays it.
        coordinator.parsingFloor = .zero
    }

    /// Nothing reaches the network.
    func stub(_ bookings: [ParsedBooking]) {
        coordinator.extractor = { _, _, _ in (bookings, CaptureSamples.usage) }
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
        let attempts = Counter()
        coordinator.extractor = { _, _, _ in
            attempts.count += 1
            if attempts.count == 1 { throw CaptureError.network("offline") }
            return (CaptureSamples.one, CaptureSamples.usage)
        }
        await coordinator.receive(data: image, filename: "one.png")

        #expect(failure() == .network("offline"))
        #expect(coordinator.canRetry, "the image decoded, so there is something to send again")

        await coordinator.retry()

        #expect(coordinator.current?.deskID == "CO03C407")
        #expect(attempts.count == 2)
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
        let seen = Seen()
        coordinator.extractor = { _, mediaType, _ in
            seen.mediaType = mediaType
            return (CaptureSamples.one, CaptureSamples.usage)
        }
        await coordinator.receive(data: image, filename: "screenshot.jpg")

        #expect(seen.mediaType == "image/png")
    }

    // MARK: The capture record

    @Test("A capture is recorded with its cost and its original")
    func recordsTheCapture() async throws {
        stub(CaptureSamples.one)
        await coordinator.receive(data: image, filename: "one.png")

        let captures = try container.mainContext.fetch(FetchDescriptor<Capture>())
        #expect(captures.count == 1)
        #expect(captures.first?.status == .parsed)
        #expect(captures.first?.inputTokens == CaptureSamples.usage.inputTokens)
        #expect(captures.first?.outputTokens == CaptureSamples.usage.outputTokens)
        #expect(captures.first?.asset != nil, "so \"view original\" has something to show")
    }

    /// Recorded too, or the monthly count would only ever show what worked.
    @Test("A failed capture is recorded as failed")
    func recordsTheFailure() async throws {
        coordinator.extractor = { _, _, _ in throw CaptureError.refused }
        await coordinator.receive(data: image, filename: "one.png")

        let captures = try container.mainContext.fetch(FetchDescriptor<Capture>())
        #expect(captures.count == 1)
        #expect(captures.first?.status == .failed)
        #expect(captures.first?.inputTokens == 0, "nothing came back to be charged for")
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
        coordinator.extractor = { _, _, _ in throw CaptureError.refused }
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
        coordinator.extractor = { _, _, _ in
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

    // MARK: Helpers

    /// The phase's error, or nil — `Phase` is not Equatable, and matching it in
    /// every test is noise.
    private func failure() -> CaptureError? {
        guard case .failed(let error) = coordinator.phase else { return nil }
        return error
    }

    final class Counter: @unchecked Sendable {
        var count = 0
    }

    final class Seen: @unchecked Sendable {
        var mediaType: String?
    }
}
