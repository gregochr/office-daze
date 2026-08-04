import Foundation

/// Builds the Targets list: near-term bookings expanded day by day under
/// `▸ INBOUND`, everything further out collapsed into trip cards under a month
/// kicker.
///
/// That two-mode behaviour is what the mock shows and it isn't stated as a
/// rule anywhere, so it is defined here: a booking within `inboundHorizon`
/// days is something you need the platform number for; a trip five weeks out
/// is something you only need to know exists.
@MainActor
enum TargetsFeed {

    static let inboundHorizon = 14

    enum Row: Identifiable {
        case day(Day, [Booking])
        case trip(Trip, children: [Trip])

        var id: String {
            switch self {
            case .day(let day, _): "day-\(day)"
            case .trip(let trip, _): "trip-\(trip.id)"
            }
        }

        var sortDay: Day {
            switch self {
            case .day(let day, _): day
            case .trip(let trip, _): trip.startsOn
            }
        }
    }

    struct Section: Identifiable {
        let kicker: String
        let rows: [Row]
        var id: String { kicker }
    }

    static func build(
        bookings: [Booking],
        trips: [Trip],
        today: Day,
        copy: (T8Label) -> String = { $0.terminator }
    ) -> [Section] {
        let upcoming = bookings
            .filter { $0.anchorDay >= today }
            .sorted { $0.startsAt < $1.startsAt }

        let horizon = today.adding(days: inboundHorizon)
        let inbound = upcoming.filter { $0.anchorDay <= horizon }
        let later = upcoming.filter { $0.anchorDay > horizon }

        var sections: [Section] = []

        if !inbound.isEmpty {
            sections.append(Section(kicker: "INBOUND", rows: dayRows(inbound)))
        }
        sections.append(contentsOf: laterSections(later, trips: trips))
        return sections
    }

    /// Consecutive bookings on the same day collapse into one gutter row.
    private static func dayRows(_ bookings: [Booking]) -> [Row] {
        var rows: [Row] = []
        for booking in bookings {
            if case .day(let day, var existing) = rows.last, day == booking.anchorDay {
                existing.append(booking)
                rows[rows.count - 1] = .day(day, existing)
            } else {
                rows.append(.day(booking.anchorDay, [booking]))
            }
        }
        return rows
    }

    /// Beyond the horizon, a booking is represented by the top-level trip it
    /// belongs to — emitted once, on first encounter, so the trips come out in
    /// the order their first booking does. A booking with no trip still gets
    /// its own day row rather than disappearing.
    private static func laterSections(_ bookings: [Booking], trips: [Trip]) -> [Section] {
        let byID = Dictionary(uniqueKeysWithValues: trips.map { ($0.id, $0) })
        var emitted: Set<UUID> = []
        var rows: [Row] = []

        for booking in bookings {
            guard let tripID = booking.tripID, let trip = byID[tripID] else {
                if case .day(let day, var existing) = rows.last, day == booking.anchorDay {
                    existing.append(booking)
                    rows[rows.count - 1] = .day(day, existing)
                } else {
                    rows.append(.day(booking.anchorDay, [booking]))
                }
                continue
            }

            let root = rootTrip(of: trip, in: byID)
            guard emitted.insert(root.id).inserted else { continue }
            rows.append(.trip(root, children: children(of: root, in: trips)))
        }

        // Group into sections by the month each row falls in.
        var sections: [Section] = []
        for row in rows {
            let kicker = row.sortDay.monthName
            if let last = sections.last, last.kicker == kicker {
                sections[sections.count - 1] = Section(kicker: kicker, rows: last.rows + [row])
            } else {
                sections.append(Section(kicker: kicker, rows: [row]))
            }
        }
        return sections
    }

    static func rootTrip(of trip: Trip, in byID: [UUID: Trip]) -> Trip {
        var current = trip
        while let parentID = current.parentTripID, let parent = byID[parentID] {
            current = parent
        }
        return current
    }

    static func children(of trip: Trip, in trips: [Trip]) -> [Trip] {
        trips.filter { $0.parentTripID == trip.id }.sorted { $0.startsOn < $1.startsOn }
    }

    // MARK: Trip card content

    /// Flex weights for the segmented bar. A train is a couple of hours, a desk
    /// is a working day, a stay is its nights — so they read at roughly the
    /// proportions they occupy. These reproduce the mock's 1/2/1/5/1/2/2/1.
    static func segmentWeight(for detail: BookingDetail) -> CGFloat {
        switch detail {
        case .rail: 1
        case .desk: 2
        case .stay(let stay): CGFloat(stay.nights) * 1.5 + 0.5
        }
    }

    /// Bookings belonging to a trip or any of its children, in time order.
    static func bookings(inTripTree trip: Trip, trips: [Trip], bookings: [Booking]) -> [Booking] {
        let ids = Set([trip.id] + children(of: trip, in: trips).map(\.id))
        return bookings
            .filter { $0.tripID.map(ids.contains) ?? false }
            .sorted { $0.startsAt < $1.startsAt }
    }

    /// `07–11.09.26 ▪ 02 TERMINATIONS` — the count is desk bookings that count
    /// toward the quota, not the number of bookings.
    static func quotaDayCount(in bookings: [Booking]) -> Int {
        Set(
            bookings
                .filter { $0.detail?.deskDetail?.countsToQuota == true }
                .map(\.anchorDay)
        ).count
    }
}
