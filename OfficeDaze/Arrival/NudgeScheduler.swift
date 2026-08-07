import Foundation
import SwiftData
import UserNotifications

/// Schedules — and, more importantly, withdraws — the evening nudge.
///
/// The trigger repeats daily, so the schedule survives the app not running.
/// The *decision* cannot: whether tomorrow needs a nudge changes every day. So
/// the app re-evaluates whenever it is awake — at launch, and after anything
/// that could change the answer — and removes the pending notification when
/// the conditions no longer hold.
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

    /// Swapped in tests so nothing reaches the notification centre.
    nonisolated(unsafe) static var schedule: (UNNotificationRequest) -> Void = { request in
        UNUserNotificationCenter.current().add(request)
    }
    nonisolated(unsafe) static var withdraw: () -> Void = {
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
        // Sorted, so a day with two unanswered desks asks about the same one
        // every evening rather than whichever the fetch happened to return.
        guard let booking = bookings
            .filter({ $0.day == today && !$0.notAttended && !recorded($0.officeID) })
            .sorted(by: { $0.deskID < $1.deskID })
            .first
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
