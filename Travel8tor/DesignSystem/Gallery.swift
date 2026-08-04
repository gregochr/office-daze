import SwiftUI

/// Stage 2's deliverable made visible: every shared piece on one scrolling
/// screen, so the type, spacing and colour can be judged before any real screen
/// is built on top of them. Stage 3 replaces this as the root view.
struct Gallery: View {
    private let copy = Copy.shared

    var body: some View {
        ScreenBackground {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    typeScale
                    palette
                    panels
                    cards
                    dayGutter
                    tripCard
                    gauge
                }
                .padding(.horizontal, Metrics.screenPadding)
                .padding(.bottom, 40)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("T8 ▪ ATTENDANCE PROTOCOL")
                    .t8(.appTitle)
                    .foregroundStyle(Palette.rail)
                Spacer()
                Text("+")
                    .font(.custom(T8Fonts.regular, size: 20))
                    .foregroundStyle(Palette.bone.opacity(0.6))
            }
            .padding(.bottom, 10)
            HUDRule()
        }
        .padding(.top, Metrics.headerTopInset)
    }

    private var typeScale: some View {
        VStack(alignment: .leading, spacing: 9) {
            SectionKicker(text: "TYPE SCALE")
            specimen("KICKER 0.22EM", .kicker, Palette.railKicker)
            specimen("[RAIL] LNER", .typeCode, Palette.rail)
            specimen("DURHAM → KGX", .rowTitle, Palette.bone)
            specimen("PLAT 2   CCH B   SEAT 12", .meta, Palette.boneMeta)
            specimen("06:40", .rowFigure, Palette.bone)
            specimen("LONDON WEEK", .tripTitle, Palette.bone)
            HStack(spacing: 14) {
                Text("04").t8(.displayFigure).foregroundStyle(Palette.bone)
                Text("3C-114").t8(.heroFigure).foregroundStyle(Palette.desk)
            }
        }
    }

    private func specimen(_ text: String, _ style: T8Font, _ colour: Color) -> some View {
        Text(text).t8(style).foregroundStyle(colour)
    }

    private var palette: some View {
        VStack(alignment: .leading, spacing: 9) {
            SectionKicker(text: "COLOUR ▪ TYPE CARRIES HUE, STATUS CARRIES BRIGHTNESS")
            HStack(spacing: 2) {
                ForEach(
                    [
                        ("GROUND", Palette.ground), ("RAISED", Palette.groundRaised),
                        ("RAIL", Palette.rail), ("DESK", Palette.desk),
                        ("STAY", Palette.stay), ("BONE", Palette.bone),
                    ],
                    id: \.0
                ) { name, colour in
                    VStack(spacing: 0) {
                        Rectangle().fill(colour).frame(height: 34)
                        Text(name)
                            .t8(.gutterWeekday)
                            .foregroundStyle(Palette.boneTertiary)
                            .padding(.top, 4)
                    }
                    .overlay(alignment: .top) {
                        Rectangle()
                            .strokeBorder(Palette.rail.opacity(0.2), lineWidth: Metrics.hairline)
                            .frame(height: 34)
                    }
                }
            }
            HStack(spacing: 2) {
                ForEach([Emphasis.full, .pending, .inactive], id: \.rawValue) { emphasis in
                    Rectangle().fill(Palette.desk.status(emphasis)).frame(height: 18)
                }
            }
        }
    }

    private var panels: some View {
        VStack(alignment: .leading, spacing: 9) {
            SectionKicker(text: "PANEL ▪ CORNER TICKS")
            HUDPanel(ticks: true) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(copy(.killCount) + " ▪ AUGUST")
                        .t8(.kicker)
                        .foregroundStyle(Palette.railKicker)
                    Text("HARD RECTANGLES. NO RADIUS ANYWHERE.")
                        .t8(.body)
                        .foregroundStyle(Palette.boneSecondary)
                }
            }
            FooterStrip(leading: "03 " + copy(.leftAlive), trailing: "18 DAYS TO RUN")
        }
    }

    private var cards: some View {
        VStack(alignment: .leading, spacing: 9) {
            SectionKicker(text: "BOOKING CARDS")
            BookingCard(
                kind: .rail, typeCode: "[RAIL] LNER", figure: "06:40",
                title: "DURHAM → KGX", metadata: ["PLAT 2", "CCH B", "SEAT 12"]
            )
            BookingCard(
                kind: .desk, typeCode: "[DESK] TERMINATES 1", figure: "3C-114",
                title: "ROPEMAKER PL", metadata: ["L3", "ZONE C", "09–17"]
            )
            BookingCard(
                kind: .rail, typeCode: "[RAIL] EUROSTAR", figure: "20:05",
                figureSubtitle: "19:05 UK",
                title: "STP → MIDI", metadata: ["CCH 9", "SEAT 51"]
            )
            BookingCard(
                kind: .stay, typeCode: "[STAY] 1 NIGHT", figure: "??:??",
                title: "THE ROPEWALK",
                flag: "⚠ " + copy(.dataIncomplete) + " ▪ 02 FIELDS",
                incomplete: true
            )
            BookingCard(
                kind: .stay, typeCode: "[STAY] 3 NIGHTS", figure: "21:00",
                title: "HOTEL SABLON", metadata: ["RUE DE ROLLEBEEK 12"],
                emphasis: .pending
            )
            EmptyDayCard()
        }
    }

    private var dayGutter: some View {
        VStack(alignment: .leading, spacing: 9) {
            SectionKicker(text: "DAY GUTTER")
            DayGutterRow(day: Day(2026, 8, 5)) {
                BookingCard(
                    kind: .rail, typeCode: "[RAIL] LNER", figure: "06:40",
                    title: "DURHAM → KGX", metadata: ["PLAT 2", "CCH B", "SEAT 12"]
                )
                BookingCard(
                    kind: .desk, typeCode: "[DESK] TERMINATES 1", figure: "3C-114",
                    title: "ROPEMAKER PL", metadata: ["L3", "ZONE C", "09–17"]
                )
            }
            DayGutterRow(day: Day(2026, 8, 6), nested: true) {
                BookingCard(
                    kind: .rail, typeCode: "[RAIL] EUROSTAR", figure: "17:52",
                    figureSubtitle: "16:52 UK",
                    title: "MIDI → STP", compact: true
                )
            }
        }
    }

    private var tripCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            SectionKicker(text: "TRIP CARD")
            TripCard(
                title: "LONDON WEEK",
                span: "07–11.09",
                segments: [
                    TripSegment(1, Palette.rail), TripSegment(2, Palette.desk),
                    TripSegment(1, Palette.rail), TripSegment(5, Palette.stay),
                    TripSegment(1, Palette.rail), TripSegment(2, Palette.stay.opacity(0.4)),
                    TripSegment(2, Palette.desk), TripSegment(1, Palette.rail),
                ],
                note: copy(.subRoute) + " ▪ BRUSSELS 07–10.09"
            )
        }
    }

    private var gauge: some View {
        VStack(alignment: .leading, spacing: 9) {
            SectionKicker(text: "GAUGE")
            HUDPanel(ticks: true) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(copy(.killCount) + " ▪ AUGUST")
                        .t8(.kicker)
                        .foregroundStyle(Palette.railKicker)
                    HStack(spacing: 20) {
                        GaugeRing(attended: 2, forecast: 2, target: 7)
                        VStack(spacing: 9) {
                            ReadoutRow(label: copy(.terminated), figure: "02", figureColour: Palette.desk)
                            ReadoutRow(
                                label: copy(.forecast), figure: "02",
                                figureColour: Palette.desk.opacity(0.55)
                            )
                            ReadoutRow(label: "TARGET", figure: "07", divider: true)
                        }
                    }
                    .padding(.top, 14)

                    FooterStrip(leading: "03 " + copy(.leftAlive), trailing: "18 DAYS TO RUN")
                        .padding(.top, 15)
                }
            }
        }
    }
}

#Preview {
    Gallery()
}
