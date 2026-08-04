import SwiftData
import SwiftUI

/// A plain push/pop stack. Targets is the root; every card pushes its detail.
///
/// `Route` is a value type and `Hashable`, which is what `navigationDestination`
/// wants — SwiftUI's typed navigation is closer to a React router's route
/// objects than to a UIKit view-controller stack. Bookings and trips are
/// referred to by id rather than by object: a `@Model` is a live reference and
/// putting one in the navigation path would keep it alive past deletion.
enum Route: Hashable {
    case trip(UUID)
    case ticket(UUID)
    case desk(UUID)
    case stay(UUID)
    case mission
}

struct RootView: View {
    @State private var path = NavigationPath()

    @Query(sort: \Booking.startsAt) private var bookings: [Booking]
    @Query(sort: \Trip.startsOnDate) private var trips: [Trip]

    var body: some View {
        NavigationStack(path: $path) {
            TargetsScreen()
                .navigationDestination(for: Route.self) { route in
                    destination(for: route)
                }
        }
        .tint(Palette.rail)
        .task { openDebugScreen() }
    }

    /// `-screen ticket|eurostar|desk|stay|trip|mission` pushes straight to a
    /// screen at launch. There is no way to drive a tap from the command line,
    /// so without this every screen below the root can only be checked by hand.
    /// Debug builds only — it never ships.
    private func openDebugScreen() {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-screen"),
              index + 1 < arguments.count else { return }

        let route: Route? = switch arguments[index + 1] {
        case "ticket":
            bookings.first { $0.kind == .rail }.map { .ticket($0.id) }
        case "eurostar":
            bookings.first { $0.detail?.railDetail?.checkInBy != nil }.map { .ticket($0.id) }
        case "desk":
            bookings.first { $0.kind == .desk }.map { .desk($0.id) }
        case "stay":
            // The incomplete one, since that is the case worth looking at.
            (bookings.first { $0.kind == .stay && $0.hasUnreadableFields }
                ?? bookings.first { $0.kind == .stay }).map { .stay($0.id) }
        case "trip":
            trips.first { trip in trips.contains { $0.parentTripID == trip.id } }
                .map { .trip($0.id) }
        case "mission":
            .mission
        default:
            nil
        }

        if let route { path.append(route) }
        #endif
    }

    @ViewBuilder
    private func destination(for route: Route) -> some View {
        switch route {
        case .trip(let id): TripDetailScreen(tripID: id)
        case .ticket(let id): TicketScreen(bookingID: id)
        case .desk(let id): DeskScreen(bookingID: id)
        case .stay(let id): StayScreen(bookingID: id)
        case .mission: MissionScreen()
        }
    }
}

/// The route a booking's card pushes to.
@MainActor
func route(for booking: Booking) -> Route {
    switch booking.kind {
    case .rail: .ticket(booking.id)
    case .desk: .desk(booking.id)
    case .stay: .stay(booking.id)
    }
}

/// Every screen below the root: a `← RETURN` label above the content, no system
/// navigation bar. The design is explicit that back is a text label at the top
/// left rather than a chevron in a nav bar.
struct ScreenScaffold<Header: View, Content: View>: View {
    var backTitle: String = "RETURN"
    /// A header block below the back label, above a rule. Trip detail and The
    /// Mission use it; the ticket, desk and stay screens don't.
    @ViewBuilder var header: () -> Header
    @ViewBuilder var content: () -> Content

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScreenBackground {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    Button { dismiss() } label: {
                        BackLabel(text: backTitle)
                    }
                    .buttonStyle(.plain)

                    header()
                }
                .padding(.horizontal, Metrics.headerPadding)
                .padding(.top, Metrics.headerTopInset)
                .padding(.bottom, Header.self == EmptyView.self ? 0 : 14)

                if Header.self != EmptyView.self {
                    HUDRule()
                }

                ScrollView {
                    content()
                        .padding(.horizontal, Metrics.screenPadding)
                        .padding(.top, 18)
                        .padding(.bottom, 26)
                }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .navigationBarBackButtonHidden()
    }
}

extension ScreenScaffold where Header == EmptyView {
    init(
        backTitle: String = "RETURN",
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.init(backTitle: backTitle, header: { EmptyView() }, content: content)
    }
}

/// A titled header block, as used by trip detail and The Mission.
struct ScreenTitleBlock<Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .t8(.screenTitle)
                    .foregroundStyle(Palette.bone)
                Spacer(minLength: 8)
                trailing()
            }
            .padding(.top, 12)

            if let subtitle {
                Text(subtitle)
                    .t8(.screenSubtitle)
                    .foregroundStyle(Palette.boneSecondary)
                    .padding(.top, 6)
            }
        }
    }
}

extension ScreenTitleBlock where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle, trailing: { EmptyView() })
    }
}
