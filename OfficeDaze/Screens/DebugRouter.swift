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
            switch ProcessInfo.processInfo.screenArgument {
            case "offices", "settings":
                SettingsScreen()
            case "office":
                OfficeEditorScreen(office: offices.first)
            case "booking":
                if let booking = bookings.first { BookingDetailScreen(booking: booking) }
            case "unread":
                // The booking whose zone the model could not read, so the
                // needs-checking marker can be looked at.
                if let booking = bookings.first(where: \.needsChecking) {
                    BookingDetailScreen(booking: booking)
                }
            case "add":
                BookingEditorScreen()
            case "alert":
                ArrivalPreviewScreen()
            case "leave":
                LeaveScreen(month: SeedData.month)
            case "gauge":
                GaugeStates()
            default:
                HomeScreen()
            }
        }
        // `-capture table|one|confirmation|page|slow|failed` drives the real capture flow with a
        // stubbed extractor, so the sheets can be looked at without a network
        // call or a share-sheet hand-off.
        .task {
            let which = ProcessInfo.processInfo.argument(after: "-capture")
            guard !which.isEmpty else { return }
            switch which {
            case "table":
                capture.extractor = { _, _, _ in (CaptureSamples.colemanWeek, CaptureSamples.usage) }
            case "one":
                capture.extractor = { _, _, _ in (CaptureSamples.one, CaptureSamples.usage) }
            case "confirmation":
                capture.extractor = { _, _, _ in
                    (CaptureSamples.confirmation, CaptureSamples.usage)
                }
            case "page":
                capture.extractor = { _, _, _ in
                    (CaptureSamples.reservationPage, CaptureSamples.usage)
                }
            case "slow":
                capture.extractor = { _, _, _ in
                    try? await Task.sleep(for: .seconds(30))
                    return (CaptureSamples.one, CaptureSamples.usage)
                }
            case "failed":
                capture.extractor = { _, _, _ in throw CaptureError.noAPIKey }
            default:
                return
            }
            await capture.receive(data: CaptureSamples.pixel, filename: "week.png")
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
    private let states: [(String, Double, Double, Int)] = [
        ("Can't reach it · 2 of 8", 2, 1, 8),
        ("On track · 3 of 6, two off for leave", 3, 3, 6),
        ("Target met · 6 of 6", 6, 0, 6),
        ("Over · 7 of 6", 7, 1, 6),
        ("All month off · 0 of 0", 0, 0, 0),
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: Metrics.cardGap) {
                ForEach(states, id: \.0) { title, attended, booked, target in
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
        guard let index = arguments.firstIndex(of: flag),
              index + 1 < arguments.count else { return "" }
        return arguments[index + 1]
    }
}
#endif
