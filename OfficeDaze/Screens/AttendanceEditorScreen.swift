import SwiftData
import SwiftUI

/// Recording a day on prem that had no desk behind it — a workshop, a meeting,
/// a visit to another site.
///
/// Not a booking with the desk left blank. `AttendanceDay` exists apart from
/// `DeskBooking` precisely because the two come apart in both directions, and a
/// booking with no desk would be a reservation for nothing — it would show up
/// on the arrival alert as a blank where the desk number goes, which is the one
/// thing that alert is for.
struct AttendanceEditorScreen: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Office.name) private var offices: [Office]
    @Query private var attendance: [AttendanceDay]

    @State private var officeID: UUID?
    @State private var date = Day.today.startOfDayUTC
    @State private var loaded = false

    private var day: Day { Day(of: date) }

    /// The day is already recorded at this office. Saving again would be a
    /// no-op — `recordAttendance` refuses to double-count — so the button says
    /// so rather than appearing to work.
    private var alreadyRecorded: Bool {
        guard let officeID else { return false }
        return attendance.contains { $0.day == day && $0.officeID == officeID }
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
            } footer: {
                if alreadyRecorded {
                    Text("That day is already recorded at this office.")
                } else {
                    Text("Counts toward the month exactly as a booked day does — the target counts days on prem, not desks reserved.")
                }
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

    private func save() {
        guard let officeID else { return }
        try? BookingStore.recordAttendance(
            day: day, officeID: officeID, source: .manual, in: context
        )
        dismiss()
    }
}

#Preview {
    NavigationStack { AttendanceEditorScreen() }
        .modelContainer(try! Store.makeInMemoryContainer(seeded: true))
}
