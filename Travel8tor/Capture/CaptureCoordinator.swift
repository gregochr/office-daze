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

    enum Phase: Equatable {
        case idle
        /// The design's `INTAKE ▪ PARSED 1.2s` state, roughly 1–2 seconds.
        case parsing(filename: String)
        case review(ParsedBooking, elapsed: TimeInterval, captureID: UUID)
        /// Never a silent drop — a failure always offers manual entry.
        case failed(CaptureError, filename: String)
    }

    var phase: Phase = .idle

    /// Swapped out in tests so no network call is made.
    var extractor: (CaptureInput) async throws -> (ParsedBooking, HaikuClient.Usage) = { input in
        guard let key = Keychain.get(.anthropicAPIKey), !key.isEmpty else {
            throw CaptureError.noAPIKey
        }
        return try await HaikuClient(apiKey: key).extract(input)
    }

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
                phase = .review(parsed, elapsed: Date().timeIntervalSince(started), captureID: capture)
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
            let (parsed, usage) = try await extractor(input)
            let capture = record(
                inputType: input.inputType, asset: data,
                model: HaikuClient.model, usage: usage, status: .parsed
            )
            phase = .review(parsed, elapsed: Date().timeIntervalSince(started), captureID: capture)
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

    // MARK: Committing

    /// Writes the booking, applying dedupe and re-running the grouping rule.
    /// Returns the id of the booking that now holds this data — which may be an
    /// existing one, if the capture merged into it.
    @discardableResult
    func commit(_ parsed: ParsedBooking, captureID: UUID?) throws -> UUID {
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

    func abort() {
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
