#if DEBUG
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

/// The OCR spike's recorder: every image that enters the capture flow is also
/// run through Vision's document reader, and what came back is written down
/// beside the image.
///
/// This exists for one day in the office. The question the spike has to answer
/// is whether a photograph of the booking system's table comes back from
/// `RecognizeDocumentsRequest` as a table or as loose paragraphs, and the only
/// way to find out is to point the phone at the real thing. Everything here is
/// in service of that: the real capture flow carries on untouched, and this
/// taps the bytes on their way in, so the office day is spent capturing rather
/// than building.
///
/// Four files per capture, in a folder named for the moment it landed:
///
/// - `image.<ext>`, the bytes exactly as they arrived, before `PhotoImport`
///   downsizes them — Vision wants the full frame, and so will any fixture.
/// - `observation.json`, Vision's own `DocumentObservation`s, encoded whole.
///   It is the complete record, words and bounding regions included.
/// - `reading.json`, the same result reduced to strings: tables as rows of
///   cells, paragraphs, lists, detected data. `DocumentObservation` has no
///   public initialiser, so this is the shape a parser test can construct —
///   which makes it the fixture format, and the JSON above the evidence.
/// - `reading.txt`, the reduction rendered for a person, so the answer can be
///   read on the phone in the office rather than after a trip to a Mac.
///
/// Debug builds only, and off until switched on in Settings: the coordinator
/// tests run the intake hundreds of times, and a Vision pass and four files per
/// run is not a test suite anyone wants.
nonisolated enum SpikeDump {

    // MARK: The switch

    private static let enabledKey = "spikeDumpEnabled"

    /// Whether the intake records. Read on every capture rather than cached,
    /// so the Settings toggle takes effect on the next capture without a
    /// relaunch.
    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// Where the dumps live: `Documents/Spike/`. Under `Documents` rather than
    /// caches so a dump survives until it is deliberately deleted, and so the
    /// archive below has one folder to zip.
    static var root: URL {
        URL.documentsDirectory.appending(path: "Spike", directoryHint: .isDirectory)
    }

    // MARK: The reading

    /// Vision's document, reduced to the strings a parser would read.
    ///
    /// `Codable` and constructible from literals, which `DocumentObservation`
    /// is not — this is the shape the parser tests will be written against,
    /// so a fixture captured in the office is a file a test can decode
    /// verbatim, and a case nobody captured is a literal a test can still
    /// write.
    struct Reading: Codable, Equatable, Sendable {
        /// The document's title, when Vision found one.
        var title: String?
        /// Each table as rows of cells, each cell's text. A spanning cell
        /// appears once, at its first position.
        var tables: [[[String]]] = []
        /// Every paragraph's transcript, in reading order.
        var paragraphs: [String] = []
        /// Each list as its items' text.
        var lists: [[String]] = []
        /// What the data detectors matched in the document's text, as printed.
        /// Dates, mostly, which is the one kind the booking table hinges on.
        var detected: [String] = []

        init(
            title: String? = nil, tables: [[[String]]] = [], paragraphs: [String] = [],
            lists: [[String]] = [], detected: [String] = []
        ) {
            self.title = title
            self.tables = tables
            self.paragraphs = paragraphs
            self.lists = lists
            self.detected = detected
        }

        init(_ observation: DocumentObservation) {
            let document = observation.document
            title = document.title?.transcript
            tables = document.tables.map { table in
                table.rows.map { row in row.map { $0.content.text.transcript } }
            }
            paragraphs = document.paragraphs.map(\.transcript)
            lists = document.lists.map { list in list.items.map(\.itemString) }
            // A match's range is into the text it was found in. Guarded
            // rather than trusted, because this runs on a real capture in
            // the office and a bad index here would take the app down for
            // the sake of a debug file.
            let transcript = document.text.transcript
            detected = document.text.detectedData.compactMap { detection in
                guard let range = detection.match.range,
                      range.upperBound <= transcript.endIndex else { return nil }
                return String(transcript[range])
            }
        }

        /// Whether Vision saw anything at all. An empty reading is a failed
        /// dump as far as the office day is concerned, and is said so.
        var isEmpty: Bool {
            title == nil && tables.isEmpty && paragraphs.isEmpty && lists.isEmpty
        }

        /// The reading as a page of text: one line per table row with the
        /// cells piped apart, one per paragraph, one per list item. Written to
        /// be read on a phone screen, and to be asserted on.
        var rendered: String {
            var lines: [String] = []
            if let title { lines.append("Title: \(title)") }
            for (index, table) in tables.enumerated() {
                lines.append("Table \(index + 1): \(table.count) rows")
                for row in table {
                    lines.append("| " + row.joined(separator: " | ") + " |")
                }
            }
            lines.append("Paragraphs: \(paragraphs.count)")
            lines.append(contentsOf: paragraphs.map { "• " + $0 })
            for (index, list) in lists.enumerated() {
                lines.append("List \(index + 1): \(list.count) items")
                lines.append(contentsOf: list.map { "- " + $0 })
            }
            if !detected.isEmpty {
                lines.append("Detected: " + detected.joined(separator: ", "))
            }
            return lines.joined(separator: "\n")
        }
    }

    // MARK: Reading an image

    /// What one image was read as: Vision's observations, whole, and their
    /// reduction.
    struct Result: Sendable {
        var observations: [DocumentObservation]
        var reading: Reading
    }

    /// Runs the document request on the bytes as they arrived.
    ///
    /// Decoded to a `CGImage` at full size rather than handed over as `Data`,
    /// and with the orientation read out of the header and passed explicitly.
    /// A photograph taken sideways carries its rotation in EXIF, and a Vision
    /// pass over the unrotated pixels reads a sideways table — the same trap
    /// `PhotoImport` steps around with `kCGImageSourceCreateThumbnailWithTransform`,
    /// handled here the way Vision itself expects it to be.
    ///
    /// Language correction is left on. The spike is measuring what Vision does
    /// by default; whether desk ids need it off is one of the things the
    /// dumps will show.
    @concurrent
    static func read(_ data: Data) async throws -> Result {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw CaptureError.unreadableImage
        }
        let request = RecognizeDocumentsRequest()
        let observations = try await request.perform(on: image, orientation: orientation(of: source))
        // Several observations would be several documents in one image. The
        // reading takes the first because the spike's images hold one; the
        // JSON keeps them all because the spike is there to find out.
        let reading = observations.first.map(Reading.init) ?? Reading()
        return Result(observations: observations, reading: reading)
    }

    /// The EXIF orientation, or `.up` when the header does not say. A
    /// screenshot has none and is upright; a camera frame always has one.
    static func orientation(of source: CGImageSource) -> CGImagePropertyOrientation {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let raw = properties[kCGImagePropertyOrientation] as? UInt32,
              let orientation = CGImagePropertyOrientation(rawValue: raw) else { return .up }
        return orientation
    }

    // MARK: Writing it down

    /// Reads the image and writes the four files into a new folder under
    /// `directory`. Returns the folder.
    ///
    /// The image is written first, and before Vision runs: a frame that Vision
    /// then chokes on is exactly the frame worth keeping, and the point of the
    /// day is to come home with the pictures.
    @concurrent
    static func record(_ data: Data, into directory: URL, at moment: Date = .now) async throws -> URL {
        let folder = directory.appending(path: folderName(for: moment), directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try data.write(to: folder.appending(path: "image.\(fileExtension(of: data))"))

        let result = try await read(data)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(result.observations).write(to: folder.appending(path: "observation.json"))
        try encoder.encode(result.reading).write(to: folder.appending(path: "reading.json"))
        try Data(result.reading.rendered.utf8).write(to: folder.appending(path: "reading.txt"))
        return folder
    }

    /// The intake's tap: records into `root` when the switch is on, and does
    /// nothing at all when it is off. Never throws and never waits — the
    /// capture it is riding on must neither slow down nor fail because a
    /// debug dump did.
    static func recordIfEnabled(_ data: Data) {
        guard isEnabled else { return }
        Task.detached {
            do {
                _ = try await record(data, into: root)
            } catch {
                // A dump that failed is a dump that is missing from the list
                // in Settings, which is where it will be noticed.
                print("Spike dump failed: \(error)")
            }
        }
    }

    /// `2026-09-21T09-14-03Z`: the moment, sortable, with the colons a file
    /// name cannot carry swapped out.
    static func folderName(for moment: Date) -> String {
        moment.formatted(.iso8601.dateSeparator(.dash).timeSeparator(.omitted))
            .replacing(":", with: "-")
    }

    /// The extension the bytes deserve, from what ImageIO says they are —
    /// `heic` for a camera frame, `png` for a screenshot — or `img` when it
    /// cannot tell, which still writes the file.
    static func fileExtension(of data: Data) -> String {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source) as String?,
              let ext = UTType(type)?.preferredFilenameExtension else { return "img" }
        return ext
    }

    // MARK: Getting them off the phone

    /// The dumps on disk, newest first. A folder is a dump; anything else
    /// under the root is ignored.
    static func dumps(in directory: URL = root) -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey],
            options: .skipsHiddenFiles
        )) ?? []
        return contents
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    /// The rendered reading of one dump, or a line saying there is none.
    static func rendered(of dump: URL) -> String {
        (try? String(contentsOf: dump.appending(path: "reading.txt"), encoding: .utf8))
            ?? "No reading was written for this dump."
    }

    /// Every dump, zipped into one file for the share sheet.
    ///
    /// `NSFileCoordinator` with `.forUploading` is the system's own way to
    /// hand a folder to something that wants a single file: it zips the
    /// directory into a temporary location and lends out that URL. The copy
    /// is made because the lent URL is gone when the block returns.
    static func archive(_ directory: URL = root, to destination: URL? = nil) throws -> URL {
        let target = destination ?? FileManager.default.temporaryDirectory
            .appending(path: "Spike-\(folderName(for: .now)).zip")
        var coordinationError: NSError?
        var copyError: (any Error)?
        NSFileCoordinator().coordinate(
            readingItemAt: directory, options: .forUploading, error: &coordinationError
        ) { zipped in
            do {
                try? FileManager.default.removeItem(at: target)
                try FileManager.default.copyItem(at: zipped, to: target)
            } catch {
                copyError = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let copyError { throw copyError }
        return target
    }

    /// Removes every dump. The archive, once shared, is the copy that matters.
    static func deleteAll(in directory: URL = root) throws {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.removeItem(at: directory)
    }
}
#endif
