import CoreLocation
import SwiftData
import SwiftUI

/// Screen 5e — the once-per-day rule made visible and adjustable.
///
/// The point of this screen is that the fire-once behaviour is not hidden. A
/// geofence that silently decides when to speak is a geofence people stop
/// trusting.
struct ArrivalSettingsScreen: View {
    @Environment(\.modelContext) private var context
    @Query private var places: [Place]

    @State private var settings = ArrivalSettings.shared
    @State private var authorization: CLAuthorizationStatus = .notDetermined

    private let copy = Copy.shared

    var body: some View {
        ScreenScaffold(backTitle: "CONFIG") {
            ScreenTitleBlock(title: copy(.arrivalTrigger))
        } content: {
            VStack(alignment: .leading, spacing: 0) {
                masterToggle
                authorizationPanel.padding(.top, 11)

                SectionKicker(text: "FIRE RATE")
                    .padding(.top, 20)
                    .padding(.bottom, 10)
                fireRatePanel

                SectionKicker(text: "PERIMETER")
                    .padding(.top, 20)
                    .padding(.bottom, 10)
                perimeterPanel

                invertedPromptPanel.padding(.top, 11)
            }
        }
        .task {
            authorization = CLLocationManager().authorizationStatus
        }
    }

    // MARK: Master toggle

    private var masterToggle: some View {
        Button { settings.enabled.toggle() } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("REPORT DESK ON ARRIVAL")
                        .t8(.rowAction)
                        .foregroundStyle(Palette.bone)
                    Text("ONLY ON DAYS WITH A BOOKING")
                        .t8(.rowActionNote)
                        .foregroundStyle(Palette.bone.opacity(0.4))
                }
                Spacer(minLength: 0)
                // A hard rectangle, like everything else — no rounded switch.
                HStack {
                    if settings.enabled { Spacer(minLength: 0) }
                    Rectangle()
                        .fill(settings.enabled ? Palette.ground : Palette.bone.opacity(0.3))
                        .frame(width: 18, height: 18)
                    if !settings.enabled { Spacer(minLength: 0) }
                }
                .padding(.horizontal, 3)
                .frame(width: 44, height: 24)
                .background(settings.enabled ? Palette.desk : Palette.bone.opacity(0.12))
            }
            .padding(.vertical, 14)
            .padding(.horizontal, 15)
            .overlay {
                Rectangle().strokeBorder(Palette.rail.opacity(0.25), lineWidth: Metrics.hairline)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: Authorisation

    /// Region monitoring in the background needs *Always*. The design doesn't
    /// show this panel, but without it a denied permission is invisible and the
    /// alert simply never fires — which reads as a bug rather than a setting.
    @ViewBuilder
    private var authorizationPanel: some View {
        let (title, note, colour) = authorizationState
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .t8(.incompleteHeader)
                .foregroundStyle(colour)
            Text(note)
                .t8(.panelBody)
                .foregroundStyle(Palette.bone.opacity(0.5))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 9)

            if authorization != .authorizedAlways {
                SolidAction(
                    title: authorization == .notDetermined ? "ASK FOR ACCESS" : "OPEN SETTINGS",
                    fill: Palette.desk
                ) {
                    if authorization == .notDetermined {
                        let monitor = ArrivalMonitor(ledger: ArrivalLedger(context: context))
                        // Both permissions are asked for here, together, at the
                        // point the feature is being switched on.
                        Task { await monitor.requestNotifications() }
                        monitor.requestAuthorization()
                    } else if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                .padding(.top, 12)
            }
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(colour.opacity(0.07))
        .overlay { Rectangle().strokeBorder(colour.opacity(0.45), lineWidth: Metrics.hairline) }
    }

    private var authorizationState: (String, String, Color) {
        switch authorization {
        case .authorizedAlways:
            (
                "LOCATION ▪ ALWAYS",
                "THE PERIMETER IS ARMED. ARRIVALS FIRE WITH THE APP CLOSED.",
                Palette.stay
            )
        case .authorizedWhenInUse:
            (
                "LOCATION ▪ WHEN IN USE",
                """
                ARRIVALS ONLY FIRE WITH THE APP OPEN. ALWAYS IS NEEDED FOR THE \
                PERIMETER TO WORK IN THE BACKGROUND.
                """,
                Palette.desk
            )
        case .denied, .restricted:
            (
                "LOCATION ▪ DENIED",
                "NO PERIMETER. GRANT ALWAYS IN SETTINGS TO ARM THE ARRIVAL TRIGGER.",
                Palette.rail
            )
        default:
            (
                "LOCATION ▪ NOT ASKED",
                """
                WHEN IN USE IS REQUESTED FIRST, THEN ALWAYS. ASKING FOR ALWAYS \
                COLD GETS DENIED.
                """,
                Palette.desk
            )
        }
    }

    // MARK: Fire rate

    private var fireRatePanel: some View {
        VStack(spacing: 0) {
            ForEach(Array(FireRate.allCases.enumerated()), id: \.element.rawValue) { index, rate in
                Button { settings.fireRate = rate } label: {
                    HStack(alignment: .top, spacing: 11) {
                        // A square radio, filled when chosen.
                        ZStack {
                            Rectangle()
                                .strokeBorder(
                                    settings.fireRate == rate
                                        ? Palette.desk : Palette.bone.opacity(0.25),
                                    lineWidth: Metrics.hairline
                                )
                            if settings.fireRate == rate {
                                Rectangle().fill(Palette.desk).frame(width: 8, height: 8)
                            }
                        }
                        .frame(width: 16, height: 16)
                        .padding(.top, 2)

                        VStack(alignment: .leading, spacing: 5) {
                            Text(rate.title)
                                .t8(.rowAction)
                                .foregroundStyle(
                                    settings.fireRate == rate
                                        ? Palette.bone : Palette.bone.opacity(0.75)
                                )
                            Text(rate.note)
                                .t8(.rowActionNote)
                                .foregroundStyle(Palette.bone.opacity(0.45))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 13)
                    .padding(.horizontal, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(settings.fireRate == rate ? Palette.desk.opacity(0.07) : .clear)
                    .overlay(alignment: .bottom) {
                        if index < FireRate.allCases.count - 1 {
                            Rectangle()
                                .fill(Palette.rail.opacity(0.16))
                                .frame(height: Metrics.hairline)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .overlay { Rectangle().strokeBorder(Palette.rail.opacity(0.25), lineWidth: Metrics.hairline) }
    }

    // MARK: Perimeter

    @ViewBuilder
    private var perimeterPanel: some View {
        VStack(spacing: 0) {
            if places.isEmpty {
                Text("NO BUILDINGS YET. THE FIRST DESK BOOKING LEARNS ONE.")
                    .t8(.rowActionNote)
                    .foregroundStyle(Palette.bone.opacity(0.4))
                    .padding(.vertical, 14)
                    .padding(.horizontal, 15)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(places) { place in
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(place.name.uppercased())
                                .t8(.rowAction)
                                .foregroundStyle(Palette.bone)
                            Spacer(minLength: 0)
                            Text(place.postcode.uppercased())
                                .t8(.rowAction)
                                .foregroundStyle(Palette.boneSecondary)
                        }
                        Text("\(Int(place.radiusMetres))m RADIUS ▪ LEARNED FROM BOOKINGS")
                            .t8(.rowActionNote)
                            .foregroundStyle(Palette.bone.opacity(0.4))
                            .padding(.top, 6)
                    }
                    .padding(.vertical, 14)
                    .padding(.horizontal, 15)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .overlay { Rectangle().strokeBorder(Palette.rail.opacity(0.25), lineWidth: Metrics.hairline) }
    }

    /// The inversion, stated. Arrive with nothing booked and the prompt offers
    /// to log the day rather than reporting a desk.
    private var invertedPromptPanel: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("NO BOOKING ▪ NO REPORT")
                .t8(.subRouteHeader)
                .foregroundStyle(Palette.rail)
            Text(
                copy.terminator
                    ? "ARRIVE WITH NOTHING BOOKED AND THE PROMPT INVERTS: OFFER TO LOG THE DAY AND CLAIM THE KILL."
                    : "ARRIVE WITH NOTHING BOOKED AND THE PROMPT INVERTS: OFFER TO RECORD THE DAY AS AN OFFICE DAY."
            )
            .t8(.panelBody)
            .foregroundStyle(Palette.bone.opacity(0.5))
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 13)
        .padding(.horizontal, 15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.rail.opacity(0.07))
        .overlay { Rectangle().strokeBorder(Palette.railBorderStrong, lineWidth: Metrics.hairline) }
    }
}
