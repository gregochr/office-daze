import CoreLocation
import Foundation
import MapKit
import Testing
@testable import Travel8tor

@Suite("Calendar handoff")
@MainActor
struct CalendarWriterTests {

    let london = TimeZone(identifier: "Europe/London")!

    func entry(floor: String? = "L3", zone: String? = "C") -> CalendarWriter.Entry {
        let day = Day(2026, 9, 11)
        return CalendarWriter.Entry(
            deskID: "3c-118",
            placeName: "Ropemaker Place",
            address: "25 Ropemaker St",
            postcode: "EC2Y 9LY",
            floor: floor,
            zone: zone,
            startsAt: day.at(9, 0, in: london),
            endsAt: day.at(17, 0, in: london),
            timeZone: london
        )
    }

    @Test("The title is natural case, because it leaves the app")
    func titleCase() {
        // Every label inside Travel8tor is upper case. A calendar entry is read
        // beside meetings other people wrote, where shouting is noise.
        #expect(CalendarWriter.title(entry()) == "Desk 3C-118 · Ropemaker Place")
    }

    @Test("The location carries the building and the postcode")
    func location() {
        #expect(
            CalendarWriter.location(entry()) == "Ropemaker Place, 25 Ropemaker St, EC2Y 9LY"
        )
    }

    @Test("An unread field is left out of the note rather than left blank")
    func notesOmitUnread() throws {
        let full = try #require(CalendarWriter.notes(entry()))
        #expect(full.contains("Floor: Level 3"))
        #expect(full.contains("Zone: C"))

        let partial = try #require(CalendarWriter.notes(entry(floor: nil, zone: nil)))
        #expect(!partial.contains("Floor"))
        #expect(!partial.contains("Zone"))
        #expect(partial.contains("Travel8tor"))
    }

    @Test("A booking already written is not written twice")
    func writesOnce() async {
        // Write-only access cannot read events back, so the recorded identifier
        // is the only defence against a second tap adding a second event.
        let (outcome, id) = await CalendarWriter.add(
            entry(), existingEventID: "EXISTING-ID"
        )
        #expect(outcome == .alreadyAdded)
        #expect(id == "EXISTING-ID")
        #expect(!outcome.isProblem)
    }

    @Test("Every outcome says what happened; only the failures read as problems")
    func outcomes() {
        #expect(!CalendarWriter.Outcome.added.isProblem)
        #expect(CalendarWriter.Outcome.denied.isProblem)
        #expect(CalendarWriter.Outcome.noCalendar.isProblem)
        #expect(CalendarWriter.Outcome.failed("disk full").isProblem)
        #expect(CalendarWriter.Outcome.failed("disk full").message.contains("DISK FULL"))
        // The strip renders these directly, so they are upper case like the
        // rest of the interface.
        for outcome: CalendarWriter.Outcome in [.added, .alreadyAdded, .denied, .noCalendar] {
            #expect(outcome.message == outcome.message.uppercased())
        }
    }
}

@Suite("Directions handoff")
@MainActor
struct DirectionsTests {

    @Test("An ungeocoded building opens nothing rather than the Atlantic")
    func refusesNullIsland() {
        var opened: [MKMapItem] = []
        let outcome = Directions.open(
            name: "Nowhere", latitude: 0, longitude: 0, opener: { opened.append($0) }
        )
        #expect(outcome == .noCoordinates)
        #expect(opened.isEmpty, "0,0 is the Atlantic, not a missing value to pass on")
        #expect(outcome.message != nil)
    }

    @Test("A geocoded building hands Maps the name and the point")
    func opensWithName() {
        var opened: [MKMapItem] = []
        let outcome = Directions.open(
            name: "Ropemaker Place", latitude: 51.5203, longitude: -0.0879,
            opener: { opened.append($0) }
        )
        #expect(outcome == .opened)
        #expect(outcome.message == nil, "success is silent; the screen shows nothing")
        #expect(opened.count == 1)
        #expect(opened.first?.name == "Ropemaker Place")
    }
}
