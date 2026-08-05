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
    /// Watched, not sampled. A single reading taken as the screen appears is
    /// wrong the moment the permission is granted.
    @State private var location = LocationAuthorization()
    @Environment(\.scenePhase) private var scenePhase

    @State private var adding = false
    @State private var newName = ""
    @State private var newCity = ""
    @State private var newAddress = ""
    @State private var locating = false
    @State private var addResult: (text: String, problem: Bool)?

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
                addBuildingRow.padding(.top, 8)
                if adding { addBuildingForm.padding(.top, 8) }

                invertedPromptPanel.padding(.top, 11)
            }
        }
        .task {
            #if DEBUG
            await runDebugAdd()
            #endif
        }
        // Coming back from Settings.app: the delegate callback is not
        // guaranteed to have arrived while the app was suspended.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { location.refresh() }
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

            // Nothing left to ask for once Always is granted, so no button.
            // The two remaining cases want different buttons: iOS only ever
            // prompts once, so a permission already answered can only be
            // changed in Settings.app — offering ASK FOR ACCESS there would be
            // a button that does nothing.
            if !location.isSettled {
                SolidAction(
                    title: location.mustUseSettings ? "OPEN SETTINGS" : "ASK FOR ACCESS",
                    fill: Palette.desk
                ) {
                    if location.mustUseSettings {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    } else {
                        // Both permissions are asked for here, together, at the
                        // point the feature is being switched on.
                        let monitor = ArrivalMonitor(ledger: ArrivalLedger(context: context))
                        Task { await monitor.requestNotifications() }
                        location.request()
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
        switch location.status {
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
                        // The mock says "LEARNED FROM BOOKINGS", which stopped
                        // being true the moment a building could be added by
                        // hand. What the row says now is the thing worth
                        // knowing anyway: whether this perimeter is armed.
                        Text(perimeterNote(place))
                            .t8(.rowActionNote)
                            .foregroundStyle(
                                place.isLocated ? Palette.bone.opacity(0.4) : Palette.desk
                            )
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

    private func perimeterNote(_ place: Place) -> String {
        place.isLocated
            ? "\(Int(place.radiusMetres))m RADIUS ▪ PERIMETER ARMED"
            : "NOT FOUND ON THE MAP ▪ NO PERIMETER"
    }

    // MARK: Adding a building

    /// The design says places are "learned from bookings", and mostly they are
    /// — `PlaceResolver` creates one from the first desk captured at a new
    /// building. This is for the other case: a perimeter you want armed before
    /// the first booking arrives, or a building whose geocode came back wrong.
    private var addBuildingRow: some View {
        Button {
            adding.toggle()
            addResult = nil
        } label: {
            HStack(spacing: 12) {
                Text(adding ? "CANCEL" : "+ ADD BUILDING")
                    .t8(.rowAction)
                    .foregroundStyle(adding ? Palette.boneSecondary : Palette.bone)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 13)
            .padding(.horizontal, 15)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay {
                Rectangle().strokeBorder(Palette.rail.opacity(0.25), lineWidth: Metrics.hairline)
            }
        }
        .buttonStyle(.plain)
    }

    private var addBuildingForm: some View {
        VStack(spacing: 8) {
            FieldRow(label: "NAME", value: $newName, placeholder: "ROPEMAKER PLACE", required: true)
            FieldRow(label: "CITY", value: $newCity, placeholder: "LONDON")
            FieldRow(label: "ADDRESS", value: $newAddress, placeholder: "25 ROPEMAKER ST")

            Text("THE POSTCODE AND THE 50m PERIMETER COME FROM THE GEOCODER. A BUILDING IT CANNOT FIND IS STILL SAVED — IT SIMPLY HAS NO PERIMETER.")
                .t8(.panelBody)
                .foregroundStyle(Palette.bone.opacity(0.45))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let addResult {
                HStack(spacing: 9) {
                    Rectangle()
                        .fill(addResult.problem ? Palette.desk : Palette.stay)
                        .frame(width: 6, height: 6)
                    Text(addResult.text)
                        .t8(.offline)
                        .foregroundStyle(addResult.problem ? Palette.desk : Palette.stay)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 11)
                .padding(.horizontal, 13)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background((addResult.problem ? Palette.desk : Palette.stay).opacity(0.07))
                .overlay {
                    Rectangle().strokeBorder(
                        (addResult.problem ? Palette.desk : Palette.stay).opacity(0.45),
                        lineWidth: Metrics.hairline
                    )
                }
            }

            SolidAction(
                title: locating ? "LOCATING…" : "SAVE BUILDING",
                fill: newName.trimmed.isEmpty ? Palette.desk.opacity(0.3) : Palette.desk
            ) {
                Task { await addBuilding() }
            }
        }
    }

    #if DEBUG
    /// `-screen arrival-settings -add-building "Broadgate Tower|London"` runs
    /// the real geocoder, which the unit tests deliberately stub out. Without
    /// it the only untested thing in this path is the one bit of new API.
    private func runDebugAdd() async {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-add-building"),
              index + 1 < arguments.count else { return }
        let parts = arguments[index + 1].split(separator: "|").map(String.init)
        adding = true
        newName = parts.first ?? ""
        newCity = parts.count > 1 ? parts[1] : ""
        newAddress = parts.count > 2 ? parts[2] : ""
        await addBuilding()
    }
    #endif

    private func addBuilding() async {
        guard !newName.trimmed.isEmpty, !locating else { return }

        let places = (try? context.fetch(FetchDescriptor<Place>())) ?? []
        if PlaceResolver.existing(named: newName, city: newCity, among: places) != nil {
            addResult = ("THAT BUILDING IS ALREADY ON THE LIST.", true)
            return
        }

        let place = Place(
            name: newName.trimmed,
            city: newCity.trimmed,
            address: newAddress.trimmed,
            postcode: "",
            latitude: 0,
            longitude: 0
        )
        context.insert(place)

        locating = true
        let located = await PlaceResolver.locate(place)
        locating = false
        try? context.save()

        // Armed straight away rather than at the next launch: a perimeter you
        // just added and that does nothing until you relaunch reads as broken.
        ArrivalMonitor(ledger: ArrivalLedger(context: context)).refreshRegions()

        addResult = located
            ? ("\(place.name.uppercased()) LOCATED. PERIMETER ARMED.", false)
            : ("SAVED, BUT NOT FOUND ON THE MAP. NO PERIMETER.", true)
        newName = ""
        newCity = ""
        newAddress = ""
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
