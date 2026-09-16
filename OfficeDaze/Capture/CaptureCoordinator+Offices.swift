import Foundation
import SwiftData

/// What the coordinator knows about offices: which one a booking belongs to,
/// and what an office learns from the bookings filed under it — the names the
/// booking system prints for it, and the site code its desks open with.
///
/// A sibling file rather than a section, on the seam the linter's file
/// length asks for: everything here is about an `Office`, and nothing here
/// touches the phase machine. It reads and writes the same context.
extension CaptureCoordinator {

    /// The office this booking will be filed under, or nil if the sheet has to
    /// ask. Never creates one.
    func matchedOffice(for booking: ParsedBooking) -> Office? {
        // Sorted, because a bare `FetchDescriptor` has no defined order and
        // every rule in `OfficeMatcher` is "exactly one, or nothing" — a rule
        // that has to look at all the candidates anyway should not have its
        // answer depend on which one SwiftData happened to hand back first.
        let offices = (try? context.fetch(
            FetchDescriptor<Office>(sortBy: [SortDescriptor(\.name)])
        )) ?? []
        let candidates = offices.map {
            OfficeMatcher.Candidate(
                id: $0.id, name: $0.name, postcode: $0.postcode, address: $0.address,
                aliases: $0.aliases
            )
        }
        guard let match = OfficeMatcher.match(booking.officeName, against: candidates) else {
            return nil
        }
        return offices.first { $0.id == match.id }
    }

    /// The site code the desks at this office open with: what the office has
    /// been told, or failing that what the desks it already holds say. See
    /// `Office.siteCode`.
    func siteCode(for officeID: UUID) -> String? {
        guard let office = office(officeID) else { return nil }
        if let code = office.siteCode { return code }
        let held = (try? context.fetch(FetchDescriptor<DeskBooking>())) ?? []
        return DeskID.site(sharedBy: held.filter { $0.officeID == officeID }.map(\.deskID))
    }

    /// The booking as it will be written under this office: the desk id's
    /// site code put right by the office's, when the office has one. No
    /// office yet, no correction — the sheet shows the id as read until it
    /// is told where the desk is.
    func filed(_ booking: ParsedBooking, under officeID: UUID?) -> ParsedBooking {
        guard let officeID else { return booking }
        return booking.filed(underSite: siteCode(for: officeID))
    }

    private func office(_ id: UUID) -> Office? {
        (try? context.fetch(FetchDescriptor<Office>()))?.first { $0.id == id }
    }

    /// The office has just been handed a desk whose id decodes, and did not
    /// know its site code. Now it does, and the next id filed here with
    /// those two letters misread is put right rather than kept.
    func learnSite(from deskID: String, for officeID: UUID) {
        guard let office = office(officeID), office.siteCode == nil,
              let desk = DeskID.parse(deskID), desk.isDecodable else { return }
        office.siteCode = desk.site
    }

    /// The sheet asked which office this printed name meant and was told. Next
    /// capture it will not ask.
    ///
    /// Taken off every other office on the way, because a building name means
    /// one building: leaving it on two would make both claim it, which the
    /// matcher reads as ambiguous and answers by asking again — the very thing
    /// this exists to stop. The newest answer is the one that stands.
    func remember(_ printed: String, as officeID: UUID) {
        let offices = (try? context.fetch(FetchDescriptor<Office>())) ?? []
        guard let target = offices.first(where: { $0.id == officeID }) else { return }

        for office in offices where office.id != officeID {
            office.aliases.removeAll { OfficeMatcher.matches(printed, $0) }
        }
        if !target.aliases.contains(where: { OfficeMatcher.matches(printed, $0) }) {
            target.aliases.append(printed)
        }
        // Not the booking, so not the error screen. The strip above and the
        // append are both pending on the context the booking is about to be
        // written through, so a save that fails here is usually flushed by that
        // one anyway — and when it is not, the booking's failure is the sentence
        // worth reading.
        write(.officeName(printed, officeID: target.id))
    }
}
