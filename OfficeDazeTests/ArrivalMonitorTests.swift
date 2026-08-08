import CoreLocation
import Foundation
import SwiftData
import Testing
import UserNotifications
@testable import OfficeDaze

/// A `CLLocationManager` that does nothing but remember what it was asked to
/// do, in order, with the arguments it was given.
///
/// Deliberately not permissive. Every call is recorded with the values that
/// came with it — the coordinates and radius of each perimeter, the identifier
/// of each one torn down, and which of the two permission prompts was raised —
/// because the defect this stands in to catch is a perimeter registered at the
/// wrong place, or not registered at all, and a stand-in that merely counted
/// calls would be green for both. `monitoredRegions` is real state rather than
/// a canned answer for the same reason: `refreshRegions` reads it back to know
/// what to tear down, so a fake that always answered "none" would make the
/// teardown look like it worked when it had nothing to do.
@MainActor
final class RecordingLocationManager: RegionMonitoring {

    /// A perimeter as CoreLocation was actually given it, flattened to values
    /// so a test can say what it expected rather than build a `CLRegion` to
    /// compare against.
    struct Perimeter: Equatable {
        let identifier: String
        let latitude: Double
        let longitude: Double
        let radius: Double
        let notifyOnEntry: Bool
        let notifyOnExit: Bool

        init(_ region: CLCircularRegion) {
            identifier = region.identifier
            latitude = region.center.latitude
            longitude = region.center.longitude
            radius = region.radius
            notifyOnEntry = region.notifyOnEntry
            notifyOnExit = region.notifyOnExit
        }
    }

    enum Call: Equatable {
        case whenInUsePrompt
        case alwaysPrompt
        case start(Perimeter)
        case stop(identifier: String)
    }

    var authorizationStatus: CLAuthorizationStatus = .notDetermined
    weak var delegate: (any CLLocationManagerDelegate)?
    var allowsBackgroundLocationUpdates = true

    private(set) var calls: [Call] = []

    /// Keyed by identifier, the way CoreLocation keys them: registering a
    /// second region under an identifier already monitored replaces the first
    /// rather than joining it. That is what makes "the office moved" a
    /// re-registration and not a second perimeter round the old building.
    private var registered: [String: CLCircularRegion] = [:]

    var monitoredRegions: Set<CLRegion> { Set(registered.values) }

    func requestWhenInUseAuthorization() { calls.append(.whenInUsePrompt) }

    func requestAlwaysAuthorization() { calls.append(.alwaysPrompt) }

    func startMonitoring(for region: CLRegion) {
        guard let circle = region as? CLCircularRegion else {
            Issue.record("a perimeter has to be circular, got \(type(of: region))")
            return
        }
        calls.append(.start(Perimeter(circle)))
        registered[circle.identifier] = circle
    }

    func stopMonitoring(for region: CLRegion) {
        calls.append(.stop(identifier: region.identifier))
        registered[region.identifier] = nil
    }

    // MARK: What the test asks about

    /// The perimeters registered, in the order they were registered.
    var started: [Perimeter] {
        calls.compactMap { if case .start(let perimeter) = $0 { perimeter } else { nil } }
    }

    var stopped: [String] {
        calls.compactMap { if case .stop(let identifier) = $0 { identifier } else { nil } }
    }

    var prompts: [Call] {
        calls.filter { $0 == .whenInUsePrompt || $0 == .alwaysPrompt }
    }

    /// What iOS would be watching now, by office id.
    var watching: Set<String> { Set(registered.keys) }

    func perimeter(_ identifier: String) -> Perimeter? {
        registered[identifier].map(Perimeter.init)
    }

    func forgetCalls() { calls.removeAll() }
}

/// The notification centre, behind the same kind of recorder. No test in this
/// file may reach the real one: asking it for authorization raises a system
/// prompt on the machine running the tests, and with nobody there to answer it
/// the call never returns.
final class RecordingNotificationCentre: @unchecked Sendable {
    /// What the user will answer the prompt with, set per test.
    var answer = false
    /// What `notificationSettings` will report, set per test.
    var status: UNAuthorizationStatus = .notDetermined

    private(set) var promptsRaised = 0
    private(set) var statusReads = 0

    func prompt() -> Bool {
        promptsRaised += 1
        return answer
    }

    func read() -> UNAuthorizationStatus {
        statusReads += 1
        return status
    }

    /// For a test that has to get the monitor into a known state before the
    /// thing it is measuring: the reads done setting up are not the read it is
    /// asking about.
    func forgetReads() { statusReads = 0 }
}

/// The alerts the ledger would have posted. Nothing reaches the lock screen
/// from a test run.
final class PostedAlerts: @unchecked Sendable {
    var requests: [UNNotificationRequest] = []
}

@Suite("The geofence engine")
@MainActor
struct ArrivalMonitorTests {

    let container: ModelContainer
    let manager: RecordingLocationManager
    let centre: RecordingNotificationCentre
    let posted: PostedAlerts
    let monitor: ArrivalMonitor

    init() throws {
        let container = try Store.makeInMemoryContainer()
        let manager = RecordingLocationManager()
        let centre = RecordingNotificationCentre()
        let posted = PostedAlerts()

        let ledger = ArrivalLedger(context: container.mainContext)
        ledger.post = { posted.requests.append($0) }
        ledger.withdraw = { _ in }

        let monitor = ArrivalMonitor(
            ledger: ledger, context: container.mainContext, manager: manager
        )
        monitor.requestNotificationPermission = { centre.prompt() }
        monitor.readNotificationStatus = { centre.read() }

        self.container = container
        self.manager = manager
        self.centre = centre
        self.posted = posted
        self.monitor = monitor
    }

    // MARK: Fixtures

    let coleman = UUID(uuidString: "B0000000-0000-0000-0000-000000000001")!
    let brussels = UUID(uuidString: "B0000000-0000-0000-0000-000000000002")!

    @discardableResult
    func office(
        _ name: String, id: UUID, latitude: Double = 51.5172,
        longitude: Double = -0.0893, radius: Double = 50, alertEnabled: Bool = true
    ) throws -> Office {
        let office = Office(
            id: id, name: name, address: "", postcode: "",
            latitude: latitude, longitude: longitude, radiusMetres: radius,
            colourHex: OfficeColours.palette[0], alertEnabled: alertEnabled
        )
        container.mainContext.insert(office)
        try container.mainContext.save()
        return office
    }

    /// Always, reported the way iOS reports it — the manager's own status
    /// changes *and* the delegate says so. Setting only the delegate would
    /// leave `escalate` reading a status the phone never had, which is a state
    /// the app can never actually be in.
    func grantAlways() {
        manager.authorizationStatus = .authorizedAlways
        monitor.authorizationChanged(to: .authorizedAlways)
    }

    /// The delegate hands its work to an unstructured `Task`, exactly as it
    /// does when iOS wakes the app for a crossing, so the effect lands a turn
    /// of the main actor later rather than before the call returns. Yielding
    /// until it shows up — rather than sleeping for a guessed interval — keeps
    /// the test honest about that hop and fast when the hop is quick.
    func settle(until landed: () -> Bool) async {
        let deadline = Date().addingTimeInterval(2)
        while !landed(), Date() < deadline {
            await Task.yield()
        }
    }

    /// For the cases where the right answer is that nothing happens. Asserting
    /// immediately would pass even if the alert were merely late, so this waits
    /// out the same hop a real crossing would have taken first.
    func settleFully() async {
        for _ in 0..<50 { await Task.yield() }
    }

    // MARK: Wiring

    /// `allowsBackgroundLocationUpdates` is `true` on the recorder until the
    /// monitor sets it, so this fails if the line is ever dropped. It needs the
    /// background location mode in the entitlements, which this app does not
    /// have and does not want: region monitoring wakes the app by itself, and
    /// setting the flag without the mode is a crash on launch, not a warning.
    @Test("The monitor takes the delegate at birth, and asks for no background updates")
    func wiresItselfUp() {
        #expect(manager.delegate === monitor)
        #expect(manager.allowsBackgroundLocationUpdates == false)
        #expect(manager.calls.isEmpty)
        #expect(ArrivalMonitor.maximumRegions == 20)
    }

    // MARK: Permission

    /// The order is the whole point. Asking for Always from a cold start is
    /// refused by iOS, and a refused prompt cannot be raised again from inside
    /// the app — so getting this backwards costs the feature permanently, on
    /// the first tap, with no way back except deleting the app.
    @Test("Nothing granted yet asks for When In Use, and never for Always")
    func coldStartAsksForWhenInUseOnly() {
        manager.authorizationStatus = .notDetermined
        monitor.requestAuthorization()

        #expect(manager.prompts == [.whenInUsePrompt])
        #expect(monitor.canMonitor == false)
    }

    @Test("When In Use is where the climb to Always begins, not where it stops")
    func whenInUseEscalates() {
        manager.authorizationStatus = .authorizedWhenInUse
        monitor.requestAuthorization()

        #expect(manager.prompts == [.alwaysPrompt])
    }

    /// The negative half of the ladder. A prompt raised against a status that
    /// cannot answer it is a no-op at best; at worst it is the second Always
    /// prompt that iOS silently drops, leaving the user staring at a button
    /// that does nothing.
    @Test("A permission already settled — refused, blocked, or full — is not asked again")
    func settledPermissionsRaiseNoPrompt() {
        for status in [CLAuthorizationStatus.denied, .restricted, .authorizedAlways] {
            manager.authorizationStatus = status
            manager.forgetCalls()
            monitor.requestAuthorization()
            #expect(manager.prompts.isEmpty, "\(status) should raise no prompt")
        }
    }

    /// iOS delivers the answer to the When In Use prompt as a callback, and
    /// that is the moment to ask for Always — while the user is still thinking
    /// about permissions rather than a week later, when a second prompt out of
    /// nowhere reads as the app being pushy.
    @Test("iOS reporting When In Use asks for Always without a second tap")
    func theCallbackContinuesTheClimb() {
        manager.authorizationStatus = .authorizedWhenInUse
        monitor.authorizationChanged(to: .authorizedWhenInUse)

        #expect(manager.prompts == [.alwaysPrompt])
        #expect(monitor.authorization == .authorizedWhenInUse)
    }

    /// Anything short of Always means iOS will not wake the app for a crossing.
    /// When In Use is the trap: it looks like permission was granted, and the
    /// app is only ever running when the user is already looking at it.
    @Test("Only Always lets the app claim the alert will fire")
    func onlyAlwaysCanMonitor() {
        let expected: [(CLAuthorizationStatus, Bool)] = [
            (.notDetermined, false), (.restricted, false), (.denied, false),
            (.authorizedWhenInUse, false), (.authorizedAlways, true),
        ]
        for (status, canMonitor) in expected {
            manager.authorizationStatus = status
            monitor.authorizationChanged(to: status)
            #expect(monitor.authorization == status)
            #expect(monitor.canMonitor == canMonitor, "\(status)")
        }
    }

    /// The location prompt is not the only one the button raises. A user who
    /// grants Always and is never asked about notifications gets woken by iOS
    /// and told nothing — and the offices list said "Alert on · 50m" throughout,
    /// which is the whole reason `notificationsAllowed` exists. The prompt is
    /// raised from an unstructured `Task`, so it lands a turn later than the
    /// location one rather than before the call returns.
    @Test("Asking for the alert asks for both permissions, not only location")
    func requestingTheAlertAsksAboutNotificationsToo() async {
        centre.answer = true
        manager.authorizationStatus = .notDetermined

        monitor.requestAuthorization()
        #expect(manager.prompts == [.whenInUsePrompt])
        await settle { centre.promptsRaised == 1 }

        #expect(centre.promptsRaised == 1, "and exactly once, not once per rung")
        #expect(monitor.notificationsAllowed, "the answer is kept, not dropped")
    }

    /// The negative, and the one that matters: a refusal has to be carried back
    /// too. Firing the prompt and forgetting the answer is what left the app
    /// promising an alert it could not deliver.
    @Test("A refusal of the notification prompt raised alongside location is kept")
    func aRefusalFromTheCombinedRequestIsKept() async {
        centre.answer = false
        manager.authorizationStatus = .authorizedWhenInUse

        monitor.requestAuthorization()
        await settle { centre.promptsRaised == 1 }

        #expect(manager.prompts == [.alwaysPrompt])
        #expect(monitor.notificationsAllowed == false)
    }

    /// iOS may deliver a tapped notification straight into a cold start, so the
    /// delegate has to be on the centre before anything else happens. Set later
    /// — lazily, by a screen — the tap that woke the app is dropped and the
    /// attendance it was answering is never written.
    ///
    /// This is the one test in the file that touches the real notification
    /// centre. It is safe where asking it for authorization is not: setting a
    /// delegate and a category list raises no system prompt and posts nothing.
    @Test("Registration puts the monitor on the centre before any alert can arrive")
    func registrationHappensUpFront() async throws {
        let centre = UNUserNotificationCenter.current()
        centre.delegate = nil

        monitor.registerNotificationHandling()

        #expect(centre.delegate === monitor, "a delegate set later would miss the cold start")

        // Named rather than compared as a set, because the buttons are the
        // point: a category registered without its actions is a bare banner,
        // and "I'm here" is the only thing in the app that records attendance
        // from the lock screen.
        let categories = await centre.notificationCategories()
        let booked = try #require(
            categories.first { $0.identifier == ArrivalNotifications.Category.booked.rawValue }
        )
        #expect(
            booked.actions.map(\.identifier)
                == [
                    ArrivalNotifications.Action.confirm.rawValue,
                    ArrivalNotifications.Action.dismiss.rawValue,
                ]
        )
        #expect(
            Set(categories.map(\.identifier))
                == Set(ArrivalNotifications.categories.map(\.identifier))
        )
    }

    @Test("A refused notification prompt is remembered as refused")
    func theNotificationAnswerIsKept() async {
        centre.answer = false
        await monitor.requestNotificationAuthorization()
        #expect(monitor.notificationsAllowed == false)

        centre.answer = true
        await monitor.requestNotificationAuthorization()
        #expect(monitor.notificationsAllowed == true)
        #expect(centre.promptsRaised == 2)
    }

    /// Only a status that actually delivers counts. `.provisional` does — a
    /// quiet alert still reaches the Notification Centre — while
    /// `.notDetermined` is exactly as silent as `.denied`, which is the case
    /// the pessimistic default exists for.
    @Test("Only a notification permission that delivers is called allowed")
    func statusMapsToWhetherAnythingArrives() async {
        let expected: [(UNAuthorizationStatus, Bool)] = [
            (.authorized, true), (.provisional, true),
            (.denied, false), (.notDetermined, false), (.ephemeral, false),
        ]
        for (status, allowed) in expected {
            centre.status = status
            await monitor.refreshNotificationStatus()
            #expect(monitor.notificationsAllowed == allowed, "\(status.rawValue)")
        }
        #expect(centre.statusReads == expected.count)
    }

    /// Permission can be revoked in Settings while the app is not running, so a
    /// cached yes is the claim this property exists to stop the UI making.
    @Test("A permission taken away in Settings is noticed on the next read")
    func revocationIsNoticed() async {
        centre.status = .authorized
        await monitor.refreshNotificationStatus()
        #expect(monitor.notificationsAllowed == true)

        centre.status = .denied
        await monitor.refreshNotificationStatus()
        #expect(monitor.notificationsAllowed == false)
        #expect(centre.statusReads == 2)
    }

    // MARK: Regions

    @Test("Every located office with its alert on gets a perimeter, and nothing else does")
    func registersTheOfficesThatQualify() throws {
        try office("Coleman", id: coleman)
        try office("Brussels", id: brussels, latitude: 50.8568, longitude: 4.3567, radius: 120)
        let muted = UUID()
        try office("Muted", id: muted, alertEnabled: false)
        let nowhere = UUID()
        // 0,0 is the Atlantic — what an office the geocoder could not find
        // holds. A 50m perimeter round it would fire for nobody, ever.
        try office("Not found", id: nowhere, latitude: 0, longitude: 0)

        grantAlways()

        #expect(manager.watching == [coleman.uuidString, brussels.uuidString])
        #expect(manager.perimeter(muted.uuidString) == nil)
        #expect(manager.perimeter(nowhere.uuidString) == nil)
    }

    /// Entry only, and the coordinates the office actually holds. Waking for
    /// the exit as well would double the wake-ups to learn something the next
    /// entry tells us anyway.
    @Test("A perimeter is the office's own place, its own radius, and entry only")
    func thePerimeterIsTheOffice() throws {
        try office("Brussels", id: brussels, latitude: 50.8568, longitude: 4.3567, radius: 120)
        grantAlways()

        let perimeter = try #require(manager.perimeter(brussels.uuidString))
        #expect(perimeter.latitude == 50.8568)
        #expect(perimeter.longitude == 4.3567)
        #expect(perimeter.radius == 120)
        #expect(perimeter.notifyOnEntry == true)
        #expect(perimeter.notifyOnExit == false)
    }

    /// The negative half of `canMonitor`. Permission dropping back to When In
    /// Use has to take the perimeters down, not leave them up: iOS will not
    /// wake the app for them, so a region still registered is one the app
    /// believes it is watching and is not.
    @Test("Losing Always tears every perimeter down rather than leaving it half-watched")
    func withoutAlwaysNothingIsWatched() throws {
        try office("Coleman", id: coleman)
        grantAlways()
        #expect(manager.watching == [coleman.uuidString])

        manager.forgetCalls()
        manager.authorizationStatus = .authorizedWhenInUse
        monitor.authorizationChanged(to: .authorizedWhenInUse)

        #expect(manager.stopped == [coleman.uuidString])
        #expect(manager.started.isEmpty)
        #expect(manager.watching.isEmpty)
    }

    /// iOS goes on monitoring a perimeter for a deleted office until something
    /// tells it not to — waking the app at a building that no longer belongs to
    /// anything, for as long as the app is installed.
    @Test("A deleted office stops being watched")
    func deletingAnOfficeRemovesItsPerimeter() throws {
        let toGo = try office("Coleman", id: coleman)
        try office("Brussels", id: brussels, latitude: 50.8568, longitude: 4.3567)
        grantAlways()
        #expect(manager.watching == [coleman.uuidString, brussels.uuidString])

        manager.forgetCalls()
        container.mainContext.delete(toGo)
        try container.mainContext.save()
        monitor.refreshRegions()

        #expect(Set(manager.stopped) == [coleman.uuidString, brussels.uuidString])
        #expect(manager.started.map(\.identifier) == [brussels.uuidString])
        #expect(manager.watching == [brussels.uuidString])
    }

    /// Correcting an address at nine in the evening writes new coordinates. If
    /// the old `CLCircularRegion` stays registered, the alert goes on firing at
    /// the previous building's perimeter and never at the corrected one — and
    /// the settings row says "Alert on · 50m" throughout.
    @Test("Moving an office moves its perimeter rather than adding a second")
    func movingAnOfficeReRegistersIt() throws {
        let office = try office("Coleman", id: coleman)
        grantAlways()

        manager.forgetCalls()
        office.latitude = 51.5074
        office.longitude = -0.1278
        office.radiusMetres = 200
        try container.mainContext.save()
        monitor.refreshRegions()

        // Torn down before it went back up: registering over a live identifier
        // is how you end up with the old centre still watched.
        #expect(
            manager.calls.first
                == RecordingLocationManager.Call.stop(identifier: coleman.uuidString)
        )
        #expect(manager.watching == [coleman.uuidString])
        let perimeter = try #require(manager.perimeter(coleman.uuidString))
        #expect(perimeter.latitude == 51.5074)
        #expect(perimeter.longitude == -0.1278)
        #expect(perimeter.radius == 200)
    }

    @Test("Turning an office's alert off takes its perimeter down")
    func mutingAnOfficeRemovesItsPerimeter() throws {
        let office = try office("Coleman", id: coleman)
        grantAlways()
        #expect(manager.watching == [coleman.uuidString])

        manager.forgetCalls()
        office.alertEnabled = false
        try container.mainContext.save()
        monitor.refreshRegions()

        #expect(manager.stopped == [coleman.uuidString])
        #expect(manager.started.isEmpty)
        #expect(manager.watching.isEmpty)
    }

    /// A wholesale rebuild has to be safe to run on every save, because that is
    /// how the editor uses it. Two refreshes in a row must leave the same set —
    /// not a duplicate, and not a gap.
    @Test("Refreshing twice leaves exactly the perimeters one refresh left")
    func refreshIsIdempotent() throws {
        try office("Coleman", id: coleman)
        try office("Brussels", id: brussels, latitude: 50.8568, longitude: 4.3567)
        grantAlways()
        let first = manager.watching

        manager.forgetCalls()
        monitor.refreshRegions()

        #expect(manager.watching == first)
        #expect(Set(manager.stopped) == first)
        #expect(Set(manager.started.map(\.identifier)) == first)
    }

    /// iOS caps region monitoring at twenty per app and rejects the twenty-first
    /// silently. Six offices is the palette's limit so this is headroom today,
    /// but a bulk import that quietly exceeded it would take the app's
    /// perimeters over the edge with nothing on screen to say so.
    @Test("iOS takes twenty regions, so the twenty-first is never offered")
    func stopsAtTheRegionLimit() throws {
        var ids: Set<String> = []
        for index in 0..<25 {
            let id = UUID()
            ids.insert(id.uuidString)
            try office("Office \(index)", id: id, latitude: 51 + Double(index) / 100)
        }
        grantAlways()

        #expect(manager.started.count == ArrivalMonitor.maximumRegions)
        #expect(manager.watching.count == ArrivalMonitor.maximumRegions)
        #expect(manager.watching.isSubset(of: ids))
    }

    // MARK: What is really being watched

    /// The answer the settings row now prints, and the reason it is asked of
    /// CoreLocation rather than of the store: these are the perimeters iOS
    /// actually holds, not the offices the app believes it registered.
    @Test("The watched set is the perimeters CoreLocation holds, named by office")
    func monitoredOfficeIDsNamesTheRegisteredPerimeters() throws {
        try office("Coleman", id: coleman)
        try office("Brussels", id: brussels, latitude: 50.8568, longitude: 4.3567)
        try office("Muted", id: UUID(), alertEnabled: false)

        #expect(monitor.monitoredOfficeIDs.isEmpty, "nothing is watched before Always")

        grantAlways()

        #expect(monitor.monitoredOfficeIDs == [coleman, brussels])
    }

    /// The defect the settings row was blind to, in one test. An office is
    /// added and saved and nothing rebuilds the perimeters — which is exactly
    /// what the office editor used to do — so the store says the alert is on,
    /// located and permitted, and iOS has never heard of the building.
    ///
    /// This is why the set is read from the manager: a set kept alongside
    /// `refreshRegions` would be updated by the same call that was never made,
    /// and would agree with the store all the way to the failure.
    @Test("An office saved without a rebuild is not watched, whatever the store says")
    func anUnregisteredOfficeIsNotWatched() throws {
        try office("Coleman", id: coleman)
        grantAlways()
        #expect(monitor.monitoredOfficeIDs == [coleman])

        let added = try office("Brussels", id: brussels, latitude: 50.8568, longitude: 4.3567)
        #expect(added.alertEnabled && added.isLocated, "the store's answer is a clean yes")
        #expect(
            monitor.monitoredOfficeIDs == [coleman],
            "and CoreLocation's is still no, because nothing told it"
        )

        monitor.refreshRegions()
        #expect(monitor.monitoredOfficeIDs == [coleman, brussels])
    }

    /// Losing Always tears the perimeters down, so the set has to empty with
    /// them. Reporting an office as watched here would put the reassuring line
    /// under an alert iOS will never wake the app for.
    @Test("Nothing is watched once Always is taken away")
    func losingAlwaysEmptiesTheWatchedSet() throws {
        try office("Coleman", id: coleman)
        grantAlways()
        #expect(monitor.monitoredOfficeIDs == [coleman])

        manager.authorizationStatus = .authorizedWhenInUse
        monitor.authorizationChanged(to: .authorizedWhenInUse)

        #expect(monitor.monitoredOfficeIDs.isEmpty)
    }

    /// iOS goes on monitoring a perimeter until told to stop, so a region left
    /// behind by a build that minted identifiers differently arrives here as a
    /// string with no office behind it. It is dropped rather than counted —
    /// counting it would let a stale perimeter vouch for a live office, which
    /// is the opposite of what this set is for.
    @Test("A perimeter whose identifier names no office is not counted as one")
    func aForeignPerimeterIsNotAnOffice() throws {
        try office("Coleman", id: coleman)
        grantAlways()

        for identifier in ["coleman-london", "", coleman.uuidString + "-old"] {
            manager.startMonitoring(for: CLCircularRegion(
                center: CLLocationCoordinate2D(latitude: 51.5172, longitude: -0.0893),
                radius: 50, identifier: identifier
            ))
        }

        #expect(manager.watching.count == 4, "iOS is watching all four")
        #expect(monitor.monitoredOfficeIDs == [coleman], "only one of them names an office")
    }

    // MARK: Crossings

    @Test("A crossing at a known office runs the arrival rule")
    func aCrossingAlerts() throws {
        try office("Coleman", id: coleman)
        grantAlways()

        monitor.entered(regionIdentifier: coleman.uuidString)

        #expect(posted.requests.count == 1)
        #expect(posted.requests.first?.content.subtitle == "You're at Coleman")
        let rows = try container.mainContext.fetch(FetchDescriptor<ArrivalAlert>())
        #expect(rows.map(\.officeID) == [coleman])
    }

    /// The wake-ups outlive the office: iOS keeps delivering for a perimeter it
    /// was never told to drop, and the id in it names nothing.
    @Test("A crossing for an office that no longer exists writes nothing")
    func aCrossingForANothingIsSilent() throws {
        try office("Coleman", id: coleman)
        grantAlways()

        monitor.entered(regionIdentifier: UUID().uuidString)

        #expect(posted.requests.isEmpty)
        #expect(try container.mainContext.fetch(FetchDescriptor<ArrivalAlert>()).isEmpty)
    }

    /// An identifier this app never minted — an older build's scheme, or a
    /// region registered by something else entirely. It must be dropped, not
    /// forced into a `UUID` that would name no office anyway.
    @Test("A region identifier that is not one of ours is ignored")
    func aForeignIdentifierIsIgnored() throws {
        try office("Coleman", id: coleman)
        grantAlways()

        monitor.entered(regionIdentifier: "")
        monitor.entered(regionIdentifier: "coleman-london")
        monitor.entered(regionIdentifier: coleman.uuidString.lowercased() + "-old")

        #expect(posted.requests.isEmpty)
        #expect(try container.mainContext.fetch(FetchDescriptor<ArrivalAlert>()).isEmpty)
    }

    /// The delegate methods are the entry points iOS actually calls, and both
    /// are `nonisolated` because CoreLocation calls them from its own queue.
    /// Driving them here is what proves the hop to the main actor is wired to
    /// the decisions above it, rather than the decisions being reachable only
    /// from a test.
    @Test("The two callbacks CoreLocation makes are wired to the rule")
    func theDelegateIsWired() async throws {
        try office("Coleman", id: coleman)
        // The monitor ignores this argument entirely and uses its own injected
        // manager, which is exactly what makes the seam possible — but the
        // signature demands one, so iOS's own argument is what is handed over.
        let cl = CLLocationManager()
        manager.authorizationStatus = .authorizedAlways

        monitor.locationManager(cl, didChangeAuthorization: .authorizedAlways)
        await settle { monitor.canMonitor }
        #expect(monitor.authorization == .authorizedAlways)
        #expect(manager.watching == [coleman.uuidString])

        let region = CLCircularRegion(
            center: CLLocationCoordinate2D(latitude: 51.5172, longitude: -0.0893),
            radius: 50, identifier: coleman.uuidString
        )
        monitor.locationManager(cl, didEnterRegion: region)
        await settle { !posted.requests.isEmpty }
        #expect(posted.requests.count == 1)
        #expect(posted.requests.first?.content.subtitle == "You're at Coleman")
    }

    /// iOS relaunches the app in the background and calls the delegate from its
    /// own queue, never the main actor. The store and the ledger are both main
    /// actor only, so the hop is not a nicety — without it this is a crash in
    /// the one situation the whole feature exists for.
    @Test("A crossing delivered off the main actor still lands on it")
    func aCrossingArrivesFromAnyQueue() async throws {
        try office("Coleman", id: coleman)
        grantAlways()
        let identifier = coleman.uuidString

        // Built inside the detached task rather than handed to it: neither
        // `CLLocationManager` nor `CLRegion` is `Sendable`, which is the reason
        // the delegate passes an identifier across the hop and not the region.
        await Task.detached {
            let region = CLCircularRegion(
                center: CLLocationCoordinate2D(latitude: 51.5172, longitude: -0.0893),
                radius: 50, identifier: identifier
            )
            monitor.locationManager(CLLocationManager(), didEnterRegion: region)
        }.value
        await settle { !posted.requests.isEmpty }

        #expect(posted.requests.count == 1)
        #expect(posted.requests.first?.content.subtitle == "You're at Coleman")
    }

    /// `-arrival <name>` on the scheme, which is the only way to walk into a
    /// building from a script. It matches loosely on purpose — the launch
    /// argument is typed by a person — but a name that matches nothing has to
    /// stay silent rather than fire at whichever office came back first.
    @Test("The simulated arrival matches an office loosely and nothing at all otherwise")
    func simulatedArrival() throws {
        try office("Coleman", id: coleman)
        try office("Brussels", id: brussels, latitude: 50.8568, longitude: 4.3567)
        grantAlways()

        monitor.simulateEntry(officeNamed: "Frankfurt")
        #expect(posted.requests.isEmpty)

        monitor.simulateEntry(officeNamed: "brus")
        #expect(posted.requests.count == 1)
        #expect(posted.requests.first?.content.subtitle == "You're at Brussels")
    }
}

/// The payload an alert carries and what a tapped button makes of it, driven
/// through the real `request` builder rather than a hand-written dictionary —
/// so the two ends cannot drift apart while both stay green.
@Suite("What an arrival alert carries back")
struct ArrivalPayloadRoundTripTests {

    let officeID = UUID()
    let day = Day(2026, 8, 5)
    let delivered = Date(timeIntervalSince1970: 1_785_000_000)

    func request(bookingID: UUID?) -> UNNotificationRequest {
        ArrivalNotifications.request(
            ArrivalNotifications.content(
                officeName: "Coleman", desk: nil,
                attended: 4, target: 7, monthName: "August"
            ),
            officeID: officeID, day: day, bookingID: bookingID, at: delivered
        )
    }

    /// The case the suite never covered. `request` writes an empty string for
    /// "nothing booked" rather than omitting the key, and the handler leans on
    /// `UUID(uuidString:)` returning nil for it. Pin the sentinel itself, not
    /// just the behaviour: any other placeholder that happens not to parse —
    /// `"none"`, `"-"` — keeps this working by luck, and a 36-character one
    /// would write an `AttendanceDay` pointing at a booking that never existed.
    @Test("An arrival with nothing booked records the day and no booking")
    func theEmptySentinelSurvivesTheRoundTrip() {
        let info = request(bookingID: nil).content.userInfo

        #expect(info[ArrivalNotifications.UserInfo.bookingID] as? String == "")
        #expect(info[ArrivalNotifications.UserInfo.officeID] as? String == officeID.uuidString)
        #expect(info[ArrivalNotifications.UserInfo.day] as? String == "2026-08-05")

        #expect(
            ArrivalNotifications.answer(
                to: ArrivalNotifications.Action.confirm.rawValue,
                userInfo: info, delivered: day
            ) == .record(officeID: officeID, day: day, bookingID: nil)
        )
    }

    /// The other half of the sentinel. A no is an answer *about a booking*, and
    /// there is no booking here — so the empty string must reach the handler as
    /// nothing to decline, rather than as a booking id that names nothing.
    @Test("No, on an arrival with nothing booked, has nothing to answer for")
    func theEmptySentinelCannotBeDeclined() {
        let info = request(bookingID: nil).content.userInfo

        #expect(
            ArrivalNotifications.answer(
                to: ArrivalNotifications.Action.decline.rawValue,
                userInfo: info, delivered: day
            ) == .ignore
        )
    }

    @Test("A booked arrival carries the booking back to the record it writes")
    func aBookedArrivalRoundTrips() {
        let bookingID = UUID()
        let info = request(bookingID: bookingID).content.userInfo

        #expect(info[ArrivalNotifications.UserInfo.bookingID] as? String == bookingID.uuidString)
        #expect(
            ArrivalNotifications.answer(
                to: ArrivalNotifications.Action.confirm.rawValue,
                userInfo: info, delivered: day
            ) == .record(officeID: officeID, day: day, bookingID: bookingID)
        )
        #expect(
            ArrivalNotifications.answer(
                to: ArrivalNotifications.Action.decline.rawValue,
                userInfo: info, delivered: day
            ) == .decline(bookingID: bookingID)
        )
    }
}
