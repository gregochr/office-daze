import Foundation
import SwiftData
import SwiftUI
import Testing
import UIKit
@testable import OfficeDaze

/// The two hand-entry editors, taken apart.
///
/// Both were forms with a `try?` in the save and a `dismiss()` after it, which
/// is the shape of the defect this review exists for: a write that never landed
/// looked exactly like one that did. What is worth asserting about either
/// screen is not that it renders — it is which record the date turns into,
/// which fields survive the round trip through the form, and what happens on
/// the one path nobody had ever taken, the refused write.
///
/// Every date here is pinned to a fixed zone. `Day.today` is the *local* day
/// and both screens hand a `DatePicker` a local instant, so a test that let the
/// simulator pick the zone would be asserting about the machine it ran on.
@Suite("The hand-entry editors")
@MainActor
struct EditorScreenTests {

    let container: ModelContainer

    init() throws {
        container = try Store.makeInMemoryContainer(seeded: true)
    }

    /// Far enough west that midnight UTC is the previous evening — the zone the
    /// wave-0 picker fix was made for.
    static let losAngeles = TimeZone(identifier: "America/Los_Angeles")!

    private func offices() throws -> [Office] {
        try container.mainContext.fetch(FetchDescriptor<Office>()).sorted { $0.name < $1.name }
    }

    private func attendance() throws -> [AttendanceDay] {
        try container.mainContext.fetch(FetchDescriptor<AttendanceDay>())
    }

    private func plannedDays() throws -> [PlannedDay] {
        try container.mainContext.fetch(FetchDescriptor<PlannedDay>())
    }

    /// A store that refuses. SwiftData will not fail on demand, and the branch
    /// worth the most here is the one that only runs when it does.
    struct StoreRefused: LocalizedError {
        var errorDescription: String? { "the store is full" }
    }

    // MARK: - The booking editor: what it opens showing

    @Test("Adding a booking opens on today, in the zone the phone is in")
    func addingOpensOnToday() throws {
        let draft = BookingEditorScreen.draft(
            for: nil, offices: try offices(),
            today: Day(2026, 8, 5), in: Self.losAngeles
        )
        // The instant matters, not just the day: `startOfDayUTC` here would
        // render as the 4th in Los Angeles, which is the bug the local bridges
        // exist to stop.
        #expect(Day(localOf: draft.date, in: Self.losAngeles) == Day(2026, 8, 5))
        #expect(Day.localCalendar(Self.losAngeles).component(.hour, from: draft.date) == 12)
        #expect(draft.deskID.isEmpty)
        #expect(draft.focused == nil, "there is nothing to be unsure about yet")
    }

    @Test("One office is chosen for you; two are not")
    func singleOfficeIsPreselected() throws {
        let all = try offices()
        let one = try #require(all.first)

        #expect(BookingEditorScreen.draft(for: nil, offices: [one]).officeID == one.id)
        #expect(all.count > 1, "the seed has to have more than one for the other half to mean anything")
        #expect(
            BookingEditorScreen.draft(for: nil, offices: all).officeID == nil,
            "picking one of several would put a building in the form the user never chose"
        )
        #expect(BookingEditorScreen.draft(for: nil, offices: []).officeID == nil)
    }

    @Test("Editing a booking opens showing every field that booking holds")
    func editingPrefillsEveryField() throws {
        let office = try #require(try offices().first)
        let booking = DeskBooking(
            officeID: office.id, day: Day(2026, 8, 12), deskID: "4C-19",
            floor: "4", zone: "C", startTime: "08:30", endTime: "17:00",
            source: .capture
        )
        let draft = BookingEditorScreen.draft(
            for: booking, offices: try offices(), in: Self.losAngeles
        )

        #expect(draft.officeID == office.id)
        #expect(Day(localOf: draft.date, in: Self.losAngeles) == Day(2026, 8, 12))
        #expect(draft.deskID == "4C-19")
        #expect(draft.floor == "4")
        #expect(draft.zone == "C")
        #expect(draft.startTime == "08:30")
        #expect(draft.endTime == "17:00")
    }

    /// The negative: an absent optional is an empty box, not the string
    /// `"nil"`, and not the last booking's floor left behind.
    @Test("A booking with nothing optional on it opens with those boxes empty")
    func editingLeavesAbsentFieldsEmpty() throws {
        let office = try #require(try offices().first)
        let booking = DeskBooking(
            officeID: office.id, day: Day(2026, 8, 12), deskID: "D1", source: .manual
        )
        let draft = BookingEditorScreen.draft(for: booking, offices: try offices())

        #expect(draft.floor.isEmpty)
        #expect(draft.zone.isEmpty)
        #expect(draft.startTime.isEmpty)
        #expect(draft.endTime.isEmpty)
        #expect(draft.focused == nil)
    }

    // MARK: - The booking editor: where the cursor lands

    @Test("The cursor lands in the first field the capture could not read")
    func focusFollowsTheFirstUnsureField() {
        #expect(BookingEditorScreen.initialFocus(["zone", "floor"]) == .zone)
        #expect(BookingEditorScreen.initialFocus(["floor", "zone"]) == .floor)
        #expect(BookingEditorScreen.initialFocus(["deskId"]) == .desk)
        #expect(BookingEditorScreen.initialFocus(["deskID"]) == .desk)
        #expect(BookingEditorScreen.initialFocus(["startTime"]) == .startTime)
        #expect(BookingEditorScreen.initialFocus(["endTime"]) == .endTime)
    }

    /// The negative, and the reason the rule is `compactMap` then `first`
    /// rather than `first` then `map`: a schema that grows a key the editor has
    /// no box for must be stepped over, not allowed to swallow the focus. The
    /// other way round, `["officeName", "zone"]` opens a keyboard on nothing
    /// and the amber marker leads nowhere.
    @Test("A field the editor has no box for is stepped over, not focused")
    func focusSkipsUnknownFields() {
        #expect(BookingEditorScreen.initialFocus(["officeName", "zone"]) == .zone)
        #expect(BookingEditorScreen.initialFocus(["officeName"]) == nil)
        #expect(BookingEditorScreen.initialFocus([]) == nil)
    }

    @Test("An unsure field arriving on the booking itself is what moves the cursor")
    func focusComesFromTheBooking() throws {
        let office = try #require(try offices().first)
        let booking = DeskBooking(
            officeID: office.id, day: Day(2026, 8, 12), deskID: "D1",
            source: .capture, unsureFields: ["zone"]
        )
        #expect(
            BookingEditorScreen.draft(for: booking, offices: try offices()).focused == .zone
        )
    }

    // MARK: - The booking editor: whether Save is live

    @Test("Save needs an office and a desk, and a desk of spaces is no desk")
    func canSaveNeedsBoth() {
        let office = UUID()
        #expect(BookingEditorScreen.canSave(officeID: office, deskID: "4C-19"))
        #expect(!BookingEditorScreen.canSave(officeID: nil, deskID: "4C-19"))
        #expect(!BookingEditorScreen.canSave(officeID: office, deskID: ""))
        #expect(
            !BookingEditorScreen.canSave(officeID: office, deskID: "   "),
            "a booking whose desk is whitespace is not a booking"
        )
        #expect(BookingEditorScreen.canSave(officeID: office, deskID: " D1 "))
    }

    // MARK: - The booking editor: what the form means as a booking

    @Test("A typed booking is trimmed, blanks become absences, and nothing is flagged")
    func candidateNormalisesTheForm() {
        let office = UUID()
        let candidate = BookingEditorScreen.candidate(
            officeID: office,
            date: Day(2026, 8, 12).localNoon(in: Self.losAngeles),
            deskID: "  4C-19  ",
            floor: "  ",
            zone: " C ",
            startTime: "",
            endTime: "\n",
            in: Self.losAngeles
        )

        #expect(candidate.officeID == office)
        #expect(candidate.day == Day(2026, 8, 12))
        #expect(candidate.deskID == "4C-19")
        #expect(candidate.floor == nil, "whitespace is an absence too")
        #expect(candidate.zone == "C")
        #expect(candidate.startTime == nil)
        #expect(candidate.endTime == nil)
        #expect(candidate.source == .manual)
        #expect(
            candidate.unsureFields.isEmpty,
            "the person typing knows what they left out — nothing typed by hand is ever flagged"
        )
    }

    // MARK: - The booking editor: the write that did not land

    @Test("A booking that saved closes the editor, and saves what was on the form")
    func aSaveThatLandedClosesTheEditor() {
        var received: [BookingMerge.Candidate] = []
        let candidate = BookingMerge.Candidate(
            officeID: UUID(), day: Day(2026, 8, 12), deskID: "4C-19", source: .manual
        )

        let outcome = BookingEditorScreen.save(candidate) { received.append($0) }

        #expect(outcome == .written)
        #expect(outcome.mayDismiss)
        #expect(outcome.message == nil)
        #expect(received == [candidate], "the store is handed the form, once, unaltered")
    }

    /// The defect itself. `try?` and an unconditional `dismiss()` meant a
    /// refused write closed the editor exactly as a successful one did: the
    /// user watched the screen slide away and believed the desk was booked.
    @Test("A booking that could not be saved keeps the editor open and says why")
    func aRefusedSaveKeepsTheEditorOpen() throws {
        var attempts = 0
        let candidate = BookingMerge.Candidate(
            officeID: UUID(), day: Day(2026, 8, 12), deskID: "4C-19", source: .manual
        )

        let outcome = BookingEditorScreen.save(candidate) { received in
            attempts += 1
            #expect(received == candidate)
            throw StoreRefused()
        }

        #expect(attempts == 1)
        #expect(!outcome.mayDismiss, "the editor must not close on a write that never landed")
        let message = try #require(outcome.message)
        #expect(message.contains("the store is full"), "it says what the store said")
        #expect(message.contains("12 August"), "and which day was not recorded")
        #expect(message.contains("still here"), "and that the typing survived")
    }

    @Test("A deletion that failed says the booking is still there, not that it was not saved")
    func aRefusedDeleteSaysTheBookingRemains() {
        var attempts = 0

        let outcome = BookingEditorScreen.delete {
            attempts += 1
            throw StoreRefused()
        }

        #expect(attempts == 1)
        #expect(!outcome.mayDismiss)
        #expect(outcome.message?.contains("still there") == true)
        #expect(
            outcome.message?.contains("saved") != true,
            "telling someone their deletion failed with the word 'saved' is worse than silence"
        )
    }

    @Test("A deletion that landed closes the editor")
    func aDeleteThatLandedClosesTheEditor() {
        var attempts = 0
        let outcome = BookingEditorScreen.delete { attempts += 1 }

        #expect(attempts == 1)
        #expect(outcome == .written)
        #expect(outcome.message == nil)
    }

    /// End to end through the real store, so the closure the screen actually
    /// passes is the one under test: typing a booking for a day that already
    /// has one corrects it rather than adding a second, and manual outranks
    /// capture.
    @Test("A booking typed over a captured one corrects it rather than adding a second")
    func savingThroughTheRealStoreUpserts() throws {
        let context = container.mainContext
        let office = try #require(try offices().first)
        let day = Day(2026, 8, 26)
        try BookingStore.upsert(
            BookingMerge.Candidate(
                officeID: office.id, day: day, deskID: "OLD", source: .capture,
                unsureFields: ["zone"]
            ),
            in: context
        )

        let candidate = BookingEditorScreen.candidate(
            officeID: office.id,
            date: day.localNoon(in: Self.losAngeles),
            deskID: "NEW", floor: "", zone: "", startTime: "", endTime: "",
            in: Self.losAngeles
        )
        let outcome = BookingEditorScreen.save(candidate) {
            try BookingStore.upsert($0, in: context)
        }

        #expect(outcome == .written)
        let held = try context.fetch(FetchDescriptor<DeskBooking>())
            .filter { $0.day == day && $0.officeID == office.id }
        #expect(held.count == 1)
        #expect(held.first?.deskID == "NEW")
        #expect(held.first?.source == .manual)
        #expect(held.first?.unsureFields.isEmpty == true, "answering the amber marker clears it")
    }

    // MARK: - The attendance editor: past, future, and today

    /// The boundary, which is the day this screen is opened on most often. It
    /// has to fall on the attendance side, because `BookingStore` draws its own
    /// line in the same place — `recordAttendance` takes `day <= today` and
    /// `recordPlanned` takes `day > today`. A screen that called today a plan
    /// would hand it to the one store call that refuses it.
    @Test("A past day is attendance, a future day is a plan, and today is attendance")
    func aheadIsStrictlyAfterToday() {
        let today = Day(2026, 8, 12)
        #expect(!AttendanceEditorScreen.isAhead(Day(2026, 8, 11), today: today))
        #expect(!AttendanceEditorScreen.isAhead(today, today: today), "today is not ahead of itself")
        #expect(AttendanceEditorScreen.isAhead(Day(2026, 8, 13), today: today))
    }

    @Test("No date is both a day worked and a day planned")
    func noDateIsBoth() {
        let today = Day(2026, 8, 12)
        for offset in -3...3 {
            let day = today.adding(days: offset)
            let ahead = AttendanceEditorScreen.isAhead(day, today: today)
            // The store is the other half of the claim: exactly one of its two
            // calls will accept any given day.
            #expect(ahead == (day > today))
            #expect(ahead != (day <= today), "\(day) claimed to be neither, or both")
        }
    }

    @Test("Today is recorded as a day attended, not as a plan")
    func todayIsRecordedAsAttendance() throws {
        let context = container.mainContext
        let office = try #require(try offices().first)
        let today = Day(2026, 8, 12)
        var planCalls = 0

        let written = AttendanceEditorScreen.record(
            day: today, officeID: office.id, fraction: 1.0, today: today,
            attend: { day, id, fraction in
                try BookingStore.recordAttendance(
                    day: day, officeID: id, source: .manual,
                    fraction: fraction, today: today, in: context
                ) != nil
            },
            plan: { _, _ in planCalls += 1; return true }
        )

        #expect(written == .attended(1.0))
        #expect(planCalls == 0, "today must never reach the call that refuses the past")
        let rows = try attendance()
        let plans = try plannedDays()
        #expect(rows.contains { $0.day == today && $0.officeID == office.id })
        #expect(!plans.contains { $0.day == today })
    }

    @Test("A day still ahead becomes a plan, and never touches attendance")
    func aFutureDayBecomesAPlan() throws {
        let context = container.mainContext
        let office = try #require(try offices().first)
        let today = Day(2026, 8, 12)
        let ahead = Day(2026, 8, 19)
        var attendCalls = 0

        let written = AttendanceEditorScreen.record(
            day: ahead, officeID: office.id, fraction: 1.0, today: today,
            attend: { _, _, _ in attendCalls += 1; return true },
            plan: { day, id in
                try BookingStore.recordPlanned(
                    day: day, officeID: id, today: today, in: context
                ) != nil
            }
        )

        #expect(written == .planned)
        #expect(attendCalls == 0, "a day that has not happened cannot have been worked")
        let plans = try plannedDays()
        let rows = try attendance()
        #expect(plans.contains { $0.day == ahead && $0.officeID == office.id })
        #expect(!rows.contains { $0.day == ahead })
    }

    @Test("A half day on prem is written as half a day")
    func halfDayIsCarriedThrough() throws {
        let context = container.mainContext
        let office = try #require(try offices().first)
        let today = Day(2026, 8, 12)
        let worked = Day(2026, 8, 11)

        let written = AttendanceEditorScreen.record(
            day: worked, officeID: office.id,
            fraction: AttendanceEditorScreen.halfDay, today: today,
            attend: { day, id, fraction in
                try BookingStore.recordAttendance(
                    day: day, officeID: id, source: .manual,
                    fraction: fraction, today: today, in: context
                ) != nil
            },
            plan: { _, _ in Issue.record("a past day is not a plan"); return false }
        )

        #expect(written == .attended(0.5))
        let row = try #require(try attendance().first { $0.day == worked && $0.officeID == office.id })
        #expect(row.fraction == 0.5)
        #expect(row.source == .manual)
    }

    /// The other half of the fraction rule: a plan has no fraction to put a
    /// half day in, so the picker is hidden for a future date and whatever it
    /// was last left on must not follow the date forward.
    @Test("A half day chosen and then dated forward is not carried into the plan")
    func halfDayDoesNotSurviveBecomingAPlan() throws {
        let context = container.mainContext
        let office = try #require(try offices().first)
        let today = Day(2026, 8, 12)
        let ahead = Day(2026, 8, 19)

        let written = AttendanceEditorScreen.record(
            day: ahead, officeID: office.id,
            fraction: AttendanceEditorScreen.halfDay, today: today,
            attend: { _, _, _ in Issue.record("a future day is not attendance"); return false },
            plan: { day, id in
                try BookingStore.recordPlanned(
                    day: day, officeID: id, today: today, in: context
                ) != nil
            }
        )

        #expect(written == .planned, "not `.attended(0.5)` — a plan is whole or it is nothing")
        #expect(try plannedDays().contains { $0.day == ahead })
    }

    // MARK: - The attendance editor: the write the store refused

    @Test("A refusal is not a save, whichever of the two calls refused")
    func aRefusalIsNotASave() {
        let today = Day(2026, 8, 12)
        var seen: [Day] = []

        let past = AttendanceEditorScreen.record(
            day: Day(2026, 8, 11), officeID: UUID(), fraction: 1.0, today: today,
            attend: { day, _, _ in seen.append(day); return false },
            plan: { _, _ in Issue.record("wrong branch"); return true }
        )
        let future = AttendanceEditorScreen.record(
            day: Day(2026, 8, 13), officeID: UUID(), fraction: 1.0, today: today,
            attend: { _, _, _ in Issue.record("wrong branch"); return true },
            plan: { day, _ in seen.append(day); return false }
        )

        #expect(past == .refused)
        #expect(future == .refused)
        #expect(seen == [Day(2026, 8, 11), Day(2026, 8, 13)])
    }

    @Test("A store that threw is reported as a failure, naming the day and the reason")
    func aThrownErrorIsReported() {
        let today = Day(2026, 8, 12)
        let written = AttendanceEditorScreen.record(
            day: Day(2026, 8, 11), officeID: UUID(), fraction: 1.0, today: today,
            attend: { _, _, _ in throw StoreRefused() },
            plan: { _, _ in Issue.record("wrong branch"); return true }
        )

        guard case .failed(let why) = written else {
            Issue.record("a throwing store is not a save: \(written)")
            return
        }
        #expect(why.contains("the store is full"))
        #expect(why.contains("11 August"))
    }

    /// The refusal nobody could see. `alreadyRecorded` only looks at the office
    /// on screen, so Save is live for a day already recorded in full somewhere
    /// else — and the store answers that with nil. The tap did nothing and said
    /// nothing.
    @Test("A day already full at another office is refused, and the refusal names it")
    func aDayFullElsewhereIsRefusedAndExplained() throws {
        let context = container.mainContext
        let all = try offices()
        let here = try #require(all.first)
        let elsewhere = try #require(all.last)
        #expect(here.id != elsewhere.id)
        let today = Day(2026, 8, 12)
        let worked = Day(2026, 8, 11)
        try BookingStore.recordAttendance(
            day: worked, officeID: elsewhere.id, source: .manual,
            fraction: 1.0, today: today, in: context
        )

        // Save is live: this office holds nothing for that day.
        #expect(
            AttendanceEditorScreen.canSave(
                officeID: here.id,
                alreadyRecorded: AttendanceEditorScreen.alreadyRecorded(
                    day: worked, officeID: here.id, today: today,
                    attendance: try attendance(), planned: try plannedDays()
                )
            )
        )

        let written = AttendanceEditorScreen.record(
            day: worked, officeID: here.id,
            fraction: AttendanceEditorScreen.halfDay, today: today,
            attend: { day, id, fraction in
                try BookingStore.recordAttendance(
                    day: day, officeID: id, source: .manual,
                    fraction: fraction, today: today, in: context
                ) != nil
            },
            plan: { _, _ in Issue.record("wrong branch"); return true }
        )

        #expect(written == .refused)
        #expect(
            try attendance().filter { $0.day == worked }.count == 1,
            "and nothing was written"
        )

        let why = AttendanceEditorScreen.refusal(
            day: worked, officeID: here.id,
            fraction: AttendanceEditorScreen.halfDay, today: today,
            attendance: try attendance(), planned: try plannedDays()
        )
        #expect(why.contains("11 August"))
        #expect(why.contains("a whole day"), "how much is already on the day")
        #expect(why.contains("half a day"), "and how much was being added")
        #expect(why.contains("another office"))
    }

    @Test("A day already planned is refused in the words of a plan, not of attendance")
    func aPlannedDayIsRefusedAsAPlan() throws {
        let context = container.mainContext
        let office = try #require(try offices().first)
        let today = Day(2026, 8, 12)
        let ahead = Day(2026, 8, 19)
        try BookingStore.recordPlanned(
            day: ahead, officeID: office.id, today: today, in: context
        )

        let why = AttendanceEditorScreen.refusal(
            day: ahead, officeID: office.id, fraction: 1.0, today: today,
            attendance: try attendance(), planned: try plannedDays()
        )
        #expect(why.contains("already planned"))
        #expect(!why.contains("recorded at this office"))
    }

    @Test("A day recorded at this very office is refused in those words")
    func aRecordedDayIsRefusedByName() throws {
        let context = container.mainContext
        let office = try #require(try offices().first)
        let today = Day(2026, 8, 12)
        let worked = Day(2026, 8, 11)
        try BookingStore.recordAttendance(
            day: worked, officeID: office.id, source: .manual,
            fraction: 1.0, today: today, in: context
        )

        let why = AttendanceEditorScreen.refusal(
            day: worked, officeID: office.id, fraction: 1.0, today: today,
            attendance: try attendance(), planned: try plannedDays()
        )
        #expect(why.contains("already recorded at this office"))
    }

    /// The fallback, which exists because the store may grow a reason this
    /// screen cannot see. It must still say that nothing happened rather than
    /// leave the day looking recorded.
    @Test("A refusal with no visible reason still says nothing was added")
    func anUnexplainedRefusalStillSaysNothingHappened() throws {
        let why = AttendanceEditorScreen.refusal(
            day: Day(2026, 8, 11), officeID: UUID(), fraction: 1.0,
            today: Day(2026, 8, 12), attendance: [], planned: []
        )
        #expect(why.contains("Nothing was added"))
        #expect(why.contains("11 August"))
    }

    // MARK: - The attendance editor: whether Save is live

    @Test("Save needs an office, and goes dead once that office holds the day")
    func attendanceCanSave() throws {
        let context = container.mainContext
        let all = try offices()
        let here = try #require(all.first)
        let elsewhere = try #require(all.last)
        let today = Day(2026, 8, 12)
        let worked = Day(2026, 8, 11)

        #expect(!AttendanceEditorScreen.canSave(officeID: nil, alreadyRecorded: false))
        #expect(AttendanceEditorScreen.canSave(officeID: here.id, alreadyRecorded: false))
        #expect(!AttendanceEditorScreen.canSave(officeID: here.id, alreadyRecorded: true))

        #expect(
            !AttendanceEditorScreen.alreadyRecorded(
                day: worked, officeID: here.id, today: today,
                attendance: try attendance(), planned: try plannedDays()
            )
        )
        try BookingStore.recordAttendance(
            day: worked, officeID: here.id, source: .manual,
            fraction: 1.0, today: today, in: context
        )
        #expect(
            AttendanceEditorScreen.alreadyRecorded(
                day: worked, officeID: here.id, today: today,
                attendance: try attendance(), planned: try plannedDays()
            )
        )
        #expect(
            !AttendanceEditorScreen.alreadyRecorded(
                day: worked, officeID: elsewhere.id, today: today,
                attendance: try attendance(), planned: try plannedDays()
            ),
            "a second site on the same day is a real thing — the store decides, not the button"
        )
        #expect(
            !AttendanceEditorScreen.alreadyRecorded(
                day: worked, officeID: nil, today: today,
                attendance: try attendance(), planned: try plannedDays()
            ),
            "with no office chosen there is nothing to have already recorded"
        )
    }

    /// The lists are consulted separately, and that is deliberate: a day held
    /// both as a plan and as a day attended is the ordinary life of a forecast
    /// that came true, not a clash.
    @Test("A plan does not make the same day look already attended, nor the reverse")
    func plansAndAttendanceAreNotConfused() throws {
        let context = container.mainContext
        let office = try #require(try offices().first)
        let today = Day(2026, 8, 12)
        let ahead = Day(2026, 8, 19)
        try BookingStore.recordPlanned(
            day: ahead, officeID: office.id, today: today, in: context
        )

        // The plan is seen when the date is ahead.
        #expect(
            AttendanceEditorScreen.alreadyRecorded(
                day: ahead, officeID: office.id, today: today,
                attendance: try attendance(), planned: try plannedDays()
            )
        )
        // And is invisible to the other branch: once that day arrives, the same
        // date is recordable as attendance.
        #expect(
            !AttendanceEditorScreen.alreadyRecorded(
                day: ahead, officeID: office.id, today: ahead,
                attendance: try attendance(), planned: try plannedDays()
            ),
            "the day the plan was for is the day it must be recordable as worked"
        )
    }

    // MARK: - The attendance editor: what the footer promises

    @Test("The footer says which of the two records the date will become")
    func footerNamesTheRecord() throws {
        let office = try #require(try offices().first)
        let today = Day(2026, 8, 12)

        let ahead = AttendanceEditorScreen.footer(
            day: Day(2026, 8, 19), officeID: office.id, fraction: 1.0,
            today: today, attendance: [], planned: []
        )
        #expect(ahead.contains("forecast"))

        let past = AttendanceEditorScreen.footer(
            day: Day(2026, 8, 11), officeID: office.id, fraction: 1.0,
            today: today, attendance: [], planned: []
        )
        #expect(past.contains("counts toward the month"))
        #expect(!past.contains("forecast"))

        let half = AttendanceEditorScreen.footer(
            day: Day(2026, 8, 11), officeID: office.id,
            fraction: AttendanceEditorScreen.halfDay,
            today: today, attendance: [], planned: []
        )
        #expect(half.contains("Half a day"))
    }

    /// A half day is only offered for a day already worked, so the footer must
    /// not start promising half-day arithmetic when the date moves forward and
    /// the picker disappears.
    @Test("The half-day footer does not survive the date moving into the future")
    func halfDayFooterIsOnlyForThePast() throws {
        let office = try #require(try offices().first)
        let footer = AttendanceEditorScreen.footer(
            day: Day(2026, 8, 19), officeID: office.id,
            fraction: AttendanceEditorScreen.halfDay,
            today: Day(2026, 8, 12), attendance: [], planned: []
        )
        #expect(!footer.contains("Half a day"))
        #expect(footer.contains("forecast"))
    }

    @Test("The footer stops promising anything once the day is already held")
    func footerAdmitsADayAlreadyHeld() throws {
        let context = container.mainContext
        let office = try #require(try offices().first)
        let today = Day(2026, 8, 12)
        let worked = Day(2026, 8, 11)
        let ahead = Day(2026, 8, 19)
        try BookingStore.recordAttendance(
            day: worked, officeID: office.id, source: .manual,
            fraction: 1.0, today: today, in: context
        )
        try BookingStore.recordPlanned(
            day: ahead, officeID: office.id, today: today, in: context
        )

        #expect(
            AttendanceEditorScreen.footer(
                day: worked, officeID: office.id, fraction: 1.0, today: today,
                attendance: try attendance(), planned: try plannedDays()
            ) == "That day is already recorded at this office."
        )
        #expect(
            AttendanceEditorScreen.footer(
                day: ahead, officeID: office.id, fraction: 1.0, today: today,
                attendance: try attendance(), planned: try plannedDays()
            ) == "That day is already planned for this office."
        )
    }

    // MARK: - The bodies, rendered

    /// Runs a view's `body` for real, and hands back what it drew.
    ///
    /// A hosting controller on its own is not enough — SwiftUI does not
    /// evaluate `body` until the view is in a window that has been laid out,
    /// and a `layoutIfNeeded` on a detached view returns having run nothing.
    /// That distinction is the difference between a test that proves the screen
    /// builds and one that only looks as though it does.
    private func render(_ view: some View) -> UIView {
        let host = UIHostingController(rootView: view.modelContainer(container))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.rootViewController = host
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        let drawn = host.view!
        // See ArrivalPreviewRenderTests.dismantle: a window left key outlives
        // the container it was handed and crashes the host from another suite.
        // The view is held here first, so what it drew is still there to be
        // asserted on after it comes out of the hierarchy.
        ArrivalPreviewRenderTests.dismantle(window, holding: container)
        return drawn
    }

    /// Every rule above is a `static` tested without a screen, which leaves one
    /// thing they cannot say between them: that the form those rules feed
    /// actually builds. A `Picker` whose tag type stops matching its selection,
    /// or a `DatePicker` handed an instant its calendar cannot render, fails
    /// here and nowhere else — and the two `.tag(Self.fullDay)` segments are
    /// exactly that kind of coupling.
    @Test("The booking editor's form builds over a real store, showing what it saves")
    func bookingEditorRenders() throws {
        let office = try #require(try offices().first)
        let booking = try #require(
            try container.mainContext.fetch(FetchDescriptor<DeskBooking>())
                .first { $0.officeID == office.id }
        )
        let view = render(NavigationStack { BookingEditorScreen(booking: booking) })

        #expect(view.bounds.width == 393, "it laid out at the size it was given")
        #expect(!view.subviews.isEmpty, "and the form drew something")

        // The seeded Brussels booking is the amber one, so this render is the
        // branch that names an unread field in the footer rather than the one
        // that explains a blank box.
        #expect(booking.unsureFields == ["zone"])
        #expect(BookingEditorScreen.unreadFieldNames(booking.unsureFields) == "zone")
        let draft = BookingEditorScreen.draft(for: booking, offices: try offices())
        #expect(draft.focused == .zone)
        #expect(BookingEditorScreen.canSave(officeID: draft.officeID, deskID: draft.deskID))
    }

    /// The other branch of the same body: a new booking, so no Delete section
    /// and the footer that explains a blank box rather than an unread one.
    @Test("The booking editor's form builds for a booking that does not exist yet")
    func bookingEditorRendersForANewBooking() throws {
        let view = render(NavigationStack { BookingEditorScreen() })

        #expect(!view.subviews.isEmpty)
        let draft = BookingEditorScreen.draft(for: nil, offices: try offices())
        #expect(
            !BookingEditorScreen.canSave(officeID: draft.officeID, deskID: draft.deskID),
            "Save opens dead: the seed has two offices and no desk has been typed"
        )
    }

    @Test("The attendance editor's form builds, opening on a day it can record")
    func attendanceEditorRenders() throws {
        let view = render(NavigationStack { AttendanceEditorScreen() })

        #expect(!view.subviews.isEmpty)

        // The screen opens on `Day.today`, so this is the one place the
        // defaulted `today:` argument every rule above pins by hand is
        // exercised as the screen itself calls it. Whatever date the suite runs
        // on, today is the attendance side of the boundary — which is what puts
        // the half-day picker on screen in the render above, and is the branch
        // a `>=` here would silently swap.
        #expect(!AttendanceEditorScreen.isAhead(.today))
        #expect(
            !AttendanceEditorScreen.alreadyRecorded(
                day: .today, officeID: nil,
                attendance: try attendance(), planned: try plannedDays()
            ),
            "with no office chosen there is nothing for today to have been recorded at"
        )
        #expect(
            !AttendanceEditorScreen.canSave(officeID: nil, alreadyRecorded: false),
            "and Save stays dead until one is picked"
        )
    }
}
