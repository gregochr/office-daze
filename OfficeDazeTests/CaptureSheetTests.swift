import Foundation
import SwiftData
import SwiftUI
import Testing
import UIKit
@testable import OfficeDaze

/// The review sheet's decisions, taken without a screen.
///
/// The sheet is the screen the whole capture pipeline exists to reach, and
/// almost none of what it decides needs a screen to be right: which card is up,
/// what the title says, which office a booking goes to, whether the primary
/// button writes or asks first, and which rows admit the model could not read
/// them. Every one of those is a `static` on `CaptureSheet` and is asserted here
/// directly. The one test that renders says so, and says what it is for.
///
/// Driven through a real `CaptureCoordinator` wherever the phase machine can
/// produce the state, with the extractor and the write stubbed by doubles that
/// record every argument — the standard `CaptureCoordinatorTests` sets, and for
/// the same reason: a double that answers the same thing whatever it is handed
/// proves nothing about the boundary it stands in for.
@Suite("The capture review sheet")
@MainActor
struct CaptureSheetTests {

    let container: ModelContainer
    let coordinator: CaptureCoordinator
    let sent = Sent()

    init() throws {
        container = try Store.makeInMemoryContainer(seeded: true)
        coordinator = CaptureCoordinator(context: container.mainContext)
        // The deliberate half second is for a person reading the sheet.
        coordinator.parsingFloor = .zero
    }

    func stub(_ bookings: [ParsedBooking]) {
        coordinator.extractor = { [sent] data, mediaType, today in
            sent.record(data, mediaType, today)
            return (bookings, CaptureSamples.usage)
        }
    }

    var image: Data { CaptureSamples.pixel }

    func bookings() throws -> [DeskBooking] {
        try container.mainContext.fetch(FetchDescriptor<DeskBooking>())
    }

    func office(_ id: UUID) throws -> Office {
        try #require(
            try container.mainContext.fetch(FetchDescriptor<Office>()).first { $0.id == id }
        )
    }

    /// What the sheet would be showing right now, asked exactly as `body` asks
    /// it — phase and current booking together, because a `.review` phase whose
    /// index has run off the end draws neither.
    func shown() -> CaptureSheet.Shown {
        CaptureSheet.shown(for: coordinator.phase, current: coordinator.current)
    }

    // MARK: What broke, and which half of the pipeline it was

    /// The header and the title were both hard-coded to the reading. That was
    /// true of every failure that could reach the card until `couldNotSave`
    /// arrived: a booking the model read perfectly and the store then refused.
    /// "Couldn't read that screenshot" over "That booking couldn't be saved"
    /// contradicts the sentence underneath it, and sends someone off to
    /// re-share an image that was never the problem — past `Enter manually`,
    /// which is the one offer on the card that could have helped.
    @Test("A booking that failed to save is not reported as a screenshot that failed to read")
    func aWriteFailureIsNotBlamedOnTheReading() async throws {
        stub(CaptureSamples.colemanWeek)
        await coordinator.receive(data: image, filename: "week.png")
        let booking = try #require(coordinator.current)

        let attempted = Attempted()
        coordinator.writeBooking = { candidate, captureID, chosen in
            attempted.record(candidate, captureID, chosen)
            throw StoreFailure.diskFull
        }
        coordinator.save(booking, to: SeedData.colemanID)

        // The double refused, but it was asked for the booking the sheet was
        // showing — not for some canned candidate.
        #expect(attempted.candidates.map(\.deskID) == [booking.deskID])
        #expect(attempted.candidates.map(\.officeID) == [SeedData.colemanID])
        #expect(attempted.chosen == [false])

        guard case .failure(let error) = shown() else {
            Issue.record("a refused write has to reach the card the user is looking at")
            return
        }
        #expect(CaptureSheet.failureHeader(for: error) == "Couldn't save that booking")
        #expect(CaptureSheet.title(for: coordinator.phase) == "Couldn't save it")
        // And the body, which was already right, still agrees with them.
        #expect(
            error.errorDescription
                == "That booking couldn't be saved: \(StoreFailure.diskFull.localizedDescription)."
                    + " Nothing was written."
        )
    }

    /// The negative, and the reason the switch is spelled out case by case
    /// rather than defaulted: every failure that really is about the reading
    /// keeps the wording it had, so the fix above cannot be "rename the header
    /// and hope".
    @Test("Every failure before the write still says the reading was what went wrong")
    func readingFailuresKeepTheirWording() {
        let reading: [CaptureError] = [
            .noAPIKey, .unsupportedFile("pdf"), .unreadableImage, .network("offline"),
            .httpStatus(529, "overloaded"), .modelReturnedNothingUsable("no rows"), .refused,
        ]
        for error in reading {
            #expect(CaptureSheet.failureHeader(for: error) == "Couldn't read that screenshot")
            #expect(CaptureSheet.title(for: .failed(error)) == "Couldn't read it")
        }
        #expect(
            CaptureSheet.failureHeader(for: .couldNotSave("the disk is full"))
                != CaptureSheet.failureHeader(for: .refused),
            "the two halves of the pipeline do not share a heading"
        )
        #expect(
            CaptureSheet.title(for: .failed(.couldNotSave("the disk is full")))
                != CaptureSheet.title(for: .failed(.refused))
        )
    }

    // MARK: Which card is up

    /// One sheet for all three faces, so the flow never flashes between
    /// presentations — which makes "which card is up" a decision rather than a
    /// navigation, and one worth asserting. Held at the model call rather than
    /// timed, because the parsing card only exists while a run is in flight.
    @Test("The card and the title follow the phase, from reading through to confirming")
    func theCardFollowsThePhase() async throws {
        #expect(shown() == .nothing, "an idle coordinator draws no card")
        #expect(CaptureSheet.title(for: coordinator.phase) == "")

        let entered = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        coordinator.extractor = { [sent] data, mediaType, today in
            sent.record(data, mediaType, today)
            entered.continuation.yield()
            for await _ in release.stream { break }
            return (CaptureSamples.colemanWeek, CaptureSamples.usage)
        }

        let running = Task { await coordinator.receive(data: image, filename: "week.png") }
        for await _ in entered.stream { break }

        #expect(shown() == .parsing(.finding), "the call is out; the checklist is on that step")
        #expect(CaptureSheet.title(for: coordinator.phase) == "Reading")

        release.continuation.yield()
        await running.value

        guard case .review(let booking) = shown() else {
            Issue.record("the response arrived and the sheet should be confirming it")
            return
        }
        #expect(booking.deskID == "CO03A424", "and on the first row of the table")
        #expect(CaptureSheet.title(for: coordinator.phase) == "Confirm")
        #expect(sent.mediaType == "image/png", "the bytes the sheet was drawn for")

        coordinator.abort()
        #expect(shown() == .nothing, "cancelling takes the card away, which dismisses the sheet")
    }

    /// `body` guards the review card on `coordinator.current` rather than on
    /// the phase alone, and this is the state that guard is for. `HaikuClient`
    /// refuses an empty parse, so nothing should reach it — but an empty white
    /// card under a "Confirm" title, with only Cancel on it, is the worst
    /// possible way to discover that something did.
    @Test("A review phase with no booking at its index draws no card at all")
    func anEmptyReviewDrawsNothing() {
        coordinator.phase = .review(bookings: [], index: 0, saved: [])

        #expect(coordinator.current == nil)
        #expect(shown() == .nothing)
    }

    // MARK: The reading checklist

    /// Done, active, or pending, from real progress — a step that completes
    /// instantly flashes past rather than being held open to look busy.
    @Test("The checklist marks what is done, what is under way, and what is still to come")
    func theChecklistFollowsRealProgress() {
        let steps: [CaptureCoordinator.Step] = [.received, .finding, .matching]
        #expect(steps.map { CaptureSheet.tick($0, at: .received) } == [.active, .pending, .pending])
        #expect(steps.map { CaptureSheet.tick($0, at: .finding) } == [.done, .active, .pending])
        #expect(steps.map { CaptureSheet.tick($0, at: .matching) } == [.done, .done, .active])

        // The label greying is a separate rule from the marker, and the step
        // under way must not be greyed with the ones still to come — a
        // checklist where nothing is black reads as though nothing has started.
        #expect(CaptureSheet.Tick.done.reached)
        #expect(CaptureSheet.Tick.active.reached)
        #expect(CaptureSheet.Tick.pending.reached == false)
    }

    // MARK: The bar over a table of bookings

    @Test("The bar marks what was filed, where you are, and what is still to come")
    func theBarSaysWhatWasSaved() async throws {
        stub(CaptureSamples.colemanWeek)
        await coordinator.receive(data: image, filename: "week.png")

        let first = try #require(coordinator.position)
        #expect(first.number == 1)
        #expect(
            CaptureSheet.bar(saved: coordinator.segments, current: first.number - 1)
                == [.current, .pending, .pending]
        )

        coordinator.save(try #require(coordinator.current), to: SeedData.colemanID)

        let second = try #require(coordinator.position)
        #expect(
            CaptureSheet.bar(saved: coordinator.segments, current: second.number - 1)
                == [.saved, .current, .pending]
        )
    }

    /// Saved has to outrank current, not the other way round: only a write that
    /// landed may be drawn as one, and the highlight for "this is the one you
    /// are on" must never be able to hide it.
    @Test("A booking already filed stays marked filed even when it is the one on screen")
    func savedOutranksCurrent() {
        #expect(CaptureSheet.bar(saved: [true, false], current: 0) == [.saved, .pending])
        #expect(CaptureSheet.bar(saved: [], current: 0) == [], "and no table, no bar")
    }

    /// Three states, three colours, and the green is the one that means filed.
    @Test("The bar's three states are drawn in three different colours")
    func theBarsColoursAreDistinct() {
        #expect(CaptureSheet.colour(of: .saved) == Palette.met)
        #expect(CaptureSheet.colour(of: .current) == Palette.tint)
        #expect(CaptureSheet.colour(of: .pending) == Palette.hairline)
    }

    // MARK: Which office the booking is filed under

    /// A match outranks the picker rather than merging with it. The picker is
    /// not even drawn when the matcher answers, so a `chosenOffice` left over
    /// from the previous row of the same table would otherwise decide where
    /// this one went with nothing on screen saying so.
    @Test("A matched office outranks whatever the picker was last left on")
    func aMatchOutranksTheLeftoverChoice() {
        #expect(
            CaptureSheet.officeToFileUnder(
                matched: SeedData.colemanID, chosen: SeedData.brusselsID
            ) == SeedData.colemanID
        )
        #expect(
            CaptureSheet.officeToFileUnder(matched: nil, chosen: SeedData.brusselsID)
                == SeedData.brusselsID,
            "and with no match the answer the user gave is the answer"
        )
        #expect(CaptureSheet.officeToFileUnder(matched: nil, chosen: nil) == nil)
    }

    @Test("The office question quotes the name that was printed, when there was one")
    func theOfficeQuestionQuotesWhatWasRead() {
        #expect(
            CaptureSheet.officeQuestion(printed: "Ropemaker Place")
                == "Which office is \"Ropemaker Place\"?"
        )
        #expect(
            CaptureSheet.officeQuestion(printed: nil) == "Which office is this?",
            "a row with no building name on it still has to ask something"
        )
    }

    // MARK: The clash, and what the button does about it

    /// Re-importing the same desk changes nothing but gaps being filled, and a
    /// destructive confirmation for that is a question with one answer — asked
    /// on every re-share of a table the user has already filed.
    @Test("Only a different desk on the same day is a clash worth asking about")
    func onlyADifferentDeskAsks() throws {
        let existing = try #require(try bookings().first { $0.day == Day(2026, 8, 5) })
        #expect(existing.deskID == "3C-114")

        #expect(CaptureSheet.clash(with: existing, incoming: "CO03A424")?.deskID == "3C-114")
        #expect(
            CaptureSheet.clash(with: existing, incoming: "3C-114") == nil,
            "the same desk again is not a question"
        )
        #expect(CaptureSheet.clash(with: nil, incoming: "3C-114") == nil, "and nor is a free day")
    }

    /// The whole review decision end to end, on the state the seed already
    /// holds: 5 August at Coleman is booked to 3C-114, and a capture arrives
    /// putting a different desk on it. The office resolves without asking, the
    /// clash is real, and the button that was going to say Save says Replace.
    @Test("A capture landing on a day already booked elsewhere offers Replace, not Save")
    func aClashTurnsTheButtonIntoReplace() async throws {
        stub([ParsedBooking(
            officeName: "Coleman, London", day: Day(2026, 8, 5), deskID: "CO03C407",
            floor: "03", zone: "C", startTime: "08:00", endTime: "17:00", unsureFields: []
        )])
        await coordinator.receive(data: image, filename: "one.png")
        let booking = try #require(coordinator.current)

        let matched = try #require(coordinator.matchedOffice(for: booking))
        let officeID = try #require(
            CaptureSheet.officeToFileUnder(matched: matched.id, chosen: nil)
        )
        #expect(officeID == SeedData.colemanID)

        let clash = try #require(CaptureSheet.clash(
            with: coordinator.existingBooking(day: booking.day, officeID: officeID),
            incoming: booking.deskID
        ))
        #expect(clash.deskID == "3C-114")

        #expect(
            CaptureSheet.primaryAction(
                officeID: officeID, replacing: true, isLast: coordinator.isLast
            ) == CaptureSheet.PrimaryAction(title: "Replace…", enabled: true, asksFirst: true)
        )
        #expect(
            CaptureSheet.clashMessage(
                existing: clash.deskID, provenance: coordinator.provenance(of: clash)
            ).hasPrefix("This day already has desk 3C-114 at this office, read from an image")
        )

        // And the same day at the other office is not this booking's clash.
        #expect(
            coordinator.existingBooking(day: booking.day, officeID: SeedData.brusselsID) == nil
        )
    }

    /// The dialog covers the card that named the desk, so it has to say where
    /// the held one came from — and when there is nothing knowable it says the
    /// sentence without a dangling comma rather than an empty clause.
    @Test("The clash message names the held desk's source, and reads without one")
    func theClashMessageSurvivesAnUnknownSource() {
        #expect(
            CaptureSheet.clashMessage(existing: "3C-121", provenance: "entered by hand")
                == "This day already has desk 3C-121 at this office, entered by hand. "
                    + "Only one desk is kept per office per day."
        )
        #expect(
            CaptureSheet.clashMessage(existing: "3C-121", provenance: nil)
                == "This day already has desk 3C-121 at this office. "
                    + "Only one desk is kept per office per day."
        )
        #expect(
            CaptureSheet.clashMessage(existing: nil, provenance: nil)
                == "This day already has desk a desk at this office. "
                    + "Only one desk is kept per office per day."
        )
    }

    /// Only a desk typed by hand is labelled. One that came from a capture is
    /// the same kind of record as the one arriving, so naming its source on the
    /// strip would be noise on every re-share.
    @Test("The clash strip names a hand-typed desk's source and leaves a captured one bare")
    func theClashStripNamesOnlyTheHandTyped() throws {
        let typed = try #require(try bookings().first { $0.day == Day(2026, 8, 12) })
        #expect(typed.source == .manual)
        let (leading, trailing) = CaptureSheet.clashText(
            deskID: typed.deskID, source: typed.source
        )
        #expect(leading == "Already booked: 3C-121")
        #expect(trailing == "entered by hand")

        let captured = try #require(try bookings().first { $0.day == Day(2026, 8, 5) })
        #expect(captured.source == .capture)
        let fromACapture = CaptureSheet.clashText(
            deskID: captured.deskID, source: captured.source
        )
        #expect(fromACapture.0 == "Already booked: 3C-114")
        #expect(fromACapture.1 == nil)
    }

    /// Disabled rather than hidden while the office is unanswered: the button
    /// is what the user is looking for, and taking it away reads as the sheet
    /// being broken rather than as the picker above it being unanswered.
    @Test("The primary button says what it will do, and is dead until an office is known")
    func thePrimaryButtonSaysWhatItDoes() {
        #expect(
            CaptureSheet.primaryAction(officeID: SeedData.colemanID, replacing: false, isLast: false)
                == CaptureSheet.PrimaryAction(
                    title: "Save and next", enabled: true, asksFirst: false
                )
        )
        #expect(
            CaptureSheet.primaryAction(officeID: SeedData.colemanID, replacing: false, isLast: true)
                == CaptureSheet.PrimaryAction(
                    title: "Save and finish", enabled: true, asksFirst: false
                )
        )
        // A clash outranks the position in the table: the last row of three
        // still says Replace, because that is what the tap is about to do.
        #expect(
            CaptureSheet.primaryAction(officeID: SeedData.colemanID, replacing: true, isLast: true)
                == CaptureSheet.PrimaryAction(title: "Replace…", enabled: true, asksFirst: true)
        )

        let unanswered = CaptureSheet.primaryAction(
            officeID: nil, replacing: false, isLast: true
        )
        #expect(unanswered.enabled == false, "nowhere to file it yet")
        #expect(unanswered.title == "Save and finish", "and it is still there to be answered")
    }

    // MARK: The detail rows

    @Test("The detail rows show what was read, in order, and flag only what was not")
    func theDetailRowsFlagTheUnread() {
        let booking = ParsedBooking(
            officeName: "Coleman, London", day: Day(2026, 8, 4), deskID: "CO03A424",
            floor: nil, zone: nil, startTime: "08:00", endTime: "17:00",
            unsureFields: ["floor", "zone"]
        )
        let rows = CaptureSheet.fieldRows(booking, office: nil)

        #expect(rows.map(\.label) == ["Office", "Date", "Desk", "Floor", "Hours"])
        #expect(rows.map(\.value) == [
            "Coleman, London", Day(2026, 8, 4).longText, "CO03A424", nil, "08:00 – 17:00",
        ])
        #expect(
            rows.map(\.needsChecking) == [false, false, false, true, false],
            "the floor was named as unread and nothing else on the card was"
        )
    }

    /// A name the model was unsure of stops being a question once the matcher
    /// has resolved it: the row then shows the office's own stored name, and
    /// there is nothing left for the user to check.
    @Test("An office name the model doubted is only flagged while nothing has answered it")
    func theOfficeFlagFollowsTheMatch() throws {
        var booking = CaptureSamples.colemanWeek[0]
        booking.unsureFields = ["office"]

        let matched = try #require(coordinator.matchedOffice(for: booking))
        let resolved = CaptureSheet.fieldRows(booking, office: matched)
        #expect(resolved[0].value == "Coleman", "the office's own name, not the printed one")
        #expect(resolved[0].needsChecking == false)

        let unresolved = CaptureSheet.fieldRows(booking, office: nil)
        #expect(unresolved[0].value == "Coleman, London", "the printed name, until it is answered")
        #expect(unresolved[0].needsChecking)
    }

    /// Hours is two fields printed as one row, so either being unread has to
    /// flag it. Reading only `startTime` presented a day ending at a time
    /// nobody had read as fact.
    @Test("Either end of the day being unread flags the hours row")
    func eitherEndFlagsTheHours() {
        func hours(_ unsure: [String]) -> CaptureSheet.Field {
            CaptureSheet.fieldRows(
                ParsedBooking(
                    officeName: nil, day: Day(2026, 8, 4), deskID: "CO03A424", floor: "03",
                    zone: nil, startTime: "08:00", endTime: "17:00", unsureFields: unsure
                ),
                office: nil
            )[4]
        }
        #expect(hours(["startTime"]).needsChecking)
        #expect(hours(["endTime"]).needsChecking)
        #expect(hours(["startTime", "endTime"]).needsChecking)
        #expect(hours(["zone"]).needsChecking == false, "a zone is not on this card at all")
        #expect(hours([]).needsChecking == false)
    }

    /// `until 17:00` rather than `– 17:00`: a dash with nothing in front of it
    /// reads as a value that went missing rather than as a day that starts
    /// whenever you arrive.
    @Test("The hours row prints one end, both ends, or nothing at all")
    func hoursReadAsASentence() {
        #expect(CaptureSheet.hours(start: "08:00", end: "17:00") == "08:00 – 17:00")
        #expect(CaptureSheet.hours(start: "08:00", end: nil) == "08:00")
        #expect(CaptureSheet.hours(start: nil, end: "17:00") == "until 17:00")
        #expect(CaptureSheet.hours(start: nil, end: nil) == nil, "and an empty row shows a dash")
    }

    // MARK: The body itself

    /// The part no extraction reaches: the `@Query`, the office picker, the
    /// toolbar, the confirmation dialog, the three card builders.
    ///
    /// The claim is not about what the pixels say — everything that can be said
    /// about those is asserted above, where a wrong word fails for a reason.
    /// It is that drawing this sheet is not a write. The review card reads the
    /// store *while it draws*: `matchedOffice` and `existingBooking` both run
    /// inside `body`, and `matchedOffice` sits one call away from `remember`,
    /// which does write. So a booking filed, an alias taught, or the row
    /// advancing under a layout pass all fail here — as does a trap in any of
    /// the seven states walked through, which is the other half of it.
    ///
    /// Every branch of the review card is walked, not just the one the capture
    /// happened to leave up: the office picker only draws when nothing matched,
    /// and the clash strip only when the day is already held at another desk.
    @Test("Every state of the sheet draws, and drawing it writes nothing")
    func drawingTheSheetChangesNothing() async throws {
        stub(CaptureSamples.colemanWeek)
        await coordinator.receive(data: image, filename: "week.png")

        let sheet = CaptureSheet(coordinator: coordinator)
        let filed = try bookings().count
        let aliases = try office(SeedData.colemanID).aliases
        let showing = try #require(coordinator.current).id

        // As the capture left it: three bookings, the first up, its office
        // matched, and 4 August free — so no picker and no clash.
        render(sheet)
        #expect(coordinator.current?.id == showing, "drawing the row is not answering it")
        #expect(coordinator.segments == [false, false, false], "nor saving it")

        // 5 August is seeded to 3C-114 at Coleman, so this one draws the strip.
        let clashing = ParsedBooking(
            officeName: "Coleman, London", day: Day(2026, 8, 5), deskID: "CO03C407",
            floor: "03", zone: "C", startTime: "08:00", endTime: "17:00", unsureFields: []
        )
        #expect(coordinator.matchedOffice(for: clashing)?.id == SeedData.colemanID)
        #expect(
            CaptureSheet.clash(
                with: coordinator.existingBooking(
                    day: clashing.day, officeID: SeedData.colemanID
                ),
                incoming: clashing.deskID
            ) != nil,
            "which is the branch this render is here for"
        )
        coordinator.phase = .review(bookings: [clashing], index: 0, saved: [])
        render(sheet)

        // A building name no rule can reach, which is the picker's branch.
        let unknown = ParsedBooking(
            officeName: "Ropemaker Place", day: Day(2026, 8, 19), deskID: "RP01A100",
            floor: nil, zone: nil, startTime: nil, endTime: "17:00", unsureFields: ["floor"]
        )
        #expect(coordinator.matchedOffice(for: unknown) == nil, "so the sheet has to ask")
        coordinator.phase = .review(bookings: [unknown], index: 0, saved: [])
        render(sheet)

        // Both ends of the checklist, then the failure card with a retry to
        // offer and without one, then the empty sheet a dismissal leaves.
        coordinator.phase = .parsing(step: .received)
        render(sheet)
        coordinator.phase = .parsing(step: .matching)
        render(sheet)

        coordinator.phase = .failed(.network("offline"))
        #expect(coordinator.canRetry, "the image decoded, so Try again is drawn")
        render(sheet)

        // The write failure clears the retry, which is why it is the state that
        // draws the card without one.
        coordinator.failed(.couldNotSave("the disk is full"))
        #expect(coordinator.canRetry == false)
        render(sheet)

        coordinator.phase = .idle
        render(sheet)

        #expect(try bookings().count == filed, "no state of the sheet writes a booking")
        #expect(try office(SeedData.colemanID).aliases == aliases, "and none teaches an alias")
        #expect(sent.calls == 1, "and drawing the failure card does not re-run the capture")
    }

    /// The first run: a screenshot shared into an app with no offices in it
    /// yet. The sheet asks which office the booking is for and has nothing to
    /// offer as an answer, so the only honest thing it can do is say so and
    /// leave the button dead. It must never invent one — a silently created
    /// office gets its own perimeter, and the user finds out months later when
    /// the arrival alert never fires.
    @Test("A capture arriving before any office exists asks, offers nothing, and files nothing")
    func aCaptureWithNoOfficeToFileUnder() throws {
        let empty = try Store.makeInMemoryContainer(seeded: false)
        let capture = CaptureCoordinator(context: empty.mainContext)
        let booking = try #require(CaptureSamples.one.first)
        capture.phase = .review(bookings: [booking], index: 0, saved: [])

        #expect(capture.matchedOffice(for: booking) == nil, "so the picker is what draws")
        let action = CaptureSheet.primaryAction(
            officeID: CaptureSheet.officeToFileUnder(matched: nil, chosen: nil),
            replacing: false, isLast: capture.isLast
        )
        #expect(action.enabled == false, "and there is nowhere for it to go")

        render(CaptureSheet(coordinator: capture), in: empty)

        #expect(
            try empty.mainContext.fetchCount(FetchDescriptor<Office>()) == 0,
            "drawing the question does not answer it by inventing an office"
        )
        #expect(try empty.mainContext.fetchCount(FetchDescriptor<DeskBooking>()) == 0)
    }

    /// In a window and made key. A hosting controller laid out on its own never
    /// evaluates the body, so the same helper written without this executes
    /// nothing and every assertion after it passes for the wrong reason — which
    /// is the exact class of test this whole review exists to remove.
    private func render(_ sheet: CaptureSheet, in store: ModelContainer? = nil) {
        let window = ArrivalPreviewRenderTests.renderWindow()
        window.rootViewController = UIHostingController(
            rootView: sheet.modelContainer(store ?? container)
        )
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        // See ArrivalPreviewRenderTests.dismantle: a window left key outlives
        // the container it was handed and crashes the host from another suite.
        ArrivalPreviewRenderTests.dismantle(window, holding: store ?? container)
    }

    // MARK: Helpers

    /// Every argument the extractor was handed, so a test can assert on any of
    /// them rather than trusting a fake that answers the same thing whatever it
    /// is given.
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
}
