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
        let bookings = try await VisionExtractor.extract(image: Self.png(of: Self.list()))

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
    @Test("The reading's lines run top to bottom")
    func linesAreTopToBottom() async throws {
        let reading = try await DocumentReader.read(Self.png(of: Self.list())).reading
        let lines = reading.lines
        let first = try #require(lines.firstIndex { $0.contains("CO03C108") })
        let date = try #require(lines.firstIndex { $0.hasPrefix("2026-10-05") })
        let second = try #require(lines.firstIndex { $0.contains("CO03C102") })
        let last = try #require(lines.firstIndex { $0.contains("CO03D218") })
        #expect(first < date, "\(lines)")
        #expect(date < second, "\(lines)")
        #expect(second < last, "\(lines)")
    }

    @Test("A blank page is reported as no text, not as no booking")
    func blankPageIsNoText() async {
        await #expect(throws: CaptureError.modelReturnedNothingUsable("no text was found in the image")) {
            try await VisionExtractor.extract(image: CaptureSamples.pixel)
        }
    }

    @Test("A page with text but no booking says so")
    func proseIsNoBooking() async throws {
        let page = Self.page { draw in
            draw("Funds   ESA   Systems   Team   Office   APIs", 40, 40)
            draw("Nothing about a desk here.", 40, 120)
        }
        await #expect(throws: CaptureError.modelReturnedNothingUsable("no complete booking in the document")) {
            try await VisionExtractor.extract(image: try Self.png(of: page))
        }
    }

    @Test("Bytes that are not an image fail at the door")
    func unreadableBytes() async {
        await #expect(throws: CaptureError.unreadableImage) {
            try await VisionExtractor.extract(image: Data("nope".utf8))
        }
    }

    // MARK: The switch

    /// The debug switch that puts this reader in the coordinator's seat. Off,
    /// the coordinator asks for a key; on, it reads on the phone and needs
    /// none — which is the whole comparison the office day is for.
    @Test("With the switch on, the coordinator reads on the device and needs no key")
    @MainActor
    func theSwitchReplacesTheModelCall() async throws {
        let was = VisionExtractor.isPreferred
        VisionExtractor.isPreferred = true
        defer { VisionExtractor.isPreferred = was }

        let container = try Store.makeInMemoryContainer(seeded: true)
        let coordinator = CaptureCoordinator(context: container.mainContext)
        coordinator.parsingFloor = .zero

        await coordinator.receive(photo: try Self.png(of: Self.list()))

        #expect(coordinator.current?.deskID == "CO03C102")
        #expect(coordinator.position?.total == 2)
        let capture = try #require(try container.mainContext.fetch(FetchDescriptor<Capture>()).first)
        #expect(capture.status == .parsed)
        #expect(capture.inputTokens == 0 && capture.outputTokens == 0, "nothing was billed")
    }

    @Test("The switch is off unless someone turned it on")
    func offByDefault() {
        #expect(!VisionExtractor.isPreferred)
    }

    @Test("Passthrough keeps the bytes and still refuses what is not an image")
    func passthrough() throws {
        let image = try Self.png(of: Self.list())
        let passed = try PhotoImport.passthrough(image)
        #expect(passed.data == image)
        #expect(passed.mediaType == "image/png")
        #expect(throws: CaptureError.unreadableImage) { try PhotoImport.passthrough(Data("nope".utf8)) }
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
