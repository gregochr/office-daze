import Foundation

/// Every user-facing sentence about when the arrival alert fires.
///
/// These were written out separately on three screens. Changing the rule from
/// once-a-day to repeats-until-acknowledged left all three still promising the
/// old behaviour, and they were found one at a time, by the user, on the
/// screens they were wrong on. The wording differs because they sit in
/// different sentences; they live together so the next change to the rule
/// cannot quietly miss one, and so a test can hold them to it.
nonisolated enum ArrivalCopy {

    /// Under the mocked lock-screen card on the preview screen.
    static let preview = "Comes back on every arrival until you tap \"I'm here\"."

    /// Beneath the alert toggle and the perimeter stepper.
    static let officeEditor = """
        The alert shows your desk number when you arrive, and comes back on \
        every arrival until you tap "I'm here".
        """

    /// Under the list of offices in Settings.
    static let officesSection = """
        Each office has its own postcode and perimeter. The arrival alert comes \
        back on every arrival until you tap "I'm here", and stops for the day \
        once you have. All offices count toward the same monthly target.
        """

    /// The three of them, for the test that keeps them honest.
    static let all = [preview, officeEditor, officesSection]
}
