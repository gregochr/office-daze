import SwiftUI

/// The workhorse. A bordered rectangle in the booking's type colour, a 3pt
/// leading edge at full strength, a 0.05 fill of the same colour.
///
/// Colour is type; brightness is status. An incomplete booking is the one
/// exception, and it is not a status — it borrows the `desk` amber to say a
/// field could not be read, which is a different claim from "pending".
struct BookingCard: View {
    let kind: BookingKind
    /// `[RAIL] LNER`, `[DESK] TERMINATES 1`, `[STAY] 3 NIGHTS`
    let typeCode: String
    /// Departure time, desk id, check-in time.
    let figure: String
    /// The UK equivalent, where the event is abroad. Never the reverse.
    var figureSubtitle: String? = nil
    /// `DURHAM → KGX`, `ROPEMAKER PL`
    let title: String
    /// `PLAT 2`, `CCH B`, `SEAT 12`
    var metadata: [String] = []
    /// A footnote row, as on the incomplete stay: `DATA INCOMPLETE ▪ 02 FIELDS`.
    var flag: String? = nil
    var incomplete: Bool = false
    var emphasis: Emphasis = .full
    /// Cards shrink a step inside a nested child trip.
    var compact: Bool = false

    private var typeColour: Color { Palette.colour(for: kind) }

    private var borderColour: Color {
        incomplete ? Palette.desk.opacity(0.5) : typeColour.opacity(0.3)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(typeCode)
                    .t8(.typeCode)
                    .foregroundStyle(typeColour.status(emphasis))
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 1) {
                    Text(figure)
                        .t8(compact ? .readoutFigure : .rowFigure)
                        .foregroundStyle(incomplete ? Palette.desk : Palette.bone)
                        .monospacedDigit()
                    if let figureSubtitle {
                        Text(figureSubtitle)
                            .t8(.meta)
                            .foregroundStyle(Palette.desk.opacity(0.7))
                            .monospacedDigit()
                    }
                }
            }

            Text(title)
                .t8(.rowTitle)
                .foregroundStyle(Palette.bone.status(emphasis))
                .padding(.top, 6)

            if !metadata.isEmpty {
                HStack(spacing: Metrics.metaGap) {
                    ForEach(metadata, id: \.self) { item in
                        Text(item)
                    }
                }
                .t8(.meta)
                .foregroundStyle(Palette.boneMeta)
                .padding(.top, 8)
            }

            if let flag {
                Text(flag)
                    .t8(.typeCode)
                    .foregroundStyle(Palette.desk)
                    .padding(.top, 8)
            }
        }
        .padding(.vertical, compact ? Metrics.cardPaddingV - 2 : Metrics.cardPaddingV)
        .padding(.horizontal, compact ? Metrics.cardPaddingH - 2 : Metrics.cardPaddingH)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(typeColour.opacity(0.05))
        .overlay { Rectangle().strokeBorder(borderColour, lineWidth: Metrics.hairline) }
        // The leading type-edge, at full strength. Drawn as an overlay rather
        // than a border so it sits flush over the 1pt border beneath it.
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(typeColour)
                .frame(width: Metrics.typeEdge)
        }
    }
}

/// A day with nothing booked, inside a trip: a dashed box reading
/// `ON SITE ▪ NO BOOKINGS`. The only dashed border in the app.
struct EmptyDayCard: View {
    var text: String = "ON SITE ▪ NO BOOKINGS"

    var body: some View {
        Text(text)
            .t8(.typeCode)
            .foregroundStyle(Palette.rail.opacity(0.5))
            .padding(.vertical, Metrics.cardPaddingV)
            .padding(.horizontal, Metrics.cardPaddingH)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay {
                Rectangle().strokeBorder(
                    Palette.rail.opacity(0.22),
                    style: StrokeStyle(lineWidth: Metrics.hairline, dash: [3, 3])
                )
            }
    }
}

/// A 30–32pt right-aligned gutter carrying `WED` over `05`, beside a stack of
/// cards. The unit the whole Targets list is built from.
struct DayGutterRow<Content: View>: View {
    let day: Day
    var nested: Bool = false
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(alignment: .top, spacing: Metrics.gutterGap) {
            VStack(alignment: .trailing, spacing: 0) {
                Text(day.weekdayAbbreviation)
                    .t8(.gutterWeekday)
                    .foregroundStyle(Palette.boneTertiary)
                Text(String(format: "%02d", day.day))
                    .t8(.gutterDay)
                    .foregroundStyle(Palette.bone)
                    .monospacedDigit()
            }
            .frame(width: nested ? Metrics.gutterWidthNested : Metrics.gutterWidth, alignment: .trailing)
            .padding(.top, 2)

            VStack(alignment: .leading, spacing: Metrics.cardGap) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// The trip card on Targets: title, span, a flex-weighted segmented bar of the
/// booking types across the trip, and the nested-leg note.
nonisolated struct TripSegment: Identifiable {
    let id = UUID()
    let weight: CGFloat
    let colour: Color

    init(_ weight: CGFloat, _ colour: Color) {
        self.weight = weight
        self.colour = colour
    }
}

struct TripCard: View {
    let title: String
    let span: String
    /// Weight and colour per segment, in order across the trip.
    let segments: [TripSegment]
    var note: String? = nil

    var body: some View {
        HUDPanel(
            border: Palette.railBorderQuiet,
            padding: EdgeInsets(top: 13, leading: 12, bottom: 14, trailing: 12)
        ) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(title).t8(.tripTitle).foregroundStyle(Palette.bone)
                    Spacer(minLength: 0)
                    Text(span).t8(.tripSpan).foregroundStyle(Palette.bone.opacity(0.4))
                }

                // Flex weights, so a three-night stay reads five times as wide as
                // a train. SwiftUI has no flex-grow: `maxWidth: .infinity`
                // divides equally and `layoutPriority` is about who gets cut
                // first, not proportion. So the widths are computed.
                GeometryReader { geometry in
                    let total = segments.reduce(0) { $0 + $1.weight }
                    let gaps = CGFloat(max(0, segments.count - 1)) * 2
                    let available = max(0, geometry.size.width - gaps)
                    HStack(spacing: 2) {
                        ForEach(segments) { segment in
                            Rectangle()
                                .fill(segment.colour)
                                .frame(width: total > 0 ? available * segment.weight / total : 0)
                        }
                    }
                }
                .frame(height: 4)
                .padding(.top, 12)

                if let note {
                    Text(note)
                        .t8(.body)
                        .foregroundStyle(Palette.bone.opacity(0.6))
                        .padding(.vertical, 8)
                        .padding(.horizontal, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Palette.railFillQuiet)
                        .overlay(alignment: .leading) {
                            Rectangle().fill(Palette.rail).frame(width: Metrics.border)
                        }
                        .padding(.top, 11)
                }
            }
        }
    }
}
