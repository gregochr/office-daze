import Foundation

/// What tapping a day in the leave grid does to it.
///
/// A pure function rather than three branches inside the view, because the
/// states are easy to get subtly wrong — a half that will not clear, a whole
/// day that skips the half — and none of that is worth a screen to find out
/// about.
nonisolated enum LeaveCycle {

    /// None → a whole day → a half → none.
    ///
    /// Half last rather than first because whole days are the common case, and
    /// making the common case one tap and the rare case two is the right way
    /// round.
    static func next(after fraction: Double?) -> Double? {
        switch fraction {
        case .none: 1.0
        case .some(let current) where current >= 1: 0.5
        default: nil
        }
    }

    /// Whether a day can be given leave at all.
    ///
    /// A weekend and a bank holiday are already outside working days, so
    /// marking one as leave would deduct the same day twice and quietly lower
    /// the target. A day already attended is history — you were there.
    static func editable(day: Day, bankHolidays: Set<Day>, attended: Set<Day>) -> Bool {
        day.isWeekday && !bankHolidays.contains(day) && !attended.contains(day)
    }
}
