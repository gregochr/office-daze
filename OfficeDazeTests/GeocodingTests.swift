import CoreLocation
import MapKit
import Testing
@testable import OfficeDaze

// Only the query half is asserted here. `coordinates` reaches MapKit, and a
// test that made a real geocode would be a test of Apple's servers and of the
// network the machine happens to be on. The branches of `coordinates` that
// never reach the network are asserted, because they are the ones that decide
// whether an office with no usable address gets a perimeter drawn around an
// arbitrary building.

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
        // Returns at the guard, before a request is built — so this asserts the
        // guard rather than the network. If the guard were dropped this would
        // either hang on a lookup or answer with a placemark.
        let point = await Geocoding.coordinates(postcode: "  ", address: "")
        #expect(point == nil)
    }

    // The lookup moved from `CLGeocoder.geocodeAddressString`, deprecated in
    // iOS 26, to MapKit's `MKGeocodingRequest`. The two tests below cover the
    // part of that swap that can be checked without a network: MapKit now gets
    // a say in whether the query is even askable, via a failable initialiser
    // that `CLGeocoder` had no equivalent of. What comes back from Apple for a
    // given postcode is still deliberately unasserted — that would be a test of
    // Apple's servers and of whatever network this machine is on.

    @Test("Every query a real office produces is one MapKit will accept")
    func realQueriesBuildRequests() throws {
        // The new nil branch, from the other side. If `MKGeocodingRequest`
        // refused these, offices would stop being located with no error and no
        // request made, and the only symptom would be an alert that never
        // fires. Both fields, and each on its own, because the editor lets an
        // office be saved with either half missing.
        let queries = [
            Geocoding.query(postcode: "EC2R 5BB", address: "63 Coleman Street"),
            Geocoding.query(postcode: "EC2R 5BB", address: ""),
            Geocoding.query(postcode: "", address: "63 Coleman Street"),
            Geocoding.query(postcode: "M2 3AA", address: "Ship Canal House, King Street"),
        ]
        for query in queries {
            let asked = try #require(query)
            #expect(MKGeocodingRequest(addressString: asked) != nil)
        }
    }

    @Test("The string MapKit is asked for is the trimmed, postcode-first one")
    func requestCarriesTheQuery() throws {
        // `addressString` is readable back off the request, so the one thing a
        // caller cannot otherwise see — which string actually reaches Apple —
        // is pinned here. Postcode first is not cosmetic: Apple resolves the
        // pair better in that order, and a request built from the raw fields
        // would carry the user's stray whitespace with it.
        let query = try #require(Geocoding.query(postcode: " EC2R 5BB ", address: "63 Coleman Street\n"))
        let request = try #require(MKGeocodingRequest(addressString: query))
        #expect(request.addressString == "EC2R 5BB, 63 Coleman Street")
    }
}
