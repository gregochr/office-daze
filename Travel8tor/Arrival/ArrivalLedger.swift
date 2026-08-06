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

    init(context: ModelContext) {
        self.context = context
    }

    /// Called on a region entry. Returns the decision so the caller — and the
    /// tests — can see what happened.
    @discardableResult
    func handleEntry(officeID: UUID, day: Day = .today) -> ArrivalRule.Decision {
        guard let office = office(officeID) else { return .disabled }

        let decision = ArrivalRule.decide(.init(
            officeID: officeID,
            day: day,
            ledger: rows(),
            bookings: bookings(),
            alertEnabled: office.alertEnabled
        ))

        switch decision {
        case .alreadyFired, .disabled:
            // Nothing. Not a second notification, and not a second ledger row.
            return decision

        case .desk(let booking):
            deliver(office: office, day: day, desk: booking)
        case .nothingBooked:
            deliver(office: office, day: day, desk: nil)
        }

        // Written for both outcomes, so turning up with nothing booked also
        // prompts only once.
        context.insert(ArrivalAlert(day: day, officeID: officeID, deliveredAt: .now))
        try? context.save()
        return decision
    }

    private func deliver(office: Office, day: Day, desk: ArrivalRule.Booking?) {
        let snapshot = try? QuotaService.snapshot(
            for: day.month_, today: day, in: context
        )
        let content = ArrivalNotifications.content(
            officeName: office.name,
            desk: desk,
            attended: snapshot?.result.attended ?? 0,
            target: snapshot?.result.target ?? 0,
            monthName: monthName(day.month_)
        )
        post(ArrivalNotifications.request(
            content, officeID: office.id, day: day, bookingID: desk?.id
        ))
    }

    /// The `I'm here` button. This is the only path that records attendance
    /// from an arrival — the geofence offers, the user confirms.
    func confirmAttendance(officeID: UUID, day: Day, bookingID: UUID?) {
        try? BookingStore.recordAttendance(
            day: day, officeID: officeID, source: .geofence,
            bookingID: bookingID, in: context
        )
    }

    // MARK: Reads

    private func office(_ id: UUID) -> Office? {
        (try? context.fetch(FetchDescriptor<Office>()))?.first { $0.id == id }
    }

    private func rows() -> [ArrivalAlert.Row] {
        ((try? context.fetch(FetchDescriptor<ArrivalAlert>())) ?? [])
            .map { ArrivalAlert.Row(day: $0.day, officeID: $0.officeID) }
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
