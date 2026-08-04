import SwiftData
import SwiftUI

@main
struct Travel8torApp: App {
    /// `try!` is deliberate and temporary. If the store cannot open there is no
    /// app, and a placeholder failure screen is stage 3's problem, not stage 1's.
    private let container: ModelContainer = try! Store.makeContainer()

    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .modelContainer(container)
    }
}

/// Stage 1 has no design system and no screens — that is stage 2 and 3. This
/// exists so the app launches and the seeded model can be eyeballed on a
/// simulator without waiting for the UI.
struct StageOneReadout: View {
    @Query(sort: \Trip.startsOnDate) private var trips: [Trip]
    @Query(sort: \Booking.startsAt) private var bookings: [Booking]

    var body: some View {
        List {
            ForEach(trips) { trip in
                Section("\(trip.label)  \(trip.startsOn) – \(trip.endsOn.map(\.description) ?? "open")") {
                    if let parentID = trip.parentTripID,
                       let parent = trips.first(where: { $0.id == parentID }) {
                        Text("child of \(parent.label)").font(.caption)
                    }
                    ForEach(bookings.filter { $0.tripID == trip.id }) { booking in
                        VStack(alignment: .leading) {
                            Text("\(booking.kind.rawValue.uppercased())  \(booking.anchorDay.description)")
                                .font(.caption.bold())
                            if booking.hasUnreadableFields {
                                Text("unsure: \(booking.unsureFields.joined(separator: ", "))")
                                    .font(.caption2)
                            }
                        }
                    }
                }
            }
        }
        .monospaced()
    }
}
