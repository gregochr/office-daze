import Foundation
import SwiftData
import SwiftUI
import Testing
import UIKit
import UserNotifications
@testable import OfficeDaze

/// The preview screen's claim is a strong one: that it shows the alert the
/// geofence will post, built from the same store by the same function. A claim
/// like that has to be held to by test, because the only other way to check it
/// is to walk into a building — which is the reason the screen exists in the
/// first place.
@Suite("The arrival preview, and the alert it promises to be")
@MainActor
struct ArrivalPreviewTests {

    let container: ModelContainer

    init() throws {
        container = try Store.makeInMemoryContainer(seeded: true)
    }

    private var context: ModelContext { container.mainContext }

    private func offices() throws -> [Office] {
        try context.fetch(FetchDescriptor<Office>()).sorted { $0.name < $1.name }
    }

    private func bookings() throws -> [DeskBooking] {
        try context.fetch(FetchDescriptor<DeskBooking>()).sorted { $0.day < $1.day }
    }

    private func office(_ id: UUID) throws -> Office {
        try #require(try offices().first { $0.id == id })
    }

    // MARK: The alert it stands in for

    /// The whole point of the screen, asserted against the thing itself: the
    /// notification `ArrivalLedger` actually posts on a perimeter crossing,
    /// caught at the seam, word for word against what the screen draws.
    ///
    /// Two independent paths through the store meeting on the same four
    /// strings. Nothing else in the suite can catch the failure that matters
    /// here — the screen quietly drifting into a mock-up of an alert that no
    /// longer says this — because both halves would go on looking reasonable
    /// on their own.
    @Test("The card is the notification the geofence posts, word for word")
    func previewMatchesWhatIsPosted() throws {
        let eleventh = Day(2026, 8, 11)
        let brussels = try office(SeedData.brusselsID)

        // Records the request it is given rather than answering a fixed one:
        // what is under test is which content reaches the notification centre.
        var posted: [UNNotificationRequestFields] = []
        let ledger = ArrivalLedger(context: context)
        ledger.post = { request in
            posted.append(UNNotificationRequestFields(request))
        }

        let decision = ledger.handleEntry(
            officeID: SeedData.brusselsID, day: eleventh, now: .now
        )
        let previewDesk = try #require(ArrivalPreviewScreen.desk(
            at: brussels, bookings: try bookings(), today: eleventh
        ))
        #expect(decision == .desk(previewDesk), "the same desk, reached two ways")

        let sent = try #require(posted.first)
        let drawn = try #require(ArrivalPreviewScreen.content(
            for: brussels, bookings: try bookings(), today: eleventh, in: context
        ))
        #expect(sent.title == drawn.title)
        #expect(sent.subtitle == drawn.subtitle)
        #expect(sent.body == drawn.body)
        #expect(sent.category == drawn.category.rawValue)

        // And that the pair of them is the alert the app is for, rather than
        // two empty strings agreeing with each other.
        #expect(drawn.title == "2-041", "the desk id, in the largest text iOS draws")
        #expect(drawn.subtitle == "You're at Brussels")
        #expect(drawn.category == .booked)
    }

    /// The zone the capture could not read is absent from the alert rather than
    /// guessed at, and the floor it did read is on it. The seeded Brussels
    /// booking is exactly that shape.
    @Test("An unread zone is missing from the alert, not invented for it")
    func unreadFieldsAreAbsentFromTheCopy() throws {
        let eleventh = Day(2026, 8, 11)
        let content = try #require(ArrivalPreviewScreen.content(
            for: try office(SeedData.brusselsID),
            bookings: try bookings(), today: eleventh, in: context
        ))
        let lines = content.body.split(separator: "\n").map(String.init)
        #expect(lines.first == "Level 2")
        #expect(!content.body.contains("Zone"))
    }

    /// Nothing booked and nothing said about the day yet: the alert offers to
    /// record it, and names what the button will do.
    @Test("With nothing booked the alert asks for the day rather than reading a desk")
    func unbookedAlert() throws {
        // The 13th: past the seeded bookings and past the attended days, so
        // this is genuinely the turned-up-unbooked case.
        let thirteenth = Day(2026, 8, 13)
        let content = try #require(ArrivalPreviewScreen.content(
            for: try office(SeedData.colemanID),
            bookings: try bookings(), today: thirteenth, in: context
        ))
        #expect(content.category == .unbooked)
        #expect(content.title == "Day 4 of 8", "the count, since there is no desk to show")
        #expect(content.body == "No desk booked today.\nTap to make it 5.")
    }

    /// A day already recorded — at the other office, earlier — keeps the count
    /// and drops the promise, because the button cannot add to a day that is
    /// already worth a whole one.
    @Test("A day already recorded elsewhere is counted but not offered again")
    func alreadyRecordedDropsTheTail() throws {
        // The 4th is seeded as attended at Brussels. Arriving at Coleman with
        // nothing booked there is the second-office case exactly.
        let fourth = Day(2026, 8, 4)
        let content = try #require(ArrivalPreviewScreen.content(
            for: try office(SeedData.colemanID),
            bookings: try bookings(), today: fourth, in: context
        ))
        #expect(content.body == "No desk booked today.", "no tap-to-make-it line")
        #expect(!content.body.contains("Tap to make it"))
    }

    @Test("With no offices at all there is no alert to draw")
    func noOfficeNoContent() throws {
        #expect(
            ArrivalPreviewScreen.content(
                for: nil, bookings: try bookings(), today: Day(2026, 8, 11), in: context
            ) == nil
        )
    }

    @Test("The count names the month and not the year, which is not in doubt")
    func monthName() {
        #expect(ArrivalPreviewScreen.monthName(SeedData.month) == "August")
        #expect(ArrivalPreviewScreen.monthName(Month(year: 2027, month: 1)) == "January")
    }

    // MARK: Which office the screen opens on

    /// The screen is meant to open on the case the alert exists for. Coleman is
    /// second alphabetically, so a screen that merely took the first office
    /// would pass an assertion for Brussels by accident.
    @Test("The preview opens on the office with a desk booked today")
    func opensOnTheBookedOffice() throws {
        let twelfth = Day(2026, 8, 12)  // the seeded Coleman booking
        #expect(try offices().first?.id == SeedData.brusselsID, "Coleman is not first")
        #expect(
            ArrivalPreviewScreen.openingOfficeID(
                offices: try offices(), bookings: try bookings(), today: twelfth
            ) == SeedData.colemanID
        )
    }

    /// The bug. Deleting a building deliberately leaves its desk bookings
    /// behind pointing at nothing — `OfficeEditorScreen.removeOffice` keeps
    /// them, and the home screen renders them as "Unknown office" — so today's
    /// booking can name an office the picker has no segment for. Selecting it
    /// drew the segmented control with nothing selected while the card below
    /// fell back to the first office and showed that building's alert.
    @Test("A booking left behind by a deleted office does not become the selection")
    func orphanedBookingIsNotSelected() throws {
        let ghost = UUID()
        #expect(try !offices().contains { $0.id == ghost })
        let today = Day(2026, 8, 18)
        context.insert(DeskBooking(
            officeID: ghost, day: today, deskID: "X-000", source: .manual
        ))
        try context.save()

        let opened = ArrivalPreviewScreen.openingOfficeID(
            offices: try offices(), bookings: try bookings(), today: today
        )
        #expect(opened != ghost, "no segment of the picker carries that id")
        #expect(opened == SeedData.brusselsID, "so it opens on the first office instead")

        // And the two halves of the screen now agree about which office that is.
        let shown = ArrivalPreviewScreen.selectedOffice(in: try offices(), selection: opened)
        #expect(shown?.id == opened)
    }

    @Test("With nothing booked today the preview opens on the first office")
    func fallsBackToTheFirstOffice() throws {
        // A Saturday in the seeded month with no booking of any kind.
        let empty = Day(2026, 8, 22)
        #expect(try !bookings().contains { $0.day == empty })
        #expect(
            ArrivalPreviewScreen.openingOfficeID(
                offices: try offices(), bookings: try bookings(), today: empty
            ) == SeedData.brusselsID
        )
    }

    @Test("With no offices there is nothing to open on")
    func noOfficesNoSelection() throws {
        #expect(
            ArrivalPreviewScreen.openingOfficeID(
                offices: [], bookings: try bookings(), today: Day(2026, 8, 12)
            ) == nil
        )
    }

    /// The empty state is for someone with no offices, and only for them.
    @Test("A selection naming no office shows the first one rather than nothing")
    func selectionFallsBack() throws {
        let shown = ArrivalPreviewScreen.selectedOffice(in: try offices(), selection: UUID())
        #expect(shown?.id == SeedData.brusselsID)
        #expect(ArrivalPreviewScreen.selectedOffice(in: [], selection: nil) == nil)
    }

    @Test("The picked office is the one drawn")
    func selectionIsHonoured() throws {
        let shown = ArrivalPreviewScreen.selectedOffice(
            in: try offices(), selection: SeedData.colemanID
        )
        #expect(shown?.id == SeedData.colemanID)
        #expect(shown?.name == "Coleman")
    }

    // MARK: Today's desk

    @Test("The desk is the one booked at that office on that day, and no other")
    func deskIsTheDaysBooking() throws {
        let eleventh = Day(2026, 8, 11)
        let brussels = try office(SeedData.brusselsID)
        let coleman = try office(SeedData.colemanID)

        let desk = try #require(
            ArrivalPreviewScreen.desk(at: brussels, bookings: try bookings(), today: eleventh)
        )
        #expect(desk.deskID == "2-041")
        #expect(desk.floor == "Level 2")
        #expect(desk.zone == nil, "the capture could not read it, so it is not carried")

        // Same day, the other building: Brussels' booking is not Coleman's.
        #expect(
            ArrivalPreviewScreen.desk(at: coleman, bookings: try bookings(), today: eleventh)
                == nil
        )
        // Same building, a day it has nothing booked.
        #expect(
            ArrivalPreviewScreen.desk(
                at: brussels, bookings: try bookings(), today: Day(2026, 8, 12)
            ) == nil
        )
    }

    // MARK: The card's own layout decisions

    /// The caption lives in `ArrivalCopy` so the three screens that describe
    /// when the alert fires cannot drift apart again — this one included.
    @Test("The line under the card is the shared sentence, until there is no desk")
    func caption() {
        #expect(ArrivalPreviewScreen.caption(hasDesk: true) == ArrivalCopy.preview)
        #expect(ArrivalPreviewScreen.caption(hasDesk: false) != ArrivalCopy.preview)
        #expect(ArrivalPreviewScreen.caption(hasDesk: false).contains("No desk booked today"))
    }

    @Test("A body with a detail line above it draws its last line as the footer")
    func footerIsSplitOff() throws {
        let content = try #require(ArrivalPreviewScreen.content(
            for: try office(SeedData.brusselsID),
            bookings: try bookings(), today: Day(2026, 8, 11), in: context
        ))
        let card = ArrivalPreviewScreen.cardText(content.body)
        #expect(card.details == ["Level 2"])
        #expect(card.footer == "Day 4 of 8 for August — tap to make it 5")
    }

    /// The bug in the card. A desk whose floor and zone were both unreadable
    /// produces a one-line body — and taking `last` unconditionally drew that
    /// single line at footnote size under a hairline with nothing above it,
    /// where iOS draws body text. The preview being wrong about what lands is
    /// the one failure this screen cannot have.
    @Test("A desk with no floor or zone keeps its only line as a line, not a footnote")
    func aOneLineBodyIsNotAFooter() throws {
        let today = Day(2026, 8, 19)
        context.insert(DeskBooking(
            officeID: SeedData.colemanID, day: today, deskID: "3C-140",
            floor: nil, zone: nil, source: .manual,
            unsureFields: ["floor", "zone"]
        ))
        try context.save()

        let content = try #require(ArrivalPreviewScreen.content(
            for: try office(SeedData.colemanID),
            bookings: try bookings(), today: today, in: context
        ))
        #expect(content.title == "3C-140")
        #expect(!content.body.contains("\n"), "nothing was readable but the count")

        let card = ArrivalPreviewScreen.cardText(content.body)
        #expect(card.details == [content.body])
        #expect(card.footer == nil, "no hairline, because there is nothing to separate")
    }

    /// The other one-line body, reached without touching the store: turning up
    /// with nothing booked on a day already recorded elsewhere.
    @Test("The already-recorded unbooked alert is one line, and it is not a footnote")
    func recordedUnbookedBodyIsOneLine() throws {
        let content = try #require(ArrivalPreviewScreen.content(
            for: try office(SeedData.colemanID),
            bookings: try bookings(), today: Day(2026, 8, 4), in: context
        ))
        let card = ArrivalPreviewScreen.cardText(content.body)
        #expect(card.details == ["No desk booked today."])
        #expect(card.footer == nil)
    }

    @Test("An empty body draws nothing rather than an empty footer under a rule")
    func emptyBody() {
        let card = ArrivalPreviewScreen.cardText("")
        #expect(card.details.isEmpty)
        #expect(card.footer == nil)
    }

    /// Three lines is what the booked alert looks like with both the place and
    /// the count on it, and the rule belongs under the count rather than under
    /// the place.
    @Test("Only the last line of a longer body becomes the footer")
    func longerBodySplit() {
        let card = ArrivalPreviewScreen.cardText("Level 3, Zone C\nsomething else\nthe count")
        #expect(card.details == ["Level 3, Zone C", "something else"])
        #expect(card.footer == "the count")
    }

    /// `UNNotificationRequest`'s content is a class the test has no reason to
    /// hold on to. Only the four strings the screen claims to match are kept,
    /// and they are read off the real request rather than supplied to it.
    private struct UNNotificationRequestFields {
        let title: String
        let subtitle: String
        let body: String
        let category: String

        init(_ request: UNNotificationRequest) {
            title = request.content.title
            subtitle = request.content.subtitle
            body = request.content.body
            category = request.content.categoryIdentifier
        }
    }
}

/// The card itself, drawn.
///
/// The only claim made here is that the screen does not trap — what it says is
/// asserted above, where a wrong word can fail for a reason. It earns its place
/// because the card takes the body apart and puts it back together line by
/// line, and the three shapes below are the three ways that split comes out.
/// A one-line body reaches the branch this review fixed, and nothing else in
/// the suite executes the drawing of it.
///
/// The screen reads `Day.today` for itself, so each state is set up by writing
/// today's booking rather than by naming a date.
@Suite("The arrival preview draws")
@MainActor
struct ArrivalPreviewRenderTests {

    private func render(_ container: ModelContainer) {
        // In a window and made key: a hosting controller laid out on its own
        // never evaluates the body, so the same test written without this
        // measures nothing at all.
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.rootViewController = UIHostingController(
            rootView: ArrivalPreviewScreen().modelContainer(container)
        )
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        Self.dismantle(window, holding: container)
    }

    /// Torn down as soon as the body has run, and this is not optional
    /// housekeeping.
    ///
    /// `makeKeyAndVisible` puts the window in the application's own window
    /// list, which retains it long after the local `window` goes out of scope.
    /// The SwiftUI graph inside it stays subscribed to the container it was
    /// handed; the container belongs to the test and dies with it; and the next
    /// test in another suite that saves a context posts a SwiftData
    /// notification straight into that dead subscriber. The whole test host
    /// goes down, taking every suite with it, and the crash is reported against
    /// whichever innocent test happened to be doing the saving.
    ///
    /// Layout has already run by the time this is called, so the body has been
    /// evaluated and the coverage counted — there is nothing left to keep alive.
    /// Containers that a rendered screen was pointed at, kept alive for the
    /// rest of the process.
    ///
    /// This is the other half of the fix, and the load-bearing half. Taking the
    /// window apart stops the view drawing, but SwiftUI does not free the graph
    /// synchronously, so an `@Query` can still be subscribed for an
    /// indeterminate while afterwards. What turns that from untidy into fatal
    /// is the container going away underneath it: the subscription is then
    /// pointing at freed storage, and the next save *anywhere in the process*
    /// posts into it and takes the whole test host down with SIGILL.
    ///
    /// The reported casualty is never the render test. It is whichever test
    /// happened to be saving — `StoreTests.init()` seeding its fixture, most
    /// often — which is why this was so hard to place: the crash names a file
    /// that has nothing wrong with it.
    ///
    /// Holding the containers costs a few in-memory stores for the length of a
    /// test run and makes the lifetime question moot. The alternative — proving
    /// every graph is freed before its container — is not something a test can
    /// actually guarantee from outside SwiftUI.
    @MainActor
    enum HeldContainers {
        static var all: [ModelContainer] = []
        static func hold(_ container: ModelContainer) { all.append(container) }
    }

    static func dismantle(_ window: UIWindow, holding container: ModelContainer? = nil) {
        if let container { HeldContainers.hold(container) }
        window.rootViewController = nil
        window.isHidden = true
        window.resignKey()
        // Detaching is not enough on its own. UIKit releases a replaced root
        // view controller on the next turn of the run loop, so without this the
        // SwiftUI graph — and the `@Query` subscription inside it — is still
        // alive when the test returns. Spinning the loop here is what actually
        // frees it, inside the test that made it, rather than at some
        // unpredictable point during a later suite.
        RunLoop.current.run(until: Date())
    }

    private func content(in container: ModelContainer) throws -> ArrivalNotifications.Content? {
        let context = container.mainContext
        // Sorted by name, because that is the order the screen's own `@Query`
        // hands them over in and the first of them is what it opens on.
        let offices = try context.fetch(FetchDescriptor<Office>())
            .sorted { $0.name < $1.name }
        return ArrivalPreviewScreen.content(
            for: ArrivalPreviewScreen.selectedOffice(in: offices, selection: nil),
            bookings: try context.fetch(FetchDescriptor<DeskBooking>()),
            today: .today,
            in: context
        )
    }

    @Test("A desk with a floor and a zone draws its count under the hairline")
    func fullBookingDraws() throws {
        let container = try Store.makeInMemoryContainer(seeded: true)
        let context = container.mainContext
        context.insert(DeskBooking(
            officeID: SeedData.brusselsID, day: .today, deskID: "2-090",
            floor: "Level 2", zone: "A", source: .manual
        ))
        try context.save()

        let drawn = try #require(try content(in: container))
        let card = ArrivalPreviewScreen.cardText(drawn.body)
        #expect(card.details == ["Level 2, Zone A"])
        #expect(card.footer != nil, "the count goes under the rule")
        render(container)
    }

    /// The shape the card got wrong: nothing readable but the desk id, so the
    /// body is one line and there is no hairline to draw.
    @Test("A desk with nothing else readable draws its one line and no hairline")
    func bareBookingDraws() throws {
        let container = try Store.makeInMemoryContainer(seeded: true)
        let context = container.mainContext
        context.insert(DeskBooking(
            officeID: SeedData.brusselsID, day: .today, deskID: "2-091",
            floor: nil, zone: nil, source: .manual, unsureFields: ["floor", "zone"]
        ))
        try context.save()

        let drawn = try #require(try content(in: container))
        let card = ArrivalPreviewScreen.cardText(drawn.body)
        #expect(card.details.count == 1)
        #expect(card.footer == nil)
        render(container)
    }

    /// One office, so the picker is gone; and nothing booked, which is the
    /// state the screen is in on most days of the year.
    @Test("With one office and nothing booked the picker goes and the prompt stays")
    func unbookedDraws() throws {
        let container = try Store.makeInMemoryContainer(seeded: true)
        let context = container.mainContext
        for booking in try context.fetch(FetchDescriptor<DeskBooking>()) {
            context.delete(booking)
        }
        let offices = try context.fetch(FetchDescriptor<Office>())
        for office in offices.dropFirst() { context.delete(office) }
        try context.save()

        let drawn = try #require(try content(in: container))
        #expect(drawn.category == .unbooked)
        #expect(ArrivalPreviewScreen.caption(hasDesk: false).contains("record the day anyway"))
        render(container)
    }

    /// The empty state, which is for someone with no offices and only them.
    @Test("With no offices at all the screen says so instead of drawing an alert")
    func emptyStateDraws() throws {
        let container = try Store.makeInMemoryContainer(seeded: false)
        #expect(try container.mainContext.fetchCount(FetchDescriptor<Office>()) == 0)
        let nothing = try content(in: container)
        #expect(nothing == nil, "nothing to draw a card from")
        render(container)
    }
}

/// `-screen` and `-capture` are how every screenshot in this repo was taken.
/// The table is worth pinning because a name that quietly fell through would
/// produce a perfectly good picture of the wrong screen, and nothing about the
/// picture would say so.
@Suite("The debug launch arguments")
@MainActor
struct DebugRouterTests {

    @Test("Every screen the flag names is the screen it opens")
    func routingTable() {
        #expect(DebugRouter.screen(for: "settings") == .settings)
        #expect(DebugRouter.screen(for: "offices") == .settings, "two names, one screen")
        #expect(DebugRouter.screen(for: "office") == .office)
        #expect(DebugRouter.screen(for: "booking") == .booking)
        #expect(DebugRouter.screen(for: "unread") == .unread)
        #expect(DebugRouter.screen(for: "add") == .add)
        #expect(DebugRouter.screen(for: "alert") == .alert)
        #expect(DebugRouter.screen(for: "leave") == .leave)
        #expect(DebugRouter.screen(for: "gauge") == .gauge)
    }

    /// No flag is the app launching normally, and that has to be the home
    /// screen rather than a blank stack.
    @Test("An absent or unrecognised screen name is the home screen")
    func unknownScreens() {
        #expect(DebugRouter.screen(for: "") == .home)
        #expect(DebugRouter.screen(for: "home") == .home)
        #expect(DebugRouter.screen(for: "aler") == .home)
        #expect(DebugRouter.screen(for: "Alert") == .home, "matched exactly, not loosely")
    }

    @Test("A flag's value is the argument after it")
    func argumentAfterAFlag() {
        let arguments = ["OfficeDaze", "-screen", "alert", "-capture", "table"]
        #expect(ProcessInfo.argument(after: "-screen", in: arguments) == "alert")
        #expect(ProcessInfo.argument(after: "-capture", in: arguments) == "table")
    }

    /// The case nobody launches on purpose: a flag typed last with its value
    /// left off, where the index after it is one past the end of the array.
    @Test("A flag with nothing after it is empty rather than a crash")
    func flagWithNoValue() {
        #expect(ProcessInfo.argument(after: "-screen", in: ["OfficeDaze", "-screen"]) == "")
        #expect(ProcessInfo.argument(after: "-screen", in: []) == "")
        #expect(ProcessInfo.argument(after: "-screen", in: ["OfficeDaze"]) == "")
    }

    /// A missed value is returned as-is rather than skipped over. `-screen
    /// -capture table` is a typo, and reading it as `-capture table` would run
    /// a capture nobody asked for; reading it as the screen name "-capture"
    /// falls through to home, which is visibly nothing happening.
    @Test("A flag followed by another flag takes that flag as its value")
    func aMissedValueIsNotSkipped() {
        let arguments = ["OfficeDaze", "-screen", "-capture", "table"]
        #expect(ProcessInfo.argument(after: "-screen", in: arguments) == "-capture")
        #expect(DebugRouter.screen(for: "-capture") == .home)
    }

    /// Nothing may stub the extractor by accident: with no `-capture` flag the
    /// app has to reach the real one, key and network and all.
    @Test("Only a named capture stubs the extractor")
    func captureStubIsOptedInto() {
        #expect(DebugRouter.stub(for: "") == nil)
        #expect(DebugRouter.stub(for: "tabel") == nil)
        #expect(DebugRouter.stub(for: "table") == .table)
        #expect(DebugRouter.stub(for: "one") == .one)
        #expect(DebugRouter.stub(for: "confirmation") == .confirmation)
        #expect(DebugRouter.stub(for: "page") == .page)
        #expect(DebugRouter.stub(for: "slow") == .slow)
        #expect(DebugRouter.stub(for: "failed") == .failed)
    }

    /// Each flag exists to put the sheet in one particular state, so each has
    /// to hand back a different sample — the counter and the bar only appear
    /// for more than one row, and the needs-checking query only for a sample
    /// that has something unread in it.
    @Test("Each capture flag hands the sheet the state it was added for")
    func stubsReturnTheirOwnSample() async throws {
        func extract(_ stub: DebugRouter.Stub) async throws -> [ParsedBooking] {
            try await DebugRouter.extractor(for: stub)(
                CaptureSamples.pixel, "image/png", Day(2026, 8, 4)
            ).0
        }

        let table = try await extract(.table)
        #expect(table.map(\.deskID) == ["CO03A424", "CO03C407", "CO03D211"])
        #expect(table.filter(\.needsChecking).count == 1, "one unread zone to query")

        let one = try await extract(.one)
        #expect(one.map(\.deskID) == ["CO03C407"], "one row, so no counter and no bar")
        #expect(one.allSatisfy { !$0.needsChecking })

        let confirmation = try await extract(.confirmation)
        #expect(confirmation.map(\.day) == [Day(2026, 8, 25)])
        #expect(confirmation.first?.unsureFields == ["zone"])

        let page = try await extract(.page)
        #expect(page.first?.floor == nil)
        #expect(page.first?.unsureFields == ["floor", "zone"])

        // The usage figure the sheet prints, on the one that carries the most.
        let usage = try await DebugRouter.extractor(for: .table)(
            CaptureSamples.pixel, "image/png", Day(2026, 8, 4)
        ).1
        #expect(usage.inputTokens == CaptureSamples.usage.inputTokens)
        #expect(usage.inputTokens > 0, "so the sheet has a figure to show")
    }

    /// `-capture failed` exists to look at the failure sheet, so it has to
    /// actually fail — and with the error whose message names the missing key.
    @Test("The failing capture throws rather than quietly succeeding")
    func failedStubThrows() async {
        await #expect(throws: CaptureError.noAPIKey) {
            try await DebugRouter.extractor(for: .failed)(
                CaptureSamples.pixel, "image/png", Day(2026, 8, 4)
            )
        }
    }
}

/// The card vocabulary every screen is built from. Nothing here draws anything
/// interesting on its own; what it does is decide, in four places, and those
/// four decisions are shared by every screen in the app.
@Suite("The shared card vocabulary")
@MainActor
struct CardsTests {

    // MARK: DetailRow

    /// The never-guess rule at its smallest. A field the model was unsure about
    /// may still carry its best reading, and putting that beside the amber
    /// marker would show a number the app has just said it does not trust.
    @Test("A field flagged for checking shows the marker and never the reading behind it")
    func markerWinsOverTheValue() {
        #expect(DetailRow.display(value: "Zone C", needsChecking: true) == .marker)
        #expect(DetailRow.display(value: nil, needsChecking: true) == .marker)
        #expect(DetailRow.display(value: "Zone C", needsChecking: true) != .text("Zone C"))
    }

    /// The other half: an empty field is an em dash, which is not the same
    /// claim as the marker and must not be drawn as one.
    @Test("An unfilled field is a dash, which is not the same as an unread one")
    func missingIsNotTheMarker() {
        #expect(DetailRow.display(value: nil, needsChecking: false) == .missing)
        #expect(DetailRow.display(value: nil, needsChecking: false) != .marker)
        #expect(DetailRow.display(value: "Level 3", needsChecking: false) == .text("Level 3"))
        // An empty string came from somewhere, so it is a value and not an
        // absence — the row prints what it was given.
        #expect(DetailRow.display(value: "", needsChecking: false) == .text(""))
    }

    // MARK: StatusStrip

    /// The bug the file's own comment names: the right-hand figure was amber
    /// whatever the strip was, which nobody saw while the green strip had
    /// nothing on its right.
    @Test("The right-hand figure takes the strip's colour, not the amber one")
    func secondaryFollowsTheTone() {
        #expect(StatusStrip.secondary(.warning) == Palette.warningSecondary)
        #expect(StatusStrip.secondary(.success) == Palette.successText)
        #expect(StatusStrip.secondary(.neutral) == Palette.secondary)
        for tone in StatusStrip.Tone.allCases where tone != .warning {
            #expect(
                StatusStrip.secondary(tone) != Palette.warningSecondary,
                "only the amber strip is amber on the right"
            )
        }
    }

    /// Four tones is four meanings, and a tone that shared another's colours
    /// would be a meaning the user cannot see. `allCases` rather than the four
    /// written out, so a fifth cannot be added without its own colours.
    @Test("No two tones wear the same colours")
    func tonesAreDistinct() {
        let tones = StatusStrip.Tone.allCases
        #expect(tones.count == 4)
        #expect(Set(tones.map(StatusStrip.surface)).count == tones.count)
        #expect(Set(tones.map(StatusStrip.text)).count == tones.count)
        #expect(Set(tones.map(StatusStrip.secondary)).count == tones.count)
    }

    /// Red means the target cannot be reached this month, and it is the only
    /// red in the app. Green means it has been met. Those two are the card
    /// shape; the two quiet ones are a pill under the dial.
    @Test("Only the two loud tones take the card shape")
    func loudness() {
        #expect(StatusStrip.isLoud(.success))
        #expect(StatusStrip.isLoud(.danger))
        #expect(!StatusStrip.isLoud(.warning))
        #expect(!StatusStrip.isLoud(.neutral))
        #expect(
            StatusStrip.Tone.allCases.filter(StatusStrip.isLoud).count == 2,
            "a new tone is quiet until someone decides otherwise"
        )
    }

    @Test("Red is the danger strip and nothing else")
    func redIsSpentOnce() {
        #expect(StatusStrip.text(.danger) == Palette.dangerText)
        #expect(StatusStrip.surface(.danger) == Palette.dangerSurface)
        for tone in StatusStrip.Tone.allCases where tone != .danger {
            #expect(StatusStrip.text(tone) != Palette.dangerText)
        }
    }

    // MARK: RowStack

    /// A hairline under the last row draws a line across a card with nothing
    /// beneath it, which is exactly the tell that a hand-built list is not a
    /// `List`.
    @Test("Hairlines go between rows and never under the last one")
    func dividersStopAtTheEnd() {
        #expect(RowStack<Office, EmptyView>.hasDivider(after: 0, of: 3))
        #expect(RowStack<Office, EmptyView>.hasDivider(after: 1, of: 3))
        #expect(!RowStack<Office, EmptyView>.hasDivider(after: 2, of: 3))
        #expect(!RowStack<Office, EmptyView>.hasDivider(after: 0, of: 1), "a lone row")
        #expect(!RowStack<Office, EmptyView>.hasDivider(after: 0, of: 0), "an empty card")
    }
}
