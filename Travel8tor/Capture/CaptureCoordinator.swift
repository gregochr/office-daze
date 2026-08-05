import Foundation
import Observation
import SwiftData
import UniformTypeIdentifiers

/// What arrived, before we know what it is.
nonisolated struct CaptureInput: Sendable {
    enum Payload: Sendable {
        case image(Data, mediaType: String)
        case pdf(Data)
        case text(String)
    }

    var payload: Payload
    var filename: String
    var today: Day

    var inputType: CaptureInputType {
        switch payload {
        case .image: .image
        case .pdf: .pdf
        case .text: .text
        }
    }
}

/// Drives both capture paths and holds the state the confirm screen renders.
///
/// `@Observable` rather than a plain struct because this outlives a single view
/// — a capture starts when a file arrives at the app and finishes when the user
/// commits or aborts, across screens.
@MainActor
@Observable
final class CaptureCoordinator {

    /// Which booking of how many is on screen. `1 OF 1` for a single
    /// confirmation, `1 OF 3` for a table — the counter is what tells the user
    /// there is more behind this one.
    struct Position: Equatable, Sendable {
        /// One-based, because it is shown rather than indexed with.
        var number: Int
        var total: Int

        var isOnlyOne: Bool { total == 1 }
    }

    enum Phase: Equatable {
        case idle
        /// The design's `INTAKE ▪ PARSED 1.2s` state, roughly 1–2 seconds.
        case parsing(filename: String)
        case review(ParsedBooking, elapsed: TimeInterval, captureID: UUID, at: Position)
        /// Never a silent drop — a failure always offers manual entry.
        case failed(CaptureError, filename: String)
    }

    var phase: Phase = .idle

    /// Swapped out in tests so no network call is made.
    var extractor: (CaptureInput) async throws -> (CaptureBatch, HaikuClient.Usage) = { input in
        guard let key = Keychain.get(.anthropicAPIKey), !key.isEmpty else {
            throw CaptureError.noAPIKey
        }
        return try await HaikuClient(apiKey: key).extract(input)
    }

    /// The bookings from this capture still waiting to be reviewed, and what is
    /// needed to keep showing them. Held here rather than in the review screen
    /// so that the screen stays a pure function of `phase` — it renders what it
    /// is given and has no queue of its own to get out of step.
    private var queue: [ParsedBooking] = []
    private var reviewed = 0
    private var batchTotal = 0
    private var batchUnreadable: [CaptureError] = []
    private var batchElapsed: TimeInterval = 0
    private var batchCaptureID: UUID?
    private var batchFilename = ""

    /// Buildings created by the last commit and not yet located. Drained by
    /// `locateNewPlaces`, which the confirm screen calls once it has dismissed.
    private var newPlaces: [Place] = []

    /// Swapped in tests so nothing reaches Apple's geocoder — a test at the
    /// mercy of a network index is a test that fails on a train.
    var geocoder: @Sendable (String) async -> Geocode.Located? = Geocode.live

    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    // MARK: Entry points

    /// A file arrived from the share sheet. iOS copies it into the app's inbox
    /// and launches us; this is what `onOpenURL` calls.
    func receive(url: URL) async {
        // A security-scoped URL from another app must be opened before reading.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let filename = url.lastPathComponent
        phase = .parsing(filename: filename)

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            phase = .failed(.network(error.localizedDescription), filename: filename)
            return
        }

        await receive(data: data, filename: filename, type: UTType(filenameExtension: url.pathExtension))
    }

    func receive(data: Data, filename: String, type: UTType?) async {
        phase = .parsing(filename: filename)
        let started = Date()

        // Path A — a pass file. Free, exact, no model call.
        if type?.conforms(to: .init("com.apple.pkpass")!) == true
            || filename.lowercased().hasSuffix(".pkpass") {
            do {
                let parsed = try PassParser.parse(passFile: data)
                let capture = record(
                    inputType: .passFile, asset: data, model: nil, usage: nil, status: .parsed
                )
                // A pass is one booking by construction — one ticket, one file.
                begin(
                    CaptureBatch(parsed), elapsed: Date().timeIntervalSince(started),
                    captureID: capture, filename: filename
                )
            } catch let error as CaptureError {
                record(inputType: .passFile, asset: data, model: nil, usage: nil, status: .failed)
                phase = .failed(error, filename: filename)
            } catch {
                phase = .failed(.malformedPass(error.localizedDescription), filename: filename)
            }
            return
        }

        // Path B — one model call.
        let payload: CaptureInput.Payload
        if type?.conforms(to: .pdf) == true || filename.lowercased().hasSuffix(".pdf") {
            payload = .pdf(data)
        } else if let mediaType = Self.imageMediaType(type: type, filename: filename) {
            payload = .image(data, mediaType: mediaType)
        } else if let text = String(data: data, encoding: .utf8), !text.isEmpty {
            payload = .text(text)
        } else {
            let ext = (filename as NSString).pathExtension
            phase = .failed(.unsupportedFile(ext.isEmpty ? "file" : ext), filename: filename)
            return
        }

        let input = CaptureInput(payload: payload, filename: filename, today: .today)
        do {
            let (batch, usage) = try await extractor(input)
            let capture = record(
                inputType: input.inputType, asset: data,
                model: HaikuClient.model, usage: usage, status: .parsed
            )
            begin(
                batch, elapsed: Date().timeIntervalSince(started),
                captureID: capture, filename: filename
            )
        } catch let error as CaptureError {
            record(
                inputType: input.inputType, asset: data,
                model: HaikuClient.model, usage: nil, status: .failed
            )
            phase = .failed(error, filename: filename)
        } catch {
            phase = .failed(.network(error.localizedDescription), filename: filename)
        }
    }

    // MARK: The review queue

    /// Takes a capture's bookings and shows the first of them.
    private func begin(
        _ batch: CaptureBatch, elapsed: TimeInterval, captureID: UUID, filename: String
    ) {
        queue = batch.bookings
        reviewed = 0
        batchTotal = batch.bookings.count
        batchUnreadable = batch.unreadable
        batchElapsed = elapsed
        batchCaptureID = captureID
        batchFilename = filename
        advance()
    }

    /// Moves to the next booking in the capture, or ends it.
    ///
    /// Called after a commit and after a skip, because from here the two are
    /// the same event: this booking is done with, show what is behind it. What
    /// the user chose is the caller's business.
    func advance() {
        guard let next = queue.first, let captureID = batchCaptureID else {
            finish()
            return
        }
        queue.removeFirst()
        reviewed += 1
        phase = .review(
            next, elapsed: batchElapsed, captureID: captureID,
            at: Position(number: reviewed, total: batchTotal)
        )
    }

    /// The end of a capture. Rows the mapping could not read are reported here
    /// rather than at the start, so the readable ones are already committed by
    /// the time the failure appears and ENTER MANUALLY covers only what is
    /// actually missing.
    private func finish() {
        if let unreadable = batchUnreadable.first {
            phase = .failed(unreadable, filename: batchFilename)
        } else {
            phase = .idle
        }
        clearBatch()
    }

    private func clearBatch() {
        queue = []
        reviewed = 0
        batchTotal = 0
        batchUnreadable = []
        batchCaptureID = nil
    }

    // MARK: Committing

    /// Writes the booking, applying dedupe and re-running the grouping rule.
    /// Returns the id of the booking that now holds this data — which may be an
    /// existing one, if the capture merged into it.
    @discardableResult
    func commit(_ parsed: ParsedBooking, captureID: UUID?) throws -> UUID {
        var parsed = parsed

        // Which building this is, before dedupe runs — desk bookings match on
        // place and date, so a desk arriving with a freshly invented placeID
        // would never match the one already stored for the same day.
        if let desk = parsed.detail.deskDetail {
            let (resolved, created) = PlaceResolver.resolve(
                desk, address: parsed.placeAddress, in: context
            )
            parsed.detail = .desk(resolved)
            if let created {
                // Off the critical path: the commit must not wait on a network
                // round trip, and the building is usable without one.
                newPlaces.append(created)
            }
        }

        let existing = try context.fetch(FetchDescriptor<Booking>())
        let candidates = existing.compactMap { booking -> Dedupe.Candidate? in
            guard let detail = booking.detail else { return nil }
            return Dedupe.Candidate(
                id: booking.id, detail: detail,
                startsAt: booking.startsAt, startZoneID: booking.startZoneID,
                endsAt: booking.endsAt, endZoneID: booking.endZoneID,
                unsureFields: booking.unsureFields, provenance: booking.provenance
            )
        }

        let incoming = Dedupe.Candidate(
            id: UUID(), detail: parsed.detail,
            startsAt: parsed.startsAt, startZoneID: parsed.startZoneID,
            endsAt: parsed.endsAt, endZoneID: parsed.endZoneID,
            unsureFields: parsed.unsureFields, provenance: parsed.provenance
        )

        let bookingID: UUID
        switch Dedupe.classify(incoming, against: candidates) {
        case .insert:
            let booking = Booking(
                id: incoming.id,
                detail: parsed.detail,
                startsAt: parsed.startsAt,
                startZoneID: parsed.startZoneID,
                endsAt: parsed.endsAt,
                endZoneID: parsed.endZoneID,
                provenance: parsed.provenance,
                unsureFields: parsed.unsureFields,
                captureID: captureID
            )
            context.insert(booking)
            bookingID = booking.id

        case .merge(let into, let result):
            guard let booking = existing.first(where: { $0.id == into }) else { return into }
            booking.detail = result.detail
            booking.startsAt = result.startsAt
            booking.startZoneID = result.startZoneID
            booking.endsAt = result.endsAt
            booking.endZoneID = result.endZoneID
            booking.unsureFields = result.unsureFields
            booking.provenance = result.provenance
            if booking.captureID == nil { booking.captureID = captureID }
            bookingID = into
        }

        if let captureID,
           let capture = try context.fetch(FetchDescriptor<Capture>())
               .first(where: { $0.id == captureID }) {
            capture.bookingID = bookingID
        }

        try regroup()
        try context.save()
        return bookingID
    }

    /// Re-runs the grouping rule over every booking. The rule is order
    /// dependent and a captured booking can land in the middle of an existing
    /// trip, so regrouping wholesale is both simpler and more correct than
    /// trying to patch one booking into the existing tree.
    private func regroup() throws {
        let bookings = try context.fetch(
            FetchDescriptor<Booking>(sortBy: [SortDescriptor(\.startsAt)])
        )
        let shapes: [(id: UUID, shape: BookingShape)] = bookings.compactMap { booking in
            guard let shape = booking.shape else { return nil }
            return (booking.id, shape)
        }

        let result = TripGrouper.group(bookings: shapes, homeCity: SeedData.homeCity)

        for trip in try context.fetch(FetchDescriptor<Trip>()) { context.delete(trip) }
        for shape in result.trips {
            context.insert(Trip(
                id: shape.id,
                label: TripGrouper.label(city: shape.primaryCity, isChild: shape.parentID != nil),
                primaryCity: shape.primaryCity,
                startsOn: shape.startsOn,
                endsOn: shape.endsOn,
                parentTripID: shape.parentID
            ))
        }
        for booking in bookings {
            booking.tripID = result.tripID(of: booking.id)
        }
    }

    /// Geocodes any building the last commit invented, then saves. Separate
    /// from `commit` so the confirm screen can dismiss immediately: the booking
    /// is already written and the building is already listed; only its
    /// perimeter is pending.
    func locateNewPlaces() async {
        let pending = newPlaces
        newPlaces = []
        for place in pending {
            await PlaceResolver.locate(place, using: geocoder)
        }
        if !pending.isEmpty { try? context.save() }
    }

    /// ABORT drops the whole capture, not just the booking on screen. The rest
    /// of the table goes with it — the user asked to stop, and advancing to the
    /// next row instead would read as the button not working.
    func abort() {
        clearBatch()
        phase = .idle
    }

    // MARK: Capture record

    /// Keeps the original so "view original" works, and gives a monthly call
    /// count and cost without instrumenting anything else.
    @discardableResult
    private func record(
        inputType: CaptureInputType, asset: Data,
        model: String?, usage: HaikuClient.Usage?, status: CaptureStatus
    ) -> UUID {
        let capture = Capture(
            receivedAt: .now,
            inputType: inputType,
            asset: asset,
            status: status,
            model: model,
            inputTokens: usage?.inputTokens ?? 0,
            outputTokens: usage?.outputTokens ?? 0
        )
        context.insert(capture)
        try? context.save()
        return capture.id
    }

    static func imageMediaType(type: UTType?, filename: String) -> String? {
        if let type {
            if type.conforms(to: .png) { return "image/png" }
            if type.conforms(to: .jpeg) { return "image/jpeg" }
            if type.conforms(to: .gif) { return "image/gif" }
            if type.conforms(to: .webP) { return "image/webp" }
            if type.conforms(to: .heic) || type.conforms(to: .heif) { return "image/jpeg" }
        }
        switch (filename as NSString).pathExtension.lowercased() {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        default: return nil
        }
    }
}
