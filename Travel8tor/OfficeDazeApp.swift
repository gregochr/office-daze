import SwiftData
import SwiftUI

@main
struct OfficeDazeApp: App {
    /// `try!` is deliberate and temporary. If the store cannot open there is no
    /// app, and a placeholder failure screen is a later stage's problem.
    private let container: ModelContainer

    init() {
        container = try! Store.makeContainer()
    }

    var body: some Scene {
        WindowGroup {
            StageOneView()
        }
        .modelContainer(container)
    }
}

/// Stage 1 has no UI by design — the maths is proved in tests before anything
/// is drawn. This view exists only so the app launches and the seeded store can
/// be seen to have opened. Home replaces it in stage 3.
private struct StageOneView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Office.name) private var offices: [Office]
    @Query(sort: \DeskBooking.date) private var bookings: [DeskBooking]

    var body: some View {
        NavigationStack {
            List {
                Section("Quota — August 2026") {
                    if let result = try? QuotaService.snapshot(
                        for: SeedData.month, today: Day(2026, 8, 4), in: context
                    ).result {
                        LabeledContent("Working days", value: "\(result.workingDays)")
                        LabeledContent("Leave", value: result.leaveTaken.formatted())
                        LabeledContent("Target", value: "\(result.target)")
                        LabeledContent("Attended", value: result.attended.formatted())
                        LabeledContent("Forecast", value: result.forecast.formatted())
                        LabeledContent("Shortfall", value: result.shortfall.formatted())
                    }
                }
                Section("Offices") {
                    ForEach(offices) { office in
                        LabeledContent(office.name, value: office.postcode)
                    }
                }
                Section("Bookings") {
                    ForEach(bookings) { booking in
                        LabeledContent(booking.day.mediumText, value: booking.deskID)
                    }
                }
            }
            .navigationTitle("Office Daze")
        }
    }
}
