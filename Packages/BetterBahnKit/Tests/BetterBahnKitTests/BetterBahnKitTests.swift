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

    /// Real-world response shape for the S-Bahn at Berlin Gesundbrunnen: VBB's feed leaves `track`
    /// and `scheduledTrack` both null and only encodes the platform as free text in `description`
    /// ("S-Bahnsteig Gleis 4"), unlike its U-Bahn feed which populates `track` directly - this is why
    /// U8 departures showed a platform there but every S-Bahn one showed none at all.
    @Test func stopTimesFallsBackToPlatformFromDescriptionWhenTrackIsMissing() throws {
        let json = """
        {"stopTimes": [{
            "place": {
                "name": "S+U Gesundbrunnen Bhf (Berlin)", "lat": 52.549034, "lon": 13.389919,
                "arrival": "2026-09-18T23:31:00Z", "departure": "2026-09-18T23:31:00Z",
                "scheduledArrival": "2026-09-18T23:31:00Z", "scheduledDeparture": "2026-09-18T23:31:00Z",
                "description": "S-Bahnsteig Gleis 4"
            },
            "mode": "METRO", "realTime": false, "tripId": "s1-trip", "routeShortName": "S1", "displayName": "S1"
        }]}
        """
        let response = try JSONDecoding.decoder.decode(MStopTimesResponse.self, from: Data(json.utf8))
        let entry = try #require(response.stopTimes.first?.toEntry(kind: .departures))

        #expect(entry.platform.planned == "4")
    }

    /// Real-world Transitous response for Hanau Hbf: DELFI puts some trains (ICE 12, RE50, …) at the
    /// station's bus bay "Steig F" instead of their track, so the app showed "Gleis F" rather than
    /// Gleis 6. A train must not take a bus bay's letter as its platform; a bus still does.
    @Test func trainIgnoresBusBayAsPlatform() throws {
        let json = """
        {"stopTimes": [{
            "place": {
                "name": "Hanau Hauptbahnhof", "stopId": "de-DELFI_de:06435:4503:4:6", "lat": 50.12, "lon": 8.93,
                "departure": "2026-09-22T21:35:00Z", "scheduledDeparture": "2026-09-22T21:35:00Z",
                "track": "F", "scheduledTrack": "F", "description": "Steig F/G | Steig F"
            },
            "mode": "HIGHSPEED_RAIL", "realTime": true, "tripId": "ice-trip", "routeShortName": "12", "displayName": "ICE 12"
        }, {
            "place": {
                "name": "Hanau Hauptbahnhof", "stopId": "de-DELFI_de:06435:4503:4:6", "lat": 50.12, "lon": 8.93,
                "departure": "2026-09-22T21:40:00Z", "scheduledDeparture": "2026-09-22T21:40:00Z",
                "track": "F", "scheduledTrack": "F", "description": "Steig F/G | Steig F"
            },
            "mode": "BUS", "realTime": true, "tripId": "bus-trip", "routeShortName": "563", "displayName": "563"
        }]}
        """
        let response = try JSONDecoding.decoder.decode(MStopTimesResponse.self, from: Data(json.utf8))
        let entries = response.stopTimes.compactMap { $0.toEntry(kind: .departures) }

        #expect(entries[0].platform.best == nil)
        #expect(entries[1].platform.best == "F")
    }

    /// Real-world Transitous names for Stuttgart Hbf: DELFI splits it into "Hauptbahnhof (oben)"
    /// and "Hauptbahnhof (tief)" without the city, which showed up as "oben Hbf" and "tief Hbf".
    @Test func stuttgartHbfLevelsShowAsStuttgartHbf() throws {
        let json = """
        {"stopTimes": [{
            "place": {
                "name": "Hauptbahnhof (oben)", "stopId": "de-DELFI_de:08111:6115:6:12", "parentId": "de-DELFI_de:08111:6115",
                "lat": 48.78, "lon": 9.18, "departure": "2026-09-22T21:35:00Z", "scheduledDeparture": "2026-09-22T21:35:00Z"
            },
            "mode": "REGIONAL_RAIL", "realTime": false, "tripId": "re-trip", "routeShortName": "MEX18", "displayName": "MEX18"
        }, {
            "place": {
                "name": "Hauptbahnhof (tief)", "stopId": "de-DELFI_de:08111:6118:1:101", "parentId": "de-DELFI_de:08111:6118",
                "lat": 48.78, "lon": 9.18, "departure": "2026-09-22T21:40:00Z", "scheduledDeparture": "2026-09-22T21:40:00Z"
            },
            "mode": "SUBURBAN", "realTime": false, "tripId": "s-trip", "routeShortName": "S1", "displayName": "S1"
        }]}
        """
        let response = try JSONDecoding.decoder.decode(MStopTimesResponse.self, from: Data(json.utf8))
        let entries = response.stopTimes.compactMap { $0.toEntry(kind: .departures) }

        #expect(entries.map(\.station.displayName) == ["Stuttgart Hbf", "Stuttgart Hbf"])
        #expect(Station.displayName(for: "Hauptbahnhof (tief)") == "Hbf")
    }

    /// Real-world Transitous names where the part in brackets is a river or region telling apart
    /// same-named towns, not a city - these showed up as "N-Wendlingen" or "Oder-Frankfurt".
    @Test func riverAndRegionQualifiersAreNotTreatedAsCities() {
        #expect(Station.displayName(for: "Wendlingen (N)") == "Wendlingen (Neckar)")
        #expect(Station.displayName(for: "Esslingen (N)") == "Esslingen (Neckar)")
        #expect(Station.displayName(for: "Ebersbach (F)") == "Ebersbach (Fils)")
        #expect(Station.displayName(for: "Frankfurt (Oder)") == "Frankfurt (Oder)")
        #expect(Station.displayName(for: "Rheinfelden (Baden)") == "Rheinfelden (Baden)")
        #expect(Station.displayName(for: "Neustadt (Weinstr.)") == "Neustadt (Weinstr.)")
        // A real "<stop> (<city>)" name is still rewritten.
        #expect(Station.displayName(for: "S Spandau Bhf (Berlin)") == "Berlin-Spandau")
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
        #expect(leg.direction == "Innsbruck Hbf")
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

    private func mergeTestLeg(_ line: String?, number: String? = nil, from: (String, Double, Double),
                              to: (String, Double, Double), departure: String, arrival: String,
                              isWalking: Bool = false) -> Leg {
        func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
        func station(_ place: (String, Double, Double)) -> Station {
            Station(id: place.0, name: place.0, coordinate: Coordinate(latitude: place.1, longitude: place.2),
                    evaNumber: nil, source: .transitous)
        }
        return Leg(origin: station(from), destination: station(to),
                   departure: TimeInfo(planned: date(departure), actual: nil),
                   arrival: TimeInfo(planned: date(arrival), actual: nil),
                   departurePlatform: nil, arrivalPlatform: nil, tripId: nil,
                   line: line.map { Line(name: $0, number: number, product: .highSpeed, operatorName: nil) },
                   direction: nil, isWalking: isWalking, cancelled: false, stopovers: [], remarks: [],
                   source: .transitous)
    }

    /// Real-world case: an Amsterdam–Hannover ICE 243 crossing the border at Rheine, where the Dutch
    /// feed's trip ends at "Rheine" (52.2763, 7.4342) and the German feed's own trip for the very same
    /// physical train picks up at "Rheine, Bahnhof" (52.2760, 7.4348) ~50 m away – modelled as a short
    /// walk leg between the two train legs rather than a direct hand-off. Left unmerged, the planner
    /// shows ICE 243 twice with a spurious "change at Rheine" in between.
    @Test func mergeThroughTrainLegsFoldsShortWalkBetweenSameTrainAcrossABorder() {
        let firstHalf = mergeTestLeg("ICE 243", number: "243", from: ("Amsterdam Centraal", 52.379, 4.899),
                                     to: ("Rheine", 52.2763, 7.4342), departure: "2026-09-21T16:00:00Z", arrival: "2026-09-21T18:24:00Z")
        let walk = mergeTestLeg(nil, from: ("Rheine", 52.2763, 7.4342), to: ("Rheine, Bahnhof", 52.2760, 7.4348),
                                departure: "2026-09-21T18:24:00Z", arrival: "2026-09-21T18:26:00Z", isWalking: true)
        let secondHalf = mergeTestLeg("ICE 243", number: "243", from: ("Rheine, Bahnhof", 52.2760, 7.4348),
                                      to: ("Hannover Hbf", 52.377, 9.742), departure: "2026-09-21T18:26:00Z", arrival: "2026-09-21T20:01:00Z")

        let merged = TransitousProvider.mergeThroughTrainLegs([firstHalf, walk, secondHalf])

        #expect(merged.count == 1)
        let ride = merged.first
        #expect(ride?.origin.name == "Amsterdam Centraal")
        #expect(ride?.destination.name == "Hannover Hbf")
        #expect(ride?.arrival.planned == secondHalf.arrival.planned)
    }

    /// A short walk between two nearby stops is only folded away when the numbered train actually
    /// continues – a genuine transfer to a different train stays a transfer even if it happens to
    /// depart moments later from a stop just as close by.
    @Test func mergeThroughTrainLegsKeepsWalkWhenTheNextTrainDiffers() {
        let firstHalf = mergeTestLeg("ICE 243", number: "243", from: ("Amsterdam Centraal", 52.379, 4.899),
                                     to: ("Rheine", 52.2763, 7.4342), departure: "2026-09-21T16:00:00Z", arrival: "2026-09-21T18:24:00Z")
        let walk = mergeTestLeg(nil, from: ("Rheine", 52.2763, 7.4342), to: ("Rheine, Bahnhof", 52.2760, 7.4348),
                                departure: "2026-09-21T18:24:00Z", arrival: "2026-09-21T18:26:00Z", isWalking: true)
        let otherTrain = mergeTestLeg("IC 118", number: "118", from: ("Rheine, Bahnhof", 52.2760, 7.4348),
                                      to: ("Hannover Hbf", 52.377, 9.742), departure: "2026-09-21T18:26:00Z", arrival: "2026-09-21T20:01:00Z")

        let merged = TransitousProvider.mergeThroughTrainLegs([firstHalf, walk, otherTrain])

        #expect(merged.count == 3)
    }

    /// At a busy multimodal hub (Amsterdam Centraal: buses, trams, metro, ferry and regional trains
    /// all sharing the stop cluster), the unfiltered `/v5/stoptimes` request's fixed-size `n` page can
    /// fill up with local traffic long before a later, rarer long-distance train like "ICE 147" is
    /// ever reached – it's not just pushed down the board, it's entirely absent from the response.
    /// With the default "all products" filter selected, `board(_:at:date:duration:products:)` must
    /// still fetch that slice in its own mode-scoped request so it's never starved this way.
    @Test func boardFetchesLongDistanceSeparatelySoItIsNotCrowdedOutByLocalTraffic() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CrowdedHubStopTimesProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let provider = TransitousProvider(http: HTTPClient(session: session))
        let amsterdam = station("ams", "Amsterdam Centraal", source: .transitous)
        let queryDate = try #require(JSONDecoding.parseISODate("2026-09-19T08:00:00Z"))

        let entries = try await provider.board(.departures, at: amsterdam, date: queryDate, duration: 90, products: Set(Product.allCases))

        #expect(entries.contains { $0.line.name.contains("147") })
        // The regional entry that both the long-distance and the "rest" request happen to echo back
        // (same tripId) must not show up twice.
        #expect(entries.filter { $0.tripId == "shared-trip" }.count == 1)
    }
}

/// Serves two different `/v5/stoptimes` fixtures depending on whether a `mode` query parameter
/// scoped to long-distance/high-speed rail is present, simulating a hub whose unfiltered response
/// never reaches a later long-distance departure.
private final class CrowdedHubStopTimesProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let mode = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "mode" }?.value
        let body: Data
        // Query window is 2026-09-19T08:00Z through 09:30Z (date=08:00, duration=90 minutes).
        if mode == "HIGHSPEED_RAIL,LONG_DISTANCE,NIGHT_RAIL" {
            body = Data("""
            {"stopTimes": [
                {"place": {"name": "Amsterdam Centraal", "stopId": "ams", "lat": 52.379, "lon": 4.899,
                           "scheduledDeparture": "2026-09-19T09:00:00Z", "pickupType": "NORMAL"},
                 "mode": "HIGHSPEED_RAIL", "tripId": "ice-147", "tripShortName": "ICE 147",
                 "displayName": "ICE 147", "headsign": "Berlin Hbf",
                 "tripTo": {"name": "Berlin Hbf", "lat": 52.5, "lon": 13.4}},
                {"place": {"name": "Amsterdam Centraal", "stopId": "ams", "lat": 52.379, "lon": 4.899,
                           "scheduledDeparture": "2026-09-19T08:50:00Z", "pickupType": "NORMAL"},
                 "mode": "LONG_DISTANCE", "tripId": "shared-trip", "tripShortName": "IC 118",
                 "displayName": "IC 118", "headsign": "Rotterdam Centraal",
                 "tripTo": {"name": "Rotterdam Centraal", "lat": 51.9, "lon": 4.5}}
            ]}
            """.utf8)
        } else {
            // The unfiltered ("rest") request is drowned out by local traffic before it ever reaches
            // 09:00 – exactly like the real Amsterdam Centraal board – so "ICE 147" never appears here.
            body = Data("""
            {"stopTimes": [
                {"place": {"name": "Amsterdam Centraal", "stopId": "ams", "lat": 52.379, "lon": 4.899,
                           "scheduledDeparture": "2026-09-19T08:01:00Z", "pickupType": "NORMAL"},
                 "mode": "BUS", "tripId": "bus-1", "tripShortName": "N84",
                 "displayName": "N84", "headsign": "Nieuwe Meer",
                 "tripTo": {"name": "Nieuwe Meer", "lat": 52.34, "lon": 4.83}},
                {"place": {"name": "Amsterdam Centraal", "stopId": "ams", "lat": 52.379, "lon": 4.899,
                           "scheduledDeparture": "2026-09-19T08:02:00Z", "pickupType": "NORMAL"},
                 "mode": "REGIONAL_RAIL", "tripId": "regional-1", "tripShortName": "Sprinter",
                 "displayName": "Sprinter", "headsign": "Hoorn",
                 "tripTo": {"name": "Hoorn", "lat": 52.64, "lon": 5.06}},
                {"place": {"name": "Amsterdam Centraal", "stopId": "ams", "lat": 52.379, "lon": 4.899,
                           "scheduledDeparture": "2026-09-19T08:50:00Z", "pickupType": "NORMAL"},
                 "mode": "LONG_DISTANCE", "tripId": "shared-trip", "tripShortName": "IC 118",
                 "displayName": "IC 118", "headsign": "Rotterdam Centraal",
                 "tripTo": {"name": "Rotterdam Centraal", "lat": 51.9, "lon": 4.5}}
            ]}
            """.utf8)
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
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

    @Test func deutschlandticket() {
        let filter = TicketFilter.deutschlandticket
        #expect(filter.isValid(regio))
        #expect(filter.isValid(Line(name: "S 1", number: nil, product: .suburban, operatorName: "DB Regio")))
        #expect(filter.isValid(Line(name: "Bus EN", number: nil, product: .bus, operatorName: nil)))
        #expect(!filter.isValid(ice))
        #expect(!filter.isValid(flix))
        #expect(!filter.isValid(coach))
        #expect(!filter.isValid(Line(name: "IC 2013", number: "2013", product: .regional, operatorName: nil)))
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
        let filter = BoardFilter(products: [.highSpeed, .longDistance], ticketFilter: .bahnCard100(.default))
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

@Suite struct BahnExpertTests {
    @Test func familyStripsVariantAndClass() {
        #expect(TrainTypeLookup.family(of: "ICE 4 Lang (BR412)") == "ICE 4")
        #expect(TrainTypeLookup.family(of: "ICE 3neo (BR408)") == "ICE 3neo")
        #expect(TrainTypeLookup.family(of: "ICE 3") == "ICE 3")
    }

    @Test func summaryDeduplicatesFamilies() {
        let group = { (name: String) in TrainTypeLookup.Group(seriesName: name, baureihe: nil, unitNumber: nil, origin: nil, destination: nil, coachCount: 13) }
        let lookup = TrainTypeLookup(category: "ICE", number: "373", date: "2026-09-20", administration: "80",
                                     groups: [group("ICE 4 Lang (BR412)"), group("ICE 4 Kurz (BR412)")], status: .planned,
                                     source: "DB-plan", retrievedAt: .now)
        #expect(lookup.summary == "ICE 4")
        #expect(lookup.pageURL?.absoluteString == "https://bahn.expert/details/ICE%20373/2026-09-20T12:00:00.000Z?administration=80")
    }

    @Test func decodesSequenceResponse() throws {
        let json = """
        {"isRealtime": false, "source": "DB-plan", "sequence": {"groups": [
            {"name": "373-planned", "originName": "Berlin", "destinationName": "Chur",
             "baureihe": {"identifier": "412.13", "baureihe": "412", "name": "ICE 4 Lang (BR412)"},
             "coaches": [{"type": "Apmzf"}, {"type": "Bpmz"}]}]}}
        """
        let response = try JSONDecoding.decoder.decode(BahnExpertClient.SequenceResponse.self, from: Data(json.utf8))
        #expect(response.sequence?.groups.first?.baureihe?.name == "ICE 4 Lang (BR412)")
        #expect(response.sequence?.groups.first?.coaches?.count == 2)
    }

    @Test func decodesSplitTrainGroupsWithTheirOwnJourneyNumbers() throws {
        let json = #"""
        {"isRealtime": true, "sequence": {"groups": [
            {"name": "ICE9220", "journeyNumber": 940, "destinationName": "Düsseldorf Hbf", "baureihe": {"baureihe": "412", "name": "ICE 4 Kurz (BR412)"}},
            {"name": "ICE9227", "journeyNumber": 950, "destinationName": "Köln Hbf", "baureihe": {"baureihe": "412", "name": "ICE 4 Kurz (BR412)"}}]}}
        """#
        let response = try JSONDecoding.decoder.decode(BahnExpertClient.SequenceResponse.self, from: Data(json.utf8))
        #expect(response.sequence?.groups.map(\.journeyNumber) == [940, 950])
    }

    @Test func decodesDetailsWithFractionalDates() throws {
        let json = """
        {"stops": [{"stopPlace": {"evaNumber": "8500010"}, "departure": {"scheduledTime": "2026-09-20T16:07:00.000Z"}}],
         "train": {"category": "ICE", "journeyNumber": 373, "admin": "85"}}
        """
        let details = try JSONDecoding.decoder.decode(BahnExpertClient.Details.self, from: Data(json.utf8))
        #expect(details.stops.first?.stopPlace.evaNumber == "8500010")
        #expect(details.train?.admin == "85")
    }

    /// Real ICE 372 run (2026-09-22): it skipped Frankfurt (Main) Hbf and instead picked up an
    /// unscheduled stop at Frankfurt (Main) Süd — bahn.expert flags exactly that pair (`cancelled` /
    /// `additional`) in `journey/detailsByJourneyId`, which is the only source this app has for either.
    @Test func decodesCancelledAndAdditionalStops() throws {
        let json = #"""
        {"stops": [
            {"stopPlace": {"evaNumber": "8000244", "name": "Mannheim Hbf"},
             "arrival": {"scheduledTime": "2026-09-22T10:22:00.000Z", "time": "2026-09-22T10:58:29.000Z"},
             "departure": {"scheduledTime": "2026-09-22T10:30:00.000Z", "time": "2026-09-22T11:02:52.000Z"}},
            {"stopPlace": {"evaNumber": "8000105", "name": "Frankfurt (Main) Hbf"},
             "arrival": {"scheduledTime": "2026-09-22T11:09:00.000Z", "time": "2026-09-22T11:09:00.000Z", "cancelled": true},
             "departure": {"scheduledTime": "2026-09-22T11:15:00.000Z", "time": "2026-09-22T11:15:00.000Z", "cancelled": true},
             "cancelled": true},
            {"stopPlace": {"evaNumber": "8002041", "name": "Frankfurt (Main) Süd"},
             "arrival": {"scheduledTime": "2026-09-22T11:19:00.000Z", "time": "2026-09-22T11:38:28.000Z", "additional": true, "scheduledPlatform": "6", "platform": "7"},
             "departure": {"scheduledTime": "2026-09-22T11:19:00.000Z", "time": "2026-09-22T11:58:04.000Z", "additional": true, "scheduledPlatform": "6", "platform": "7"},
             "additional": true},
            {"stopPlace": {"evaNumber": "8000150", "name": "Hanau Hbf"},
             "arrival": {"scheduledTime": "2026-09-22T11:28:00.000Z", "time": "2026-09-22T12:07:20.000Z"},
             "departure": {"scheduledTime": "2026-09-22T11:30:00.000Z", "time": "2026-09-22T12:09:01.000Z"}}
        ]}
        """#
        let details = try JSONDecoding.decoder.decode(BahnExpertClient.Details.self, from: Data(json.utf8))
        let stops = details.stops.map(JourneyStop.init)

        #expect(stops[1].isCancelled)
        #expect(stops[2].isAdditional)
        #expect(stops[2].name == "Frankfurt (Main) Süd")
        #expect(stops[2].departurePlatform == PlatformInfo(planned: "6", actual: "7"))
        #expect(!stops[0].isAdditional && !stops[0].isCancelled)

        let zusatzhaltStation = station("8002041", "Frankfurt (Main) Süd")
        let match = try #require(BahnExpertClient.nextRegularStop(after: zusatzhaltStation, in: stops))
        #expect(match.zusatzhalt.evaNumber == "8002041")
        #expect(match.nextRegular.evaNumber == "8000150")

        // A regular (non-additional) stop is never mistaken for a Zusatzhalt.
        #expect(BahnExpertClient.nextRegularStop(after: station("8000244", "Mannheim Hbf"), in: stops) == nil)
        // No regular stop left after the Zusatzhalt (e.g. it's also the run's last stop).
        #expect(BahnExpertClient.nextRegularStop(after: zusatzhaltStation, in: Array(stops.prefix(3))) == nil)
    }

    /// `Trip`/`Leg` stopovers only ever come from Transitous, which never has a Zusatzhalt at all —
    /// `inserting(_:into:)` is what splices Frankfurt (Main) Süd into the existing (already
    /// realtime-overlaid) stop list rather than it being silently missing from the journey view.
    @Test func insertsTheZusatzhaltAtItsRightfulPlace() throws {
        let json = #"""
        {"stops": [
            {"stopPlace": {"evaNumber": "8000244", "name": "Mannheim Hbf"}},
            {"stopPlace": {"evaNumber": "8000105", "name": "Frankfurt (Main) Hbf"}, "cancelled": true},
            {"stopPlace": {"evaNumber": "8002041", "name": "Frankfurt (Main) Süd"}, "additional": true,
             "departure": {"scheduledTime": "2026-09-22T11:19:00.000Z", "time": "2026-09-22T11:58:04.000Z"}},
            {"stopPlace": {"evaNumber": "8000150", "name": "Hanau Hbf"}}
        ]}
        """#
        let details = try JSONDecoding.decoder.decode(BahnExpertClient.Details.self, from: Data(json.utf8))
        let stops = details.stops.map(JourneyStop.init)

        // The already-refreshed schedule: no Zusatzhalt (Transitous never has it), but Frankfurt Hbf
        // is already flagged cancelled by an earlier realtime overlay, which must survive the merge.
        let existing = [
            station("8000244", "Mannheim Hbf"),
            station("8000105", "Frankfurt (Main) Hbf"),
            station("8000150", "Hanau Hbf"),
        ].enumerated().map { index, s in
            Stopover(station: s, arrival: nil, departure: nil, arrivalPlatform: nil, departurePlatform: nil, cancelled: index == 1)
        }

        let merged = BahnExpertClient.inserting(stops, into: existing)

        #expect(merged.map(\.station.name) == ["Mannheim Hbf", "Frankfurt (Main) Hbf", "Frankfurt (Main) Süd", "Hanau Hbf"])
        #expect(merged[1].cancelled)
        #expect(merged[2].isAdditional)
        #expect(!merged[0].isAdditional && !merged[3].isAdditional)
        #expect(merged[2].departure?.actual == JSONDecoding.parseISODate("2026-09-22T11:58:04.000Z"))

        // Nothing to insert: the list comes back untouched (same stops, no Zusatzhalt in `stops`).
        let withoutZusatzhalt = stops.filter { !$0.isAdditional }
        #expect(BahnExpertClient.inserting(withoutZusatzhalt, into: existing) == existing)
        // Stopovers never loaded for this leg/trip: stays empty rather than showing a partial list.
        #expect(BahnExpertClient.inserting(stops, into: []).isEmpty)

        // Callers (a saved journey's periodic realtime refresh, the trip sheet's own reload) re-run
        // this against a stop list that already carries the Zusatzhalt from a previous call — it must
        // not show up twice.
        let mergedAgain = BahnExpertClient.inserting(stops, into: merged)
        #expect(mergedAgain == merged)
    }

    @Test func unitNumberOnlyFromLiveGroupNames() {
        #expect(BahnExpertClient.unitNumber(from: "ICE9465") == "9465")
        #expect(BahnExpertClient.unitNumber(from: "ICE0160") == "160")
        #expect(BahnExpertClient.unitNumber(from: "373-planned") == nil)
    }

    /// Without a Referer bahn.expert returns an empty 206 and every lookup silently fails.
    @Test func requestsCarryTheRefererBahnExpertRequires() throws {
        let request = try BahnExpertClient.request(procedure: "journey/find", input: ["json": ["journeyNumber": 373]])
        #expect(request.value(forHTTPHeaderField: "Referer") == "https://bahn.expert/")
        #expect(request.url?.absoluteString == "https://bahn.expert/api/orpc/journey/find")
        #expect(request.httpMethod == "POST")
    }

    @Test func decodesPosition() throws {
        let json = #"{"longitude": 11.0772616667, "latitude": 52.45801, "time": "2026-09-19T10:48:08.000Z", "metaSource": "SENSOR", "speed": 240.21}"#
        let wire = try JSONDecoding.decoder.decode(BahnExpertClient.PositionResponse.self, from: Data(json.utf8))
        let position = TrainPosition(coordinate: .init(latitude: wire.latitude, longitude: wire.longitude), time: wire.time, speedKmh: wire.speed, source: wire.metaSource)
        #expect(position.speedKmh == 240.21)
        #expect(!position.isStale(now: wire.time.addingTimeInterval(30)))
        #expect(position.isStale(now: wire.time.addingTimeInterval(300)))
    }

    @Test func familyPrefersBaureiheNumber() {
        let group = { (number: String?, name: String?) in
            TrainTypeLookup.Group(seriesName: name, baureihe: number, unitNumber: nil, origin: nil, destination: nil, coachCount: 0)
        }
        #expect(group("412", "ICE 4 Lang (BR412)").family == "ICE 4")
        #expect(group("407", "ICE 3 Velaro (BR407)").family == "ICE 3")
        #expect(group("411", "ICE T (BR411)").family == "ICE T")
        #expect(group("408", "ICE 3neo (BR408)").family == "ICE 3neo")
        #expect(group(nil, "ICE L").family == "ICE L")
        #expect(group(nil, nil).family == nil)
    }

    @Test func trainReferenceOnlyForLongDistance() {
        let line = { (name: String, number: String) in Line(name: name, number: number, product: .highSpeed, operatorName: nil) }
        #expect(BahnExpertClient.trainReference(for: line("ICE 950", "950"))?.category == "ICE")
        #expect(BahnExpertClient.trainReference(for: line("RE 5", "5")) == nil)
        #expect(BahnExpertClient.trainReference(for: nil) == nil)
    }

    @Test func dayValidation() {
        #expect(BahnExpertClient.isValidDay("2026-09-20"))
        #expect(!BahnExpertClient.isValidDay("2026-02-31"))
        #expect(!BahnExpertClient.isValidDay("20.09.2026"))
    }

    @Test func berlinDayUsesLocalCalendarDay() {
        // 23:30 UTC on the 19th is already the 20th in Berlin (CEST).
        let date = Date(timeIntervalSince1970: 1_789_860_600)
        #expect(BahnExpertClient.berlinDay(date) == "2026-09-20")
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

    @Test func sliceKeepsTheTrackWhenTheShapeRunsBackwards() {
        // A shape stored against the direction of travel used to collapse into a straight line
        // between the two stations, drawn right across the map.
        let track = (0...10).map { Coordinate(latitude: 50 + 0.05 * sin(Double($0)), longitude: 7 + Double($0) * 0.1) }
        let part = Polyline.slice(track.reversed(), from: track[2], to: track[8])
        #expect(part.count == 7)
        #expect(part.first?.longitude == track[2].longitude)
        #expect(part.last?.longitude == track[8].longitude)
    }

    @Test func sliceKeepsTheWholeShapeWhenTheEndsDontFit() {
        let track = (0...10).map { Coordinate(latitude: 50, longitude: 7 + Double($0) * 0.1) }
        // Endpoints from a different trip entirely.
        let part = Polyline.slice(track, from: Coordinate(latitude: 48, longitude: 11), to: Coordinate(latitude: 53, longitude: 10))
        #expect(part.count == track.count)
    }

    @Test func straightLineBetweenCitiesIsNotTrackGeometry() {
        let straight = [Coordinate(latitude: 50.943, longitude: 6.958), Coordinate(latitude: 52.376, longitude: 9.741)]
        #expect(!RouteGeometryService.followsTracks(straight))
        // A short hop between neighbouring stops legitimately has only two points.
        let hop = [Coordinate(latitude: 50.943, longitude: 6.958), Coordinate(latitude: 50.951, longitude: 6.969)]
        #expect(RouteGeometryService.followsTracks(hop))
    }

    @Test func simplifyKeepsTheShape() {
        let track = (0...500).map { i -> Coordinate in
            let t = Double(i) / 500
            return Coordinate(latitude: 50 + 0.3 * t + 0.02 * sin(t * 12), longitude: 7 + 0.4 * t)
        }
        let simplified = Polyline.simplify(track, tolerance: 8)
        #expect(simplified.count < track.count / 4)
        // Every dropped point was within the tolerance of what's left.
        for point in track {
            let deviation = zip(simplified, simplified.dropFirst())
                .map { Polyline.distance(from: point, toSegment: $0.0, $0.1) }.min() ?? .infinity
            #expect(deviation < 10)
        }
    }

    @Test func heatmapCountsOverlaps() {
        let a = (0...20).map { Coordinate(latitude: 50, longitude: 7 + Double($0) * 0.01) }
        let b = (10...30).map { Coordinate(latitude: 50.0001, longitude: 7 + Double($0) * 0.01) } // parallel track
        let runs = SegmentHeatmap().runs(for: [a, b])
        #expect(runs.contains { $0.count == 2 })
        #expect(runs.contains { $0.count == 1 })
        #expect(runs.map(\.count).max() == 2)
    }

    @Test func heatmapFollowsTheOriginalGeometry() {
        // A curve whose points sit nowhere near the centres of a 0.0015° grid.
        let curve = (0 ... 200).map { i -> Coordinate in
            let t = Double(i) / 200
            return Coordinate(latitude: 50.00073 + 0.2 * t, longitude: 7.00061 + 0.3 * t + 0.02 * sin(t * 8))
        }
        let runs = SegmentHeatmap().runs(for: [curve])
        let drawn = runs.flatMap(\.coordinates)
        #expect(!drawn.isEmpty)
        // Every drawn point lies on the original line, not on a grid centre.
        func distanceToCurve(_ p: Coordinate) -> Double {
            zip(curve, curve.dropFirst()).map { a, b in
                // Project onto the segment in degrees, then measure in meters.
                let dx = b.longitude - a.longitude, dy = b.latitude - a.latitude
                let square = dx * dx + dy * dy
                let t = square == 0 ? 0 : max(0, min(1, ((p.longitude - a.longitude) * dx + (p.latitude - a.latitude) * dy) / square))
                return p.distance(to: Coordinate(latitude: a.latitude + dy * t, longitude: a.longitude + dx * t))
            }.min() ?? .infinity
        }
        for point in drawn { #expect(distanceToCurve(point) < 1) }
        // And the line keeps its length instead of being replaced by a staircase.
        let length = runs.reduce(0.0) { $0 + Polyline.length($1.coordinates) }
        #expect(abs(length - Polyline.length(curve)) < Polyline.length(curve) * 0.01)
    }

    @Test func heatmapDrawsASharedStretchWithoutGaps() {
        // Same track twice, sampled differently by each source.
        let fine = (0 ... 100).map { Coordinate(latitude: 50, longitude: 7 + Double($0) * 0.002) }
        let coarse = (0 ... 10).map { Coordinate(latitude: 50.0004, longitude: 7 + Double($0) * 0.02) }
        let runs = SegmentHeatmap().runs(for: [fine, coarse])
        #expect(runs.allSatisfy { $0.count == 2 })
        let covered = runs.reduce(0.0) { $0 + Polyline.length($1.coordinates) }
        #expect(covered > Polyline.length(fine) * 0.98)
    }
}

@Suite struct RideMatchTests {
    private func leg(_ line: String?, number: String? = nil, from: String, to: String,
                     departure: String, arrival: String) -> Leg {
        func date(_ value: String) -> Date {
            let formatter = ISO8601DateFormatter()
            return formatter.date(from: value)!
        }
        func station(_ name: String) -> Station {
            Station(id: name, name: name, coordinate: nil, evaNumber: nil, source: .transitous)
        }
        return Leg(origin: station(from), destination: station(to),
                   departure: TimeInfo(planned: date(departure), actual: nil),
                   arrival: TimeInfo(planned: date(arrival), actual: nil),
                   departurePlatform: nil, arrivalPlatform: nil, tripId: nil,
                   line: line.map { Line(name: $0, number: number, product: .highSpeed, operatorName: nil) },
                   direction: nil, isWalking: false, cancelled: false, stopovers: [], remarks: [],
                   source: .transitous)
    }

    @Test func checkinStartingLaterStillMatches() {
        let saved = leg("ICE 645", from: "Köln Hbf", to: "Hannover Hbf",
                        departure: "2026-03-04T09:00:00Z", arrival: "2026-03-04T11:30:00Z")
        // Checked in one stop late and under a slightly different spelling.
        let checkin = leg("ICE645", from: "Köln Messe/Deutz", to: "Hannover Hbf",
                          departure: "2026-03-04T09:12:00Z", arrival: "2026-03-04T11:34:00Z")
        #expect(RideMatch.isSameRide(checkin, saved))
        #expect(RideMatch.deduplicated([Journey(legs: [checkin], source: .traewelling)],
                                       against: [Journey(legs: [saved], source: .transitous)]).isEmpty)
    }

    @Test func differentNameButSameStretchMatches() {
        let saved = leg("RE 5", from: "Koblenz Hbf", to: "Bonn Hbf",
                        departure: "2026-03-04T14:00:00Z", arrival: "2026-03-04T15:00:00Z")
        let checkin = leg("RE 5 (12345)", from: "Koblenz Hbf", to: "Bonn Hbf",
                          departure: "2026-03-04T14:02:00Z", arrival: "2026-03-04T15:01:00Z")
        #expect(RideMatch.isSameRide(checkin, saved))
    }

    @Test func sameTrainOnAnotherDayIsKept() {
        let saved = leg("ICE 645", from: "Köln Hbf", to: "Hannover Hbf",
                        departure: "2026-03-04T09:00:00Z", arrival: "2026-03-04T11:30:00Z")
        let checkin = leg("ICE 645", from: "Köln Hbf", to: "Hannover Hbf",
                          departure: "2026-03-11T09:00:00Z", arrival: "2026-03-11T11:30:00Z")
        #expect(!RideMatch.isSameRide(checkin, saved))
        #expect(RideMatch.deduplicated([Journey(legs: [checkin], source: .traewelling)],
                                       against: [Journey(legs: [saved], source: .transitous)]).count == 1)
    }

    @Test func aDifferentTrainOnTheSameDayIsKept() {
        let saved = leg("ICE 645", from: "Köln Hbf", to: "Hannover Hbf",
                        departure: "2026-03-04T09:00:00Z", arrival: "2026-03-04T11:30:00Z")
        let checkin = leg("RE 1", from: "Hannover Hbf", to: "Bremen Hbf",
                          departure: "2026-03-04T12:00:00Z", arrival: "2026-03-04T13:00:00Z")
        #expect(!RideMatch.isSameRide(checkin, saved))
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

// MARK: - Train route planning

/// Mock that answers boards and journey queries per station pair, so chained planning can be tested.
final class RoutingMockProvider: TransitProvider, @unchecked Sendable {
    let source: DataSource = .bahnDe
    /// Departure boards keyed by station name.
    var boards: [String: [BoardEntry]] = [:]
    var trips: [String: Trip] = [:]
    /// Journeys keyed by "<from> -> <to>"; the planner filters them by time itself.
    var routes: [String: [Journey]] = [:]
    private(set) var journeyQueries: [String] = []
    private let lock = NSLock()

    func searchStations(_ query: String) async throws -> [Station] { [] }

    func journeys(_ query: JourneyQuery) async throws -> JourneyPage {
        let key = "\(query.from.name) -> \(query.to.name)"
        lock.withLock { journeyQueries.append(key) }
        return JourneyPage(journeys: routes[key] ?? [], earlierCursor: nil, laterCursor: nil, source: source)
    }

    func board(_ kind: BoardKind, at station: Station, date: Date, duration: Int, products: Set<Product>) async throws -> [BoardEntry] {
        (boards[station.name] ?? []).filter {
            $0.time.best >= date && $0.time.best <= date.addingTimeInterval(TimeInterval(duration * 60))
        }
    }

    func trip(id: String) async throws -> Trip {
        guard let trip = trips[id] else { throw TransitError.notFound(id) }
        return trip
    }
}

@Suite struct TrainRoutePlannerTests {
    let koeln = station("8000207", "Köln Hbf", 50.943, 6.958)
    let duesseldorf = station("8000085", "Düsseldorf Hbf", 51.219, 6.794)
    let hamm = station("8000149", "Hamm (Westf)", 51.678, 7.808)
    let hannover = station("8000152", "Hannover Hbf", 52.377, 9.741)
    let berlin = station("8011160", "Berlin Hbf", 52.525, 13.369)
    let base = Date(timeIntervalSince1970: 1_800_000_000)

    func time(_ minutes: Double) -> TimeInfo { TimeInfo(planned: base.addingTimeInterval(minutes * 60), actual: nil) }

    func stop(_ s: Station, arr: Double?, dep: Double?) -> Stopover {
        Stopover(station: s, arrival: arr.map(time), departure: dep.map(time),
                 arrivalPlatform: nil, departurePlatform: nil, cancelled: false)
    }

    func trip(_ id: String, _ name: String, _ stops: [Stopover]) -> Trip {
        Trip(id: id, line: Line(name: name, number: String(name.split(separator: " ").last!), product: .highSpeed,
                                operatorName: "DB Fernverkehr AG"),
             direction: stops.last?.station.name, stopovers: stops, cancelled: false, remarks: [], source: .bahnDe)
    }

    func entry(_ trip: Trip, at station: Station, minutes: Double) -> BoardEntry {
        BoardEntry(kind: .departures, tripId: trip.id, station: station, line: trip.line!,
                   otherEnd: trip.stopovers.last?.station.name, time: time(minutes),
                   platform: PlatformInfo(planned: nil, actual: nil), cancelled: false,
                   terminatesOrOriginatesHere: false, remarks: [], source: .bahnDe)
    }

    func journey(_ name: String, _ from: Station, _ to: Station, dep: Double, arr: Double) -> Journey {
        let ride = trip("t-\(name)-\(dep)", name, [stop(from, arr: nil, dep: dep), stop(to, arr: arr, dep: nil)])
        return Journey(legs: [ride.leg(from: from, to: to)!], source: .bahnDe)
    }

    func makeProvider() -> RoutingMockProvider { RoutingMockProvider() }

    func planner(_ mock: RoutingMockProvider) -> TrainRoutePlanner {
        TrainRoutePlanner(provider: CombinedProvider(primary: mock, fallback: nil, bahnDe: nil))
    }

    /// Exit named: the ride ends there and the fastest onward connection is appended.
    @Test func continuesFromNamedExitStation() async throws {
        let mock = makeProvider()
        let ice = trip("ice423", "ICE 423", [
            stop(koeln, arr: nil, dep: 10), stop(hamm, arr: 70, dep: 72), stop(hannover, arr: 130, dep: nil),
        ])
        mock.trips[ice.id] = ice
        mock.boards[koeln.name] = [entry(ice, at: koeln, minutes: 10)]
        mock.routes["Hamm (Westf) -> Berlin Hbf"] = [
            journey("ICE 500", hamm, berlin, dep: 80, arr: 260),
            journey("IC 140", hamm, berlin, dep: 75, arr: 300),
        ]

        let requirement = TrainRequirement(trainName: "423", boarding: koeln, exit: hamm)
        let plan = try await planner(mock).plan([requirement], from: koeln, to: berlin, date: base)
        let best = try #require(plan.best)
        #expect(best.transitLegs.map { $0.line?.name } == ["ICE 423", "ICE 500"])
        #expect(best.legs.first?.origin.isSamePlace(as: koeln) == true)
        #expect(best.legs.last?.destination.isSamePlace(as: berlin) == true)
        #expect(plan.resolvedNames[requirement.id] == "ICE 423")
    }

    /// No exit named: every stop after boarding is tried and the fastest way on wins.
    @Test func picksFastestAlightingStopWhenNoneGiven() async throws {
        let mock = makeProvider()
        let ice = trip("ice423", "ICE 423", [
            stop(koeln, arr: nil, dep: 10), stop(duesseldorf, arr: 30, dep: 32),
            stop(hamm, arr: 70, dep: 72), stop(hannover, arr: 130, dep: nil),
        ])
        mock.trips[ice.id] = ice
        mock.boards[koeln.name] = [entry(ice, at: koeln, minutes: 10)]
        // Staying on until Hannover is slowest; Hamm has the sprinter.
        mock.routes["Düsseldorf Hbf -> Berlin Hbf"] = [journey("IC 2", duesseldorf, berlin, dep: 40, arr: 330)]
        mock.routes["Hamm (Westf) -> Berlin Hbf"] = [journey("ICE 500", hamm, berlin, dep: 80, arr: 250)]
        mock.routes["Hannover Hbf -> Berlin Hbf"] = [journey("ICE 700", hannover, berlin, dep: 140, arr: 280)]

        let plan = try await planner(mock).plan(
            [TrainRequirement(trainName: "ICE 423", boarding: koeln)], from: koeln, to: berlin, date: base)
        let best = try #require(plan.best)
        #expect(best.transitLegs.map { $0.line?.name } == ["ICE 423", "ICE 500"])
        #expect(best.transitLegs.first?.destination.isSamePlace(as: hamm) == true)
        #expect(best.arrival?.best == base.addingTimeInterval(250 * 60))
        // All three onward options were compared.
        #expect(plan.journeys.count > 1)
    }

    /// Riding through to the destination wins when nothing faster branches off.
    @Test func staysOnBoardWhenTrainReachesDestination() async throws {
        let mock = makeProvider()
        let ice = trip("ice423", "ICE 423", [
            stop(koeln, arr: nil, dep: 10), stop(hamm, arr: 70, dep: 72), stop(berlin, arr: 250, dep: nil),
        ])
        mock.trips[ice.id] = ice
        mock.boards[koeln.name] = [entry(ice, at: koeln, minutes: 10)]
        mock.routes["Hamm (Westf) -> Berlin Hbf"] = [journey("IC 140", hamm, berlin, dep: 80, arr: 330)]

        let plan = try await planner(mock).plan(
            [TrainRequirement(trainName: "ICE 423", boarding: koeln)], from: koeln, to: berlin, date: base)
        #expect(plan.best?.transitLegs.map { $0.line?.name } == ["ICE 423"])
    }

    /// A second requirement is added to the first one, not replacing it.
    @Test func chainsTwoRequirements() async throws {
        let mock = makeProvider()
        let first = trip("ice423", "ICE 423", [stop(koeln, arr: nil, dep: 10), stop(hamm, arr: 70, dep: nil)])
        let second = trip("ice500", "ICE 500", [stop(hannover, arr: nil, dep: 150), stop(berlin, arr: 270, dep: nil)])
        mock.trips[first.id] = first
        mock.trips[second.id] = second
        mock.boards[koeln.name] = [entry(first, at: koeln, minutes: 10)]
        mock.boards[hannover.name] = [entry(second, at: hannover, minutes: 150)]
        mock.routes["Hamm (Westf) -> Hannover Hbf"] = [journey("RE 1", hamm, hannover, dep: 80, arr: 140)]

        let plan = try await planner(mock).plan([
            TrainRequirement(trainName: "ICE 423", boarding: koeln, exit: hamm),
            TrainRequirement(trainName: "ICE 500", boarding: hannover, exit: berlin),
        ], from: koeln, to: berlin, date: base)
        let best = try #require(plan.best)
        #expect(best.transitLegs.map { $0.line?.name } == ["ICE 423", "RE 1", "ICE 500"])
        #expect(best.arrival?.best == base.addingTimeInterval(270 * 60))
    }

    /// The traveller has to get to the boarding station first – that feeder is part of the route.
    @Test func addsFeederToBoardingStation() async throws {
        let mock = makeProvider()
        let ice = trip("ice423", "ICE 423", [stop(hamm, arr: nil, dep: 90), stop(berlin, arr: 260, dep: nil)])
        mock.trips[ice.id] = ice
        mock.boards[hamm.name] = [entry(ice, at: hamm, minutes: 90)]
        mock.routes["Köln Hbf -> Hamm (Westf)"] = [
            journey("RE 1", koeln, hamm, dep: 5, arr: 60),
            journey("RE 3", koeln, hamm, dep: 30, arr: 85),
        ]

        let plan = try await planner(mock).plan(
            [TrainRequirement(trainName: "ICE 423", boarding: hamm)], from: koeln, to: berlin, date: base)
        let best = try #require(plan.best)
        // Both feeders make it – the later one is the more comfortable choice.
        #expect(best.transitLegs.map { $0.line?.name } == ["RE 3", "ICE 423"])
    }

    @Test func reportsUnknownTrain() async throws {
        let mock = makeProvider()
        mock.boards[koeln.name] = []
        await #expect(throws: TransitError.self) {
            try await planner(mock).plan([TrainRequirement(trainName: "ICE 999", boarding: koeln)],
                                         from: koeln, to: berlin, date: base)
        }
    }

    /// The board's own feed brands the train differently from how the user typed it (an ÖBB "RJ" that
    /// DB's own feed would call "ICE", per `TransitousProvider`'s own doc comments on this) – direct
    /// name matching finds nothing, so the DB Timetables API's real category/number/time is used to
    /// find it anyway, purely by which board entry departs closest to that confirmed time.
    @Test func rescuesTrainReportedUnderADifferentBrandViaTimetables() async throws {
        let mock = makeProvider()
        let rj = trip("rj423", "RJ 423", [stop(koeln, arr: nil, dep: 10), stop(berlin, arr: 240, dep: nil)])
        mock.trips[rj.id] = rj
        mock.boards[koeln.name] = [entry(rj, at: koeln, minutes: 10)]

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [TimetablesPlanProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let timetables = TimetablesClient(credentials: TimetablesCredentials(clientID: "x", apiKey: "y"),
                                          http: HTTPClient(session: session))
        let planner = TrainRoutePlanner(provider: CombinedProvider(primary: mock, fallback: nil, bahnDe: nil), timetables: timetables)

        let plan = try await planner.plan([TrainRequirement(trainName: "ICE 423", boarding: koeln)],
                                          from: koeln, to: berlin, date: base)

        #expect(plan.best?.transitLegs.map(\.tripId) == ["rj423"])
        #expect(plan.resolvedNames.values.first == "RJ 423")
    }

    /// Without any Timetables client configured, an unmatched name still just fails to find the
    /// train – no crash, no silent misbehavior.
    @Test func skipsRescueWithoutTimetablesConfigured() async throws {
        let mock = makeProvider()
        let rj = trip("rj423", "RJ 423", [stop(koeln, arr: nil, dep: 10), stop(berlin, arr: 240, dep: nil)])
        mock.trips[rj.id] = rj
        mock.boards[koeln.name] = [entry(rj, at: koeln, minutes: 10)]

        await #expect(throws: TransitError.self) {
            try await planner(mock).plan([TrainRequirement(trainName: "ICE 423", boarding: koeln)],
                                         from: koeln, to: berlin, date: base)
        }
    }

    @Test func parsesCategoryAndNumberFromFreeText() {
        let iceMatch = TrainRoutePlanner.parseCategoryAndNumber("ICE 423")
        #expect(iceMatch?.category == "ICE")
        #expect(iceMatch?.number == "423")
        let numberOnly = TrainRoutePlanner.parseCategoryAndNumber("423")
        #expect(numberOnly?.category == nil)
        #expect(numberOnly?.number == "423")
        #expect(TrainRoutePlanner.parseCategoryAndNumber("ICE") == nil)
    }
}

/// Serves a fixed DB Timetables `/plan` XML response (one ICE 423 departure) regardless of which
/// hour bucket is requested, so `scheduledTimes`'s multi-bucket pagination doesn't need a fragile
/// hour-by-hour fixture.
private final class TimetablesPlanProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        // `base` (2026-01-15 08:00 UTC) plus 10 minutes, in Berlin local time, IRIS "YYMMDDHHmm" form.
        let body = Data("""
        <timetable station='Köln Hbf'><s id="1"><tl f="N" t="p" o="80" c="ICE" n="423"/><dp pt="2701150910" pp="7"/></s></timetable>
        """.utf8)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite struct TimetablesCategoryTests {
    @Test func splitsCategoryAndNumberWhenSeparatedBySpace() {
        #expect(TimetablesClient.category(from: "ICE 571") == "ICE")
        #expect(TimetablesClient.category(from: "RE 5") == "RE")
    }

    /// Transitous names S-Bahn (and some other) lines with no space between the letter prefix and the
    /// number ("S15", not "S 15") — this must still split into IRIS's own "S" category, or every
    /// Timetables lookup for an S-Bahn train silently matches nothing.
    @Test func splitsCategoryAndNumberWithNoSpace() {
        #expect(TimetablesClient.category(from: "S15") == "S")
        #expect(TimetablesClient.category(from: "U8") == "U")
    }
}

/// Real-world scenario reported for the S15 (Berlin Hbf → Berlin Gesundbrunnen): Transitous returns
/// no platform at all for some S-Bahn stops, even though DB's own Timetables ("IRIS") `plan` feed
/// always carries the scheduled one. `TimetablesClient.realtime(for:)` should fill that gap, while
/// still preferring a genuine Gleisänderung (`fchg`'s `cp`) over the leg's own planned platform when
/// the leg already has one.
@Suite struct TimetablesRealtimePlatformTests {
    let berlinHbf = station("8011160", "Berlin Hbf", 52.525, 13.369, source: .bahnDe)
    let gesundbrunnen = station("8011102", "Berlin Gesundbrunnen", 52.549, 13.391, source: .bahnDe)
    // 2027-01-15 08:00 UTC == 09:00 Europe/Berlin (CET) -> IRIS "2701150900".
    let departure = Date(timeIntervalSince1970: 1_800_000_000)

    func leg(departurePlatform: PlatformInfo?) -> Leg {
        Leg(origin: berlinHbf, destination: gesundbrunnen,
            departure: TimeInfo(planned: departure, actual: nil),
            arrival: TimeInfo(planned: departure.addingTimeInterval(600), actual: nil),
            departurePlatform: departurePlatform, arrivalPlatform: nil, tripId: "s15",
            // No space between category and number, matching how Transitous actually names S-Bahn
            // lines ("S15", not "S 15") - this is what tripped up `category(from:)` originally.
            line: Line(name: "S15", number: "15", product: .suburban, operatorName: nil),
            direction: nil, isWalking: false, cancelled: false, stopovers: [], remarks: [],
            source: .transitous)
    }

    func client(_ protocolClass: URLProtocol.Type) -> (TimetablesClient, URLSession) {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [protocolClass]
        let session = URLSession(configuration: config)
        let client = TimetablesClient(credentials: TimetablesCredentials(clientID: "x", apiKey: "y"),
                                      http: HTTPClient(session: session))
        return (client, session)
    }

    @Test func fillsInAMissingPlatformFromDBsOwnScheduleWhenNothingChanged() async throws {
        let (timetables, session) = client(UnchangedS15Protocol.self)
        defer { session.invalidateAndCancel() }

        let override = await timetables.realtime(for: leg(departurePlatform: nil))

        #expect(override?.departurePlatform?.planned == "12")
        #expect(override?.departurePlatform?.actual == nil)
    }

    @Test func doesNotOverwriteAnExistingPlatformWithoutARealtimeChange() async throws {
        let (timetables, session) = client(UnchangedS15Protocol.self)
        defer { session.invalidateAndCancel() }

        let override = await timetables.realtime(for: leg(departurePlatform: PlatformInfo(planned: "3", actual: nil)))

        #expect(override?.departurePlatform == nil)
    }

    @Test func overlaysAGleisaenderungOntoTheExistingPlannedPlatform() async throws {
        let (timetables, session) = client(ChangedS15Protocol.self)
        defer { session.invalidateAndCancel() }

        let override = await timetables.realtime(for: leg(departurePlatform: PlatformInfo(planned: "3", actual: nil)))

        #expect(override?.departurePlatform == PlatformInfo(planned: "3", actual: "14"))
    }
}

/// `/plan` has a scheduled platform for the S15 at Berlin Hbf, but `/fchg` reports no Gleisänderung
/// (or anything else) yet. `/fchg` for Gesundbrunnen (the arrival side, not under test) is likewise
/// empty for every request, matched here by responding the same way regardless of path.
private final class UnchangedS15Protocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.path
        let body: Data = path.contains("plan/")
            ? Data("""
              <timetable station='Berlin Hbf'><s id="1"><tl c="S" n="15"/><dp pt="2701150900" pp="12"/></s></timetable>
              """.utf8)
            : Data("<timetable></timetable>".utf8)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// Same schedule as `UnchangedS15Protocol`, but `/fchg` now reports a Gleisänderung (platform 12 -> 14).
private final class ChangedS15Protocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.path
        let body: Data
        if path.contains("plan/") {
            body = Data("""
            <timetable station='Berlin Hbf'><s id="1"><tl c="S" n="15"/><dp pt="2701150900" pp="12"/></s></timetable>
            """.utf8)
        } else if path.contains("fchg/8011160") {
            // `event(from:)` only builds an event when a time (planned or changed) is present, so a
            // pure platform swap still needs `ct` — here unchanged from `pt`, i.e. no delay.
            body = Data("""
            <timetable station='Berlin Hbf'><s id="1"><dp ct="2701150900" cp="14"/></s></timetable>
            """.utf8)
        } else {
            body = Data("<timetable></timetable>".utf8)
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// Real-world scenario reported for the departure board at Berlin Gesundbrunnen: Transitous carries a
/// platform for the U8 (U-Bahn) but not for the S15 (S-Bahn) on the very same board, even though DB's
/// own IRIS schedule has the S15's. `fillMissingPlatforms(in:at:)` should fill only the actual gap and
/// leave an entry that already has a platform untouched (and not fire a lookup for it at all).
@Suite struct TimetablesBoardPlatformTests {
    let gesundbrunnen = station("8011102", "Berlin Gesundbrunnen", 52.549, 13.391, source: .bahnDe)
    // 2027-01-15 08:00 UTC == 09:00 Europe/Berlin (CET) -> IRIS "2701150900".
    let departure = Date(timeIntervalSince1970: 1_800_000_000)

    func entry(line: Line, platform: PlatformInfo) -> BoardEntry {
        BoardEntry(kind: .departures, tripId: line.name, station: gesundbrunnen, line: line, otherEnd: nil,
                   time: TimeInfo(planned: departure, actual: nil), platform: platform, cancelled: false,
                   terminatesOrOriginatesHere: nil, remarks: [], source: .transitous)
    }

    @Test func fillsOnlyTheEntryMissingAPlatform() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [GesundbrunnenBoardProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let timetables = TimetablesClient(credentials: TimetablesCredentials(clientID: "x", apiKey: "y"),
                                          http: HTTPClient(session: session))

        let u8 = entry(line: Line(name: "U8", number: "8", product: .subway, operatorName: nil),
                        platform: PlatformInfo(planned: "2", actual: nil))
        let s15 = entry(line: Line(name: "S15", number: "15", product: .suburban, operatorName: nil),
                         platform: PlatformInfo(planned: nil, actual: nil))

        let filled = await timetables.fillMissingPlatforms(in: [u8, s15], at: gesundbrunnen)

        #expect(filled[0].platform == PlatformInfo(planned: "2", actual: nil))
        #expect(filled[1].platform.planned == "12")
    }
}

private final class GesundbrunnenBoardProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.path
        let body: Data = path.contains("plan/")
            ? Data("""
              <timetable station='Berlin Gesundbrunnen'><s id="1"><tl c="S" n="15"/><dp pt="2701150900" pp="12"/></s></timetable>
              """.utf8)
            : Data("<timetable></timetable>".utf8)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite struct BahnDeEvaNumberTests {
    /// Real-world bug found while investigating the Gesundbrunnen platform report: bahn.de's own
    /// search for "Berlin Gesundbrunnen" also returns two closely clustered, separately-EVA'd
    /// entrances ("Gesundbrunnen Bahnhof (S+U)" and "Gesundbrunnen Bahnhof Badstr.") a few hundred
    /// meters from the main station. `evaNumber(for:)` used to pick whichever was nearest by raw
    /// coordinate distance, which landed on "610701" (Badstr.) - a sub-entrance with no Timetables
    /// ("IRIS") schedule of its own - instead of the actual station EVA "8011102", silently making
    /// every DB Timetables lookup for Gesundbrunnen come back empty. A name match must be preferred.
    @Test func prefersExactNameMatchOverNearerDecoyEntrance() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [GesundbrunnenSearchProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let bahnDe = BahnDeClient(http: HTTPClient(session: session))

        // Transitous's own coordinate for the station, closer to the "Badstr." decoy than to the
        // main station's own bahn.de coordinate - reproducing the real report.
        let station = Station(id: "de:11000:900003201", name: "S+U Gesundbrunnen Bhf (Berlin)",
                               coordinate: Coordinate(latitude: 52.548424, longitude: 13.388507),
                               evaNumber: nil, source: .transitous)

        let eva = try await bahnDe.evaNumber(for: station)

        #expect(eva == "8011102")
    }
}

private final class GesundbrunnenSearchProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let body = Data("""
        [
          {"extId":"8011102","name":"Berlin Gesundbrunnen","lat":52.548656,"lon":13.39106,"type":"ST"},
          {"extId":"730796","name":"Gesundbrunnen Bahnhof (S+U), Berlin","lat":52.54897,"lon":13.388264,"type":"ST"},
          {"extId":"610701","name":"Gesundbrunnen Bahnhof Badstr., Berlin","lat":52.548424,"lon":13.388507,"type":"ST"}
        ]
        """.utf8)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
