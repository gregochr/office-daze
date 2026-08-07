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

    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    var isActive: Bool {
        if case .idle = phase { return false }
        return true
    }

    // MARK: Intake

    /// iOS copied the shared file into our inbox and launched us. This is the
    /// whole share-sheet path, in place of an extension.
    func receive(url: URL) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        guard let data = try? Data(contentsOf: url) else {
            phase = .failed(.unsupportedFile((url.pathExtension.isEmpty ? "file" : url.pathExtension)))
            return
        }
        await receive(data: data, filename: url.lastPathComponent)
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
        phase = .parsing(step: .received)
        do {
            let prepared = try await Task.detached { try PhotoImport.prepare(data) }.value
            lastInput = (prepared.data, prepared.mediaType)
            await run()
        } catch {
            // A PDF says so by name. Bytes with no name behind them can only
            // say they were not an image.
            phase = .failed(ext.map { CaptureError.unsupportedFile($0) } ?? .unreadableImage)
        }
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
            phase = .parsing(step: .matching)

            captureID = record(asset: data, status: .parsed, usage: usage)
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
            record(asset: data, status: .failed, usage: nil)
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
        let offices = (try? context.fetch(FetchDescriptor<Office>())) ?? []
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
        try? BookingStore.upsert(
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
            captureID: captureID,
            chosen: chosen,
            in: context
        )
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
        try? context.save()
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

    /// Keeps the original so "view original screenshot" works, and gives a
    /// monthly call count and cost without instrumenting anything else.
    @discardableResult
    private func record(
        asset: Data, status: CaptureStatus, usage: HaikuClient.Usage?
    ) -> UUID {
        let capture = Capture(
            receivedAt: .now,
            asset: asset,
            status: status,
            inputTokens: usage?.inputTokens ?? 0,
            outputTokens: usage?.outputTokens ?? 0
        )
        context.insert(capture)
        try? context.save()
        return capture.id
    }
}
