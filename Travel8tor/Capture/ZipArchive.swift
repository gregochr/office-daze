import Compression
import Foundation

/// A minimal ZIP reader, enough to pull `pass.json` out of a `.pkpass`.
///
/// iOS ships no public unzip API — `AppleArchive` reads Apple's own format, not
/// ZIP, and `PKPass` exposes only a handful of named fields rather than the
/// pass structure. Rather than add a dependency for one file, this reads the
/// central directory and inflates the one entry we want.
///
/// Deliberately not a general-purpose ZIP library: no writing, no ZIP64, no
/// encryption. A `.pkpass` is a small, flat, well-formed archive.
nonisolated enum ZipArchive {

    struct Entry {
        let name: String
        let compressionMethod: UInt16
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int
    }

    private static let endOfCentralDirectory: UInt32 = 0x0605_4B50
    private static let centralFileHeader: UInt32 = 0x0201_4B50
    private static let localFileHeader: UInt32 = 0x0403_4B50

    static func entries(in data: Data) throws -> [Entry] {
        guard let eocd = findEndOfCentralDirectory(in: data) else { throw CaptureError.notAZip }

        let count = Int(read16(data, eocd + 10))
        var offset = Int(read32(data, eocd + 16))
        var entries: [Entry] = []

        for _ in 0..<count {
            guard offset + 46 <= data.count, read32(data, offset) == centralFileHeader else {
                throw CaptureError.notAZip
            }
            let method = read16(data, offset + 10)
            let compressed = Int(read32(data, offset + 20))
            let uncompressed = Int(read32(data, offset + 24))
            let nameLength = Int(read16(data, offset + 28))
            let extraLength = Int(read16(data, offset + 30))
            let commentLength = Int(read16(data, offset + 32))
            let localOffset = Int(read32(data, offset + 42))

            guard offset + 46 + nameLength <= data.count else { throw CaptureError.notAZip }
            let name = String(
                decoding: data[(offset + 46)..<(offset + 46 + nameLength)], as: UTF8.self
            )

            entries.append(Entry(
                name: name,
                compressionMethod: method,
                compressedSize: compressed,
                uncompressedSize: uncompressed,
                localHeaderOffset: localOffset
            ))
            offset += 46 + nameLength + extraLength + commentLength
        }
        return entries
    }

    static func extract(_ name: String, from data: Data) throws -> Data {
        guard let entry = try entries(in: data).first(where: { $0.name == name }) else {
            throw CaptureError.missingPassJSON
        }
        return try extract(entry, from: data)
    }

    static func extract(_ entry: Entry, from data: Data) throws -> Data {
        let header = entry.localHeaderOffset
        guard header + 30 <= data.count, read32(data, header) == localFileHeader else {
            throw CaptureError.notAZip
        }
        // The local header's name and extra lengths can differ from the central
        // directory's; the data offset must come from here.
        let nameLength = Int(read16(data, header + 26))
        let extraLength = Int(read16(data, header + 28))
        let start = header + 30 + nameLength + extraLength
        let end = start + entry.compressedSize
        guard end <= data.count else { throw CaptureError.notAZip }

        let payload = data[start..<end]

        switch entry.compressionMethod {
        case 0:
            return Data(payload)
        case 8:
            return try inflate(Data(payload), expectedSize: entry.uncompressedSize)
        default:
            throw CaptureError.malformedPass("unsupported compression method \(entry.compressionMethod)")
        }
    }

    /// Raw DEFLATE. Apple's `COMPRESSION_ZLIB` is the raw stream with no zlib
    /// header, which is exactly what ZIP stores.
    private static func inflate(_ data: Data, expectedSize: Int) throws -> Data {
        guard expectedSize > 0 else { return Data() }
        // A little slack: a corrupt size field shouldn't truncate silently.
        let capacity = max(expectedSize, 1) + 1024
        var output = Data(count: capacity)

        let written: Int = output.withUnsafeMutableBytes { destination in
            data.withUnsafeBytes { source in
                compression_decode_buffer(
                    destination.bindMemory(to: UInt8.self).baseAddress!, capacity,
                    source.bindMemory(to: UInt8.self).baseAddress!, data.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }

        guard written > 0 else { throw CaptureError.malformedPass("could not inflate entry") }
        return output.prefix(written)
    }

    // MARK: Little-endian reads

    private static func findEndOfCentralDirectory(in data: Data) -> Int? {
        // The record is 22 bytes plus a comment of up to 64K, so scan back from
        // the end rather than assuming it is the last 22 bytes.
        guard data.count >= 22 else { return nil }
        let lowest = max(0, data.count - 22 - 65_535)
        var index = data.count - 22
        while index >= lowest {
            if read32(data, index) == endOfCentralDirectory { return index }
            index -= 1
        }
        return nil
    }

    private static func read16(_ data: Data, _ offset: Int) -> UInt16 {
        guard offset + 2 <= data.count else { return 0 }
        let base = data.startIndex + offset
        return UInt16(data[base]) | UInt16(data[base + 1]) << 8
    }

    private static func read32(_ data: Data, _ offset: Int) -> UInt32 {
        guard offset + 4 <= data.count else { return 0 }
        let base = data.startIndex + offset
        return UInt32(data[base])
            | UInt32(data[base + 1]) << 8
            | UInt32(data[base + 2]) << 16
            | UInt32(data[base + 3]) << 24
    }
}
