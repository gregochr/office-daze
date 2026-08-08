import Foundation
import SwiftData
import UserNotifications

/// Schedules — and, more importantly, withdraws — the evening nudge.
///
/// The prompt to book tomorrow repeats daily, so that schedule survives the app
/// not running. The *decision* cannot: whether tomorrow needs a nudge changes
/// every day. So the app re-evaluates whenever it is awake — at launch, and
/// after anything that could change the answer — and removes the pending
/// notification when the conditions no longer hold.
///
/// The question about today does not repeat, because its content names a day
/// and its buttons write that day. See `EveningNudge.request`.
@MainActor
enum NudgeScheduler {

    private static let enabledKey = "nudge.enabled"
    private static let hourKey = "nudge.hour"
    private static let minuteKey = "nudge.minute"

    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// Defaults to 18:00 — late enough to know how the day went, early enough
    /// to still book something for tomorrow.
    ///
    /// Wall-clock time on the *device's* clock, not a Day-domain value: 18:00
    /// means six in the evening wherever the phone is, which is what a person
    /// setting a reminder means. Anything reading or writing this must use
    /// `Day.localCalendar()`, never `Day.calendar` — that one is pinned to UTC,
    /// and putting a UTC hour into a trigger that fires locally is how this
    /// reminder spent every British summer going off at five.
    static var time: DateComponents {
        get {
            let defaults = UserDefaults.standard
            guard defaults.object(forKey: hourKey) != nil else {
                return DateComponents(hour: 18, minute: 0)
            }
            return DateComponents(
                hour: defaults.integer(forKey: hourKey),
                minute: defaults.integer(forKey: minuteKey)
            )
        }
        set {
            UserDefaults.standard.set(newValue.hour ?? 18, forKey: hourKey)
            UserDefaults.standard.set(newValue.minute ?? 0, forKey: minuteKey)
        }
    }

    /// The picker hands back a `Date`; the trigger wants an hour and a minute on
    /// the device's clock. Both directions live here rather than inline in the
    /// settings screen, because the screen had them *both* wrong in the same
    /// direction — it read and wrote through `Day.calendar`, which is UTC — and
    /// two matching errors cancel on screen while the trigger keeps the mistake.
    /// A user in BST chose 18:00, 17 was stored, the picker redisplayed 18:00,
    /// and the reminder arrived at five with nothing anywhere admitting it.
    /// Isolated here they can be tested against a pinned zone.
    static func components(
        from picked: Date, in zone: TimeZone = .autoupdatingCurrent
    ) -> DateComponents {
        Day.localCalendar(zone).dateComponents([.hour, .minute], from: picked)
    }

    /// The `Date` to hand back to the picker. The day is only scaffolding — the
    /// picker shows hours and minutes — but it has to be a real one, so it is
    /// today's by default rather than an arbitrary epoch.
    static func pickerDate(
        for time: DateComponents, on day: Day = .today,
        in zone: TimeZone = .autoupdatingCurrent
    ) -> Date {
        Day.localCalendar(zone).date(from: DateComponents(
            year: day.year, month: day.month, day: day.day,
            hour: time.hour ?? 18, minute: time.minute ?? 0
        )) ?? .now
    }

    /// Swapped in tests so nothing reaches the notification centre.
    ///
    /// Plain `static var`, not `nonisolated(unsafe)`: the enum is `@MainActor`,
    /// so these are main-actor isolated and fully checked for free, which is how
    /// `ArrivalLedger.post`/`withdraw` — the same seam, one file over — have
    /// always been declared. The annotation bought nothing and silenced the one
    /// check that matters on shared mutable state: with it, a future
    /// `Task.detached` reading `schedule` compiles clean under Complete checking
    /// and races the main actor's write.
    static var schedule: (UNNotificationRequest) -> Void = { request in
        UNUserNotificationCenter.current().add(request)
    }
    static var withdraw: () -> Void = {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [EveningNudge.identifier])
    }

    /// Re-evaluates and either schedules or withdraws. Safe to call often —
    /// it is idempotent, and calling it too rarely is the failure mode that
    /// matters (a nudge that fires for a day already booked).
    @discardableResult
    static func refresh(today: Day = .today, in context: ModelContext) -> Bool {
        guard isEnabled else {
            withdraw()
            return false
        }

        let tomorrow = today.adding(days: 1)
        let bankHolidays = Set(BankHolidays.englandAndWales(in: tomorrow.month_))
        let bookings = (try? context.fetch(FetchDescriptor<DeskBooking>())) ?? []

        let snapshot = try? QuotaService.snapshot(
            for: tomorrow.month_, today: today, in: context
        )

        let input = EveningNudge.Input(
            tomorrow: tomorrow,
            isWorkingDay: tomorrow.isWeekday && !bankHolidays.contains(tomorrow),
            hasBookingTomorrow: bookings.contains { $0.day == tomorrow },
            shortfall: snapshot?.result.shortfall ?? 0,
            unconfirmedToday: unconfirmed(today: today, bookings: bookings, in: context)
        )

        switch EveningNudge.decide(input) {
        case .quiet:
            withdraw()
            return false

        case .bookTomorrow:
            let message = EveningNudge.message(
                shortfall: input.shortfall, tomorrow: tomorrow
            )
            schedule(EveningNudge.request(
                at: time, title: message.title, body: message.body
            ))
            return true

        case .confirmToday(let unconfirmed):
            let message = EveningNudge.confirmMessage(unconfirmed)
            schedule(EveningNudge.request(
                at: time, title: message.title, body: message.body,
                answering: unconfirmed
            ))
            return true
        }
    }

    /// Today's desk, if it was booked and nothing has been said about it.
    ///
    /// Answered either way — attended, or told no — and there is nothing left to
    /// ask. Every booking today is tested rather than only the first one the
    /// store hands back: two offices in one day is unusual but possible, a
    /// fetch has no order to rely on, and testing the wrong one would decide
    /// the whole day was answered on the strength of the other office's
    /// attendance. That is the failure this feature exists to catch.
    ///
    /// The office name and desk id come along because the notification names
    /// them, and by the time it fires there is no screen to fetch them.
    private static func unconfirmed(
        today: Day, bookings: [DeskBooking], in context: ModelContext
    ) -> EveningNudge.Unconfirmed? {
        let attendance = (try? context.fetch(FetchDescriptor<AttendanceDay>())) ?? []
        func recorded(_ officeID: UUID) -> Bool {
            attendance.contains { $0.day == today && $0.officeID == officeID }
        }

        let offices = (try? context.fetch(FetchDescriptor<Office>())) ?? []
        // Lowest desk ID wins, so a day with two unanswered desks asks about the
        // same one every evening rather than whichever the fetch happened to
        // return. `min(by:)` rather than `sorted(by:).first` — same element, and
        // it does not order the tail nobody looks at.
        guard let booking = bookings
            .filter({ $0.day == today && !$0.notAttended && !recorded($0.officeID) })
            .min(by: { $0.deskID < $1.deskID })
        else { return nil }

        return EveningNudge.Unconfirmed(
            day: today,
            officeID: booking.officeID,
            officeName: offices.first { $0.id == booking.officeID }?.name ?? "the office",
            bookingID: booking.id,
            deskID: booking.deskID
        )
    }
}
