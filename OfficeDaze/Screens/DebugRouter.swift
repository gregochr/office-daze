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
                // The booking whose zone the model could not read, so the
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
        // stubbed extractor, so the sheets can be looked at without a network
        // call or a share-sheet hand-off.
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
    /// can be looked at without a network call, an API key, or a share-sheet
    /// hand-off.
    static func extractor(
        for stub: Stub
    ) -> (Data, String, Day) async throws -> ([ParsedBooking], HaikuClient.Usage) {
        switch stub {
        case .table:
            { _, _, _ in (CaptureSamples.colemanWeek, CaptureSamples.usage) }
        case .one:
            { _, _, _ in (CaptureSamples.one, CaptureSamples.usage) }
        case .confirmation:
            { _, _, _ in (CaptureSamples.confirmation, CaptureSamples.usage) }
        case .page:
            { _, _, _ in (CaptureSamples.reservationPage, CaptureSamples.usage) }
        case .slow:
            // Long enough to read the progress sheet, and to try cancelling it.
            { _, _, _ in
                try? await Task.sleep(for: .seconds(30))
                return (CaptureSamples.one, CaptureSamples.usage)
            }
        case .failed:
            { _, _, _ in throw CaptureError.noAPIKey }
        }
    }
}

/// The dial's states side by side, which is the only way to judge it: the
/// point of a fixed scale is that two months are comparable, and a scale can
/// only be compared with another one.
///
/// The same four the Xcode preview draws, put behind `-screen gauge` because a
/// preview cannot be screenshotted from a script and the hatching is the
/// fiddliest thing in the drawing.
struct GaugeStates: View {

    /// The states the page exists to put side by side.
    ///
    /// A named table rather than five literals inside the body, because the
    /// value of this screen is entirely in the list being *complete*: drop the
    /// over-target row and the hatching — the fiddliest thing in the drawing,
    /// and the only part with no month in the sample data to exercise it —
    /// stops being looked at, and the page still renders four perfectly good
    /// dials that say nothing is wrong.
    static let states: [(title: String, attended: Double, booked: Double, target: Int)] = [
        ("Can't reach it · 2 of 8", 2, 1, 8),
        ("On track · 3 of 6, two off for leave", 3, 3, 6),
        ("Target met · 6 of 6", 6, 0, 6),
        ("Over · 7 of 6", 7, 1, 6),
        ("All month off · 0 of 0", 0, 0, 0),
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: Metrics.cardGap) {
                ForEach(Self.states, id: \.title) { title, attended, booked, target in
                    Card(padding: EdgeInsets(top: 12, leading: 8, bottom: 12, trailing: 8)) {
                        VStack(spacing: 2) {
                            Text(title)
                                .font(.system(size: 13))
                                .foregroundStyle(Palette.secondary)
                            AttendanceGauge(
                                attended: attended, booked: booked, target: target
                            )
                        }
                        .frame(maxWidth: .infinity)
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
