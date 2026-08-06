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
