import CoreLocation
import Testing
@testable import OfficeDaze

// Only the query half is asserted here. `coordinates` reaches CLGeocoder, and
// a test that made a real geocode would be a test of Apple's servers and of
// the network the machine happens to be on. The one branch of `coordinates`
// that never reaches the network — the empty query — is asserted, because it
// is the branch that decides whether an office with no address gets a
// perimeter drawn around an arbitrary building.

@Suite("Geocoding a saved office")
struct GeocodingTests {

    @Test("Postcode and address are joined, postcode first")
    func bothParts() {
        #expect(
            Geocoding.query(postcode: "EC2R 5BB", address: "63 Coleman Street")
                == "EC2R 5BB, 63 Coleman Street"
        )
    }

    @Test("Either half on its own is a query, with no stray separator")
    func onePart() {
        #expect(Geocoding.query(postcode: "EC2R 5BB", address: "") == "EC2R 5BB")
        #expect(Geocoding.query(postcode: "", address: "63 Coleman Street") == "63 Coleman Street")
    }

    @Test("Surrounding whitespace is trimmed rather than sent")
    func trimming() {
        #expect(
            Geocoding.query(postcode: "  EC2R 5BB\n", address: "\t63 Coleman Street ")
                == "EC2R 5BB, 63 Coleman Street"
        )
    }

    @Test("An office with nothing to geocode produces no query")
    func nothingToAsk() {
        #expect(Geocoding.query(postcode: "", address: "") == nil)
        // The one that a naive `isEmpty` check on the joined string would let
        // through: whitespace-only fields join to ", ", which is not empty.
        #expect(Geocoding.query(postcode: "   ", address: "\n\t ") == nil)
    }

    @Test("A blank office never reaches the geocoder, and never gets coordinates")
    func blankOfficeIsNotLocated() async {
        // Returns at the guard, before CLGeocoder is constructed — so this
        // asserts the guard rather than the network. If the guard were dropped
        // this would either hang on a lookup or answer with a placemark.
        let point = await Geocoding.coordinates(postcode: "  ", address: "")
        #expect(point == nil)
    }
}
