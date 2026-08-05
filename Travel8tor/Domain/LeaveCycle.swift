import Foundation

/// What tapping a day in The Mission's grid does to its leave.
///
/// A pure function rather than three branches inside the view, for the same
/// reason the rest of `Domain/` is: the states are easy to get subtly wrong —
/// a half that will not clear, a full day that skips the half — and none of
/// that is worth a store and a screen to find out about.
nonisolated enum LeaveCycle {

    /// None → a full day → a half → none.
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

    /// Whether a day in a given grid state may be given leave at all.
    ///
    /// A day already attended is history — you were there. A bank holiday is
    /// already out of working days, so marking it as leave would deduct the
    /// same day twice and quietly lower the target.
    static func editable(_ state: MissionGrid.State) -> Bool {
        state != .attended && state != .bankHoliday
    }
}
