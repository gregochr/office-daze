import Foundation
import Vision

/// A document as Vision read it, reduced to strings and where on the page
/// each came from.
///
/// This is the seam between the recogniser and the parser, and it is a plain
/// value on purpose. `DocumentObservation` has no public initialiser, so a
/// parser written against it could only ever be tested by running Vision on
/// an image; a parser written against this can be tested from a literal, and
/// a reading Vision produced in the office can be saved as JSON and decoded
/// straight back into one. It is the fixture format.
///
/// Position is kept because grouping is not trusted. Vision hands back
/// paragraphs, tables and lists as separate arrays, and the booking list is a
/// column of cards that it may return as any of them. Sorting every block by
/// its top edge puts them back in reading order whatever it chose, and the
/// parser reads that order.
nonisolated struct DocumentReading: Codable, Equatable, Sendable {

    enum Kind: String, Codable, Sendable {
        case title, paragraph, table, list
    }

    /// One thing Vision found: a paragraph, a table, a list, or the title.
    struct Block: Codable, Equatable, Sendable {
        var kind: Kind
        /// The block's top edge in Vision's normalised coordinates, where 1 is
        /// the top of the image and 0 the bottom. Higher is earlier.
        var top: Double
        /// The text as rows of cells: one row of one cell for a paragraph or a
        /// title, the cells of each row for a table, one row of one cell per
        /// item for a list. A cell's own line breaks stay inside its string.
        var rows: [[String]]

        init(kind: Kind, top: Double, rows: [[String]]) {
            self.kind = kind
            self.top = top
            self.rows = rows
        }

        /// A paragraph, which is what most of a page is.
        init(_ text: String, top: Double) {
            self.init(kind: .paragraph, top: top, rows: [[text]])
        }
    }

    var blocks: [Block] = []
    /// What the data detectors matched in the page's text, as printed. Dates
    /// and times, mostly.
    var detected: [String] = []

    init(blocks: [Block] = [], detected: [String] = []) {
        self.blocks = blocks
        self.detected = detected
    }

    init(_ observation: DocumentObservation) {
        let document = observation.document
        var blocks: [Block] = []
        if let title = document.title {
            blocks.append(Block(kind: .title, top: Self.top(of: title), rows: [[title.transcript]]))
        }
        blocks += document.paragraphs.map { Block($0.transcript, top: Self.top(of: $0)) }
        blocks += document.tables.map { table in
            Block(
                kind: .table, top: Self.top(of: table),
                rows: table.rows.map { row in row.map { $0.content.text.transcript } }
            )
        }
        blocks += document.lists.map { list in
            Block(kind: .list, top: Self.top(of: list), rows: list.items.map { [$0.itemString] })
        }
        self.blocks = blocks

        // A match's range is into the text it was found in. Guarded rather
        // than trusted: this runs on a real capture, and a bad index would
        // take the app down for the sake of a hint.
        let transcript = document.text.transcript
        detected = document.text.detectedData.compactMap { detection in
            guard let range = detection.match.range,
                  range.upperBound <= transcript.endIndex else { return nil }
            return String(transcript[range])
        }
    }

    /// A region is a contour; its top edge is the top of the path's box. Vision's
    /// normalised space has its origin at the bottom left, so the top of the
    /// page is 1 and the largest `maxY` is the earliest block.
    private static func top(of region: some BoundingRegionProviding) -> Double {
        Double(region.boundingRegion.normalizedPath.boundingBox.maxY)
    }

    var isEmpty: Bool { blocks.isEmpty }

    /// The blocks in reading order: top of the page first. A tie keeps the
    /// order Vision gave, so two blocks on one line stay as they came.
    var ordered: [Block] {
        blocks.enumerated()
            .sorted { $0.element.top > $1.element.top || ($0.element.top == $1.element.top && $0.offset < $1.offset) }
            .map(\.element)
    }

    /// Every line of the page, in reading order: blocks top to bottom, cells
    /// left to right, a cell's own line breaks split. This is what the parser
    /// reads, and it is the same list whether Vision returned a table or a
    /// column of paragraphs.
    ///
    /// A line repeated immediately is dropped once: Vision reports the title
    /// as a paragraph as well, and the parser has no use for hearing it twice.
    var lines: [String] {
        var lines: [String] = []
        for block in ordered {
            for row in block.rows {
                for cell in row {
                    for line in cell.split(whereSeparator: \.isNewline) {
                        let trimmed = line.trimmingCharacters(in: .whitespaces)
                        guard !trimmed.isEmpty, trimmed != lines.last else { continue }
                        lines.append(trimmed)
                    }
                }
            }
        }
        return lines
    }

    /// The reading as a page of text, block by block in reading order, so a
    /// dump can be read on a phone in the office.
    var rendered: String {
        var out: [String] = []
        for block in ordered {
            switch block.kind {
            case .title:
                out.append("Title: " + (block.rows.first?.first ?? ""))
            case .paragraph:
                out.append("• " + (block.rows.first?.first ?? "").replacing("\n", with: "\n  "))
            case .table:
                out.append("Table: \(block.rows.count) rows")
                out += block.rows.map { "| " + $0.joined(separator: " | ") + " |" }
            case .list:
                out.append("List: \(block.rows.count) items")
                out += block.rows.map { "- " + ($0.first ?? "") }
            }
        }
        if out.isEmpty { out.append("Nothing was read.") }
        if !detected.isEmpty {
            out.append("Detected: " + detected.joined(separator: ", "))
        }
        return out.joined(separator: "\n")
    }
}
