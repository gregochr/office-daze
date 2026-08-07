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
    /// ask. The office name and desk id come along because the notification
    /// names them, and by the time it fires there is no screen to fetch them.
    private static func unconfirmed(
        today: Day, bookings: [DeskBooking], in context: ModelContext
    ) -> EveningNudge.Unconfirmed? {
        guard let booking = bookings.first(where: { $0.day == today && !$0.notAttended })
        else { return nil }

        let attendance = (try? context.fetch(FetchDescriptor<AttendanceDay>())) ?? []
        let recorded = attendance.contains {
            $0.day == today && $0.officeID == booking.officeID
        }
        guard !recorded else { return nil }

        let office = ((try? context.fetch(FetchDescriptor<Office>())) ?? [])
            .first { $0.id == booking.officeID }
        return EveningNudge.Unconfirmed(
            day: today,
            officeID: booking.officeID,
            officeName: office?.name ?? "the office",
            bookingID: booking.id,
            deskID: booking.deskID
        )
    }
}
