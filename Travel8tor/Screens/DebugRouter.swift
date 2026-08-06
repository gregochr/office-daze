#if DEBUG
import SwiftData
import SwiftUI

/// `-screen offices|office|booking|add` opens straight onto one screen.
///
/// There is no way to drive taps in the simulator from a script, so without
/// this the only screens that can be looked at from the command line are the
/// ones the app happens to launch on. Debug builds only; it never ships.
struct DebugRouter: View {
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
            default:
                HomeScreen()
            }
        }
    }
}

extension ProcessInfo {
    var screenArgument: String {
        let arguments = self.arguments
        guard let index = arguments.firstIndex(of: "-screen"),
              index + 1 < arguments.count else { return "" }
        return arguments[index + 1]
    }
}
#endif
