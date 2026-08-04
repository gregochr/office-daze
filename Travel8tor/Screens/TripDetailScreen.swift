import SwiftData
import SwiftUI

/// The nested-trip case. The parent's days run at full width; the child trip is
/// an indented block with its own gutter, and after it closes the parent's
/// remaining days continue at full width — which is what makes the Thursday
/// London hotel and the Friday desk read as belonging to the outer trip.
struct TripDetailScreen: View {
    let tripID: UUID

    @Query(sort: \Booking.startsAt) private var bookings: [Booking]
    @Query(sort: \Trip.startsOnDate) private var trips: [Trip]

    private let copy = Copy.shared

    private var trip: Trip? { trips.first { $0.id == tripID } }
    private var children: [Trip] { trip.map { TargetsFeed.children(of: $0, in: trips) } ?? [] }

    var body: some View {
        ScreenScaffold(backTitle: copy(.targets)) {
            if let trip {
                ScreenTitleBlock(
                    title: trip.label.uppercased(),
                    subtitle: subtitle(trip)
                )
            }
        } content: {
            if let trip {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(
                        TripLayout.blocks(
                            for: trip, child: children.first, bookings: bookings
                        )
                    ) { block in
                        blockView(block)
                    }
                }
            }
        }
    }

    private func subtitle(_ trip: Trip) -> String {
        let span = TimeDisplay.span(trip.startsOn, trip.endsOn ?? trip.startsOn)
        let year = String(format: "%02d", trip.startsOn.year % 100)
        let tree = TargetsFeed.bookings(inTripTree: trip, trips: trips, bookings: bookings)
        let count = TargetsFeed.quotaDayCount(in: tree)
        let word = copy.terminator ? "TERMINATIONS" : "OFFICE DAYS"
        return "\(span).\(year) ▪ \(String(format: "%02d", count)) \(word)"
    }

    // MARK: Views

    @ViewBuilder
    private func blockView(_ block: TripLayout.Block) -> some View {
        switch block {
        case .day(let day, let dayBookings):
            DayGutterRow(day: day) {
                cards(dayBookings, compact: false)
            }
            .padding(.bottom, 12)

        case .child(let child, let childDays):
            childBlock(child, days: childDays)
                .padding(.bottom, 12)
        }
    }

    private func childBlock(
        _ child: Trip, days: [(day: Day, bookings: [Booking])]
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("▸ \(copy(.subRoute)) ▪ \(child.primaryCity.uppercased())")
                    .t8(.subRouteHeader)
                    .foregroundStyle(Palette.rail)
                Spacer(minLength: 0)
                Text(nightCount(child))
                    .t8(.subRouteNights)
                    .foregroundStyle(Palette.bone.opacity(0.38))
            }
            .padding(.bottom, 12)

            ForEach(Array(days.enumerated()), id: \.offset) { index, entry in
                DayGutterRow(day: entry.day, nested: true) {
                    if entry.bookings.isEmpty {
                        EmptyDayCard()
                    } else {
                        cards(entry.bookings, compact: true)
                    }
                }
                .padding(.bottom, index == days.count - 1 ? 0 : 8)
            }
        }
        .padding(.vertical, 12)
        .padding(.leading, Metrics.nestedPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.railFillFaint)
        .overlay(alignment: .leading) {
            Rectangle().fill(Palette.rail).frame(width: Metrics.border)
        }
        .padding(.leading, Metrics.nestedInset)
    }

    private func nightCount(_ child: Trip) -> String {
        let nights = bookings
            .filter { $0.tripID == child.id }
            .compactMap { $0.detail?.stayDetail?.nights }
            .reduce(0, +)
        return nights == 1 ? "1 NIGHT" : "\(nights) NIGHTS"
    }

    @ViewBuilder
    private func cards(_ dayBookings: [Booking], compact: Bool) -> some View {
        ForEach(dayBookings) { booking in
            if let presentation = BookingPresenter.present(
                booking, copy: copy.callAsFunction, compact: compact
            ) {
                NavigationLink(value: route(for: booking)) {
                    BookingCard(presentation, compact: compact)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

nonisolated extension T8Font {
    static let subRouteHeader = T8Font(9.5, bold: true, tracking: 0.18)
    static let subRouteNights = T8Font(9.5)
}
