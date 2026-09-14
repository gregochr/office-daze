import Foundation
import SwiftData
import Testing
import UIKit
@testable import OfficeDaze

/// The on-device reader end to end: a page drawn here, Vision run on it for
/// real, and the bookings that come out.
///
/// The page is drawn to match the booking system's list — a column of cards,
/// no ruled lines — because that is the layout whose grouping Vision is least
/// predictable on. Whether it comes back as a table or as paragraphs, the
/// bookings must be the same, and that is what this pins.
@Suite("The on-device reader")
struct VisionExtractorTests {

    @Test("A drawn list gives its bookings, and a row cut off at the top gives none")
    func readsADrawnList() async throws {
        let bookings = try await VisionExtractor.extract(image: Self.png(of: Self.list()), today: Day(2026, 9, 14))

        #expect(bookings.map(\.day) == [Day(2026, 10, 5), Day(2026, 10, 6)])
        #expect(bookings.map(\.deskID) == ["CO03C102", "CO03D218"])
        #expect(bookings.map(\.zone) == ["C", "D"])
        #expect(bookings.allSatisfy { $0.floor == "03" })
        #expect(bookings.allSatisfy { $0.startTime == "08:00" && $0.endTime == "17:00" })
        #expect(bookings.allSatisfy { $0.officeName == "Coleman, London" })
    }

    /// The page reads top to bottom, or every date would pair with the wrong
    /// row. Asserted here, off a real reading, because it depends on which
    /// way up Vision's coordinate space is.
    ///
    /// Lines are found through `DeskID`, not by their raw text: on the CI
    /// runner Vision read the cut-off row's id with one character wrong, which
    /// the parser undoes and a `contains` does not. The test is about order,
    /// and the fold is exactly what makes order the only thing left to check.
    @Test("The reading's lines run top to bottom")
    func linesAreTopToBottom() async throws {
        let reading = try await DocumentReader.read(Self.png(of: Self.list())).reading
        let lines = reading.lines
        func line(with desk: String) throws -> Int {
            try #require(lines.firstIndex { DeskID.find(in: $0)?.text == desk }, "\(lines)")
        }
        let first = try line(with: "CO03C108")
        let date = try #require(lines.firstIndex { $0.hasPrefix("2026-10-05") }, "\(lines)")
        let second = try line(with: "CO03C102")
        let last = try line(with: "CO03D218")
        #expect(first < date, "\(lines)")
        #expect(date < second, "\(lines)")
        #expect(second < last, "\(lines)")
    }

    @Test("A blank page is reported as no text, not as no booking")
    func blankPageIsNoText() async {
        await #expect(throws: CaptureError.nothingUsable("no text was found in the image")) {
            try await VisionExtractor.extract(image: CaptureSamples.pixel, today: Day(2026, 9, 14))
        }
    }

    @Test("A page with text but no booking says so")
    func proseIsNoBooking() async throws {
        let page = Self.page { draw in
            draw("Funds   ESA   Systems   Team   Office   APIs", 40, 40)
            draw("Nothing about a desk here.", 40, 120)
        }
        await #expect(throws: CaptureError.nothingUsable("no complete booking in the document")) {
            try await VisionExtractor.extract(image: try Self.png(of: page), today: Day(2026, 9, 14))
        }
    }

    /// The drawn list is for 5 and 6 October. Seen from the 6th, the 5th has
    /// gone; seen from the 7th, both have, and the page says so.
    @Test("Bookings for days that have gone are left out, and a page of them says so")
    func pastBookingsAreLeftOut() async throws {
        let image = try Self.png(of: Self.list())
        let fromTheSixth = try await VisionExtractor.extract(image: image, today: Day(2026, 10, 6))
        #expect(fromTheSixth.map(\.day) == [Day(2026, 10, 6)], "today is not the past")

        await #expect(throws: CaptureError.nothingUsable(
            "all 2 bookings in the document have already passed"
        )) {
            try await VisionExtractor.extract(image: image, today: Day(2026, 10, 7))
        }
    }

    @Test("The reason nothing came back is the first one that applies")
    func reasons() {
        #expect(VisionExtractor.nothingUsable(readNothing: true, pastBookings: 3) == "no text was found in the image")
        #expect(VisionExtractor.nothingUsable(readNothing: false, pastBookings: 0) == "no complete booking in the document")
        #expect(VisionExtractor.nothingUsable(readNothing: false, pastBookings: 1)
                == "the only booking in the document has already passed")
        #expect(VisionExtractor.nothingUsable(readNothing: false, pastBookings: 2)
                == "all 2 bookings in the document have already passed")
    }

    @Test("Bytes that are not an image fail at the door")
    func unreadableBytes() async {
        await #expect(throws: CaptureError.unreadableImage) {
            try await VisionExtractor.extract(image: Data("nope".utf8), today: Day(2026, 9, 14))
        }
    }

    // MARK: In the coordinator's seat

    /// The real extractor is the coordinator's default, so a capture that
    /// arrives with nothing stubbed is read on the device, recorded, and put
    /// up for review.
    @Test("The coordinator reads on the device by default and records the capture")
    @MainActor
    func theCoordinatorReadsOnTheDevice() async throws {
        let container = try Store.makeInMemoryContainer(seeded: true)
        let coordinator = CaptureCoordinator(context: container.mainContext)
        coordinator.parsingFloor = .zero

        await coordinator.receive(photo: try Self.png(of: Self.list()))

        #expect(coordinator.current?.deskID == "CO03C102")
        #expect(coordinator.position?.total == 2)
        let capture = try #require(try container.mainContext.fetch(FetchDescriptor<Capture>()).first)
        #expect(capture.status == .parsed)
    }

    @Test("The check at the door keeps the bytes and refuses what is not an image")
    func prepareIsACheck() throws {
        let image = try Self.png(of: Self.list())
        #expect(try PhotoImport.prepare(image) == image, "every pixel goes through")
        #expect(throws: CaptureError.unreadableImage) { try PhotoImport.prepare(Data("nope".utf8)) }
    }

    // MARK: Drawing the page

    /// The list as the booking system draws it: a date card, then a booking
    /// card, no rules. The first booking card is drawn with its date above
    /// the top edge, which is what the top of a photograph looks like.
    static func list() -> UIImage {
        page { draw in
            // The cut-off row: no date card above it.
            row(draw, y: 20, desk: "CO03C108")
            card(draw, y: 130, date: "2026-10-05")
            row(draw, y: 220, desk: "CO03C102")
            card(draw, y: 330, date: "2026-10-06")
            row(draw, y: 420, desk: "CO03D218")
        }
    }

    typealias Draw = (String, CGFloat, CGFloat) -> Void

    static func card(_ draw: Draw, y: CGFloat, date: String) {
        draw(date, 40, y)
        draw("Times shown based on building location", 40, y + 40)
    }

    static func row(_ draw: Draw, y: CGFloat, desk: String) {
        draw("Reservation f...", 40, y)
        draw(desk, 300, y)
        draw("03, Coleman, London", 300, y + 34)
        draw("08:00 - 17:00", 560, y)
        draw("Europe/London", 560, y + 34)
        draw("Christopher Gregory", 760, y)
        draw("Confirmed", 980, y)
    }

    static func page(_ body: (Draw) -> Void) -> UIImage {
        let size = CGSize(width: 1200, height: 560)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let font = UIFont.systemFont(ofSize: 24, weight: .medium)
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.black]
            body { text, x, y in
                (text as NSString).draw(at: CGPoint(x: x, y: y), withAttributes: attributes)
            }
        }
    }

    static func png(of image: UIImage) throws -> Data {
        try #require(image.pngData())
    }
}
