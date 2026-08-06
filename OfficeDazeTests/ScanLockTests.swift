import Foundation
import Testing
@testable import OfficeDaze

/// When the live scanner decides to fire.
///
/// The camera does not exist in the simulator, so this is the only half of
/// lock-on that can be verified here — but it is the half that decides whether
/// a model call is spent, and the half where firing on the wrong frame gets a
/// booking read off a badge or a parcel label.
@Suite("The scan lock")
struct ScanLockTests {

    /// A frame of the reservation page, close to what recognition hands back:
    /// separate blocks, joined with newlines.
    let page = """
        Reservation for CO03C117
        Location
        Buildings
        WRES1946519
        """

    // MARK: What counts as a desk id

    @Test("The reservation page's heading is a desk id")
    func readsTheHeading() {
        #expect(ScanLock.candidate(in: page) == "CO03C117")
    }

    @Test("A table row carries its own desk id and its status")
    func readsATableRow() {
        let row = "Wed 26 Aug   CO03A424   Confirmed   09:00 - 17:00"
        #expect(ScanLock.candidate(in: row) == "CO03A424")
    }

    /// The reservation number sits on the same page as the desk id and is the
    /// nearest thing to it in shape. Firing on one would file a booking for a
    /// desk that does not exist.
    @Test("A reservation number is not a desk id")
    func rejectsAReservationNumber() {
        #expect(ScanLock.candidate(in: "Reservation WRES1946519 Confirmed") == nil)
    }

    @Test("Neither a date nor a postcode nor a duration is a desk id", arguments: [
        "Booking 2026-08-25 09:00:00 CEST",
        "Building Coleman, London EC2R 8AH",
        "Confirmed duration 9 Hours",
    ])
    func rejectsTheRestOfThePage(_ text: String) {
        #expect(ScanLock.candidate(in: text) == nil)
    }

    /// The desk id has to be a token of its own. Without that the tail of a
    /// serial number qualifies, and a scanner with no shutter would fire on it
    /// unprompted.
    @Test("A desk id embedded in a longer token does not count")
    func rejectsPartOfALongerToken() {
        #expect(ScanLock.candidate(in: "Confirmed ref 998812CO03C117X4") == nil)
    }

    // MARK: What counts as a booking

    /// Eight characters in the right shape turn up on badges and parcels. The
    /// corroborating word is what makes the pair worth spending a call on.
    @Test("A desk id with nothing around it is not a booking")
    func requiresACorroboratingWord() {
        #expect(ScanLock.candidate(in: "CO03C117") == nil)
    }

    @Test("The corroborating word is read whatever its case")
    func ignoresCase() {
        #expect(ScanLock.candidate(in: "reservation for co03c117") == "CO03C117")
    }

    // MARK: Settling

    /// Firing on the first sharp frame fires mid-pan, on whatever the phone
    /// happened to be pointing through on the way.
    @Test("It fires only once the same desk id has held for three frames")
    func waitsForTheFrameToSettle() {
        var lock = ScanLock()
        #expect(lock.observe(page) == nil)
        #expect(lock.observe(page) == nil)
        #expect(lock.observe(page) == "CO03C117")
        #expect(lock.isLocked)
    }

    @Test("Panning onto a second desk id starts the count again")
    func aDifferentDeskIDRestartsTheCount() {
        var lock = ScanLock()
        _ = lock.observe(page)
        _ = lock.observe(page)
        #expect(lock.observe("Confirmed CO03A424") == nil)
        #expect(lock.observe("Confirmed CO03A424") == nil)
        #expect(lock.observe("Confirmed CO03A424") == "CO03A424")
    }

    @Test("Losing the booking mid-count starts it again")
    func anEmptyFrameRestartsTheCount() {
        var lock = ScanLock()
        _ = lock.observe(page)
        _ = lock.observe(page)
        #expect(lock.observe("Inbox   Calendar   Settings") == nil)
        #expect(lock.observe(page) == nil)
        #expect(lock.observe(page) == nil)
        #expect(lock.observe(page) == "CO03C117")
    }

    /// The debounce is that the caller is never told twice. Frames keep
    /// arriving while the photo is being taken, and each one would otherwise
    /// be another 0.4p.
    @Test("Once locked it says nothing more, however long the camera looks")
    func firesOnce() {
        var lock = ScanLock()
        _ = lock.observe(page)
        _ = lock.observe(page)
        #expect(lock.observe(page) == "CO03C117")

        for _ in 0..<10 {
            #expect(lock.observe(page) == nil)
        }
    }

    // MARK: Tapping instead of waiting

    /// The escape hatch from a document none of the cues match: without it the
    /// viewfinder never goes off and there is no way to make it.
    @Test("A tap fires whatever the camera is looking at")
    func aTapFires() {
        var lock = ScanLock()
        let fired = lock.lockNow()

        #expect(fired)
        #expect(lock.isLocked)
    }

    /// Frames keep arriving after the tap. Each one that fired would be
    /// another call on top of the one the tap already paid for.
    @Test("A tap mid-count stops the frames still arriving from firing too")
    func aTapSilencesTheFrames() {
        var lock = ScanLock()
        _ = lock.observe(page)
        _ = lock.observe(page)
        let fired = lock.lockNow()

        #expect(fired)
        #expect(lock.observe(page) == nil)
        #expect(lock.lockNow() == false)
    }

    @Test("A tap after the lock has already fired changes nothing")
    func aTapAfterTheLockIsIgnored() {
        var lock = ScanLock()
        for _ in 0..<3 { _ = lock.observe(page) }
        #expect(lock.lockNow() == false)
    }

    /// A dropped frame is not a failed capture. The scanner goes back to
    /// looking, and the lock has to be willing to fire again when it does.
    @Test("A reset lock can fire again")
    func resetsAfterAFailedCapture() {
        var lock = ScanLock()
        for _ in 0..<3 { _ = lock.observe(page) }
        lock.reset()

        #expect(lock.isLocked == false)
        #expect(lock.observe(page) == nil)
        #expect(lock.observe(page) == nil)
        #expect(lock.observe(page) == "CO03C117")
    }
}
