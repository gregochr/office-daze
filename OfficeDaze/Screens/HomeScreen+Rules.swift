import Foundation

/// What HomeScreen decides, separated from the screen that shows it.
///
/// Everything in here is `static` and is handed what it needs, which is the
/// reason the file exists: these are the questions the screen has to get right
/// — which records are one row, what a Delete means, what a refusal should say
/// — and they are answered without a screen, a store or a fetch, so
/// HomeScreenTests can ask them directly. That seam was already in the screen;
/// the file boundary is drawn along it rather than at a line count, and it is
/// self-enforcing: nothing here can quietly start reading the screen's state,
/// because there is no state in this file to read.
///
/// The three nested types come with it. `Entry`, `Deletion` and `Answer` are
/// the vocabulary these rules are written in — a row, what deleting one means,
/// and what answering one did — and none of them mentions a view.
extension HomeScreen {

    /// A row in the month's list.
    ///
    /// Most are desk bookings. The other kind is a day on prem with no desk
    /// behind it — a workshop, a meeting, a visit — which has to appear here or
    /// the gauge counts a day the list below it cannot account for.
    enum Entry: Identifiable {
        case booking(DeskBooking)
        case attended(AttendanceDay)
        case planned(PlannedDay)

        var id: UUID {
            switch self {
            case .booking(let booking): booking.id
            case .attended(let day): day.id
            case .planned(let day): day.id
            }
        }

        var day: Day {
            switch self {
            case .booking(let booking): booking.day
            case .attended(let record): record.day
            case .planned(let record): record.day
            }
        }

        /// Which building the row is about. Every kind of row has one, and it
        /// is half of the day-and-office pairing everything on this screen
        /// matches on — including the sentence that has to explain a refusal.
        var officeID: UUID? {
            switch self {
            case .booking(let booking): booking.officeID
            case .attended(let record): record.officeID
            case .planned(let record): record.officeID
            }
        }

        /// The booking behind this row, for the rows that have one.
        var booking: DeskBooking? {
            if case .booking(let booking) = self { return booking }
            return nil
        }
    }

    /// The month's list: every booking, plus every day on prem — worked or
    /// intended — that no booking already accounts for.
    ///
    /// Static so the rule worth getting right can be tested: one day at one
    /// office is one row however many records describe it. A booked day speaks
    /// for its own attendance, and a planned day that has since been worked is
    /// spoken for by the attendance. Everything is matched on day and office,
    /// the same pairing `isAttended` uses, so no two parts of this screen can
    /// disagree about which days are already covered.
    static func entries(
        bookings: [DeskBooking], attendance: [AttendanceDay],
        planned: [PlannedDay], in month: Month
    ) -> [Entry] {
        let booked = bookings.filter { month.contains($0.day) }
        func isBooked(_ day: Day, _ officeID: UUID?) -> Bool {
            booked.contains { $0.day == day && $0.officeID == officeID }
        }

        let attended = attendance.filter {
            month.contains($0.day) && !isBooked($0.day, $0.officeID)
        }
        let intended = planned.filter { record in
            month.contains(record.day)
                && !isBooked(record.day, record.officeID)
                // Turning up is what converts it. The attendance row is the
                // truer record of the same day, so the plan stops being shown.
                && !attended.contains {
                    $0.day == record.day && $0.officeID == record.officeID
                }
        }
        return (
            booked.map(Entry.booking)
                + attended.map(Entry.attended)
                + intended.map(Entry.planned)
        ).sorted { $0.day < $1.day }
    }

    /// The attendance record that speaks for a booking's day, if there is one.
    ///
    /// Matched on day *and* office, the pairing `entries` and `isAttended` both
    /// use, so no two parts of this screen can disagree about which record a
    /// row is standing for. A day worked at the other building is a different
    /// row's record, and removing it from this one would delete something this
    /// row never showed.
    static func attendanceRecord(
        for booking: DeskBooking, in attendance: [AttendanceDay]
    ) -> AttendanceDay? {
        attendance.first { $0.day == booking.day && $0.officeID == booking.officeID }
    }

    /// What a row's Delete means, once you know what is behind the row.
    ///
    /// A booked day that was also turned up for is two records under one row.
    /// That single row is deliberate — see `entries` — but it cost the
    /// attendance its only delete: `deleteAttendance` has one caller in the
    /// app, this screen's `.attended` row, and `entries` never emits one for a
    /// booked day. Nothing else reached it either. The detail screen's
    /// "Attended — confirmed" strip is a label, and `recordAttendance` refuses
    /// a second row for the same day and office, so a mis-tapped "I'm here" on
    /// a booked day — the likeliest mis-tap there is, since a booked day is
    /// exactly the day the arrival alert fires on — went on counting toward the
    /// eight with no way in the app to take it back.
    ///
    /// So Delete on such a row asks which record it means rather than silently
    /// taking the desk. Every other row holds one record and still deletes
    /// without a question: an extra tap on every delete would be a worse trade
    /// than the one this buys.
    enum Deletion {
        /// One record behind the row. Delete means it, and acts.
        case record
        /// A booking, and the attendance for the same day at the same office.
        case bookingOrAttendance(AttendanceDay)
    }

    static func deletion(for entry: Entry, attendance: [AttendanceDay]) -> Deletion {
        guard let booking = entry.booking,
              let record = attendanceRecord(for: booking, in: attendance)
        else { return .record }
        return .bookingOrAttendance(record)
    }

    // MARK: The gauge's sentences

    /// `4 August · 18 working days left`, and the second half of the sentence
    /// the dial is telling. Another month is not a deadline you are inside, so
    /// it says how big it was rather than how much of it is left.
    static func dateLine(_ result: Quota.Result, month: Month, today: Day) -> String {
        guard month == today.month_ else {
            return "\(result.workingDays) working days"
        }
        let left = result.daysToRun == 1 ? "1 working day left" : "\(result.daysToRun) working days left"
        return "\(today.dayAndMonth) · \(left)"
    }

    static func daysLeftText(_ result: Quota.Result) -> String {
        result.daysAvailable == 1 ? "1 day left" : "\(result.daysAvailable) days left"
    }

    /// `Target 6 — 8 days less 2 for 5 days' leave`. The one line that says
    /// where the number came from, because a target that moves without
    /// explanation reads as a bug.
    ///
    /// Leave too small to have moved anything gets a sentence of its own. The
    /// old pro-rate shifted the number a little for every day booked, so the
    /// leave was always visible in the result; blocks of five mean four days
    /// off change nothing at all, and a line that then says only "8 days a
    /// month" reads as though the four days were never recorded.
    static func targetExplanation(_ result: Quota.Result) -> String {
        let target = "Target \(result.target)"
        guard result.leaveTaken > 0 else { return "\(target) — 8 days a month" }
        let days = "\(number(result.leaveTaken)) \(result.leaveTaken == 1 ? "day's" : "days'") leave"
        guard result.relief > 0 else { return "\(target) — \(days); 5 days takes 2 off" }
        return "\(target) — 8 days less \(number(result.relief)) for \(days)"
    }

    /// The amber strip's two halves.
    ///
    /// "4 days to go" gave the size of the gap and said nothing about what was
    /// already arranged, so a month with four days lined up and four still to
    /// find read exactly like one with nothing at all. The leading half now
    /// names the action that closes the gap, and the trailing half says what is
    /// already counted toward it — and how much month is left to do it in,
    /// which is the half that matters when the two numbers stop fitting.
    ///
    /// "Booked" covers planned days too. They are distinguished on their own
    /// rows, where the difference is actionable; in a one-line summary of what
    /// is lined up, it is not.
    static func shortfallText(_ result: Quota.Result) -> (leading: String, trailing: String) {
        let short = number(result.shortfall)
        let leading = "\(short) more \(result.shortfall == 1 ? "day" : "days") to book"
        let lined = result.forecast == 0
            ? "none booked"
            : "\(number(result.forecast)) booked"
        return (leading, "\(lined) · \(result.daysToRun) days left")
    }

    static func number(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...1)))
    }

    // MARK: Offices

    /// Offices with days against them this month, biggest first. An office with
    /// nothing recorded has no share of the figure and no segment in the bar.
    ///
    /// Handed the already-computed split rather than reaching back for
    /// `snapshot`: the map runs once per office, and a property read inside it
    /// re-ran the whole four-fetch snapshot each time round — the one place in
    /// the screen where the cost of a re-render grew with the user's data.
    /// Taking it as a parameter is what makes that impossible to reintroduce,
    /// and it makes the ordering rule testable without a store.
    static func officeShares(
        offices: [Office], attendedByOffice: [UUID: Double]
    ) -> [(office: Office, days: Double)] {
        offices
            .map { ($0, attendedByOffice[$0.id] ?? 0) }
            .filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
    }

    static func dayCount(_ days: Double) -> String {
        "\(number(days)) \(days == 1 ? "day" : "days")"
    }

    // MARK: Bookings

    /// The heading over the list has to name the month the list is showing.
    ///
    /// It was the literal "This month" over rows the stepper moves freely in
    /// both directions, so two chevrons forward the heading claimed October's
    /// bookings were this month's — while the empty state four lines below it
    /// got the same question right. `SectionHeader` uppercases, so a stepped
    /// month reads OCTOBER 2026, in the style of the headings around it.
    static func bookingsTitle(month: Month, today: Day) -> String {
        month == today.month_ ? "This month" : month.text
    }

    // MARK: The question the app has to ask

    /// A day gone by that nothing has been said about.
    ///
    /// Attendance is the only record that a day was worked on prem — there is
    /// no other copy — and every route into it needs the user to act. One of
    /// those routes is a geofence, and a geofence that does not fire (phone
    /// off, Always quietly dropped, a different entrance, fifty metres too
    /// tight) leaves a day worked, booked, and counting for nothing, with
    /// nothing anywhere saying so. This is the question that catches it, put
    /// where the user is already looking.
    ///
    /// Yesterday and earlier, not today: today is still being worked, and the
    /// arrival alert and the evening nudge both have it covered.
    ///
    /// Static so the rule can be tested without a screen. The three cases are
    /// not symmetric: a day already attended is answered, a booking carries its
    /// own answer once given, and a planned day has nowhere to keep one — which
    /// is why answering it no deletes it.
    static func isUnanswered(
        _ entry: Entry, attendance: [AttendanceDay], today: Day
    ) -> Bool {
        guard entry.day < today else { return false }
        func recorded(_ day: Day, _ officeID: UUID?) -> Bool {
            attendance.contains { $0.day == day && $0.officeID == officeID }
        }
        switch entry {
        case .attended:
            return false
        case .booking(let booking):
            return !booking.notAttended && !recorded(booking.day, booking.officeID)
        case .planned(let record):
            return !recorded(record.day, record.officeID)
        }
    }

    /// What answering a row's question did.
    ///
    /// `refused` is the case that used to be invisible, and it is why this is an
    /// enum rather than a `try?`. `recordAttendance` answers a write it will not
    /// make by *returning nil*, not by throwing, so `try?` on it flattened three
    /// different outcomes — written, declined, and thrown — into the same silent
    /// nothing, and the screen went on to `answered()` as though the day had
    /// been counted.
    ///
    /// The reachable decline is a day whose recorded fractions already total a
    /// whole day at another office. The question is still asked on such a row,
    /// because `isUnanswered` matches on this row's own office, so Yes was live,
    /// wrote nothing, said nothing, and left the row asking.
    enum Answer: Equatable {
        case written
        case refused
        case failed(String)
        /// Nothing to answer. `.attended` rows never ask the question, so this
        /// is unreachable from the buttons; it exists so the switch below has
        /// somewhere honest to put that case rather than reporting a success.
        case nothing
    }

    /// Yes: the day was worked. The store call arrives as a closure for the
    /// reason `AttendanceEditorScreen.record` takes its two — the outcome worth
    /// getting right is a refusal, and a refusal is a branch SwiftData will not
    /// take on request.
    ///
    /// The closure is handed the booking's id for a booked day and nil for a
    /// planned one, which is the difference between an attendance row that knows
    /// which desk it belongs to and one that floats free.
    static func answerYes(
        _ entry: Entry, record: (Day, UUID?, UUID?) throws -> Bool
    ) -> Answer {
        let bookingID: UUID?
        switch entry {
        case .booking(let booking): bookingID = booking.id
        case .planned: bookingID = nil
        case .attended: return .nothing
        }
        do {
            return try record(entry.day, entry.officeID, bookingID) ? .written : .refused
        } catch {
            return .failed(
                "\(entry.day.dayAndMonth) couldn't be recorded: \(error.localizedDescription). Nothing was saved."
            )
        }
    }

    /// No. A booking keeps its row and stops asking — the desk was reserved,
    /// which happened whether or not the day was. An intention that came to
    /// nothing leaves no trace worth keeping: it only ever counted toward the
    /// forecast, and the forecast is days ahead.
    ///
    /// Two closures rather than one, because those are two different writes to
    /// two different records and the branch between them is the rule above. A
    /// single closure would let a booking be deleted where it should have been
    /// marked and nothing here would notice.
    ///
    /// Neither call can decline, so there is no `refused` on this side — only a
    /// throw, which used to be swallowed and left the row asking a question the
    /// user had already answered.
    static func answerNo(
        _ entry: Entry,
        mark: (DeskBooking) throws -> Void,
        forget: (PlannedDay) throws -> Void
    ) -> Answer {
        do {
            switch entry {
            case .booking(let booking):
                try mark(booking)
            case .planned(let record):
                try forget(record)
            case .attended:
                return .nothing
            }
            return .written
        } catch {
            return .failed(
                "\(entry.day.dayAndMonth) couldn't be answered: \(error.localizedDescription). Nothing was saved."
            )
        }
    }

    /// Why the store refused a Yes, said in terms of what is actually on that
    /// day. The store answers with nil and no reason; every reason it has is
    /// visible from the rows this screen already holds.
    ///
    /// Only the middle sentence is reachable from a row's Yes button — the first
    /// describes a day this row would not be asking about, and the last is the
    /// reason we do not have. They are written out anyway because a fallback
    /// that says "could not be recorded" and nothing else is what the user gets
    /// if a future guard is added to the store and nobody updates this.
    static func refusal(
        day: Day, officeID: UUID?, attendance: [AttendanceDay]
    ) -> String {
        if attendance.contains(where: { $0.day == day && $0.officeID == officeID }) {
            return "\(day.dayAndMonth) is already recorded at this office. Nothing was added."
        }
        let elsewhere = attendance.filter { $0.day == day }.reduce(0) { $0 + $1.fraction }
        if elsewhere > 0 {
            return "\(day.dayAndMonth) already has \(amount(elsewhere)) recorded at another office, and a whole day here would take it over one. Remove that day first if it is wrong."
        }
        return "\(day.dayAndMonth) could not be recorded. Nothing was added."
    }

    /// `half a day` / `a whole day`, so the sentence above reads as English
    /// rather than as a decimal. Exact rather than approximate: the attendance
    /// editor's picker offers exactly those two fractions and every other writer
    /// in the app records 1.0, so there is no third value to round.
    static func amount(_ fraction: Double) -> String {
        fraction < 1 ? "half a day" : "a whole day"
    }

    /// Every delete on this screen can only fail by throwing — nothing declines
    /// a delete — so all it needs is somewhere for the throw to land. Silence
    /// left the row sitting there with no reason given, which reads as a tap
    /// that missed rather than as a save that failed.
    static func deletionFailure(_ entry: Entry, _ error: Error) -> String {
        let what = switch entry {
        case .booking: "The desk booking"
        case .attended: "The day in the office"
        case .planned: "The planned day"
        }
        return "\(what) for \(entry.day.dayAndMonth) couldn't be removed: \(error.localizedDescription)."
    }
}
