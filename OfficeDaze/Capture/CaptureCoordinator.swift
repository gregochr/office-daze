import Foundation
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// A capture, from the file arriving to the last booking being saved.
///
/// Lives for the app's lifetime rather than a screen's: iOS launches the app
/// *with* the shared file, so the capture starts before any sheet exists and
/// has to outlive the one that shows it.
@MainActor
@Observable
final class CaptureCoordinator {

    /// The three-step checklist on the loading sheet, driven by real progress:
    /// received when the file lands, finding when the request goes out,
    /// matching when the response is parsed.
    enum Step: Int, Comparable, Sendable {
        case received, finding, matching

        static func < (a: Step, b: Step) -> Bool { a.rawValue < b.rawValue }
    }

    enum Phase {
        case idle
        case parsing(step: Step)
        /// Reviewing booking `index` of `bookings`, with `saved` already
        /// committed.
        case review(bookings: [ParsedBooking], index: Int, saved: Set<UUID>)
        case failed(CaptureError)
    }

    var phase: Phase = .idle

    /// How long the parsing sheet stays up at minimum.
    ///
    /// The checklist is driven by real progress everywhere else, which is
    /// right — a step that finishes instantly should not be held open to look
    /// busy. But a fast parse blinked the sheet from Reading to Confirm with
    /// nothing legible in between, and the user arrived at a filled-in form
    /// without having seen where it came from. Half a second is one of the few
    /// places a deliberate delay earns its keep. Settable so tests do not pay
    /// it, and so it can be turned off entirely.
    var parsingFloor: Duration = .milliseconds(500)

    /// Kept so `Try again` has something to retry with.
    private var lastInput: (data: Data, mediaType: String)?
    private var captureID: UUID?

    /// Which run the phase belongs to.
    ///
    /// A run has two suspension points — the model call and the floor above —
    /// and the user can cancel or retry across either. Without this the run
    /// that was abandoned still wakes up and writes its result: Cancel, then
    /// half a second later the sheet reappears holding bookings from a capture
    /// the user has already dismissed.
    private var generation = 0

    /// Swapped in tests so nothing reaches the network.
    var extractor: (Data, String, Day) async throws -> ([ParsedBooking], HaikuClient.Usage) = {
        data, mediaType, today in
        guard let key = Keychain.apiKey, !key.isEmpty else { throw CaptureError.noAPIKey }
        return try await HaikuClient(apiKey: key).extract(
            image: data, mediaType: mediaType, today: today
        )
    }

    /// The re-encode in front of the call, injectable for one reason: it is a
    /// suspension point the user can cancel across, and the only way to prove
    /// Cancel is honoured there is to hold it open on demand. `@Sendable`
    /// because it runs off the main actor — that is the whole point of it.
    var preparer: @Sendable (Data) throws -> (data: Data, mediaType: String) = {
        try PhotoImport.prepare($0)
    }

    /// The booking write, injectable for the same reason: a `context.save()`
    /// cannot be made to fail on demand from outside, and the failure is
    /// exactly what needs pinning — a write that did not land used to be drawn
    /// to the user as a green segment.
    var writeBooking: (_ candidate: BookingMerge.Candidate, _ captureID: UUID?, _ chosen: Bool)
        throws -> Void

    /// A write this coordinator makes *beside* the booking, named by what it was
    /// for rather than left as a bare `context.save()`.
    ///
    /// There are two, and neither is the thing the user came here to do: the
    /// office name the sheet had to ask about, so the next capture does not ask
    /// again, and the capture's own line in the month's call count and cost.
    /// Naming them is what lets a failure be reported as what was missed, and
    /// what stops the double that stands in for the store in a test being handed
    /// nothing it can be held to.
    enum Aside: Equatable, Sendable {
        /// The answer to "which office is this?", written onto that office and
        /// taken off every other one on the way.
        case officeName(String, officeID: UUID)
        /// One call, its outcome and what it cost — the whole of what Settings'
        /// monthly total is made of.
        case captureCost(id: UUID, status: CaptureStatus, inputTokens: Int, outputTokens: Int)
    }

    /// An aside whose save did not go through, and why.
    struct UnsavedAside: Equatable, Sendable {
        let aside: Aside
        let reason: String
    }

    /// Every aside that did not land, in order.
    ///
    /// Deliberately not an alert — `write(_:)` says why at length — but just as
    /// deliberately not nothing. The `try?` that used to stand in its place was a
    /// failure the app could not notice, a test could not reach and no future
    /// screen could ever report. Whatever eventually wants to say "your month's
    /// cost is short by a call" or "you will be asked which office this is
    /// again" reads this. It accumulates for the life of the app, which is a
    /// couple of small values per capture and the only span over which the
    /// question is worth asking.
    private(set) var unsavedAsides: [UnsavedAside] = []

    /// The asides' save, injectable for the same reason `writeBooking` is — a
    /// `context.save()` cannot be made to fail on demand from outside. What
    /// needs pinning here is the opposite of what needs pinning there: that a
    /// failure does *not* take the capture down with it.
    var writeAside: (Aside) throws -> Void

    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
        // Captures the parameter rather than `self`, so this can be a stored
        // property with a real default instead of an optional nobody sets.
        writeBooking = { candidate, captureID, chosen in
            try BookingStore.upsert(
                candidate, captureID: captureID, chosen: chosen, in: context
            )
        }
        // The aside is already a pending change on the context by the time this
        // runs; committing it is all that is left to do.
        writeAside = { _ in try context.save() }
    }

    /// Commits an aside, and carries on if it will not commit.
    ///
    /// This is the one place in the coordinator where a write that failed is not
    /// raised to the user, and the reason is what raising it would cost.
    /// `failed(_:)` replaces `.review` with an error screen, which throws away
    /// every booking in the table that has not been saved yet. Spending that on
    /// the office alias — a convenience whose entire consequence when lost is
    /// that the sheet asks which office this is once more — or on a line in
    /// Settings' monthly cost would be losing the user's bookings to protect
    /// their bookkeeping. The booking's own write is the one that has earned the
    /// screen, and it already has it.
    ///
    /// It costs less than it looks like, too: both asides are pending changes on
    /// the same context as that write, so in the ordinary transient failure the
    /// booking's `save()` flushes them a line later and nothing is lost at all,
    /// and in the failure that persists the booking's save fails too and the
    /// user is told about the thing that mattered. Routing either of these to
    /// `.couldNotSave` would also put the words "That booking couldn't be saved"
    /// on screen before any booking had been attempted, which is simply untrue.
    ///
    /// What is not acceptable, and what was here, is `try?`. Carrying on is a
    /// decision; discarding the fact is not.
    private func write(_ aside: Aside) {
        do {
            try writeAside(aside)
        } catch {
            unsavedAsides.append(
                UnsavedAside(aside: aside, reason: error.localizedDescription)
            )
        }
    }

    var isActive: Bool {
        if case .idle = phase { return false }
        return true
    }

    // MARK: Intake

    /// iOS copied the shared file into our inbox and launched us. This is the
    /// whole share-sheet path, in place of an extension.
    ///
    /// The copy is ours to remove. `Info.plist` declares document types without
    /// `LSSupportsOpeningDocumentsInPlace`, so iOS never hands over the sender's
    /// file — it duplicates it into `Documents/Inbox/`, uniquifying rather than
    /// overwriting, and the documented contract is that the receiving app
    /// deletes it. Nothing else in the app ever would: `Store.wipe` reaches the
    /// database and not the container, so every shared screenshot would sit in
    /// `Documents` — and therefore in every iCloud backup — for the life of the
    /// install, on top of the copy the database already holds.
    func receive(url: URL) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer {
            if scoped { url.stopAccessingSecurityScopedResource() }
            if Self.isInboxCopy(url) { try? FileManager.default.removeItem(at: url) }
        }

        guard let data = try? Data(contentsOf: url) else {
            // Not "we can't read a .FILE file". The read failed, which says
            // nothing about the format unless the format is one we have no
            // decoder for in the first place.
            phase = .failed(Self.failure(forExtension: url.pathExtension))
            return
        }
        await receive(data: data, filename: url.lastPathComponent)
    }

    /// Whether this URL is a copy iOS made for us, and so ours to delete.
    ///
    /// Guarded on the path rather than deleting whatever arrives, because the
    /// day `LSSupportsOpeningDocumentsInPlace` is added the URL becomes the
    /// sender's own document and removing it would delete the user's file out
    /// of another app.
    static func isInboxCopy(_ url: URL) -> Bool {
        url.isFileURL && url.path.contains("/Documents/Inbox/")
    }

    func receive(data: Data, filename: String) async {
        // The extension is only good for the error message. What the bytes
        // actually are is ImageIO's answer, not the filename's — a share from
        // Photos arrives as .heic or .jpeg with no promise about its size, and
        // the size is what the API rejected.
        let ext = (filename as NSString).pathExtension
        await receive(image: data, unreadableAs: ext.isEmpty ? nil : ext)
    }

    /// A photo chosen from the library — raw bytes, no filename to go on.
    func receive(photo data: Data) async {
        await receive(image: data, unreadableAs: nil)
    }

    /// The one intake every path goes through, because every path can hand over
    /// a 12MP camera frame: the share sheet as readily as the picker.
    ///
    /// The re-encode runs before `lastInput` is set, so `Try again` repeats the
    /// model call and not the conversion — and an image that never decoded
    /// leaves `lastInput` nil, which is what `canRetry` reads to hide a retry
    /// that could only fail the same way twice.
    private func receive(image data: Data, unreadableAs ext: String?) async {
        // The sheet appears the instant the file lands, not when the response
        // does — the call takes a couple of seconds and a blank screen for
        // those seconds reads as a hang.
        //
        // Which means Cancel is live while the re-encode runs off-actor, and
        // the re-encode of a 12MP frame is a few hundred milliseconds of it.
        // `run()` guards its own two suspension points on this counter for
        // exactly the same reason; this one was missed, and the cancelled
        // capture would wake up, re-arm `lastInput`, spend an API call and
        // re-present the sheet the user had just dismissed.
        generation += 1
        let attempt = generation
        phase = .parsing(step: .received)
        do {
            let prepared = try await Task.detached { [preparer] in try preparer(data) }.value
            guard attempt == generation else { return }
            lastInput = (prepared.data, prepared.mediaType)
            await run()
        } catch {
            guard attempt == generation else { return }
            phase = .failed(Self.failure(forExtension: ext))
        }
    }

    /// The formats ImageIO decodes for us. An extension in this list is never
    /// the diagnosis of a preparation failure.
    private static let readableExtensions: Set<String> = [
        "png", "jpg", "jpeg", "heic", "heif", "gif", "webp", "tiff", "tif", "bmp",
    ]

    /// Why the bytes never became an image, in the only terms the app can
    /// honestly claim.
    ///
    /// `PhotoImport.prepare` throws `.unreadableImage` from four places — no
    /// image source, an empty one, a failed thumbnail, a failed encode — and
    /// only the first of those is ever about the format. Deciding the message
    /// from the extension alone told someone whose screenshot arrived truncated
    /// that "Office Daze can't read a .PNG file", which is false about the
    /// app's commonest input and sends them off to type the booking in by hand
    /// instead of re-sharing it. A PDF still says so by name, because there the
    /// format really is the answer.
    private static func failure(forExtension ext: String?) -> CaptureError {
        guard let ext, !ext.isEmpty, !readableExtensions.contains(ext.lowercased()) else {
            return .unreadableImage
        }
        return .unsupportedFile(ext)
    }

    /// The photo could not be loaded out of the library at all. Surfaced
    /// through the same sheet as every other failure rather than as a tap that
    /// appears to do nothing.
    func failed(_ error: CaptureError) {
        lastInput = nil
        phase = .failed(error)
    }

    /// False when the failure happened before there was anything to send —
    /// an unreadable file, an unsupported one. Offering `Try again` there is
    /// offering a button that does nothing.
    var canRetry: Bool { lastInput != nil }

    func retry() async {
        guard lastInput != nil else { return }
        phase = .parsing(step: .received)
        await run()
    }

    private func run() async {
        guard let (data, mediaType) = lastInput else { return }
        generation += 1
        let run = generation
        let started = ContinuousClock.now
        do {
            phase = .parsing(step: .finding)
            let (bookings, usage) = try await extractor(data, mediaType, .today)
            guard run == generation else { return }

            // A parse with nothing in it is a failure, not a review. Today the
            // only extractor refuses an empty list itself, so nothing reaches
            // here — but taking the extractor's word for it made `.review` the
            // one phase that could be entered with nothing to show: `current`
            // nil, `isLast` false, `position` nil, and a sheet titled "Confirm"
            // holding no card and no way out but Cancel. The sheet was hardened
            // to draw no card there, which stops it looking broken; only
            // refusing the phase at the source stops the dead end. The
            // alternative — leaving the invariant to whoever writes the next
            // extractor — is how it got here in the first place.
            guard !bookings.isEmpty else {
                // Recorded with the usage, unlike the `catch` below: the call
                // went out and was billed, and Settings' monthly cost is wrong
                // by exactly that call if a response that came back empty is
                // written down as having cost nothing.
                record(status: .failed, usage: usage)
                phase = .failed(.modelReturnedNothingUsable("no bookings in the document"))
                return
            }
            phase = .parsing(step: .matching)

            captureID = record(status: .parsed, usage: usage)
            // Only the success path waits. A failure is a screen the user has
            // to read and act on, and holding it back would be delaying bad
            // news for the sake of an animation.
            let elapsed = ContinuousClock.now - started
            if elapsed < parsingFloor {
                try? await Task.sleep(for: parsingFloor - elapsed)
            }
            guard run == generation else { return }
            phase = .review(bookings: bookings, index: 0, saved: [])
        } catch let error as CaptureError {
            guard run == generation else { return }
            record(status: .failed, usage: nil)
            phase = .failed(error)
        } catch {
            guard run == generation else { return }
            phase = .failed(.network(error.localizedDescription))
        }
    }

    // MARK: Review

    var current: ParsedBooking? {
        guard case .review(let bookings, let index, _) = phase, index < bookings.count else {
            return nil
        }
        return bookings[index]
    }

    /// `Booking 2 of 3`, and the three-segment bar. Nil for a single booking,
    /// which hides both.
    var position: (number: Int, total: Int)? {
        guard case .review(let bookings, let index, _) = phase, bookings.count > 1 else {
            return nil
        }
        return (index + 1, bookings.count)
    }

    var segments: [Bool] {
        guard case .review(let bookings, _, let saved) = phase else { return [] }
        return bookings.map { saved.contains($0.id) }
    }

    var isLast: Bool {
        guard case .review(let bookings, let index, _) = phase else { return false }
        return index == bookings.count - 1
    }

    /// The office this booking will be filed under, or nil if the sheet has to
    /// ask. Never creates one.
    func matchedOffice(for booking: ParsedBooking) -> Office? {
        // Sorted, because a bare `FetchDescriptor` has no defined order and
        // every rule in `OfficeMatcher` is "exactly one, or nothing" — a rule
        // that has to look at all the candidates anyway should not have its
        // answer depend on which one SwiftData happened to hand back first.
        let offices = (try? context.fetch(
            FetchDescriptor<Office>(sortBy: [SortDescriptor(\.name)])
        )) ?? []
        let candidates = offices.map {
            OfficeMatcher.Candidate(
                id: $0.id, name: $0.name, postcode: $0.postcode, address: $0.address,
                aliases: $0.aliases
            )
        }
        guard let match = OfficeMatcher.match(booking.officeName, against: candidates) else {
            return nil
        }
        return offices.first { $0.id == match.id }
    }

    /// The booking already held for this office and day, if there is one.
    ///
    /// A second capture of the same day is a change rather than a duplicate, so
    /// nothing here is at risk of doubling the month — but the desk id would
    /// move without being asked about, and that is what the sheet uses this to
    /// name before it happens.
    func existingBooking(day: Day, officeID: UUID) -> DeskBooking? {
        (try? context.fetch(FetchDescriptor<DeskBooking>()))?
            .first { $0.officeID == officeID && $0.day == day }
    }

    /// Where the booking already held came from, in words: `entered by hand`,
    /// `read from an image on 4 August`, or nothing knowable.
    ///
    /// The clash dialog asks which of two desks to keep and used to withhold
    /// the one thing that decides it — which is newer, and where the old one
    /// came from.
    func provenance(of booking: DeskBooking) -> String? {
        guard booking.source == .capture else { return "entered by hand" }
        guard let captureID = booking.captureID,
              let capture = (try? context.fetch(FetchDescriptor<Capture>()))?
                  .first(where: { $0.id == captureID }) else {
            return "read from an image"
        }
        return "read from an image on \(Day(of: capture.receivedAt).dayAndMonth)"
    }

    /// Commits this booking and moves on. Each save writes immediately rather
    /// than batching, so abandoning the sheet halfway keeps what is already
    /// saved.
    ///
    /// `chosen` says the sheet asked about a clash and this is the answer, so
    /// the incoming booking wins whatever the stored one's source was.
    func save(_ booking: ParsedBooking, to officeID: UUID, chosen: Bool = false) {
        guard case .review(let bookings, let index, var saved) = phase else { return }
        // Asked before anything is written, because adding the alias first
        // would make the question look as though it had never been asked.
        if let printed = booking.officeName, matchedOffice(for: booking) == nil {
            remember(printed, as: officeID)
        }
        // Only a write that landed may be drawn as one. `try?` here meant a
        // failed save turned the segment green and advanced the sheet anyway:
        // the user watched three capsules fill, the sheet dismissed, and the
        // rows were gone at the next launch with nothing having said so. The
        // rest of the table is lost by failing here, which is the price of
        // being told at all — and the sheet's remaining choice, entering it by
        // hand, is the right one when the store has just refused a write.
        do {
            try writeBooking(
                BookingMerge.Candidate(
                    officeID: officeID,
                    day: booking.day,
                    deskID: booking.deskID,
                    floor: booking.floor,
                    zone: booking.zone,
                    startTime: booking.startTime,
                    endTime: booking.endTime,
                    source: .capture,
                    unsureFields: booking.unsureFields
                ),
                captureID,
                chosen
            )
        } catch {
            // Through `failed`, which also clears `lastInput`: retrying reruns
            // the model call, not the save, so the one button that could not
            // possibly help is hidden.
            failed(.couldNotSave(error.localizedDescription))
            return
        }
        saved.insert(booking.id)
        phase = .review(bookings: bookings, index: index, saved: saved)
        advance()
    }

    /// The sheet asked which office this printed name meant and was told. Next
    /// capture it will not ask.
    ///
    /// Taken off every other office on the way, because a building name means
    /// one building: leaving it on two would make both claim it, which the
    /// matcher reads as ambiguous and answers by asking again — the very thing
    /// this exists to stop. The newest answer is the one that stands.
    private func remember(_ printed: String, as officeID: UUID) {
        let offices = (try? context.fetch(FetchDescriptor<Office>())) ?? []
        guard let target = offices.first(where: { $0.id == officeID }) else { return }

        for office in offices where office.id != officeID {
            office.aliases.removeAll { OfficeMatcher.matches(printed, $0) }
        }
        if !target.aliases.contains(where: { OfficeMatcher.matches(printed, $0) }) {
            target.aliases.append(printed)
        }
        // Not the booking, so not the error screen. The strip above and the
        // append are both pending on the context the booking is about to be
        // written through, so a save that fails here is usually flushed by that
        // one anyway — and when it is not, the booking's failure is the sentence
        // worth reading.
        write(.officeName(printed, officeID: target.id))
    }

    /// Skip is a save that writes nothing. From here the two are the same
    /// event: this booking is done with, show what is behind it.
    func advance() {
        guard case .review(let bookings, let index, let saved) = phase else { return }
        if index + 1 < bookings.count {
            phase = .review(bookings: bookings, index: index + 1, saved: saved)
        } else {
            phase = .idle
        }
    }

    func abort() {
        // Anything still in flight belongs to a run the user has walked away
        // from, and stays where it is when it wakes.
        generation += 1
        phase = .idle
        lastInput = nil
        captureID = nil
    }

    // MARK: The capture record

    /// A monthly call count and cost, without instrumenting anything else.
    ///
    /// It used to keep the image too, for a "view original screenshot" screen.
    /// That screen was never built — there is no reader of `Capture.asset`
    /// anywhere in the app — so what it actually did was retain a photograph of
    /// the user's employer's booking system, floors, desk ids and colleagues'
    /// rows and all, in the container and therefore in every iCloud backup, for
    /// the life of the install and with no way to view or remove one. A failed
    /// capture kept its image as well, so an accidentally-shared photo of
    /// something else entirely was kept forever too. Keeping bytes nobody can
    /// read is a privacy cost with no matching benefit; the four fields below
    /// are the ones Settings actually shows. If the original is ever wanted
    /// back, it needs a reader, a bound and a line of copy saying it is kept —
    /// not a silent write.
    @discardableResult
    private func record(status: CaptureStatus, usage: HaikuClient.Usage?) -> UUID {
        let capture = Capture(
            receivedAt: .now,
            asset: nil,
            status: status,
            inputTokens: usage?.inputTokens ?? 0,
            outputTokens: usage?.outputTokens ?? 0
        )
        context.insert(capture)
        // Read off the row rather than off the arguments, so an aside cannot
        // claim a cost the record does not hold: the whole worth of the payload
        // is that a test can hold this to the tokens actually written down.
        //
        // Not raised to the user for the reason `write(_:)` gives, and here the
        // case is starker still — two of the three callers are already on their
        // way to an error screen the user has to read and act on, and replacing
        // "the network request failed" with a complaint about bookkeeping would
        // be answering the wrong question at the worst moment.
        write(.captureCost(
            id: capture.id,
            status: capture.status,
            inputTokens: capture.inputTokens,
            outputTokens: capture.outputTokens
        ))
        return capture.id
    }
}
