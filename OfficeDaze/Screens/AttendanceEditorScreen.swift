import SwiftData
import SwiftUI

/// A day in the office with no desk reserved — a workshop, a meeting, a visit
/// to another site.
///
/// Not a booking with the desk left blank. `AttendanceDay` and `PlannedDay`
/// exist apart from `DeskBooking` because a booking would have to carry a desk
/// number, and the arrival alert would then show one that was invented — the
/// one thing that alert must never do.
///
/// One screen for both because the user is answering one question. Which record
/// it becomes follows from the date and is not theirs to choose: a day gone by
/// was worked, a day ahead is intended, and no date is both.
struct AttendanceEditorScreen: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Office.name) private var offices: [Office]
    @Query private var attendance: [AttendanceDay]
    @Query private var planned: [PlannedDay]

    @State private var officeID: UUID?
    /// `localNoon` rather than `startOfDayUTC`: the picker below renders this
    /// instant in the device's zone, and midnight UTC on the 5th is the
    /// evening of the 4th anywhere west of Greenwich.
    @State private var date = Day.today.localNoon()
    /// 1.0 or 0.5. `AttendanceDay.fraction` has held both from the start and
    /// `Quota` has always summed it faithfully, but nothing could enter a half:
    /// you could book half a day off in the holiday calendar and not record
    /// half a day on. A field that can only arrive through a seeded fixture is
    /// a trap for whoever reads the model next.
    @State private var fraction: Double = Self.fullDay
    @State private var loaded = false
    /// Set only by a write that did not land, or one the store refused.
    /// Non-nil holds the screen open.
    @State private var failure: String?

    /// The two the picker offers, named so the rule and the tags cannot drift
    /// apart — a tag that stops matching a case silently deselects the segment.
    static let fullDay = 1.0
    static let halfDay = 0.5

    /// `localOf`, matching `localNoon` above: the picker hands back an instant
    /// in the device's zone, so it must be read in the device's zone.
    private var day: Day { Day(localOf: date) }

    /// Counts toward the month now, or only toward the forecast.
    ///
    /// Strictly after today, which puts today on the attendance side — and it
    /// has to be that way round rather than the other, because the boundary is
    /// the day this screen is most often opened on. `BookingStore` draws its
    /// line in the same place (`recordAttendance` takes `day <= today`,
    /// `recordPlanned` takes `day > today`), and the two must agree: a screen
    /// that called today a plan would hand it to a store that refuses the past
    /// its own way, and the save would write nothing at all.
    static func isAhead(_ day: Day, today: Day = .today) -> Bool { day > today }

    private var isAhead: Bool { Self.isAhead(day, today: .today) }

    /// Already held, in whichever form suits the date. Saving again would be a
    /// no-op — both store calls refuse a duplicate — so the button says so
    /// rather than appearing to work.
    ///
    /// It looks in one list or the other, never both: the same date held as a
    /// plan and as a day attended is not a clash, it is the ordinary life of a
    /// day that was forecast and then happened, and treating it as one would
    /// lock the editor out of the correction it exists for.
    static func alreadyRecorded(
        day: Day,
        officeID: UUID?,
        today: Day = .today,
        attendance: [AttendanceDay],
        planned: [PlannedDay]
    ) -> Bool {
        guard let officeID else { return false }
        return isAhead(day, today: today)
            ? planned.contains { $0.day == day && $0.officeID == officeID }
            : attendance.contains { $0.day == day && $0.officeID == officeID }
    }

    private var alreadyRecorded: Bool {
        Self.alreadyRecorded(
            day: day, officeID: officeID, attendance: attendance, planned: planned
        )
    }

    /// An office, and something left to record. There is no desk to type here,
    /// so the office is the whole of the input.
    static func canSave(officeID: UUID?, alreadyRecorded: Bool) -> Bool {
        officeID != nil && !alreadyRecorded
    }

    private var canSave: Bool {
        Self.canSave(officeID: officeID, alreadyRecorded: alreadyRecorded)
    }

    var body: some View {
        Form {
            Section {
                Picker("Office", selection: $officeID) {
                    Text("Choose").tag(UUID?.none)
                    ForEach(offices) { office in
                        Text(office.name).tag(UUID?.some(office.id))
                    }
                }
                DatePicker("Date", selection: $date, displayedComponents: .date)
                // Only for a day already worked. A half-day intended is not a
                // thing anyone knows in advance, and `PlannedDay` has no
                // fraction to put it in — it forecasts a day on prem or it does
                // not.
                if !isAhead {
                    Picker("Time on prem", selection: $fraction) {
                        Text("Full day").tag(Self.fullDay)
                        Text("Half day").tag(Self.halfDay)
                    }
                    .pickerStyle(.segmented)
                }
            } footer: {
                Text(footer)
            }
        }
        .navigationTitle("Day in the office")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }.disabled(!canSave)
            }
        }
        // Stays open behind the alert, so the date and office that were refused
        // are still on screen to be changed.
        .alert(
            "Not recorded",
            isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(failure ?? "")
        }
        .task {
            guard !loaded else { return }
            loaded = true
            // One office is not a choice worth making.
            if offices.count == 1 { officeID = offices.first?.id }
        }
    }

    private var footer: String {
        Self.footer(
            day: day, officeID: officeID, fraction: fraction,
            attendance: attendance, planned: planned
        )
    }

    /// Says which of the two it will be, because the difference is the whole
    /// point: one moves the gauge, the other only the forecast.
    static func footer(
        day: Day,
        officeID: UUID?,
        fraction: Double,
        today: Day = .today,
        attendance: [AttendanceDay],
        planned: [PlannedDay]
    ) -> String {
        let ahead = isAhead(day, today: today)
        if alreadyRecorded(
            day: day, officeID: officeID, today: today,
            attendance: attendance, planned: planned
        ) {
            return ahead
                ? "That day is already planned for this office."
                : "That day is already recorded at this office."
        }
        if ahead {
            return "A day still to come counts toward the forecast, the same as a booked desk does — it becomes a day attended when you turn up and say so."
        }
        if fraction < fullDay {
            return "Half a day on prem counts as half a day toward the month — the same arithmetic as half a day's leave, in the other direction."
        }
        return "A day you were there counts toward the month exactly as a booked day does, because the target counts days on prem rather than desks reserved."
    }

    /// What a save did. `refused` is the case that used to be invisible: both
    /// store calls answer a write they will not make by returning nil rather
    /// than throwing, so `try?` and an unconditional `dismiss()` drew a refusal
    /// exactly as they drew a success.
    enum Written: Equatable {
        case attended(Double)
        case planned
        case refused
        case failed(String)
    }

    /// Writes the day, choosing the record from the date.
    ///
    /// The two store calls arrive as closures for two reasons: the branch this
    /// exists to get right is which of them runs, and a refusal is a branch
    /// SwiftData will not take on request. Both return nil for a write they
    /// decline — a day already planned, or a day whose recorded fractions
    /// already add to one — and nil is not success.
    static func record(
        day: Day,
        officeID: UUID,
        fraction: Double,
        today: Day = .today,
        attend: (Day, UUID, Double) throws -> Bool,
        plan: (Day, UUID) throws -> Bool
    ) -> Written {
        do {
            if isAhead(day, today: today) {
                return try plan(day, officeID) ? .planned : .refused
            }
            return try attend(day, officeID, fraction) ? .attended(fraction) : .refused
        } catch {
            return .failed(
                "That day couldn't be saved: \(error.localizedDescription). Nothing was recorded for \(day.dayAndMonth)."
            )
        }
    }

    /// Why the store refused, said in terms of what is actually on that day.
    ///
    /// The store answers a refusal with nil and no reason, and every reason it
    /// has is visible from here. The one worth naming is the last: a day the
    /// user has already recorded in full somewhere else. Save is enabled for it
    /// — `alreadyRecorded` only looks at this office — so without this the tap
    /// did nothing, said nothing, and left the day looking recordable.
    static func refusal(
        day: Day,
        officeID: UUID?,
        fraction: Double,
        today: Day = .today,
        attendance: [AttendanceDay],
        planned: [PlannedDay]
    ) -> String {
        if isAhead(day, today: today) {
            return "\(day.dayAndMonth) is already planned. Nothing was added."
        }
        if let officeID, attendance.contains(where: { $0.day == day && $0.officeID == officeID }) {
            return "\(day.dayAndMonth) is already recorded at this office. Nothing was added."
        }
        let recorded = attendance.filter { $0.day == day }.reduce(0) { $0 + $1.fraction }
        if recorded > 0 {
            return "\(day.dayAndMonth) already has \(Self.text(recorded)) recorded at another office, and \(Self.text(fraction)) more would take it over a whole day. Remove that day first if it is wrong."
        }
        return "\(day.dayAndMonth) could not be recorded. Nothing was added."
    }

    /// `half a day` / `a whole day`, so the sentence above reads as English
    /// rather than as two decimals.
    private static func text(_ fraction: Double) -> String {
        fraction < fullDay ? "half a day" : "a whole day"
    }

    private func save() {
        guard let officeID else { return }
        let written = Self.record(
            day: day,
            officeID: officeID,
            fraction: fraction,
            attend: { day, office, fraction in
                try BookingStore.recordAttendance(
                    day: day, officeID: office, source: .manual,
                    fraction: fraction, in: context
                ) != nil
            },
            plan: { day, office in
                try BookingStore.recordPlanned(day: day, officeID: office, in: context) != nil
            }
        )
        switch written {
        case .attended, .planned:
            dismiss()
        case .refused:
            failure = Self.refusal(
                day: day, officeID: officeID, fraction: fraction,
                attendance: attendance, planned: planned
            )
        case .failed(let why):
            failure = why
        }
    }
}

#Preview {
    NavigationStack { AttendanceEditorScreen() }
        .modelContainer(try! Store.makeInMemoryContainer(seeded: true))
}
