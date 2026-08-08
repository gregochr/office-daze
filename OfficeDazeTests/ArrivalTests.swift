import Foundation
import SwiftData
import Testing
import UserNotifications
@testable import OfficeDaze

/// The rule the whole feature turns on. Four outcomes, tested without a device
/// walking through a door.
@Suite("The arrival rule")
struct ArrivalRuleTests {

    let london = UUID()
    let brussels = UUID()
    let today = Day(2026, 8, 5)

    func booking(_ office: UUID, _ day: Day, desk: String = "3C-114") -> ArrivalRule.Booking {
        .init(
            id: UUID(), officeID: office, day: day, deskID: desk,
            floor: "Level 3", zone: "C"
        )
    }

    @Test("A desk booked for today at this office is what the alert shows")
    func showsTheDesk() {
        let desk = booking(london, today)
        let decision = ArrivalRule.decide(.init(
            officeID: london, day: today, bookings: [desk]
        ))
        #expect(decision == .desk(desk))
    }

    /// The whole point of the repeat: having alerted once is not a reason to
    /// stay quiet. The desk number is what the user came for, and one
    /// notification missed on the walk in is gone.
    @Test("A later arrival on an unacknowledged day alerts again")
    func repeatsUntilAcknowledged() {
        let arrived = Date(timeIntervalSince1970: 1_785_000_000)
        let desk = booking(london, today)
        let decision = ArrivalRule.decide(.init(
            officeID: london, day: today,
            lastAlert: arrived,
            now: arrived.addingTimeInterval(ArrivalRule.settleWindow + 1),
            bookings: [desk]
        ))
        #expect(decision == .desk(desk))
    }

    /// The acknowledgement, and the only thing that stops the day.
    @Test("A day already recorded at this office alerts no further")
    func acknowledged() {
        let decision = ArrivalRule.decide(.init(
            officeID: london, day: today,
            attendance: [.init(day: today, officeID: london)],
            bookings: [booking(london, today)]
        ))
        #expect(decision == .acknowledged)
    }

    @Test("The acknowledgement is per office and per day, not global")
    func acknowledgementIsScoped() {
        let recorded = [ArrivalRule.Attendance(day: today, officeID: london)]

        // A different office on the same day still alerts.
        #expect(
            ArrivalRule.decide(.init(officeID: brussels, day: today, attendance: recorded))
                == .nothingBooked
        )
        // The same office tomorrow still alerts.
        #expect(
            ArrivalRule.decide(
                .init(officeID: london, day: today.adding(days: 1), attendance: recorded)
            ) == .nothingBooked
        )
    }

    /// Drift across the perimeter is not an arrival. Without this a boundary
    /// flutter delivers a burst of identical alerts, which is how a
    /// notification gets switched off for good.
    @Test("A crossing moments after the last alert is drift, not a return")
    func settles() {
        let arrived = Date(timeIntervalSince1970: 1_785_000_000)
        #expect(
            ArrivalRule.decide(.init(
                officeID: london, day: today,
                lastAlert: arrived,
                now: arrived.addingTimeInterval(ArrivalRule.settleWindow - 1),
                bookings: [booking(london, today)]
            )) == .settling
        )
    }

    /// Order matters: an acknowledged day is silent whether or not the window
    /// has passed, and the window never resurrects an acknowledged day.
    @Test("Acknowledgement is checked before the settle window")
    func acknowledgementOutranksTheWindow() {
        let arrived = Date(timeIntervalSince1970: 1_785_000_000)
        #expect(
            ArrivalRule.decide(.init(
                officeID: london, day: today,
                attendance: [.init(day: today, officeID: london)],
                lastAlert: arrived,
                now: arrived.addingTimeInterval(ArrivalRule.settleWindow + 1)
            )) == .acknowledged
        )
    }

    /// Turning up with nothing booked is the inverted prompt, not silence — the
    /// day still counts if the user says it does.
    @Test("Arriving with nothing booked still offers to record the day")
    func nothingBooked() {
        #expect(
            ArrivalRule.decide(.init(officeID: london, day: today)) == .nothingBooked
        )
        // A booking at a different office, or on a different day, is not this
        // arrival's booking.
        #expect(
            ArrivalRule.decide(.init(
                officeID: london, day: today,
                bookings: [booking(brussels, today), booking(london, today.adding(days: 1))]
            )) == .nothingBooked
        )
    }

    @Test("An office with its alert switched off never fires")
    func disabled() {
        #expect(
            ArrivalRule.decide(.init(
                officeID: london, day: today,
                bookings: [booking(london, today)], alertEnabled: false
            )) == .disabled
        )
    }
}

@Suite("The arrival alert's copy")
struct ArrivalNotificationTests {

    /// Three screens described the old rule, and changing it left all three
    /// promising once a day. Copy cannot be tested for being *right*, but it
    /// can be held to naming the thing that actually ends the alert — and the
    /// old promise can be kept from coming back.
    @Test("No screen still promises the alert fires once a day")
    func copyMatchesTheRule() {
        for line in ArrivalCopy.all {
            #expect(!line.localizedCaseInsensitiveContains("once a day"))
            #expect(!line.localizedCaseInsensitiveContains("once per day"))
            #expect(
                line.contains("I'm here"),
                "the acknowledgement is the only thing that stops it, so each line says so"
            )
        }
    }

    func booking(floor: String? = "Level 3", zone: String? = "C") -> ArrivalRule.Booking {
        .init(
            id: UUID(), officeID: UUID(), day: Day(2026, 8, 5),
            deskID: "3C-114", floor: floor, zone: zone
        )
    }

    /// The desk id is the title because the title is the largest text iOS will
    /// render on a lock screen, and reading it at arm's length without
    /// unlocking is the entire point.
    @Test("The desk number is the headline")
    func deskIsTheTitle() {
        let content = ArrivalNotifications.content(
            officeName: "Coleman", desk: booking(),
            attended: 4, target: 7, monthName: "August"
        )
        #expect(content.title == "3C-114")
        #expect(content.subtitle == "You're at Coleman")
        #expect(content.body.contains("Level 3, Zone C"))
        #expect(content.body.contains("Day 4 of 7 for August"))
        #expect(content.category == .booked)
    }

    /// A floor is free text: people type "Level 3", the Coleman system prints
    /// "03". A bare "03" on a lock screen says nothing, so it gets the word —
    /// but a value that already carries one must not become "Level Level 3".
    @Test("The floor gets the word Level exactly once")
    func floorIsNotDoublePrefixed() {
        #expect(ArrivalNotifications.level("Level 3") == "Level 3")
        #expect(ArrivalNotifications.level("03") == "Level 03")
        #expect(ArrivalNotifications.level("3") == "Level 3")
        #expect(ArrivalNotifications.level("Mezzanine") == "Mezzanine")

        let content = ArrivalNotifications.content(
            officeName: "Coleman", desk: booking(floor: "Level 3"),
            attended: 4, target: 7, monthName: "August"
        )
        #expect(content.body.contains("Level 3, Zone C"))
        #expect(!content.body.contains("Level Level"))
    }

    /// Only what was actually read. A floor the capture could not make out is
    /// absent from the line rather than an empty "Level ,".
    @Test("An unread floor or zone is left out, not left blank")
    func omitsUnreadFields() {
        let neither = ArrivalNotifications.content(
            officeName: "Brussels", desk: booking(floor: nil, zone: nil),
            attended: 1, target: 7, monthName: "August"
        )
        #expect(!neither.body.contains("Level"))
        #expect(!neither.body.contains("Zone"))
        #expect(neither.body.contains("Day 1 of 7"))

        let floorOnly = ArrivalNotifications.content(
            officeName: "Brussels", desk: booking(zone: nil),
            attended: 1, target: 7, monthName: "August"
        )
        #expect(floorOnly.body.contains("Level 3"))
        #expect(!floorOnly.body.contains("Level Level"))
        #expect(!floorOnly.body.contains("Zone"))
    }

    /// The largest line iOS renders is worth a fact. With no desk to show, the
    /// old title said "You're on site" — which the subtitle says again a line
    /// later, in more detail — so the month position takes it instead.
    @Test("The unbooked prompt puts the month position in the title")
    func unbooked() {
        let content = ArrivalNotifications.content(
            officeName: "Coleman", desk: nil,
            attended: 4, target: 7, monthName: "August"
        )
        #expect(content.title == "Day 4 of 7")
        #expect(!content.title.contains("on site"), "the subtitle already says where")
        #expect(content.body.contains("No desk booked today."))
        #expect(content.body.contains("Tap to make it 5."))
        #expect(content.category == .unbooked)
    }

    /// The day being arrived at is not attended yet — it becomes day 5 only
    /// once the user confirms.
    @Test("The count is what is already recorded, not what today might become")
    func dayCount() {
        #expect(
            ArrivalNotifications.dayCount(attended: 4, target: 7, monthName: "August")
                == "Day 4 of 7 for August"
        )
        #expect(
            ArrivalNotifications.dayCount(attended: 4.5, target: 7, monthName: "August")
                == "Day 4.5 of 7 for August"
        )
    }

    /// The two assertions above and the one in `consequence` are the only ones
    /// in this suite that exercise a half day, and they were the only two that
    /// could pass or fail on the region the machine running them happened to be
    /// set to: the formatter behind them followed `Locale.autoupdatingCurrent`,
    /// so "4.5" became "4,5" on a French simulator and both went red with no
    /// code change. Pinned in production now, the way `Day`'s formatters are.
    @Test("The half-day figure is pinned to en_GB, not to the device's region")
    func halfDaysDoNotFollowTheDeviceRegion() {
        #expect(
            ArrivalNotifications.dayCount(attended: 4.5, target: 7, monthName: "August")
                == "Day 4.5 of 7 for August"
        )
        #expect(ArrivalNotifications.shortCount(attended: 4.5, target: 7) == "Day 4.5 of 7")
        #expect(ArrivalNotifications.consequence(attended: 4.5) == "tap to make it 5.5")
        #expect(
            EveningNudge.message(shortfall: 2.5, tomorrow: Day(2026, 8, 12))
                .body.contains("2.5 days still to go")
        )

        // What the three above are actually guarding. This is the rendering a
        // comma-decimal device gives, and it is what they used to produce there
        // — so a full stop asserted above is the pin holding, not the host
        // agreeing by accident.
        #expect(
            (4.5).formatted(
                .number.precision(.fractionLength(0...1))
                    .locale(Locale(identifier: "fr_FR"))
            ) == "4,5"
        )
    }

    /// The count alone reads as though turning up had already been counted,
    /// which is the one thing this app never claims. The tail says what the
    /// button will do about it.
    @Test("The count names the consequence of the button under it")
    func consequence() {
        let content = ArrivalNotifications.content(
            officeName: "Coleman", desk: booking(),
            attended: 4, target: 7, monthName: "August"
        )
        #expect(content.body.contains("Day 4 of 7 for August — tap to make it 5"))
        #expect(ArrivalNotifications.consequence(attended: 4.5) == "tap to make it 5.5")
    }

    /// Arriving at a second office on a day already recorded at the first. The
    /// alert still fires — the acknowledgement is per office — but the button
    /// under it will not move the count, so nothing promises that it will.
    @Test("A day already recorded drops the tail rather than promising a fifth")
    func alreadyRecordedDropsTheTail() {
        let booked = ArrivalNotifications.content(
            officeName: "Brussels", desk: booking(),
            attended: 5, target: 7, monthName: "August", alreadyRecorded: true
        )
        #expect(booked.body.contains("Day 5 of 7 for August"))
        #expect(!booked.body.contains("tap to make it"))

        let unbooked = ArrivalNotifications.content(
            officeName: "Brussels", desk: nil,
            attended: 5, target: 7, monthName: "August", alreadyRecorded: true
        )
        #expect(unbooked.title == "Day 5 of 7", "still the fact worth the largest line")
        #expect(!unbooked.body.contains("Tap to make it"))
    }

    /// A default-level notification under a Work Focus is silently held back,
    /// and a Work Focus is exactly what is running when someone walks into an
    /// office at nine. This is the line that makes the alert arrive.
    @Test("The alert is Time Sensitive, so a Work Focus does not swallow it")
    func timeSensitive() {
        let request = ArrivalNotifications.request(
            ArrivalNotifications.content(
                officeName: "Coleman", desk: booking(),
                attended: 4, target: 7, monthName: "August"
            ),
            officeID: UUID(), day: Day(2026, 8, 5), bookingID: nil,
            at: Date(timeIntervalSince1970: 1_785_000_000)
        )
        #expect(request.content.interruptionLevel == .timeSensitive)
    }

    @Test("Every category that asks a question offers the confirm button")
    func categories() {
        let categories = ArrivalNotifications.categories
        #expect(
            categories.count == 4,
            "booked, unbooked, the evening question, and the follow-up that asks nothing"
        )
        let asking = categories.filter {
            $0.identifier != ArrivalNotifications.Category.followUp.rawValue
        }
        let confirmable = asking.allSatisfy { category in
            category.actions.contains { $0.identifier == ArrivalNotifications.Action.confirm.rawValue }
        }
        #expect(confirmable, "attendance must be recordable from the lock screen")

        // Registered, and registered with nothing on it. Leaving the identifier
        // unregistered would produce the same bare notification, which is the
        // problem: a typo and a decision would look identical on the lock
        // screen. And a button here would be a second promise from the alert
        // that has just admitted it could not keep the first.
        let followUp = categories.first {
            $0.identifier == ArrivalNotifications.Category.followUp.rawValue
        }
        #expect(followUp != nil)
        #expect(followUp?.actions.isEmpty == true)

        // The evening question is about a morning that has been and gone, so
        // "I'm here" is the wrong tense — but the identifier is the same one,
        // which is what lets it record through the handler that already exists.
        let evening = categories.first {
            $0.identifier == ArrivalNotifications.Category.nudgeConfirm.rawValue
        }
        let titles = evening?.actions.map(\.title) ?? []
        #expect(titles == ["I was there", "No"])
    }

    @Test("The request carries what the confirm button needs to write the record")
    func requestUserInfo() throws {
        let desk = booking()
        let officeID = UUID()
        let request = ArrivalNotifications.request(
            ArrivalNotifications.content(
                officeName: "Coleman", desk: desk,
                attended: 4, target: 7, monthName: "August"
            ),
            officeID: officeID, day: Day(2026, 8, 5), bookingID: desk.id,
            at: Date(timeIntervalSince1970: 1_785_000_000)
        )
        let info = request.content.userInfo
        #expect(info[ArrivalNotifications.UserInfo.officeID] as? String == officeID.uuidString)
        #expect(info[ArrivalNotifications.UserInfo.day] as? String == "2026-08-05")
        #expect(info[ArrivalNotifications.UserInfo.bookingID] as? String == desk.id.uuidString)
    }

    /// The lock screen is the only surface a tapped button has: the
    /// notification carrying it is gone the instant it is pressed, so a write
    /// that did not land has to arrive as another notification or not at all.
    ///
    /// Whether it brings the button back is not a matter of taste.
    /// `answer(to:userInfo:delivered:)` refuses any payload whose day is not the
    /// day it was delivered on, so a button offered for a day gone by would be a
    /// button that silently did nothing — the very defect this alert exists to
    /// report.
    @Test("The follow-up offers the button again only when a button could answer it")
    func retryOnlyWhereItCouldWork() {
        let today = ArrivalNotifications.notRecorded(
            officeName: "Coleman", day: Day(2026, 8, 12),
            why: "That day couldn't be saved.", retry: true
        )
        #expect(today.title == "Not recorded")
        #expect(today.subtitle == "12 August at Coleman")
        #expect(today.body.contains("That day couldn't be saved."))
        #expect(today.body.contains("Tap I'm here to try again."))
        #expect(
            today.category != .followUp,
            "the retry needs a category that carries the confirm action"
        )
        #expect(
            ArrivalNotifications.categories
                .first { $0.identifier == today.category.rawValue }?
                .actions.contains { $0.identifier == ArrivalNotifications.Action.confirm.rawValue }
                == true
        )

        let gone = ArrivalNotifications.notRecorded(
            officeName: "Coleman", day: Day(2026, 8, 12),
            why: "That day couldn't be saved.", retry: false
        )
        #expect(gone.category == .followUp, "a button here could not answer for that day")
        #expect(gone.body.contains("Open Office Daze to record the day."))
        #expect(!gone.body.contains("Tap I'm here"))
    }

    /// The store refusing a day that is already worth a whole day is not a
    /// failure — the day is on the gauge, which is what the tap was for. Wearing
    /// the same title as a disk that would not write would send someone hunting
    /// for a problem that is not there.
    @Test("A day already counted is told as reassurance, not as an error")
    func alreadyCountedIsNotAnError() {
        let content = ArrivalNotifications.alreadyCounted(
            officeName: "Brussels", day: Day(2026, 8, 4),
            why: "4 August is already counted as a whole day at another office."
        )
        #expect(content.title == "Already counted")
        #expect(!content.title.localizedCaseInsensitiveContains("not"))
        #expect(content.subtitle == "4 August at Brussels")
        #expect(content.body.contains("already counted as a whole day"))
        #expect(content.category == .followUp, "nothing left to press")
    }

    /// "Not recorded" over a declined day says the opposite of what happened:
    /// it reads as the app confirming the day was marked as one you were not
    /// there for, which is precisely the write that failed.
    @Test("A lost No does not announce itself as a day recorded")
    func notAnsweredHasItsOwnTitle() {
        let content = ArrivalNotifications.notAnswered(
            officeName: "Brussels", day: Day(2026, 8, 11),
            why: "That answer couldn't be saved: the disk is full."
        )
        #expect(content.title == "Not saved")
        #expect(content.title != "Not recorded")
        #expect(content.body.contains("the disk is full"))
        #expect(content.body.contains("still unanswered"))
        #expect(content.category == .followUp)
    }

    /// A follow-up posted in the same second as the arrival it answers would
    /// share that arrival's identifier, and iOS reads a repeated identifier as
    /// an edit of the notification already on screen.
    @Test("A follow-up cannot be mistaken for an edit of the alert it answers")
    func followUpHasItsOwnIdentifier() {
        let officeID = UUID()
        let day = Day(2026, 8, 12)
        let at = Date(timeIntervalSince1970: 1_785_000_000)

        let arrival = ArrivalNotifications.identifier(officeID: officeID, day: day, at: at)
        let followUp = ArrivalNotifications.followUpIdentifier(
            officeID: officeID, day: day, at: at
        )
        #expect(arrival != followUp, "the same second must not collide")

        let request = ArrivalNotifications.request(
            ArrivalNotifications.alreadyCounted(officeName: "Coleman", day: day, why: "w"),
            officeID: officeID, day: day, bookingID: nil, at: at, identifier: followUp
        )
        #expect(request.identifier == followUp)
        // The default is still the arrival's own, so nothing else moved.
        #expect(
            ArrivalNotifications.request(
                ArrivalNotifications.content(
                    officeName: "Coleman", desk: nil, attended: 4, target: 7,
                    monthName: "August"
                ),
                officeID: officeID, day: day, bookingID: nil, at: at
            ).identifier == arrival
        )
    }

    /// iOS reads a repeated identifier as an edit of the notification already
    /// on screen, not as a new one — so two arrivals sharing an identifier
    /// would rewrite the first alert silently instead of alerting again.
    @Test("Each delivery has its own identifier")
    func identifierIsPerDelivery() {
        let officeID = UUID()
        let day = Day(2026, 8, 5)
        let first = Date(timeIntervalSince1970: 1_785_000_000)
        #expect(
            ArrivalNotifications.identifier(officeID: officeID, day: day, at: first)
                != ArrivalNotifications.identifier(
                    officeID: officeID, day: day, at: first.addingTimeInterval(3600)
                )
        )
        // Reconstructible: the ledger stores the time, and the identifier of
        // the notification to withdraw is derived from it rather than kept.
        #expect(
            ArrivalNotifications.identifier(officeID: officeID, day: day, at: first)
                == ArrivalNotifications.identifier(officeID: officeID, day: day, at: first)
        )
    }
}

/// The evening question names one day, and its buttons write that day. Every
/// test here is about keeping those two facts from drifting apart — which they
/// did, silently, for as long as the notification repeated.
@Suite("The evening question's day")
struct EveningNudgeStalenessTests {

    let london = TimeZone(identifier: "Europe/London")!
    let brussels = TimeZone(identifier: "Europe/Brussels")!
    let sixOClock = DateComponents(hour: 18, minute: 0)

    func unconfirmed(_ day: Day) -> EveningNudge.Unconfirmed {
        .init(
            day: day, officeID: UUID(), officeName: "Coleman",
            bookingID: UUID(), deskID: "3C-114"
        )
    }

    /// The defect this suite exists for. A repeating trigger redelivered "Were
    /// you at Coleman today?" the next evening still carrying yesterday's date;
    /// "I was there" then wrote attendance for a day the user was not there,
    /// and left the day they were there unrecorded.
    @Test("A question about one day is pinned to that day's evening and asked once")
    func theQuestionCannotOutliveItsDay() throws {
        let request = EveningNudge.request(
            at: sixOClock, title: "t", body: "b",
            answering: unconfirmed(Day(2026, 8, 11)), in: london
        )
        let trigger = try #require(request.trigger as? UNCalendarNotificationTrigger)

        #expect(!trigger.repeats, "a repeat asks about the 11th again on the 12th")
        #expect(trigger.dateComponents.year == 2026)
        #expect(trigger.dateComponents.month == 8)
        #expect(trigger.dateComponents.day == 11, "the day it asks about, not any day")
        #expect(trigger.dateComponents.hour == 18)
        #expect(trigger.dateComponents.minute == 0)

        // The invariant the response handler leans on: whatever day the payload
        // names, the trigger can only deliver it on that same day.
        #expect(
            request.content.userInfo[ArrivalNotifications.UserInfo.day] as? String
                == "2026-08-11"
        )
    }

    /// Six in the evening means six on the phone's clock. Built in two zones the
    /// same wall-clock question is two different instants, an hour apart — which
    /// is the check that the zone is used rather than accepted and ignored.
    @Test("Six in the evening is six where the phone is")
    func theEveningIsLocal() throws {
        func instant(_ zone: TimeZone) throws -> Date {
            let request = EveningNudge.request(
                at: sixOClock, title: "t", body: "b",
                answering: unconfirmed(Day(2026, 8, 11)), in: zone
            )
            let trigger = try #require(request.trigger as? UNCalendarNotificationTrigger)
            return try #require(Day.localCalendar(zone).date(from: trigger.dateComponents))
        }

        // 18:00 BST is 17:00 UTC; 18:00 CEST is 16:00 UTC.
        let utc = Day.localCalendar(TimeZone(identifier: "UTC")!)
        #expect(try instant(london) == utc.date(from: DateComponents(
            year: 2026, month: 8, day: 11, hour: 17
        )))
        #expect(try instant(brussels) == utc.date(from: DateComponents(
            year: 2026, month: 8, day: 11, hour: 16
        )))
    }

    /// The other branch keeps its repeat, and keeps it on purpose: it carries no
    /// payload and its category has no buttons, so a stale redelivery reads
    /// oddly rather than writing anything — and the app is not running most
    /// evenings, so a schedule that needs the app awake is a schedule that stops.
    @Test("The prompt to book tomorrow still repeats, and names no single date")
    func theBookingPromptRepeats() throws {
        let request = EveningNudge.request(
            at: DateComponents(hour: 18, minute: 30), title: "t", body: "b", in: london
        )
        let trigger = try #require(request.trigger as? UNCalendarNotificationTrigger)

        #expect(trigger.repeats)
        #expect(trigger.dateComponents.day == nil, "any day, or it is not a daily match")
        #expect(trigger.dateComponents.hour == 18)
        #expect(trigger.dateComponents.minute == 30)
        #expect(
            request.content.userInfo.isEmpty,
            "nothing for a button to write, which is what makes the repeat safe"
        )
    }
}

/// What a tapped button is allowed to write. The rule is pure so that it can be
/// tested at all: `UNNotificationResponse` has no initialiser a test can call,
/// so anything decided inside the delegate method is untestable by construction.
@Suite("The answer a tapped notification gives")
struct NotificationAnswerTests {

    let officeID = UUID()
    let bookingID = UUID()
    let day = Day(2026, 8, 11)

    func payload(day: Day, booking: UUID?) -> [AnyHashable: Any] {
        [
            ArrivalNotifications.UserInfo.officeID: officeID.uuidString,
            ArrivalNotifications.UserInfo.day: day.description,
            ArrivalNotifications.UserInfo.bookingID: booking?.uuidString ?? "",
        ]
    }

    func answer(
        _ action: ArrivalNotifications.Action, day: Day = Day(2026, 8, 11),
        booking: UUID? = nil, delivered: Day
    ) -> ArrivalNotifications.Answer {
        ArrivalNotifications.answer(
            to: action.rawValue, userInfo: payload(day: day, booking: booking),
            delivered: delivered
        )
    }

    @Test("An answer about the day it was delivered on records that day")
    func recordsTheDayItAsksAbout() {
        #expect(
            answer(.confirm, booking: bookingID, delivered: day)
                == .record(officeID: officeID, day: day, bookingID: bookingID)
        )
    }

    /// The failure this guard exists for. Content built for the 11th, delivered
    /// again on the 12th, answered "I was there" — the write must not happen,
    /// because it would record a day the user was not there while leaving the
    /// day they were there unrecorded. `recordAttendance` cannot catch it: its
    /// only date check is `day <= today`, which a stale past day passes.
    @Test("A payload delivered on a later day is not an answer to anything")
    func refusesARedelivery() {
        #expect(answer(.confirm, booking: bookingID, delivered: Day(2026, 8, 12)) == .ignore)
        #expect(answer(.decline, booking: bookingID, delivered: Day(2026, 8, 12)) == .ignore)
        // And the day before, which is the case a "recent enough" guard would
        // have waved through: content for the 11th cannot be delivered on the
        // 10th, so a payload claiming it is not to be trusted either.
        #expect(answer(.confirm, booking: bookingID, delivered: Day(2026, 8, 10)) == .ignore)
    }

    /// The check is against the *delivery* date, not against today, and this is
    /// why: an alert can sit on a lock screen for days. Monday's arrival tapped
    /// on Wednesday is still Monday's arrival and still records Monday.
    @Test("A tap days later still records the day the alert was delivered for")
    func aLateTapStillCounts() {
        let old = Day(2026, 1, 5)
        #expect(
            answer(.confirm, day: old, booking: nil, delivered: old)
                == .record(officeID: officeID, day: old, bookingID: nil)
        )
    }

    @Test("No is an answer only when it names the booking it answers for")
    func declineNeedsABooking() {
        #expect(
            answer(.decline, booking: bookingID, delivered: day)
                == .decline(bookingID: bookingID)
        )
        // The arrival alert writes "" where there is no booking, so this has to
        // survive a string that is not a UUID rather than a missing key.
        #expect(answer(.decline, booking: nil, delivered: day) == .ignore)
    }

    @Test("Dismissing, and anything that is not a button, writes nothing")
    func nonAnswers() {
        #expect(answer(.dismiss, booking: bookingID, delivered: day) == .ignore)
        #expect(
            ArrivalNotifications.answer(
                to: UNNotificationDefaultActionIdentifier,
                userInfo: payload(day: day, booking: bookingID), delivered: day
            ) == .ignore,
            "opening the app is not saying you were there"
        )
    }

    @Test("A payload missing or malformed writes nothing")
    func malformedPayloads() {
        let good = payload(day: day, booking: bookingID)
        let confirm = ArrivalNotifications.Action.confirm.rawValue

        var noOffice = good
        noOffice[ArrivalNotifications.UserInfo.officeID] = nil
        #expect(ArrivalNotifications.answer(to: confirm, userInfo: noOffice, delivered: day) == .ignore)

        var badOffice = good
        badOffice[ArrivalNotifications.UserInfo.officeID] = "not-a-uuid"
        #expect(ArrivalNotifications.answer(to: confirm, userInfo: badOffice, delivered: day) == .ignore)

        var badDay = good
        badDay[ArrivalNotifications.UserInfo.day] = "2026-13-40"
        #expect(ArrivalNotifications.answer(to: confirm, userInfo: badDay, delivered: day) == .ignore)

        #expect(ArrivalNotifications.answer(to: confirm, userInfo: [:], delivered: day) == .ignore)
    }

    /// End to end, without a device: the request the scheduler builds, read back
    /// through the rule the handler uses, on the evening it was pinned to.
    @Test("A question built tonight is answerable tonight and no other night")
    func roundTrip() {
        let asking = EveningNudge.Unconfirmed(
            day: day, officeID: officeID, officeName: "Coleman",
            bookingID: bookingID, deskID: "3C-114"
        )
        let info = EveningNudge.request(
            at: DateComponents(hour: 18, minute: 0), title: "t", body: "b",
            answering: asking, in: TimeZone(identifier: "Europe/London")!
        ).content.userInfo

        let confirm = ArrivalNotifications.Action.confirm.rawValue
        #expect(
            ArrivalNotifications.answer(to: confirm, userInfo: info, delivered: day)
                == .record(officeID: officeID, day: day, bookingID: bookingID)
        )
        #expect(
            ArrivalNotifications.answer(
                to: confirm, userInfo: info, delivered: day.adding(days: 1)
            ) == .ignore
        )
    }
}

/// The reminder time is a wall-clock time on the phone's own clock. It was read
/// and written through `Day.calendar`, which is pinned to UTC — and because both
/// ends made the same mistake, the picker redisplayed the time the user chose
/// while the trigger fired an hour early all summer.
@Suite("The reminder time")
@MainActor
struct NudgeTimeTests {

    let london = TimeZone(identifier: "Europe/London")!
    let newYork = TimeZone(identifier: "America/New_York")!

    func picked(_ day: Day, hour: Int, minute: Int = 0, in zone: TimeZone) throws -> Date {
        try #require(Day.localCalendar(zone).date(from: DateComponents(
            year: day.year, month: day.month, day: day.day, hour: hour, minute: minute
        )))
    }

    @Test("Six in the evening in British Summer Time is stored as six, not five")
    func summerTimeIsNotAnHourEarly() throws {
        let chosen = try picked(Day(2026, 8, 7), hour: 18, in: london)
        let stored = NudgeScheduler.components(from: chosen, in: london)

        #expect(stored.hour == 18)
        #expect(stored.minute == 0)
        // The old reading, kept here so the mistake is visible: through the UTC
        // calendar the very same instant is 17:00, and 17 is the number that
        // reached a trigger which fires on the device's clock.
        #expect(Day.calendar.dateComponents([.hour], from: chosen).hour == 17)
    }

    /// Winter is the case that made it invisible: with no offset there is no
    /// error, so the bug was undetectable for half the year in the one zone the
    /// app is written for.
    @Test("The same reading holds when the clocks go back")
    func winterAgrees() throws {
        let chosen = try picked(Day(2026, 1, 7), hour: 18, in: london)
        #expect(NudgeScheduler.components(from: chosen, in: london).hour == 18)
        #expect(Day.calendar.dateComponents([.hour], from: chosen).hour == 18)
    }

    /// Every user outside UTC was affected by their own offset, not by BST.
    @Test("The zone is read from the phone, not assumed")
    func offsetIsTheUsersOwn() throws {
        let chosen = try picked(Day(2026, 8, 7), hour: 18, in: newYork)
        #expect(NudgeScheduler.components(from: chosen, in: newYork).hour == 18)
        // The same instant, read on a London clock, is a different hour — so the
        // zone argument is doing work rather than being ignored.
        #expect(NudgeScheduler.components(from: chosen, in: london).hour == 23)
    }

    @Test("What the picker is handed back is what was stored")
    func roundTripsThroughThePicker() throws {
        for zone in [london, newYork] {
            for hour in [0, 9, 18, 23] {
                let stored = NudgeScheduler.components(
                    from: try picked(Day(2026, 8, 7), hour: hour, minute: 30, in: zone),
                    in: zone
                )
                let shown = NudgeScheduler.pickerDate(
                    for: stored, on: Day(2026, 8, 7), in: zone
                )
                let parts = Day.localCalendar(zone)
                    .dateComponents([.hour, .minute], from: shown)
                #expect(parts.hour == hour, "\(zone.identifier)")
                #expect(parts.minute == 30, "\(zone.identifier)")
            }
        }
    }

    /// An untouched reminder has nothing stored, and 18:00 is what the trigger
    /// uses. The screen used to render that default through UTC and show 19:00 —
    /// so the first thing a BST user did was "correct" a working default into a
    /// broken one.
    @Test("The untouched default shows the hour it will actually fire at")
    func theDefaultShowsItself() {
        let shown = NudgeScheduler.pickerDate(
            for: DateComponents(hour: 18, minute: 0), on: Day(2026, 8, 7), in: london
        )
        #expect(Day.localCalendar(london).component(.hour, from: shown) == 18)
    }
}

/// Two permissions have to hold before an arrival alert reaches anyone, and the
/// offices list used to check one. Granting Always location and declining the
/// notification prompt that came with it left every row reading "Alert on · 50m"
/// in the reassuring green, with nothing anywhere in the app mentioning
/// notifications at all.
@Suite("Whether an alert will actually fire")
struct AlertReadinessTests {

    func readiness(
        alertEnabled: Bool = true, canMonitor: Bool = true,
        notificationsAllowed: Bool = true, isLocated: Bool = true,
        radiusMetres: Double = 50
    ) -> AlertReadiness {
        .of(
            alertEnabled: alertEnabled, canMonitor: canMonitor,
            notificationsAllowed: notificationsAllowed, isLocated: isLocated,
            radiusMetres: radiusMetres
        )
    }

    @Test("Everything granted, an office located, and the radius is the line")
    func ready() {
        #expect(readiness() == .ready(radiusMetres: 50))
        #expect(readiness().willFire)
        #expect(readiness().text == "Alert on · 50m")
    }

    /// The finding itself. Nothing about denying notifications changes location,
    /// an office's coordinates or the toggle, so every other input here is the
    /// happy one — and the row must still refuse to promise.
    @Test("An alert with notifications off does not fire and does not claim to")
    func notificationsDenied() {
        let state = readiness(notificationsAllowed: false)
        #expect(state == .needsNotifications)
        #expect(!state.willFire, "green here is a promise iOS will not keep")
        #expect(state.text == "Alert needs notifications turned on")
    }

    @Test("Each other reason has its own line, and none of them fires")
    func theReasons() {
        #expect(readiness(alertEnabled: false) == .off)
        #expect(readiness(canMonitor: false) == .needsLocation)
        #expect(readiness(isLocated: false) == .notLocated)

        for state in [
            readiness(alertEnabled: false), readiness(canMonitor: false),
            readiness(notificationsAllowed: false), readiness(isLocated: false),
        ] {
            #expect(!state.willFire)
        }
    }

    /// Ordered by what the user should fix first: without location the app is
    /// never woken, so "turn notifications on" would be advice that changes
    /// nothing. A switched-off office says nothing about permissions at all.
    @Test("The reason given is the first one that needs fixing")
    func orderOfReasons() {
        #expect(
            readiness(
                alertEnabled: false, canMonitor: false,
                notificationsAllowed: false, isLocated: false
            ) == .off
        )
        #expect(
            readiness(canMonitor: false, notificationsAllowed: false, isLocated: false)
                == .needsLocation
        )
        #expect(readiness(notificationsAllowed: false, isLocated: false) == .needsNotifications)
    }
}

@Suite("The arrival ledger")
@MainActor
struct ArrivalLedgerTests {

    let container: ModelContainer
    let ledger: ArrivalLedger

    init() throws {
        container = try Store.makeInMemoryContainer(seeded: true)
        ledger = ArrivalLedger(context: container.mainContext)
    }

    /// Counts posts instead of posting. A real notification from a test run
    /// leaves one on the machine, and asking for permission in CI is a hang.
    final class Posted: @unchecked Sendable {
        var requests: [UNNotificationRequest] = []
    }

    func recording() -> Posted {
        let posted = Posted()
        ledger.post = { posted.requests.append($0) }
        return posted
    }

    func withdrawals() -> Withdrawn {
        let withdrawn = Withdrawn()
        ledger.withdraw = { withdrawn.identifiers.append(contentsOf: $0) }
        return withdrawn
    }

    final class Withdrawn: @unchecked Sendable {
        var identifiers: [String] = []
    }

    /// The 12th is booked at Coleman and not attended. The 5th is both, and is
    /// where the acknowledged path is exercised instead.
    let unattended = Day(2026, 8, 12)

    @Test("Arriving on a booked day posts the desk and writes the ledger row")
    func booked() throws {
        let posted = recording()
        let decision = ledger.handleEntry(officeID: SeedData.colemanID, day: unattended)

        guard case .desk(let booking) = decision else {
            Issue.record("expected a desk, got \(decision)")
            return
        }
        #expect(booking.deskID == "3C-121")
        #expect(posted.requests.count == 1)
        #expect(posted.requests.first?.content.title == "3C-121")

        let rows = try container.mainContext.fetch(FetchDescriptor<ArrivalAlert>())
        #expect(rows.count == 1)
        #expect(rows.first?.officeID == SeedData.colemanID)
    }

    /// The evening question is decided while the app is awake and fires hours
    /// later, so it can outlive its own answer: confirm the day from the
    /// arrival alert at nine and the six o'clock notification still asks. No
    /// there must not overwrite a day that was worked — the attendance record
    /// is the only copy there is.
    @Test("No on a stale question cannot unrecord a day that was worked")
    func declineRefusesAnAnsweredDay() throws {
        // The refusal now says so on the lock screen, so this needs the seam
        // even though the notification is not what it is about.
        _ = recording()
        let context = container.mainContext
        let booking = try #require(
            try context.fetch(FetchDescriptor<DeskBooking>())
                .first { $0.day == unattended }
        )
        ledger.confirmAttendance(
            officeID: SeedData.colemanID, day: unattended,
            bookingID: booking.id, today: unattended
        )

        ledger.declineAttendance(bookingID: booking.id)
        #expect(!booking.notAttended, "the day was worked; the question was stale")
        #expect(
            try context.fetch(FetchDescriptor<AttendanceDay>())
                .contains { $0.day == unattended },
            "and the record it was worked is still there"
        )

        // A day nothing has been said about still takes the answer.
        let unanswered = try #require(
            try context.fetch(FetchDescriptor<DeskBooking>())
                .first { $0.day == Day(2026, 8, 11) }
        )
        ledger.declineAttendance(bookingID: unanswered.id)
        #expect(unanswered.notAttended)
    }

    /// A day already recorded has nothing left to ask for, so the perimeter is
    /// crossed and nothing happens. The 5th is seeded as attended at Coleman.
    @Test("An acknowledged day is silent")
    func acknowledgedIsSilent() throws {
        let posted = recording()
        let decision = ledger.handleEntry(officeID: SeedData.colemanID, day: Day(2026, 8, 5))

        #expect(decision == .acknowledged)
        #expect(posted.requests.isEmpty)
        #expect(try container.mainContext.fetchCount(FetchDescriptor<ArrivalAlert>()) == 0)
    }

    /// Walking out and back in is a second arrival, and the desk number is
    /// wanted again. The first notification comes off the lock screen so the
    /// two do not stack.
    @Test("A later arrival alerts again and withdraws the one before it")
    func repeatsAndReplaces() throws {
        let posted = recording()
        let withdrawn = withdrawals()
        let arrived = Date(timeIntervalSince1970: 1_785_000_000)

        ledger.handleEntry(officeID: SeedData.colemanID, day: unattended, now: arrived)
        let second = ledger.handleEntry(
            officeID: SeedData.colemanID, day: unattended,
            now: arrived.addingTimeInterval(ArrivalRule.settleWindow + 1)
        )

        guard case .desk = second else {
            Issue.record("expected a second desk alert, got \(second)")
            return
        }
        #expect(posted.requests.count == 2)
        #expect(
            posted.requests[0].identifier != posted.requests[1].identifier,
            "a shared identifier would edit the first alert instead of raising a second"
        )
        #expect(withdrawn.identifiers == [posted.requests[0].identifier])
        #expect(try container.mainContext.fetchCount(FetchDescriptor<ArrivalAlert>()) == 2)
    }

    @Test("A crossing inside the settle window posts nothing and writes nothing")
    func settlesInsideTheWindow() throws {
        let posted = recording()
        let arrived = Date(timeIntervalSince1970: 1_785_000_000)

        ledger.handleEntry(officeID: SeedData.colemanID, day: unattended, now: arrived)
        let second = ledger.handleEntry(
            officeID: SeedData.colemanID, day: unattended,
            now: arrived.addingTimeInterval(ArrivalRule.settleWindow - 1)
        )

        #expect(second == .settling)
        #expect(posted.requests.count == 1, "not a second notification")
        #expect(try container.mainContext.fetchCount(FetchDescriptor<ArrivalAlert>()) == 1)
    }

    /// Turning up with nothing booked repeats on the same terms — the day still
    /// counts if the user says it does, and until they do the prompt is worth
    /// making again.
    @Test("Arriving with nothing booked also repeats")
    func unbookedRepeats() throws {
        let posted = recording()
        _ = withdrawals()
        let day = Day(2026, 8, 20) // a working day with no seeded booking
        let arrived = Date(timeIntervalSince1970: 1_785_000_000)

        #expect(
            ledger.handleEntry(officeID: SeedData.colemanID, day: day, now: arrived)
                == .nothingBooked
        )
        #expect(
            ledger.handleEntry(
                officeID: SeedData.colemanID, day: day,
                now: arrived.addingTimeInterval(ArrivalRule.settleWindow + 1)
            ) == .nothingBooked
        )
        #expect(posted.requests.count == 2)
        #expect(posted.requests.first?.content.body.contains("No desk booked today.") == true)
    }

    /// The whole rule, end to end: it keeps asking until the button is tapped,
    /// and then it stops.
    @Test("Confirming is what ends the day's alerts")
    func confirmingStopsIt() throws {
        let posted = recording()
        _ = withdrawals()
        let arrived = Date(timeIntervalSince1970: 1_785_000_000)

        ledger.handleEntry(officeID: SeedData.colemanID, day: unattended, now: arrived)
        ledger.confirmAttendance(
            officeID: SeedData.colemanID, day: unattended, bookingID: nil, today: unattended
        )
        let after = ledger.handleEntry(
            officeID: SeedData.colemanID, day: unattended,
            now: arrived.addingTimeInterval(ArrivalRule.settleWindow + 1)
        )

        #expect(after == .acknowledged)
        #expect(posted.requests.count == 1, "the tap is what stopped it, not the window")
    }

    /// The geofence offers; the user confirms. Nothing else writes attendance.
    @Test("An arrival records no attendance until the button is tapped")
    func neverRecordsSilently() throws {
        _ = recording()
        let day = Day(2026, 8, 20)
        let before = try container.mainContext.fetchCount(FetchDescriptor<AttendanceDay>())

        ledger.handleEntry(officeID: SeedData.colemanID, day: day)
        #expect(
            try container.mainContext.fetchCount(FetchDescriptor<AttendanceDay>()) == before,
            "the alert offers; it does not record"
        )

        ledger.confirmAttendance(officeID: SeedData.colemanID, day: day, bookingID: nil, today: day)
        #expect(
            try container.mainContext.fetchCount(FetchDescriptor<AttendanceDay>()) == before + 1
        )

        // And confirming twice does not double-count the day.
        ledger.confirmAttendance(officeID: SeedData.colemanID, day: day, bookingID: nil, today: day)
        #expect(
            try container.mainContext.fetchCount(FetchDescriptor<AttendanceDay>()) == before + 1
        )
    }

    @Test("An office with its alert off is not woken for")
    func disabledOffice() throws {
        let posted = recording()
        let office = try #require(
            try container.mainContext.fetch(FetchDescriptor<Office>())
                .first { $0.id == SeedData.colemanID }
        )
        office.alertEnabled = false
        try container.mainContext.save()

        #expect(ledger.handleEntry(officeID: office.id, day: Day(2026, 8, 5)) == .disabled)
        #expect(posted.requests.isEmpty)
        #expect(try container.mainContext.fetchCount(FetchDescriptor<ArrivalAlert>()) == 0)
    }
}

/// The lock screen has no alert to raise and no form to hold open, and the
/// notification carrying the button is taken away by iOS the instant it is
/// pressed. So every one of these is about the same question: when the write
/// did not land, how does the user ever find out?
///
/// Before this suite the answer was that they did not. `try?` on a store call
/// that answers a refusal with nil rather than a throw collapsed a disk error, a
/// refusal and a success into one silent `Void` — the day was not recorded,
/// nothing was said, and the notification that offered the button was gone.
@Suite("What a tapped button does when the write does not land")
@MainActor
struct ArrivalLedgerFailureTests {

    let container: ModelContainer
    let ledger: ArrivalLedger
    let posted: Posted

    init() throws {
        container = try Store.makeInMemoryContainer(seeded: true)
        ledger = ArrivalLedger(context: container.mainContext)
        posted = Posted()
        ledger.post = { [posted] in posted.requests.append($0) }
        ledger.withdraw = { _ in }
    }

    final class Posted: @unchecked Sendable {
        var requests: [UNNotificationRequest] = []
    }

    /// What a full disk feels like from here. `LocalizedError` so the sentence
    /// the user is shown can be asserted on rather than guessed at.
    struct DiskFull: Error, LocalizedError {
        var errorDescription: String? { "the disk is full" }
    }

    /// Records the context it was handed and then refuses to write.
    ///
    /// It records rather than merely counting because the thing worth pinning is
    /// *which* context the ledger writes: a seam that quietly saved a second,
    /// empty context would look identical from out here, and would be exactly
    /// the kind of double that proves nothing.
    final class Saves: @unchecked Sendable {
        var contexts: [ObjectIdentifier] = []
        var failing = true

        func callAsFunction(_ context: ModelContext) throws {
            contexts.append(ObjectIdentifier(context))
            if failing { throw DiskFull() }
            try context.save()
        }
    }

    /// The `I'm here` write, recording what it was asked to write.
    final class Attempts: @unchecked Sendable {
        struct Attempt: Equatable {
            let day: Day
            let officeID: UUID
            let bookingID: UUID?
            let today: Day
        }
        var attempts: [Attempt] = []
        var answer: Result<Bool, DiskFull> = .success(true)

        func callAsFunction(
            _ day: Day, _ officeID: UUID, _ bookingID: UUID?, _ today: Day
        ) throws -> Bool {
            attempts.append(.init(day: day, officeID: officeID, bookingID: bookingID, today: today))
            return try answer.get()
        }
    }

    /// The `No` write, recording the booking it was handed.
    ///
    /// It sets the flag *and then* fails, in that order, because that is the
    /// order `BookingStore.markNotAttended` does it in — the property first, the
    /// save second. A double that only threw would leave nothing behind, and the
    /// half of this failure worth catching is precisely what is left behind: an
    /// answer sitting in the context that the store never took.
    final class Declines: @unchecked Sendable {
        var bookings: [UUID] = []

        func callAsFunction(_ booking: DeskBooking) throws {
            bookings.append(booking.id)
            booking.notAttended = true
            throw DiskFull()
        }
    }

    let coleman = SeedData.colemanID
    let brussels = SeedData.brusselsID
    /// Booked at Coleman, not attended. The 5th is both, and the 4th is attended
    /// at Brussels — which is where "already a whole day elsewhere" comes from.
    let unattended = Day(2026, 8, 12)
    /// A working day with nothing seeded against it at all.
    let free = Day(2026, 8, 20)

    func booking(on day: Day) throws -> DeskBooking {
        try #require(
            try container.mainContext.fetch(FetchDescriptor<DeskBooking>())
                .first { $0.day == day }
        )
    }

    func attendance() throws -> [AttendanceDay] {
        try container.mainContext.fetch(FetchDescriptor<AttendanceDay>())
    }

    // MARK: The write that lands

    /// The case a noisy fix would break, and it would be a worse bug than the
    /// one being fixed: a "saved!" notification for every arrival doubles the
    /// alerts to say what the gauge already says, and an app that talks on the
    /// happy path is one whose warnings stop being read.
    @Test("A write that lands says nothing, and records the day the notification named")
    func successIsStillSilent() throws {
        let desk = try booking(on: unattended)

        let outcome = ledger.confirmAttendance(
            officeID: coleman, day: unattended, bookingID: desk.id, today: unattended
        )

        #expect(outcome == .recorded)
        #expect(posted.requests.isEmpty, "a button that worked has nothing to say")

        let written = try #require(try attendance().first { $0.day == unattended })
        #expect(written.officeID == coleman)
        #expect(written.source == .geofence, "the geofence offered it; the user confirmed")
        #expect(written.bookingID == desk.id)
        #expect(written.fraction == 1.0)
    }

    /// An alert can sit unanswered on a lock screen for days, and Monday's
    /// arrival tapped on Wednesday still records Monday. The store call has to be
    /// handed the day the notification named, not the day the tap happened on —
    /// which is only visible by looking at what it was handed.
    @Test("The store is asked for the day the alert named, not for today")
    func forwardsTheNotificationsDay() throws {
        let attempts = Attempts()
        ledger.attend = attempts.callAsFunction
        let desk = try booking(on: unattended)

        let outcome = ledger.confirmAttendance(
            officeID: coleman, day: unattended, bookingID: desk.id, today: free
        )

        #expect(outcome == .recorded)
        #expect(posted.requests.isEmpty)
        #expect(
            attempts.attempts == [
                .init(day: unattended, officeID: coleman, bookingID: desk.id, today: free)
            ]
        )
    }

    // MARK: The refusal

    /// The reachable refusal, and the one that used to be perfectly silent. The
    /// 4th is seeded as a whole day at Brussels; arriving at Coleman on the same
    /// day still alerts, because the acknowledgement is per office — so the
    /// button is there to be pressed and the store will not honour it.
    @Test("A day already counted at another office says so rather than doing nothing")
    func alreadyCountedElsewhere() throws {
        let before = try attendance().count

        let outcome = ledger.confirmAttendance(
            officeID: coleman, day: Day(2026, 8, 4), bookingID: nil, today: Day(2026, 8, 4)
        )

        guard case .alreadyCounted(let why) = outcome else {
            Issue.record("expected the day to be already counted, got \(outcome)")
            return
        }
        #expect(why.contains("4 August"))
        #expect(why.contains("another office"))
        #expect(try attendance().count == before, "and nothing was written")

        let request = try #require(posted.requests.first)
        #expect(posted.requests.count == 1)
        #expect(request.content.title == "Already counted", "reassurance, not an alarm")
        #expect(request.content.body.contains("another office"))
        #expect(
            request.content.categoryIdentifier
                == ArrivalNotifications.Category.followUp.rawValue,
            "nothing left to press"
        )
        #expect(request.identifier.hasPrefix("arrival.answered."))
    }

    /// Coming back from lunch and pressing it again. Nothing is wrong, nothing
    /// is missing, and saying so is friendlier than the silence that invites a
    /// third press.
    @Test("Pressing the button twice for the same day says the day counts once")
    func alreadyCountedHere() throws {
        let outcome = ledger.confirmAttendance(
            officeID: coleman, day: Day(2026, 8, 5), bookingID: nil, today: Day(2026, 8, 5)
        )

        guard case .alreadyCounted(let why) = outcome else {
            Issue.record("expected the day to be already counted, got \(outcome)")
            return
        }
        #expect(why.contains("5 August"))
        #expect(why.contains("counts once"))
        #expect(posted.requests.first?.content.title == "Already counted")
    }

    /// Half a day at another office and a whole day asked for here. The store
    /// refuses outright rather than trimming it to fit — how much of the day was
    /// spent where is the user's fact, not the store's — so this one genuinely
    /// needs the app, and a button would only be refused again.
    @Test("A half day elsewhere is refused with no button to press again")
    func refusedWithNothingToRetry() throws {
        container.mainContext.insert(AttendanceDay(
            day: free, officeID: brussels, source: .manual, fraction: 0.5
        ))
        try container.mainContext.save()

        let outcome = ledger.confirmAttendance(
            officeID: coleman, day: free, bookingID: nil, today: free
        )

        guard case .refused(let why) = outcome else {
            Issue.record("expected a refusal, got \(outcome)")
            return
        }
        #expect(why.contains("part of the day"))
        #expect(try attendance().filter { $0.day == free }.count == 1, "still just the half")

        let request = try #require(posted.requests.first)
        #expect(request.content.title == "Not recorded")
        #expect(
            request.content.categoryIdentifier
                == ArrivalNotifications.Category.followUp.rawValue,
            "the same tap would be refused the same way, so no button is offered"
        )
        #expect(request.content.body.contains("Open Office Daze"))
    }

    // MARK: The throw

    @Test("A write that throws says so, and offers the button again for today")
    func throwOffersARetry() throws {
        let attempts = Attempts()
        attempts.answer = .failure(DiskFull())
        ledger.attend = attempts.callAsFunction
        let desk = try booking(on: unattended)

        let outcome = ledger.confirmAttendance(
            officeID: coleman, day: unattended, bookingID: desk.id, today: unattended
        )

        guard case .failed(let why) = outcome else {
            Issue.record("expected a failure, got \(outcome)")
            return
        }
        #expect(why.contains("the disk is full"))
        #expect(
            attempts.attempts == [
                .init(day: unattended, officeID: coleman, bookingID: desk.id, today: unattended)
            ]
        )

        let request = try #require(posted.requests.first)
        #expect(request.content.title == "Not recorded")
        #expect(request.content.body.contains("the disk is full"))
        #expect(request.content.body.contains("Tap I'm here to try again."))
        #expect(
            request.content.categoryIdentifier
                != ArrivalNotifications.Category.followUp.rawValue,
            "the button has to come back, and a category with no actions cannot bring it"
        )
        #expect(request.identifier.hasPrefix("arrival.answered."))
        // The payload the retry will be answered from has to name the same day,
        // or the second press is refused as a redelivery.
        #expect(
            request.content.userInfo[ArrivalNotifications.UserInfo.day] as? String
                == unattended.description
        )
    }

    /// The rule that decides it: `answer` refuses any payload whose day is not
    /// the day it was delivered on, so a button offered here for a day gone by
    /// would be a button that silently did nothing — which is the defect this
    /// notification exists to report.
    @Test("A throw on a day already gone points at the app instead of at a dead button")
    func throwOnAnOldDayOffersNoRetry() throws {
        let attempts = Attempts()
        attempts.answer = .failure(DiskFull())
        ledger.attend = attempts.callAsFunction

        let outcome = ledger.confirmAttendance(
            officeID: coleman, day: unattended, bookingID: nil, today: free
        )

        guard case .failed = outcome else {
            Issue.record("expected a failure, got \(outcome)")
            return
        }
        let request = try #require(posted.requests.first)
        #expect(request.content.title == "Not recorded")
        #expect(
            request.content.categoryIdentifier
                == ArrivalNotifications.Category.followUp.rawValue
        )
        #expect(request.content.body.contains("Open Office Daze to record the day."))
        #expect(!request.content.body.contains("Tap I'm here"))

        // What makes the absent button the right call: the answer rule would
        // have thrown the press away.
        #expect(
            ArrivalNotifications.answer(
                to: ArrivalNotifications.Action.confirm.rawValue,
                userInfo: request.content.userInfo, delivered: free
            ) == .ignore
        )
    }

    // MARK: The evening question's No

    /// The refusal is right and always was — a stale question must not unrecord
    /// a day that was worked — but from the lock screen it looked exactly like
    /// the button not working: press No, nothing happens, press it again.
    @Test("No on a day already recorded says the day is counted rather than doing nothing")
    func declineOnARecordedDaySaysSo() throws {
        let desk = try booking(on: unattended)
        ledger.confirmAttendance(
            officeID: coleman, day: unattended, bookingID: desk.id, today: unattended
        )
        #expect(posted.requests.isEmpty, "the confirm landed, so it said nothing")

        let outcome = ledger.declineAttendance(bookingID: desk.id)

        guard case .alreadyRecorded(let why) = outcome else {
            Issue.record("expected the day to be already recorded, got \(outcome)")
            return
        }
        #expect(why.contains("12 August"))
        #expect(!desk.notAttended, "the day was worked; the question was stale")

        let request = try #require(posted.requests.first)
        #expect(posted.requests.count == 1)
        #expect(request.content.title == "Already counted")
        #expect(request.content.body.contains("12 August"))
    }

    /// Two failures in one. The answer did not save — which the user is told —
    /// and the flag the store set on its way to saving is still sitting in this
    /// context, where the next successful save anywhere in the app would commit
    /// it. A day that reports itself unanswered and then quietly answers itself
    /// later is worse than either failure alone.
    @Test("An answer that will not save is put back, and says it did not save")
    func declineThatThrowsIsUndoneAndAnnounced() throws {
        let declines = Declines()
        ledger.decline = declines.callAsFunction
        let desk = try booking(on: Day(2026, 8, 11))

        let outcome = ledger.declineAttendance(bookingID: desk.id)

        guard case .failed(let why) = outcome else {
            Issue.record("expected a failure, got \(outcome)")
            return
        }
        #expect(why.contains("the disk is full"))
        #expect(declines.bookings == [desk.id], "and it was asked about that booking")
        #expect(
            !desk.notAttended,
            "the store never took the answer, so this context must not be holding it"
        )
        try container.mainContext.save()
        #expect(
            !desk.notAttended,
            "and a later save must not commit the answer that failed"
        )

        let request = try #require(posted.requests.first)
        #expect(request.content.title == "Not saved", "not 'Not recorded' — that reads as the opposite")
        #expect(request.content.body.contains("the disk is full"))
        #expect(request.content.body.contains("still unanswered"))
        #expect(
            request.content.categoryIdentifier
                == ArrivalNotifications.Category.followUp.rawValue
        )
    }

    /// The one silent branch, and deliberately so: a booking deleted between the
    /// question being scheduled and the answer being given leaves nothing to
    /// write and nothing to correct. An alarm about nothing is still an alarm.
    @Test("No about a booking that no longer exists says nothing")
    func declineWithNothingToDecline() {
        #expect(ledger.declineAttendance(bookingID: UUID()) == .noSuchBooking)
        #expect(posted.requests.isEmpty)
    }

    // MARK: The ledger row

    /// The one failure here with no one to tell: the alert has already gone out,
    /// and what did not save is bookkeeping the user can neither see nor act on.
    /// So it is handled rather than announced — starting with not leaving the
    /// row behind, because a context still holding an insert that failed commits
    /// it on the next unrelated save.
    @Test("A ledger row that will not save is dropped rather than left to commit itself")
    func failedLedgerRowIsNotLeftPending() throws {
        let saves = Saves()
        ledger.save = saves.callAsFunction

        let decision = ledger.handleEntry(officeID: coleman, day: unattended)

        guard case .desk = decision else {
            Issue.record("expected a desk alert, got \(decision)")
            return
        }
        #expect(posted.requests.count == 1, "the user still got what they came for")
        #expect(
            saves.contexts == [ObjectIdentifier(container.mainContext)],
            "and it was the app's own context that was asked to write"
        )

        saves.failing = false
        try container.mainContext.save()
        #expect(
            try container.mainContext.fetchCount(FetchDescriptor<ArrivalAlert>()) == 0,
            "a row reported lost must not turn up later"
        )
    }

    /// The cost of losing the row, and the reason it is worth catching at all: a
    /// boundary flutter seconds later reads an empty ledger, finds no settle
    /// window and alerts again. A burst of identical alerts is how a
    /// notification gets switched off for good — a permanent price for a
    /// transient failure.
    @Test("An alert that could not be written down still holds the settle window")
    func settleWindowSurvivesAFailedSave() {
        let saves = Saves()
        ledger.save = saves.callAsFunction
        let arrived = Date(timeIntervalSince1970: 1_785_000_000)

        ledger.handleEntry(officeID: coleman, day: unattended, now: arrived)
        let second = ledger.handleEntry(
            officeID: coleman, day: unattended,
            now: arrived.addingTimeInterval(ArrivalRule.settleWindow - 1)
        )

        #expect(second == .settling)
        #expect(posted.requests.count == 1, "not a second alert seconds after the first")

        // And it is still only a window: past it, the arrival is a real one.
        let later = ledger.handleEntry(
            officeID: coleman, day: unattended,
            now: arrived.addingTimeInterval(ArrivalRule.settleWindow + 1)
        )
        guard case .desk = later else {
            Issue.record("expected a second desk alert, got \(later)")
            return
        }
        #expect(posted.requests.count == 2)
    }
}
