import Foundation
import SwiftData
import Testing
@testable import Travel8tor

@Suite("Dedupe")
struct DedupeTests {

    let london = TimeZone(identifier: "Europe/London")!

    func rail(
        id: UUID = UUID(),
        operatorName: String = "Eurostar",
        origin: String = "St Pancras",
        ref: String? = "XKR48821",
        coach: String? = "09",
        seat: String? = "51",
        platform: String? = nil,
        at day: Day = Day(2026, 9, 7),
        hour: Int = 17, minute: Int = 4,
        provenance: Provenance = .pass,
        unsure: [String] = []
    ) -> Dedupe.Candidate {
        Dedupe.Candidate(
            id: id,
            detail: .rail(RailDetail(
                operatorName: operatorName,
                originStation: origin, destStation: "Brussels Midi",
                originCity: "London", destCity: "Brussels",
                originCode: nil, destCode: nil,
                platform: platform, coach: coach, seat: seat,
                bookingRef: ref, checkInBy: nil, passSerial: nil
            )),
            startsAt: day.at(hour, minute, in: london),
            startZoneID: "Europe/London",
            endsAt: nil, endZoneID: nil,
            unsureFields: unsure, provenance: provenance
        )
    }

    func stay(
        id: UUID = UUID(), hotel: String = "The Ropewalk",
        checkIn: Date? = nil, ref: String? = nil,
        night: Day = Day(2026, 9, 10),
        provenance: Provenance = .screengrab,
        unsure: [String] = ["checkIn", "bookingRef"]
    ) -> Dedupe.Candidate {
        Dedupe.Candidate(
            id: id,
            detail: .stay(StayDetail(
                hotelName: hotel, address: nil, city: "London",
                checkIn: checkIn, checkOut: night.adding(days: 1).at(11, 0, in: london),
                nights: 1, bookingRef: ref
            )),
            startsAt: checkIn ?? night.at(19, 30, in: london),
            startZoneID: "Europe/London",
            endsAt: nil, endZoneID: nil,
            unsureFields: unsure, provenance: provenance
        )
    }

    // MARK: Matching

    @Test("Rail matches on the booking reference")
    func railByReference() {
        let existing = rail(ref: "XKR48821")
        // Same booking, different capture: the email formats the ref with a
        // space and gets the operator's casing different.
        let incoming = rail(operatorName: "EUROSTAR", ref: "XKR4 8821", provenance: .email)
        #expect(Dedupe.matches(existing, incoming))
    }

    @Test("Different references are different bookings even at the same time")
    func differentReferences() {
        // An outbound and a return can share an operator and a departure clock;
        // the reference is what tells them apart.
        let out = rail(ref: "XKR48821")
        let back = rail(ref: "XKR48822")
        #expect(!Dedupe.matches(out, back))
    }

    @Test("With no reference, rail falls back to operator, instant and origin")
    func railFallback() {
        let existing = rail(ref: nil)
        #expect(Dedupe.matches(existing, rail(origin: "London St Pancras", ref: nil)))
        #expect(!Dedupe.matches(existing, rail(ref: nil, hour: 18)))
        #expect(!Dedupe.matches(existing, rail(operatorName: "LNER", ref: nil)))
    }

    @Test("Stays match on a fuzzy hotel name and the first night")
    func stayFuzzy() {
        let existing = stay(hotel: "The Ropewalk")
        #expect(Dedupe.matches(existing, stay(hotel: "Ropewalk Hotel London")))
        #expect(!Dedupe.matches(existing, stay(hotel: "Hotel Sablon")))
        #expect(!Dedupe.matches(existing, stay(night: Day(2026, 9, 11))))
    }

    @Test("A second desk capture for the same day is a change, not a duplicate")
    func deskIsAChange() {
        func desk(_ id: String, provenance: Provenance = .email) -> Dedupe.Candidate {
            Dedupe.Candidate(
                id: UUID(),
                detail: .desk(DeskDetail(
                    placeID: UUID(), placeName: "Ropemaker Place", city: "London",
                    floor: "L3", zone: "C", deskID: id, hours: nil, countsToQuota: true
                )),
                startsAt: Day(2026, 9, 11).at(9, 0, in: london),
                startZoneID: "Europe/London",
                endsAt: nil, endZoneID: nil, unsureFields: [], provenance: provenance
            )
        }
        // One desk per day per building, so this matches — and the merge below
        // is what applies the change rather than creating a second booking.
        #expect(Dedupe.matches(desk("3C-118"), desk("3C-121")))
    }

    @Test("Different kinds never match")
    func kindsDiffer() {
        #expect(!Dedupe.matches(rail(), stay()))
    }

    // MARK: Merging

    @Test("A pass arriving after a screengrab wins and clears the amber flags")
    func passClearsAmber() {
        // The design's stated case: the screengrab left two fields unread; the
        // pass carries them, so the flags go.
        let screengrab = stay(
            hotel: "The Ropewalk", checkIn: nil, ref: nil,
            provenance: .screengrab, unsure: ["checkIn", "bookingRef"]
        )
        let pass = stay(
            hotel: "The Ropewalk",
            checkIn: Day(2026, 9, 10).at(21, 30, in: london),
            ref: "RW-4471", provenance: .pass, unsure: []
        )

        let merged = Dedupe.merge(winner: screengrab, incoming: pass)
        #expect(merged.provenance == .pass)
        #expect(merged.detail.stayDetail?.checkIn != nil)
        #expect(merged.detail.stayDetail?.bookingRef == "RW-4471")
        #expect(merged.unsureFields.isEmpty, "the flags the screengrab left are cleared")
    }

    @Test("The loser fills the winner's blanks without overwriting anything")
    func loserFillsBlanks() {
        // The pass wins, but it has no platform; the email did.
        let pass = rail(ref: "XKR48821", coach: "09", seat: "51", platform: nil, provenance: .pass, unsure: ["platform"])
        let email = rail(ref: "XKR48821", coach: "14", seat: "22", platform: "5", provenance: .email)

        let merged = Dedupe.merge(winner: pass, incoming: email)
        #expect(merged.provenance == .pass)
        #expect(merged.detail.railDetail?.coach == "09", "the winner's value is kept")
        #expect(merged.detail.railDetail?.seat == "51")
        #expect(merged.detail.railDetail?.platform == "5", "the loser fills a blank")
        #expect(!merged.unsureFields.contains("platform"), "and the flag goes with it")
    }

    @Test("A flag survives when neither capture could read the field")
    func flagSurvivesWhenStillUnread() {
        let a = stay(provenance: .screengrab, unsure: ["checkIn", "bookingRef"])
        let b = stay(provenance: .email, unsure: ["checkIn"])
        let merged = Dedupe.merge(winner: a, incoming: b)
        #expect(merged.unsureFields.contains("checkIn"), "still nobody could read it")
    }

    @Test("Provenance precedence is manual > pass > email > screengrab")
    func precedence() {
        #expect(Provenance.manual > .pass)
        #expect(Provenance.pass > .email)
        #expect(Provenance.email > .screengrab)

        let manual = rail(operatorName: "MANUAL ENTRY", ref: "X", provenance: .manual)
        let pass = rail(operatorName: "Eurostar", ref: "X", provenance: .pass)
        #expect(Dedupe.merge(winner: pass, incoming: manual).provenance == .manual)
        #expect(
            Dedupe.merge(winner: pass, incoming: manual).detail.railDetail?.operatorName
                == "MANUAL ENTRY"
        )
    }

    // MARK: Classification

    @Test("Nothing matching means insert")
    func insert() {
        #expect(Dedupe.classify(rail(), against: []) == .insert)
        #expect(Dedupe.classify(rail(ref: "AAA"), against: [rail(ref: "BBB")]) == .insert)
    }

    @Test("A match merges into the existing booking rather than adding a second")
    func merge() {
        let existingID = UUID()
        let existing = rail(id: existingID, ref: "XKR48821", provenance: .screengrab, unsure: ["seat"])
        let incoming = rail(ref: "XKR48821", seat: "51", provenance: .pass)

        guard case .merge(let into, let result) = Dedupe.classify(incoming, against: [existing]) else {
            Issue.record("expected a merge")
            return
        }
        #expect(into == existingID)
        #expect(result.detail.railDetail?.seat == "51")
        #expect(!result.unsureFields.contains("seat"))
    }
}

@Suite("Capture coordinator")
@MainActor
struct CaptureCoordinatorTests {

    let container: ModelContainer

    init() throws {
        container = try Store.makeInMemoryContainer(seeded: true)
    }

    @Test("Committing a new booking regroups the trips around it")
    func commitRegroups() throws {
        let context = container.mainContext
        let coordinator = CaptureCoordinator(context: context)

        // A second London desk on the Tuesday of the Brussels leg — a day that
        // currently renders as ON SITE ▪ NO BOOKINGS.
        let parsed = ParsedBooking(
            detail: .desk(DeskDetail(
                placeID: SeedData.ropemakerPlaceID, placeName: "Ropemaker Place",
                city: "London", floor: "L3", zone: "C", deskID: "3C-140",
                hours: "09–17", countsToQuota: true
            )),
            startsAt: Day(2026, 9, 8).at(9, 0, in: SeedData.london),
            startZoneID: "Europe/London",
            endsAt: nil, endZoneID: nil,
            unsureFields: [], provenance: .email, confidence: .high
        )

        let id = try coordinator.commit(parsed, captureID: nil)

        let booking = try #require(
            try context.fetch(FetchDescriptor<Booking>()).first { $0.id == id }
        )
        let trips = try context.fetch(FetchDescriptor<Trip>())
        let trip = try #require(trips.first { $0.id == booking.tripID })

        // A London desk inside the Brussels leg's dates belongs to the London
        // week — the same rule the seed exercises, now applied at capture.
        #expect(trip.primaryCity == "London")
        #expect(trip.parentTripID == nil)
        #expect(trips.count == 3, "no trip was created or lost")
    }

    @Test("Committing a duplicate merges rather than adding a second booking")
    func commitMerges() throws {
        let context = container.mainContext
        let coordinator = CaptureCoordinator(context: context)
        let before = try context.fetchCount(FetchDescriptor<Booking>())

        // The Ropewalk again, this time from a pass that carries the check-in.
        let parsed = ParsedBooking(
            detail: .stay(StayDetail(
                hotelName: "The Ropewalk", address: "41 Rivington St", city: "London",
                checkIn: Day(2026, 9, 10).at(21, 30, in: SeedData.london),
                checkOut: Day(2026, 9, 11).at(11, 0, in: SeedData.london),
                nights: 1, bookingRef: "RW-4471"
            )),
            startsAt: Day(2026, 9, 10).at(21, 30, in: SeedData.london),
            startZoneID: "Europe/London",
            endsAt: Day(2026, 9, 11).at(11, 0, in: SeedData.london),
            endZoneID: "Europe/London",
            unsureFields: [], provenance: .pass, confidence: .high
        )

        try coordinator.commit(parsed, captureID: nil)

        #expect(try context.fetchCount(FetchDescriptor<Booking>()) == before, "merged, not added")

        let ropewalk = try #require(
            try context.fetch(FetchDescriptor<Booking>())
                .first { $0.detail?.stayDetail?.hotelName == "The Ropewalk" }
        )
        #expect(ropewalk.provenance == .pass, "the higher provenance wins")
        #expect(ropewalk.detail?.stayDetail?.checkIn != nil)
        #expect(!ropewalk.hasUnreadableFields, "the amber flags are cleared")
    }

    @Test("A model failure surfaces and offers manual entry rather than dropping")
    func failureIsNeverSilent() async throws {
        let coordinator = CaptureCoordinator(context: container.mainContext)
        coordinator.extractor = { _ in throw CaptureError.noAPIKey }

        await coordinator.receive(
            data: Data("not an image".utf8), filename: "shot.png", type: .png
        )

        guard case .failed(let error, let filename) = coordinator.phase else {
            Issue.record("expected a failure phase, got \(coordinator.phase)")
            return
        }
        #expect(error == .noAPIKey)
        #expect(filename == "shot.png")
        #expect(error.offersManualEntry)

        // The attempt is still recorded, so a failed call is visible in the
        // capture log rather than vanishing.
        let captures = try container.mainContext.fetch(FetchDescriptor<Capture>())
        #expect(captures.contains { $0.status == .failed })
    }

    @Test("A pass file takes the free path and never calls the model")
    func passPathIsFree() async throws {
        let coordinator = CaptureCoordinator(context: container.mainContext)
        coordinator.extractor = { _ in
            Issue.record("a pass file must not reach the model")
            throw CaptureError.noAPIKey
        }

        let zip = makeZip(named: "pass.json", contents: Data(eurostarPassJSON.utf8))
        await coordinator.receive(data: zip, filename: "eurostar.pkpass", type: nil)

        guard case .review(let parsed, _, _) = coordinator.phase else {
            Issue.record("expected a review phase, got \(coordinator.phase)")
            return
        }
        #expect(parsed.provenance == .pass)
        #expect(!parsed.costedCall)

        let capture = try #require(
            try container.mainContext.fetch(FetchDescriptor<Capture>())
                .first { $0.inputType == .passFile }
        )
        #expect(capture.model == nil, "no model recorded for a free capture")
        #expect(capture.inputTokens == 0)
    }

    @Test("An unreadable file type is refused by name")
    func unsupportedType() async {
        let coordinator = CaptureCoordinator(context: container.mainContext)
        // Binary that isn't an image, a PDF, a pass, or decodable text.
        await coordinator.receive(
            data: Data([0xFF, 0xD8, 0xFE, 0x00]), filename: "booking.numbers", type: nil
        )
        guard case .failed(let error, _) = coordinator.phase else {
            Issue.record("expected a failure")
            return
        }
        #expect(error == .unsupportedFile("numbers"))
    }
}
