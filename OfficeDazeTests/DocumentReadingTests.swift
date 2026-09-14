import Foundation
import Testing
@testable import OfficeDaze

/// The seam between Vision and the parser: what a reading flattens to, and
/// how it survives being a fixture.
@Suite("A document reading")
struct DocumentReadingTests {

    typealias Block = DocumentReading.Block

    @Test("Lines come out top to bottom whatever order the blocks were given in")
    func linesAreInPageOrder() {
        let reading = DocumentReading(blocks: [
            Block("bottom", top: 0.1),
            Block("top", top: 0.9),
            Block("middle", top: 0.5),
        ])
        #expect(reading.lines == ["top", "middle", "bottom"])
    }

    @Test("A table contributes one line per cell, left to right within each row")
    func tablesFlattenToCells() {
        let reading = DocumentReading(blocks: [
            Block("after", top: 0.2),
            Block(kind: .table, top: 0.8, rows: [["a", "b"], ["c", "d"]]),
        ])
        #expect(reading.lines == ["a", "b", "c", "d", "after"])
    }

    @Test("A cell's own line breaks are split, and blank lines dropped")
    func cellsSplitOnNewlines() {
        let reading = DocumentReading(blocks: [
            Block("CO03C108\n03, Coleman, London\n\n", top: 0.5),
        ])
        #expect(reading.lines == ["CO03C108", "03, Coleman, London"])
    }

    /// Vision reports the title as a paragraph as well. The parser has no use
    /// for hearing it twice.
    @Test("A line repeated immediately is heard once")
    func consecutiveDuplicatesCollapse() {
        let reading = DocumentReading(blocks: [
            Block(kind: .title, top: 0.9, rows: [["My reservations"]]),
            Block("My reservations", top: 0.9),
            Block("2026-09-16", top: 0.8),
        ])
        #expect(reading.lines == ["My reservations", "2026-09-16"])
    }

    @Test("Blocks at the same height keep the order Vision gave them")
    func tiesKeepInsertionOrder() {
        let reading = DocumentReading(blocks: [
            Block("CO03C108", top: 0.5),
            Block("08:00 - 17:00", top: 0.5),
            Block("Confirmed", top: 0.5),
        ])
        #expect(reading.lines == ["CO03C108", "08:00 - 17:00", "Confirmed"])
    }

    @Test("Rendering shows each block in page order, in its own shape")
    func renders() {
        let reading = DocumentReading(
            blocks: [
                Block(kind: .list, top: 0.2, rows: [["Starts 08:00"], ["Ends 17:00"]]),
                Block(kind: .title, top: 0.9, rows: [["My reservations"]]),
                Block(kind: .table, top: 0.6, rows: [["2026-09-16"], ["CO03C108", "Confirmed"]]),
                Block("Reservation for CO03C117", top: 0.4),
            ],
            detected: ["2026-09-16"]
        )
        #expect(reading.rendered == """
            Title: My reservations
            Table: 2 rows
            | 2026-09-16 |
            | CO03C108 | Confirmed |
            • Reservation for CO03C117
            List: 2 items
            - Starts 08:00
            - Ends 17:00
            Detected: 2026-09-16
            """)
    }

    @Test("An empty reading says so")
    func emptyRenders() {
        let reading = DocumentReading()
        #expect(reading.isEmpty)
        #expect(reading.lines.isEmpty)
        #expect(reading.rendered == "Nothing was read.")
    }

    @Test("A reading survives its own JSON — the fixture format has to")
    func roundTripsThroughJSON() throws {
        let reading = DocumentReading(
            blocks: [
                Block(kind: .table, top: 0.7, rows: [["a", "b"], ["c", "d"]]),
                Block("p", top: 0.3),
            ],
            detected: ["d"]
        )
        let data = try JSONEncoder().encode(reading)
        #expect(try JSONDecoder().decode(DocumentReading.self, from: data) == reading)
    }
}
