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

    init(context: ModelContext) {
        self.context = context
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
        context.insert(ArrivalAlert(day: day, officeID: officeID, deliveredAt: now))
        try? context.save()
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

    /// The `I'm here` button. This is the only path that records attendance
    /// from an arrival — the geofence offers, the user confirms.
    func confirmAttendance(
        officeID: UUID, day: Day, bookingID: UUID?, today: Day = .today
    ) {
        try? BookingStore.recordAttendance(
            day: day, officeID: officeID, source: .geofence,
            bookingID: bookingID, today: today, in: context
        )
    }

    // MARK: Reads

    private func office(_ id: UUID) -> Office? {
        (try? context.fetch(FetchDescriptor<Office>()))?.first { $0.id == id }
    }

    /// The most recent delivery for this office today, which is both the start
    /// of the settle window and the notification to withdraw.
    private func lastAlert(officeID: UUID, day: Day) -> Date? {
        ((try? context.fetch(FetchDescriptor<ArrivalAlert>())) ?? [])
            .filter { $0.day == day && $0.officeID == officeID }
            .map(\.deliveredAt)
            .max()
    }

    private func attendance() -> [ArrivalRule.Attendance] {
        ((try? context.fetch(FetchDescriptor<AttendanceDay>())) ?? []).compactMap {
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
