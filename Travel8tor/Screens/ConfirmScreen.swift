import SwiftData
import SwiftUI

/// Screen 5c — full review, every field with per-field confidence, unreadable
/// ones outlined amber.
///
/// Built as a full screen rather than the bottom sheet the mock shows: with no
/// share extension the app is launched *by* the share, so there is no host app
/// to sit over. The internal layout is unchanged.
struct ConfirmScreen: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    let coordinator: CaptureCoordinator
    @State private var manual = false
    private let copy = Copy.shared

    var body: some View {
        ScreenBackground(raised: true) {
            VStack(spacing: 0) {
                switch coordinator.phase {
                case .idle:
                    Color.clear
                case .parsing(let filename):
                    parsing(filename)
                case .review(let parsed, let elapsed, let captureID, let position):
                    review(parsed, elapsed: elapsed, captureID: captureID, at: position)
                case .failed(let error, let filename):
                    failure(error, filename: filename)
                }
            }
        }
        #if DEBUG
        // `-capture failed -tap manual`. The transition out of a failure is the
        // one thing on this screen a launch argument could not otherwise reach.
        .task {
            let arguments = ProcessInfo.processInfo.arguments
            if let index = arguments.firstIndex(of: "-tap"), index + 1 < arguments.count,
               arguments[index + 1] == "manual",
               case .failed = coordinator.phase {
                manual = true
            }
        }
        #endif
        .fullScreenCover(isPresented: $manual) {
            ManualEntryScreen(coordinator: coordinator) {
                // The typed booking is written; the failed parse underneath has
                // nothing left to say.
                coordinator.abort()
                dismiss()
            }
        }
    }

    // MARK: Parsing

    private func parsing(_ filename: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            header(title: "INTAKE", trailingTitle: nil, trailingAction: nil)
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 9) {
                    Rectangle().fill(Palette.rail).frame(width: 7, height: 7)
                    Text("READING \(filename.uppercased())")
                        .t8(.panelLabel)
                        .foregroundStyle(Palette.rail)
                }
                ProgressView()
                    .progressViewStyle(.linear)
                    .tint(Palette.rail)
            }
            .padding(.horizontal, Metrics.screenPadding)
            .padding(.top, 20)
            Spacer()
        }
    }

    // MARK: Review

    private func review(
        _ parsed: ParsedBooking, elapsed: TimeInterval, captureID: UUID,
        at position: CaptureCoordinator.Position
    ) -> some View {
        VStack(spacing: 0) {
            header(
                title: "REVIEW ▪ \(parsed.kind.rawValue.uppercased())",
                trailingTitle: "COMMIT",
                trailingAction: { commit(parsed, captureID: captureID) }
            )

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    intakeStrip(parsed, elapsed: elapsed, at: position)
                    unreadableBanner(parsed)

                    VStack(spacing: 8) {
                        ForEach(ConfirmFields.fields(for: parsed), id: \.label) { field in
                            fieldRow(field)
                        }
                        attachRow(parsed)
                    }
                    .padding(.top, 16)

                    Text("ORIGINAL RETAINED ALONGSIDE RECORD.")
                        .t8(.provenanceSmall)
                        .foregroundStyle(Palette.bone.opacity(0.4))
                        .padding(.vertical, 11)
                        .padding(.horizontal, 13)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .overlay {
                            Rectangle().strokeBorder(
                                Palette.rail.opacity(0.2), lineWidth: Metrics.hairline
                            )
                        }
                        .padding(.top, 14)

                    // Only when there is something to move on to. A single
                    // booking has nothing behind it, and SKIP would then be a
                    // second, quieter ABORT.
                    if !position.isOnlyOne {
                        OutlinedAction(title: "SKIP THIS ONE") { advance() }
                            .padding(.top, 11)
                    }
                }
                .padding(.horizontal, Metrics.screenPadding)
                .padding(.top, 16)
                .padding(.bottom, 26)
            }
        }
    }

    /// `INTAKE ▪ PARSED 1.2s` with the cost chip — `1 CALL` on desk amber for a
    /// model call, `FREE` on stay cyan for a pass file. The distinction is the
    /// point: one path costs money and one doesn't.
    ///
    /// A capture holding several bookings adds `▪ 01 OF 03`, and shows the chip
    /// only on the first: one document was read once, however many bookings
    /// came out of it, and a chip on every one would read as three calls.
    private func intakeStrip(
        _ parsed: ParsedBooking, elapsed: TimeInterval, at position: CaptureCoordinator.Position
    ) -> some View {
        let counted = String(
            format: "%02d OF %02d", position.number, position.total
        )
        return HStack(spacing: 9) {
            Rectangle().fill(Palette.rail).frame(width: 7, height: 7)
            Text(
                String(format: "INTAKE ▪ PARSED %.1fs", elapsed)
                    + (position.isOnlyOne ? "" : " ▪ \(counted)")
            )
            .t8(.panelLabel)
            .foregroundStyle(Palette.rail)
            Spacer(minLength: 8)
            if position.number == 1 {
                Text(parsed.costedCall ? "1 CALL" : "FREE")
                    .t8(.typeCode)
                    .foregroundStyle(Palette.ground)
                    .padding(.vertical, 4)
                    .padding(.horizontal, 7)
                    .background(parsed.costedCall ? Palette.desk : Palette.stay)
            }
        }
    }

    @ViewBuilder
    private func unreadableBanner(_ parsed: ParsedBooking) -> some View {
        let total = ConfirmFields.fields(for: parsed).count
        let unreadable = parsed.unsureFields.count
        if unreadable > 0 {
            HStack(spacing: 9) {
                Rectangle().fill(Palette.desk).frame(width: 6, height: 6)
                Text("\(String(format: "%02d", unreadable)) OF \(String(format: "%02d", total)) FIELDS UNREADABLE")
                    .t8(.offline)
                    .foregroundStyle(Palette.desk)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 11)
            .padding(.horizontal, 13)
            .background(Palette.desk.opacity(0.08))
            .overlay { Rectangle().strokeBorder(Palette.desk, lineWidth: Metrics.hairline) }
            .padding(.top, 16)
        }
    }

    private func fieldRow(_ field: ConfirmFields.Field) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(field.label)
                    .t8(.cellLabel)
                    .foregroundStyle(field.unreadable ? Palette.desk : Palette.boneTertiary)
                Spacer(minLength: 8)
                if field.unreadable {
                    Text("UNREADABLE")
                        .t8(.unreadableTag)
                        .foregroundStyle(Palette.desk)
                }
            }
            Text(field.value)
                .t8(.fieldValueLarge)
                .foregroundStyle(field.unreadable ? Palette.bone.opacity(0.3) : Palette.bone)
                .padding(.top, 6)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(field.unreadable ? Palette.desk.opacity(0.06) : .clear)
        .overlay {
            Rectangle().strokeBorder(
                field.unreadable ? Palette.desk : Palette.rail.opacity(0.25),
                lineWidth: Metrics.hairline
            )
        }
    }

    /// `ATTACH TO` shows what the grouping rule will decide, before it decides
    /// it — so an obviously wrong grouping is visible at review rather than
    /// after the fact.
    private func attachRow(_ parsed: ParsedBooking) -> some View {
        let destination = (try? predictedTrip(parsed)) ?? nil
        return VStack(alignment: .leading, spacing: 0) {
            Text("ATTACH TO")
                .t8(.cellLabel)
                .foregroundStyle(Palette.boneTertiary)
            Text(destination ?? "NEW TRIP")
                .t8(.fieldValueLarge)
                .foregroundStyle(Palette.bone)
                .padding(.top, 6)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay {
            Rectangle().strokeBorder(Palette.rail.opacity(0.25), lineWidth: Metrics.hairline)
        }
    }

    private func predictedTrip(_ parsed: ParsedBooking) throws -> String? {
        let trips = try context.fetch(FetchDescriptor<Trip>())
        guard let shape = Booking(
            detail: parsed.detail, startsAt: parsed.startsAt,
            startZoneID: parsed.startZoneID, provenance: parsed.provenance
        ).shape else { return nil }

        let outcome = TripGrouping.classify(
            shape, among: trips.map(\.shape), homeCity: SeedData.homeCity
        )
        switch outcome {
        case .attach(let id), .attachAndClose(let id, _):
            guard let trip = trips.first(where: { $0.id == id }) else { return nil }
            return "\(trip.label.uppercased()) "
                + TimeDisplay.span(trip.startsOn, trip.endsOn ?? trip.startsOn)
        case .openRootTrip(let city, _):
            return "NEW ▪ \(city.uppercased()) WEEK"
        case .openChildTrip(_, let city, _):
            return "NEW ▪ \(copy(.subRoute)) \(city.uppercased())"
        case .unattached:
            return nil
        }
    }

    // MARK: Failure

    /// Never a silent drop: a failure says what went wrong and offers manual
    /// entry.
    private func failure(_ error: CaptureError, filename: String) -> some View {
        VStack(spacing: 0) {
            header(title: "INTAKE FAILED", trailingTitle: nil, trailingAction: nil)
            VStack(alignment: .leading, spacing: 0) {
                Text("⚠ COULD NOT READ \(filename.uppercased())")
                    .t8(.incompleteHeader)
                    .foregroundStyle(Palette.desk)
                Text(error.errorDescription ?? "UNKNOWN FAILURE")
                    .t8(.panelBody)
                    .foregroundStyle(Palette.bone.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)
            }
            .padding(15)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.desk.opacity(0.08))
            .overlay { Rectangle().strokeBorder(Palette.desk, lineWidth: Metrics.hairline) }
            .padding(.horizontal, Metrics.screenPadding)
            .padding(.top, 18)

            // Never a dead end: the file could not be read, so the booking gets
            // typed instead, and lands through the same commit.
            OutlinedAction(title: "ENTER MANUALLY") { manual = true }
                .padding(.horizontal, Metrics.screenPadding)
                .padding(.top, 11)

            Spacer()
        }
    }

    // MARK: Chrome

    private func header(
        title: String, trailingTitle: String?, trailingAction: (() -> Void)?
    ) -> some View {
        VStack(spacing: 0) {
            HStack {
                Button { coordinator.abort(); dismiss() } label: {
                    Text("ABORT")
                        .t8(.panelLabel)
                        .foregroundStyle(Palette.boneSecondary)
                }
                Spacer(minLength: 8)
                Text(title)
                    .t8(.back)
                    .foregroundStyle(Palette.rail)
                Spacer(minLength: 8)
                if let trailingTitle, let trailingAction {
                    Button(action: trailingAction) {
                        Text(trailingTitle)
                            .t8(.panelLabel)
                            .foregroundStyle(Palette.desk)
                    }
                } else {
                    Text("ABORT").t8(.panelLabel).foregroundStyle(.clear)
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, Metrics.headerPadding)
            .padding(.top, Metrics.headerTopInset)
            .padding(.bottom, 13)
            HUDRule()
        }
    }

    private func commit(_ parsed: ParsedBooking, captureID: UUID) {
        try? coordinator.commit(parsed, captureID: captureID)
        advance()
        // A new building's perimeter is a network round trip away. The booking
        // is already written, so the screen goes first and the geocode follows.
        Task { await coordinator.locateNewPlaces() }
    }

    /// This booking is done with, committed or skipped. A capture with more
    /// rows in it redraws with the next one; one with none left has nothing to
    /// show, unless a row failed to read — that failure is what the screen
    /// stays open for.
    private func advance() {
        coordinator.advance()
        if case .idle = coordinator.phase { dismiss() }
    }
}

/// The field list a booking shows at review, and which of them were unreadable.
/// Pulled out of the view so the mapping is testable — it is where a field can
/// silently go missing.
nonisolated enum ConfirmFields {

    struct Field: Hashable {
        let label: String
        let value: String
        let unreadable: Bool
    }

    static func fields(for parsed: ParsedBooking) -> [Field] {
        switch parsed.detail {
        case .rail(let rail): railFields(rail, parsed)
        case .desk(let desk): deskFields(desk, parsed)
        case .stay(let stay): stayFields(stay, parsed)
        }
    }

    private static func railFields(_ rail: RailDetail, _ parsed: ParsedBooking) -> [Field] {
        let zone = TimeZone(identifier: parsed.startZoneID) ?? TimeDisplay.uk
        return [
            field("OPERATOR", rail.operatorName.uppercased(), parsed, "operatorName"),
            field("FROM", rail.originStation.uppercased(), parsed, "originStation"),
            field("TO", rail.destStation.uppercased(), parsed, "destStation"),
            field("DEPARTS", TimeDisplay.inline(parsed.startsAt, in: zone), parsed, "departsAt"),
            field(
                "ARRIVES",
                parsed.endsAt.map {
                    TimeDisplay.inline($0, in: parsed.endZone ?? zone)
                } ?? BookingPresentation.unread,
                parsed, "arrival"
            ),
            field("PLATFORM", rail.platform, parsed, "platform"),
            field("COACH", rail.coach, parsed, "coach"),
            field("SEAT", rail.seat, parsed, "seat"),
            field("REF", rail.bookingRef, parsed, "bookingRef"),
        ]
    }

    private static func deskFields(_ desk: DeskDetail, _ parsed: ParsedBooking) -> [Field] {
        [
            field("BUILDING", desk.placeName.uppercased(), parsed, "placeName"),
            field("DESK", desk.deskID.uppercased(), parsed, "deskID"),
            field("DATE", TimeDisplay.dayStamp(Day(of: parsed.startsAt, in: parsed.startZone)), parsed, "date"),
            field("FLOOR", desk.floor, parsed, "floor"),
            field("HOURS", desk.hours, parsed, "hours"),
        ]
    }

    private static func stayFields(_ stay: StayDetail, _ parsed: ParsedBooking) -> [Field] {
        let zone = parsed.startZone
        return [
            field("HOTEL", stay.hotelName.uppercased(), parsed, "hotelName"),
            field("ADDRESS", stay.address?.uppercased(), parsed, "address"),
            // Deliberately not keyed on "checkIn". The night is known even
            // when the check-in *time* is not — it comes from check-out minus
            // the nights — so flagging it here would report a field as
            // unreadable that was in fact read.
            field("NIGHT OF", TimeDisplay.dayStamp(Day(of: parsed.startsAt, in: zone)), parsed, "nightOf"),
            field("NIGHTS", String(format: "%02d", stay.nights), parsed, "nights"),
            field(
                "CHECK-IN",
                stay.checkIn.map { TimeDisplay.local($0, in: zone) },
                parsed, "checkIn"
            ),
            field(
                "CHECK-OUT",
                stay.checkOut.map { TimeDisplay.local($0, in: zone) },
                parsed, "checkOut"
            ),
            field("REF", stay.bookingRef, parsed, "bookingRef"),
        ]
    }

    /// A field with no value renders the placeholder and the amber outline —
    /// never a blank, so an absence is always visible.
    private static func field(
        _ label: String, _ value: String?, _ parsed: ParsedBooking, _ key: String
    ) -> Field {
        let unread = value == nil || parsed.unsureFields.contains(key)
        return Field(
            label: label,
            value: unread ? (label.contains("CHECK") || label.contains("ARRIV")
                ? BookingPresentation.unread : "TAP TO ENTER") : value!,
            unreadable: unread
        )
    }
}

nonisolated extension ParsedBooking {
    var startZone: TimeZone { TimeZone(identifier: startZoneID) ?? TimeDisplay.uk }
    var endZone: TimeZone? { endZoneID.flatMap(TimeZone.init(identifier:)) }
}

nonisolated extension T8Font {
    static let unreadableTag = T8Font(9, bold: true, tracking: 0.10)
    static let fieldValueLarge = T8Font(12.5, bold: true)
    static let provenanceSmall = T8Font(9.5, tracking: 0.05, lineHeight: 1.6)
}
