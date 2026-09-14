import Foundation
import ImageIO
import SwiftData
import Testing
import UIKit
import UniformTypeIdentifiers
@testable import OfficeDaze

/// The OCR spike's recorder, from the bytes entering the coordinator to the
/// four files on disk.
///
/// One of these runs Vision's document reader for real, on an image drawn
/// here. That is deliberate: the office day depends on
/// `RecognizeDocumentsRequest` working on this OS, and whether it works on
/// the CI simulator was a question worth answering before anyone stood in
/// front of a monitor with a phone. (It does.)
@Suite("The OCR spike recorder")
struct SpikeDumpTests {

    /// A fresh directory per test, nowhere near `Documents/Spike`.
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "SpikeDumpTests-\(UUID().uuidString)", directoryHint: .isDirectory)

    // MARK: Names and formats

    @Test("The folder is named for the moment, sortable, with no colons")
    func folderNameIsSortableAndLegal() {
        let moment = Date(timeIntervalSince1970: 1_790_000_000)
        let name = SpikeDump.folderName(for: moment)
        #expect(name == "2026-09-21T141320Z")
        #expect(!name.contains(":"))
        #expect(name < SpikeDump.folderName(for: moment + 1), "a later moment sorts later")
    }

    @Test("The image keeps the extension its bytes deserve")
    func extensionComesFromTheBytes() {
        #expect(SpikeDump.fileExtension(of: CaptureSamples.pixel) == "png")
        #expect(SpikeDump.fileExtension(of: Data("not an image".utf8)) == "img")
    }

    @Test("The EXIF orientation is read out of the header, and defaults to upright")
    func orientationIsReadFromTheHeader() throws {
        let source = try #require(CGImageSourceCreateWithData(CaptureSamples.pixel as CFData, nil))
        #expect(DocumentReader.orientation(of: source) == .up, "a screenshot carries none")

        let rotated = try Self.jpeg(of: Self.document(), orientation: .right)
        let rotatedSource = try #require(CGImageSourceCreateWithData(rotated as CFData, nil))
        #expect(DocumentReader.orientation(of: rotatedSource) == .right)
    }

    // MARK: On disk

    /// The one that runs Vision. If this fails on CI and passes on a Mac, the
    /// end-to-end fixture tests will have to be device-only, and that is worth
    /// knowing now.
    @Test("Recording writes the image, Vision's result, and the reading twice")
    func recordingWritesFourFiles() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = try Self.png(of: Self.document())

        let folder = try await SpikeDump.record(
            image, into: directory, at: Date(timeIntervalSince1970: 1_790_000_000)
        )

        #expect(folder.lastPathComponent == "2026-09-21T141320Z")
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        #expect(files == ["image.png", "observation.json", "reading.json", "reading.txt"])
        #expect(try Data(contentsOf: folder.appending(path: "image.png")) == image,
                "the bytes as they arrived, untouched")

        let reading = try JSONDecoder().decode(
            DocumentReading.self, from: Data(contentsOf: folder.appending(path: "reading.json"))
        )
        let text = try String(contentsOf: folder.appending(path: "reading.txt"), encoding: .utf8)
        #expect(text == reading.rendered, "the text is the JSON, rendered")
        #expect(!reading.isEmpty, "Vision read something off a page of large black text")

        // Whether the rows come back as a table or as paragraphs is the very
        // question the spike exists to answer, so this asserts only that the
        // words arrived somewhere.
        let everything = reading.lines.joined(separator: "\n")
        #expect(everything.contains("Coleman"), "\(text)")
        #expect(everything.contains("Confirmed"), "\(text)")
        #expect(everything.contains("CO03C117"), "\(text)")

        let observations = try Data(contentsOf: folder.appending(path: "observation.json"))
        #expect(observations.count > text.utf8.count, "Vision's own record is the full one")
    }

    @Test("Bytes that are not an image are still kept, and the failure is Vision's")
    func unreadableBytesAreKeptBeforeTheFailure() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        await #expect(throws: CaptureError.unreadableImage) {
            try await SpikeDump.record(Data("nope".utf8), into: directory)
        }
        let kept = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(kept.count == 1, "the folder was made")
        let inside = try FileManager.default.contentsOfDirectory(
            atPath: directory.appending(path: kept[0]).path
        )
        #expect(inside == ["image.img"], "the bytes were written before Vision was asked")
    }

    @Test("Dumps list newest first and ignore loose files")
    func dumpsAreNewestFirst() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        for name in ["2026-09-21T090000Z", "2026-09-21T110000Z", "2026-09-21T100000Z"] {
            try FileManager.default.createDirectory(
                at: directory.appending(path: name), withIntermediateDirectories: true
            )
        }
        try Data().write(to: directory.appending(path: "stray.txt"))

        #expect(SpikeDump.dumps(in: directory).map(\.lastPathComponent) == [
            "2026-09-21T110000Z", "2026-09-21T100000Z", "2026-09-21T090000Z",
        ])
        #expect(SpikeDump.dumps(in: directory.appending(path: "missing")).isEmpty)
    }

    @Test("A dump with no reading says so rather than showing nothing")
    func missingReadingIsNamed() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let dump = directory.appending(path: "2026-09-21T090000Z")
        try FileManager.default.createDirectory(at: dump, withIntermediateDirectories: true)
        #expect(SpikeDump.rendered(of: dump) == "No reading was written for this dump.")

        try Data("Paragraphs: 1\n• hello".utf8).write(to: dump.appending(path: "reading.txt"))
        #expect(SpikeDump.rendered(of: dump) == "Paragraphs: 1\n• hello")
    }

    @Test("The archive is one zip of every dump")
    func archiveIsAZip() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let dump = directory.appending(path: "2026-09-21T090000Z")
        try FileManager.default.createDirectory(at: dump, withIntermediateDirectories: true)
        try Data("Paragraphs: 0".utf8).write(to: dump.appending(path: "reading.txt"))
        let destination = FileManager.default.temporaryDirectory
            .appending(path: "SpikeDumpTests-\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: destination) }

        let zip = try SpikeDump.archive(directory, to: destination)

        #expect(zip == destination)
        let bytes = try Data(contentsOf: zip)
        #expect(bytes.prefix(2) == Data([0x50, 0x4B]), "a zip starts with PK")
    }

    @Test("Deleting all removes the folder, and removing nothing is not a failure")
    func deleteAllIsIdempotent() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try SpikeDump.deleteAll(in: directory)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        #expect(throws: Never.self) { try SpikeDump.deleteAll(in: directory) }
    }

    // MARK: The tap on the intake

    @Test("The coordinator hands the recorder the bytes as they arrived, not as prepared")
    @MainActor
    func theRecorderSeesTheOriginalBytes() async throws {
        let container = try Store.makeInMemoryContainer(seeded: true)
        let coordinator = CaptureCoordinator(context: container.mainContext)
        coordinator.parsingFloor = .zero
        let recorded = Recorded()
        coordinator.spikeRecorder = { recorded.add($0) }
        let prepared = Data("prepared".utf8)
        coordinator.preparer = { _ in (prepared, "image/jpeg") }
        coordinator.extractor = { data, _, _ in
            recorded.extractorSaw(data)
            return (CaptureSamples.one, CaptureSamples.usage)
        }

        await coordinator.receive(photo: CaptureSamples.pixel)

        #expect(recorded.images == [CaptureSamples.pixel], "the full frame, before the preparer")
        #expect(recorded.sent == [prepared], "and the model still gets the prepared one")
    }

    @Test("The default recorder does nothing while the switch is off")
    func recorderIsOffByDefault() {
        #expect(!SpikeDump.isEnabled, "the test runner's defaults never switch it on")
        // Records nothing, writes nothing, and — the part that matters for the
        // suite — spawns no Vision pass for every capture test in the target.
        SpikeDump.recordIfEnabled(CaptureSamples.pixel)
        #expect(!FileManager.default.fileExists(atPath: SpikeDump.root.path))
    }

    /// What the tap and the extractor were each handed. `nonisolated` because
    /// the tap is `@Sendable` and called from wherever the intake runs.
    nonisolated final class Recorded: @unchecked Sendable {
        private(set) var images: [Data] = []
        private(set) var sent: [Data] = []
        func add(_ data: Data) { images.append(data) }
        func extractorSaw(_ data: Data) { sent.append(data) }
    }

    // MARK: A document to read

    /// A page in the shape of the booking system's table: a date heading, a
    /// header row, two rows with ruled cells, and a reservation heading below
    /// it. Large, black, on white — the easiest case there is, which is the
    /// point: this test asks whether Vision runs here, not how well.
    static func document() -> UIImage {
        let size = CGSize(width: 1000, height: 640)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor.black.setStroke()
            let font = UIFont.systemFont(ofSize: 26, weight: .medium)
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.black]

            ("My reservations" as NSString).draw(at: CGPoint(x: 40, y: 30), withAttributes: attributes)

            let columns: [CGFloat] = [40, 260, 620, 760, 960]
            let rows: [[String]] = [
                ["Desk", "Location", "Start", "Status"],
                ["Tuesday 4 August 2026", "", "", ""],
                ["CO03A424", "03, Coleman, London", "08:00", "Confirmed"],
                ["CO03C407", "03, Coleman, London", "08:00", "Confirmed"],
            ]
            var y: CGFloat = 100
            for row in rows {
                context.cgContext.setLineWidth(2)
                context.cgContext.stroke(CGRect(x: 40, y: y, width: 920, height: 60))
                for (index, cell) in row.enumerated() {
                    (cell as NSString).draw(
                        at: CGPoint(x: columns[index] + 12, y: y + 14), withAttributes: attributes
                    )
                }
                y += 60
            }

            ("Reservation for CO03C117" as NSString).draw(
                at: CGPoint(x: 40, y: y + 60), withAttributes: attributes
            )
            ("Building: Coleman" as NSString).draw(
                at: CGPoint(x: 40, y: y + 110), withAttributes: attributes
            )
        }
    }

    static func png(of image: UIImage) throws -> Data {
        try #require(image.pngData())
    }

    /// A JPEG carrying an EXIF orientation, written the way a camera writes
    /// one: pixels as drawn, rotation in the header.
    static func jpeg(of image: UIImage, orientation: CGImagePropertyOrientation) throws -> Data {
        let cgImage = try #require(image.cgImage)
        let encoded = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(
            encoded, UTType.jpeg.identifier as CFString, 1, nil
        ))
        CGImageDestinationAddImage(destination, cgImage, [
            kCGImagePropertyOrientation: orientation.rawValue
        ] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return encoded as Data
    }
}
