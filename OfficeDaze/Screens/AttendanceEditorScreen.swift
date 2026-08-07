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
    @State private var date = Day.today.startOfDayUTC
    /// 1.0 or 0.5. `AttendanceDay.fraction` has held both from the start and
    /// `Quota` has always summed it faithfully, but nothing could enter a half:
    /// you could book half a day off in the holiday calendar and not record
    /// half a day on. A field that can only arrive through a seeded fixture is
    /// a trap for whoever reads the model next.
    @State private var fraction: Double = 1.0
    @State private var loaded = false

    private var day: Day { Day(of: date) }

    /// Counts toward the month now, or only toward the forecast.
    private var isAhead: Bool { day > .today }

    /// Already held, in whichever form suits the date. Saving again would be a
    /// no-op — both store calls refuse a duplicate — so the button says so
    /// rather than appearing to work.
    private var alreadyRecorded: Bool {
        guard let officeID else { return false }
        return isAhead
            ? planned.contains { $0.day == day && $0.officeID == officeID }
            : attendance.contains { $0.day == day && $0.officeID == officeID }
    }

    private var canSave: Bool { officeID != nil && !alreadyRecorded }

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
                        Text("Full day").tag(1.0)
                        Text("Half day").tag(0.5)
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
        .task {
            guard !loaded else { return }
            loaded = true
            // One office is not a choice worth making.
            if offices.count == 1 { officeID = offices.first?.id }
        }
    }

    /// Says which of the two it will be, because the difference is the whole
    /// point: one moves the gauge, the other only the forecast.
    private var footer: String {
        if alreadyRecorded {
            return isAhead
                ? "That day is already planned for this office."
                : "That day is already recorded at this office."
        }
        if isAhead {
            return "A day still to come counts toward the forecast, the same as a booked desk does — it becomes a day attended when you turn up and say so."
        }
        if fraction < 1 {
            return "Half a day on prem counts as half a day toward the month — the same arithmetic as half a day's leave, in the other direction."
        }
        return "A day you were there counts toward the month exactly as a booked day does, because the target counts days on prem rather than desks reserved."
    }

    private func save() {
        guard let officeID else { return }
        if isAhead {
            try? BookingStore.recordPlanned(day: day, officeID: officeID, in: context)
        } else {
            try? BookingStore.recordAttendance(
                day: day, officeID: officeID, source: .manual,
                fraction: fraction, in: context
            )
        }
        dismiss()
    }
}

#Preview {
    NavigationStack { AttendanceEditorScreen() }
        .modelContainer(try! Store.makeInMemoryContainer(seeded: true))
}
