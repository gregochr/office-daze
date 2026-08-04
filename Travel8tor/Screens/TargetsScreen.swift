import SwiftData
import SwiftUI

/// The root. Chronological list, nearest first, plus the month's gauge.
struct TargetsScreen: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Booking.startsAt) private var bookings: [Booking]
    @Query(sort: \Trip.startsOnDate) private var trips: [Trip]

    private let copy = Copy.shared
    private let today = Day.today

    var body: some View {
        ScreenBackground {
            VStack(alignment: .leading, spacing: 0) {
                header
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        gaugePanel
                        list
                    }
                    .padding(.bottom, 26)
                }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("T8 ▪ ATTENDANCE PROTOCOL")
                    .t8(.appTitle)
                    .foregroundStyle(Palette.rail)
                Spacer()
                // Capture is stage 4; the affordance is here so the header is
                // the real one rather than a placeholder that has to move.
                Text("+")
                    .font(.custom(T8Fonts.regular, size: 20))
                    .foregroundStyle(Palette.bone.opacity(0.6))
            }
            .padding(.bottom, 10)
            HUDRule()
        }
        .padding(.horizontal, Metrics.headerPadding)
        .padding(.top, Metrics.headerTopInset)
    }

    // MARK: Gauge

    private var snapshot: QuotaService.Snapshot? {
        try? QuotaService.snapshot(for: today.month_, today: today, in: context)
    }

    @ViewBuilder
    private var gaugePanel: some View {
        if let snapshot {
            let result = snapshot.result
            NavigationLink(value: Route.mission) {
                HUDPanel(ticks: true) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("\(copy(.killCount)) ▪ \(snapshot.month.name)")
                            .t8(.kicker)
                            .foregroundStyle(Palette.railKicker)

                        HStack(spacing: 20) {
                            GaugeRing(
                                attended: result.attended,
                                forecast: result.forecast,
                                target: result.target
                            )
                            VStack(spacing: 9) {
                                ReadoutRow(
                                    label: copy(.terminated),
                                    figure: figure(result.attended),
                                    figureColour: Palette.desk
                                )
                                ReadoutRow(
                                    label: copy(.forecast),
                                    figure: figure(result.forecast),
                                    figureColour: Palette.desk.opacity(0.55)
                                )
                                ReadoutRow(
                                    label: "TARGET",
                                    figure: String(format: "%02d", result.target),
                                    divider: true
                                )
                            }
                        }
                        .padding(.top, 14)

                        FooterStrip(
                            leading: "\(figure(result.shortfall)) \(copy(.leftAlive))",
                            trailing: "\(String(format: "%02d", result.daysToRun)) DAYS TO RUN"
                        )
                        .padding(.top, 15)
                    }
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, Metrics.screenPadding)
            .padding(.top, Metrics.screenPadding)
        }
    }

    /// Half-days render as halves rather than being rounded away.
    private func figure(_ value: Double) -> String {
        value == value.rounded()
            ? String(format: "%02d", Int(value))
            : String(format: "%04.1f", value)
    }

    // MARK: List

    private var sections: [TargetsFeed.Section] {
        TargetsFeed.build(bookings: bookings, trips: trips, today: today, copy: copy.callAsFunction)
    }

    @ViewBuilder
    private var list: some View {
        let sections = sections
        if sections.isEmpty {
            emptyState
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                    SectionKicker(text: section.kicker)
                        .padding(.top, index == 0 ? 0 : 18)
                        .padding(.bottom, 11)

                    ForEach(section.rows) { row in
                        rowView(row)
                            .padding(.bottom, Metrics.dayGroupGap)
                    }
                }
            }
            .padding(.horizontal, Metrics.screenPadding)
            .padding(.top, 20)
        }
    }

    @ViewBuilder
    private func rowView(_ row: TargetsFeed.Row) -> some View {
        switch row {
        case .day(let day, let dayBookings):
            DayGutterRow(day: day) {
                ForEach(dayBookings) { booking in
                    if let presentation = BookingPresenter.present(booking, copy: copy.callAsFunction) {
                        NavigationLink(value: route(for: booking)) {
                            BookingCard(presentation)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        case .trip(let trip, let children):
            NavigationLink(value: Route.trip(trip.id)) {
                tripCard(trip, children: children)
            }
            .buttonStyle(.plain)
        }
    }

    private func tripCard(_ trip: Trip, children: [Trip]) -> some View {
        let tripBookings = TargetsFeed.bookings(inTripTree: trip, trips: trips, bookings: bookings)
        let segments = tripBookings.compactMap { booking -> TripSegment? in
            guard let detail = booking.detail else { return nil }
            let colour = Palette.colour(for: detail.kind)
            return TripSegment(
                TargetsFeed.segmentWeight(for: detail),
                booking.hasUnreadableFields ? colour.opacity(0.4) : colour
            )
        }

        let note = children.first.map { child in
            "\(copy(.subRoute)) ▪ \(child.primaryCity.uppercased()) "
                + TimeDisplay.span(child.startsOn, child.endsOn ?? child.startsOn)
        }

        return TripCard(
            title: trip.label.uppercased(),
            span: TimeDisplay.span(trip.startsOn, trip.endsOn ?? trip.startsOn),
            segments: segments,
            note: note
        )
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 9) {
            SectionKicker(text: "INBOUND")
            EmptyDayCard(text: "NO TARGETS ACQUIRED")
        }
        .padding(.horizontal, Metrics.screenPadding)
        .padding(.top, 20)
    }
}

extension BookingCard {
    /// Builds a card straight from a presentation, so screens don't repeat the
    /// eight-argument initialiser.
    init(_ presentation: BookingPresentation, compact: Bool = false) {
        self.init(
            kind: presentation.kind,
            typeCode: presentation.typeCode,
            figure: presentation.figure,
            figureSubtitle: presentation.figureSubtitle,
            title: presentation.title,
            metadata: presentation.metadata,
            flag: presentation.flag,
            incomplete: presentation.incomplete,
            emphasis: presentation.emphasis,
            compact: compact
        )
    }
}
