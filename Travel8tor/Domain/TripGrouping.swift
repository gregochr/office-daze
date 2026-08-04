import Foundation

// MARK: - The contract
//
// The data-model document states the grouping rule in four lines:
//
//   1. Find the innermost existing Trip whose range covers the booking. If one
//      exists, attach and stop.
//   2. An outbound rail leg from home with no covering trip opens a Trip; the
//      first return leg toward home closes it.
//   3. A stay or rail leg in a city other than the covering Trip's primaryCity,
//      wholly inside its range, creates a child Trip.
//   4. Label from primaryCity + span.
//
// Rule 1 is wrong as written, and the document contradicts it three paragraphs
// later. The Thursday London hotel sits on 10.09; the Brussels leg spans
// 07–10.09 and therefore covers it; rule 1 says attach and stop, which files a
// London hotel inside the Brussels leg. The document's own worked example says
// the opposite — "the Thursday London hotel and Friday desk fall back to the
// parent, because no child covers them" — which means "covers" was never meant
// to be about dates alone.
//
// The rule that produces the documented answer:
//
//   Find the innermost trip whose range covers the booking, then walk up the
//   ancestor chain and attach to the first trip whose primaryCity matches the
//   booking's city. Date range selects the candidates; city picks among them.
//
// Rail legs have two cities, so they cannot be keyed on either alone. The
// outbound Eurostar (London → Brussels) must open the Brussels child; the
// return (Brussels → London) must join that same child and close it. Keying on
// the endpoint that is *not* the covering trip's city works for both:
//
//   - Outbound from London week (city London): far end is Brussels. Brussels is
//     neither home nor an ancestor's city, so it opens a child.
//   - Return, innermost cover now Brussels leg (city Brussels): far end is
//     London, which *is* an ancestor's city. So it is a homeward leg: it
//     attaches to the Brussels leg and closes it.
//   - Friday's LNER from London week: far end is Durham, which is home. Same
//     homeward branch, closing the parent.
//
// Everything here is user-overridable. Grouping is a convenience, not a truth.

/// The only facts about a trip the rule needs: where, when, and whose child.
nonisolated struct TripShape: Hashable, Sendable, Identifiable {
    let id: UUID
    let primaryCity: String
    let startsOn: Day
    /// `nil` means the trip is still open — no return leg has closed it yet, so
    /// it covers every day from `startsOn` onward.
    var endsOn: Day?
    let parentID: UUID?

    func covers(_ day: Day) -> Bool {
        guard day >= startsOn else { return false }
        guard let endsOn else { return true }
        return day <= endsOn
    }
}

/// A booking has either one city or two. Rail is the only two-city kind, and
/// that difference is what the rule turns on — so it lives in the type rather
/// than in an `if kind == .rail`.
nonisolated enum BookingGeography: Hashable, Sendable {
    case single(city: String)
    case journey(from: String, to: String)
}

/// The only facts about a booking the rule needs.
nonisolated struct BookingShape: Hashable, Sendable {
    let kind: BookingKind
    let geography: BookingGeography
    /// The day the booking is filed under: departure day for rail, the day
    /// itself for a desk, the first night for a stay. Deliberately not a span —
    /// a stay that runs past the end of its trip should still belong to it.
    let anchorDay: Day
}

/// What the rule decided. The caller performs it; the rule stays pure.
nonisolated enum GroupingOutcome: Hashable, Sendable {
    /// Attach to an existing trip and leave it open.
    case attach(tripID: UUID)
    /// Attach to a trip and close it on this day — a homeward leg.
    case attachAndClose(tripID: UUID, on: Day)
    /// No trip covered this booking: open a new top-level trip and attach to it.
    case openRootTrip(city: String, startsOn: Day)
    /// Open a child of an existing trip and attach to that child.
    case openChildTrip(parentID: UUID, city: String, startsOn: Day)
    /// Nothing sensible to attach to — a homeward leg with no open trip, say.
    case unattached
}

nonisolated enum TripGrouping {

    /// Decide where a booking belongs. Pure: same inputs, same answer, no store.
    static func classify(
        _ booking: BookingShape,
        among trips: [TripShape],
        homeCity: String
    ) -> GroupingOutcome {
        let chain = ancestorChain(covering: booking.anchorDay, in: trips)

        switch booking.geography {
        case .single(let city):
            return classifySingle(city: city, chain: chain, on: booking.anchorDay)
        case .journey(let from, let to):
            return classifyJourney(
                from: from, to: to, chain: chain,
                on: booking.anchorDay, homeCity: homeCity
            )
        }
    }

    // MARK: Single-city bookings — desks and stays

    private static func classifySingle(
        city: String,
        chain: [TripShape],
        on day: Day
    ) -> GroupingOutcome {
        // The sharpened rule: date range selects candidates, city picks among
        // them. This is the line that sends the Thursday London hotel to the
        // London week rather than the Brussels leg it sits inside.
        if let match = chain.first(where: { $0.primaryCity == city }) {
            return .attach(tripID: match.id)
        }

        guard let innermost = chain.first else {
            // A desk or stay with no covering trip is just a day out; it does
            // not open a trip. Only rail does that.
            return .unattached
        }

        // A city nobody in the chain matches: it deserves a child. But the
        // document is explicit that one level of nesting is enough — so if the
        // innermost cover is already a child, attach there rather than nest
        // deeper.
        if innermost.parentID != nil {
            return .attach(tripID: innermost.id)
        }
        return .openChildTrip(parentID: innermost.id, city: city, startsOn: day)
    }

    // MARK: Rail legs

    private static func classifyJourney(
        from: String,
        to: String,
        chain: [TripShape],
        on day: Day,
        homeCity: String
    ) -> GroupingOutcome {
        guard let innermost = chain.first else {
            // Rule 2: an outbound leg from home opens a trip, named for where
            // it is going.
            if from == homeCity {
                return .openRootTrip(city: to, startsOn: day)
            }
            // Homeward, or between two other cities, with nothing open to join.
            return .unattached
        }

        // The far end: the endpoint that isn't where we already are.
        let far: String
        if from == innermost.primaryCity && to == innermost.primaryCity {
            return .attach(tripID: innermost.id) // a local hop
        } else if from == innermost.primaryCity {
            far = to
        } else if to == innermost.primaryCity {
            far = from
        } else {
            // Neither end is the covering trip's city. Treat where it is going
            // as the far end and let the checks below decide.
            far = to
        }

        // Heading home, or back to an ancestor's city, closes the current trip.
        let ancestorCities = chain.dropFirst().map(\.primaryCity)
        if far == homeCity || ancestorCities.contains(far) {
            return .attachAndClose(tripID: innermost.id, on: day)
        }

        if innermost.parentID != nil {
            return .attach(tripID: innermost.id) // one level only
        }
        return .openChildTrip(parentID: innermost.id, city: far, startsOn: day)
    }

    // MARK: Chain construction

    /// Trips covering `day`, innermost first, then its parent, and so on.
    static func ancestorChain(covering day: Day, in trips: [TripShape]) -> [TripShape] {
        let byID = Dictionary(uniqueKeysWithValues: trips.map { ($0.id, $0) })

        func depth(_ trip: TripShape) -> Int {
            var d = 0
            var current = trip
            while let parentID = current.parentID, let parent = byID[parentID] {
                d += 1
                current = parent
            }
            return d
        }

        let covering = trips.filter { $0.covers(day) }
        // Deepest wins; on a tie the later-starting trip is the more specific.
        guard let innermost = covering.max(by: { a, b in
            (depth(a), a.startsOn) < (depth(b), b.startsOn)
        }) else { return [] }

        var chain: [TripShape] = [innermost]
        var current = innermost
        while let parentID = current.parentID, let parent = byID[parentID] {
            chain.append(parent)
            current = parent
        }
        return chain
    }
}
