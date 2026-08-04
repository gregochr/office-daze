import CoreLocation
import Foundation
import SwiftData
import UserNotifications

/// Region monitoring, and nothing else. The sequence it triggers lives in
/// `ArrivalLedger`, which has no CoreLocation in it and can therefore be tested
/// without one.
///
/// Created at app launch rather than by a screen, and deliberately so: iOS
/// relaunches the app in the background when a monitored region is crossed, and
/// the queued event is only delivered if a `CLLocationManager` exists with its
/// delegate already set. A manager created lazily by a view that never appears
/// would drop the event silently.
@MainActor
final class ArrivalMonitor: NSObject {

    private let manager = CLLocationManager()
    private let ledger: ArrivalLedger
    private let settings: ArrivalSettings
    private let copy: Copy

    init(ledger: ArrivalLedger, settings: ArrivalSettings = .shared, copy: Copy = .shared) {
        self.ledger = ledger
        self.settings = settings
        self.copy = copy
        super.init()
        manager.delegate = self
    }

    // MARK: Authorisation

    var authorization: CLAuthorizationStatus { manager.authorizationStatus }

    /// Ask for When In Use first and escalate to Always only once that is
    /// granted. Asking for Always cold gets denied — iOS shows the harsher
    /// prompt, people decline, and there is no second chance.
    func requestAuthorization() {
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse: manager.requestAlwaysAuthorization()
        default: break
        }
    }

    /// Registers the delegate and the notification categories. No prompt —
    /// safe to call at launch, and it has to be, because the action a tapped
    /// notification carries is only routed if the delegate is already set.
    func registerNotificationHandling() {
        let centre = UNUserNotificationCenter.current()
        centre.delegate = self
        centre.setNotificationCategories(
            ArrivalNotifications.categories(copy: copy.callAsFunction)
        )
    }

    /// Asks for notification permission. Deliberately not called at launch:
    /// prompting before the user has turned anything on spends the one prompt
    /// iOS gives you on a feature they have not yet asked for.
    @discardableResult
    func requestNotifications() async -> Bool {
        registerNotificationHandling()
        return (try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    // MARK: Regions

    /// One region per known place, 50m, entry only.
    ///
    /// Exits are not monitored: the ledger already answers "has this fired
    /// today", and dwell-time logic would not survive the app being killed —
    /// which is exactly when a geofence needs to work.
    func refreshRegions() {
        guard settings.enabled else {
            for region in manager.monitoredRegions { manager.stopMonitoring(for: region) }
            return
        }

        // iOS monitors at most 20 regions per app. One office is the expected
        // case; the cap is explicit so a long list degrades predictably rather
        // than letting iOS drop whichever regions it likes.
        let wanted = ledger.monitorablePlaces.prefix(20)
        let wantedIDs = Set(wanted.map { $0.id.uuidString })

        for region in manager.monitoredRegions where !wantedIDs.contains(region.identifier) {
            manager.stopMonitoring(for: region)
        }

        let monitored = Set(manager.monitoredRegions.map(\.identifier))
        for place in wanted where !monitored.contains(place.id.uuidString) {
            let region = CLCircularRegion(
                center: CLLocationCoordinate2D(
                    latitude: place.latitude, longitude: place.longitude
                ),
                radius: place.radiusMetres,
                identifier: place.id.uuidString
            )
            region.notifyOnEntry = true
            region.notifyOnExit = false
            manager.startMonitoring(for: region)
        }
    }

    var monitoredPlaceIDs: [UUID] {
        manager.monitoredRegions.compactMap { UUID(uuidString: $0.identifier) }
    }
}

// MARK: - CLLocationManagerDelegate

extension ArrivalMonitor: CLLocationManagerDelegate {

    nonisolated func locationManager(
        _ manager: CLLocationManager, didEnterRegion region: CLRegion
    ) {
        guard let placeID = UUID(uuidString: region.identifier) else { return }
        Task { @MainActor in await ledger.handleEntry(placeID: placeID) }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        // The `manager` parameter is deliberately not captured: CLLocationManager
        // is not Sendable, so sending it into the MainActor task is a data race.
        // `self.manager` is the same object, already isolated to this actor.
        Task { @MainActor in
            // Escalate the moment When In Use lands, while the app is still in
            // the foreground and the second prompt reads as a follow-up rather
            // than an ambush.
            if self.manager.authorizationStatus == .authorizedWhenInUse {
                self.manager.requestAlwaysAuthorization()
            }
            refreshRegions()
        }
    }

    nonisolated func locationManager(
        _ manager: CLLocationManager, monitoringDidFailFor region: CLRegion?, withError error: Error
    ) {
        // Nothing to recover: the region simply isn't monitored. Surfacing it
        // on the settings screen is stage 6.
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension ArrivalMonitor: UNUserNotificationCenterDelegate {

    nonisolated func userNotificationCenter(
        _ centre: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let info = response.notification.request.content.userInfo
        guard response.actionIdentifier == ArrivalNotifications.Action.confirm.rawValue,
              let placeText = info[ArrivalNotifications.UserInfo.placeID] as? String,
              let placeID = UUID(uuidString: placeText),
              let dayText = info[ArrivalNotifications.UserInfo.day] as? String,
              let day = Day(dayText) else { return }

        let bookingID = (info[ArrivalNotifications.UserInfo.bookingID] as? String)
            .flatMap(UUID.init(uuidString:))

        await MainActor.run {
            ledger.confirmAttendance(placeID: placeID, bookingID: bookingID, day: day)
        }
    }

    /// Show the alert even with the app open — arriving at the office with
    /// Travel8tor already on screen is exactly when the desk number is wanted.
    nonisolated func userNotificationCenter(
        _ centre: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}

nonisolated extension Day {
    /// Parses the `description` form, which is what rides on the notification.
    init?(_ text: String) {
        let parts = text.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2])
        else { return nil }
        self.init(year, month, day)
    }
}
