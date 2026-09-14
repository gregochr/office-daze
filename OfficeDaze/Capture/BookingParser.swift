import Foundation

/// What a page of the booking system says, read as bookings.
///
/// This is the other half of what the Claude call used to do — the reasoning
/// the prompt spelled out in prose: which layout this is, which date a row
/// belongs to, which rows are whole, which are confirmed. It reads the lines
/// of a `DocumentReading` in page order and nothing else, so it works the
/// same whether Vision returned a table or a column of paragraphs, and it can
/// be tested from a list of strings.
///
/// The prompt's first rule survives as a property of the code rather than a
/// request: a parser can only emit what it found. There is no path here that
/// produces a date, a desk or a time from anything but a line that printed
/// one. The one thing it derives is the floor and zone inside a desk id, and
/// that is decoding a known scheme, not guessing — see `DeskID`.
nonisolated enum BookingParser {

    // MARK: Layouts

    /// The pages the booking system prints, and the one it might.
    enum Layout: Equatable, Sendable {
        /// "My reservations": a column of date cards, each with a booking
        /// card beneath it. Several bookings, one per complete pair.
        case list
        /// A reservation's own page: reservation number, time details, and a
        /// reserved-items block at the bottom. One booking.
        case summary
        /// The "Reservation details" form: a subject, a date line, a desk
        /// card. One booking — and possibly not yet a confirmed one; see
        /// `assumesConfirmed`.
        case details
        /// Nothing recognisable — a confirmation email, or a photo of
        /// something else. Read as a single booking, and only ever produces
        /// one if a desk id and a date are actually there.
        case unknown
    }

    static func layout(of lines: [String]) -> Layout {
        let upper = lines.map { $0.uppercased() }
        func any(of cues: [String]) -> Bool {
            upper.contains { line in cues.contains { line.contains($0) } }
        }
        if any(of: ["RESERVATION NUMBER", "TIME DETAILS", "RESERVED ITEMS", "SHIFT DETAILS"]) {
            return .summary
        }
        if any(of: ["RESERVATION SUBJECT", "RESERVATION DETAILS", "ADD EXTRA SERVICES"]) {
            return .details
        }
        if any(of: ["TIMES SHOWN BASED ON"]) || lines.contains(where: { isBareDate($0) }) {
            return .list
        }
        return .unknown
    }

    /// Whether a page that prints no status at all is taken as confirmed.
    ///
    /// A reservation's own page and a confirmation email describe something
    /// that exists, so yes. The details form is the open question: it looks
    /// like the page *before* a booking is confirmed, and if that is what it
    /// is, this is the one line to change. Pinned by a test so the decision
    /// is visible rather than implied.
    static func assumesConfirmed(_ layout: Layout) -> Bool {
        switch layout {
        case .summary, .details, .unknown: true
        case .list: false
        }
    }

    // MARK: Parsing

    static func parse(_ reading: DocumentReading) -> [ParsedBooking] {
        captured(from: reading.lines).compactMap { $0.parsed() }
    }

    /// The bookings on the page, before `CapturedBooking.parsed()` applies the
    /// rules every capture shares — the valid date, the default end time, the
    /// unread-field flags.
    static func captured(from lines: [String]) -> [CapturedBooking] {
        let layout = layout(of: lines)
        switch layout {
        case .list:
            return list(lines)
        case .summary, .details, .unknown:
            return single(lines, assumingConfirmed: assumesConfirmed(layout)).map { [$0] } ?? []
        }
    }

    // MARK: The list

    /// One booking per complete section. A section is a date card and the
    /// booking card beneath it; the rule the user set is that either half
    /// missing means no booking.
    ///
    /// A photograph of the list is cut off at both ends, and the two ends cut
    /// differently. At the top, the first thing in frame is often a booking
    /// card whose date card is above the edge: those lines arrive before any
    /// date and are dropped, because a heading carries downwards only. At the
    /// bottom, the last thing is often a date card whose booking is below
    /// the edge: that section closes with no desk in it and produces nothing.
    static func list(_ lines: [String]) -> [CapturedBooking] {
        var bookings: [CapturedBooking] = []
        var date: String?
        var section: [Line] = []

        func close() {
            if let date { bookings += rows(in: section, on: date) }
            section = []
        }

        for facts in lines.map(facts(in:)) {
            // A date on the line opens a section; whatever else the line
            // carried belongs to the new section, not the old one.
            if let opened = facts.lazy.compactMap(\.opensSection).first {
                close()
                date = opened.date
                section = opened.range.map { [.range($0)] } ?? []
            }
            section += facts.filter { $0.opensSection == nil }
        }
        close()
        return bookings
    }

    /// The bookings in one section, one per desk id, each paired by position
    /// with a status. Gathered from the section as a bag rather than walked
    /// in order, because the card's cells sit on one line and Vision may
    /// hand them back in any order — the time before the desk, the status
    /// before either.
    ///
    /// Only a row with a status is a row, and only `Confirmed` is a booking.
    /// A desk with no status to its name is half a row — cut off, or a
    /// second row sharing one status line — and half a row is not a booking.
    static func rows(in section: [Line], on date: String) -> [CapturedBooking] {
        let desks = section.compactMap(\.desk)
        let statuses = section.compactMap(\.status)
        let ranges = section.compactMap(\.range)
        let locations = section.compactMap(\.location)

        return desks.enumerated().compactMap { index, desk in
            guard index < statuses.count, statuses[index] == .confirmed else { return nil }
            return booking(
                date: date, desk: desk,
                range: ranges.count == desks.count ? ranges[index] : ranges.first,
                location: locations.count == desks.count ? locations[index] : locations.first,
                building: nil
            )
        }
    }

    // MARK: A page about one reservation

    /// The one booking a reservation page, a details form or an email
    /// describes, or nil when it does not describe one.
    ///
    /// The desk is the *last* id on the page. A reservation page prints it
    /// twice — in the "Reservation for" heading and in the reserved-items
    /// block at the bottom — and a photo that has scrolled past the heading
    /// still has the block, while one that stops short of the block still has
    /// the heading. Both are the same id, so the last one found is right
    /// whichever half is in frame.
    ///
    /// The date comes from wherever the page prints one beside a time: the
    /// reserved-items line `2026-10-05 • 08:00 - 17:00`, or the `Starts` and
    /// `Ends` stamps, or an email's timestamp. A bare date is taken only when
    /// nothing better is there.
    static func single(_ lines: [String], assumingConfirmed: Bool) -> CapturedBooking? {
        let classified = lines.flatMap(facts(in:))
        guard let desk = classified.compactMap(\.desk).last else { return nil }

        let statuses = classified.compactMap(\.status)
        if let printed = statuses.first {
            guard printed == .confirmed else { return nil }
        } else if !assumingConfirmed {
            return nil
        }

        var date: String?
        var range: TimeRange?
        if let (found, found2) = classified.lazy.compactMap(\.dateAndRange).first {
            date = found
            range = found2
        } else {
            let stamps = classified.compactMap(\.stamp)
            if let first = stamps.first {
                date = first.date
                let end = stamps.dropFirst().first { $0.date == first.date }?.time
                range = TimeRange(start: first.time, end: end)
            } else {
                date = classified.lazy.compactMap(\.date).first
                range = classified.lazy.compactMap(\.range).first
            }
        }
        guard let date else { return nil }

        let locations = classified.compactMap(\.location)
        return booking(
            date: date, desk: desk, range: range,
            location: locations.first { $0.floor != nil } ?? locations.first,
            building: buildingValue(in: lines)
        )
    }

    /// The value under a `Buildings` label, or beside a `Building:` one. The
    /// reservation page prints its building this way and nowhere else when
    /// the reserved-items block is out of frame.
    static func buildingValue(in lines: [String]) -> String? {
        for (index, line) in lines.enumerated() {
            if let match = line.firstMatch(of: /^Buildings?:\s*(.+)$/.ignoresCase()) {
                return String(match.1).trimmingCharacters(in: .whitespaces)
            }
            if line.trimmingCharacters(in: .whitespaces).uppercased().wholeMatch(of: /BUILDINGS?/) != nil,
               index + 1 < lines.count {
                return lines[index + 1]
            }
        }
        return nil
    }

    // MARK: Assembling one

    /// One booking from the facts gathered for it, in the model's vocabulary
    /// so `CapturedBooking.parsed()` finishes the job.
    ///
    /// Floor is the one field with two sources. When the id decodes and the
    /// page also prints a floor, they must agree; a disagreement is a
    /// misreading of one or the other with no way to say which, so the floor
    /// is left unread rather than picked. An id from a site whose scheme is
    /// unknown contributes nothing, and the page's floor stands alone.
    ///
    /// The office is printed or decoded, in that order: what the page says,
    /// then the building label, then the site code — so a page from a known
    /// site always names its office, and the sheet never has to ask which
    /// building a Coleman desk is in.
    static func booking(
        date: String, desk: DeskID, range: TimeRange?, location: Location?, building: String?
    ) -> CapturedBooking {
        let floor: String?
        switch (desk.decodedFloor, location?.floor) {
        case (let decoded?, let printed?):
            floor = Int(decoded) == Int(printed) ? printed : nil
        case (let decoded?, nil):
            floor = decoded
        case (nil, let printed):
            floor = printed
        }
        return CapturedBooking(
            office: location?.office ?? building ?? desk.decodedOffice,
            date: date,
            deskId: desk.text,
            floor: floor,
            zone: desk.decodedZone,
            startTime: range?.start,
            endTime: range?.end,
            unsureFields: []
        )
    }

    // MARK: Reading a line

    struct TimeRange: Equatable, Sendable {
        var start: String
        var end: String?
    }

    struct Location: Equatable, Sendable {
        var floor: String?
        var office: String
    }

    enum Status: Equatable, Sendable {
        case confirmed, cancelled, pending, waitlisted, declined
    }

    /// One fact a line of the page states. A line states any number of them:
    /// the list card's cells sit on one line, and Vision may hand the whole
    /// row back as one string — `CO03C102 03, Coleman, London 08:00 - 17:00
    /// Confirmed` — or as five.
    enum Line: Equatable, Sendable {
        /// A date with no time beside it: the list's date card.
        case date(String)
        /// A date and a time range together: `2026-10-05 • 08:00 - 17:00 Europe/London`.
        case dateAndRange(String, TimeRange)
        /// A date and a single time: the `Starts` and `Ends` values, or an
        /// email's `2026-08-25 09:00:00 CEST`.
        case stamp(date: String, time: String)
        /// A time range on its own: the list card's `08:00 - 17:00`.
        case range(TimeRange)
        case desk(DeskID)
        /// `03, Coleman, London`, or `Coleman · London`.
        case location(Location)
        case status(Status)

        var desk: DeskID? { if case .desk(let id) = self { id } else { nil } }
        var status: Status? { if case .status(let status) = self { status } else { nil } }
        var range: TimeRange? { if case .range(let range) = self { range } else { nil } }
        var location: Location? { if case .location(let location) = self { location } else { nil } }
        var date: String? { if case .date(let date) = self { date } else { nil } }
        var dateAndRange: (String, TimeRange)? {
            if case .dateAndRange(let date, let range) = self { (date, range) } else { nil }
        }
        var stamp: (date: String, time: String)? {
            if case .stamp(let date, let time) = self { (date, time) } else { nil }
        }

        /// The date this fact opens a list section with, and the range it
        /// brought along, if it is that kind of fact.
        var opensSection: (date: String, range: TimeRange?)? {
            switch self {
            case .date(let date): (date, nil)
            case .dateAndRange(let date, let range): (date, range)
            default: nil
            }
        }
    }

    /// Everything one line states, in the order it states it. Most lines
    /// state nothing.
    static func facts(in raw: String) -> [Line] {
        let line = raw.trimmingCharacters(in: .whitespaces)
        var facts: [Line] = DeskID.all(in: line).map(Line.desk)

        if let match = line.firstMatch(of: /(\d{4}-\d{2}-\d{2})\D+?(\d{1,2}:\d{2})\s*[-–]\s*(\d{1,2}:\d{2})/) {
            facts.append(.dateAndRange(
                String(match.1), TimeRange(start: time(match.2), end: time(match.3))
            ))
        } else if let match = line.firstMatch(of: /(\d{4}-\d{2}-\d{2})\s+(\d{1,2}:\d{2})/) {
            facts.append(.stamp(date: String(match.1), time: time(match.2)))
        } else {
            if let match = line.firstMatch(of: /\b(\d{4}-\d{2}-\d{2})\b/) {
                facts.append(.date(String(match.1)))
            }
            if let match = line.firstMatch(of: /(\d{1,2}:\d{2})\s*[-–]\s*(\d{1,2}:\d{2})/) {
                facts.append(.range(TimeRange(start: time(match.1), end: time(match.2))))
            }
        }
        if let status = status(in: line) { facts.append(.status(status)) }
        if let location = location(in: line) { facts.append(.location(location)) }
        return facts
    }

    /// `2026-09-16` and nothing else: the list's date card, which is what
    /// makes a page a list.
    static func isBareDate(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).wholeMatch(of: /\d{4}-\d{2}-\d{2}/) != nil
    }

    /// The status word on a line, as a whole word. The card prints it as its
    /// own cell, which is a line of its own or the tail of the row's.
    static func status(in line: String) -> Status? {
        let words = Set(line.uppercased().split { !$0.isLetter && $0 != "-" }.map(String.init))
        return statusWords.first { !$0.words.isDisjoint(with: words) }?.status
    }

    private static let statusWords: [(words: Set<String>, status: Status)] = [
        (["CONFIRMED"], .confirmed),
        (["CANCELLED", "CANCELED"], .cancelled),
        (["PENDING"], .pending),
        (["WAITLISTED", "WAIT-LISTED", "WAITLIST"], .waitlisted),
        (["DECLINED", "REJECTED"], .declined),
    ]

    /// `03, Coleman, London` is floor 03 at "Coleman, London". `Coleman ·
    /// London` is the same office with no floor, as the details form prints
    /// it, and the dot becomes the comma so the two read as one name.
    static func location(in line: String) -> Location? {
        if let match = line.firstMatch(of: /\b(\d{1,2}),\s*([A-Za-z]+(?: [A-Za-z]+)*(?:,\s*[A-Za-z]+(?: [A-Za-z]+)*)*)/) {
            return Location(
                floor: String(match.1),
                office: String(match.2).trimmingCharacters(in: .whitespaces)
            )
        }
        if let match = line.firstMatch(of: /^([A-Za-z][A-Za-z ]*?)\s*[·•]\s*([A-Za-z][A-Za-z ]*)$/) {
            return Location(
                floor: nil,
                office: "\(match.1.trimmingCharacters(in: .whitespaces)), \(match.2.trimmingCharacters(in: .whitespaces))"
            )
        }
        return nil
    }

    /// `8:00` as `08:00`, so a time reads the same however the page padded it.
    static func time(_ text: some StringProtocol) -> String {
        let parts = text.split(separator: ":")
        guard parts.count == 2, let hour = Int(parts[0]) else { return String(text) }
        return String(format: "%02d:%@", hour, String(parts[1]))
    }
}
