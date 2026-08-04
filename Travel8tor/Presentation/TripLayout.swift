import Foundation

/// Lays a trip and its child out as one column.
///
/// The ordering is by instant, not by day. The Brussels leg opens on the
/// evening of a Monday the parent already occupies — the 06:40 LNER and the
/// 10:00 desk come first, and only then does the 17:04 Eurostar leave.
/// Comparing days would hoist the whole child block above them.
///
/// Extracted from the view because it is the part that can be wrong in a way a
/// screenshot only sometimes reveals.
@MainActor
enum TripLayout {

    enum Block: Identifiable {
        case day(Day, [Booking])
        case child(Trip, [(day: Day, bookings: [Booking])])

        var id: String {
            switch self {
            case .day(let day, _): "day-\(day)"
            case .child(let trip, _): "child-\(trip.id)"
            }
        }
    }

    static func blocks(
        for trip: Trip,
        child: Trip?,
        bookings: [Booking]
    ) -> [Block] {
        var parentDays = groupByDay(bookings.filter { $0.tripID == trip.id })

        guard let child else {
            return parentDays.map { Block.day($0.day, $0.bookings) }
        }

        let childBookings = bookings.filter { $0.tripID == child.id }
        let childDays = fillGaps(
            groupByDay(childBookings), from: child.startsOn, to: child.endsOn
        )

        guard let childStart = childBookings.map(\.startsAt).min() else {
            return parentDays.map { Block.day($0.day, $0.bookings) }
        }

        var out: [Block] = []
        var inserted = false
        while !parentDays.isEmpty {
            let next = parentDays.removeFirst()
            let earliest = next.bookings.map(\.startsAt).min() ?? next.day.startOfDayUTC
            if !inserted && earliest > childStart {
                out.append(.child(child, childDays))
                inserted = true
            }
            out.append(.day(next.day, next.bookings))
        }
        if !inserted { out.append(.child(child, childDays)) }
        return out
    }

    static func groupByDay(_ bookings: [Booking]) -> [(day: Day, bookings: [Booking])] {
        var out: [(day: Day, bookings: [Booking])] = []
        for booking in bookings.sorted(by: { $0.startsAt < $1.startsAt }) {
            if let last = out.last, last.day == booking.anchorDay {
                out[out.count - 1].bookings.append(booking)
            } else {
                out.append((booking.anchorDay, [booking]))
            }
        }
        return out
    }

    /// Days inside the child's span with nothing booked still get a row — they
    /// are days you were there, which is worth showing as `ON SITE ▪ NO
    /// BOOKINGS` rather than as a gap.
    static func fillGaps(
        _ days: [(day: Day, bookings: [Booking])], from start: Day, to end: Day?
    ) -> [(day: Day, bookings: [Booking])] {
        guard let end else { return days }
        let booked = Dictionary(uniqueKeysWithValues: days.map { ($0.day, $0.bookings) })
        var out: [(day: Day, bookings: [Booking])] = []
        var day = start
        while day <= end {
            out.append((day, booked[day] ?? []))
            day = day.adding(days: 1)
        }
        return out
    }
}
