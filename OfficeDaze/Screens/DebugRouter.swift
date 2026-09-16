#if DEBUG
import SwiftData
import SwiftUI

/// `-screen offices|office|booking|add` opens straight onto one screen.
///
/// There is no way to drive taps in the simulator from a script, so without
/// this the only screens that can be looked at from the command line are the
/// ones the app happens to launch on. Debug builds only; it never ships.
struct DebugRouter: View {
    @Environment(CaptureCoordinator.self) private var capture
    @Query(sort: \Office.name) private var offices: [Office]
    @Query(sort: \DeskBooking.date) private var bookings: [DeskBooking]

    var body: some View {
        NavigationStack {
            switch Self.screen(for: ProcessInfo.processInfo.screenArgument) {
            case .settings:
                SettingsScreen()
            case .office:
                OfficeEditorScreen(office: offices.first)
            case .booking:
                if let booking = bookings.first { BookingDetailScreen(booking: booking) }
            case .unread:
                // The booking whose zone the reader could not read, so the
                // needs-checking marker can be looked at.
                if let booking = bookings.first(where: \.needsChecking) {
                    BookingDetailScreen(booking: booking)
                }
            case .add:
                BookingEditorScreen()
            case .alert:
                ArrivalPreviewScreen()
            case .leave:
                LeaveScreen(month: SeedData.month)
            case .gauge:
                GaugeStates()
            case .home:
                HomeScreen()
            }
        }
        // `-capture table|one|confirmation|page|slow|failed` drives the real capture flow with a
        // stubbed extractor, so the sheets can be looked at without a
        // photograph or a share-sheet hand-off.
        .task {
            let which = ProcessInfo.processInfo.argument(after: "-capture")
            guard let stub = Self.stub(for: which) else { return }
            capture.extractor = Self.extractor(for: stub)
            await capture.receive(data: CaptureSamples.pixel, filename: "week.png")
        }
    }

    /// Which screen `-screen <name>` names.
    ///
    /// A named case per screen rather than a switch over strings inside the
    /// body, because this table is what every screenshot script in the repo
    /// depends on: a name that quietly fell through to `home` would produce a
    /// perfectly good screenshot of the wrong screen, and nothing about the
    /// picture would say so.
    enum Screen: Equatable {
        case settings, office, booking, unread, add, alert, leave, gauge, home
    }

    static func screen(for argument: String) -> Screen {
        switch argument {
        // Two names for one screen: the settings screen is where the offices
        // are, and both are what it gets asked for.
        case "offices", "settings": .settings
        case "office": .office
        case "booking": .booking
        case "unread": .unread
        case "add": .add
        case "alert": .alert
        case "leave": .leave
        case "gauge": .gauge
        // Including the empty string, which is what no `-screen` at all looks
        // like — the app launching normally.
        default: .home
        }
    }

    /// Which canned extraction `-capture <name>` asks for. `nil` means leave
    /// the real extractor alone and open no sheet.
    enum Stub: Equatable {
        case table, one, confirmation, page, slow, failed
    }

    static func stub(for argument: String) -> Stub? {
        switch argument {
        case "table": .table
        case "one": .one
        case "confirmation": .confirmation
        case "page": .page
        case "slow": .slow
        case "failed": .failed
        default: nil
        }
    }

    /// The stand-in extractor, which is the whole point of the flag: the sheets
    /// can be looked at without a photograph or a share-sheet hand-off.
    static func extractor(for stub: Stub) -> (Data, Day) async throws -> [ParsedBooking] {
        switch stub {
        case .table:
            { _, _ in CaptureSamples.colemanWeek }
        case .one:
            { _, _ in CaptureSamples.one }
        case .confirmation:
            { _, _ in CaptureSamples.confirmation }
        case .page:
            { _, _ in CaptureSamples.reservationPage }
        case .slow:
            // Long enough to read the progress sheet, and to try cancelling it.
            { _, _ in
                try? await Task.sleep(for: .seconds(30))
                return CaptureSamples.one
            }
        case .failed:
            { _, _ in throw CaptureError.nothingUsable("no complete booking in the document") }
        }
    }
}

/// The slot row's states side by side, which is the only way to judge it: the
/// point of eight fixed slots is that two months are comparable, and a row can
/// only be compared with another one.
///
/// Put behind `-screen gauge` because a preview cannot be screenshotted from a
/// script, and the hatching and the half-day split are the fiddliest things in
/// the drawing.
struct GaugeStates: View {

    /// The states the page exists to put side by side.
    ///
    /// A named table rather than literals inside the body, because the value of
    /// this screen is entirely in the list being *complete*: drop the rows that
    /// hatch, or the half day, and the fiddliest parts of the drawing — the ones
    /// with no month in the sample data to exercise them — stop being looked
    /// at, while the page still renders perfectly good rows that say nothing is
    /// wrong. Targets eight and six share their days, so what leave does to the
    /// card is the only difference between them.
    static let states: [GaugeSample] = [
        GaugeSample(title: "Target 8 · 4 done, 2 booked", attended: 4, booked: 2, target: 8),
        GaugeSample(title: "Target 6 · the same days", attended: 4, booked: 2, target: 6),
        GaugeSample(title: "Target 4 · 2 done, 1 booked", attended: 2, booked: 1, target: 4),
        GaugeSample(title: "Over target · 7 of 6, into the hatching", attended: 7, booked: 0, target: 6),
        GaugeSample(title: "Nine done · capped at eight", attended: 9, booked: 0, target: 8),
        GaugeSample(title: "A half day · 4.5 done", attended: 4.5, booked: 2, target: 7),
        GaugeSample(title: "All month off · target 0", attended: 0, booked: 0, target: 0),
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: Metrics.cardGap) {
                ForEach(Self.states, id: \.title) { state in
                    Card(padding: EdgeInsets(top: 12, leading: 16, bottom: 16, trailing: 16)) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(state.title)
                                .font(.system(size: 13))
                                .foregroundStyle(Palette.secondary)
                            AttendanceGauge(
                                attended: state.attended, booked: state.booked, target: state.target
                            )
                        }
                    }
                }
            }
            .padding(Metrics.screenPadding)
        }
        .background(Palette.ground)
        .navigationTitle("Gauge")
        .navigationBarTitleDisplayMode(.inline)
    }
}

extension ProcessInfo {
    var screenArgument: String { argument(after: "-screen") }

    func argument(after flag: String) -> String {
        Self.argument(after: flag, in: arguments)
    }

    /// Takes the list rather than reading `arguments`, so the bounds can be
    /// tested: a `ProcessInfo` always answers with the arguments the test
    /// runner was launched with, and the case that matters is the one nobody
    /// launches deliberately — a flag typed last with its value left off, where
    /// `index + 1` is one past the end.
    static func argument(after flag: String, in arguments: [String]) -> String {
        guard let index = arguments.firstIndex(of: flag),
              index + 1 < arguments.count else { return "" }
        return arguments[index + 1]
    }
}
#endif
