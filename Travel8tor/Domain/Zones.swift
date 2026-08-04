import Foundation

/// Cities to IANA time zones.
///
/// A `.pkpass` carries a UTC offset on its dates, never a zone identifier — and
/// an offset is not a zone: `+01:00` is London in summer and Brussels in
/// winter. Where the city is known, the identifier is better than the offset,
/// because only the identifier survives a DST boundary.
///
/// The fallback is the offset the pass supplied. It renders correctly for that
/// instant, which is what the ticket screen shows.
nonisolated enum Zones {

    static let byCity: [String: String] = [
        "durham": "Europe/London",
        "london": "Europe/London",
        "newcastle": "Europe/London",
        "edinburgh": "Europe/London",
        "brussels": "Europe/Brussels",
        "bruxelles": "Europe/Brussels",
        "amsterdam": "Europe/Amsterdam",
        "paris": "Europe/Paris",
        "lille": "Europe/Paris",
        "rotterdam": "Europe/Amsterdam",
        "cologne": "Europe/Berlin",
        "frankfurt": "Europe/Berlin",
        "dublin": "Europe/Dublin",
    ]

    static func timeZone(forCity city: String) -> TimeZone? {
        byCity[city.lowercased()].flatMap(TimeZone.init(identifier:))
    }

    /// The zone to file an event under: the city's zone where known, else the
    /// fixed offset the source supplied, else UK.
    static func resolve(city: String?, offsetSeconds: Int?) -> TimeZone {
        if let city, let known = timeZone(forCity: city) { return known }
        if let offsetSeconds, let fixed = TimeZone(secondsFromGMT: offsetSeconds) { return fixed }
        return TimeDisplay.uk
    }

    /// Best-effort city for a station name, used when a pass names stations but
    /// not cities.
    static func city(forStation station: String) -> String? {
        let name = station.lowercased()
        for (city, _) in byCity where name.contains(city) { return city.capitalized }
        // Station names that don't contain their city.
        let stations: [String: String] = [
            "king's cross": "London", "kings cross": "London", "kgx": "London",
            "st pancras": "London", "stp": "London", "euston": "London",
            "paddington": "London", "waterloo": "London", "liverpool street": "London",
            "midi": "Brussels", "zuid": "Brussels",
            "gare du nord": "Paris", "nord": "Paris",
            "centraal": "Amsterdam",
        ]
        for (needle, city) in stations where name.contains(needle) { return city }
        return nil
    }
}
