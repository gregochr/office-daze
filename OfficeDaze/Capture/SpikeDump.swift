#if DEBUG
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The fixture recorder: every image that enters the capture flow is also run
/// through the document reader on its own, and what came back is written down
/// beside the image.
///
/// It began as the OCR spike's tap, for finding out what a photograph of the
/// booking system's list came back as. It stays because the answer changes: a
/// page that reads badly in the office is a page whose reading belongs in the
/// test bundle, and this is how it gets there. The real capture flow carries
/// on untouched; this taps the bytes on their way in.
///
/// Four files per capture, in a folder named for the moment it landed:
///
/// - `image.<ext>`, the bytes exactly as they arrived, before `PhotoImport`
///   downsizes them — Vision wants the full frame, and so will any fixture.
/// - `observation.json`, Vision's own `DocumentObservation`s, encoded whole.
///   It is the complete record, words and bounding regions included.
/// - `reading.json`, the same result reduced to a `DocumentReading`: blocks
///   of text with their positions. `DocumentObservation` has no public
///   initialiser, so this is the shape the parser reads and its tests
///   construct — which makes it the fixture format, and the JSON above the
///   evidence.
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

        let result = try await DocumentReader.read(data)
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
