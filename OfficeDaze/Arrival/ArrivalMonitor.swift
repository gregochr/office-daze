import CoreLocation
import Foundation
import SwiftData
import UserNotifications

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

    private let manager = CLLocationManager()
    private let ledger: ArrivalLedger
    private let context: ModelContext

    private(set) var authorization: CLAuthorizationStatus

    init(ledger: ArrivalLedger, context: ModelContext) {
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

    // MARK: Permission

    /// When In Use first, then Always — and only once When In Use is granted.
    /// Asking for Always cold gets denied, and a denied prompt cannot be
    /// re-asked from inside the app.
    func requestAuthorization() {
        // Notifications are asked for here rather than at launch. An alert
        // permission prompt on first run, before the user knows what it is
        // for, is the prompt that gets denied — and a denied prompt cannot be
        // re-asked from inside the app.
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        escalate()
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

// MARK: - CLLocationManagerDelegate

extension ArrivalMonitor: CLLocationManagerDelegate {

    nonisolated func locationManager(
        _ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus
    ) {
        // The status crosses the actor boundary, not the manager: CLLocationManager
        // is not Sendable, and the main-actor copy we already hold is the same
        // object anyway.
        Task { @MainActor in
            authorization = status
            // Escalate the moment When In Use lands, while the user is still
            // thinking about permissions rather than a week later.
            if status == .authorizedWhenInUse {
                escalate()
            }
            refreshRegions()
        }
    }

    nonisolated func locationManager(
        _ manager: CLLocationManager, didEnterRegion region: CLRegion
    ) {
        guard let officeID = UUID(uuidString: region.identifier) else { return }
        Task { @MainActor in
            ledger.handleEntry(officeID: officeID)
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
        let info = response.notification.request.content.userInfo
        guard response.actionIdentifier == ArrivalNotifications.Action.confirm.rawValue,
              let officeText = info[ArrivalNotifications.UserInfo.officeID] as? String,
              let officeID = UUID(uuidString: officeText),
              let dayText = info[ArrivalNotifications.UserInfo.day] as? String,
              let day = CapturedBooking.day(from: dayText) else { return }

        let bookingText = info[ArrivalNotifications.UserInfo.bookingID] as? String
        await MainActor.run {
            ledger.confirmAttendance(
                officeID: officeID, day: day,
                bookingID: bookingText.flatMap(UUID.init(uuidString:))
            )
        }
    }
}
