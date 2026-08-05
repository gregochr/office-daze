import Foundation
import SwiftData
import Testing
import UserNotifications
@testable import Travel8tor

@Suite("Arrival rule")
struct ArrivalRuleTests {

    let ropemaker = SeedData.ropemakerPlaceID
    let elsewhere = UUID()
    let wednesday = Day(2026, 8, 5)

    func desk(
        _ day: Day = Day(2026, 8, 5), at place: UUID? = nil, id: String = "3C-114"
    ) -> ArrivalRule.DeskBooking {
        ArrivalRule.DeskBooking(
            id: UUID(), placeID: place ?? ropemaker, day: day,
            deskID: id, floor: "3", zone: "C"
        )
    }

    // MARK: The fire-once rule

    @Test("A ledger row for today silences the alert — that is the whole rule")
    func ledgerSilences() {
        let input = ArrivalRule.Input(
            day: wednesday, placeID: ropemaker,
            ledger: [(day: wednesday, placeID: ropemaker)],
            deskBookings: [desk()]
        )
        #expect(ArrivalRule.decide(input) == .doNothing(.alreadyFiredToday))
    }

    @Test("Yesterday's row does not silence today")
    func ledgerIsPerDay() {
        let input = ArrivalRule.Input(
            day: wednesday, placeID: ropemaker,
            ledger: [(day: wednesday.adding(days: -1), placeID: ropemaker)],
            deskBookings: [desk()]
        )
        #expect(ArrivalRule.decide(input) == .offerBooked(input.deskBookings[0]))
    }

    @Test("A row for another building does not silence this one")
    func ledgerIsPerPlace() {
        let input = ArrivalRule.Input(
            day: wednesday, placeID: ropemaker,
            ledger: [(day: wednesday, placeID: elsewhere)],
            deskBookings: [desk()]
        )
        #expect(ArrivalRule.decide(input) == .offerBooked(input.deskBookings[0]))
    }

    @Test("A lunch run does not re-fire, but EVERY ARRIVAL says otherwise")
    func fireRate() {
        // The design's own words: spent once delivered, lunch runs do not
        // re-fire — unless you asked for every crossing.
        let ledger = [(day: wednesday, placeID: ropemaker)]

        let once = ArrivalRule.Input(
            day: wednesday, placeID: ropemaker, ledger: ledger,
            deskBookings: [desk()], fireRate: .firstArrivalOnly
        )
        #expect(ArrivalRule.decide(once) == .doNothing(.alreadyFiredToday))

        let every = ArrivalRule.Input(
            day: wednesday, placeID: ropemaker, ledger: ledger,
            deskBookings: [desk()], fireRate: .everyArrival
        )
        #expect(every.deskBookings.first.map(ArrivalRule.Decision.offerBooked) == ArrivalRule.decide(every))

        // Persist-all-day honours the ledger too: the Live Activity it starts
        // is additive to the once-a-day alert, not a second way to fire.
        let persist = ArrivalRule.Input(
            day: wednesday, placeID: ropemaker, ledger: ledger,
            deskBookings: [desk()], fireRate: .persistAllDay
        )
        #expect(ArrivalRule.decide(persist) == .doNothing(.alreadyFiredToday))
    }

    // MARK: What gets offered

    @Test("A desk booked here today is offered")
    func bookedOffer() {
        let booking = desk()
        let input = ArrivalRule.Input(
            day: wednesday, placeID: ropemaker, deskBookings: [booking]
        )
        #expect(ArrivalRule.decide(input) == .offerBooked(booking))
    }

    @Test("Nothing booked inverts the prompt rather than staying silent")
    func invertedPrompt() {
        // Arrive with nothing booked and the offer becomes "log the day".
        let input = ArrivalRule.Input(day: wednesday, placeID: ropemaker, deskBookings: [])
        #expect(ArrivalRule.decide(input) == .offerUnbooked)
    }

    @Test("A desk booked at a different building is not this building's desk")
    func wrongBuilding() {
        let input = ArrivalRule.Input(
            day: wednesday, placeID: ropemaker,
            deskBookings: [desk(at: elsewhere)]
        )
        #expect(ArrivalRule.decide(input) == .offerUnbooked)
    }

    @Test("A day already on the count is not offered again")
    func alreadyAttended() {
        // Re-offering a counted day invites a double entry.
        let input = ArrivalRule.Input(
            day: wednesday, placeID: ropemaker,
            deskBookings: [desk()], attendedDays: [wednesday]
        )
        #expect(ArrivalRule.decide(input) == .doNothing(.alreadyAttended))
    }

    @Test("Disabled means silent, whatever else is true")
    func disabled() {
        let input = ArrivalRule.Input(
            day: wednesday, placeID: ropemaker, deskBookings: [desk()], enabled: false
        )
        #expect(ArrivalRule.decide(input) == .doNothing(.disabled))
    }

    // MARK: The ledger row

    @Test("Both offers write a ledger row; silence writes nothing")
    func ledgerWrites() {
        // The inverted prompt writes a row too, so a day you declined to log
        // does not ask again at 14:00.
        #expect(ArrivalRule.writesLedgerRow(.offerBooked(desk())))
        #expect(ArrivalRule.writesLedgerRow(.offerUnbooked))
        #expect(!ArrivalRule.writesLedgerRow(.doNothing(.alreadyFiredToday)))
        #expect(!ArrivalRule.writesLedgerRow(.doNothing(.disabled)))
    }
}

@Suite("Arrival ledger")
@MainActor
struct ArrivalLedgerTests {

    let container: ModelContainer
    let ledger: ArrivalLedger
    let wednesday = Day(2026, 8, 5)

    init() throws {
        container = try Store.makeInMemoryContainer(seeded: true)
        // No CLLocationManager anywhere in this suite — the sequence
        // under test does not need one.
        ledger = ArrivalLedger(context: container.mainContext)
    }

    /// Captures what would have been posted instead of touching the real
    /// notification centre.
    final class Delivered: @unchecked Sendable {
        var contents: [UNMutableNotificationContent] = []
    }

    func capturing() -> Delivered {
        let delivered = Delivered()
        ledger.deliver = { content in delivered.contents.append(content) }
        return delivered
    }

    @Test("Entering on a booked day offers the desk and writes one ledger row")
    func firstEntry() async throws {
        let delivered = capturing()
        await ledger.handleEntry(placeID: SeedData.ropemakerPlaceID, day: wednesday)

        #expect(delivered.contents.count == 1)
        let content = try #require(delivered.contents.first)
        #expect(content.title == "TARGET ACQUIRED")
        #expect(content.body.contains("ROPEMAKER PLACE"))
        #expect(content.body.contains("3C-114"), "the desk id is the point of the alert")
        #expect(content.categoryIdentifier == ArrivalNotifications.Category.booked.rawValue)

        let ledger = try container.mainContext.fetch(FetchDescriptor<ArrivalAlert>())
        #expect(ledger.count == 1)
        #expect(ledger[0].day == wednesday)
    }

    @Test("Re-entering the same day is silent and writes no second row")
    func reEntryIsSilent() async throws {
        let delivered = capturing()
        await ledger.handleEntry(placeID: SeedData.ropemakerPlaceID, day: wednesday)
        // Back from lunch.
        await ledger.handleEntry(placeID: SeedData.ropemakerPlaceID, day: wednesday)

        #expect(delivered.contents.count == 1, "spent once delivered")
        #expect(try container.mainContext.fetchCount(FetchDescriptor<ArrivalAlert>()) == 1)
        #expect(ledger.lastDecision == .doNothing(.alreadyFiredToday))
    }

    @Test("Arriving writes no attendance — the geofence offers, it does not record")
    func neverWritesSilently() async throws {
        // The single most important assertion in this file. The handoff's
        // sequence says to write an AttendanceDay on delivery for a booked day;
        // the brief says attendance is never written silently, and the brief
        // wins. A geofence hit at the wrong building, or walking past on a
        // Sunday, must not quietly move the count.
        let before = try container.mainContext.fetchCount(FetchDescriptor<AttendanceDay>())
        _ = capturing()

        await ledger.handleEntry(placeID: SeedData.ropemakerPlaceID, day: wednesday)

        #expect(
            try container.mainContext.fetchCount(FetchDescriptor<AttendanceDay>()) == before,
            "nothing is recorded until the offer is accepted"
        )
    }

    @Test("Confirming is what writes the attendance record")
    func confirmationWrites() throws {
        let before = try container.mainContext.fetchCount(FetchDescriptor<AttendanceDay>())

        let wrote = ledger.confirmAttendance(
            placeID: SeedData.ropemakerPlaceID, bookingID: nil, day: wednesday
        )

        #expect(wrote)
        let after = try container.mainContext.fetch(FetchDescriptor<AttendanceDay>())
        #expect(after.count == before + 1)
        let record = try #require(after.first { $0.day == wednesday })
        #expect(record.source == .geofence)
        #expect(record.fraction == 1.0)
    }

    @Test("Confirming twice does not double-count the day")
    func confirmationIsIdempotent() throws {
        #expect(ledger.confirmAttendance(placeID: SeedData.ropemakerPlaceID, bookingID: nil, day: wednesday))
        #expect(!ledger.confirmAttendance(placeID: SeedData.ropemakerPlaceID, bookingID: nil, day: wednesday))

        let days = try container.mainContext.fetch(FetchDescriptor<AttendanceDay>())
            .filter { $0.day == wednesday }
        #expect(days.count == 1)
    }

    @Test("An unbooked arrival inverts the prompt and still fires once")
    func unbookedArrival() async throws {
        let delivered = capturing()
        // Sunday: nothing booked anywhere.
        let sunday = Day(2026, 8, 9)
        await ledger.handleEntry(placeID: SeedData.ropemakerPlaceID, day: sunday)

        let content = try #require(delivered.contents.first)
        #expect(content.title.contains("NO BOOKING"))
        #expect(content.categoryIdentifier == ArrivalNotifications.Category.unbooked.rawValue)

        // Declining still spends the day — it must not ask again at 14:00.
        await ledger.handleEntry(placeID: SeedData.ropemakerPlaceID, day: sunday)
        #expect(delivered.contents.count == 1)
    }

    @Test("A confirmed day silences any later arrival")
    func confirmedDayIsSpent() async throws {
        let delivered = capturing()
        ledger.confirmAttendance(
            placeID: SeedData.ropemakerPlaceID, bookingID: nil, day: wednesday
        )
        await ledger.handleEntry(placeID: SeedData.ropemakerPlaceID, day: wednesday)

        #expect(delivered.contents.isEmpty)
        #expect(ledger.lastDecision == .doNothing(.alreadyAttended))
    }

    @Test("The notification carries what the action handler needs to confirm")
    func notificationCarriesItsContext() async throws {
        let delivered = capturing()
        await ledger.handleEntry(placeID: SeedData.ropemakerPlaceID, day: wednesday)

        // The app may be relaunched by the time the action is tapped, so the
        // notification has to carry its own context.
        let info = try #require(delivered.contents.first?.userInfo)
        #expect(info[ArrivalNotifications.UserInfo.placeID] as? String
            == SeedData.ropemakerPlaceID.uuidString)
        #expect(info[ArrivalNotifications.UserInfo.day] as? String == wednesday.description)
        #expect(info[ArrivalNotifications.UserInfo.bookingID] != nil)

        let day = try #require((info[ArrivalNotifications.UserInfo.day] as? String).flatMap(Day.init))
        #expect(day == wednesday, "the day round-trips through the notification")
    }

    @Test("Turning the trigger off silences arrivals entirely")
    func disabledMonitor() async throws {
        ArrivalSettings.shared.enabled = false
        defer { ArrivalSettings.shared.enabled = true }

        let delivered = capturing()
        await ledger.handleEntry(placeID: SeedData.ropemakerPlaceID, day: wednesday)

        #expect(delivered.contents.isEmpty)
        #expect(try container.mainContext.fetchCount(FetchDescriptor<ArrivalAlert>()) == 0)
    }
}

@Suite("Arrival notifications")
struct ArrivalNotificationTests {

    @Test("Both categories offer a confirm and a decline")
    func categories() throws {
        let categories = ArrivalNotifications.categories(copy: { $0.terminator })
        #expect(categories.count == 2)

        for category in categories {
            let ids = category.actions.map(\.identifier)
            #expect(ids.contains(ArrivalNotifications.Action.confirm.rawValue))
            #expect(ids.contains(ArrivalNotifications.Action.decline.rawValue))
        }
    }

    @Test("Copy mode reaches the notification actions too")
    func copyMode() throws {
        let terminator = ArrivalNotifications.categories(copy: { $0.terminator })
        let plain = ArrivalNotifications.categories(copy: { $0.plain })

        func confirmTitle(_ set: Set<UNNotificationCategory>) -> String? {
            set.first?.actions
                .first { $0.identifier == ArrivalNotifications.Action.confirm.rawValue }?
                .title
        }
        #expect(confirmTitle(terminator) == "CLAIM THE KILL")
        #expect(confirmTitle(plain) == "LOG THIS DAY")
    }
}

@Suite("Floor formatting")
struct FloorTests {

    @Test("A floor already prefixed is not prefixed twice")
    func noDoublePrefix() {
        // The seed stores "L3"; rendering it as "LEVEL L3" reads as a typo.
        #expect(Abbreviate.level("L3") == "LEVEL 3")
        #expect(Abbreviate.level("3") == "LEVEL 3")
        #expect(Abbreviate.level("l12") == "LEVEL 12")
    }

    @Test("A named floor stands alone")
    func namedFloors() {
        #expect(Abbreviate.level("Ground") == "GROUND")
        #expect(Abbreviate.level("Mezzanine") == "MEZZANINE")
        // "LG" is a name, not L-then-digits, so it is left as it is.
        #expect(Abbreviate.level("LG") == "LG")
    }
}

@Suite("Live Activity")
@MainActor
struct LiveActivityTests {

    let wednesday = Day(2026, 8, 5)

    /// A throwaway defaults suite per test, so switching the fire rate here
    /// does not leave it switched for the app on the same simulator.
    func settings(_ rate: FireRate) -> ArrivalSettings {
        let suite = UserDefaults(suiteName: "t8.tests.\(UUID().uuidString)")!
        let settings = ArrivalSettings(defaults: suite)
        settings.fireRate = rate
        return settings
    }

    /// Records what would have been handed to ActivityKit. Nothing in this
    /// suite reaches the real one — a request would leave a panel on the lock
    /// screen of whatever ran the tests.
    final class Started: @unchecked Sendable {
        var calls: [(place: Place, booking: ArrivalRule.DeskBooking, day: Day, dayNumber: Int, target: Int)] = []
    }

    /// The container is held here rather than left as a local in the factory.
    /// `mainContext` does not keep its container alive, so letting one go out
    /// of scope leaves the context pointing at freed storage — which crashes
    /// inside SwiftData on the next fetch rather than failing an assertion.
    struct Rig {
        let container: ModelContainer
        let ledger: ArrivalLedger
        let started: Started
    }

    func rig(_ rate: FireRate) throws -> Rig {
        let container = try Store.makeInMemoryContainer(seeded: true)
        let ledger = ArrivalLedger(
            context: container.mainContext, settings: settings(rate)
        )
        let started = Started()
        ledger.deliver = { _ in }
        ledger.startActivity = { place, booking, day, dayNumber, target in
            started.calls.append((place, booking, day, dayNumber, target))
        }
        return Rig(container: container, ledger: ledger, started: started)
    }

    @Test("PERSIST ALL DAY starts the activity as well as alerting")
    func persistStartsActivity() async throws {
        let rig = try rig(.persistAllDay)
        await rig.ledger.handleEntry(placeID: SeedData.ropemakerPlaceID, day: wednesday)

        #expect(rig.started.calls.count == 1)
        let call = try #require(rig.started.calls.first)
        #expect(call.booking.deskID == "3C-114")
        #expect(call.place.name == "Ropemaker Place")
        // The activity is additive: the notification still went out, because it
        // is the only thing carrying the confirm action.
        #expect(rig.ledger.lastDecision == .offerBooked(call.booking))
    }

    @Test("FIRST ARRIVAL ONLY alerts and starts nothing")
    func firstArrivalStartsNothing() async throws {
        let rig = try rig(.firstArrivalOnly)
        await rig.ledger.handleEntry(placeID: SeedData.ropemakerPlaceID, day: wednesday)
        #expect(rig.started.calls.isEmpty)
    }

    @Test("An unbooked arrival starts nothing — there is no desk to hold")
    func unbookedStartsNothing() async throws {
        let rig = try rig(.persistAllDay)
        // Sunday: nothing booked anywhere.
        await rig.ledger.handleEntry(placeID: SeedData.ropemakerPlaceID, day: Day(2026, 8, 9))
        #expect(rig.started.calls.isEmpty)
    }

    @Test("A second entry the same day starts no second activity")
    func firesOnce() async throws {
        let rig = try rig(.persistAllDay)
        await rig.ledger.handleEntry(placeID: SeedData.ropemakerPlaceID, day: wednesday)
        await rig.ledger.handleEntry(placeID: SeedData.ropemakerPlaceID, day: wednesday)
        #expect(rig.started.calls.count == 1, "the ledger governs the activity too")
    }

    @Test("The panel's derived strings read as the design does")
    func derivedStrings() {
        let state = DeskActivityAttributes.ContentState(
            deskID: "3C-114", floor: "L3", zone: "C",
            heldUntil: "17:00", dayNumber: 3, target: 7
        )
        #expect(state.floorZone == "3 / C")
        #expect(state.dayCount == "DAY 03/07")
    }

    @Test("An unread field is absent from the panel, never filled in")
    func neverGuesses() {
        let neither = DeskActivityAttributes.ContentState(
            deskID: "3C-114", floor: nil, zone: nil,
            heldUntil: nil, dayNumber: 1, target: 7
        )
        #expect(neither.floorZone == nil, "no cell at all rather than a guess")

        let zoneOnly = DeskActivityAttributes.ContentState(
            deskID: "3C-114", floor: nil, zone: "C",
            heldUntil: nil, dayNumber: 1, target: 7
        )
        #expect(zoneOnly.floorZone == "C")
    }
}
