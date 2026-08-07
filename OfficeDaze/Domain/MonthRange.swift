import Foundation

/// How far the month steppers will travel.
///
/// The two directions are not symmetrical, and the steppers should not pretend
/// otherwise. Backwards is a closed door: there will never be a booking in a
/// month earlier than the one your first record sits in, so stepping back into
/// it only ever shows an empty month with an empty gauge above it. Forwards is
/// open, because a desk can be reserved and a fortnight booked off as far ahead
/// as the booking system allows — a month with nothing in it yet is the normal
/// way to arrive at a month you are about to fill.
///
/// So only the back chevron stops.
nonisolated enum MonthRange {

    /// The earliest month worth stepping back to: as far back as the records
    /// go, and no further.
    ///
    /// Today is a floor rather than the whole answer. Taking only the earliest
    /// record would leave an empty store unable to move at all — including
    /// forwards from a month it had no reason to be stuck in — and taking only
    /// today would hide the history of anyone who has been using the app for
    /// longer than the month they are standing in.
    static func earliest(recorded: some Sequence<Day>, today: Day) -> Month {
        guard let first = recorded.min()?.month_ else { return today.month_ }
        return min(first, today.month_)
    }

    /// Whether the back chevron does anything from here.
    static func canStepBack(
        from month: Month, recorded: some Sequence<Day>, today: Day
    ) -> Bool {
        month > earliest(recorded: recorded, today: today)
    }
}
