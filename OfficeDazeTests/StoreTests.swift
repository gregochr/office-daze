import Foundation
import SwiftData
import Testing
@testable import OfficeDaze

@Suite("Seed data and the store")
@MainActor
struct StoreTests {

    let container: ModelContainer

    init() throws {
        container = try Store.makeInMemoryContainer(seeded: true)
    }

    @Test("The six entities open, and the sample month lands")
    func seeds() throws {
        let context = container.mainContext
        #expect(try context.fetchCount(FetchDescriptor<Office>()) == 2)
        #expect(try context.fetchCount(FetchDescriptor<DeskBooking>()) == 4)
        #expect(try context.fetchCount(FetchDescriptor<AttendanceDay>()) == 4)
        #expect(try context.fetchCount(FetchDescriptor<LeaveDay>()) == 3)
    }

    @Test("The offices are the design's two, in different colours")
    func offices() throws {
        let offices = try container.mainContext.fetch(FetchDescriptor<Office>())
            .sorted { $0.name < $1.name }
        #expect(offices.map(\.name) == ["Brussels", "Coleman"])
        #expect(Set(offices.map(\.colourHex)).count == 2, "never the same colour twice")
        // Hoisted out of #expect: `allSatisfy` is `rethrows`, and the macro
        // cannot tell a non-throwing closure from a throwing one inside it.
        let fiftyMetres = offices.allSatisfy { $0.radiusMetres == 50 }
        let located = offices.allSatisfy(\.isLocated)
        #expect(fiftyMetres)
        #expect(located, "both are geocoded, so both can be monitored")
    }

    @Test("The bookings are the four on the home screen")
    func bookings() throws {
        let bookings = try container.mainContext.fetch(FetchDescriptor<DeskBooking>())
            .sorted { $0.day < $1.day }
        #expect(bookings.map(\.deskID) == ["3C-114", "3C-116", "2-041", "3C-121"])
        #expect(bookings.map(\.day) == [
            Day(2026, 8, 5), Day(2026, 8, 6), Day(2026, 8, 11), Day(2026, 8, 12),
        ])
        #expect(bookings[0].hoursText == "09:00 – 17:00")
    }

    /// The never-guess rule, at rest in the store: the Brussels booking's zone
    /// was not readable, so it is absent *and* named.
    @Test("An unread field is absent and flagged, not blank and silent")
    func needsChecking() throws {
        let brussels = try #require(
            try container.mainContext.fetch(FetchDescriptor<DeskBooking>())
                .first { $0.deskID == "2-041" }
        )
        #expect(brussels.zone == nil)
        #expect(brussels.unsureFields == ["zone"])
        #expect(brussels.needsChecking)
    }

    /// You can turn up without booking. The nullable bookingID is what makes
    /// that recordable, and two of the seeded days exercise it.
    @Test("Attendance stands on its own, with or without a booking")
    func attendanceWithoutBooking() throws {
        let attendance = try container.mainContext.fetch(FetchDescriptor<AttendanceDay>())
        #expect(attendance.filter { $0.bookingID == nil }.count == 2)
        #expect(attendance.filter { $0.bookingID != nil }.count == 2)
    }

    @Test("The seeded month is the worked example")
    func quotaFromTheStore() throws {
        let snapshot = try QuotaService.snapshot(
            for: SeedData.month, today: Day(2026, 8, 4), in: container.mainContext
        )
        #expect(snapshot.result.workingDays == 20)
        #expect(snapshot.result.leaveTaken == 3)
        #expect(snapshot.result.relief == 0, "three days is short of a block")
        #expect(snapshot.result.target == 8)
        #expect(snapshot.result.attended == 4, "London 3, Brussels 1")
    }

    @Test("The office cards split the month by office")
    func perOfficeCounts() throws {
        let snapshot = try QuotaService.snapshot(
            for: SeedData.month, today: Day(2026, 8, 4), in: container.mainContext
        )
        #expect(snapshot.attendedByOffice[SeedData.colemanID] == 3)
        #expect(snapshot.attendedByOffice[SeedData.brusselsID] == 1)
    }

    /// The postcode is its own field, but people type it into the address as
    /// well. Appending it regardless gave "… 1210 Brussels 1210".
    @Test("A postcode already in the address is not appended twice")
    func addressFormatting() throws {
        let offices = try container.mainContext.fetch(FetchDescriptor<Office>())
        let brussels = try #require(offices.first { $0.name == "Brussels" })
        let coleman = try #require(offices.first { $0.name == "Coleman" })
        #expect(fullAddress(brussels) == "1 Boulevard du Roi Albert II, 1210 Brussels")
        #expect(fullAddress(coleman) == "63 Coleman Street, London EC2R 5BB")
    }

    /// A workshop or a meeting is a day on prem with no desk behind it. The
    /// target counts days worked, not desks reserved, so it counts the same.
    @Test("A day recorded by hand with no booking counts toward the month")
    func attendanceWithoutABooking() throws {
        let context = container.mainContext
        func attended() throws -> Double {
            try QuotaService.snapshot(
                for: SeedData.month, today: Day(2026, 8, 4), in: context
            ).result.attended
        }
        let before = try attended()

        // The 7th at Brussels: a working day in the seeded month that is
        // genuinely past by the 10th, so neither the future-day guard nor the
        // day-already-recorded guard is what this test is about. It used to be
        // the 3rd, which the seed already holds for Coleman — the assertion
        // below then read a second row on one date as a second day worked,
        // which is the very thing the day-level guard now refuses.
        let recorded = try #require(
            try BookingStore.recordAttendance(
                day: Day(2026, 8, 7), officeID: SeedData.brusselsID,
                source: .manual, today: Day(2026, 8, 10), in: context
            )
        )
        #expect(recorded.bookingID == nil, "there was no desk to point at")
        #expect(try attended() == before + 1)

        try BookingStore.deleteAttendance(recorded, in: context)
        #expect(try attended() == before)
    }

    /// Recording a day still to come made the gauge claim a day that had not
    /// happened — and collapsed the difference between met and on track, which
    /// is exactly that attendance counts days behind you.
    @Test("A day that has not happened cannot be recorded as attended")
    func attendanceIsNeverInTheFuture() throws {
        let context = container.mainContext
        // The 7th: a day the seed does not already hold, so what is being
        // tested below is the future guard on its own rather than the
        // day-already-recorded one.
        let today = Day(2026, 8, 7)
        let recorded = try BookingStore.recordAttendance(
            day: today.adding(days: 1), officeID: SeedData.brusselsID,
            source: .manual, today: today, in: context
        )
        #expect(recorded == nil)
        #expect(try context.fetchCount(FetchDescriptor<AttendanceDay>()) == 4, "nothing written")

        // Today itself is not the future.
        #expect(
            try BookingStore.recordAttendance(
                day: today, officeID: SeedData.brusselsID,
                source: .manual, today: today, in: context
            ) != nil
        )
    }

    /// The list has to account for every day the gauge counts, without counting
    /// a day twice because it was both booked and turned up for.
    @Test("The month's list is the bookings plus the days no booking explains")
    func listCoversEveryCountedDay() throws {
        let context = container.mainContext
        let entries = HomeScreen.entries(
            bookings: try context.fetch(FetchDescriptor<DeskBooking>()),
            attendance: try context.fetch(FetchDescriptor<AttendanceDay>()),
            planned: try context.fetch(FetchDescriptor<PlannedDay>()),
            in: SeedData.month
        )
        // Four bookings, and four attended days of which two are already
        // covered by a booking on the same day at the same office.
        #expect(entries.count == 6)
        #expect(entries.map(\.day) == [
            Day(2026, 8, 3), Day(2026, 8, 4), Day(2026, 8, 5),
            Day(2026, 8, 6), Day(2026, 8, 11), Day(2026, 8, 12),
        ])

        let unbooked = entries.filter { if case .attended = $0 { true } else { false } }
        #expect(unbooked.map(\.day) == [Day(2026, 8, 3), Day(2026, 8, 4)])
    }

    /// The day the app is most likely to lose: booked, gone by, and never
    /// confirmed. Every route into attendance needs the user to act, and one of
    /// them is a geofence that can silently fail to fire — so a row that nobody
    /// has said anything about has to say so itself.
    @Test("A booked day gone by with nothing said about it is an open question")
    func pastUnconfirmedRowsAsk() throws {
        let context = container.mainContext
        let attendance = try context.fetch(FetchDescriptor<AttendanceDay>())
        let bookings = try context.fetch(FetchDescriptor<DeskBooking>())
        let today = Day(2026, 8, 13)

        func entry(_ day: Day) throws -> HomeScreen.Entry {
            .booking(try #require(bookings.first { $0.day == day }))
        }
        func asks(_ entry: HomeScreen.Entry, today: Day = Day(2026, 8, 13)) -> Bool {
            HomeScreen.isUnanswered(entry, attendance: attendance, today: today)
        }

        // 12 August: booked, in the past, and no attendance anywhere.
        #expect(asks(try entry(Day(2026, 8, 12))))
        // 5 August: booked and attended. Answered.
        #expect(!asks(try entry(Day(2026, 8, 5))))
        // The same 12 August, seen from the 12th. Still being worked, and both
        // the arrival alert and the evening nudge have today covered.
        #expect(!asks(try entry(Day(2026, 8, 12)), today: Day(2026, 8, 12)))

        // Told no. The answer is stored, so the row stops asking — and it is
        // not attendance, because a day not worked has nothing to record.
        let unused = try #require(bookings.first { $0.day == Day(2026, 8, 12) })
        try BookingStore.markNotAttended(unused, in: context)
        #expect(!asks(.booking(unused)))
        #expect(try context.fetchCount(FetchDescriptor<AttendanceDay>()) == 4)

        // And answering yes after all clears it, or the row would read as both
        // attended and not.
        try BookingStore.recordAttendance(
            day: unused.day, officeID: unused.officeID, source: .manual,
            bookingID: unused.id, today: today, in: context
        )
        #expect(!unused.notAttended)
    }

    /// `AttendanceDay.fraction` held 1.0 or 0.5 from the start and `Quota`
    /// summed it faithfully, but nothing could enter a half — you could book
    /// half a day off and not record half a day on. A field only a fixture can
    /// reach is a trap for whoever reads the model next.
    @Test("Half a day on prem counts as half a day")
    func halfDaysCanBeRecorded() throws {
        let context = container.mainContext
        let day = Day(2026, 8, 7)
        let record = try #require(
            try BookingStore.recordAttendance(
                day: day, officeID: SeedData.brusselsID, source: .manual,
                fraction: 0.5, today: day, in: context
            )
        )
        #expect(record.fraction == 0.5)

        let snapshot = try QuotaService.snapshot(for: SeedData.month, today: day, in: context)
        #expect(snapshot.result.attended == 4.5, "four seeded days and a half")
        #expect(snapshot.attendedByOffice[SeedData.brusselsID] == 1.5)
    }

    /// The day-level guard, from the direction that actually reaches it. The
    /// dedupe used to key on the day AND the office, so arriving at a second
    /// building on a day already recorded — tapping "I'm here" on the second
    /// alert, which the notification itself says will not move the count —
    /// wrote a second whole-day row and bought a day nobody worked.
    @Test("A second office on a day already recorded does not buy another day")
    func aDayIsRecordedOnceHoweverManyOfficesItTook() throws {
        let context = container.mainContext
        // The 3rd is seeded as a whole day at Coleman.
        let second = try BookingStore.recordAttendance(
            day: Day(2026, 8, 3), officeID: SeedData.brusselsID,
            source: .geofence, today: Day(2026, 8, 6), in: context
        )
        #expect(second == nil, "the day is already worth a day")
        #expect(try context.fetchCount(FetchDescriptor<AttendanceDay>()) == 4, "nothing written")

        let snapshot = try QuotaService.snapshot(
            for: SeedData.month, today: Day(2026, 8, 6), in: context
        )
        #expect(snapshot.result.attended == 4, "four days worked, four counted")
        #expect(
            snapshot.result.attended == Double(snapshot.attendedDays.count),
            "the sum and the set cannot disagree about a day"
        )
        #expect(
            snapshot.attendedByOffice.values.reduce(0, +) == snapshot.result.attended,
            "and the split bar adds up to the gauge above it"
        )
    }

    /// The limit of that guard, and why it counts fractions rather than rows:
    /// a morning at one building and an afternoon at another is a whole day
    /// worked in two halves, and refusing the second half would lose half a day
    /// that happened.
    @Test("Half a day leaves room for the other half, at another office or none")
    func halvesFillTheDayAndNoMore() throws {
        let context = container.mainContext
        let day = Day(2026, 8, 7)
        func record(_ officeID: UUID, _ fraction: Double) throws -> AttendanceDay? {
            try BookingStore.recordAttendance(
                day: day, officeID: officeID, source: .manual,
                fraction: fraction, today: day, in: context
            )
        }

        #expect(try record(SeedData.colemanID, 0.5) != nil, "the morning")
        #expect(try record(SeedData.brusselsID, 0.5) != nil, "and the afternoon")

        // The same building twice is still the same answer twice, whatever the
        // fraction says — that guard is what stops "I'm here" tapped again
        // after lunch writing a second row.
        #expect(try record(SeedData.colemanID, 0.5) == nil, "already answered for Coleman")

        // And a third building has nothing left to be given: the day is full.
        #expect(try record(UUID(), 0.5) == nil, "a day is worth at most a day")
        // As has a whole day laid over a day already half spent.
        #expect(try record(UUID(), 1.0) == nil)

        #expect(try context.fetchCount(FetchDescriptor<AttendanceDay>()) == 6, "four seeded, two halves")
        let snapshot = try QuotaService.snapshot(for: SeedData.month, today: day, in: context)
        #expect(snapshot.result.attended == 5, "four seeded days and the two halves as one")
        #expect(snapshot.attendedByOffice[SeedData.colemanID] == 3.5)
        #expect(snapshot.attendedByOffice[SeedData.brusselsID] == 1.5)
    }

    /// The store refuses to write an over-full day now, but a store written by
    /// a version that did not has to stop being believed rather than stay
    /// wrong: the gauge caps the date at a day, and the split bar underneath
    /// has to add up to the gauge or the screen contradicts itself.
    @Test("A day recorded twice by an older build still counts once")
    func rowsFromBeforeTheGuardAreCappedOnRead() throws {
        let context = container.mainContext
        // Inserted straight into the context, past `recordAttendance` — which
        // is exactly the provenance of the rows this cap exists for.
        context.insert(AttendanceDay(
            day: Day(2026, 8, 3), officeID: SeedData.brusselsID, source: .geofence
        ))
        try context.save()

        let snapshot = try QuotaService.snapshot(
            for: SeedData.month, today: Day(2026, 8, 6), in: context
        )
        #expect(try context.fetchCount(FetchDescriptor<AttendanceDay>()) == 5, "five rows")
        #expect(snapshot.result.attended == 4, "over four days")
        #expect(snapshot.attendedByOffice[SeedData.colemanID] == 2.5)
        #expect(snapshot.attendedByOffice[SeedData.brusselsID] == 1.5)
        #expect(
            snapshot.attendedByOffice.values.reduce(0, +) == snapshot.result.attended,
            "the bar and the gauge tell the same story about a day nobody can split"
        )
    }

    /// One assertion existed for this, on the arm where both ends were read.
    /// The `(nil, end?)` arm is not exotic — `CapturedBooking.parsed()` fills
    /// `endTime` from a default while leaving `startTime` nil whenever the model
    /// could not read it, so it is on the ordinary capture path — and swapping
    /// the two nil arms passed the whole suite while the detail screen printed
    /// a booking's default end time as though it were its start.
    @Test(
        "The hours line says only what was read",
        arguments: [
            ("09:00", "17:00", "09:00 – 17:00"),
            ("09:00", nil, "09:00"),
            (nil, "17:00", "until 17:00"),
            (nil, nil, nil),
        ] as [(String?, String?, String?)]
    )
    func hoursText(start: String?, end: String?, expected: String?) {
        let booking = DeskBooking(
            officeID: SeedData.colemanID, day: Day(2026, 8, 5), deskID: "3C-114",
            startTime: start, endTime: end, source: .capture
        )
        #expect(booking.hoursText == expected)
    }

    /// Editing replaces the row rather than mutating it — the merge would
    /// otherwise find the booking being edited and merge it with itself — so
    /// anything the candidate does not carry has to be carried by hand. "Were
    /// you there?" was answered about the day, and correcting a typo in the
    /// desk id is no reason to ask again.
    @Test("Correcting a booking does not un-answer it")
    func editingKeepsTheAnswer() throws {
        let context = container.mainContext
        let booking = try #require(
            try context.fetch(FetchDescriptor<DeskBooking>())
                .first { $0.day == Day(2026, 8, 12) }
        )
        try BookingStore.markNotAttended(booking, in: context)

        let saved = try BookingStore.replace(
            booking,
            with: .init(
                officeID: SeedData.colemanID, day: Day(2026, 8, 12), deskID: "3C-122",
                floor: "Level 3", zone: "C", source: .manual
            ),
            in: context
        )

        #expect(saved.deskID == "3C-122")
        #expect(saved.notAttended, "still answered")
        #expect(
            !HomeScreen.isUnanswered(
                .booking(saved),
                attendance: try context.fetch(FetchDescriptor<AttendanceDay>()),
                today: Day(2026, 8, 13)
            )
        )
    }

    /// The limit of that. The answer was about the day, so a booking edited
    /// onto a different day arrives at one nobody has been asked about — and
    /// carrying the answer there would be answering for the user, which is the
    /// one thing the question exists not to do.
    @Test("An answer does not follow a booking onto a day it was not given for")
    func theAnswerDoesNotMoveDays() throws {
        let context = container.mainContext
        let booking = try #require(
            try context.fetch(FetchDescriptor<DeskBooking>())
                .first { $0.day == Day(2026, 8, 12) }
        )
        try BookingStore.markNotAttended(booking, in: context)

        // The 12th was a typo for the 19th, which has nothing booked.
        let saved = try BookingStore.replace(
            booking,
            with: .init(
                officeID: SeedData.colemanID, day: Day(2026, 8, 19), deskID: "3C-121",
                source: .manual
            ),
            in: context
        )

        #expect(saved.day == Day(2026, 8, 19))
        #expect(!saved.notAttended, "the 19th has not been asked about")
    }

    /// The never-guess rule is the app's best idea, and an amber dot saying
    /// only that something could not be read was the worst way to report it.
    @Test("What could not be read is named, not merely marked")
    func unreadFieldsAreNamed() {
        #expect(BookingEditorScreen.unreadFieldNames(["zone"]) == "zone")
        #expect(BookingEditorScreen.unreadFieldNames(["floor", "zone"]) == "floor and zone")
        #expect(
            BookingEditorScreen.unreadFieldNames(["floor", "zone", "startTime"])
                == "floor, zone and from"
        )
        // The schema's own names are what arrive; anything else is ignored
        // rather than shown raw.
        #expect(BookingEditorScreen.unreadFieldNames(["nonsense"]) == "this booking")
        #expect(BookingEditorScreen.Field(unsureField: "deskId") == .desk)
    }

    /// The mirror of the attendance guard: attendance refuses the future,
    /// planning refuses the past. Between them every day has exactly one record
    /// that fits it, and neither can be used to say the other's thing.
    @Test("A day already gone cannot be planned")
    func planningIsNeverInThePast() throws {
        let context = container.mainContext
        let today = Day(2026, 8, 6)
        #expect(
            try BookingStore.recordPlanned(
                day: today, officeID: SeedData.brusselsID, today: today, in: context
            ) == nil,
            "today is not still to come"
        )
        #expect(
            try BookingStore.recordPlanned(
                day: today.adding(days: 1), officeID: SeedData.brusselsID,
                today: today, in: context
            ) != nil
        )
    }

    /// One day at one office is one row, however many records describe it.
    @Test("A planned day that has been worked shows as attended, not twice")
    func plannedThenAttendedIsOneRow() throws {
        let context = container.mainContext
        let day = Day(2026, 8, 20)
        try BookingStore.recordPlanned(
            day: day, officeID: SeedData.brusselsID, today: Day(2026, 8, 6), in: context
        )

        func rows() throws -> [HomeScreen.Entry] {
            HomeScreen.entries(
                bookings: try context.fetch(FetchDescriptor<DeskBooking>()),
                attendance: try context.fetch(FetchDescriptor<AttendanceDay>()),
                planned: try context.fetch(FetchDescriptor<PlannedDay>()),
                in: SeedData.month
            )
        }
        #expect(try rows().filter { $0.day == day }.count == 1)

        // The day arrives and is turned up for.
        try BookingStore.recordAttendance(
            day: day, officeID: SeedData.brusselsID, source: .manual,
            today: day, in: context
        )
        let onTheDay = try rows().filter { $0.day == day }
        #expect(onTheDay.count == 1, "the plan and the day worked are one day")
        if case .attended = onTheDay.first {} else {
            Issue.record("expected the attended row to win, got \(String(describing: onTheDay.first))")
        }
    }

    /// Re-importing a day cannot double the month — one desk per office per
    /// day — but it can move the desk id, which is what the sheet now asks
    /// about before it happens.
    @Test("A re-import replaces the day's desk rather than adding one")
    func reimportReplaces() throws {
        let context = container.mainContext
        let before = try context.fetchCount(FetchDescriptor<DeskBooking>())

        try BookingStore.upsert(
            .init(
                officeID: SeedData.colemanID, day: Day(2026, 8, 5),
                deskID: "CO03C117", source: .capture
            ),
            chosen: true,
            in: context
        )

        #expect(try context.fetchCount(FetchDescriptor<DeskBooking>()) == before)
        let booking = try #require(
            try context.fetch(FetchDescriptor<DeskBooking>())
                .first { $0.officeID == SeedData.colemanID && $0.day == Day(2026, 8, 5) }
        )
        #expect(booking.deskID == "CO03C117")
        // The gaps the new read did not carry are kept rather than blanked.
        #expect(booking.floor == "Level 3", "a replacement is not an erasure")
    }

    /// An edit deletes the row and re-creates it, so every field the candidate
    /// does not describe has to be carried across. The calendar event id is
    /// one, and it is the only handle the app has on an event write-only
    /// access cannot read back: lose it and the next tap writes a twin nothing
    /// can find again.
    @Test("Correcting a booking keeps the calendar event it was written to")
    func editingKeepsTheCalendarEvent() throws {
        let context = container.mainContext
        let capture = UUID()
        let booking = try #require(
            try context.fetch(FetchDescriptor<DeskBooking>())
                .first { $0.day == Day(2026, 8, 12) }
        )
        booking.calendarEventID = "EVENT-1"
        booking.captureID = capture
        try context.save()

        let saved = try BookingStore.replace(
            booking,
            with: .init(
                officeID: SeedData.colemanID, day: Day(2026, 8, 12), deskID: "3C-122",
                floor: "Level 3", zone: "C", source: .manual
            ),
            in: context
        )

        #expect(saved.deskID == "3C-122", "the correction landed")
        #expect(try context.fetchCount(FetchDescriptor<DeskBooking>()) == 4, "corrected, not twinned")
        #expect(saved.calendarEventID == "EVENT-1", "and the event is still findable")
        #expect(saved.captureID == capture, "as is the screenshot it was read from")
    }

    /// The one case where the carry must not happen. Moving a booking onto a
    /// day that already has one makes the merge land on that day's row rather
    /// than a fresh one — and writing this booking's event id over it would
    /// orphan the event that row already points at, which is the very thing
    /// carrying the id across exists to prevent.
    @Test("Moving a booking onto an occupied day leaves that day's event alone")
    func replaceNeverOrphansTheDestinationsEvent() throws {
        let context = container.mainContext
        let bookings = try context.fetch(FetchDescriptor<DeskBooking>())
        let moving = try #require(bookings.first { $0.day == Day(2026, 8, 12) })
        let destination = try #require(bookings.first { $0.day == Day(2026, 8, 5) })
        moving.calendarEventID = "EVENT-MOVED"
        destination.calendarEventID = "EVENT-ALREADY-THERE"
        try context.save()

        // Same office, so the booking already on the 5th is what merges.
        let saved = try BookingStore.replace(
            moving,
            with: .init(
                officeID: SeedData.colemanID, day: Day(2026, 8, 5), deskID: "3C-122",
                source: .manual
            ),
            in: context
        )

        #expect(try context.fetchCount(FetchDescriptor<DeskBooking>()) == 3, "the two days are one")
        #expect(saved.deskID == "3C-122")
        #expect(
            saved.calendarEventID == "EVENT-ALREADY-THERE",
            "one event orphaned rather than two"
        )
    }

    /// Nothing cascades: entities point at each other by UUID, so a row that
    /// is re-created under a new id leaves every reference to the old one
    /// pointing at nothing. The day was attended at the desk that was
    /// corrected, and it is still that desk.
    @Test("Correcting a booking leaves the day attended at it still pointing at it")
    func editingRelinksTheDayAttended() throws {
        let context = container.mainContext
        let booking = try #require(
            try context.fetch(FetchDescriptor<DeskBooking>()).first { $0.deskID == "3C-114" }
        )
        let attended = try #require(
            try context.fetch(FetchDescriptor<AttendanceDay>())
                .first { $0.bookingID == booking.id }
        )

        let saved = try BookingStore.replace(
            booking,
            with: .init(
                officeID: SeedData.colemanID, day: Day(2026, 8, 5), deskID: "3C-115",
                source: .manual
            ),
            in: context
        )

        #expect(saved.deskID == "3C-115")
        #expect(attended.bookingID == saved.id, "the day follows the desk it was")
        #expect(try context.fetchCount(FetchDescriptor<AttendanceDay>()) == 4, "and stands")
    }

    /// The limit of the link. An attendance row's booking id says "this is the
    /// desk I had that day" — an edit that moves the booking to another day
    /// makes that false, so it is cleared rather than bent to point at a desk
    /// booked for a day you were somewhere else. Being there is not undone by
    /// it: the day stays, exactly as it does when a booking is deleted.
    @Test("An edit that moves a booking off a day unbooks that day, not the day itself")
    func editingAwayUnbooksTheDay() throws {
        let context = container.mainContext
        let booking = try #require(
            try context.fetch(FetchDescriptor<DeskBooking>()).first { $0.deskID == "3C-114" }
        )
        let attended = try #require(
            try context.fetch(FetchDescriptor<AttendanceDay>())
                .first { $0.bookingID == booking.id }
        )

        // The 5th was a typo for the 19th, which has nothing booked.
        try BookingStore.replace(
            booking,
            with: .init(
                officeID: SeedData.colemanID, day: Day(2026, 8, 19), deskID: "3C-114",
                source: .manual
            ),
            in: context
        )

        #expect(attended.bookingID == nil, "not left pointing at a row that is gone")
        #expect(attended.day == Day(2026, 8, 5), "the day you were there is untouched")
        #expect(try context.fetchCount(FetchDescriptor<AttendanceDay>()) == 4)

        let snapshot = try QuotaService.snapshot(
            for: SeedData.month, today: Day(2026, 8, 6), in: context
        )
        #expect(snapshot.result.attended == 4, "and it still counts toward the month")
    }

    /// The two come apart in both directions, which is why they are separate
    /// entities. Deleting the desk you reserved does not undo having been
    /// there, and attendance is the only record that you were.
    @Test("Deleting a booking keeps the day it was attended on")
    func deleteKeepsAttendance() throws {
        let context = container.mainContext
        let booking = try #require(
            try context.fetch(FetchDescriptor<DeskBooking>()).first { $0.deskID == "3C-114" }
        )
        let attended = try #require(
            try context.fetch(FetchDescriptor<AttendanceDay>())
                .first { $0.bookingID == booking.id }
        )

        try BookingStore.delete(booking, in: context)

        #expect(try context.fetchCount(FetchDescriptor<DeskBooking>()) == 3)
        #expect(try context.fetchCount(FetchDescriptor<AttendanceDay>()) == 4, "the day stands")
        // Cleared, not left pointing at a row that is gone. The day is now one
        // turned up for without booking, which is what it is.
        #expect(attended.bookingID == nil)

        let snapshot = try QuotaService.snapshot(
            for: SeedData.month, today: Day(2026, 8, 4), in: context
        )
        #expect(snapshot.result.attended == 4, "and it still counts toward the month")
    }

    /// A row of each of the three kinds `SeedData` does not lay down.
    ///
    /// Without them the wipe tests counted three tables that were empty before
    /// the wipe as well, which proves nothing — and the emptiest of the three
    /// is the one that matters most: `Capture.asset` is the user's original
    /// photograph of a confirmation email, names and desk numbers and all.
    private func insertTheUnseededModels() throws {
        let context = container.mainContext
        context.insert(PlannedDay(day: Day(2026, 8, 20), officeID: SeedData.brusselsID))
        context.insert(ArrivalAlert(
            day: Day(2026, 8, 5), officeID: SeedData.colemanID, deliveredAt: .now
        ))
        context.insert(Capture(
            receivedAt: .now, asset: Data([0xFF, 0xD8, 0xFF]), status: .parsed
        ))
        try context.save()
    }

    /// Every table in the schema, so a scope that forgets one cannot pass by
    /// being counted over a table that was empty to begin with.
    private func counts() throws -> [String: Int] {
        let context = container.mainContext
        return [
            "Office": try context.fetchCount(FetchDescriptor<Office>()),
            "DeskBooking": try context.fetchCount(FetchDescriptor<DeskBooking>()),
            "AttendanceDay": try context.fetchCount(FetchDescriptor<AttendanceDay>()),
            "PlannedDay": try context.fetchCount(FetchDescriptor<PlannedDay>()),
            "LeaveDay": try context.fetchCount(FetchDescriptor<LeaveDay>()),
            "ArrivalAlert": try context.fetchCount(FetchDescriptor<ArrivalAlert>()),
            "Capture": try context.fetchCount(FetchDescriptor<Capture>()),
        ]
    }

    @Test("Wiping everything leaves nothing behind, in all seven tables")
    func wipe() throws {
        try insertTheUnseededModels()
        // The fixture has to have something in every table, or the assertion
        // below is seven ways of saying nothing.
        let before = try counts()
        #expect(before.count == OfficeDazeSchema.all.count, "a table has been added since")
        // Hoisted out of #expect: `allSatisfy` is `rethrows` and the macro
        // cannot tell a non-throwing closure from a throwing one inside it.
        let somethingToLose = before.values.allSatisfy { $0 > 0 }
        #expect(somethingToLose, "a count over an empty table proves nothing")

        try Store.wipe(container.mainContext, defaults: throwawayDefaults(), forgetSecret: {})
        let survivors = try counts().filter { $0.value > 0 }
        #expect(survivors.isEmpty, "nothing behind")
    }

    /// The offices are the only thing in the store that was typed in by hand,
    /// so clearing out the sample month must not take them with it.
    @Test("Wiping the records keeps the offices and nothing else")
    func wipeRecordsOnly() throws {
        try insertTheUnseededModels()
        let somethingToLose = try counts().values.allSatisfy { $0 > 0 }
        #expect(somethingToLose, "a count over an empty table proves nothing")

        try Store.wipe(
            container.mainContext, scope: .records,
            defaults: throwawayDefaults(), forgetSecret: {}
        )

        let after = try counts()
        #expect(after["Office"] == 2)
        // Named, so a failure says which table survived rather than that some
        // number was not zero. The retained screenshots are the point: they are
        // the user's photographs, and "Clear records" says it clears them.
        let survivors = after.filter { $0.key != "Office" && $0.value > 0 }
        #expect(survivors.isEmpty, "the records scope keeps the buildings and nothing else")

        let offices = try container.mainContext.fetch(FetchDescriptor<Office>())
        #expect(offices.map(\.name).sorted() == ["Brussels", "Coleman"])
        // Not just present — intact. A perimeter that survived the wipe
        // without its coordinates would monitor nothing.
        //
        // Hoisted out of #expect for the same reason as `offices()` above:
        // `allSatisfy` is `rethrows` and the macro cannot tell the difference.
        let located = offices.allSatisfy(\.isLocated)
        #expect(located)
    }

    /// The Anthropic key is the one thing the app holds that is not a row in the
    /// schema, and it was the one thing a button reading "Everything, including
    /// 2 offices" left behind — a live, billable credential, on a phone the
    /// dialog had just promised was cleared.
    @Test("Everything means the API key too; the records scope leaves it alone")
    func wipeForgetsTheKeyOnlyForEverything() throws {
        let context = container.mainContext

        // Records what it is asked, rather than swallowing the call: which
        // scope reaches for the secret is the entire question here.
        final class Asked { var scopes: [Store.Scope] = [] }
        let asked = Asked()

        try Store.wipe(
            context, scope: .records, defaults: throwawayDefaults(),
            forgetSecret: { asked.scopes.append(.records) }
        )
        #expect(asked.scopes.isEmpty, "the key is as typed-in as the offices are")

        try Store.wipe(
            context, scope: .everything, defaults: throwawayDefaults(),
            forgetSecret: { asked.scopes.append(.everything) }
        )
        #expect(asked.scopes == [.everything])
    }

    /// A UserDefaults nobody else is reading. `store.seeded` decides whether the
    /// app lays the sample month down on the next launch, and a test that wrote
    /// the real one would be answering that question for the simulator it
    /// happened to run on.
    private func throwawayDefaults(
        _ name: String = "OfficeDazeTests.\(UUID().uuidString)"
    ) -> UserDefaults {
        UserDefaults(suiteName: name)!
    }
}

/// The gates around the sample month, and the one question both month steppers
/// ask. Neither had a test: the seeding flag because it is process-wide state
/// with no seam, which is now injected, and `recordedDays` for no reason at all
/// — every suite in the target already builds the context it takes.
@Suite("The store's gates")
@MainActor
struct StoreGateTests {

    let container: ModelContainer

    init() throws {
        container = try Store.makeInMemoryContainer()
    }

    /// Each case gets its own defaults, so cases running in parallel cannot
    /// read each other's flag — and the real one is never touched.
    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "OfficeDazeTests.\(UUID().uuidString)")!
    }

    @Test("A fresh install gets the sample month, and is marked as having had it")
    func seedsOnce() throws {
        let context = container.mainContext
        let defaults = freshDefaults()
        #expect(!Store.hasSeeded(in: defaults))

        try Store.seedIfNeeded(context, defaults: defaults)
        #expect(try context.fetchCount(FetchDescriptor<Office>()) == 2)
        #expect(Store.hasSeeded(in: defaults))
    }

    /// The whole point of the flag. "Is the store empty" and "has it ever been
    /// seeded" stop being the same question the moment the store can be wiped:
    /// an emptied store is empty on purpose, and answering the first question
    /// would put the sample bookings straight back on the next launch.
    @Test("A store emptied on purpose is not seeded again")
    func anEmptiedStoreStaysEmpty() throws {
        let context = container.mainContext
        let defaults = freshDefaults()
        try Store.seedIfNeeded(context, defaults: defaults)
        try Store.wipe(context, defaults: defaults, forgetSecret: {})
        #expect(try context.fetchCount(FetchDescriptor<Office>()) == 0)
        #expect(Store.hasSeeded(in: defaults), "wiping is having had it")

        try Store.seedIfNeeded(context, defaults: defaults)
        #expect(try context.fetchCount(FetchDescriptor<Office>()) == 0, "nothing came back")
    }

    /// The second guard, which exists for the install that predates the flag:
    /// a store with offices in it has plainly been used, so the flag is set
    /// without laying anything down over the top of them.
    @Test("A store that already has offices is marked seeded, not seeded over")
    func aUsedStoreIsNotSeededOver() throws {
        let context = container.mainContext
        let defaults = freshDefaults()
        context.insert(Office(
            name: "Somewhere", address: "1 A Street", postcode: "N1 1AA",
            colourHex: OfficeColours.palette[0]
        ))
        try context.save()

        try Store.seedIfNeeded(context, defaults: defaults)
        #expect(try context.fetchCount(FetchDescriptor<Office>()) == 1, "not two more")
        #expect(try context.fetchCount(FetchDescriptor<DeskBooking>()) == 0)
        #expect(Store.hasSeeded(in: defaults))
    }

    /// The sole input to both month steppers. `MonthRangeTests` is thorough
    /// about the range and feeds it hand-built arrays, so the four fetches and
    /// the bank-holiday filter that actually build that array were never run —
    /// dropping any one term left every test green and the back chevron dead at
    /// the month where that kind of record was the only one.
    @Test("Every kind of record is a month you can step back to, except a bank holiday")
    func recordedDaysCoversEveryKind() throws {
        let context = container.mainContext
        context.insert(DeskBooking(
            officeID: SeedData.colemanID, day: Day(2026, 3, 4), deskID: "3C-114",
            source: .manual
        ))
        context.insert(AttendanceDay(
            day: Day(2026, 4, 6), officeID: SeedData.colemanID, source: .manual
        ))
        context.insert(PlannedDay(day: Day(2026, 5, 7), officeID: SeedData.brusselsID))
        context.insert(LeaveDay(day: Day(2026, 6, 8), kind: .annual))
        // Derived from the calendar rather than entered, so a month holding
        // nothing else is still an empty month — the same grounds every other
        // reader leaves them out on.
        context.insert(LeaveDay(day: Day(2026, 7, 9), kind: .bankHoliday))
        try context.save()

        let recorded = try Store.recordedDays(in: context).sorted()
        #expect(recorded == [Day(2026, 3, 4), Day(2026, 4, 6), Day(2026, 5, 7), Day(2026, 6, 8)])
    }
}
