import CoreLocation
import Foundation
import SwiftData
import SwiftUI
import Testing
import UserNotifications
@testable import OfficeDaze

/// The figure under "This month", and the leave line above it.
@Suite("What the settings screen counts")
@MainActor
struct SettingsCountsTests {

    let utc = TimeZone(identifier: "UTC")!
    let brussels = TimeZone(identifier: "Europe/Brussels")!
    let august = Month(year: 2026, month: 8)

    func capture(at instant: Date, _ status: CaptureStatus) -> Capture {
        Capture(receivedAt: instant, status: status)
    }

    func noon(_ day: Day) -> Date {
        day.startOfDayUTC.addingTimeInterval(12 * 3600)
    }

    /// Every capture counts, whatever became of it: a reading that found
    /// nothing was still a reading, and a count that hid the failures would
    /// hide exactly the ones worth knowing about.
    @Test("The month's count includes every reading, including the ones that failed")
    func countsFailuresToo() {
        let reads = SettingsScreen.reads(of: [
            capture(at: noon(Day(2026, 8, 3)), .parsed),
            capture(at: noon(Day(2026, 8, 4)), .failed),
            capture(at: noon(Day(2026, 8, 5)), .pending),
        ], in: august, zone: utc)

        #expect(reads == 3)
    }

    /// The negative: another month's captures are another month's count.
    @Test("A capture from a neighbouring month is not this month's")
    func countIsPerMonth() {
        let captures = [
            capture(at: noon(Day(2026, 7, 31)), .parsed),
            capture(at: noon(Day(2026, 8, 15)), .parsed),
            capture(at: noon(Day(2026, 9, 1)), .parsed),
        ]

        #expect(SettingsScreen.reads(of: captures, in: august, zone: utc) == 1)
        #expect(SettingsScreen.reads(of: captures, in: Month(year: 2026, month: 9), zone: utc) == 1)
        #expect(SettingsScreen.reads(of: [], in: august, zone: utc) == 0)
    }

    /// `receivedAt` is a real instant, so it belongs to the month it was in
    /// where the phone was. Read through the UTC storage codec, a screenshot
    /// taken at half past midnight on the 1st anywhere east of Greenwich fell
    /// in the previous month, and this month's count silently omitted it.
    @Test("A capture just after midnight belongs to the month the phone was in")
    func countIsCountedInTheDevicesZone() {
        // 31 August, 23:30 UTC — half past one on 1 September in Brussels.
        let instant = Day(2026, 8, 31).startOfDayUTC.addingTimeInterval(23.5 * 3600)
        let captures = [capture(at: instant, .parsed)]
        let september = Month(year: 2026, month: 9)

        #expect(SettingsScreen.reads(of: captures, in: september, zone: brussels) == 1)
        #expect(SettingsScreen.reads(of: captures, in: august, zone: brussels) == 0)
        // And a phone in London that night is right to file it under August.
        #expect(SettingsScreen.reads(of: captures, in: august, zone: utc) == 1)
        #expect(SettingsScreen.reads(of: captures, in: september, zone: utc) == 0)
    }

    // MARK: Leave

    @Test("The leave line counts this month's days off, halves included")
    func leaveSummaryCountsThisMonth() {
        #expect(SettingsScreen.leaveSummary([], in: august) == "None this month")
        #expect(SettingsScreen.leaveSummary(
            [LeaveDay(day: Day(2026, 8, 10))], in: august
        ) == "1 day this month")
        #expect(SettingsScreen.leaveSummary([
            LeaveDay(day: Day(2026, 8, 10)),
            LeaveDay(day: Day(2026, 8, 11), fraction: 0.5),
        ], in: august) == "1.5 days this month")
        #expect(SettingsScreen.leaveSummary(
            [LeaveDay(day: Day(2026, 8, 11), fraction: 0.5, kind: .sick)], in: august
        ) == "0.5 days this month", "a day off sick is a day not on prem")
    }

    /// Bank holidays are derived from the calendar rather than booked, and they
    /// are already outside the working days the target is built from — so
    /// counting them here would tell the user they had taken leave they never
    /// asked for. The other month's day is the second way to be excluded.
    @Test("A bank holiday, and another month's leave, are not days off this month")
    func leaveSummaryExcludes() {
        #expect(SettingsScreen.leaveSummary([
            LeaveDay(day: Day(2026, 8, 31), kind: .bankHoliday),
            LeaveDay(day: Day(2026, 9, 1)),
            LeaveDay(day: Day(2026, 7, 31)),
        ], in: august) == "None this month")

        // And with one real day among them, only that one is counted.
        #expect(SettingsScreen.leaveSummary([
            LeaveDay(day: Day(2026, 8, 31), kind: .bankHoliday),
            LeaveDay(day: Day(2026, 9, 1)),
            LeaveDay(day: Day(2026, 8, 12)),
        ], in: august) == "1 day this month")
    }
}

/// The destructive dialog, and the two very different things its buttons do.
@Suite("Deleting data from Settings")
@MainActor
struct SettingsDeleteTests {

    let container: ModelContainer
    let manager: RecordingLocationManager
    let monitor: ArrivalMonitor
    let nudges: NudgeRecorder
    let erasures: WipeRecorder

    /// A `UserDefaults` nobody else is using. `Store.wipe` marks the store
    /// seeded, and doing that to `.standard` would decide whether the *app*
    /// lays the sample month down on the next launch of this simulator.
    let defaults: UserDefaults

    init() throws {
        container = try Store.makeInMemoryContainer(seeded: true)
        manager = RecordingLocationManager()
        nudges = NudgeRecorder()
        erasures = WipeRecorder()
        defaults = UserDefaults(suiteName: "SettingsScreenTests.\(UUID().uuidString)")!

        let ledger = ArrivalLedger(context: container.mainContext)
        ledger.post = { _ in }
        ledger.withdraw = { _ in }
        monitor = ArrivalMonitor(
            ledger: ledger, context: container.mainContext, manager: manager
        )
        // Always, reported the way iOS reports it, so the seeded offices are
        // really being watched before anything is deleted.
        manager.authorizationStatus = .authorizedAlways
        monitor.authorizationChanged(to: .authorizedAlways)
    }

    /// The real `Store.wipe`, reached through the recorder so the tests below
    /// can say which scope, which store and which `UserDefaults` it was handed
    /// — and so one of them can make it throw.
    func wipe(_ scope: Store.Scope) -> SettingsScreen.Wiped {
        SettingsScreen.wipe(
            scope, in: container.mainContext, arrival: monitor, defaults: defaults,
            refreshNudge: { nudges.refresh($0) },
            erase: { try erasures.erase($0, $1, $2) }
        )
    }

    /// One thing outlives the records it was computed from, and it is
    /// invisible: iOS goes on waking the app at a deleted office's perimeter
    /// for as long as the app is installed.
    @Test("Deleting everything takes the offices and their perimeters with it")
    func everythingLeavesNothingWatched() throws {
        let watched = manager.watching
        #expect(watched == [SeedData.colemanID.uuidString, SeedData.brusselsID.uuidString],
                "both seeded offices are being watched to begin with")
        manager.forgetCalls()

        let wiped = wipe(.everything)

        #expect(try container.mainContext.fetchCount(FetchDescriptor<Office>()) == 0)
        #expect(Set(manager.stopped) == watched, "every perimeter is torn down by name")
        #expect(manager.watching.isEmpty, "and none goes back up")
        // The positive half of the fix below. A delete that lands says nothing
        // at all: the emptied screen behind the dialog is the confirmation, and
        // an alert here would be one more tap on the way out of a flow the user
        // has already confirmed twice.
        #expect(wiped.failure == nil, "a delete that worked is silent")
        // And the scope the screen chose is the scope the store was asked for —
        // the one argument that decides whether two buildings survive.
        #expect(erasures.scopes == [.everything])
        #expect(erasures.defaults.first === defaults, "and not the app's own settings")
    }

    /// The other scope, and the reason there are two: the offices are the only
    /// thing in the store that was typed in by hand. Clearing out the sample
    /// month must not cost them.
    @Test("Deleting the records keeps the offices and their perimeters")
    func recordsKeepsWhatWasTypedIn() throws {
        manager.forgetCalls()

        let wiped = wipe(.records)

        #expect(try container.mainContext.fetchCount(FetchDescriptor<Office>()) == 2)
        #expect(try container.mainContext.fetchCount(FetchDescriptor<DeskBooking>()) == 0)
        #expect(manager.watching
                == [SeedData.colemanID.uuidString, SeedData.brusselsID.uuidString],
                "the buildings are still being watched")
        #expect(wiped.failure == nil, "and the narrower delete is silent too")
        #expect(erasures.scopes == [.records], "the narrower scope reaches the store as itself")
    }

    /// The evening reminder is decided from the bookings, so a wipe has to
    /// re-decide it — otherwise tonight's nudge still names a desk that no
    /// longer exists. It is re-decided against the store that was emptied,
    /// which is what the recorded context proves.
    @Test("A wipe re-decides the evening reminder against the store it just emptied")
    func theNudgeIsRebuiltAfterAWipe() throws {
        _ = wipe(.everything)

        #expect(nudges.contexts.count == 1)
        let asked = try #require(nudges.contexts.first)
        #expect(try asked.fetchCount(FetchDescriptor<DeskBooking>()) == 0)
    }

    // MARK: When the delete does not happen

    /// The finding. `try? Store.wipe(...)` dropped the throw on the floor and
    /// then went on to refresh the perimeters and redo the reminder —
    /// reporting, to the character, what a delete that worked reports. So a delete that failed told the user their data was gone while
    /// every row of it was still in the store, which for the one feature in the
    /// app whose entire purpose is removing data is the worst direction to be
    /// wrong in: the person who believes it hands the phone on.
    ///
    /// SwiftData will not fail on demand, which is why `erase` is a parameter.
    @Test("A delete that throws says so rather than reporting the store emptied")
    func aFailedDeleteIsReported() throws {
        let before = try container.mainContext.fetchCount(FetchDescriptor<Office>())
        #expect(before == 2, "there is something here to lose")
        erasures.failing = DiskFull()

        let wiped = wipe(.everything)

        #expect(wiped.failure ==
            "The delete didn't finish: the volume is full. Some of your data, and your offices, "
            + "are still here. Nothing is safely gone — try again."
        )
        // Everything the old code went on to report as though the delete had
        // happened, now checked against what actually happened.
        #expect(try container.mainContext.fetchCount(FetchDescriptor<Office>()) == 2)
        #expect(erasures.scopes == [.everything], "the delete was attempted, not skipped")
    }

    /// The other scope's sentence. The two deletes take different things, so
    /// naming what survived is scope's work.
    @Test("A failed delete names what the user still has, and it differs by scope")
    func theFailureNamesWhatSurvived() {
        erasures.failing = DiskFull()

        let wiped = wipe(.records)

        #expect(wiped.failure ==
            "The delete didn't finish: the volume is full. Some of your bookings, "
            + "attendance and leave are still here. Nothing is safely gone — try again."
        )
        #expect(wiped.failure?.contains("offices") == false,
                "the narrower delete never went near the offices, so its failure must not name them")
        #expect(erasures.scopes == [.records])
        // And the reason is the store's own words rather than a generic
        // apology: a delete refused by a full disk and one refused by a
        // validation failure are different problems with different remedies.
        #expect(
            SettingsScreen.deleteFailure(.records, Unwritable()).contains("the store is read-only")
        )
    }

    /// What the screen does about the *other* two steps when the delete throws,
    /// which is the part that is deliberate rather than incidental. Both are
    /// reconciliations, not celebrations: they bring iOS's registered perimeters
    /// and tonight's reminder into line with whatever the store now holds. A
    /// throw says the delete did not finish, not that it did not start, so
    /// skipping them would leave the app being woken at a deleted office's
    /// perimeter with no later screen left to trigger a rebuild.
    @Test("A delete that failed still reconciles the perimeters and the reminder it left behind")
    func aFailedDeleteStillPutsTheOutsideWorldInStep() throws {
        manager.forgetCalls()
        erasures.failing = DiskFull()

        let wiped = wipe(.everything)

        #expect(wiped.failure != nil)
        #expect(manager.watching
                == [SeedData.colemanID.uuidString, SeedData.brusselsID.uuidString],
                "the offices that survived are watched again, not abandoned")
        // The reminder is re-decided against the store as it really is — which,
        // this time, is a store with the bookings still in it.
        #expect(nudges.contexts.count == 1)
        let asked = try #require(nudges.contexts.first)
        #expect(try asked.fetchCount(FetchDescriptor<DeskBooking>()) > 0,
                "and it was re-decided from the bookings that are still there")
    }

    /// The button has to name what it would take. "Everything" over two
    /// buildings someone typed in themselves is the dialog understating the
    /// loss.
    @Test("The destructive button names the offices it would take")
    func everythingTitleNamesTheOffices() {
        #expect(SettingsScreen.everythingTitle(officeCount: 0) == "Everything")
        #expect(SettingsScreen.everythingTitle(officeCount: 1)
                == "Everything, including 1 office")
        #expect(SettingsScreen.everythingTitle(officeCount: 3)
                == "Everything, including 3 offices")
    }
}

/// `NudgeScheduler.refresh` behind a recorder, so no test in this file reaches
/// the real notification centre or the real `UserDefaults` — and so the wipe
/// can be asked *which* store it re-decided the reminder against.
final class NudgeRecorder: @unchecked Sendable {
    private(set) var contexts: [ModelContext] = []

    func refresh(_ context: ModelContext) { contexts.append(context) }
}

/// `Store.wipe` behind a recorder that can be made to fail.
///
/// It is not a stub: with `failing` unset it calls the real `Store.wipe` with
/// the very arguments it was handed, so every test that goes through it is
/// still asserting against a store that was genuinely emptied. What it adds is
/// the two things a real delete cannot give a test — a throw on demand, and the
/// arguments in a form that can be asserted on. The scope is the one that
/// matters most: it decides whether two buildings someone typed in survive, and
/// a double that ignored it would pass every assertion here while the screen
/// passed `.everything` for both buttons.
@MainActor
final class WipeRecorder {
    private(set) var scopes: [Store.Scope] = []
    private(set) var contexts: [ModelContext] = []
    private(set) var defaults: [UserDefaults] = []
    /// Set to make the next delete throw, standing in for a full disk or a
    /// validation failure. There is no way to provoke either from SwiftData.
    var failing: Error?

    func erase(_ scope: Store.Scope, _ context: ModelContext, _ defaults: UserDefaults) throws {
        scopes.append(scope)
        contexts.append(context)
        self.defaults.append(defaults)
        if let failing { throw failing }
        try Store.wipe(context, scope: scope, defaults: defaults)
    }
}

/// The throw itself, worded the way a `localizedDescription` is: it lands
/// mid-sentence in the alert, so the tests above can assert the whole line the
/// user reads rather than a prefix of it.
struct DiskFull: LocalizedError {
    var errorDescription: String? { "the volume is full" }
}

/// A second, different reason — because the alert quotes the store rather than
/// apologising generically, and a delete refused by a full disk and one refused
/// by a read-only store are different problems with different remedies.
struct Unwritable: LocalizedError {
    var errorDescription: String? { "the store is read-only" }
}

/// The office rows, and the row above them that appears when the alert cannot
/// fire at all.
@Suite("What the offices list says about the arrival alert")
@MainActor
struct SettingsArrivalRowTests {

    let container: ModelContainer
    let manager: RecordingLocationManager
    let centre: RecordingNotificationCentre
    let monitor: ArrivalMonitor

    init() throws {
        let container = try Store.makeInMemoryContainer()
        let manager = RecordingLocationManager()
        // Local, then handed over at the end: a closure that captured
        // `self.centre` would be capturing a struct still being initialised.
        let centre = RecordingNotificationCentre()

        let ledger = ArrivalLedger(context: container.mainContext)
        ledger.post = { _ in }
        ledger.withdraw = { _ in }
        let monitor = ArrivalMonitor(
            ledger: ledger, context: container.mainContext, manager: manager
        )
        monitor.readNotificationStatus = { centre.read() }

        self.container = container
        self.manager = manager
        self.centre = centre
        self.monitor = monitor
    }

    /// Stored and registered, the way the office editor leaves one: inserted,
    /// saved, and the perimeters rebuilt. An office built in memory and never
    /// registered is not "an office with the alert on" — it is the very state
    /// the `.notWatched` rung exists to report, so every test below that means
    /// something else has to go through here.
    @discardableResult
    func office(
        _ name: String, latitude: Double = 51.5172, longitude: Double = -0.0893,
        radius: Double = 50, alertEnabled: Bool = true
    ) throws -> Office {
        let office = Office(
            name: name, address: "", postcode: "", latitude: latitude,
            longitude: longitude, radiusMetres: radius,
            colourHex: OfficeColours.palette[0], alertEnabled: alertEnabled
        )
        container.mainContext.insert(office)
        try container.mainContext.save()
        monitor.refreshRegions()
        return office
    }

    func grant(location: CLAuthorizationStatus, notifications: UNAuthorizationStatus) async {
        manager.authorizationStatus = location
        monitor.authorizationChanged(to: location)
        centre.status = notifications
        await monitor.refreshNotificationStatus()
    }

    /// The row reads two permissions and the office's own two fields, and every
    /// one of them can be wired to the wrong argument without the ladder itself
    /// changing at all — which is how "Alert on · 50m" came to be printed in the
    /// reassuring green over an alert that could never arrive.
    @Test("Each reason the alert cannot fire reaches the row that has to explain it")
    func everyBlockedStateIsNamed() async throws {
        let located = try office("Coleman")

        await grant(location: .notDetermined, notifications: .notDetermined)
        #expect(SettingsScreen.readiness(located, arrival: monitor) == .needsLocation)

        // When In Use is the trap: it looks granted, and iOS will never wake
        // the app for a crossing.
        await grant(location: .authorizedWhenInUse, notifications: .authorized)
        #expect(SettingsScreen.readiness(located, arrival: monitor) == .needsLocation)

        await grant(location: .authorizedAlways, notifications: .denied)
        #expect(SettingsScreen.readiness(located, arrival: monitor) == .needsNotifications)

        await grant(location: .authorizedAlways, notifications: .authorized)
        // 0,0 is the Atlantic — what an office the geocoder could not find
        // holds, so it is the absence of a location rather than one. Both
        // halves have to be zero: an office on the Greenwich meridian has a
        // longitude of 0 and is perfectly well located.
        #expect(SettingsScreen.readiness(
            try office("Nowhere", latitude: 0, longitude: 0), arrival: monitor
        ) == .notLocated)
        #expect(SettingsScreen.readiness(
            try office("Greenwich", latitude: 51.4779, longitude: 0), arrival: monitor
        ) == .ready(radiusMetres: 50))
        #expect(SettingsScreen.readiness(
            try office("Muted", alertEnabled: false), arrival: monitor
        ) == .off)

        for readiness in [
            AlertReadiness.needsLocation, .needsNotifications, .notLocated, .notWatched, .off,
        ] {
            #expect(!readiness.willFire, "\(readiness) is not green")
        }
    }

    /// The positive, and the one argument a shared ladder can most easily get
    /// wrong: each row has to print *its own* office's perimeter.
    @Test("A row that will fire says so, with its own office's radius")
    func aReadyRowNamesItsOwnPerimeter() async throws {
        await grant(location: .authorizedAlways, notifications: .authorized)

        let coleman = try office("Coleman", radius: 50)
        let brussels = try office("Brussels", latitude: 50.8568, radius: 120)

        #expect(SettingsScreen.readiness(coleman, arrival: monitor) == .ready(radiusMetres: 50))
        #expect(SettingsScreen.readiness(brussels, arrival: monitor) == .ready(radiusMetres: 120))
        #expect(SettingsScreen.readiness(brussels, arrival: monitor).text == "Alert on · 120m")
        #expect(SettingsScreen.readiness(coleman, arrival: monitor).willFire)
    }

    /// `.provisional` delivers quietly but it does deliver, so the alert really
    /// will reach the user and the row is right to say so. This is the state a
    /// row that compared against `.authorized` alone would call broken.
    @Test("A quietly-delivered alert is still an alert that arrives")
    func provisionalNotificationsAreEnough() async throws {
        await grant(location: .authorizedAlways, notifications: .provisional)

        #expect(SettingsScreen.readiness(try office("Coleman"), arrival: monitor)
                == .ready(radiusMetres: 50))
    }

    // MARK: What CoreLocation is really watching

    /// The finding this pair of files was opened for. Everything the row used to
    /// ask is a clean yes — the toggle is on, the office has coordinates, both
    /// permissions are granted — and no perimeter has been registered, because
    /// nothing rebuilt them after the office was saved. That is exactly the
    /// state the missing `refreshRegions` call left the app in for a week, and
    /// the row printed "Alert on · 50m" in the reassuring green throughout.
    @Test("An office nothing registered says so rather than promising a 50m alert")
    func anUnwatchedOfficeIsNotReported() async throws {
        await grant(location: .authorizedAlways, notifications: .authorized)

        let added = Office(
            name: "Frankfurt", address: "", postcode: "", latitude: 50.1109,
            longitude: 8.6821, radiusMetres: 50,
            colourHex: OfficeColours.palette[0], alertEnabled: true
        )
        container.mainContext.insert(added)
        try container.mainContext.save()
        // Deliberately no `refreshRegions` — this is the office editor as it
        // was, and every input the old row read is now true.
        #expect(added.alertEnabled && added.isLocated)
        #expect(monitor.canMonitor && monitor.notificationsAllowed)

        let state = SettingsScreen.readiness(added, arrival: monitor)
        #expect(state == .notWatched)
        #expect(state.text == "Alert on · not being watched yet")
        #expect(!state.willFire, "and it is not in the colour that promises an alert")

        // And the rebuild is what makes the promise good.
        monitor.refreshRegions()
        #expect(SettingsScreen.readiness(added, arrival: monitor) == .ready(radiusMetres: 50))
    }

    /// The negative, and the one that stops the new rung being an alarm that is
    /// always on: a second office being watched must not vouch for the first.
    /// Wiring `isWatched` to "anything at all is registered" would pass every
    /// test above and leave the defect exactly where it was.
    @Test("One office being watched does not make its neighbour watched")
    func theWatchedSetIsPerOffice() async throws {
        await grant(location: .authorizedAlways, notifications: .authorized)
        let coleman = try office("Coleman")

        let frankfurt = Office(
            name: "Frankfurt", address: "", postcode: "", latitude: 50.1109,
            longitude: 8.6821, radiusMetres: 50,
            colourHex: OfficeColours.palette[0], alertEnabled: true
        )
        container.mainContext.insert(frankfurt)
        // Not saved and not registered, so the store's own fetch does not see
        // it either — the point is that the answer is looked up by id.
        #expect(manager.watching == [coleman.id.uuidString])

        #expect(SettingsScreen.readiness(coleman, arrival: monitor) == .ready(radiusMetres: 50))
        #expect(SettingsScreen.readiness(frankfurt, arrival: monitor) == .notWatched)
    }

    /// Ordering. A switched-off office has no perimeter either, so asking about
    /// the perimeter first would answer "not being watched yet" for an alert the
    /// user turned off on purpose — burying the only reason that is actionable.
    @Test("The reason given is the one the user can act on, not the perimeter")
    func theWatchedRungComesLast() async throws {
        await grant(location: .authorizedAlways, notifications: .authorized)

        #expect(SettingsScreen.readiness(
            try office("Muted", alertEnabled: false), arrival: monitor
        ) == .off, "nothing is watched here either, and the toggle is the reason")
        #expect(SettingsScreen.readiness(
            try office("Nowhere", latitude: 0, longitude: 0), arrival: monitor
        ) == .notLocated, "nor here, and the missing address is the reason")

        await grant(location: .authorizedWhenInUse, notifications: .authorized)
        #expect(SettingsScreen.readiness(
            try office("Coleman"), arrival: monitor
        ) == .needsLocation, "losing Always tears the perimeters down; permission is the reason")
    }

    // MARK: The permission row

    /// A refusal and an unanswered prompt need different remedies, and only one
    /// of them can be fixed from inside the app. iOS will not raise a prompt it
    /// has already had refused, so a button that asked again there would do
    /// nothing at all, for ever, with nothing on screen to say why.
    @Test("The permission row sends a refusal to Settings and an unasked prompt to iOS")
    func thePermissionRowMatchesTheRemedyToTheState() {
        let expected: [(CLAuthorizationStatus, String, Bool)] = [
            (.denied, "Open Settings", true),
            (.restricted, "Open Settings", true),
            (.authorizedWhenInUse, "Allow Always", false),
            (.notDetermined, "Allow", false),
        ]
        for (status, title, opensSettings) in expected {
            #expect(SettingsScreen.grantTitle(status) == title, "\(status)")
            #expect(SettingsScreen.opensSettings(status) == opensSettings, "\(status)")
            #expect(
                SettingsScreen.permissionText(status)
                    == (opensSettings
                        ? "Location access is off — the arrival alert can't fire"
                        : "The arrival alert needs \"Always\" location access"),
                "\(status)"
            )
        }
    }
}

// MARK: - Drawing the screen

/// The settings screen with its body actually running.
///
/// Nothing this screen does on open reaches outside the store and the two
/// recorders below: the reminder's notification centre and the arrival
/// monitor's. It once read and rewrote a live API key on open as well, which
/// is why the render is held to touching nothing it was not handed.
@Suite("Drawing the settings screen")
@MainActor
struct SettingsScreenRenderTests {

    let container: ModelContainer
    let manager: RecordingLocationManager
    let centre: RecordingNotificationCentre
    let monitor: ArrivalMonitor

    init() throws {
        let container = try Store.makeInMemoryContainer()
        let manager = RecordingLocationManager()
        let centre = RecordingNotificationCentre()

        let ledger = ArrivalLedger(context: container.mainContext)
        ledger.post = { _ in }
        ledger.withdraw = { _ in }
        let monitor = ArrivalMonitor(
            ledger: ledger, context: container.mainContext, manager: manager
        )
        monitor.readNotificationStatus = { centre.read() }
        monitor.requestNotificationPermission = { centre.prompt() }

        self.container = container
        self.manager = manager
        self.centre = centre
        self.monitor = monitor
    }

    /// In a window and made key. A `UIHostingController` laid out on its own
    /// never evaluates the body, so the same helper written without this
    /// executes nothing and every assertion after it passes for the wrong
    /// reason.
    ///
    /// The window is held for the life of the test rather than dropped on
    /// return: `.task` is asynchronous, and a deallocated window takes the view
    /// — and the task — down before it has run.
    @discardableResult
    func render() -> UIWindow {
        // The evening reminder is reached through `NudgeScheduler`'s statics,
        // which are the real notification centre by default. Whether `.task`
        // finds the reminder switched on depends on this simulator's
        // `UserDefaults`, which other suites in this target write to — so both
        // ends are stubbed rather than assumed, and nothing this render does
        // can post or withdraw a real notification. Nothing here asserts on
        // them; they are here to keep the render from having side effects.
        NudgeScheduler.schedule = { _ in }
        NudgeScheduler.withdraw = {}

        let window = ArrivalPreviewRenderTests.renderWindow()
        window.rootViewController = UIHostingController(
            rootView: AnyView(
                NavigationStack { SettingsScreen() }
                    .modelContainer(container)
                    .environment(monitor)
            )
        )
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        return window
    }

    /// `.task` runs after the body, on the main actor, so its effects land a
    /// turn later. Yielding until they show up — rather than sleeping for a
    /// guessed interval — keeps the test honest about that hop and fast when
    /// the hop is quick.
    func settle(until landed: () -> Bool) async {
        let deadline = Date().addingTimeInterval(5)
        while !landed(), Date() < deadline {
            await Task.yield()
        }
    }

    @discardableResult
    func office(
        _ name: String, latitude: Double = 51.5172, longitude: Double = -0.0893,
        alertEnabled: Bool = true
    ) throws -> Office {
        let office = Office(
            name: name, address: "63 Coleman Street", postcode: "EC2R 5BB",
            latitude: latitude, longitude: longitude, radiusMetres: 50,
            colourHex: OfficeColours.palette[0], alertEnabled: alertEnabled
        )
        container.mainContext.insert(office)
        try container.mainContext.save()
        return office
    }

    func grant(location: CLAuthorizationStatus, notifications: UNAuthorizationStatus) async {
        manager.authorizationStatus = location
        monitor.authorizationChanged(to: location)
        centre.status = notifications
        await monitor.refreshNotificationStatus()
        // Read back by `.task` again a moment later, so the count below starts
        // from a known place rather than from however the fixture got here.
        centre.forgetReads()
    }

    /// What the store held before the screen drew, so the tests below can say
    /// it holds the same afterwards.
    func census() throws -> [Int] {
        let context = container.mainContext
        return [
            try context.fetchCount(FetchDescriptor<Office>()),
            try context.fetchCount(FetchDescriptor<DeskBooking>()),
            try context.fetchCount(FetchDescriptor<AttendanceDay>()),
            try context.fetchCount(FetchDescriptor<LeaveDay>()),
            try context.fetchCount(FetchDescriptor<Capture>()),
        ]
    }

    // MARK: What drawing it does to everything else

    /// The claim in `.task`'s own comment: the notification permission is
    /// re-read on every appearance and not cached, because it can be revoked in
    /// iOS Settings while this screen is merely backgrounded — and the row above
    /// exists to stop the app claiming an alert works when it does not.
    @Test("Drawing the screen re-reads the notification permission rather than trusting it")
    func drawingRereadsTheNotificationPermission() async throws {
        try office("Coleman")
        await grant(location: .authorizedAlways, notifications: .authorized)
        #expect(monitor.notificationsAllowed)

        // Revoked behind the app's back, exactly as iOS Settings would.
        centre.status = .denied
        let window = render()
        // Held for the body of the test — `.task` is asynchronous and a window
        // dropped on return takes the view down before it runs — but taken
        // apart on the way out. A key window outlives the container it was
        // handed, and its `@Query` is still subscribed when a later suite
        // saves: the notification lands in a dead observer and takes the whole
        // test host with it, reported against whichever test was saving.
        defer { ArrivalPreviewRenderTests.dismantle(window, holding: container) }
        await settle { centre.statusReads > 0 }

        #expect(centre.statusReads == 1)
        #expect(monitor.notificationsAllowed == false, "the screen noticed rather than cached")
        // And the row it draws for that office now names the reason.
        let stored = try container.mainContext.fetch(FetchDescriptor<Office>())
        let coleman = try #require(stored.first)
        #expect(SettingsScreen.readiness(coleman, arrival: monitor) == .needsNotifications)
    }

    /// A settings screen counts things: this month's captures, the month's
    /// leave, what a delete would take. Counting must not become writing. The
    /// dangerous half is the destructive dialog, which is built by `body` and is
    /// two taps from taking every office in the store.
    @Test("Drawing the screen counts the store without changing a row of it")
    func drawingWritesNothingToTheStore() async throws {
        let coleman = try office("Coleman")
        try office("Brussels", latitude: 50.8568, longitude: 4.3567)
        let context = container.mainContext
        context.insert(DeskBooking(
            officeID: coleman.id, day: .today, deskID: "2-090", source: .manual
        ))
        context.insert(LeaveDay(day: Day.today))
        context.insert(Capture(receivedAt: .now, status: .parsed))
        try context.save()
        await grant(location: .authorizedAlways, notifications: .authorized)

        let before = try census()
        let window = render()
        // Held for the body of the test — `.task` is asynchronous and a window
        // dropped on return takes the view down before it runs — but taken
        // apart on the way out. A key window outlives the container it was
        // handed, and its `@Query` is still subscribed when a later suite
        // saves: the notification lands in a dead observer and takes the whole
        // test host with it, reported against whichever test was saving.
        defer { ArrivalPreviewRenderTests.dismantle(window, holding: container) }
        await settle { centre.statusReads > 0 }
        for _ in 0..<50 { await Task.yield() }

        #expect(try census() == before, "drawing the delete button does not press it")
        #expect(before == [2, 1, 0, 1, 1], "and there was something there to lose")
    }

    /// The empty screen, which is the first thing a new install draws: no
    /// offices, so no permission row and no preview link, and every count on
    /// zero. It is the branch most likely to be wrong and least likely to be
    /// looked at, because the developer's own store is never empty.
    @Test("A store with nothing in it draws, and the summaries say so")
    func anEmptyStoreDraws() async throws {
        await grant(location: .notDetermined, notifications: .notDetermined)

        let window = render()
        // Held for the body of the test — `.task` is asynchronous and a window
        // dropped on return takes the view down before it runs — but taken
        // apart on the way out. A key window outlives the container it was
        // handed, and its `@Query` is still subscribed when a later suite
        // saves: the notification lands in a dead observer and takes the whole
        // test host with it, reported against whichever test was saving.
        defer { ArrivalPreviewRenderTests.dismantle(window, holding: container) }
        await settle { centre.statusReads > 0 }

        #expect(try census() == [0, 0, 0, 0, 0])
        #expect(SettingsScreen.leaveSummary([], in: Day.today.month_) == "None this month")
        #expect(SettingsScreen.reads(of: [], in: Day.today.month_) == 0)
        #expect(SettingsScreen.everythingTitle(officeCount: 0) == "Everything",
                "with no offices the destructive button has nothing extra to name")
    }

    /// The permission row's own branch — drawn only when there is an office to
    /// alert about, because "the arrival alert needs Always" is meaningless
    /// advice to someone who has not added a building yet.
    @Test("An office without Always draws the row that says why, and its remedy")
    func theBlockedStateDraws() async throws {
        let coleman = try office("Coleman")
        await grant(location: .denied, notifications: .authorized)

        let window = render()
        // Held for the body of the test — `.task` is asynchronous and a window
        // dropped on return takes the view down before it runs — but taken
        // apart on the way out. A key window outlives the container it was
        // handed, and its `@Query` is still subscribed when a later suite
        // saves: the notification lands in a dead observer and takes the whole
        // test host with it, reported against whichever test was saving.
        defer { ArrivalPreviewRenderTests.dismantle(window, holding: container) }
        await settle { centre.statusReads > 0 }

        #expect(monitor.canMonitor == false)
        #expect(manager.watching.isEmpty, "a refusal takes the perimeters down with it")
        #expect(SettingsScreen.readiness(coleman, arrival: monitor) == .needsLocation)
        #expect(SettingsScreen.permissionText(monitor.authorization)
                == "Location access is off — the arrival alert can't fire")
        #expect(SettingsScreen.grantTitle(monitor.authorization) == "Open Settings")
        #expect(SettingsScreen.opensSettings(monitor.authorization),
                "iOS will not raise a prompt it has already had refused")
    }
}
