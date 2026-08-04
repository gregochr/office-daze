import Foundation
import SwiftData
import UserNotifications

/// The arrival sequence with no CoreLocation in it: check the ledger, decide,
/// write the row, offer, and — separately — record the day once confirmed.
///
/// Split from `ArrivalMonitor` because none of this needs a location manager.
/// Keeping them together meant a test could not exercise the fire-once rule
/// without instantiating a real `CLLocationManager`, whose authorisation
/// callback then fired after the test's store had gone.
@MainActor
final class ArrivalLedger {

    private let context: ModelContext
    private let settings: ArrivalSettings
    private let copy: Copy

    /// Swapped in tests so nothing reaches the real notification centre.
    var deliver: (UNMutableNotificationContent) async -> Void = { content in
        let request = UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil
        )
        try? await UNUserNotificationCenter.current().add(request)
    }

    private(set) var lastDecision: ArrivalRule.Decision?

    init(context: ModelContext, settings: ArrivalSettings = .shared, copy: Copy = .shared) {
        self.context = context
        self.settings = settings
        self.copy = copy
    }

    // MARK: Entry

    /// The whole sequence: check the ledger, decide, write the row, offer.
    func handleEntry(placeID: UUID, day: Day = .today) async {
        let decision = decide(placeID: placeID, day: day)
        lastDecision = decision

        guard ArrivalRule.writesLedgerRow(decision) else { return }

        // The row is written when the alert is *delivered*, not when it is
        // confirmed — that is what makes it fire once whether or not you
        // answer. A declined prompt should not ask again at 14:00.
        context.insert(ArrivalAlert(day: day, placeID: placeID, deliveredAt: .now))
        try? context.save()

        guard let place = place(placeID) else { return }

        switch decision {
        case .offerBooked(let booking):
            let result = try? QuotaService
                .snapshot(for: day.month_, today: day, in: context).result
            await deliver(ArrivalNotifications.bookedContent(
                place: place, booking: booking, day: day,
                shortfall: Int((result?.shortfall ?? 0).rounded()),
                target: result?.target ?? 0,
                dayNumber: Int((result?.attended ?? 0).rounded()) + 1,
                copy: copy.callAsFunction
            ))
        case .offerUnbooked:
            await deliver(ArrivalNotifications.unbookedContent(
                place: place, day: day, copy: copy.callAsFunction
            ))
        case .doNothing:
            break
        }
    }

    func decide(placeID: UUID, day: Day) -> ArrivalRule.Decision {
        let ledger = ((try? context.fetch(FetchDescriptor<ArrivalAlert>())) ?? [])
            .map { (day: $0.day, placeID: $0.placeID) }

        let desks = ((try? context.fetch(FetchDescriptor<Booking>())) ?? [])
            .compactMap { booking -> ArrivalRule.DeskBooking? in
                guard let desk = booking.detail?.deskDetail else { return nil }
                return ArrivalRule.DeskBooking(
                    id: booking.id, placeID: desk.placeID, day: booking.anchorDay,
                    deskID: desk.deskID, floor: desk.floor, zone: desk.zone
                )
            }

        let attended = Set(
            ((try? context.fetch(FetchDescriptor<AttendanceDay>())) ?? []).map(\.day)
        )

        return ArrivalRule.decide(.init(
            day: day, placeID: placeID,
            ledger: ledger, deskBookings: desks, attendedDays: attended,
            fireRate: settings.fireRate, enabled: settings.enabled
        ))
    }

    // MARK: Confirmation

    /// The only path that writes an `AttendanceDay`. The geofence offers; this
    /// is the confirming.
    ///
    /// Deliberately not called from `handleEntry`, even on a day with a desk
    /// booked. The design brief is explicit that attendance is never written
    /// silently. (The handoff README's sequence does say to write one on
    /// delivery for the booked case; the brief's rule wins — a geofence hit at
    /// the wrong building must not quietly move the count.)
    @discardableResult
    func confirmAttendance(placeID: UUID, bookingID: UUID?, day: Day) -> Bool {
        let existing = (try? context.fetch(FetchDescriptor<AttendanceDay>())) ?? []
        guard !existing.contains(where: { $0.day == day }) else { return false }

        context.insert(AttendanceDay(
            day: day, placeID: placeID, source: .geofence, fraction: 1.0, bookingID: bookingID
        ))
        try? context.save()
        return true
    }

    func place(_ id: UUID) -> Place? {
        ((try? context.fetch(FetchDescriptor<Place>())) ?? []).first { $0.id == id }
    }

    /// Places worth monitoring: those we have coordinates for.
    var monitorablePlaces: [Place] {
        ((try? context.fetch(FetchDescriptor<Place>())) ?? [])
            .filter { $0.latitude != 0 || $0.longitude != 0 }
    }
}
