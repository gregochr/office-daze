import CoreLocation
import Foundation
import SwiftData
import UserNotifications

/// The slice of `CLLocationManager` this file actually touches.
///
/// A protocol rather than the concrete class because nothing in a test can
/// grant `CLLocationManager` Always, and nothing can make it register a
/// perimeter — so every decision below the delegate was unreachable: which
/// regions get registered, which get torn down, which of the two permission
/// prompts is raised, and in what order. That is precisely the code where being
/// wrong is invisible from the outside, because a perimeter iOS was never told
/// about looks exactly like one it is watching.
///
/// Kept deliberately narrow: every member here is one `ArrivalMonitor` calls,
/// and nothing else. A wider seam would let a stand-in drift away from what
/// CoreLocation is really being asked to do, which is the one thing the seam
/// exists to pin down.
protocol RegionMonitoring: AnyObject {
    var authorizationStatus: CLAuthorizationStatus { get }
    var monitoredRegions: Set<CLRegion> { get }
    var delegate: (any CLLocationManagerDelegate)? { get set }
    var allowsBackgroundLocationUpdates: Bool { get set }

    func requestWhenInUseAuthorization()
    func requestAlwaysAuthorization()
    func startMonitoring(for region: CLRegion)
    func stopMonitoring(for region: CLRegion)
}

/// The real one, member for member — no adapter code, so there is nothing here
/// that can be right in the test and wrong in the app.
extension CLLocationManager: RegionMonitoring {}

/// Region monitoring, and the two permission prompts it needs.
///
/// Created at launch rather than by a screen. iOS relaunches the app in the
/// background when a monitored region is crossed, and the queued event is only
/// delivered if a `CLLocationManager` already exists with its delegate set — a
/// manager created lazily by a view that never appears would drop the arrival
/// silently.
@MainActor
@Observable
final class ArrivalMonitor: NSObject {

    /// iOS caps region monitoring at 20 regions per app. Six offices is the
    /// palette's own limit, so this is headroom rather than a constraint — but
    /// it is here so a future bulk import cannot quietly exceed it.
    static let maximumRegions = 20

    private let manager: any RegionMonitoring
    private let ledger: ArrivalLedger
    private let context: ModelContext

    /// The notification centre, behind two closures.
    ///
    /// Swapped in tests for the same reason `ArrivalLedger.post` is: asking the
    /// real centre for authorization from a test run either raises a system
    /// prompt on the machine or, with nobody there to answer it, never returns.
    /// The status read is seamed alongside it rather than left real, because
    /// collapsing the five `UNAuthorizationStatus` cases down to one Bool is
    /// the whole of what this class does with notifications — and a simulator
    /// that always answers `.notDetermined` would make that mapping look tested
    /// when only one of its five inputs had ever been tried.
    var requestNotificationPermission: () async -> Bool = {
        (try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound])) ?? false
    }
    var readNotificationStatus: () async -> UNAuthorizationStatus = {
        await UNUserNotificationCenter.current()
            .notificationSettings().authorizationStatus
    }

    private(set) var authorization: CLAuthorizationStatus

    /// Whether iOS will deliver anything the app posts.
    ///
    /// Location says whether we are *woken*; this says whether the user ever
    /// sees the result, and until now nothing in the app read it. The request
    /// was fired and forgotten from one button, so a user who granted Always
    /// location and declined the notification prompt that came with it saw
    /// "Alert on · 50m" in the reassuring green against an alert that could
    /// never arrive — and no screen in the app so much as mentioned
    /// notifications. Starts false and is corrected by `refreshNotificationStatus`
    /// rather than assumed: claiming the alert works when it does not is the
    /// failure that matters here, so the pessimistic start is the safe one.
    private(set) var notificationsAllowed = false

    init(
        ledger: ArrivalLedger, context: ModelContext,
        manager: any RegionMonitoring = CLLocationManager()
    ) {
        self.manager = manager
        self.ledger = ledger
        self.context = context
        authorization = manager.authorizationStatus
        super.init()
        manager.delegate = self
        manager.allowsBackgroundLocationUpdates = false
    }

    /// Whether the alert can actually fire. Anything short of Always means iOS
    /// will not wake the app for a crossing, so the app must not claim it will.
    var canMonitor: Bool { authorization == .authorizedAlways }

    /// The offices CoreLocation is really watching, by id.
    ///
    /// Asked of the manager rather than remembered from `refreshRegions`,
    /// because a set built from what the app *intended* to register would
    /// repeat the defect that made this necessary: the office editor did not
    /// call `refreshRegions` at all, so a new office, a corrected address and a
    /// widened perimeter each went unwatched for days — and every screen in the
    /// app went on saying "Alert on · 50m", because every screen was reading
    /// the toggle. A perimeter iOS was never told about looks exactly like one
    /// it is watching, from this side, unless this side asks.
    ///
    /// It also catches the registrations the app never gets told were dropped:
    /// twenty regions is the per-app cap, and CoreLocation refuses the
    /// twenty-first silently.
    ///
    /// Identifiers that will not parse are dropped rather than counted, for the
    /// reason `entered(regionIdentifier:)` drops them — a region left behind by
    /// an older build names no office here, and counting it would let a stale
    /// perimeter vouch for a live office.
    ///
    /// Not observable, and it cannot be: `monitoredRegions` lives on
    /// CoreLocation's object, not in this one's stored properties, so
    /// `@Observable` has nothing to invalidate on. What redraws the row is that
    /// every path which changes this set changes something a screen does watch
    /// — `authorization`, or the `Office` rows behind its `@Query`. Adding a
    /// call site that rebuilds the perimeters without touching either would
    /// leave the row a redraw behind, which is why the copy for `.notWatched`
    /// says "yet" rather than accusing.
    var monitoredOfficeIDs: Set<UUID> {
        Set(manager.monitoredRegions.compactMap { UUID(uuidString: $0.identifier) })
    }

    // MARK: Permission

    /// When In Use first, then Always — and only once When In Use is granted.
    /// Asking for Always cold gets denied, and a denied prompt cannot be
    /// re-asked from inside the app.
    func requestAuthorization() {
        // Notifications are asked for here rather than at launch. An alert
        // permission prompt on first run, before the user knows what it is
        // for, is the prompt that gets denied — and a denied prompt cannot be
        // re-asked from inside the app.
        Task { await requestNotificationAuthorization() }
        escalate()
    }

    /// The notification prompt on its own, and the answer kept rather than
    /// dropped on the floor.
    ///
    /// Separately callable because the evening reminder needs notifications and
    /// needs nothing else: it depends on neither location nor owning an office,
    /// but the only call site used to be a row that appears only when both of
    /// those are unmet. Turning the reminder on could therefore leave
    /// authorization at `.notDetermined` for ever, with the toggle on and no
    /// notification ever arriving.
    func requestNotificationAuthorization() async {
        notificationsAllowed = await requestNotificationPermission()
    }

    /// Re-read rather than remembered: permission can be revoked in Settings
    /// while the app is not running, and a cached yes is exactly the claim this
    /// property exists to stop the UI making.
    func refreshNotificationStatus() async {
        let status = await readNotificationStatus()
        // Provisional counts: a quietly-delivered alert still reaches the
        // Notification Centre, so the app is not lying when it says the alert
        // will arrive. Everything else — `.notDetermined` as much as `.denied`
        // — does not, and an unasked prompt is exactly as silent as a refused
        // one.
        notificationsAllowed = status == .authorized || status == .provisional
    }

    /// Location only. Kept apart from `requestAuthorization` because the
    /// delegate calls it when iOS reports When In Use — and a notification
    /// prompt appearing as a side effect of a status callback is a prompt the
    /// user did not ask for.
    private func escalate() {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse:
            manager.requestAlwaysAuthorization()
        default:
            break
        }
    }

    // MARK: What the delegate decides

    /// What a change of location permission means, apart from the hop that
    /// carries it here.
    ///
    /// Split off `didChangeAuthorization` because that method is `nonisolated`
    /// and hands its work to an unstructured `Task`: anything driving it can
    /// only assert on what has landed *by now*. The decision itself — escalate
    /// if there is anywhere left to escalate to, then rebuild the perimeters
    /// whatever the answer was — is ordinary main-actor code, and it is worth
    /// being able to assert on it exactly and in order. The rebuild is outside
    /// the `if` on purpose: a permission being taken *away* has to tear the
    /// perimeters down just as surely as one being granted puts them up.
    func authorizationChanged(to status: CLAuthorizationStatus) {
        authorization = status
        // Escalate the moment When In Use lands, while the user is still
        // thinking about permissions rather than a week later.
        if status == .authorizedWhenInUse {
            escalate()
        }
        refreshRegions()
    }

    /// A crossing, named by the only thing on a `CLRegion` this app ever wrote.
    ///
    /// Takes the identifier rather than the region because that is all that can
    /// safely cross to the main actor — `CLRegion` is not `Sendable` — and
    /// because it makes the one failure mode visible: an identifier that is not
    /// one of our office ids. iOS goes on monitoring a perimeter until told to
    /// stop, and a build that changed how identifiers are minted, or a region
    /// left behind by an older install, arrives here as a string with no office
    /// behind it. There is nothing to decide about it, so it is dropped rather
    /// than forced into a `UUID` that would name no office anyway.
    func entered(regionIdentifier: String) {
        guard let officeID = UUID(uuidString: regionIdentifier) else { return }
        ledger.handleEntry(officeID: officeID)
    }

    /// Delegate and categories only — no prompt. Registration has to happen at
    /// launch because iOS may deliver a tapped notification straight into a
    /// cold start, and a delegate set later would miss it.
    func registerNotificationHandling() {
        let centre = UNUserNotificationCenter.current()
        centre.delegate = self
        centre.setNotificationCategories(ArrivalNotifications.categories)
    }

    // MARK: Regions

    /// Rebuilt wholesale rather than diffed: the set is at most six regions,
    /// and a diff that drifts out of step with the store is a perimeter that
    /// silently stops being watched.
    func refreshRegions() {
        for region in manager.monitoredRegions {
            manager.stopMonitoring(for: region)
        }
        guard canMonitor else { return }

        let offices = ((try? context.fetch(FetchDescriptor<Office>())) ?? [])
            .filter { $0.alertEnabled && $0.isLocated }
            .prefix(Self.maximumRegions)

        for office in offices {
            let region = CLCircularRegion(
                center: CLLocationCoordinate2D(
                    latitude: office.latitude, longitude: office.longitude
                ),
                radius: office.radiusMetres,
                identifier: office.id.uuidString
            )
            // Entry only, still — even though the alert now repeats on every
            // arrival. CoreLocation tracks the inside/outside state either way;
            // these two flags only say which transitions are worth waking the
            // app for. A re-entry after a real exit therefore arrives as
            // another `didEnterRegion`, and waking for the exit as well would
            // double the wake-ups to learn something the next entry tells us.
            region.notifyOnEntry = true
            region.notifyOnExit = false
            manager.startMonitoring(for: region)
        }
    }

    #if DEBUG
    /// `-arrival <office name>` fires the rule as though the perimeter had been
    /// crossed. There is no way to walk into a building from a script.
    func simulateEntry(officeNamed name: String) {
        guard let office = ((try? context.fetch(FetchDescriptor<Office>())) ?? [])
            .first(where: { $0.name.localizedCaseInsensitiveContains(name) }) else { return }
        ledger.handleEntry(officeID: office.id)
    }
    #endif
}

/// Whether an office's arrival alert will actually reach the user, and the line
/// the offices list prints when it will not.
///
/// A type rather than two functions on the settings row, because the row got it
/// wrong: it asked `alertEnabled && canMonitor && isLocated` and printed
/// "Alert on · 50m" in `Palette.met` green for a user who had granted Always
/// location and then declined the notification prompt that arrived alongside it.
/// Two permissions have to hold, not one. Making it an enum forces every new
/// reason the alert cannot fire to come with the line that explains it, and lets
/// the ladder be tested — a `View` cannot be.
nonisolated enum AlertReadiness: Equatable, Sendable {
    case off
    case needsLocation
    case needsNotifications
    case notLocated
    case notWatched
    case ready(radiusMetres: Int)

    /// Ordered by what the user should fix first. Location comes before
    /// notifications because without it the app is never even woken, so telling
    /// someone to turn notifications on first would be advice that changes
    /// nothing.
    ///
    /// `isWatched` is last because it is the only rung that is not about
    /// permission or about the office: it is about whether CoreLocation was
    /// ever actually told. Every rung above it explains why there is no
    /// perimeter, so asking it first would print "not being watched yet" for a
    /// switched-off office and bury the reason.
    ///
    /// It defaults to `true` only so this ladder can be exercised on its other
    /// five axes without every case naming it. That default is optimistic, and
    /// an optimistic default is the shape of the bug this rung exists to catch
    /// — so the app's one caller, `SettingsScreen.readiness`, passes it
    /// explicitly and `SettingsScreenTests` fails if it ever stops.
    static func of(
        alertEnabled: Bool, canMonitor: Bool, notificationsAllowed: Bool,
        isLocated: Bool, radiusMetres: Double, isWatched: Bool = true
    ) -> AlertReadiness {
        guard alertEnabled else { return .off }
        guard canMonitor else { return .needsLocation }
        guard notificationsAllowed else { return .needsNotifications }
        guard isLocated else { return .notLocated }
        guard isWatched else { return .notWatched }
        return .ready(radiusMetres: Int(radiusMetres))
    }

    /// Green is for an alert that will fire, and only that. The toggle being on
    /// is not the same thing.
    var willFire: Bool {
        if case .ready = self { true } else { false }
    }

    var text: String {
        switch self {
        case .off: "Alert off"
        case .needsLocation: "Alert needs location access"
        case .needsNotifications: "Alert needs notifications turned on"
        case .notLocated: "Alert on · no location yet"
        case .notWatched: "Alert on · not being watched yet"
        case .ready(let radius): "Alert on · \(radius)m"
        }
    }
}

// MARK: - CLLocationManagerDelegate

extension ArrivalMonitor: CLLocationManagerDelegate {

    nonisolated func locationManager(
        _ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus
    ) {
        // The status crosses the actor boundary, not the manager: CLLocationManager
        // is not Sendable, and the main-actor copy we already hold is the same
        // object anyway.
        Task { @MainActor in
            authorizationChanged(to: status)
        }
    }

    nonisolated func locationManager(
        _ manager: CLLocationManager, didEnterRegion region: CLRegion
    ) {
        // Same reasoning: the identifier crosses, the region does not.
        let identifier = region.identifier
        Task { @MainActor in
            entered(regionIdentifier: identifier)
        }
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension ArrivalMonitor: UNUserNotificationCenterDelegate {

    /// The alert is worth seeing even with the app open — arriving at the
    /// office while looking at the app is exactly when the desk number is
    /// wanted.
    nonisolated func userNotificationCenter(
        _ centre: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(
        _ centre: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        // The whole decision is made in `ArrivalNotifications.answer`, against
        // the day the notification was *delivered* rather than today — see the
        // reasoning there. This function is left as the adapter, because a
        // `UNNotificationResponse` cannot be constructed by a test and anything
        // decided in here therefore cannot be tested at all.
        let answer = ArrivalNotifications.answer(
            to: response.actionIdentifier,
            userInfo: response.notification.request.content.userInfo,
            delivered: Day(localOf: response.notification.date)
        )
        await MainActor.run {
            switch answer {
            case .ignore:
                break
            case .record(let officeID, let day, let bookingID):
                ledger.confirmAttendance(
                    officeID: officeID, day: day, bookingID: bookingID
                )
            case .decline(let bookingID):
                // A no is an answer worth storing: without it the row goes on
                // asking and the notification comes back tomorrow about the
                // same day.
                ledger.declineAttendance(bookingID: bookingID)
            }
            // Unconditional, including after `.ignore`. The evening question is
            // decided while the app is awake and fires hours later, so answering
            // one has to re-decide the next — and a tap that was refused as
            // stale is the strongest possible sign that what is pending no
            // longer matches the store.
            NudgeScheduler.refresh(in: context)
        }
    }
}
