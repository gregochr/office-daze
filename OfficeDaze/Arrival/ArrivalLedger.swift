import Foundation
import SwiftData
import UserNotifications

/// The store side of the arrival: reads what the rule needs, applies it, and
/// writes the ledger row.
///
/// The rule itself is in `ArrivalRule` and knows nothing about SwiftData; this
/// only knows how to fetch and write.
@MainActor
final class ArrivalLedger {

    private let context: ModelContext

    /// Swapped in tests. Posting a real notification from a test run leaves one
    /// on the machine, and asking the notification centre for permission in CI
    /// is a hang.
    var post: (UNNotificationRequest) -> Void = { request in
        UNUserNotificationCenter.current().add(request)
    }

    /// Takes the previous alert off the lock screen before the next one goes
    /// on. Swapped in tests for the same reason as `post`.
    var withdraw: ([String]) -> Void = { identifiers in
        UNUserNotificationCenter.current()
            .removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    /// The ledger row's own save, behind a closure for the reason `post` is
    /// behind one: the branch worth getting right is the one SwiftData takes
    /// when it fails, and it will not fail on request. It is handed the context
    /// rather than closing over it so a test can see *which* context was
    /// written — a seam that quietly saved a different one would look identical
    /// from out here.
    var save: (ModelContext) throws -> Void = { try $0.save() }

    /// The two store writes the notification's buttons make, behind closures
    /// for the same reason. Bound in `init` rather than given a default,
    /// because both need the context and a stored property's default cannot
    /// reach it.
    var attend: (Day, UUID, UUID?, Day) throws -> Bool
    var decline: (DeskBooking) throws -> Void

    init(context: ModelContext) {
        self.context = context
        attend = { day, officeID, bookingID, today in
            // `!= nil` because the store answers a write it will not make by
            // returning nil rather than by throwing, and nil is not success.
            try BookingStore.recordAttendance(
                day: day, officeID: officeID, source: .geofence,
                bookingID: bookingID, today: today, in: context
            ) != nil
        }
        decline = { booking in
            try BookingStore.markNotAttended(booking, in: context)
        }
    }

    /// Called on a region entry. Returns the decision so the caller — and the
    /// tests — can see what happened.
    @discardableResult
    func handleEntry(
        officeID: UUID, day: Day = .today, now: Date = .now
    ) -> ArrivalRule.Decision {
        guard let office = office(officeID) else { return .disabled }

        let previous = lastAlert(officeID: officeID, day: day)
        let decision = ArrivalRule.decide(.init(
            officeID: officeID,
            day: day,
            attendance: attendance(),
            lastAlert: previous,
            now: now,
            bookings: bookings(),
            alertEnabled: office.alertEnabled
        ))

        switch decision {
        case .acknowledged, .settling, .disabled:
            // Nothing. No notification, and no ledger row.
            return decision

        case .desk(let booking):
            deliver(office: office, day: day, desk: booking, at: now, replacing: previous)
        case .nothingBooked:
            deliver(office: office, day: day, desk: nil, at: now, replacing: previous)
        }

        // Appended, not updated: the ledger is every delivery, and its latest
        // row is what the settle window and the withdrawal both read.
        let row = ArrivalAlert(day: day, officeID: officeID, deliveredAt: now)
        context.insert(row)
        do {
            try save(context)
        } catch {
            // The one failure here with no one to tell. The alert has already
            // gone out — the user has what they came for — and what did not
            // save is bookkeeping they can neither see nor act on. A second
            // notification saying "your arrival was noted but not written down"
            // would be the burst of noise the settle window exists to prevent,
            // paid for a fact of no use to anybody.
            //
            // So it is handled rather than announced. The pending row goes,
            // because a context still holding an insert that failed will commit
            // it on the next unrelated save — a row that reports itself lost and
            // then quietly appears is worse than either. And the delivery is
            // kept in memory instead, because the cost of losing it is real: the
            // very next crossing reads an empty ledger, finds no settle window,
            // and alerts again seconds later. A burst of identical alerts is how
            // a notification gets switched off for good, which is a permanent
            // price for a transient failure.
            context.delete(row)
            unsavedDeliveries[Delivery(officeID: officeID, day: day)] = now
        }
        return decision
    }

    private func deliver(
        office: Office, day: Day, desk: ArrivalRule.Booking?,
        at now: Date, replacing previous: Date?
    ) {
        // The one this replaces, by the time it was delivered — the identifier
        // is reconstructible from the ledger row, so nothing extra is stored to
        // find it again.
        if let previous {
            withdraw([ArrivalNotifications.identifier(
                officeID: office.id, day: day, at: previous
            )])
        }

        let snapshot = try? QuotaService.snapshot(
            for: day.month_, today: day, in: context
        )
        let content = ArrivalNotifications.content(
            officeName: office.name,
            desk: desk,
            attended: snapshot?.result.attended ?? 0,
            target: snapshot?.result.target ?? 0,
            monthName: monthName(day.month_),
            // Recorded at another office earlier today. The rule stops the
            // alert only for the office it was recorded at, so this one still
            // fires — but "tap to make it 5" would be a promise the button
            // cannot keep, because the day is already counted.
            alreadyRecorded: snapshot?.attendedDays.contains(day) ?? false
        )
        post(ArrivalNotifications.request(
            content, officeID: office.id, day: day, bookingID: desk?.id, at: now
        ))
    }

    // MARK: The buttons

    /// What became of a tapped `I'm here`.
    ///
    /// Four cases because four things can happen and three of them used to look
    /// exactly like the fourth. `try?` on a call that answers a refusal with nil
    /// collapsed a throw, a refusal and a success into one silent `Void`: the
    /// user tapped, the day was not recorded, nothing was said, and the
    /// notification carrying the button was gone.
    ///
    /// `alreadyCounted` is kept apart from `failed` deliberately. It is not a
    /// failure — the day is on the gauge, which is what the tap was for — and
    /// dressing it as one sends someone hunting for a problem that is not
    /// there. `refused` is the middle: nothing is broken, but the day is not
    /// counted and pressing again cannot change that.
    enum Confirmed: Equatable {
        case recorded
        case alreadyCounted(String)
        case refused(String)
        case failed(String)
    }

    /// The `I'm here` button. This is the only path that records attendance
    /// from an arrival — the geofence offers, the user confirms.
    ///
    /// Returns what happened, the way `handleEntry` returns its decision, so
    /// the caller and the tests can see it. It also *says* what happened, here
    /// rather than at the call site, because the call site is a delegate method
    /// on a lock screen: there is no screen to raise an alert on and no form to
    /// hold open, and the notification that carried the button is taken away by
    /// iOS the instant it is pressed. Another notification is the only surface
    /// there is.
    ///
    /// `today` is the day the follow-up would be delivered on as well as the
    /// day the store measures against, which is what decides whether the
    /// follow-up may offer the button again — see `notRecorded`.
    @discardableResult
    func confirmAttendance(
        officeID: UUID, day: Day, bookingID: UUID?, today: Day = .today, now: Date = .now
    ) -> Confirmed {
        let outcome: Confirmed
        do {
            outcome = try attend(day, officeID, bookingID, today)
                ? .recorded
                : Self.refusal(
                    day: day, officeID: officeID, attendance: recordedDays()
                )
        } catch {
            outcome = .failed(
                "That day couldn't be saved: \(error.localizedDescription)."
            )
        }

        let name = officeName(officeID)
        switch outcome {
        case .recorded:
            // Silent, and it has to stay silent. A "saved!" notification for
            // every arrival doubles the alerts to say what the gauge already
            // says, and an app that talks on the happy path is one whose
            // warnings stop being read.
            break
        case .alreadyCounted(let why):
            follow(
                ArrivalNotifications.alreadyCounted(officeName: name, day: day, why: why),
                officeID: officeID, day: day, bookingID: bookingID, at: now
            )
        case .refused(let why):
            follow(
                ArrivalNotifications.notRecorded(
                    officeName: name, day: day, why: why, retry: false
                ),
                officeID: officeID, day: day, bookingID: bookingID, at: now
            )
        case .failed(let why):
            follow(
                ArrivalNotifications.notRecorded(
                    officeName: name, day: day, why: why,
                    // Only a day being recorded on the day it is happening can
                    // be answered by a button, because `ArrivalNotifications.answer`
                    // refuses a payload whose day is not the day it was
                    // delivered on. Offering one for any other day would be
                    // offering a button that silently does nothing — which is
                    // the defect this whole notification exists to report.
                    retry: day == today
                ),
                officeID: officeID, day: day, bookingID: bookingID, at: now
            )
        }
        return outcome
    }

    /// Which kind of refusal it was, and what to say about it.
    ///
    /// `BookingStore.recordAttendance` answers every refusal with the same
    /// reasonless nil. The difference between "your day is already counted" and
    /// "something is wrong" is only visible from out here, by looking at what is
    /// actually on the day — so anything this cannot explain comes back as a
    /// refusal rather than as reassurance. Telling someone a day is counted when
    /// it is not would be the same silent lie in a friendlier voice.
    static func refusal(
        day: Day, officeID: UUID, attendance: [AttendanceDay]
    ) -> Confirmed {
        if attendance.contains(where: { $0.day == day && $0.officeID == officeID }) {
            return .alreadyCounted(
                "\(day.dayAndMonth) was already recorded here. A day counts once, however many times you walk in."
            )
        }
        let elsewhere = attendance.filter { $0.day == day }.reduce(0) { $0 + $1.fraction }
        if elsewhere >= 1 {
            return .alreadyCounted(
                "\(day.dayAndMonth) is already counted as a whole day at another office, so there was nothing to add."
            )
        }
        if elsewhere > 0 {
            // Half a day at another office and a whole day asked for here. The
            // store will not trim it to fit — how much of the day was spent
            // where is the user's fact, not the store's — so this one needs the
            // app, and the button would only be refused again.
            return .refused(
                "\(day.dayAndMonth) already has part of the day recorded at another office, and a whole day more would take it over one."
            )
        }
        return .refused("\(day.dayAndMonth) couldn't be recorded.")
    }

    /// What became of a tapped `No` on the evening question.
    enum Declined: Equatable {
        case answered
        case alreadyRecorded(String)
        /// The booking the question was about is gone. Nothing to write, and
        /// nothing to say — see `declineAttendance`.
        case noSuchBooking
        case failed(String)
    }

    /// The evening question's `No`. Records the answer, not an absence — see
    /// `BookingStore.markNotAttended`.
    ///
    /// Refuses to answer for a day already recorded. The nudge's content is
    /// decided when the app was last awake and the notification fires hours
    /// later, so a question can outlive its answer: confirm the day from the
    /// arrival alert at nine, and the evening still asks. Tapping No there must
    /// not overwrite a day that was worked — that record is the only copy.
    ///
    /// That refusal is now said out loud. It is the right refusal and it always
    /// was, but from the lock screen it looked exactly like the button not
    /// working: press No, nothing happens, press it again.
    @discardableResult
    func declineAttendance(bookingID: UUID, now: Date = .now) -> Declined {
        let bookings = (try? context.fetch(FetchDescriptor<DeskBooking>())) ?? []
        // Silent on purpose, and the only silent branch. A booking deleted
        // between the question being scheduled and the answer being given
        // leaves nothing to write and nothing to correct; telling someone their
        // No did not take, about a booking that no longer exists, is an alarm
        // about nothing.
        guard let booking = bookings.first(where: { $0.id == bookingID }) else {
            return .noSuchBooking
        }
        let name = officeName(booking.officeID)
        let recorded = recordedDays()
            .contains { $0.day == booking.day && $0.officeID == booking.officeID }
        guard !recorded else {
            let why = "You recorded \(booking.day.dayAndMonth) as a day you were there, so it was left as it is."
            follow(
                ArrivalNotifications.alreadyCounted(
                    officeName: name, day: booking.day, why: why
                ),
                officeID: booking.officeID, day: booking.day,
                bookingID: booking.id, at: now
            )
            return .alreadyRecorded(why)
        }

        // Read before the write, because the write is the mutation: the store
        // sets the flag and then saves, so a save that throws leaves this
        // context holding an answer the store never took — and the next
        // successful save anywhere in the app would commit it. Put back what
        // was there.
        let before = booking.notAttended
        do {
            try decline(booking)
            return .answered
        } catch {
            booking.notAttended = before
            let why = "That answer couldn't be saved: \(error.localizedDescription)."
            follow(
                ArrivalNotifications.notAnswered(
                    officeName: name, day: booking.day, why: why
                ),
                officeID: booking.officeID, day: booking.day,
                bookingID: booking.id, at: now
            )
            return .failed(why)
        }
    }

    /// Posts the answer to a button already pressed, in its own identifier
    /// space so iOS cannot mistake it for an edit of the alert that raised it.
    private func follow(
        _ content: ArrivalNotifications.Content,
        officeID: UUID, day: Day, bookingID: UUID?, at now: Date
    ) {
        post(ArrivalNotifications.request(
            content, officeID: officeID, day: day, bookingID: bookingID, at: now,
            identifier: ArrivalNotifications.followUpIdentifier(
                officeID: officeID, day: day, at: now
            )
        ))
    }

    // MARK: Reads

    /// One office on one day — the ledger's own key, and the only thing the
    /// settle window is scoped by.
    private struct Delivery: Hashable {
        let officeID: UUID
        let day: Day
    }

    /// Deliveries whose ledger row would not save, kept for this process only.
    ///
    /// Not a cache and not a queue: nothing retries these, and they are gone
    /// when the app is. They exist so that a save failing does not also cost the
    /// settle window — see `handleEntry`.
    private var unsavedDeliveries: [Delivery: Date] = [:]

    private func office(_ id: UUID) -> Office? {
        (try? context.fetch(FetchDescriptor<Office>()))?.first { $0.id == id }
    }

    /// For the follow-ups, which name the place the day was about. An office
    /// deleted between the alert and the tap leaves the sentence still standing
    /// rather than a blank where a name should be.
    private func officeName(_ id: UUID?) -> String {
        id.flatMap(office)?.name ?? "your office"
    }

    /// The most recent delivery for this office today, which is both the start
    /// of the settle window and the notification to withdraw.
    ///
    /// Rows and unsaved deliveries together, latest wins. A row that would not
    /// write is still an alert the user was shown, and the window has to hold
    /// for it or a boundary flutter seconds later alerts all over again.
    private func lastAlert(officeID: UUID, day: Day) -> Date? {
        let rows = ((try? context.fetch(FetchDescriptor<ArrivalAlert>())) ?? [])
            .filter { $0.day == day && $0.officeID == officeID }
            .map(\.deliveredAt)
        let unsaved = unsavedDeliveries[Delivery(officeID: officeID, day: day)]
        return (rows + [unsaved].compactMap { $0 }).max()
    }

    private func recordedDays() -> [AttendanceDay] {
        (try? context.fetch(FetchDescriptor<AttendanceDay>())) ?? []
    }

    private func attendance() -> [ArrivalRule.Attendance] {
        recordedDays().compactMap {
            guard let officeID = $0.officeID else { return nil }
            return ArrivalRule.Attendance(day: $0.day, officeID: officeID)
        }
    }

    private func bookings() -> [ArrivalRule.Booking] {
        ((try? context.fetch(FetchDescriptor<DeskBooking>())) ?? []).map {
            ArrivalRule.Booking(
                id: $0.id, officeID: $0.officeID, day: $0.day,
                deskID: $0.deskID, floor: $0.floor, zone: $0.zone
            )
        }
    }

    private func monthName(_ month: Month) -> String {
        String(month.text.split(separator: " ").first ?? "")
    }
}
