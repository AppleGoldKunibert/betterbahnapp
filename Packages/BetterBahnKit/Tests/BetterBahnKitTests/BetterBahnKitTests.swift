import Foundation
import Testing
@testable import BetterBahnKit

func fixture<T: Decodable>(_ name: String, as type: T.Type) throws -> T {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try JSONDecoding.decoder.decode(T.self, from: Data(contentsOf: url))
}

func station(_ id: String, _ name: String, _ lat: Double? = nil, _ lon: Double? = nil, source: DataSource = .bahnDe) -> Station {
    Station(id: id, name: name, coordinate: lat.flatMap { lat in lon.map { Coordinate(latitude: lat, longitude: $0) } },
            evaNumber: source == .bahnDe ? id : nil, source: source)
}

// MARK: - Transitous mapping

@Suite struct TransitousMappingTests {
    @Test func stopTimes() throws {
        let response = try fixture("transitous-stoptimes", as: MStopTimesResponse.self)
        let entries = response.stopTimes.compactMap { $0.toEntry(kind: .departures) }
        #expect(entries.count == 3)
        let first = try #require(entries.first)
        #expect(first.line.name == "RB25 (10574)" || first.line.product == .regional)
        #expect(first.source == .transitous)
    }

    /// Real-world Transitous geocode response for "Berlin Gesundbrunnen": the DELFI feed's entry
    /// covers every product including the U8 subway, while a second, OpenOV-fed entry ~70m away
    /// covers almost the same products but misses the subway – and its `/v5/stoptimes` happens to
    /// return only a single bus line for that ID. Left undeduplicated, both show up as separate,
    /// near-identically-named suggestions in the station picker, and picking the second one leaves
    /// the board looking almost empty. Only the more complete one should survive.
    @Test func searchStationsMergesSameStationAcrossFeeds() {
        let complete = MGeocodeMatch(type: "STOP", name: "S+U Gesundbrunnen Bhf (Berlin)",
                                     id: "de-DELFI_de:11000:900007102", lat: 52.548637, lon: 13.388372,
                                     country: "DE", modes: ["HIGHSPEED_RAIL", "LONG_DISTANCE", "REGIONAL_RAIL", "SUBURBAN", "SUBWAY", "BUS"])
        let partial = MGeocodeMatch(type: "STOP", name: "Berlin Gesundbrunnen",
                                    id: "nl-OpenOV_stoparea:489941", lat: 52.548610, lon: 13.389444,
                                    country: "DE", modes: ["HIGHSPEED_RAIL", "LONG_DISTANCE", "NIGHT_RAIL", "REGIONAL_RAIL", "BUS"])
        let farAway = MGeocodeMatch(type: "STOP", name: "Rügener Str. (Berlin)",
                                    id: "de-VBB_de:11000:900007157::1", lat: 52.545128, lon: 13.390834,
                                    country: "DE", modes: ["BUS"])

        let merged = TransitousProvider.mergingNearbyDuplicates([complete, partial, farAway])

        #expect(merged.map(\.id) == [complete.id, farAway.id])
    }

    /// German train stations first, then the listed neighbours' train stations (AT, CH, NL, PL, CZ,
    /// in that order), then German buses, then German U-Bahn, then everything else.
    @Test func searchRankOrdersByCountryAndMode() {
        func match(_ id: String, country: String, modes: [String]) -> MGeocodeMatch {
            MGeocodeMatch(type: "STOP", name: id, id: id, lat: 0, lon: 0, country: country, modes: modes)
        }
        let deTrain = match("deTrain", country: "DE", modes: ["REGIONAL_RAIL"])
        let atTrain = match("atTrain", country: "AT", modes: ["REGIONAL_RAIL"])
        let chTrain = match("chTrain", country: "CH", modes: ["REGIONAL_RAIL"])
        let nlTrain = match("nlTrain", country: "NL", modes: ["REGIONAL_RAIL"])
        let plTrain = match("plTrain", country: "PL", modes: ["REGIONAL_RAIL"])
        let czTrain = match("czTrain", country: "CZ", modes: ["REGIONAL_RAIL"])
        let deBus = match("deBus", country: "DE", modes: ["BUS"])
        let deSubway = match("deSubway", country: "DE", modes: ["SUBWAY"])
        let frTram = match("frTram", country: "FR", modes: ["TRAM"])

        let shuffled = [frTram, deSubway, czTrain, deBus, nlTrain, atTrain, deTrain, plTrain, chTrain]
        let ranked = shuffled.enumerated()
            .sorted { TransitousProvider.searchRank($0.element, query: "x", offset: $0.offset)
                    > TransitousProvider.searchRank($1.element, query: "x", offset: $1.offset) }
            .map(\.element.id)

        #expect(ranked == ["deTrain", "atTrain", "chTrain", "nlTrain", "plTrain", "czTrain", "deBus", "deSubway", "frTram"])
    }

    /// An exact name match jumps to the very top, but only for Germany or a listed neighbour, with
    /// Germany still winning over the neighbour when both match exactly – a German bus stop named
    /// exactly like the query should still outrank a same-named Austrian train station.
    @Test func searchRankPrefersExactMatchFromPriorityCountries() {
        func match(_ id: String, name: String, country: String, modes: [String]) -> MGeocodeMatch {
            MGeocodeMatch(type: "STOP", name: name, id: id, lat: 0, lon: 0, country: country, modes: modes)
        }
        let exactDeBus = match("exactDeBus", name: "Berlin Hbf", country: "DE", modes: ["BUS"])
        let exactAtTrain = match("exactAtTrain", name: "Berlin Hbf", country: "AT", modes: ["REGIONAL_RAIL"])
        let exactFrTrain = match("exactFrTrain", name: "Berlin Hbf", country: "FR", modes: ["REGIONAL_RAIL"])
        let plainDeTrain = match("plainDeTrain", name: "Berlin Ostkreuz", country: "DE", modes: ["REGIONAL_RAIL"])

        let shuffled = [exactFrTrain, plainDeTrain, exactAtTrain, exactDeBus]
        let ranked = shuffled.enumerated()
            .sorted { TransitousProvider.searchRank($0.element, query: "Berlin Hbf", offset: $0.offset)
                    > TransitousProvider.searchRank($1.element, query: "Berlin Hbf", offset: $1.offset) }
            .map(\.element.id)

        // Exact matches from Germany/neighbours beat everything else, Germany first among them;
        // the exact match from France (not a listed country) doesn't get the boost.
        #expect(ranked == ["exactDeBus", "exactAtTrain", "plainDeTrain", "exactFrTrain"])
    }

    /// Regression: the exact-match bonus must key off the cleaned display name, not each feed's raw
    /// spelling – otherwise, for the very cluster `mergingNearbyDuplicates` exists to collapse, whichever
    /// feed's raw formatting happens to read like plain "<City> <Stop>" wins the exact-match tier over
    /// a more complete sibling just because its raw name still carries "S+U "/" Bhf (…)" formatting,
    /// undoing the completeness-based pick for real stations like Berlin Gesundbrunnen.
    @Test func searchRankExactMatchUsesDisplayNameNotRawFeedName() {
        let complete = MGeocodeMatch(type: "STOP", name: "S+U Gesundbrunnen Bhf (Berlin)", id: "de-DELFI",
                                     lat: 52.548637, lon: 13.388372, country: "DE",
                                     modes: ["HIGHSPEED_RAIL", "LONG_DISTANCE", "REGIONAL_RAIL", "SUBURBAN", "SUBWAY", "BUS"])
        let partial = MGeocodeMatch(type: "STOP", name: "Berlin Gesundbrunnen", id: "nl-OpenOV",
                                    lat: 52.548610, lon: 13.389444, country: "DE",
                                    modes: ["HIGHSPEED_RAIL", "LONG_DISTANCE", "NIGHT_RAIL", "REGIONAL_RAIL", "BUS"])

        let ranked = [partial, complete].enumerated()
            .sorted { TransitousProvider.searchRank($0.element, query: "Berlin Gesundbrunnen", offset: $0.offset)
                    > TransitousProvider.searchRank($1.element, query: "Berlin Gesundbrunnen", offset: $1.offset) }
            .map(\.element.id)

        #expect(ranked == [complete.id, partial.id])
    }

    /// Some feeds (e.g. European rail interoperability reference data) carry an all-caps, umlaut-free
    /// alias for a station alongside its properly written local name, and the geocoder can echo back
    /// either one depending on which alias matched the query text – confirmed live for "München Hbf"
    /// (typed as ASCII "Muenchen Hbf", the API answers "MUENCHEN HBF") and "Berlin Südkreuz" (typed as
    /// "Suedkreuz", it answers "Berlin Suedkreuz"). Prefer the properly written variant either way.
    @Test func isBetterNamePrefersProperlyWrittenVariant() {
        #expect(TransitousProvider.isBetterName("München Hbf", than: "MUENCHEN HBF"))
        #expect(!TransitousProvider.isBetterName("MUENCHEN HBF", than: "München Hbf"))
        #expect(TransitousProvider.isBetterName("Berlin Südkreuz", than: "Berlin Suedkreuz"))
        #expect(!TransitousProvider.isBetterName("Berlin Suedkreuz", than: "Berlin Südkreuz"))
        // Unrelated names never get swapped just because one happens to be prettier.
        #expect(!TransitousProvider.isBetterName("Frankfurt Hbf", than: "Berlin Hbf"))
        #expect(!TransitousProvider.isBetterName("Berlin Hbf", than: "Berlin Hbf"))
    }

    /// A cross-border ICE/Railjet (Munich–Bologna) is listed twice: Deutsche Bahn's own feed only
    /// models it up to the border and calls it "Kufstein" (matching its own last stop), while ÖBB's
    /// feed for the identical physical train correctly keeps "Bologna" as the headsign. The merge
    /// should keep the row that names the real destination, not the one stuck at the border.
    @Test func stopTimesMergeBorderSplitDuplicate() throws {
        let json = """
        {"stopTimes": [
            {"place": {"name": "München Hbf", "stopId": "at:1", "lat": 48.14, "lon": 11.56,
                       "scheduledDeparture": "2026-09-18T11:22:00Z"},
             "mode": "HIGHSPEED_RAIL", "headsign": "Bologna, Stazione di Bologna Centrale",
             "tripFrom": {"name": "München Hbf", "lat": 48.14, "lon": 11.56},
             "tripTo": {"name": "Kufstein Bahnhof", "lat": 47.58, "lon": 12.16},
             "tripId": "at-trip", "displayName": "RJ 87", "agencyName": "Deutsche Bahn AG"},
            {"place": {"name": "München Hbf", "stopId": "de:1", "lat": 48.14, "lon": 11.56,
                       "scheduledDeparture": "2026-09-18T11:22:00Z"},
             "mode": "HIGHSPEED_RAIL", "headsign": "Kufstein",
             "tripFrom": {"name": "München Hbf", "lat": 48.14, "lon": 11.56},
             "tripTo": {"name": "Kufstein", "lat": 47.58, "lon": 12.16},
             "tripId": "de-trip", "displayName": "ICE 87", "agencyName": "DB Fernverkehr AG"}
        ]}
        """
        let response = try JSONDecoding.decoder.decode(MStopTimesResponse.self, from: Data(json.utf8))
        let merged = TransitousProvider.mergeBorderSplitDuplicates(response.stopTimes, kind: .departures)
        #expect(merged.count == 1)
        #expect(merged.first?.tripId == "at-trip")
        let entries = merged.compactMap { $0.toEntry(kind: .departures) }
        #expect(entries.first?.otherEnd == "Bologna, Stazione di Bologna Centrale")
    }

    /// Two genuinely different trains sharing a number by coincidence (or two rows that both/neither
    /// know a continuation) must not be merged away.
    @Test func stopTimesKeepsAmbiguousOrDistinctRows() throws {
        let json = """
        {"stopTimes": [
            {"place": {"name": "München Hbf", "stopId": "a:1", "lat": 48.14, "lon": 11.56,
                       "scheduledDeparture": "2026-09-18T11:22:00Z"},
             "mode": "HIGHSPEED_RAIL", "headsign": "Kufstein",
             "tripTo": {"name": "Kufstein", "lat": 47.58, "lon": 12.16},
             "tripId": "a", "displayName": "ICE 87", "agencyName": "DB Fernverkehr AG"},
            {"place": {"name": "München Hbf", "stopId": "b:1", "lat": 48.14, "lon": 11.56,
                       "scheduledDeparture": "2026-09-18T12:22:00Z"},
             "mode": "HIGHSPEED_RAIL", "headsign": "Kufstein",
             "tripTo": {"name": "Kufstein", "lat": 47.58, "lon": 12.16},
             "tripId": "b", "displayName": "ICE 87", "agencyName": "DB Fernverkehr AG"}
        ]}
        """
        let response = try JSONDecoding.decoder.decode(MStopTimesResponse.self, from: Data(json.utf8))
        let merged = TransitousProvider.mergeBorderSplitDuplicates(response.stopTimes, kind: .departures)
        #expect(merged.count == 2)
    }

    /// A single stitched itinerary leg (München–Innsbruck) riding the German feed's border-truncated
    /// trip still reaches the real destination as its `to`, but the trip's own `headsign` only names
    /// the border stop, which then shows up as one of this same leg's intermediate stops. The leg's
    /// direction should read the true destination, not the stop it already passes through.
    @Test func legDirectionIgnoresHeadsignThatIsJustAnIntermediateStop() throws {
        let json = """
        {"mode": "HIGHSPEED_RAIL",
         "from": {"name": "München Ostbahnhof", "lat": 48.13, "lon": 11.6},
         "to": {"name": "Innsbruck Hauptbahnhof", "lat": 47.26, "lon": 11.4},
         "startTime": "2026-09-17T11:55:00Z", "endTime": "2026-09-17T13:31:00Z",
         "headsign": "Kufstein", "tripId": "de-trip", "displayName": "ICE 87",
         "intermediateStops": [
            {"name": "Rosenheim", "lat": 47.85, "lon": 12.13},
            {"name": "Kufstein", "lat": 47.58, "lon": 12.16},
            {"name": "Wörgl Hbf", "lat": 47.48, "lon": 12.06}
         ]}
        """
        let leg = try JSONDecoding.decoder.decode(MLeg.self, from: Data(json.utf8)).toLeg()
        #expect(leg.destination.name == "Innsbruck Hauptbahnhof")
        #expect(leg.direction == "Innsbruck Hauptbahnhof")
    }

    /// A leg that genuinely terminates where its headsign says must keep that headsign as-is.
    @Test func legDirectionKeepsHeadsignMatchingRealDestination() throws {
        let json = """
        {"mode": "HIGHSPEED_RAIL",
         "from": {"name": "München Hbf", "lat": 48.14, "lon": 11.56},
         "to": {"name": "Kufstein", "lat": 47.58, "lon": 12.16},
         "startTime": "2026-09-17T11:22:00Z", "endTime": "2026-09-17T13:07:00Z",
         "headsign": "Kufstein", "tripId": "de-trip", "displayName": "ICE 87",
         "intermediateStops": [{"name": "Rosenheim", "lat": 47.85, "lon": 12.13}]}
        """
        let leg = try JSONDecoding.decoder.decode(MLeg.self, from: Data(json.utf8)).toLeg()
        #expect(leg.direction == "Kufstein")
    }

    @Test func plan() throws {
        let response = try fixture("transitous-plan", as: MPlanResponse.self)
        let journey = Journey(legs: try #require(response.itineraries.first).legs.map { $0.toLeg() }, source: .transitous)
        let transit = journey.transitLegs
        #expect(transit.count == 2)
        #expect(transit[0].line?.name == "ICE 224")
        #expect(transit[0].line?.number == "224")
        #expect(transit[0].line?.product == .highSpeed)
        #expect(transit[0].departure.delayMinutes == 40)
        #expect(transit[0].stopovers.count >= 3)
        #expect(response.nextPageCursor != nil)
    }

    @Test func trip() throws {
        let itinerary = try fixture("transitous-trip", as: MItinerary.self)
        let leg = try #require(itinerary.legs.first).toLeg()
        #expect(leg.origin.name == "München Hbf")
        #expect(leg.stopovers.count == 14)
    }
}

// MARK: - Station display names

@Suite struct StationDisplayNameTests {
    /// The same physical station reaches `Station.name` in several raw forms depending on which
    /// feed/provider produced it – they should all read the same to the user.
    @Test func sameStationReadsIdenticallyAcrossRawNameForms() {
        let forms = ["S+U Gesundbrunnen Bhf (Berlin)", "Berlin Gesundbrunnen", "S Gesundbrunnen Bhf (Berlin)"]
        let displayNames = Set(forms.map(Station.displayName(for:)))
        #expect(displayNames == ["Berlin Gesundbrunnen"])
    }

    @Test func stripsProductPrefixAndReordersCityStop() {
        #expect(Station.displayName(for: "S+U Berlin Hauptbahnhof") == "Berlin Hbf")
        #expect(Station.displayName(for: "S Spandau Bhf (Berlin)") == "Berlin-Spandau")
    }
}

// MARK: - Rules & filters

@Suite struct RulesTests {
    let ice = Line(name: "ICE 423", number: "423", product: .highSpeed, operatorName: "DB Fernverkehr AG")
    let flix = Line(name: "FLX 1245", number: "1245", product: .longDistance, operatorName: "FlixTrain")
    let flixNoOperator = Line(name: "FLX 30", number: "30", product: .longDistance, operatorName: nil)
    let regio = Line(name: "RE 6", number: nil, product: .regionalExpress, operatorName: "National Express")
    let coach = Line(name: "FlixBus N123", number: nil, product: .coach, operatorName: "FlixBus")
    let sleeper = Line(name: "ES 453", number: "453", product: .longDistance, operatorName: "European Sleeper")

    @Test func bc100() {
        let rules = BC100Rules.default
        #expect(rules.isValid(ice))
        #expect(rules.isValid(regio))
        #expect(!rules.isValid(flix))
        #expect(!rules.isValid(flixNoOperator))
        #expect(!rules.isValid(coach))
        #expect(!rules.isValid(sleeper))
    }

    func entry(_ line: Line, kind: BoardKind = .departures, otherEnd: String = "Berlin Hbf", terminal: Bool? = false) -> BoardEntry {
        BoardEntry(kind: kind, tripId: UUID().uuidString, station: station("8000207", "Köln Hbf"), line: line,
                   otherEnd: otherEnd, time: TimeInfo(planned: .now, actual: nil),
                   platform: PlatformInfo(planned: "1", actual: nil), cancelled: false,
                   terminatesOrOriginatesHere: terminal, remarks: [], source: .bahnDe)
    }

    @Test func boardKeepsPassingTrainsAndDropsTerminating() {
        let filter = BoardFilter()
        #expect(filter.includes(entry(ice)))
        #expect(filter.includes(entry(ice, terminal: nil)))
        #expect(!filter.includes(entry(ice, otherEnd: "Köln Hbf", terminal: true)))
        #expect(!filter.includes(entry(ice, kind: .arrivals, otherEnd: "Köln Hbf", terminal: true)))
    }

    @Test func boardProductsAndBC100() {
        let filter = BoardFilter(products: [.highSpeed, .longDistance], bc100Rules: .default)
        #expect(filter.includes(entry(ice)))
        #expect(!filter.includes(entry(flix)))
        #expect(!filter.includes(entry(regio)))
    }

    @Test func pkceMatchesRFC7636() {
        #expect(PKCE.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk") == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        #expect(PKCE().verifier.count == 64)
    }

    @Test func lineNormalize() {
        #expect(Line.normalize("ICE  423") == Line.normalize("ice423"))
    }
}

// MARK: - Providers with mocks

final class MockProvider: TransitProvider, @unchecked Sendable {
    let source: DataSource
    var failing = false
    var boards: [BoardEntry] = []
    var trips: [String: Trip] = [:]
    var journeyPages: [JourneyPage] = []
    var calls: [String] = []
    var receivedCursors: [String?] = []
    private let lock = NSLock()

    init(source: DataSource) { self.source = source }

    private func record(_ call: String) throws {
        lock.withLock { calls.append(call) }
        if failing { throw TransitError.http(status: 503, body: nil) }
    }

    func searchStations(_ query: String) async throws -> [Station] {
        try record("search")
        return [station("1", query, source: source)]
    }

    func journeys(_ query: JourneyQuery) async throws -> JourneyPage {
        try record("journeys")
        lock.withLock { receivedCursors.append(query.cursor) }
        return journeyPages.first ?? JourneyPage(journeys: [], earlierCursor: nil, laterCursor: nil, source: source)
    }

    func board(_ kind: BoardKind, at station: Station, date: Date, duration: Int, products: Set<Product>) async throws -> [BoardEntry] {
        try record("board")
        return boards
    }

    func trip(id: String) async throws -> Trip {
        try record("trip")
        guard let trip = trips[id] else { throw TransitError.notFound(id) }
        return trip
    }
}

@Suite struct CombinedProviderTests {
    @Test func fallsBackAndCoolsDown() async throws {
        let primary = MockProvider(source: .bahnDe)
        primary.failing = true
        let fallback = MockProvider(source: .transitous)
        let combined = CombinedProvider(primary: primary, fallback: fallback, bahnDe: nil, cooldown: 60)

        let first = try await combined.searchStations("Köln")
        #expect(first.first?.source == .transitous)
        _ = try await combined.searchStations("Köln")
        // Second call skips the failing primary during cooldown.
        #expect(primary.calls.count == 1)
        #expect(fallback.calls.count == 2)
    }

    @Test func usesPrimaryWhenHealthy() async throws {
        let primary = MockProvider(source: .bahnDe)
        let fallback = MockProvider(source: .transitous)
        let combined = CombinedProvider(primary: primary, fallback: fallback, bahnDe: nil)
        let result = try await combined.searchStations("Köln")
        #expect(result.first?.source == .bahnDe)
        #expect(fallback.calls.isEmpty)
    }

    @Test func cursorPrefix() {
        #expect(CombinedProvider.cursorSource("transitous:abc") == .transitous)
        #expect(CombinedProvider.stripCursor("dbRest:laterThan=x", source: .dbRest) == "laterThan=x")
        #expect(CombinedProvider.stripCursor("dbRest:laterThan=x", source: .transitous) == nil)
    }
}

@Suite struct TrainPickerTests {
    let koeln = station("8000207", "Köln Hbf", 50.943, 6.958)
    let duesseldorf = station("8000085", "Düsseldorf Hbf", 51.219, 6.794)
    let berlin = station("8011160", "Berlin Hbf", 52.525, 13.369)
    let base = Date(timeIntervalSince1970: 1_800_000_000)

    func stop(_ s: Station, arr: Double?, dep: Double?, access: StopAccess = .normal) -> Stopover {
        Stopover(station: s, arrival: arr.map { TimeInfo(planned: base.addingTimeInterval($0 * 60), actual: nil) },
                 departure: dep.map { TimeInfo(planned: base.addingTimeInterval($0 * 60), actual: nil) },
                 arrivalPlatform: nil, departurePlatform: nil, cancelled: false, access: access)
    }

    func trip(_ id: String, _ name: String, _ stops: [Stopover]) -> Trip {
        Trip(id: id, line: Line(name: name, number: String(name.split(separator: " ").last!), product: .highSpeed, operatorName: "DB Fernverkehr AG"),
             direction: "Berlin Hbf", stopovers: stops, cancelled: false, remarks: [], source: .bahnDe)
    }

    func boardEntry(_ trip: Trip, minutes: Double) -> BoardEntry {
        BoardEntry(kind: .departures, tripId: trip.id, station: koeln, line: trip.line!, otherEnd: "Berlin Hbf",
                   time: TimeInfo(planned: base.addingTimeInterval(minutes * 60), actual: nil),
                   platform: PlatformInfo(planned: nil, actual: nil), cancelled: false,
                   terminatesOrOriginatesHere: false, remarks: [], source: .bahnDe)
    }

    func makePicker() -> (TrainPicker, Trip, Trip) {
        let fast = trip("ice1", "ICE 1", [stop(koeln, arr: nil, dep: 0), stop(berlin, arr: 240, dep: nil)])
        let slow = trip("ice423", "ICE 423", [stop(koeln, arr: nil, dep: 10), stop(duesseldorf, arr: 30, dep: 32), stop(berlin, arr: 290, dep: nil)])
        let other = trip("ice999", "ICE 999", [stop(koeln, arr: nil, dep: 20), stop(duesseldorf, arr: 40, dep: nil)])
        let primary = MockProvider(source: .bahnDe)
        primary.boards = [boardEntry(fast, minutes: 0), boardEntry(slow, minutes: 10), boardEntry(other, minutes: 20)]
        primary.trips = ["ice1": fast, "ice423": slow, "ice999": other]
        let provider = CombinedProvider(primary: primary, fallback: MockProvider(source: .transitous), bahnDe: nil)
        return (TrainPicker(provider: provider), fast, slow)
    }

    @Test func alternativesOnlyIncludeTrainsReachingDestination() async throws {
        let (picker, fast, _) = makePicker()
        let leg = try #require(fast.leg(from: koeln, to: berlin))
        let alternatives = try await picker.alternatives(for: leg)
        #expect(alternatives.map { $0.line?.name } == ["ICE 423"])
    }

    @Test func forceTrainByName() async throws {
        let (picker, _, _) = makePicker()
        let match = try await picker.journey(withTrain: "ice423", from: koeln, to: berlin, date: base)
        #expect(match.journey.legs.count == 1)
        #expect(match.journey.legs[0].line?.name == "ICE 423")
        #expect(match.breaksBoardingRules == false)
        #expect(match.alternative == nil)
        let byNumber = try await picker.journey(withTrain: "423", from: koeln, to: berlin, date: base)
        #expect(byNumber.journey.legs[0].tripId == "ice423")
        await #expect(throws: TransitError.self) {
            try await picker.journey(withTrain: "ICE 999", from: koeln, to: berlin, date: base)
        }
    }

    @Test func forceTrainIgnoresBoardingRestrictionAndOffersAlternative() async throws {
        let restricted = trip("ice777", "ICE 777", [
            stop(koeln, arr: nil, dep: 0, access: .exitOnly),
            stop(berlin, arr: 240, dep: nil),
        ])
        let primary = MockProvider(source: .bahnDe)
        primary.boards = [BoardEntry(kind: .departures, tripId: restricted.id, station: koeln, line: restricted.line!,
                                     otherEnd: "Berlin Hbf", time: TimeInfo(planned: base, actual: nil),
                                     platform: PlatformInfo(planned: nil, actual: nil), cancelled: false,
                                     terminatesOrOriginatesHere: false, remarks: [], access: .exitOnly, source: .bahnDe)]
        primary.trips = ["ice777": restricted]
        let legalTrip = trip("re1", "RE 1", [stop(koeln, arr: nil, dep: 5), stop(berlin, arr: 260, dep: nil)])
        primary.journeyPages = [JourneyPage(journeys: [Journey(legs: [try #require(legalTrip.leg(from: koeln, to: berlin))], source: .bahnDe)],
                                            earlierCursor: nil, laterCursor: nil, source: .bahnDe)]
        let provider = CombinedProvider(primary: primary, fallback: MockProvider(source: .transitous), bahnDe: nil)
        let picker = TrainPicker(provider: provider)

        let match = try await picker.journey(withTrain: "ICE 777", from: koeln, to: berlin, date: base)
        #expect(match.journey.legs[0].tripId == "ice777")
        #expect(match.breaksBoardingRules == true)
        #expect(match.alternative?.legs.first?.line?.name == "RE 1")
    }

    @Test func replaceLastLeg() async throws {
        let (picker, fast, slow) = makePicker()
        let journey = Journey(legs: [try #require(fast.leg(from: koeln, to: berlin))], source: .bahnDe)
        let newLeg = try #require(slow.leg(from: koeln, to: berlin))
        let replaced = try await picker.replacing(legAt: 0, in: journey, with: newLeg, finalDestination: berlin)
        #expect(replaced.legs.map(\.tripId) == ["ice423"])
    }
}

@Suite struct AccessAndDeadlineTests {
    @Test func stopAccessFilter() {
        func entry(_ access: StopAccess) -> BoardEntry {
            BoardEntry(kind: .departures, tripId: UUID().uuidString, station: station("1", "Köln Hbf"),
                       line: Line(name: "ICE 1", number: "1", product: .highSpeed, operatorName: nil), otherEnd: "Berlin Hbf",
                       time: TimeInfo(planned: .now, actual: nil), platform: PlatformInfo(planned: nil, actual: nil),
                       cancelled: false, terminatesOrOriginatesHere: false, remarks: [], access: access, source: .transitous)
        }
        let filter = BoardFilter()
        #expect(!filter.includes(entry(.passThrough)))
        #expect(filter.includes(entry(.exitOnly)))
        #expect(filter.includes(entry(.normal)))
        #expect(StopAccess(pickupAllowed: false, dropoffAllowed: true) == .exitOnly)
    }

    final class SlowProvider: TransitProvider, @unchecked Sendable {
        let source = DataSource.bahnDe
        func searchStations(_ query: String) async throws -> [Station] {
            try await Task.sleep(for: .seconds(30))
            return []
        }
        func journeys(_ query: JourneyQuery) async throws -> JourneyPage { throw TransitError.timeout }
        func board(_ kind: BoardKind, at station: Station, date: Date, duration: Int, products: Set<Product>) async throws -> [BoardEntry] { [] }
        func trip(id: String) async throws -> Trip { throw TransitError.timeout }
    }

    @Test func slowPrimaryFallsBackQuickly() async throws {
        let combined = CombinedProvider(primary: SlowProvider(), fallback: MockProvider(source: .transitous), bahnDe: nil)
        let start = Date.now
        let result = try await combined.searchStations("Köln")
        #expect(result.first?.source == .transitous)
        #expect(Date.now.timeIntervalSince(start) < 5)
    }
}

@Suite struct FormationTests {
    @Test func seriesFromConstructionTypes() {
        #expect(BahnDeClient.model(constructionTypes: ["I4080", "I4081"], groupName: "ICE8033", category: "ICE") == "ICE 3neo")
        #expect(BahnDeClient.model(constructionTypes: ["I0812", "I1412", "I1812"], groupName: "ICE9465", category: "ICE") == "ICE 4")
        #expect(BahnDeClient.model(constructionTypes: ["I4010", "I8010"], groupName: "ICE0160", category: "ICE") == "ICE 1")
        #expect(BahnDeClient.model(constructionTypes: ["I4110", "I4115"], groupName: "ICE1162", category: "ICE") == "ICE T")
        #expect(BahnDeClient.model(constructionTypes: ["R8911", "R8921"], groupName: "ICE1811", category: "ICE") == "ICE L")
        #expect(BahnDeClient.model(constructionTypes: ["E1465", "R6682"], groupName: "ICD2854", category: "IC") == "IC 2 (Twindexx)")
    }

    @Test func formationSummary() {
        let formation = TrainFormation(units: [.init(model: "ICE 3neo", number: "8030"), .init(model: "ICE 3neo", number: "8005")])
        #expect(formation.modelSummary == "2× ICE 3neo")
        #expect(formation.unitSummary == "Tz 8030 + 8005")
    }
}

@Suite struct GeometryTests {
    @Test func polylineRoundTrip() {
        let coords = [Coordinate(latitude: 50.943029, longitude: 6.958729), Coordinate(latitude: 51.21996, longitude: 6.794315),
                      Coordinate(latitude: 52.524925, longitude: 13.369629)]
        let decoded = Polyline.decode(Polyline.encode(coords))
        #expect(decoded.count == 3)
        #expect(abs(decoded[2].longitude - 13.369629) < 0.000002)
    }

    @Test func transitousLegHasTrackGeometry() throws {
        let itinerary = try fixture("transitous-leg-geometry", as: MItinerary.self)
        let ice = try #require(itinerary.legs.first).toLeg()
        let geometry = try #require(ice.geometry)
        // Following the tracks is longer than the straight line between Köln and Duisburg.
        let straight = try #require(ice.origin.coordinate).distance(to: try #require(ice.destination.coordinate))
        #expect(geometry.count > 50)
        #expect(Polyline.length(geometry) > straight)
    }

    @Test func slice() {
        let line = (0...10).map { Coordinate(latitude: 50, longitude: 7 + Double($0) * 0.1) }
        let part = Polyline.slice(line, from: Coordinate(latitude: 50, longitude: 7.31), to: Coordinate(latitude: 50, longitude: 7.69))
        #expect(part.count == 5)
    }

    @Test func heatmapCountsOverlaps() {
        let a = (0...20).map { Coordinate(latitude: 50, longitude: 7 + Double($0) * 0.01) }
        let b = (10...30).map { Coordinate(latitude: 50.0001, longitude: 7 + Double($0) * 0.01) } // parallel track
        let runs = SegmentHeatmap().runs(for: [a, b])
        #expect(runs.contains { $0.count == 2 })
        #expect(runs.contains { $0.count == 1 })
        #expect(runs.map(\.count).max() == 2)
    }
}

@Suite struct TraewellingHistoryTests {
    @Test func statusToJourney() throws {
        let page = try fixture("traewelling-statuses", as: TraewellingClient.StatusPage.self)
        #expect(page.data.count == 2)
        #expect(page.links?.next != nil)
        let status = page.data[0]
        let geometry = [Coordinate(latitude: 50.943, longitude: 6.958), Coordinate(latitude: 52.376, longitude: 9.741)]
        let journey = try #require(status.journey(geometry: geometry))
        let leg = try #require(journey.legs.first)
        #expect(leg.line?.product == .highSpeed)
        #expect(leg.line?.name == "ICE 645")
        #expect(leg.departure.delayMinutes == 4)
        #expect(leg.geometry?.count == 2)
        #expect(leg.source == .traewelling)
        #expect(page.data[1].product == .suburban)
    }
}

@Suite struct ConnectionCheckTests {
    let base = Date(timeIntervalSince1970: 1_800_000_000)

    func leg(_ line: String, _ from: String, _ to: String, dep: Double, arr: Double, depDelay: Double = 0, arrDelay: Double = 0,
             cancelled: Bool = false, walking: Bool = false) -> Leg {
        Leg(origin: station(from, from), destination: station(to, to),
            departure: TimeInfo(planned: base.addingTimeInterval(dep * 60), actual: base.addingTimeInterval((dep + depDelay) * 60)),
            arrival: TimeInfo(planned: base.addingTimeInterval(arr * 60), actual: base.addingTimeInterval((arr + arrDelay) * 60)),
            departurePlatform: nil, arrivalPlatform: nil, tripId: walking ? nil : line,
            line: walking ? nil : Line(name: line, number: nil, product: .highSpeed, operatorName: nil),
            direction: nil, isWalking: walking, cancelled: cancelled, stopovers: [], remarks: [], source: .bahnDe)
    }

    @Test func onTimeHasNoIssues() {
        let journey = Journey(legs: [leg("ICE 1", "A", "B", dep: 0, arr: 60), leg("ICE 2", "B", "C", dep: 70, arr: 120)], source: .bahnDe)
        #expect(journey.connectionIssues().isEmpty)
    }

    @Test func delayBreaksTransfer() {
        let journey = Journey(legs: [
            leg("ICE 1", "A", "B", dep: 0, arr: 60, arrDelay: 12),
            leg("", "B", "B", dep: 60, arr: 63, walking: true),
            leg("ICE 2", "B", "C", dep: 70, arr: 120),
        ], source: .bahnDe)
        let issues = journey.connectionIssues()
        #expect(issues.count == 1)
        guard case .transferMissed(let at, _, _, let buffer) = issues[0] else { Issue.record("wrong issue"); return }
        #expect(at == "B")
        #expect(buffer == -2)
        #expect(issues[0].isBlocking)
    }

    @Test func tightButPossible() {
        let journey = Journey(legs: [leg("ICE 1", "A", "B", dep: 0, arr: 60, arrDelay: 6), leg("ICE 2", "B", "C", dep: 70, arr: 120)], source: .bahnDe)
        #expect(journey.connectionIssues().first?.isBlocking == false)
    }

    @Test func cancellation() {
        let journey = Journey(legs: [leg("ICE 1", "A", "B", dep: 0, arr: 60, cancelled: true)], source: .bahnDe)
        #expect(journey.connectionIssues().first?.title == "ICE 1 fällt aus")
    }

    @Test func walkingTimeDoesNotShrinkTheTransferBuffer() {
        // A 3 min walk between platforms used to be subtracted from the buffer; it no longer is.
        let journey = Journey(legs: [
            leg("ICE 1", "A", "B", dep: 0, arr: 60),
            leg("", "B", "B", dep: 60, arr: 63, walking: true),
            leg("ICE 2", "B", "C", dep: 65, arr: 120),
        ], source: .bahnDe)
        #expect(journey.connectionIssues().isEmpty)
    }

    @Test func oneMinuteRealtimeBufferIsStillPossible() {
        let journey = Journey(legs: [leg("ICE 1", "A", "B", dep: 0, arr: 60, arrDelay: 9), leg("ICE 2", "B", "C", dep: 70, arr: 120)], source: .bahnDe)
        #expect(journey.connectionIssues().allSatisfy { !$0.isBlocking })
    }

    @Test func zeroMinuteRealtimeBufferIsImpossible() {
        let journey = Journey(legs: [leg("ICE 1", "A", "B", dep: 0, arr: 60, arrDelay: 10), leg("ICE 2", "B", "C", dep: 70, arr: 120)], source: .bahnDe)
        guard case .transferMissed(_, _, _, let buffer) = journey.connectionIssues().first else { Issue.record("wrong issue"); return }
        #expect(buffer == 0)
    }
}
