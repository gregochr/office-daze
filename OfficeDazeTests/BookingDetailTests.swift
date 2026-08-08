import EventKit
import Foundation
import SwiftData
import SwiftUI
import Testing
@testable import OfficeDaze

// The office name is the untrusted string in this app. The user types it in
// the office editor, and the capture sheet writes it from whatever Claude read
// off a screenshot — so anything that puts it into a URL has to encode it for
// the position it lands in, not merely "for a URL".
//
// Each case here parses the built URL back apart rather than comparing the
// whole string, because the defect being guarded against is *extra query
// parameters*: a comparison that only checked `q` would pass on a URL that had
// grown a third parameter beside it.

@Suite("Directions link")
@MainActor
struct BookingDetailTests {

    private func items(_ name: String) -> [URLQueryItem] {
        let url = BookingDetailScreen.directionsURL(
            latitude: 51.5155, longitude: -0.0922, name: name
        )
        guard let url,
              let parsed = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = parsed.queryItems
        else {
            Issue.record("no URL built for \(name)")
            return []
        }
        return items
    }

    @Test("A plain office name gives the destination and the label, and nothing else")
    func ordinaryName() {
        #expect(items("Moorgate") == [
            URLQueryItem(name: "daddr", value: "51.5155,-0.0922"),
            URLQueryItem(name: "q", value: "Moorgate"),
        ])
    }

    @Test("An ampersand in the name stays inside the name")
    func ampersand() {
        // `.urlQueryAllowed` leaves `&` alone — it is legal *somewhere* in a
        // query — so the old string interpolation truncated the label at the
        // ampersand and left "Grill House" as a parameter of its own.
        let items = items("Bar & Grill House")
        #expect(items.count == 2, "no parameter was smuggled in beside daddr and q")
        #expect(items.last == URLQueryItem(name: "q", value: "Bar & Grill House"))
    }

    @Test("An office name cannot inject an Apple Maps parameter")
    func parameterInjection() {
        // `dirflg` is a real Apple Maps parameter: `d` means driving. Named
        // this way, the old encoder handed Maps a genuine instruction and
        // silently opened the wrong travel mode.
        let items = items("Coleman&dirflg=d")
        #expect(items.count == 2)
        #expect(items.first?.name == "daddr")
        #expect(items.last == URLQueryItem(name: "q", value: "Coleman&dirflg=d"))
        #expect(!items.contains { $0.name == "dirflg" })

        let raw = BookingDetailScreen.directionsURL(
            latitude: 51.5155, longitude: -0.0922, name: "Coleman&dirflg=d"
        )?.absoluteString
        #expect(raw?.contains("&dirflg=d") == false, "the ampersand and equals are both escaped")
        #expect(raw?.contains("q=Coleman%26dirflg%3Dd") == true)
    }

    @Test("A name that is nothing but separators produces no parameters of its own")
    func onlySeparators() {
        let items = items("&&==?#")
        #expect(items.count == 2)
        #expect(items.last == URLQueryItem(name: "q", value: "&&==?#"))
    }

    @Test("Accents and spaces survive the round trip")
    func nonASCII() {
        #expect(items("Zürich Hauptsitz").last == URLQueryItem(name: "q", value: "Zürich Hauptsitz"))
    }

    @Test("The link is https, so a fall-through to Safari is not plaintext")
    func scheme() {
        let url = BookingDetailScreen.directionsURL(
            latitude: 51.5155, longitude: -0.0922, name: "Moorgate"
        )
        #expect(url?.scheme == "https")
        #expect(url?.host == "maps.apple.com")
    }

    @Test("A negative longitude reaches Maps as a coordinate, not as a search")
    func coordinateFormatting() {
        // West of Greenwich is the common case for this app, and a minus sign
        // that got percent-encoded or dropped would send the user to a mirror
        // of London somewhere in Kent.
        #expect(items("Moorgate").first == URLQueryItem(name: "daddr", value: "51.5155,-0.0922"))
    }

    // MARK: Whether the row goes anywhere at all

    private func office(latitude: Double, longitude: Double) -> Office {
        Office(
            name: "Coleman", address: "63 Coleman Street, London", postcode: "EC2R 5BB",
            latitude: latitude, longitude: longitude, colourHex: OfficeColours.palette[0]
        )
    }

    /// The row's `enabled:` and its action read the same function, so these two
    /// cases are the row's appearance and its behaviour at once.
    @Test("A located office gives the row somewhere to go")
    func locatedOfficeOpens() throws {
        let url = try #require(
            BookingDetailScreen.directionsURL(for: office(latitude: 51.5172, longitude: -0.0893))
        )
        let items = try #require(
            URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        )
        #expect(items.first == URLQueryItem(name: "daddr", value: "51.5172,-0.0893"))
        #expect(items.last == URLQueryItem(name: "q", value: "Coleman"))
    }

    /// 0,0 is the Atlantic, and it is what an office the geocoder could not
    /// find holds. A live-looking Directions row over it would open Maps on a
    /// point in the ocean; the row has to be dead instead.
    @Test("An office the geocoder never found has no directions, so the row is dead")
    func unlocatedOfficeHasNoURL() {
        #expect(BookingDetailScreen.directionsURL(for: office(latitude: 0, longitude: 0)) == nil)
    }

    /// Either coordinate on its own is a real place — the equator and the
    /// prime meridian both run through inhabited ground — so only the pair
    /// being zero means "not found".
    @Test("An office on the meridian or the equator still has directions")
    func oneZeroCoordinateIsStillAPlace() {
        #expect(BookingDetailScreen.directionsURL(for: office(latitude: 51.5, longitude: 0)) != nil)
        #expect(BookingDetailScreen.directionsURL(for: office(latitude: 0, longitude: 4.35)) != nil)
    }

    /// A booking whose office has since been deleted. `removeOffice` keeps the
    /// bookings, so this is reachable, and the screen must not offer to
    /// navigate to a building it cannot name.
    @Test("A booking with no office at all has no directions")
    func missingOfficeHasNoURL() {
        #expect(BookingDetailScreen.directionsURL(for: nil) == nil)
    }
}

/// What the calendar row promises, and what it says when the promise fails.
///
/// The row used to read "Update calendar event" the moment the booking held an
/// identifier, and there was no update behind it: the app asks for write-only
/// access, reading an event back is a read, and the branch that would have done
/// the updating could never run. Every tap wrote a twin. `CalendarWriter` now
/// refuses, and these are the assertions that the row stopped inviting the user
/// into that refusal.
@Suite("The calendar row's promise")
@MainActor
struct BookingDetailCalendarRowTests {

    private func title(_ outcome: CalendarWriter.Outcome?, hasEvent: Bool = false) -> String {
        BookingDetailScreen.calendarTitle(outcome: outcome, hasEvent: hasEvent)
    }

    private func enabled(_ outcome: CalendarWriter.Outcome?, hasEvent: Bool = false) -> Bool {
        BookingDetailScreen.calendarRowEnabled(outcome: outcome, hasEvent: hasEvent)
    }

    // MARK: The promise

    @Test("A booking that is not in the calendar yet is offered the write")
    func unwrittenBookingInvitesTheTap() {
        #expect(title(nil) == "Add to calendar")
        #expect(enabled(nil))
    }

    /// The bug, stated as the user met it. Opening the screen a second time
    /// showed a live row promising an update, and the tap behind it saved a
    /// second identical event and threw the first one's identifier away.
    @Test("A booking already in the calendar says so, and offers nothing further")
    func writtenBookingSaysSoAndStops() {
        #expect(title(nil, hasEvent: true) == "Added to calendar")
        #expect(!enabled(nil, hasEvent: true))
    }

    /// Belt and braces on the exact string, because the defect was a promise
    /// and not a spelling: no state of this row may offer an update while the
    /// app holds write-only access.
    @Test("No state of the row offers an update the app cannot perform")
    func nothingPromisesAnUpdateThatCannotHappen() {
        let reachable: [CalendarWriter.Outcome?] = [
            nil, .added("EVENT-1"), .denied, .failed(CalendarWriter.alreadyWritten),
        ]
        for outcome in reachable {
            for hasEvent in [true, false] {
                #expect(
                    title(outcome, hasEvent: hasEvent) != "Update calendar event",
                    "\(String(describing: outcome)), hasEvent \(hasEvent)"
                )
            }
        }
    }

    @Test("A write that has just succeeded closes the row")
    func addedClosesTheRow() {
        #expect(title(.added("EVENT-1"), hasEvent: true) == "Added to calendar")
        #expect(!enabled(.added("EVENT-1"), hasEvent: true))
        // Independent of whether the identifier reached the store: the save may
        // throw after the event is written, and a row that reopened on that
        // would write the twin the refusal exists to prevent.
        #expect(!enabled(.added("EVENT-1"), hasEvent: false))
    }

    /// `.updated` is unreachable while the app asks for write-only access, and
    /// it is kept for the day it asks for full access instead. Its copy is
    /// asserted so that day does not arrive to a row with nothing to say.
    @Test("The update outcome still has its own words, for the day it can happen")
    func updatedKeepsItsCopy() {
        #expect(title(.updated("EVENT-1"), hasEvent: true) == "Calendar updated")
        #expect(!enabled(.updated("EVENT-1"), hasEvent: true))
    }

    // MARK: What it says when the write fails

    /// The second defect. The row rendered fixed copy and dropped the reason on
    /// the floor, so someone whose calendar is managed by their employer was
    /// told that something had failed and never what.
    @Test("A failure says what failed, in the words the writer chose")
    func failureCarriesItsReason() {
        #expect(title(.failed("The calendar is unavailable.")) == "The calendar is unavailable.")
        #expect(title(.failed("The calendar is unavailable.")) != "Couldn't add to calendar")
    }

    @Test("The refusal to write a twin reaches the row whole")
    func alreadyWrittenReachesTheRow() {
        let shown = title(.failed(CalendarWriter.alreadyWritten), hasEvent: true)
        #expect(shown == CalendarWriter.alreadyWritten)
        #expect(shown.contains("edit or delete it in Calendar"), "and it says what to do instead")
    }

    /// The negative. A message is only worth showing if there is one — an empty
    /// reason would leave a row with no text on it, which reads as broken
    /// rather than as informative.
    @Test("A failure with nothing to say falls back to the fixed words")
    func emptyReasonFallsBack() {
        #expect(title(.failed("")) == "Couldn't add to calendar")
        #expect(title(.failed("   \n ")) == "Couldn't add to calendar")
    }

    // MARK: Whether the tap is worth offering again

    @Test("A refused permission stays tappable, so granting it in Settings is not a dead end")
    func deniedCanBeRetried() {
        #expect(title(.denied) == "Calendar access refused")
        #expect(enabled(.denied))
    }

    @Test("A write that failed for any other reason can be tried again")
    func failureCanBeRetried() {
        #expect(enabled(.failed("The calendar is unavailable.")))
    }

    /// Except when the reason it failed is that the event already exists —
    /// then the next tap fails identically, and offering it is theatre.
    @Test("A failure on a booking that already has an event is not offered again")
    func alreadyWrittenIsNotRetried() {
        #expect(!enabled(.failed(CalendarWriter.alreadyWritten), hasEvent: true))
    }

    // MARK: What counts as having an event

    /// The row and the writer have to agree on this or the row goes grey over a
    /// booking `CalendarWriter.write` would happily have written — a feature
    /// gone missing with nothing on screen to explain it. `write` treats an
    /// empty identifier as no identifier; so does this.
    @Test("An empty identifier is no identifier, to the row as to the writer")
    func emptyIdentifierIsNoEvent() {
        #expect(!BookingDetailScreen.hasEvent(nil))
        #expect(!BookingDetailScreen.hasEvent(""))
        #expect(BookingDetailScreen.hasEvent("EVENT-1"))

        #expect(title(nil, hasEvent: BookingDetailScreen.hasEvent("")) == "Add to calendar")
        #expect(enabled(nil, hasEvent: BookingDetailScreen.hasEvent("")))
    }

    // MARK: The reason, all the way from the calendar to the row

    struct CalendarManagedByYourEmployer: Error, LocalizedError {
        var errorDescription: String? { "Your account doesn't allow calendar changes." }
    }

    /// Records what it was asked to do rather than nodding at it, so the test
    /// can say that nothing reached the calendar — not merely that the row said
    /// something sad.
    @MainActor
    final class RefusingCalendar: CalendarBackend {
        let saveError: Error
        private(set) var saved: [EKEvent] = []
        private(set) var accessRequests = 0
        private let store = EKEventStore()

        init(saveError: Error) { self.saveError = saveError }

        func requestWriteOnlyAccess() async throws -> Bool {
            accessRequests += 1
            return true
        }

        func makeEvent() -> EKEvent { EKEvent(eventStore: store) }

        func save(_ event: EKEvent) throws -> String {
            saved.append(event)
            throw saveError
        }
    }

    /// End to end, because the two halves of this fix are in different files
    /// and each is useless alone: the writer already carries the reason out,
    /// and until now the row threw it away on arrival.
    @Test("The reason a write failed travels from the calendar to the row unchanged")
    func reasonSurvivesTheJourney() async {
        let calendar = RefusingCalendar(saveError: CalendarManagedByYourEmployer())
        let outcome = await CalendarWriter.write(
            CalendarWriter.Entry(
                deskID: "3C-114", officeName: "Coleman",
                address: "63 Coleman Street, London EC2R 5BB",
                floor: "Level 3", zone: "C", day: Day(2026, 8, 5),
                startTime: "09:00", endTime: "17:00"
            ),
            existingEventID: nil,
            in: TimeZone(identifier: "Europe/London")!,
            using: calendar
        )
        #expect(outcome == .failed("Your account doesn't allow calendar changes."))
        #expect(calendar.accessRequests == 1)
        #expect(calendar.saved.count == 1, "it was attempted, and the calendar refused it")

        // Nothing was written, so the booking keeps no identifier — and the row
        // both names the reason and stays tappable for the next attempt.
        #expect(
            BookingDetailScreen.calendarTitle(outcome: outcome, hasEvent: false)
                == "Your account doesn't allow calendar changes."
        )
        #expect(BookingDetailScreen.calendarRowEnabled(outcome: outcome, hasEvent: false))
    }
}

/// Whether the day is over, whether it was worked, and what the screen puts
/// under the desk number because of it.
@Suite("What the booking's day has to say")
@MainActor
struct BookingDetailStandingTests {

    @Test("A day that was confirmed on arrival says so, rather than claiming it was typed")
    func geofenceIsNamed() {
        #expect(
            BookingDetailScreen.standing(
                attendedVia: .geofence, day: Day(2026, 8, 5), today: Day(2026, 8, 7)
            ) == .attended("Attended — confirmed on arrival")
        )
    }

    /// The two are not equally trustworthy — one is the phone seeing the user
    /// arrive and the other is somebody remembering — so the strip has to keep
    /// them apart.
    @Test("A day recorded by hand is not passed off as an arrival")
    func manualIsNamed() {
        #expect(
            BookingDetailScreen.standing(
                attendedVia: .manual, day: Day(2026, 8, 5), today: Day(2026, 8, 7)
            ) == .attended("Attended — confirmed by hand")
        )
    }

    /// A booked day that has been and gone with no attendance is the whole
    /// point of the screen: a day you booked is not a day you went, and this is
    /// where the user says which.
    @Test("A past day nobody recorded is offered the question")
    func pastDayAsks() {
        #expect(
            BookingDetailScreen.standing(
                attendedVia: nil, day: Day(2026, 8, 5), today: Day(2026, 8, 7)
            ) == .offerAttendance
        )
    }

    /// The boundary, and the commonest case there is: the arrival alert fires
    /// in the morning, so today is exactly the day "I was here" has to work on.
    /// A strict `<` would have hidden the row until tomorrow.
    @Test("Today is a day you can already say you were here on")
    func todayAsks() {
        #expect(
            BookingDetailScreen.standing(
                attendedVia: nil, day: Day(2026, 8, 7), today: Day(2026, 8, 7)
            ) == .offerAttendance
        )
        #expect(BookingDetailScreen.isPast(Day(2026, 8, 7), today: Day(2026, 8, 7)))
    }

    /// The negative, and the one that matters: offering it would let a user
    /// record a day that has not happened, and the gauge counts attendance.
    @Test("A day still ahead is not offered, because it cannot yet have been worked")
    func futureDaySaysNothing() {
        #expect(
            BookingDetailScreen.standing(
                attendedVia: nil, day: Day(2026, 8, 8), today: Day(2026, 8, 7)
            ) == .tooEarlyToSay
        )
        #expect(!BookingDetailScreen.isPast(Day(2026, 8, 8), today: Day(2026, 8, 7)))
    }

    /// Attendance outranks the calendar. A booking recorded early — the evening
    /// question answered before midnight rolls the day over — still reads as
    /// attended rather than as a day to ask about.
    @Test("A recorded day reads as attended even when the day is still ahead")
    func attendanceOutranksTheDate() {
        #expect(
            BookingDetailScreen.standing(
                attendedVia: .geofence, day: Day(2026, 8, 8), today: Day(2026, 8, 7)
            ) == .attended("Attended — confirmed on arrival")
        )
    }

    @Test("The month and the year are compared, not just the day number")
    func acrossMonths() {
        #expect(BookingDetailScreen.isPast(Day(2026, 7, 31), today: Day(2026, 8, 1)))
        #expect(!BookingDetailScreen.isPast(Day(2027, 1, 4), today: Day(2026, 12, 31)))
    }

    // MARK: The strip that names what could not be read

    @Test("One unread field is named as a sentence, not as a heading")
    func oneField() {
        #expect(BookingDetailScreen.sentenceCased("floor") == "Floor")
    }

    /// `.capitalized` is the call this reaches for and must not use: the names
    /// arrive as a list, and title-casing the lot gives "Floor And Zone".
    @Test("A list of unread fields keeps its lower-case joining words")
    func aListOfFields() {
        #expect(BookingDetailScreen.sentenceCased("floor and zone") == "Floor and zone")
        #expect(
            BookingDetailScreen.sentenceCased("floor, zone and hours")
                == "Floor, zone and hours"
        )
    }

    /// The negative. Nothing to name is not a crash — `prefix(1)` on an empty
    /// string is empty, and the caller only asks when a field is unread.
    @Test("Nothing to name produces nothing, rather than trapping")
    func nothingToName() {
        #expect(BookingDetailScreen.sentenceCased("") == "")
    }
}

/// The body itself, run for the four shapes it draws differently: an office
/// that is gone, a booking already in the calendar, a field the capture could
/// not read, and a past day nobody has answered for.
///
/// What each render claims is small — that the screen does not trap on that
/// shape — and the words it draws are asserted above, where a wrong one fails
/// for a reason. These exist because every one of those four branches is a
/// crash the pure functions cannot catch: a nil office, an optional unwrapped
/// in a `ViewBuilder`, a `switch` that has to stay exhaustive.
@Suite("The booking detail screen renders")
@MainActor
struct BookingDetailRenderTests {

    /// In a real window, and keyed. A hosting controller whose view is only
    /// given a frame never evaluates `body` at all — SwiftUI has nothing
    /// on screen to update, so the test passes without executing a line of the
    /// screen, which is the coverage-crank this whole review exists to stamp
    /// out. Being in the key window is what makes the render real.
    private func render(_ booking: DeskBooking, in container: ModelContainer) {
        let host = UIHostingController(
            rootView: BookingDetailScreen(booking: booking).modelContainer(container)
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        // See ArrivalPreviewRenderTests.dismantle: a window left key outlives
        // the container it was handed and crashes the host from another suite.
        ArrivalPreviewRenderTests.dismantle(window, holding: container)
    }

    @Test("A booking whose office has been deleted still draws, with no directions")
    func orphanedBooking() throws {
        let container = try Store.makeInMemoryContainer(seeded: true)
        let context = container.mainContext
        let orphan = DeskBooking(
            officeID: UUID(), day: Day(2026, 8, 20), deskID: "9Z-001", source: .manual
        )
        context.insert(orphan)
        try context.save()

        render(orphan, in: container)

        #expect(BookingDetailScreen.directionsURL(for: nil) == nil)
    }

    @Test("A booking already in the calendar draws its closed row")
    func bookingWithAnEvent() throws {
        let container = try Store.makeInMemoryContainer(seeded: true)
        let context = container.mainContext
        let booking = try #require(
            try context.fetch(FetchDescriptor<DeskBooking>())
                .first { $0.day == Day(2026, 8, 5) }
        )
        booking.calendarEventID = "EVENT-1"
        try context.save()

        render(booking, in: container)

        #expect(BookingDetailScreen.hasEvent(booking.calendarEventID))
        #expect(!BookingDetailScreen.calendarRowEnabled(outcome: nil, hasEvent: true))
    }

    /// The seeded Brussels booking arrives with its zone unread on purpose, so
    /// the amber strip has something to name. The name is asserted rather than
    /// the strip's mere presence: "Zone couldn't be read" is the whole point of
    /// the row, and " couldn't be read" would render just as happily.
    @Test("A booking with a field the capture could not read names it, and draws")
    func unreadFieldIsNamed() throws {
        let container = try Store.makeInMemoryContainer(seeded: true)
        let booking = try #require(
            try container.mainContext.fetch(FetchDescriptor<DeskBooking>())
                .first { $0.needsChecking }
        )
        #expect(booking.unsureFields == ["zone"])

        render(booking, in: container)

        #expect(
            BookingDetailScreen.sentenceCased(
                BookingEditorScreen.unreadFieldNames(booking.unsureFields)
            ) == "Zone"
        )
    }

    /// A day long gone that nobody ever answered for. The screen has to put the
    /// question under it — that branch is the only way an unattended booked day
    /// is ever recorded from this screen.
    @Test("A past day nobody recorded draws the question rather than a confirmation")
    func pastUnansweredBookingAsks() throws {
        let container = try Store.makeInMemoryContainer(seeded: true)
        let context = container.mainContext
        let longAgo = Day(2020, 1, 15)
        let booking = DeskBooking(
            officeID: SeedData.colemanID, day: longAgo, deskID: "1A-001", source: .manual
        )
        context.insert(booking)
        try context.save()

        // No attendance was ever recorded for it, at any office.
        #expect(
            try context.fetch(FetchDescriptor<AttendanceDay>())
                .allSatisfy { $0.day != longAgo }
        )

        render(booking, in: container)

        // Whatever day the clock says, 2020 is behind it — so the branch the
        // render just took is the one that offers the question.
        #expect(BookingDetailScreen.isPast(longAgo, today: .today))
        #expect(
            BookingDetailScreen.standing(attendedVia: nil, day: longAgo, today: .today)
                == .offerAttendance
        )
    }
}
