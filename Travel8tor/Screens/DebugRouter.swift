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
            case "offices":
                OfficesScreen()
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
            case "settings":
                SettingsScreen()
            default:
                HomeScreen()
            }
        }
        // `-capture table|one|slow|failed` drives the real capture flow with a
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
            await capture.receive(data: Data("screenshot".utf8), filename: "week.png")
        }
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
