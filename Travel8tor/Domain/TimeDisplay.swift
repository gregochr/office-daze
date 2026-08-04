import Foundation

/// The time-zone display rule, applied everywhere without exception:
///
///   Render in the local time of the event. When that zone is not
///   Europe/London, the UK equivalent follows in brackets — `20:05 (19:05 UK)`.
///   Never the reverse. Never a bare time for an event abroad.
///
/// It lives here, as a pure function with tests, rather than in a view, because
/// "without exception" is only true if there is one implementation.
nonisolated enum TimeDisplay {

    static let uk = TimeZone(identifier: "Europe/London")!

    /// `20:05` — the local time of the event, always.
    static func local(_ instant: Date, in zone: TimeZone) -> String {
        var calendar = Day.calendar
        calendar.timeZone = zone
        let parts = calendar.dateComponents([.hour, .minute], from: instant)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }

    /// `19:05 UK`, or nil when the event is already in UK time.
    static func ukEquivalent(_ instant: Date, in zone: TimeZone) -> String? {
        guard !isUK(zone) else { return nil }
        return "\(local(instant, in: uk)) UK"
    }

    /// `20:05` at home, `20:05 (19:05 UK)` abroad. The inline form, for card
    /// metadata rows.
    static func inline(_ instant: Date, in zone: TimeZone) -> String {
        let time = local(instant, in: zone)
        guard let equivalent = ukEquivalent(instant, in: zone) else { return time }
        return "\(time) (\(equivalent))"
    }

    /// The stacked form, for ticket screens and cards where the UK line sits
    /// beneath the figure. `nil` second element means no second line — which is
    /// how a view knows not to reserve space for one.
    static func stacked(_ instant: Date, in zone: TimeZone) -> (time: String, uk: String?) {
        (local(instant, in: zone), ukEquivalent(instant, in: zone))
    }

    /// Zones are compared by their current offset, not by identifier. Europe/
    /// London and Europe/Belfast are different identifiers and the same clock;
    /// showing "(19:05 UK)" beside a Belfast time would be nonsense.
    static func isUK(_ zone: TimeZone) -> Bool {
        zone.identifier == uk.identifier
            || zone.secondsFromGMT(for: .now) == uk.secondsFromGMT(for: .now)
    }

    /// `2h01`, the journey duration on a ticket.
    static func duration(from start: Date, to end: Date) -> String {
        let total = Int(end.timeIntervalSince(start).rounded()) / 60
        return String(format: "%dh%02d", total / 60, total % 60)
    }

    /// `07–11.09`, a trip span.
    static func span(_ from: Day, _ to: Day) -> String {
        String(format: "%02d–%02d.%02d", from.day, to.day, to.month)
    }

    /// `WED 05.08`, a card's date line.
    static func dayStamp(_ day: Day) -> String {
        String(format: "%@ %02d.%02d", day.weekdayAbbreviation, day.day, day.month)
    }
}

extension Day {
    /// `MON`…`SUN`. Deliberately not locale-derived: the design is English and
    /// upper case throughout, and a device set to French should not render
    /// `MER` in the day gutter.
    nonisolated var weekdayAbbreviation: String {
        ["SUN", "MON", "TUE", "WED", "THU", "FRI", "SAT"][weekday - 1]
    }

    /// `AUGUST`, for the gauge kicker.
    nonisolated var monthName: String { Month(year: year, month: month).name }
}

extension Month {
    nonisolated var name: String {
        [
            "JANUARY", "FEBRUARY", "MARCH", "APRIL", "MAY", "JUNE",
            "JULY", "AUGUST", "SEPTEMBER", "OCTOBER", "NOVEMBER", "DECEMBER",
        ][month - 1]
    }

    /// `AUG 26`, for The Mission's month stepper.
    nonisolated var shortName: String {
        String(format: "%@ %02d", String(name.prefix(3)), year % 100)
    }
}
