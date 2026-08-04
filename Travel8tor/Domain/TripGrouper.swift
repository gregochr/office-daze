import Foundation

/// Applies `TripGrouping.classify` to a run of bookings, building the trip tree
/// as it goes. This is what the seed data uses — so the September nesting is
/// *produced* by the rule rather than hard-coded beside it, and a test that
/// checks the seed is also a test of the rule.
nonisolated enum TripGrouper {

    struct Assignment: Hashable, Sendable {
        let bookingID: UUID
        let tripID: UUID?
    }

    struct Result: Sendable {
        var trips: [TripShape]
        var assignments: [Assignment]

        func tripID(of bookingID: UUID) -> UUID? {
            assignments.first { $0.bookingID == bookingID }?.tripID
        }

        func trip(_ id: UUID?) -> TripShape? {
            guard let id else { return nil }
            return trips.first { $0.id == id }
        }
    }

    /// Bookings are processed in the order given — the document says "run on
    /// every new booking, in order". Chronological order is what the seed uses.
    ///
    /// `newID` is injected rather than calling `UUID()` inline so tests can make
    /// the output deterministic. Passing a function as a parameter is the usual
    /// Swift substitute for a Java interface with one method.
    static func group(
        bookings: [(id: UUID, shape: BookingShape)],
        homeCity: String,
        newID: () -> UUID = { UUID() }
    ) -> Result {
        var trips: [TripShape] = []
        var assignments: [Assignment] = []

        for booking in bookings {
            let outcome = TripGrouping.classify(
                booking.shape, among: trips, homeCity: homeCity
            )

            switch outcome {
            case .attach(let tripID):
                assignments.append(.init(bookingID: booking.id, tripID: tripID))

            case .attachAndClose(let tripID, let day):
                if let index = trips.firstIndex(where: { $0.id == tripID }) {
                    trips[index].endsOn = day
                }
                assignments.append(.init(bookingID: booking.id, tripID: tripID))

            case .openRootTrip(let city, let startsOn):
                let trip = TripShape(
                    id: newID(), primaryCity: city,
                    startsOn: startsOn, endsOn: nil, parentID: nil
                )
                trips.append(trip)
                assignments.append(.init(bookingID: booking.id, tripID: trip.id))

            case .openChildTrip(let parentID, let city, let startsOn):
                let trip = TripShape(
                    id: newID(), primaryCity: city,
                    startsOn: startsOn, endsOn: nil, parentID: parentID
                )
                trips.append(trip)
                assignments.append(.init(bookingID: booking.id, tripID: trip.id))

            case .unattached:
                assignments.append(.init(bookingID: booking.id, tripID: nil))
            }
        }

        return Result(trips: trips, assignments: assignments)
    }

    /// Rule 4: label from primaryCity and span. The document's own examples are
    /// "London week" and "Brussels leg"; a top-level trip is a week, a nested
    /// one is a leg.
    static func label(city: String, isChild: Bool) -> String {
        "\(city) \(isChild ? "leg" : "week")"
    }
}
