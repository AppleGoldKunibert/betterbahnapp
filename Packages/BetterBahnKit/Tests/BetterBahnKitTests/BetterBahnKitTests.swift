import Foundation
import Synchronization
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

    /// Real-world Transitous rows at Berlin Hbf: DELFI names the RE 3 "RE3 (3309)", VBB's own feed
    /// only "RE3" with the run number as trip short name, so trains only VBB had showed no number.
    /// Both are named the DELFI way, and the same run from both feeds is one board row.
    @Test func regionalRunNumberFromVBB() throws {
        func row(_ minute: Int, _ name: String, _ short: String, _ trip: String, live: Bool, to: String) -> String {
            """
            {"place": {"name": "Berlin Hbf", "lat": 52.52, "lon": 13.37,
                       "departure": "2026-10-06T12:\(minute):00Z", "scheduledDeparture": "2026-10-06T12:\(minute):00Z"},
             "mode": "REGIONAL_RAIL", "realTime": \(live), "tripId": "\(trip)", "headsign": "\(to)",
             "routeShortName": "\(name.prefix { $0 != " " })", "displayName": "\(name)", "tripShortName": "\(short)"}
            """
        }
        let json = """
        {"stopTimes": [
            \(row(41, "RE3 (3309)", "003309", "delfi-3309", live: true, to: "Lutherstadt Wittenberg Hbf")),
            \(row(41, "RE3", "03309", "vbb-3309", live: false, to: "Lutherstadt Wittenberg, Hauptbahnhof")),
            \(row(46, "RE8", "62018", "vbb-62018", live: true, to: "Elsterwerda, Bahnhof")),
            \(row(46, "RE8 (62018)", "062018", "delfi-62018", live: true, to: "Elsterwerda, Bahnhof")),
            \(row(52, "RE3", "03351", "vbb-3351", live: true, to: "Lutherstadt Wittenberg Hbf")),
            \(row(53, "RE3", "03353", "vbb-3353", live: false, to: "Lutherstadt Wittenberg Hbf")),
            \(row(54, "MEX18", "", "mex", live: false, to: "Sonstwo"))
        ]}
        """
        let stopTimes = try JSONDecoding.decoder.decode(MStopTimesResponse.self, from: Data(json.utf8)).stopTimes
        let entries = stopTimes.compactMap { $0.toEntry(kind: .departures) }
        #expect(entries[1].line.name == "RE3 (3309)")
        #expect(entries[1].line.number == "3309" && entries[1].line.tripNumber == "3309")
        #expect(entries[4].line.name == "RE3 (3351)")
        #expect(entries[6].line.name == "MEX18")

        let board = TransitousProvider.deduplicated(entries)
        #expect(board.map(\.tripId) == ["delfi-3309", "vbb-62018", "vbb-3351", "vbb-3353", "mex"])
        #expect(board.map(\.line.name) == ["RE3 (3309)", "RE8 (62018)", "RE3 (3351)", "RE3 (3353)", "MEX18"])
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

    /// Real-world Transitous data for Berlin Hbf (#105): ICEs going on to Gesundbrunnen may not be
    /// boarded there, so MOTIS leaves them out of the departures and only lists them as arrivals. They
    /// show as departures marked "Nur Ausstieg"; trains ending here and ones already departing don't.
    @Test func continuingArrivalsWithoutBoardingBecomeDepartures() throws {
        let arrivalsJSON = """
        {"stopTimes": [
          {"place": {"name": "S+U Berlin Hauptbahnhof", "lat": 52.525, "lon": 13.369,
             "scheduledArrival": "2026-10-05T20:33:00Z", "scheduledDeparture": "2026-10-05T20:37:00Z",
             "arrival": "2026-10-05T20:33:00Z", "departure": "2026-10-05T20:37:00Z",
             "pickupType": "NOT_ALLOWED", "dropoffType": "NORMAL"},
           "mode": "HIGHSPEED_RAIL", "tripId": "ice594", "displayName": "ICE 594", "tripShortName": "594",
           "headsign": "S+U Gesundbrunnen Bhf (Berlin)",
           "tripTo": {"name": "S+U Gesundbrunnen Bhf (Berlin)", "lat": 52.548, "lon": 13.388}},
          {"place": {"name": "S+U Berlin Hauptbahnhof", "lat": 52.525, "lon": 13.369,
             "scheduledArrival": "2026-10-05T21:29:00Z", "arrival": "2026-10-05T21:29:00Z"},
           "mode": "HIGHSPEED_RAIL", "tripId": "ice500", "displayName": "ICE 500", "tripShortName": "500",
           "tripTo": {"name": "S+U Berlin Hauptbahnhof", "lat": 52.525, "lon": 13.369}},
          {"place": {"name": "S+U Berlin Hauptbahnhof", "lat": 52.525, "lon": 13.369,
             "scheduledArrival": "2026-10-05T21:25:00Z", "scheduledDeparture": "2026-10-05T21:28:00Z"},
           "mode": "HIGHSPEED_RAIL", "tripId": "ice870", "displayName": "ICE 870", "tripShortName": "870",
           "tripTo": {"name": "Hamburg-Altona", "lat": 53.55, "lon": 9.93}}
        ]}
        """
        let departuresJSON = """
        {"stopTimes": [
          {"place": {"name": "S+U Berlin Hauptbahnhof", "lat": 52.525, "lon": 13.369,
             "scheduledArrival": "2026-10-05T21:25:00Z", "scheduledDeparture": "2026-10-05T21:28:00Z"},
           "mode": "HIGHSPEED_RAIL", "tripId": "ice870", "displayName": "ICE 870", "tripShortName": "870",
           "tripTo": {"name": "Hamburg-Altona", "lat": 53.55, "lon": 9.93}}
        ]}
        """
        let arrivals = try JSONDecoding.decoder.decode(MStopTimesResponse.self, from: Data(arrivalsJSON.utf8)).stopTimes
        let departures = try JSONDecoding.decoder.decode(MStopTimesResponse.self, from: Data(departuresJSON.utf8)).stopTimes

        let added = TransitousProvider.continuingWithoutBoarding(arrivals, missingFrom: departures)
        #expect(added.map(\.tripId) == ["ice594"])
        let entry = try #require(added.first?.toEntry(kind: .departures))
        #expect(entry.kind == .departures)
        #expect(entry.access == .exitOnly)
        #expect(entry.time.planned == ISO8601DateFormatter().date(from: "2026-10-05T20:37:00Z"))
        #expect(entry.otherEnd == Station.displayName(for: "S+U Gesundbrunnen Bhf (Berlin)"))
        #expect(BoardFilter().includes(entry))
    }

    /// ICE 204 arrives at Hamburg-Harburg at 13:02 and leaves at 13:04, only to let people off. A
    /// search from 13:04 must still see it (its arrival lies before the start), one from 13:05 not.
    @Test func noBoardingTrainArrivingBeforeStartStillLeaves() throws {
        let arrivalsJSON = """
        {"stopTimes": [
          {"place": {"name": "Hamburg-Harburg", "lat": 53.456, "lon": 9.992,
             "scheduledArrival": "2026-10-06T11:02:00Z", "arrival": "2026-10-06T11:01:00Z",
             "scheduledDeparture": "2026-10-06T11:04:00Z", "departure": "2026-10-06T11:04:00Z",
             "pickupType": "NOT_ALLOWED", "dropoffType": "NORMAL"},
           "mode": "HIGHSPEED_RAIL", "tripId": "ice204", "displayName": "ICE 204", "tripShortName": "204",
           "tripTo": {"name": "Hamburg-Altona", "lat": 53.552, "lon": 9.935}}
        ]}
        """
        let arrivals = try JSONDecoding.decoder.decode(MStopTimesResponse.self, from: Data(arrivalsJSON.utf8)).stopTimes
        let start = try #require(ISO8601DateFormatter().date(from: "2026-10-06T11:04:00Z"))
        #expect(TransitousProvider.continuingWithoutBoarding(arrivals, missingFrom: [], departingFrom: start)
            .map(\.tripId) == ["ice204"])
        #expect(TransitousProvider.continuingWithoutBoarding(arrivals, missingFrom: [], departingFrom: start.addingTimeInterval(60))
            .isEmpty)
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

    /// Real-world ICE 573 Hamburg–Stuttgart: its `headsign` is the bare "Hauptbahnhof (oben)", which
    /// showed up as the destination "Hbf" on boards and as the leg's direction.
    @Test func stuttgartHbfAsDestinationShowsAsStuttgartHbf() throws {
        let tripTo = """
        {"name": "Hauptbahnhof (oben)", "stopId": "de-DELFI_de:08111:6115:3:5", "parentId": "de-DELFI_de:08111:6115", "lat": 48.78, "lon": 9.18}
        """
        let board = """
        {"stopTimes": [{
            "place": {"name": "Hamburg Hbf", "stopId": "hh", "lat": 53.55, "lon": 10.0,
                      "departure": "2026-09-30T03:29:00Z", "scheduledDeparture": "2026-09-30T03:29:00Z"},
            "mode": "HIGHSPEED_RAIL", "realTime": false, "tripId": "ice-573", "displayName": "ICE 573",
            "headsign": "Hauptbahnhof (oben)", "tripTo": \(tripTo)
        }]}
        """
        let entries = try JSONDecoding.decoder.decode(MStopTimesResponse.self, from: Data(board.utf8))
            .stopTimes.compactMap { $0.toEntry(kind: .departures) }
        #expect(entries.map(\.otherEnd) == ["Stuttgart Hbf"])

        let leg = """
        {"mode": "HIGHSPEED_RAIL", "headsign": "Hauptbahnhof (oben)", "tripTo": \(tripTo),
         "from": {"name": "Hamburg Hbf", "lat": 53.55, "lon": 10.0},
         "to": {"name": "Frankfurt (Main) Hauptbahnhof", "lat": 50.1, "lon": 8.66},
         "startTime": "2026-09-30T03:29:00Z", "endTime": "2026-09-30T06:50:00Z"}
        """
        let decoded = try JSONDecoding.decoder.decode(MLeg.self, from: Data(leg.utf8))
        #expect(decoded.direction == "Stuttgart Hbf")
    }

    /// DELFI's "<town>, Bahnhof" names are shown as just the town, like DB does (#45).
    @Test func bahnhofSuffixIsDropped() {
        #expect(Station.displayName(for: "Rheine, Bahnhof") == "Rheine")
        #expect(Station.displayName(for: "Friesack (Mark), Bahnhof") == "Friesack (Mark)")
        #expect(Station.displayName(for: "Bahnhofstraße") == "Bahnhofstraße")
    }

    /// DELFI leaves out the river/region some towns need ("Schwedt, Bahnhof"); the direction showed
    /// "Schwedt" instead of DB's "Schwedt (Oder)" (#85). Other stops in the town keep their name.
    @Test func delfiTownsGetTheirQualifierBack() {
        #expect(Station.displayName(for: "Schwedt, Bahnhof") == "Schwedt (Oder)")
        #expect(Station.displayName(for: "Lübbenau, Bahnhof") == "Lübbenau (Spreewald)")
        #expect(Station.displayName(for: "Falkenberg/E., Bahnhof") == "Falkenberg (Elster)")
        #expect(Station.displayName(for: "Schwedt (Oder)") == "Schwedt (Oder)")
        #expect(Station.displayName(for: "Schwedt, ZOB") == "Schwedt, ZOB")
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

    /// Real-world Transitous names that came out garbled because the Berlin-style "<stop> (<city>)"
    /// rewrite ran on every name, plus other leftovers from the feeds' own naming.
    @Test func displayNameCleansUpFeedNames() {
        // Brackets outside VBB tell apart same-named towns and stay where they are.
        #expect(Station.displayName(for: "Borna (Leipzig)") == "Borna (Leipzig)")
        #expect(Station.displayName(for: "Böhlen (b. Leipzig)") == "Böhlen (bei Leipzig)")
        #expect(Station.displayName(for: "Friedberg (b Augsburg)") == "Friedberg (bei Augsburg)")
        #expect(Station.displayName(for: "Weiler (R)") == "Weiler (Rems)")
        // Notes that say nothing about the place are dropped.
        #expect(Station.displayName(for: "Rosenheim (DE)") == "Rosenheim")
        #expect(Station.displayName(for: "Fulda (FlixTrain)") == "Fulda")
        #expect(Station.displayName(for: "Frankfurt Flugh (DE)") == "Frankfurt Flughafen")
        // No comma before Hbf.
        #expect(Station.displayName(for: "Aachen, Hauptbahnhof") == "Aachen Hbf")
        // VBB stations outside Berlin go by their town.
        #expect(Station.displayName(for: "S Oranienburg Bhf") == "Oranienburg")
        #expect(Station.displayName(for: "S Bernau Bhf") == "Bernau (bei Berlin)")
        #expect(Station.displayName(for: "S Ostkreuz Bhf (Berlin)") == "Berlin Ostkreuz")
        #expect(Station.displayName(for: "S Tegel (Berlin)") == "Berlin-Tegel")
    }

    /// Real-world Transitous geocode hits for "hbf": Stuttgart's and München's main stations come
    /// without their city ("Hauptbahnhof (tief)", "Hauptbahnhof Süd") and showed up as just "Hbf"
    /// and "Hbf Süd" - the town from the hit's areas is put in front.
    @Test func searchPutsTheTownInFrontOfABareHauptbahnhof() {
        func match(_ name: String, town: String) -> MGeocodeMatch {
            MGeocodeMatch(type: "STOP", name: name, id: name, lat: 48.78, lon: 9.18, country: "DE",
                          modes: ["REGIONAL_RAIL"], areas: [.init(name: town, adminLevel: 6, isDefault: true)])
        }
        #expect(match("Hauptbahnhof (tief)", town: "Stuttgart").toStation().displayName == "Stuttgart Hbf")
        #expect(match("Hauptbahnhof Süd", town: "München").toStation().displayName == "München Hbf Süd")
        #expect(match("Ulm Hauptbahnhof", town: "Ulm").toStation().displayName == "Ulm Hbf")
    }

    /// DB's own names leave out the space before the bracket, which the bracket rules missed.
    @Test func displayNameHandlesDBsBracketsWithoutSpace() {
        #expect(Station.displayName(for: "Bernau(b Berlin)") == "Bernau (bei Berlin)")
        #expect(Station.displayName(for: "Frankfurt(Oder)") == "Frankfurt (Oder)")
    }

    /// With the user's location, train stations are grouped into distance bands (50–100 km before
    /// 200–300 km and so on), ahead of the usual Germany-first/main-station order, so searching
    /// "Bernau" from Munich finds Bernau am Chiemsee (~80 km) before Bernau bei Berlin (~500 km).
    @Test func searchSortsTrainStationsByDistanceBand() {
        let munich = Coordinate(latitude: 48.14, longitude: 11.56)
        let farMain = MGeocodeMatch(type: "STOP", name: "Berlin Hauptbahnhof", id: "far", lat: 52.52, lon: 13.37,
                                    country: "DE", modes: ["HIGHSPEED_RAIL", "REGIONAL_RAIL"])
        let far = MGeocodeMatch(type: "STOP", name: "S Bernau Bhf", id: "bernau-berlin", lat: 52.68, lon: 13.59,
                                country: "DE", modes: ["REGIONAL_RAIL", "SUBURBAN"])
        let near = MGeocodeMatch(type: "STOP", name: "Bernau am Chiemsee", id: "bernau-chiemsee", lat: 47.82, lon: 12.38,
                                 country: "DE", modes: ["REGIONAL_RAIL"])
        let austria = MGeocodeMatch(type: "STOP", name: "Salzburg Hbf", id: "salzburg", lat: 47.81, lon: 13.05,
                                    country: "AT", modes: ["HIGHSPEED_RAIL", "REGIONAL_RAIL"])
        let bus = MGeocodeMatch(type: "STOP", name: "Bernau Bus", id: "bus", lat: 48.14, lon: 11.56,
                                country: "DE", modes: ["BUS"])

        func ranked(near location: Coordinate?) -> [String] {
            [bus, farMain, far, austria, near].enumerated()
                .sorted { TransitousProvider.searchRank($0.element, query: "x", offset: $0.offset, near: location)
                        > TransitousProvider.searchRank($1.element, query: "x", offset: $1.offset, near: location) }
                .map(\.element.id)
        }

        // Bernau bei Berlin is preferred and stays first; then ~80 km, Berlin Hbf (~500 km) after,
        // the nearby bus stop, and Salzburg (~120 km, abroad, not typed) last.
        #expect(ranked(near: munich) == ["bernau-berlin", "bernau-chiemsee", "far", "bus", "salzburg"])
        // Without a location: Bernau bei Berlin, then German trains (main stations first), then Austria.
        #expect(ranked(near: nil) == ["bernau-berlin", "far", "bernau-chiemsee", "salzburg", "bus"])

        // Typing "Bernau": Bernau bei Berlin matches exactly too (without its bracket) and comes first.
        // A bus stop named exactly "Bernau" 150 km away doesn't count as exact (only nearby ones do),
        // so the train station at the Chiemsee comes before it.
        let exactBus = MGeocodeMatch(type: "STOP", name: "Bernau", id: "exact-bus", lat: 49.17, lon: 10.33,
                                     country: "DE", modes: ["BUS"])
        let typed = [exactBus, near, far].enumerated()
            .sorted { TransitousProvider.searchRank($0.element, query: "Bernau", offset: $0.offset, near: munich)
                    > TransitousProvider.searchRank($1.element, query: "Bernau", offset: $1.offset, near: munich) }
            .map(\.element.id)
        #expect(typed == ["bernau-berlin", "bernau-chiemsee", "exact-bus"])
        #expect(TransitousProvider.distanceBand(forMeters: 75_000) == 1)
        #expect(TransitousProvider.distanceBand(forMeters: 1_200_000) == 7)
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

    /// Real-world geocode hits for "Berlin-Gesundbrunnen": "gesund" typed far from Berlin only finds
    /// SNCF's entry, whose board has nothing but the bus 247. Boards and journeys use DELFI's far busier
    /// station there instead; the U-Bahn stop and a station elsewhere don't count.
    @Test func busierStopReplacesForeignFeedsGermanStation() {
        let sncf = MGeocodeMatch(type: "STOP", name: "Berlin-Gesundbrunnen",
                                 id: "fr-horaires-sncf_FR::LMO:71a3fb60-3a69-11e9-8417-bb1d8a705241:",
                                 lat: 52.5488, lon: 13.391, country: "DE",
                                 modes: ["HIGHSPEED_RAIL", "LONG_DISTANCE", "NIGHT_RAIL", "REGIONAL_RAIL", "BUS"],
                                 importance: 0.000174)
        let delfi = MGeocodeMatch(type: "STOP", name: "S+U Gesundbrunnen Bhf (Berlin)", id: "de-DELFI_de:11000:900007102",
                                  lat: 52.548637, lon: 13.388372, country: "DE",
                                  modes: ["HIGHSPEED_RAIL", "LONG_DISTANCE", "REGIONAL_RAIL", "SUBURBAN", "SUBWAY", "BUS"],
                                  importance: 0.00865)
        let subway = MGeocodeMatch(type: "STOP", name: "U Gesundbrunnen (Berlin)", id: "de-VBB_u8",
                                   lat: 52.5487, lon: 13.3895, country: "DE", modes: ["SUBWAY"], importance: 0.02)
        let elsewhere = MGeocodeMatch(type: "STOP", name: "Northeim Gesundbrunnen", id: "de-DELFI_de:03155:68739::1",
                                      lat: 51.7067, lon: 10.0286, country: "DE", modes: ["REGIONAL_RAIL"], importance: 0.01)
        let station = sncf.toStation()

        #expect(TransitousProvider.busierStop(for: station, among: [sncf, subway, elsewhere, delfi])?.id == delfi.id)
        // Not busier by far: the stop stays.
        var quiet = delfi
        quiet.importance = 0.0005
        #expect(TransitousProvider.busierStop(for: station, among: [sncf, quiet]) == nil)
    }

    /// Real-world board at Berlin Gesundbrunnen: an extra S1 to Frohnau DB added at short notice came
    /// without a line ("?", mode OTHER). It takes the line of the other trains to Frohnau; one to a
    /// destination two lines go to stays unknown.
    @Test func boardNamesUnknownLinesAfterTrainsToTheSameDestination() {
        let gesundbrunnen = Station(id: "g", name: "Berlin Gesundbrunnen", coordinate: nil, evaNumber: nil, source: .transitous)
        func entry(_ name: String, _ product: Product, to otherEnd: String, platform: String?) -> BoardEntry {
            BoardEntry(kind: .departures, tripId: UUID().uuidString, station: gesundbrunnen,
                       line: Line(name: name, number: nil, product: product, operatorName: nil), otherEnd: otherEnd,
                       time: TimeInfo(planned: .now, actual: nil), platform: PlatformInfo(planned: platform, actual: nil),
                       cancelled: false, terminatesOrOriginatesHere: false, remarks: [], source: .transitous)
        }
        let entries = [
            entry("S1", .suburban, to: "Berlin-Frohnau", platform: "4"),
            entry("S26", .suburban, to: "Berlin-Blankenburg", platform: "4"),
            entry("? ", .other, to: "Berlin-Frohnau", platform: "4"),
            entry("S25", .suburban, to: "Berlin-Hennigsdorf", platform: "4"),
            entry("RE5", .regionalExpress, to: "Berlin-Hennigsdorf", platform: "6"),
            entry("?", .other, to: "Berlin-Hennigsdorf", platform: nil),
        ]

        let named = TransitousProvider.namingUnknownLines(entries)

        #expect(named[2].line.name == "S1")
        #expect(named[2].line.product == .suburban)
        #expect(named[5].line.name == "?")
    }

    /// The row two lines could be: bahn.de's board has the train at that time to that destination.
    @Test func bahnDeNamesUnknownLines() throws {
        let gesundbrunnen = Station(id: "g", name: "Berlin Gesundbrunnen", coordinate: nil, evaNumber: nil, source: .transitous)
        let planned = try #require(JSONDecoding.parseISODate("2026-10-05T09:51:00Z"))
        let unknown = BoardEntry(kind: .departures, tripId: "extra", station: gesundbrunnen,
                                 line: Line(name: "? ", number: "", product: .other, operatorName: nil),
                                 otherEnd: "Berlin-Frohnau", time: TimeInfo(planned: planned, actual: nil),
                                 platform: PlatformInfo(planned: "4", actual: nil), cancelled: false,
                                 terminatesOrOriginatesHere: false, remarks: [], source: .transitous)
        let json = #"""
        {"entries": [
            {"journeyId": "s26", "zeit": "2026-10-05T11:51:00", "terminus": "Berlin-Blankenburg",
             "verkehrmittel": {"name": "S 26", "produktGattung": "SBAHN"}},
            {"journeyId": "s1", "zeit": "2026-10-05T11:51:00", "terminus": "Berlin-Frohnau",
             "verkehrmittel": {"name": "S 1", "produktGattung": "SBAHN"}}
        ]}
        """#
        let board = try JSONDecoding.decoder.decode(BahnDeClient.Board.self, from: Data(json.utf8)).entries

        let named = BahnDeClient.namingUnknownLines([unknown], using: board)

        #expect(named[0].line.name == "S1")
        #expect(named[0].line.product == .suburban)
        #expect(BahnDeClient.namingUnknownLines([unknown], using: [board[0]])[0].line.name == "? ")
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
        // Matches every typed word too, just not the whole name.
        let plainDeTrain = match("plainDeTrain", name: "Berlin Hbf Europaplatz", country: "DE", modes: ["REGIONAL_RAIL"])

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

    /// Real-world hits (issue #57): what was typed – the town included – counts before the kind of
    /// station, so a tram or bus stop matching every word beats a train station matching only one,
    /// and the stop in the town that was typed beats same-named stops elsewhere.
    @Test func searchRankPrefersHitsMatchingEveryTypedWord() {
        func area(_ name: String, _ level: Double, town: Bool = false) -> MGeocodeMatch.Area {
            .init(name: name, adminLevel: level, isDefault: town)
        }
        func match(_ id: String, _ name: String, modes: [String], areas: [MGeocodeMatch.Area]) -> MGeocodeMatch {
            MGeocodeMatch(type: "STOP", name: name, id: id, lat: 0, lon: 0, country: "DE", modes: modes, areas: areas)
        }
        func ranked(_ query: String, _ matches: [MGeocodeMatch]) -> [String] {
            matches.enumerated()
                .sorted { TransitousProvider.searchRank($0.element, query: query, offset: $0.offset)
                        > TransitousProvider.searchRank($1.element, query: query, offset: $1.offset) }
                .map(\.element.id)
        }

        let leipzig = [area("Deutschland", 2), area("Sachsen", 4), area("Leipzig", 6, town: true)]
        let leipzigHbf = match("leipzigHbf", "Leipzig Hbf", modes: ["HIGHSPEED_RAIL", "REGIONAL_RAIL", "TRAM"], areas: leipzig)
        let augustusplatz = match("augustusplatz", "Leipzig, Augustusplatz", modes: ["TRAM", "BUS"], areas: leipzig)
        #expect(ranked("Leipzig Augustusplatz", [leipzigHbf, augustusplatz]) == ["augustusplatz", "leipzigHbf"])
        #expect(ranked("Leipzig Augustusp", [leipzigHbf, augustusplatz]) == ["augustusplatz", "leipzigHbf"])

        let spandau = [area("Deutschland", 2), area("Berlin", 4, town: true), area("Spandau", 9), area("Spandau", 10)]
        let rathausSpandau = match("rathausSpandau", "S+U Rathaus Spandau (Berlin)", modes: ["SUBWAY", "BUS"], areas: spandau)
        let berlinSpandau = match("berlinSpandau", "S Spandau Bhf (Berlin)", modes: ["LONG_DISTANCE", "SUBURBAN"], areas: spandau)
        let kasselRathaus = match("kasselRathaus", "Kassel Rathaus", modes: ["SUBURBAN", "TRAM"],
                                  areas: [area("Hessen", 4), area("Kassel", 6, town: true)])
        #expect(ranked("Rathaus Spandau", [berlinSpandau, kasselRathaus, rathausSpandau]).first == "rathausSpandau")

        // The town is only in the stop's areas, not its name.
        let bernau = [area("Deutschland", 2), area("Brandenburg", 4), area("Barnim", 6), area("Bernau", 8, town: true)]
        let bernauStop = match("bernauStop", "Bahnhofstraße", modes: ["BUS"], areas: bernau)
        let orlamuende = match("orlamuende", "Orlamünde, Bahnhofstraße", modes: ["REGIONAL_RAIL", "BUS"],
                               areas: [area("Thüringen", 4), area("Orlamünde", 8, town: true)])
        let bernauTrain = match("bernauTrain", "S Bernau Bhf", modes: ["REGIONAL_RAIL", "SUBURBAN"], areas: bernau)
        #expect(ranked("Bahnhofstraße Bernau", [orlamuende, bernauTrain, bernauStop]).first == "bernauStop")
        #expect(ranked("Bernau Bahnhofstr.", [orlamuende, bernauTrain, bernauStop]).first == "bernauStop")
        // Areas above the town don't count: not every stop in Brandenburg is "Brandenburg".
        #expect(TransitousProvider.textMatchScore(bernauStop, query: "Brandenburg") == 0)
        #expect(TransitousProvider.textMatchScore(bernauStop, query: "Barnim") == 0)
    }

    /// Real-world hits for "München": the village station "München (Bad Berka)" (in Thuringia) came
    /// before Munich's own stations, being a train station with exactly that name, and nearer from Berlin.
    @Test func searchRankPutsTheTypedTownBeforeSameNamedPlaces() {
        func area(_ name: String, _ level: Double, town: Bool = false) -> MGeocodeMatch.Area {
            .init(name: name, adminLevel: level, isDefault: town)
        }
        let munich = [area("Bayern", 4), area("München", 6, town: true)]
        let hbf = MGeocodeMatch(type: "STOP", name: "München Hbf", id: "hbf", lat: 48.140, lon: 11.558, country: "DE",
                                modes: ["HIGHSPEED_RAIL", "REGIONAL_RAIL"], areas: munich, importance: 0.0259)
        let pasing = MGeocodeMatch(type: "STOP", name: "München Pasing", id: "pasing", lat: 48.150, lon: 11.462, country: "DE",
                                   modes: ["HIGHSPEED_RAIL", "REGIONAL_RAIL"], areas: munich, importance: 0.00005)
        let marienplatz = MGeocodeMatch(type: "STOP", name: "Marienplatz", id: "marienplatz", lat: 48.137, lon: 11.575,
                                        country: "DE", modes: ["SUBWAY", "BUS"], areas: munich, importance: 0.003)
        let berka = MGeocodeMatch(type: "STOP", name: "München (Bad Berka)", id: "berka", lat: 50.870, lon: 11.255, country: "DE",
                                  modes: ["REGIONAL_RAIL"],
                                  areas: [area("Thüringen", 4), area("Bad Berka", 8, town: true), area("München", 11)],
                                  importance: 0.00026)
        let hits = [berka, marienplatz, pasing, hbf]
        let typedTown = hits.contains { TransitousProvider.isInTown(named: "München", $0) }
        #expect(typedTown)
        for location in [nil, Coordinate(latitude: 52.52, longitude: 13.40)] {
            let ranked = hits.enumerated()
                .sorted { TransitousProvider.searchRank($0.element, query: "München", offset: $0.offset, near: location, typedTown: typedTown)
                        > TransitousProvider.searchRank($1.element, query: "München", offset: $1.offset, near: location, typedTown: typedTown) }
                .map(\.element.id)
            #expect(ranked.last == "berka")
            #expect(ranked.first == "hbf")
        }
        #expect(TransitousProvider.isInTown(named: "Muench", pasing))
        #expect(!TransitousProvider.isInTown(named: "Pasing", pasing))
    }

    @Test func textMatchScoreHandlesSpellingsAndAbbreviations() {
        func match(_ name: String) -> MGeocodeMatch {
            MGeocodeMatch(type: "STOP", name: name, id: name, lat: 0, lon: 0, country: "DE", modes: ["REGIONAL_RAIL"])
        }
        #expect(TransitousProvider.textMatchScore(match("Köln Hbf"), query: "Koeln Hauptbahnhof") == 4)
        #expect(TransitousProvider.textMatchScore(match("MUENCHEN HBF"), query: "München") == 2)
        #expect(TransitousProvider.textMatchScore(match("Berlin, Hauptstr."), query: "Hauptstraße") == 2)
        // A whole word beats a word that only starts with what was typed.
        #expect(TransitousProvider.textMatchScore(match("Bonn Hbf"), query: "Bonn") == 2)
        #expect(TransitousProvider.textMatchScore(match("Bönningstedt"), query: "Bonn") == 1)
        #expect(TransitousProvider.textMatchScore(match("Bernhausen Hauptstraße"), query: "Bernau") == 0)
    }

    /// From Berlin, "Frankfurt" used to list the small stations around Frankfurt (Oder) before
    /// Frankfurt (M) Hbf, being in a nearer distance band. Busy stations count as nearer now.
    @Test func searchRankLetsBusyStationsCountAsNearer() {
        let berlin = Coordinate(latitude: 52.52, longitude: 13.40)
        func town(_ name: String) -> [MGeocodeMatch.Area] { [.init(name: name, adminLevel: 6, isDefault: true)] }
        let mainHbf = MGeocodeMatch(type: "STOP", name: "Frankfurt (M) Hbf", id: "main", lat: 50.107, lon: 8.663,
                                    country: "DE", modes: ["HIGHSPEED_RAIL", "REGIONAL_RAIL"],
                                    areas: town("Frankfurt am Main"), importance: 0.0215)
        let oder = MGeocodeMatch(type: "STOP", name: "Frankfurt (Oder)", id: "oder", lat: 52.336, lon: 14.546,
                                 country: "DE", modes: ["LONG_DISTANCE", "REGIONAL_RAIL"],
                                 areas: town("Frankfurt (Oder)"), importance: 0.0028)
        let border = MGeocodeMatch(type: "STOP", name: "Frankfurt(Oder), Grenze", id: "border", lat: 52.34, lon: 14.56,
                                   country: "PL", modes: ["REGIONAL_RAIL"], importance: 0.00043)
        let small = MGeocodeMatch(type: "STOP", name: "Frankfurt(Oder)-Rosengarten", id: "small", lat: 52.31, lon: 14.46,
                                  country: "DE", modes: ["REGIONAL_RAIL"], importance: 0.0001)
        let ranked = [small, border, oder, mainHbf].enumerated()
            .sorted { TransitousProvider.searchRank($0.element, query: "Frankfurt", offset: $0.offset, near: berlin)
                    > TransitousProvider.searchRank($1.element, query: "Frankfurt", offset: $1.offset, near: berlin) }
            .map(\.element.id)
        #expect(ranked == ["main", "oder", "border", "small"])

        // A coach stop named just "Bonn" in Bonn doesn't count as an exact match for "Bonn".
        let bonnArea = [MGeocodeMatch.Area(name: "Bonn", adminLevel: 6, isDefault: true)]
        let bonnCoach = MGeocodeMatch(type: "STOP", name: "Bonn", id: "coach", lat: 50.73, lon: 7.10,
                                      country: "DE", modes: ["COACH"], areas: bonnArea)
        let bonnHbf = MGeocodeMatch(type: "STOP", name: "Bonn Hbf", id: "bonnHbf", lat: 50.732, lon: 7.097,
                                    country: "DE", modes: ["LONG_DISTANCE", "REGIONAL_RAIL"], areas: bonnArea, importance: 0.0026)
        let bonn = [bonnCoach, bonnHbf].enumerated()
            .sorted { TransitousProvider.searchRank($0.element, query: "Bonn", offset: $0.offset, near: berlin)
                    > TransitousProvider.searchRank($1.element, query: "Bonn", offset: $1.offset, near: berlin) }
            .map(\.element.id)
        #expect(bonn == ["bonnHbf", "coach"])
        #expect(TransitousProvider.bandShift(forImportance: nil) == 0)
        #expect(TransitousProvider.bandShift(forImportance: 0.0005) == 0)
        #expect(TransitousProvider.bandShift(forImportance: 0.5) == 4)
    }

    @Test func mainStationQueryOnlyForATownName() {
        #expect(TransitousProvider.mainStationQuery(for: "Potsdam ") == "Potsdam Hbf")
        #expect(TransitousProvider.mainStationQuery(for: "Potsdam Hbf") == nil)
        #expect(TransitousProvider.mainStationQuery(for: "Hauptbahnhof") == nil)
        #expect(TransitousProvider.mainStationQuery(for: "Leipzig Augustusplatz") == nil)
        #expect(TransitousProvider.mainStationQuery(for: "Ber") == nil)
    }

    /// For "Potsdam", none of the geocoder's hits is Potsdam Hbf; it's asked for "Potsdam Hbf" too,
    /// and of those hits only the ones in Potsdam are kept.
    @Test func searchStationsAddsTheTownsMainStation() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MainStationGeocodeProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let provider = TransitousProvider(http: HTTPClient(session: session))

        let stations = try await provider.searchStations("Potsdam")

        #expect(stations.map(\.id) == ["potsdamHbf", "golm"])
    }

    /// Real-world hits (issue #91): from Berlin, "ber" lists Flughafen BER before Bern and "ost" Berlin's
    /// stations before Ulm Ost, while from Munich Bern (nearer there) stays first and typing "bern"
    /// in full keeps Bern on top. Without a location the order stays as before.
    @Test func searchRankWeighsNearbyStationsAgainstTheText() {
        let berlin = Coordinate(latitude: 52.52, longitude: 13.405)
        let munich = Coordinate(latitude: 48.14, longitude: 11.56)
        func match(_ id: String, _ name: String, _ lat: Double, _ lon: Double, _ country: String,
                   _ modes: [String], _ importance: Double) -> MGeocodeMatch {
            MGeocodeMatch(type: "STOP", name: name, id: id, lat: lat, lon: lon, country: country, modes: modes,
                          importance: importance)
        }
        func ranked(_ query: String, _ matches: [MGeocodeMatch], near location: Coordinate?) -> [String] {
            matches.enumerated()
                .sorted { TransitousProvider.searchRank($0.element, query: query, offset: $0.offset, near: location)
                        > TransitousProvider.searchRank($1.element, query: query, offset: $1.offset, near: location) }
                .map(\.element.id)
        }

        let bern = match("bern", "Bern", 46.949, 7.439, "CH", ["HIGHSPEED_RAIL", "LONG_DISTANCE", "REGIONAL_RAIL"], 0.0518)
        let beroun = match("beroun", "Beroun", 49.958, 14.078, "CZ", ["REGIONAL_RAIL", "BUS"], 0.0031)
        let dilBer = match("dilBer", "Dil Ber", 9.071, 38.738, "ET", ["BUS"], 0.0002)
        let ber = match("ber", "Flughafen BER", 52.365, 13.510, "DE", ["LONG_DISTANCE", "REGIONAL_RAIL", "SUBURBAN"], 0.0033)
        let berHits = [bern, beroun, dilBer, ber]
        #expect(ranked("ber", berHits, near: berlin) == ["ber", "bern", "beroun", "dilBer"])
        // Stations abroad only count in full ("bern") or nearby: from Munich too, BER comes first.
        #expect(ranked("ber", berHits, near: munich) == ["ber", "bern", "beroun", "dilBer"])
        #expect(ranked("ber", berHits, near: nil).first == "ber")
        // Near the border, stations abroad count from the first letters: Basel from Freiburg.
        let basel = match("basel", "Basel SBB", 47.547, 7.590, "CH", ["LONG_DISTANCE", "REGIONAL_RAIL"], 0.03)
        let freiburg = Coordinate(latitude: 47.997, longitude: 7.842)
        #expect(!TransitousProvider.isFarForeign(basel, query: "bas", isTrain: true, near: freiburg))
        #expect(TransitousProvider.isFarForeign(basel, query: "bas", isTrain: true, near: berlin))
        // A train station in the place that was typed counts from anywhere, a far bus stop doesn't.
        #expect(!TransitousProvider.isFarForeign(basel, query: "basel", isTrain: true, near: berlin))
        #expect(!TransitousProvider.isFarForeign(basel, query: "Basel SBB", isTrain: true, near: berlin))
        #expect(TransitousProvider.isFarForeign(dilBer, query: "ber", isTrain: false, near: berlin))
        // "flughafen" or "ost" isn't a place: Zürich Flughafen and Interlaken Ost stay behind.
        let zurichAirport = match("zurichAirport", "Zürich Flughafen", 47.450, 8.562, "CH", ["LONG_DISTANCE"], 0.03)
        let stuttgart = Coordinate(latitude: 48.78, longitude: 9.18)
        #expect(TransitousProvider.isFarForeign(zurichAirport, query: "flughafen", isTrain: true, near: stuttgart))
        #expect(!TransitousProvider.isFarForeign(zurichAirport, query: "zürich", isTrain: true, near: stuttgart))

        let ostbf = match("ostbf", "Berlin Ostbf", 52.510, 13.435, "DE", ["HIGHSPEED_RAIL", "REGIONAL_RAIL", "SUBURBAN"], 0.0057)
        let ostkreuz = match("ostkreuz", "S Ostkreuz Bhf (Berlin)", 52.503, 13.469, "DE", ["REGIONAL_RAIL", "SUBURBAN"], 0.0089)
        let ulmOst = match("ulmOst", "Ulm Ost", 48.407, 9.995, "DE", ["REGIONAL_RAIL"], 0.00025)
        let ostra = match("ostra", "Ostrá", 50.188, 14.891, "CZ", ["REGIONAL_RAIL"], 0.0012)
        let ostHits = [ulmOst, ostra, ostbf, ostkreuz]
        // "Ostbf" is the station "Ost", like "Nordbahnhof" is "Nord".
        #expect(ranked("ost", ostHits, near: berlin) == ["ostbf", "ostkreuz", "ulmOst", "ostra"])
        #expect(ranked("ost", ostHits, near: nil).first == "ostbf")

        let bernau = match("bernau-berlin", "S Bernau Bhf", 52.68, 13.59, "DE", ["REGIONAL_RAIL", "SUBURBAN"], 0.0012)
        #expect(ranked("bern", [bernau, beroun, bern], near: berlin).first == "bern")

        // A bus stop's exact name only counts nearby: not "Zoo" in Bavaria or Wrocław for Berlin's zoo.
        let zoo = match("zoo", "S+U Zoologischer Garten Bhf (Berlin)", 52.507, 13.332, "DE",
                        ["LONG_DISTANCE", "REGIONAL_RAIL"], 0.006)
        let bavarianZoo = match("bavarianZoo", "Zoo", 49.95, 11.57, "DE", ["BUS"], 0.0001)
        let wroclawZoo = match("wroclawZoo", "ZOO", 51.10, 17.07, "PL", ["TRAM", "BUS"], 0.0003)
        let berlinZooBus = match("berlinZooBus", "Zoo", 52.506, 13.335, "DE", ["BUS"], 0.0002)
        #expect(ranked("zoo", [bavarianZoo, wroclawZoo, zoo], near: berlin) == ["zoo", "bavarianZoo", "wroclawZoo"])
        #expect(ranked("zoo", [bavarianZoo, zoo, berlinZooBus], near: berlin).first == "berlinZooBus")
        #expect(ranked("zoo", [zoo, bavarianZoo], near: nil).first == "bavarianZoo")

        // "ber" is Flughafen BER's short name, so it comes first from Munich too.
        let bergAmLaim = match("bergAmLaim", "München-Berg am Laim", 48.123, 11.633, "DE", ["SUBURBAN"], 0.002)
        #expect(ranked("ber", [bergAmLaim, ber], near: munich) == ["ber", "bergAmLaim"])

        // German names of towns abroad find their stations: "stettin" is Szczecin.
        let szczecin = match("szczecin", "Szczecin Główny", 53.418, 14.551, "PL",
                             ["LONG_DISTANCE", "REGIONAL_RAIL"], 0.0014)
        let stettinBus = match("stettinBus", "Stettin", 59.0, 16.2, "SE", ["BUS"], 0.00001)
        let stettinerStr = match("stettinerStr", "Gartz, Stettiner Str.", 53.21, 14.39, "DE", ["BUS"], 0.0001)
        #expect(ranked("stettin", [stettinBus, stettinerStr, szczecin], near: berlin).first == "szczecin")
        #expect(ranked("stettin", [stettinBus, stettinerStr, szczecin], near: nil).first == "szczecin")
    }

    /// German names of towns abroad: matched by `searchWords`, asked for in the local spelling.
    @Test func germanNamesOfTownsAbroad() {
        let szczecin = MGeocodeMatch(type: "STOP", name: "Szczecin Główny", id: "s", lat: 53.418, lon: 14.551,
                                     country: "PL")
        #expect(TransitousProvider.textMatch(szczecin, query: "Stettin") == (matched: 1, whole: 1))
        #expect(TransitousProvider.localNameQuery(for: "stettin") == "Szczecin")
        #expect(TransitousProvider.localNameQuery(for: "Brüssel Midi") == "Bruxelles Midi")
        #expect(TransitousProvider.localNameQuery(for: "Bruessel") == "Bruxelles")
        #expect(TransitousProvider.localNameQuery(for: "berlin") == nil)
        // Only the whole word: "Prager Str." isn't Praha.
        let pragerStr = MGeocodeMatch(type: "STOP", name: "Praha hl.n.", id: "p", lat: 50.08, lon: 14.43, country: "CZ")
        #expect(TransitousProvider.textMatch(pragerStr, query: "prager").matched == 0)
    }

    /// "Hbf" next to a place only counts for that place's stations, abroad too ("hl.n."), and the
    /// local query leaves it out: for "Szczecin hbf" the geocoder only lists German Hbfs. A part of
    /// town alone isn't a match either, while "Nordbahnhof" is the station "Nord".
    @Test func stationWordsAndPartsOfTownOnlyCountNextToAPlace() {
        func stop(_ name: String, country: String = "DE", town: String, district: String? = nil) -> MGeocodeMatch {
            var areas = [MGeocodeMatch.Area(name: town, adminLevel: 6, isDefault: true)]
            if let district { areas.append(.init(name: district, adminLevel: 9, isDefault: false)) }
            return MGeocodeMatch(type: "STOP", name: name, id: name, lat: 0, lon: 0, country: country, areas: areas)
        }
        let berlinHbf = stop("Berlin Hbf", town: "Berlin")
        let praha = stop("Praha hl.n.", country: "CZ", town: "Prag")
        #expect(TransitousProvider.textMatch(berlinHbf, query: "prag hbf") == (matched: 0, whole: 0))
        #expect(TransitousProvider.textMatch(praha, query: "prag hbf") == (matched: 2, whole: 2))
        #expect(TransitousProvider.textMatch(berlinHbf, query: "hbf") == (matched: 1, whole: 1))
        #expect(TransitousProvider.textMatch(berlinHbf, query: "berlin hbf") == (matched: 2, whole: 2))
        #expect(TransitousProvider.localNameQuery(for: "stettin hbf") == "Szczecin")

        let dortmund = stop("Dortmund Hbf", town: "Dortmund", district: "Innenstadt West")
        #expect(TransitousProvider.textMatch(dortmund, query: "west") == (matched: 0, whole: 0))
        #expect(TransitousProvider.textMatch(dortmund, query: "dortmund west") == (matched: 2, whole: 1))
        let nordbahnhof = stop("Berlin-Nordbahnhof", town: "Berlin")
        #expect(TransitousProvider.textMatch(nordbahnhof, query: "nord") == (matched: 1, whole: 1))
        // "an" is the town's word for every stop in Brandenburg an der Havel, not just Am Anger's.
        let brandenburgHbf = stop("Brandenburg, Hauptbahnhof", town: "Brandenburg an der Havel")
        let amAnger = stop("Brandenburg, Am Anger", town: "Brandenburg an der Havel")
        #expect(TransitousProvider.textMatch(brandenburgHbf, query: "brandenburg an der havel")
            == TransitousProvider.textMatch(amAnger, query: "brandenburg an der havel"))
        let halleHbf = stop("Halle (Saale) Hbf", town: "Halle (Saale)")
        let feuerwache = stop("Halle (Saale), An der Feuerwache", town: "Halle (Saale)")
        #expect(TransitousProvider.textMatch(halleHbf, query: "halle an der saale") == (matched: 2, whole: 2))
        #expect(TransitousProvider.textMatch(feuerwache, query: "halle an der saale") == (matched: 2, whole: 2))
        // Typed last, "an" is still the start of a word: Anhalter Bahnhof.
        #expect(TransitousProvider.typedWords("berlin an").count == 2)
    }

    /// ø, æ and ł aren't accented letters in Unicode, but typed as o, ae and l they still match, and
    /// the start of a German name already asks for the local one.
    @Test func lettersAbroadAndStartsOfGermanNames() {
        #expect(TransitousProvider.searchWords("København H").first?.contains("kobenhavn") == true)
        #expect(TransitousProvider.searchWords("Wrocław").first?.contains("wroclaw") == true)
        #expect(TransitousProvider.isExactMatch("Tønder", query: "tonder"))
        #expect(TransitousProvider.localNameQuery(for: "sonderburg") == "Sønderborg")
        #expect(TransitousProvider.localNameQuery(for: "kopenh") == "København")
        #expect(TransitousProvider.localNameQuery(for: "trie") == nil) // Triest or Trient
        #expect(TransitousProvider.localNameQuery(for: "kop") == nil)
        let copenhagen = MGeocodeMatch(type: "STOP", name: "København H", id: "k", lat: 55.67, lon: 12.56, country: "DK")
        #expect(TransitousProvider.textMatch(copenhagen, query: "kopenh") == (matched: 1, whole: 0))
        #expect(TransitousProvider.namesPlace("kopenh", copenhagen))

        // The start of a big station's name names its place from 4 letters on: "wroc" from Görlitz.
        let wroclaw = MGeocodeMatch(type: "STOP", name: "Wrocław Główny", id: "w", lat: 51.098, lon: 17.037, country: "PL",
                                    modes: ["LONG_DISTANCE"], importance: 0.0035)
        #expect(TransitousProvider.namesPlace("wroc", wroclaw))
        #expect(!TransitousProvider.namesPlace("wro", wroclaw))
        // A stop without trips named like its town (in German "Stettin") isn't an exact match, and the
        // main station abroad comes first among equals.
        let szczecinArea = [MGeocodeMatch.Area(name: "Stettin", adminLevel: 8, isDefault: true)]
        let phantom = MGeocodeMatch(type: "STOP", name: "Szczecin", id: "phantom", lat: 53.43, lon: 14.55, country: "PL",
                                    modes: [], areas: szczecinArea)
        let glowny = MGeocodeMatch(type: "STOP", name: "Szczecin Główny", id: "glowny", lat: 53.418, lon: 14.551,
                                   country: "PL", modes: ["LONG_DISTANCE"], areas: szczecinArea, importance: 0.003)
        let dabie = MGeocodeMatch(type: "STOP", name: "Szczecin Dąbie", id: "dabie", lat: 53.40, lon: 14.62,
                                  country: "PL", modes: ["REGIONAL_RAIL"], areas: szczecinArea, importance: 0.003)
        #expect(TransitousProvider.isNamed("Szczecin", like: "Stettin"))
        let prenzlau = Coordinate(latitude: 53.316, longitude: 13.862)
        let ranked = [phantom, dabie, glowny].enumerated()
            .sorted { TransitousProvider.searchRank($0.element, query: "szczecin", offset: $0.offset, near: prenzlau)
                    > TransitousProvider.searchRank($1.element, query: "szczecin", offset: $1.offset, near: prenzlau) }
            .map(\.element.id)
        #expect(ranked.first == "glowny")
        // DELFI's border points aren't stations.
        let border = MGeocodeMatch(type: "STOP", name: "Toender [Grenze]", id: "b", lat: 54.9, lon: 8.9, country: "DE")
        #expect(TransitousProvider.isBorderPoint(border))
        #expect(!TransitousProvider.isBorderPoint(MGeocodeMatch(type: "STOP", name: "Ahlbeck Grenze", id: "a", lat: 0,
                                                                lon: 0, country: "DE")))
    }

    /// In the user's town its stations go by their short name ("süd" in Essen, "ost" in Frankfurt),
    /// U-Bahn stations nearby count their nearness, and train stations just across the border count
    /// like a neighbour's (Sopron from Vienna).
    @Test func searchRankKnowsTheUsersTownAndTheBorder() {
        func match(_ id: String, _ name: String, _ lat: Double, _ lon: Double, _ country: String, _ modes: [String],
                   _ importance: Double, town: String) -> MGeocodeMatch {
            MGeocodeMatch(type: "STOP", name: name, id: id, lat: lat, lon: lon, country: country, modes: modes,
                          areas: [.init(name: town, adminLevel: 6, isDefault: true)], importance: importance)
        }
        func ranked(_ query: String, _ matches: [MGeocodeMatch], near location: Coordinate, town: String?) -> [String] {
            matches.enumerated()
                .sorted {
                    TransitousProvider.searchRank($0.element, query: query, offset: $0.offset, near: location, userTown: town)
                        > TransitousProvider.searchRank($1.element, query: query, offset: $1.offset, near: location,
                                                        userTown: town)
                }
                .map(\.element.id)
        }

        let essen = Coordinate(latitude: 51.456, longitude: 7.012)
        let essenSued = match("essenSued", "Essen Süd S", 51.44, 7.02, "DE", ["SUBURBAN"], 0.00057, town: "Essen")
        let kraySued = match("kraySued", "Essen-Kray Süd", 51.47, 7.08, "DE", ["REGIONAL_RAIL"], 0.00025, town: "Essen")
        let reSued = match("reSued", "RE Süd Bf", 51.6, 7.2, "DE", ["REGIONAL_RAIL"], 0.0012, town: "Recklinghausen")
        let ffmSued = match("ffmSued", "Frankfurt (Main) Süd", 50.10, 8.69, "DE", ["LONG_DISTANCE", "REGIONAL_RAIL"],
                            0.008, town: "Frankfurt am Main")
        #expect(ranked("süd", [ffmSued, reSued, kraySued, essenSued], near: essen, town: "Essen").first == "essenSued")

        let frankfurt = Coordinate(latitude: 50.111, longitude: 8.682)
        let ffmOst = match("ffmOst", "Frankfurt (Main) Ostbahnhof", 50.112, 8.708, "DE", ["REGIONAL_RAIL", "SUBWAY"],
                           0.00203, town: "Frankfurt am Main")
        let ofOst = match("ofOst", "Offenbach Ost", 50.10, 8.78, "DE", ["SUBURBAN"], 0.00223, town: "Offenbach am Main")
        #expect(ranked("ost", [ofOst, ffmOst], near: frankfurt, town: "Frankfurt").first == "ffmOst")

        // Trams too: "neumarkt" in Köln.
        let cologne = Coordinate(latitude: 50.938, longitude: 6.960)
        let neumarkt = match("neumarkt", "Köln Neumarkt", 50.936, 6.947, "DE", ["TRAM", "BUS"], 0.00037, town: "Köln")
        let oberpfalz = match("oberpfalz", "Neumarkt (Oberpf)", 49.28, 11.46, "DE", ["REGIONAL_RAIL"], 0.0015,
                              town: "Neumarkt in der Oberpfalz")
        #expect(ranked("neumarkt", [oberpfalz, neumarkt], near: cologne, town: "Köln").first == "neumarkt")
        // VRS names Köln-Mülheim "Köln Mülheim Bf Mülheim".
        let koelnMuelheim = match("koelnMuelheim", "Köln Mülheim Bf Mülheim", 50.958, 7.013, "DE",
                                  ["REGIONAL_RAIL", "SUBURBAN", "TRAM", "BUS"], 0.00226, town: "Köln")
        let ruhr = match("ruhr", "Mülheim Hbf", 51.431, 6.887, "DE", ["LONG_DISTANCE", "REGIONAL_RAIL"], 0.0023,
                         town: "Mülheim an der Ruhr")
        #expect(ranked("mülheim", [ruhr, koelnMuelheim], near: cologne, town: "Köln").first == "koelnMuelheim")

        // Just "hbf" is the station nearby: Stralsund Hbf, not Berlin Hbf.
        let stralsund = Coordinate(latitude: 54.309, longitude: 13.077)
        let stralsundHbf = match("stralsundHbf", "Stralsund Hbf", 54.309, 13.077, "DE", ["LONG_DISTANCE"], 0.0015,
                                 town: "Stralsund")
        let berlinHbf = match("berlinHbf", "Berlin Hbf", 52.525, 13.369, "DE", ["LONG_DISTANCE"], 0.015, town: "Berlin")
        #expect(ranked("hbf", [berlinHbf, stralsundHbf], near: stralsund, town: nil).first == "stralsundHbf")

        let nuremberg = Coordinate(latitude: 49.452, longitude: 11.077)
        let nueAirport = match("nueAirport", "Nürnberg Flughafen", 49.4945, 11.0779, "DE", ["BUS", "SUBWAY"], 0.00133,
                               town: "Nürnberg")
        let mucAirport = match("mucAirport", "Flughafen München", 48.353, 11.785, "DE", ["SUBURBAN", "REGIONAL_RAIL"],
                               0.003, town: "Freising")
        #expect(ranked("flughafen", [mucAirport, nueAirport], near: nuremberg, town: "Nürnberg").first == "nueAirport")
        #expect(ranked("flughafen", [mucAirport, nueAirport], near: nuremberg, town: nil).first == "nueAirport")

        let vienna = Coordinate(latitude: 48.208, longitude: 16.373)
        let sopron = match("sopron", "Sopron", 47.68, 16.58, "HU", ["REGIONAL_RAIL"], 0.0011, town: "Sopron")
        let sopronBus = match("sopronBus", "Sopron, autóbusz-állomás", 47.685, 16.59, "HU", ["BUS"], 0.0031, town: "Sopron")
        #expect(ranked("sopron", [sopronBus, sopron], near: vienna, town: "Wien").first == "sopron")

        // Neuchâtel's stops (in "Neuenburg", in German) match "neuenburg" only by its German name, so
        // they don't push Neuenburg (Baden) down.
        let freiburg = Coordinate(latitude: 47.997, longitude: 7.842)
        let neuchatel = match("neuchatel", "Neuchâtel", 46.996, 6.936, "CH", ["LONG_DISTANCE", "REGIONAL_RAIL"], 0.0094,
                              town: "Neuenburg")
        let evole = match("evole", "Neuchâtel, Evole", 46.99, 6.92, "CH", ["REGIONAL_RAIL"], 0.0032, town: "Neuenburg")
        let neuenburg = match("neuenburg", "Neuenburg (Baden)", 47.815, 7.556, "DE", ["REGIONAL_RAIL"], 0.0004,
                              town: "Neuenburg am Rhein")
        #expect(ranked("neuenburg", [evole, neuchatel, neuenburg], near: freiburg, town: "Freiburg").last == "evole")
    }

    /// A town only counts as typed from its first word: "neustadt" isn't Wiener Neustadt.
    @Test func typedTownStartsWithItsFirstWord() {
        func stop(_ town: String) -> MGeocodeMatch {
            MGeocodeMatch(type: "STOP", name: "Bahnhof", id: town, lat: 0, lon: 0, country: "DE",
                          areas: [MGeocodeMatch.Area(name: town, adminLevel: 8, isDefault: true)])
        }
        #expect(!TransitousProvider.isInTown(named: "neustadt", stop("Wiener Neustadt"), wholeWords: true))
        #expect(TransitousProvider.isInTown(named: "neustadt", stop("Neustadt an der Weinstraße"), wholeWords: true))
        #expect(TransitousProvider.isInTown(named: "frankfurt oder", stop("Frankfurt (Oder)"), wholeWords: true))
        #expect(TransitousProvider.isInTown(named: "neust", stop("Wiener Neustadt")))
    }

    /// A small town's station a bit farther away comes before a village station nearby, and a busy
    /// one far away after both; the village is still found, and first once its name is typed in full.
    @Test func searchRankPrefersBusierStationsButKeepsVillages() {
        let berlin = Coordinate(latitude: 52.52, longitude: 13.405)
        func match(_ id: String, _ name: String, _ lat: Double, _ lon: Double, _ importance: Double) -> MGeocodeMatch {
            MGeocodeMatch(type: "STOP", name: name, id: id, lat: lat, lon: lon, country: "DE", modes: ["REGIONAL_RAIL"],
                          importance: importance)
        }
        let village = match("village", "Neudorf", 52.65, 13.80, 0.0002)
        let smallTown = match("smallTown", "Neustadt (Dosse)", 52.85, 12.45, 0.0015)
        let far = match("far", "Neustadt (Weinstr) Hbf", 49.0, 8.4, 0.004)
        func ranked(_ query: String) -> [String] {
            [far, village, smallTown].enumerated()
                .sorted { TransitousProvider.searchRank($0.element, query: query, offset: $0.offset, near: berlin)
                        > TransitousProvider.searchRank($1.element, query: query, offset: $1.offset, near: berlin) }
                .map(\.element.id)
        }
        #expect(ranked("neu") == ["smallTown", "village", "far"])

        // An S-Bahn-only halt counts a quarter of its departures: behind a regional station with fewer,
        // but still ahead of a village station.
        func rankedHits(_ query: String, _ matches: [MGeocodeMatch]) -> [String] {
            matches.enumerated()
                .sorted { TransitousProvider.searchRank($0.element, query: query, offset: $0.offset, near: berlin)
                        > TransitousProvider.searchRank($1.element, query: query, offset: $1.offset, near: berlin) }
                .map(\.element.id)
        }
        let sBahn = MGeocodeMatch(type: "STOP", name: "Neue Mühle", id: "sBahn", lat: 52.40, lon: 13.55, country: "DE",
                                  modes: ["SUBURBAN", "SUBWAY", "BUS"], importance: 0.008)
        let regional = MGeocodeMatch(type: "STOP", name: "Neuenhagen", id: "regional", lat: 52.529, lon: 13.69, country: "DE",
                                     modes: ["REGIONAL_RAIL", "SUBURBAN"], importance: 0.004)
        #expect(rankedHits("neu", [village, sBahn, regional]) == ["regional", "sBahn", "village"])
        #expect(TransitousProvider.isSuburbanOnly(["SUBURBAN", "BUS"]))
        #expect(!TransitousProvider.isSuburbanOnly(["SUBURBAN", "REGIONAL_RAIL"]))
        #expect(ranked("Neudorf").first == "village")
        #expect(TransitousProvider.sizeScore(forImportance: nil) == 0)
        #expect(TransitousProvider.sizeScore(forImportance: 0.0015) == 3)
        #expect(TransitousProvider.sizeScore(forImportance: 1) == 8)
    }

    /// A slow extra query ("Po Bahnhof") is dropped after `extraQueryDeadline` instead of holding up
    /// the whole search until `CombinedProvider` gives up on it and falls back to bahn.de's noise.
    @Test func slowExtraQueriesDontHoldUpTheSearch() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SlowExtraGeocodeProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let provider = TransitousProvider(http: HTTPClient(session: session))

        let stations = try await provider.searchStations("Po")
        #expect(stations.map(\.id) == ["potsdamHbf"])
        // Checked against the slow answer itself, not a stopwatch, so a busy test runner can't fail it.
        #expect(!SlowExtraGeocodeProtocol.answeredSlowly.withLock { $0 })
        #expect(CombinedProvider.isShortQuery("Po "))
        #expect(!CombinedProvider.isShortQuery("Pot"))
    }

    /// "Be" in Berlin: at most three Berlin stations first, then Bern, the rest of Berlin after.
    /// The Swiss canton in "Brügg BE" isn't a whole-word match for "Be".
    @Test func shortSearchesSpreadOverTowns() {
        func match(_ id: String, town: String) -> MGeocodeMatch {
            MGeocodeMatch(type: "STOP", name: id, id: id, lat: 0, lon: 0, country: "DE", modes: ["REGIONAL_RAIL"],
                          areas: [.init(name: town, adminLevel: 4, isDefault: true)])
        }
        let berlin = ["hbf", "suedkreuz", "ostbf", "spandau", "gesundbrunnen"].map { match($0, town: "Berlin") }
        let bern = match("bern", town: "Bern")
        let spread = TransitousProvider.spreadingTowns(berlin + [bern], query: "Be")
        #expect(spread.map(\.id) == ["hbf", "suedkreuz", "ostbf", "bern", "spandau", "gesundbrunnen"])
        // Typing the town keeps its stations together.
        #expect(TransitousProvider.spreadingTowns(berlin + [bern], query: "Berlin").map(\.id).last == "bern")

        let bruegg = MGeocodeMatch(type: "STOP", name: "Brügg BE, Bahnhof", id: "bruegg", lat: 47.12, lon: 7.28,
                                   country: "CH", modes: ["REGIONAL_RAIL"])
        #expect(TransitousProvider.textMatch(bruegg, query: "Be").whole == 0)
        #expect(TransitousProvider.textMatch(bruegg, query: "Be").matched == 1)
    }

    /// "be" near Berlin asks for Berlin Hbf and Bernau (one station per place); Bern and Bebra are
    /// too far away to be hinted.
    @Test func stationHintsFindNearbyStationsByTheirFirstLetters() throws {
        let json = #"[["Berlin Hbf",52.525,13.369,0.02],["Berlin Südkreuz",52.475,13.365,0.0097],"#
            + #"["S Bernau Bhf",52.676,13.592,0.0012],["Bern",46.949,7.439,0.05],["Bebra",50.97,9.79,0.002],"#
            + #"["S+U Potsdamer Platz Bhf (Berlin)",52.509,13.376,0.0063],["S Potsdam Hauptbahnhof",52.391,13.067,0.0038]]"#
        let hints = try JSONDecoder().decode([StationHints.Hint].self, from: Data(json.utf8))
        let berlin = Coordinate(latitude: 52.52, longitude: 13.405)
        // Bern is far, but big enough (`hubSize`) to count from anywhere; Bebra isn't.
        #expect(StationHints.names(matching: "be", near: berlin, in: hints) == ["Berlin Hbf", "S Bernau Bhf", "Bern"])
        #expect(StationHints.names(matching: "bern", near: berlin, in: hints) == ["S Bernau Bhf", "Bern"])
        #expect(StationHints.names(matching: "x", near: berlin, in: hints).isEmpty)
        #expect(StationHints.names(matching: "be", near: berlin, excluding: "Berlin", in: hints)
            == ["S Bernau Bhf", "Bern"])
        // Stations in the user's town still count when what was typed matches more than the town.
        #expect(StationHints.names(matching: "po", near: berlin, excluding: "Berlin", in: hints)
            == ["S+U Potsdamer Platz Bhf (Berlin)", "S Potsdam Hauptbahnhof"])
        // The bundled list loads.
        #expect(StationHints.all.count > 1000)

        // Big stations count from anywhere: "ham" in Berlin finds Hamburg Hbf before Hammelspring.
        let more = try JSONDecoder().decode([StationHints.Hint].self, from: Data(#"""
            [["Hamburg Hbf",53.553,10.007,0.03],["Hammelspring",52.99,13.62,0.0002],
             ["Neustadt (Dosse), Bahnhof",52.853,12.45,0.0006],["Dresden-Neustadt",51.065,13.741,0.004],
             ["Neustadt (Weinstr) Hbf",49.35,8.14,0.0022]]
            """#.utf8))
        #expect(StationHints.names(matching: "ham", near: berlin, in: more) == ["Hamburg Hbf", "Hammelspring"])
        // For longer names only nearby ones whose name starts with it: Neustadt (Dosse), not Dresden-Neustadt.
        #expect(StationHints.names(matching: "neustadt", near: berlin, nearbyOnly: true, in: more)
            == ["Neustadt (Dosse), Bahnhof"])
        #expect(TransitousProvider.nearbyStationQueries(for: "neustadt", near: berlin).count
            <= TransitousProvider.longQueryHints)
    }

    /// A typed umlaut stays one at the start of a word ("kö" for Köln, not Konstanz), a resort's title
    /// doesn't count as its place ("rathen" for Kurort Rathen), and longer names also find a station
    /// by its second word ("travem" for Lübeck-Travemünde).
    @Test func stationHintsKeepUmlautsAndLookPastTitles() throws {
        let hints = try JSONDecoder().decode([StationHints.Hint].self, from: Data(#"""
            [["Köln Hbf",50.943,6.959,0.011],["Konstanz",47.659,9.177,0.004],["Kurort Rathen Bahnhof",50.958,14.081,0.0004],
             ["Lübeck-Travemünde Strand",53.962,10.874,0.0003],["Rathenow",52.6,12.33,0.001]]
            """#.utf8))
        let freiburg = Coordinate(latitude: 47.997, longitude: 7.842)
        #expect(StationHints.names(matching: "kö", near: freiburg, in: hints) == ["Köln Hbf"])
        #expect(StationHints.names(matching: "ko", near: freiburg, in: hints).first == "Konstanz")
        let dresden = Coordinate(latitude: 51.05, longitude: 13.74)
        #expect(StationHints.names(matching: "rathen", near: dresden, nearbyOnly: true, in: hints)
            == ["Kurort Rathen Bahnhof"])
        let kiel = Coordinate(latitude: 54.32, longitude: 10.13)
        #expect(StationHints.names(matching: "travem", near: kiel, nearbyOnly: true, in: hints)
            == ["Lübeck-Travemünde Strand"])
        #expect(TransitousProvider.typedWords("kö").first?.starts == ["koe"])
        #expect(TransitousProvider.typedWords("lü").first?.isWord == false)
    }

    /// Main stations go by their own name, not the stop in front of them ("…/Münchener Straße"
    /// would match "mü") or a short one ("KA Hbf (Vorplatz)").
    @Test func mainStationsKeepTheirOwnName() throws {
        let hints = try JSONDecoder().decode([StationHints.Hint].self, from: Data(#"""
            [["Karlsruhe Hbf",48.993,8.4,0.012],["Frankfurt (M) Hbf",50.107,8.664,0.022]]
            """#.utf8))
        func station(_ name: String, _ lat: Double, _ lon: Double) -> MGeocodeMatch {
            MGeocodeMatch(type: "STOP", name: name, id: name, lat: lat, lon: lon, country: "DE",
                          modes: ["LONG_DISTANCE", "REGIONAL_RAIL"])
        }
        let frankfurt = station("Frankfurt (Main) Hauptbahnhof/Münchener Straße", 50.1072, 8.6638)
        #expect(TransitousProvider.withMainStationName(frankfurt, hints: hints).name == "Frankfurt (M) Hbf")
        let karlsruhe = station("KA Hbf (Vorplatz)", 48.9935, 8.4005)
        #expect(TransitousProvider.withMainStationName(karlsruhe, hints: hints).name == "Karlsruhe Hbf")
        let brandenburg = station("Brandenburg, ZOB", 52.4006, 12.5636)
        let brandenburgHints = try JSONDecoder().decode([StationHints.Hint].self,
                                                        from: Data(#"[["Brandenburg, Hauptbahnhof",52.401,12.563,0.002]]"#.utf8))
        #expect(TransitousProvider.withMainStationName(brandenburg, hints: brandenburgHints).name == "Brandenburg, Hauptbahnhof")
        // Without a main station nearby in the list, the name up to "Hbf".
        let hamburg = station("Hamburg Hbf/ZOB", 53.553, 10.007)
        #expect(TransitousProvider.withMainStationName(hamburg, hints: []).name == "Hamburg Hbf")
        let leipzig = station("Leipzig Hbf", 51.345, 12.382)
        #expect(TransitousProvider.withMainStationName(leipzig, hints: hints).name == "Leipzig Hbf")
        #expect(TransitousProvider.isBetterName("Karlsruhe Hbf", than: "KA Hbf (Vorplatz)"))
    }

    /// Short words don't name a place ("st" isn't St. Gallen), typed words follow the town's order
    /// ("bad harz" is Bad Harzburg, not Bad Lauterberg im Harz), and the big town nearby counts next
    /// to a station's name ("stuttgart flughafen" for Flughafen/Messe in Leinfelden-Echterdingen).
    @Test func placesAreNamedInFullAndInOrder() {
        func stop(_ name: String, town: String, _ lat: Double = 0, _ lon: Double = 0, country: String = "DE",
                  modes: [String] = ["REGIONAL_RAIL"]) -> MGeocodeMatch {
            MGeocodeMatch(type: "STOP", name: name, id: name, lat: lat, lon: lon, country: country, modes: modes,
                          areas: [.init(name: town, adminLevel: 8, isDefault: true)])
        }
        let stGallen = stop("St. Gallen", town: "St. Gallen", country: "CH")
        #expect(!TransitousProvider.isInTown(named: "st", stGallen, wholeWords: true))
        #expect(!TransitousProvider.namesPlace("st", stGallen))
        #expect(TransitousProvider.namesPlace("st gallen", stGallen))
        #expect(TransitousProvider.isInTown(named: "bad harz", stop("Bad Harzburg", town: "Bad Harzburg"), wholeWords: true))
        #expect(!TransitousProvider.isInTown(named: "bad harz", stop("Barbis", town: "Bad Lauterberg im Harz"),
                                             wholeWords: true))
        #expect(TransitousProvider.isInTown(named: "rathen", stop("Kurort Rathen", town: "Kurort Rathen"), wholeWords: true))

        let airport = stop("Flughafen/Messe", town: "Leinfelden-Echterdingen", 48.690, 9.193, modes: ["SUBURBAN"])
        #expect(TransitousProvider.textMatch(airport, query: "stuttgart flughafen") == (matched: 2, whole: 2))
        #expect(TransitousProvider.textMatch(airport, query: "stuttgart") == (matched: 0, whole: 0))
        #expect(TransitousProvider.isInTypedPlace("stuttgart flughafen", airport))

        #expect(TransitousProvider.withoutStationWords("bahnhof zoo") == "zoo")
        #expect(TransitousProvider.withoutStationWords("hbf") == "hbf")
        #expect(TransitousProvider.placeStationQuery(for: "rathen") == "rathen Bahnhof")

        // "Airport" in Vantaa isn't a place called "airport"; "Sankt" is "St.".
        let vantaa = stop("Airport", town: "Vantaa", country: "FI", modes: ["REGIONAL_RAIL"])
        #expect(!TransitousProvider.namesPlace("airport", vantaa))
        #expect(TransitousProvider.textMatch(stop("St.Pauli", town: "Hamburg", modes: ["SUBWAY"]), query: "sankt pauli")
            == (matched: 2, whole: 2))
        #expect(TransitousProvider.typedWords("st").first?.starts == ["st"])

        // Without a location, a bus stop abroad called "Han" doesn't beat Hannover Hbf.
        let han = stop("Han", town: "Konya", country: "TR", modes: ["BUS"])
        let hannover = stop("Hannover Hbf", town: "Hannover", modes: ["LONG_DISTANCE"])
        #expect(TransitousProvider.searchRank(hannover, query: "han", offset: 1)
            > TransitousProvider.searchRank(han, query: "han", offset: 0))
    }

    @Test func extraQueriesForAliasesAndTheNearbyTown() {
        let berlin = Coordinate(latitude: 52.52, longitude: 13.405)
        #expect(TransitousProvider.aliasQuery(for: "BER ") == "Flughafen BER")
        #expect(TransitousProvider.aliasQuery(for: "bern") == nil)

        #expect(TransitousProvider.nearbyTownQuery(for: "ost ", near: berlin) == "Berlin ost")
        #expect(TransitousProvider.nearbyTownQuery(for: "ost", near: Coordinate(latitude: 48.10, longitude: 11.50)) == "München ost")
        // What was typed could be (the start of) the town itself.
        #expect(TransitousProvider.nearbyTownQuery(for: "ber", near: berlin) == nil)
        // One or two letters ask for the town itself: the geocoder finds nothing for them.
        #expect(TransitousProvider.nearbyTownQuery(for: "Be", near: berlin) == "Berlin")
        #expect(TransitousProvider.nearbyTownQuery(for: "Berlin Hbf", near: berlin) == nil)
        // No location, or no larger town nearby (Perleberg in the Prignitz).
        #expect(TransitousProvider.nearbyTownQuery(for: "ost", near: nil) == nil)
        #expect(TransitousProvider.nearbyTownQuery(for: "ost", near: Coordinate(latitude: 53.07, longitude: 11.86)) == nil)
    }

    /// The geocoder has neither Berlin's stations for "ost" nor Flughafen BER for "ber" among its hits;
    /// "Berlin ost" and "Flughafen BER" are asked for too, and only hits matching what was typed kept.
    @Test func searchStationsAsksForStationsInTheNearbyTownAndAliases() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [NearbyGeocodeProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let provider = TransitousProvider(http: HTTPClient(session: session))
        let berlin = Coordinate(latitude: 52.52, longitude: 13.405)

        let ost = try await provider.searchStations("ost", near: berlin)
        #expect(ost.map(\.id) == ["ostbf", "ulmOst"])

        let ber = try await provider.searchStations("ber", near: berlin)
        #expect(ber.map(\.id) == ["ber", "bern"])
        #expect(!NearbyGeocodeProtocol.requestedTexts.withLock { $0 }.contains("Berlin ber"))

        // Two letters: the geocoder finds nothing, but main stations starting with them, and nearby
        // stations from the bundled list (Flughafen BER).
        let be = try await provider.searchStations("Be", near: berlin)
        #expect(be.map(\.id) == ["berlinHbf", "ber"])
        #expect(TransitousProvider.shortQueries(for: "bre") == ["bre Hbf", "bre Bahnhof"])
        #expect(TransitousProvider.shortQueries(for: "brem").isEmpty)
        #expect(TransitousProvider.shortQueries(for: "Be ") == ["Be Hbf", "Be Bahnhof"])
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
        // The main station's name wins over the bus station in front of it.
        #expect(TransitousProvider.isBetterName("Brandenburg, Hauptbahnhof", than: "Brandenburg, ZOB"))
        #expect(!TransitousProvider.isBetterName("Brandenburg, ZOB", than: "Brandenburg, Hauptbahnhof"))
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

    /// ICE 146 Berlin–Amsterdam at Berlin Hbf: DB's feed has it ending in Hengelo (with realtime),
    /// NS's feed starting in Berlin and ending in Amsterdam (without). Neither headsign goes beyond
    /// its own trip, but same number, time and track are the same train: one row, the live one.
    @Test func stopTimesMergeSameTrainFromTwoFeeds() throws {
        let json = """
        {"stopTimes": [
            {"place": {"name": "Berlin Hbf", "stopId": "nl:1", "lat": 52.52, "lon": 13.37,
                       "scheduledDeparture": "2026-10-06T07:09:00Z", "departure": "2026-10-06T07:09:00Z",
                       "scheduledTrack": "6"},
             "mode": "HIGHSPEED_RAIL", "realTime": false, "headsign": "Amsterdam Centraal",
             "tripFrom": {"name": "Berlin Hbf", "lat": 52.52, "lon": 13.37},
             "tripTo": {"name": "Amsterdam Centraal", "lat": 52.38, "lon": 4.9},
             "tripId": "nl-trip", "routeShortName": "ICE", "tripShortName": "146", "displayName": "ICE 146",
             "agencyName": "NS International"},
            {"place": {"name": "S+U Berlin Hauptbahnhof", "stopId": "de:1", "lat": 52.52, "lon": 13.37,
                       "scheduledDeparture": "2026-10-06T07:09:00Z", "departure": "2026-10-06T07:12:00Z",
                       "scheduledTrack": "6", "track": "6"},
             "mode": "HIGHSPEED_RAIL", "realTime": true, "headsign": "Hengelo",
             "tripFrom": {"name": "S Südkreuz Bhf (Berlin)", "lat": 52.48, "lon": 13.37},
             "tripTo": {"name": "Hengelo", "lat": 52.26, "lon": 6.79},
             "tripId": "de-trip", "routeShortName": "77", "tripShortName": "ICE 146", "displayName": "ICE 146",
             "agencyName": "DB Fernverkehr AG"},
            {"place": {"name": "Berlin Hbf", "stopId": "nl:1", "lat": 52.52, "lon": 13.37,
                       "scheduledDeparture": "2026-10-06T09:09:00Z", "scheduledTrack": "6"},
             "mode": "HIGHSPEED_RAIL", "headsign": "Amsterdam Centraal",
             "tripTo": {"name": "Amsterdam Centraal", "lat": 52.38, "lon": 4.9},
             "tripId": "nl-144", "displayName": "ICE 144", "agencyName": "NS International"}
        ]}
        """
        let response = try JSONDecoding.decoder.decode(MStopTimesResponse.self, from: Data(json.utf8))
        let merged = TransitousProvider.mergeBorderSplitDuplicates(response.stopTimes, kind: .departures)
        #expect(merged.map(\.tripId) == ["de-trip", "nl-144"])
        let entry = try #require(merged.first?.toEntry(kind: .departures))
        #expect(entry.time.actual != nil)
    }

    /// Local lines share their "number" between both directions; two S5 at the same minute stay apart.
    @Test func stopTimesKeepsLocalTrainsWithSameLineAndTime() throws {
        let json = """
        {"stopTimes": [
            {"place": {"name": "Berlin Hbf", "stopId": "a:1", "lat": 52.52, "lon": 13.37,
                       "scheduledDeparture": "2026-10-06T07:11:00Z"},
             "mode": "SUBURBAN", "realTime": true, "headsign": "Berlin-Mahlsdorf",
             "tripTo": {"name": "Berlin-Mahlsdorf", "lat": 52.5, "lon": 13.6},
             "tripId": "s5-east", "displayName": "S5", "agencyName": "S-Bahn Berlin"},
            {"place": {"name": "Berlin Hbf", "stopId": "a:2", "lat": 52.52, "lon": 13.37,
                       "scheduledDeparture": "2026-10-06T07:11:00Z"},
             "mode": "SUBURBAN", "headsign": "Westkreuz",
             "tripTo": {"name": "Westkreuz", "lat": 52.5, "lon": 13.28},
             "tripId": "s5-west", "displayName": "S5", "agencyName": "S-Bahn Berlin"}
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

    /// MOTIS picks stop times by their live time: at 9:08:30 DB's live row of ICE 146 (left early,
    /// 9:08) is gone while NS's planned row (9:09) is still there, so the board showed the train
    /// without its live time. The board asks earlier, merges both and then drops the departed train.
    @Test func boardAsksEarlierSoAnEarlyTrainMergesWithItsPlannedTwin() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [EarlyTwinStopTimesProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let provider = TransitousProvider(http: HTTPClient(session: session))
        let berlin = station("bln", "Berlin Hbf", source: .transitous)

        let queryDate = try #require(JSONDecoding.parseISODate("2026-10-06T07:08:30Z"))
        let entries = try await provider.board(.departures, at: berlin, date: queryDate, duration: 90, products: [.highSpeed])
        #expect(entries.isEmpty)
        let asked = try #require(EarlyTwinStopTimesProtocol.lastTime.withLock { $0 })
        #expect(JSONDecoding.parseISODate(asked) == queryDate.addingTimeInterval(-10 * 60))

        let earlier = try #require(JSONDecoding.parseISODate("2026-10-06T07:05:00Z"))
        let shown = try await provider.board(.departures, at: berlin, date: earlier, duration: 90, products: [.highSpeed])
        #expect(shown.map(\.tripId) == ["de-trip"])
        #expect(shown.first?.time.actual != nil)
    }

    /// Real-world Dresden Hbf: `arriveBy=true` alone makes Transitous search backwards from `time`,
    /// so the arrivals board showed days of past arrivals instead of the next 90 minutes.
    @Test func arrivalsBoardAsksForLaterArrivals() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RecordingStopTimesProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let provider = TransitousProvider(http: HTTPClient(session: session))
        let dresden = station("dd", "Dresden Hbf", source: .transitous)

        _ = try await provider.board(.arrivals, at: dresden, date: .now, duration: 90, products: [.highSpeed])

        let items = try #require(RecordingStopTimesProtocol.lastQuery.withLock { $0 })
        #expect(items.first { $0.name == "arriveBy" }?.value == "true")
        #expect(items.first { $0.name == "direction" }?.value == "LATER")
    }
}

private final class RecordingStopTimesProtocol: URLProtocol, @unchecked Sendable {
    static let lastQuery = Mutex<[URLQueryItem]?>(nil)
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
        Self.lastQuery.withLock { $0 = items }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"stopTimes": []}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// ICE 146 at Berlin Hbf from DB's feed (live, leaving a minute early) and NS's feed (planned only).
private final class EarlyTwinStopTimesProtocol: URLProtocol, @unchecked Sendable {
    static let lastTime = Mutex<String?>(nil)
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
        if request.url!.path.hasSuffix("v5/stoptimes"), items?.first(where: { $0.name == "arriveBy" })?.value == "false" {
            Self.lastTime.withLock { $0 = items?.first { $0.name == "time" }?.value }
        }
        let body = request.url!.path.hasSuffix("v5/stoptimes") ? """
        {"stopTimes": [
            {"place": {"name": "S+U Berlin Hauptbahnhof", "stopId": "de:1", "lat": 52.52, "lon": 13.37,
                       "scheduledDeparture": "2026-10-06T07:09:00Z", "departure": "2026-10-06T07:08:00Z",
                       "scheduledTrack": "6", "track": "6"},
             "mode": "HIGHSPEED_RAIL", "realTime": true, "headsign": "Hengelo",
             "tripTo": {"name": "Hengelo", "lat": 52.26, "lon": 6.79},
             "tripId": "de-trip", "tripShortName": "ICE 146", "displayName": "ICE 146"},
            {"place": {"name": "Berlin Hbf", "stopId": "nl:1", "lat": 52.52, "lon": 13.37,
                       "scheduledDeparture": "2026-10-06T07:09:00Z", "departure": "2026-10-06T07:09:00Z",
                       "scheduledTrack": "6"},
             "mode": "HIGHSPEED_RAIL", "realTime": false, "headsign": "Amsterdam Centraal",
             "tripTo": {"name": "Amsterdam Centraal", "lat": 52.38, "lon": 4.9},
             "tripId": "nl-trip", "tripShortName": "146", "displayName": "ICE 146"}
        ]}
        """ : "{}"
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
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

// MARK: - RIL100 codes

@Suite struct Ril100Tests {
    func station(_ id: String, _ name: String, _ lat: Double, _ lon: Double) -> Station {
        Station(id: id, name: name, coordinate: Coordinate(latitude: lat, longitude: lon), evaNumber: nil, source: .transitous)
    }

    /// A code finds its station in any case, also with the double spaces DB writes some with (#165).
    @Test func findsStationsByCodeInAnyCase() {
        #expect(Ril100.entry(forCode: "ff")?.name == "Frankfurt (Main) Hbf")
        #expect(Ril100.entry(forCode: "FfT")?.name == "Frankfurt (Main) Hbf (tief)")
        #expect(Ril100.entry(forCode: " ah ")?.name == "Hamburg Hbf")
        #expect(Ril100.entry(forCode: "ll t")?.name == "Leipzig Hbf (Tiefgleise)")
        #expect(Ril100.entry(forCode: "f") == nil)
        #expect(Ril100.entry(forCode: "Frankfurt") == nil)
    }

    /// Stops are matched by position and name, also on another level of the station (which shows the
    /// station's shortest code), but not a different station nearby.
    @Test func matchesStopsToStationsByPositionAndName() {
        #expect(Ril100.code(for: station("a", "Frankfurt (Main) Hauptbahnhof", 50.1069, 8.6625)) == "FF")
        #expect(Ril100.code(for: station("b", "Frankfurt (Main) Hbf tief", 50.1072, 8.6650)) == "FF")
        #expect(Ril100.code(for: station("c", "S+U Alexanderplatz Bhf (Berlin)", 52.5215, 13.4115)) == "BALE")
        #expect(Ril100.code(for: station("d", "Berlin Hbf (tief)", 52.5250, 13.3690)) == "BL")
        #expect(Ril100.code(for: station("e", "Hamburg Hbf (S-Bahn)", 53.5530, 10.0070)) == "AH")
        // A tram stop named otherwise 300 m away isn't the station.
        #expect(Ril100.code(for: station("f", "Frankfurt, Platz der Republik", 50.1095, 8.6660)) == nil)
        // Far from DB's positions the same name isn't enough.
        #expect(Ril100.code(for: station("g", "Frankfurt (Main) Hbf", 50.12, 8.70)) == nil)
        let bls = Ril100.entry(forCode: "bls")!
        #expect(Ril100.matches(station("h", "Berlin Hbf", 52.5251, 13.3692), bls))
    }

    /// The station the code belongs to comes first and only once; behind a first hit whose name starts
    /// with the typed word.
    @Test func placesTheCodesStationFirstAndOnce() throws {
        let ff = try #require(Ril100.entry(forCode: "ff"))
        let hbf = station("hbf", "Frankfurt (Main) Hauptbahnhof", 50.1069, 8.6625)
        let tief = station("tief", "Frankfurt (Main) Hbf tief", 50.1072, 8.6650)
        let other = station("other", "Fulda", 50.554, 9.684)
        #expect(Ril100.placing(hbf, for: ff, typed: "ff", in: [other, tief, hbf]).map(\.id) == ["hbf", "other"])
        // Without the looked-up stop, the first hit that is the station moves up.
        #expect(Ril100.placing(nil, for: ff, typed: "ff", in: [other, tief, hbf]).map(\.id) == ["tief", "other"])
        #expect(Ril100.placing(nil, for: ff, typed: "ff", in: [other]).map(\.id) == ["other"])

        let harblek = try #require(Ril100.entry(forCode: "aha"))
        let aha = station("aha", "Aha", 47.8331, 8.1347)
        let harblekStop = station("harblek", "Harblek", 54.3619, 8.9625)
        #expect(Ril100.placing(harblekStop, for: harblek, typed: "Aha", in: [aha]).map(\.id) == ["aha", "harblek"])
        let altdoebern = try #require(Ril100.entry(forCode: "bad"))
        let altdoebernStop = station("altdoebern", "Altdöbern", 51.6528, 14.0092)
        let ragaz = station("ragaz", "Bad Ragaz", 47.0, 9.5)
        let toelz = station("toelz", "Bad Tölz", 47.76, 11.56)
        #expect(Ril100.placing(altdoebernStop, for: altdoebern, typed: "bad", in: [ragaz, toelz]).map(\.id)
            == ["ragaz", "altdoebern", "toelz"])
        let canyon = station("canyon", "Canyon MHP", 40.0, -100.0)
        let heimeranplatz = station("heimeranplatz", "München Heimeranplatz", 48.1330, 11.5315)
        #expect(Ril100.placing(heimeranplatz, for: try #require(Ril100.entry(forCode: "mhp")), typed: "mhp", in: [canyon])
            .map(\.id) == ["heimeranplatz", "canyon"])
    }

    /// The geocoder misses many of DB's full names, so the station is also looked up by their first
    /// part and the town.
    @Test func searchTextsForDBsNames() {
        #expect(Ril100.searchTexts(for: "Hof Hbf") == ["Hof Hbf", "Hof"])
        #expect(Ril100.searchTexts(for: "Frankfurt (Main) Hbf") == ["Frankfurt (Main) Hbf", "Frankfurt"])
        #expect(Ril100.searchTexts(for: "Berlin Hauptbahnhof - Lehrter Bahnhof")
            == ["Berlin Hauptbahnhof - Lehrter Bahnhof", "Berlin Hauptbahnhof", "Berlin"])
        #expect(Ril100.searchTexts(for: "Alexanderplatz") == ["Alexanderplatz"])
    }

    /// "ff" in the picker: Frankfurt (Main) Hbf, looked up by DB's name, first; its lower level, which
    /// the geocoder found for "ff" itself, left out.
    @Test func searchFindsTheStationForATypedCode() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Ril100GeocodeProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let provider = TransitousProvider(http: HTTPClient(session: session))

        let stations = try await provider.searchStations(StationSearch(parsing: "ff"), near: nil)

        #expect(stations.map(\.id) == ["frankfurtHbf", "fulda"])
    }
}

/// "Frankfurt (Main) Hbf" gives the station, anything else ("ff" and its extras) its lower level and Fulda.
private final class Ril100GeocodeProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let text = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "text" }?.value
        let body = text == "Frankfurt (Main) Hbf"
            ? #"[{"type":"STOP","id":"frankfurtHbf","name":"Frankfurt (Main) Hauptbahnhof","lat":50.1069,"lon":8.6625,"country":"DE","modes":["HIGHSPEED_RAIL","REGIONAL_RAIL"],"importance":0.02}]"#
            : #"[{"type":"STOP","id":"fulda","name":"Fulda","lat":50.554,"lon":9.684,"country":"DE","modes":["HIGHSPEED_RAIL"],"importance":0.004},"#
                + #"{"type":"STOP","id":"tief","name":"Frankfurt (Main) Hbf tief","lat":50.1072,"lon":8.665,"country":"DE","modes":["SUBURBAN"],"importance":0.01}]"#
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
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

    @Test func sBahnNameWithTripNumber() {
        #expect(Line(name: "S 8", number: "8", product: .suburban, operatorName: nil, tripNumber: "37856").nameWithTripNumber == "S 8 (37856)")
        #expect(Line(name: "S 8", number: "8", product: .suburban, operatorName: nil).nameWithTripNumber == "S 8")
        #expect(Line(name: "S 8 (37856)", number: "8", product: .suburban, operatorName: nil, tripNumber: "37856").nameWithTripNumber == "S 8 (37856)")
        #expect(Line(name: "RE 14a", number: "14", product: .regionalExpress, operatorName: nil, tripNumber: "17677").nameWithTripNumber == "RE 14a")
        #expect(Line(name: "U 2", number: "2", product: .subway, operatorName: nil, tripNumber: "12").nameWithTripNumber == "U 2")
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

    func transferPicker() throws -> (TrainPicker, Leg, Journey) {
        let fast = trip("ice1", "ICE 1", [stop(koeln, arr: nil, dep: 0), stop(berlin, arr: 240, dep: nil)])
        let toDuesseldorf = trip("re5", "RE 5", [stop(koeln, arr: nil, dep: 15), stop(duesseldorf, arr: 40, dep: nil)])
        let onwards = trip("ice10", "ICE 10", [stop(duesseldorf, arr: nil, dep: 50), stop(berlin, arr: 300, dep: nil)])
        let late = trip("ice12", "ICE 12", [stop(duesseldorf, arr: nil, dep: 400), stop(berlin, arr: 640, dep: nil)])
        let lateFeeder = trip("re7", "RE 7", [stop(koeln, arr: nil, dep: 360), stop(duesseldorf, arr: 385, dep: nil)])
        let withTransfer = Journey(legs: [try #require(toDuesseldorf.leg(from: koeln, to: duesseldorf)),
                                          try #require(onwards.leg(from: duesseldorf, to: berlin))], source: .bahnDe)
        let tooLate = Journey(legs: [try #require(lateFeeder.leg(from: koeln, to: duesseldorf)),
                                     try #require(late.leg(from: duesseldorf, to: berlin))], source: .bahnDe)
        let direct = Journey(legs: [try #require(fast.leg(from: koeln, to: berlin))], source: .bahnDe)
        let primary = MockProvider(source: .bahnDe)
        primary.journeyPages = [JourneyPage(journeys: [direct, withTransfer, tooLate], earlierCursor: nil, laterCursor: nil, source: .bahnDe)]
        let provider = CombinedProvider(primary: primary, fallback: MockProvider(source: .transitous), bahnDe: nil)
        return (TrainPicker(provider: provider), try #require(fast.leg(from: koeln, to: berlin)), withTransfer)
    }

    @Test func connectionsWithTransfersSkipDirectAndOutOfWindow() async throws {
        let (picker, leg, withTransfer) = try transferPicker()
        let connections = try await picker.connections(for: leg)
        #expect(connections.map(\.id) == [withTransfer.id])
    }

    @Test func replaceLegWithConnection() async throws {
        let (picker, leg, withTransfer) = try transferPicker()
        let journey = Journey(legs: [leg], source: .bahnDe)
        let replaced = try await picker.replacing(legAt: 0, in: journey, with: withTransfer.legs, finalDestination: berlin)
        #expect(replaced.legs.map(\.tripId) == ["re5", "ice10"])
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

    /// Alfred's example: Berlin Hbf → Halle → back to Gesundbrunnen on an ICE that also stops at Hbf
    /// (no boarding there) is a detour and gets hidden; so is leaving a train that goes on to the
    /// destination. A change onto a train that doesn't call at either station stays.
    @Test func detoursOntoATrainCallingAtTheOriginOrDestination() {
        let hbf = station("8011160", "Berlin Hbf"), halle = station("8010159", "Halle (Saale) Hbf")
        let gesundbrunnen = station("8011102", "Berlin Gesundbrunnen"), leipzig = station("8010205", "Leipzig Hbf")
        let base = Date(timeIntervalSince1970: 1_790_000_000)
        func t(_ minutes: Double) -> Date { base.addingTimeInterval(minutes * 60) }
        func leg(_ trip: String, _ from: Station, _ to: Station, _ dep: Double, _ arr: Double) -> Leg {
            Leg(origin: from, destination: to, departure: TimeInfo(planned: t(dep), actual: nil),
                arrival: TimeInfo(planned: t(arr), actual: nil), departurePlatform: nil, arrivalPlatform: nil,
                tripId: trip, line: Line(name: "ICE \(trip)", number: trip, product: .highSpeed, operatorName: nil),
                direction: nil, isWalking: false, cancelled: false, stopovers: [], remarks: [], source: .transitous)
        }
        func entry(_ trip: String, _ kind: BoardKind, _ minutes: Double, _ access: StopAccess = .normal) -> BoardEntry {
            BoardEntry(kind: kind, tripId: trip, station: hbf,
                       line: Line(name: "ICE \(trip)", number: trip, product: .highSpeed, operatorName: nil), otherEnd: nil,
                       time: TimeInfo(planned: t(minutes), actual: nil), platform: PlatformInfo(planned: nil, actual: nil),
                       cancelled: false, terminatesOrOriginatesHere: false, remarks: [], access: access, source: .transitous)
        }
        // ICE 594 runs Halle → Berlin Hbf (no boarding, minute 150) → Gesundbrunnen (minute 158).
        let calls = StationCalls(departuresAtOrigin: [entry("594", .departures, 150, .exitOnly), entry("10", .departures, 0)],
                                 departuresAtDestination: [entry("700", .departures, 50)],
                                 arrivalsAtDestination: [entry("594", .arrivals, 158), entry("700", .arrivals, 48)])

        let viaHalle = Journey(legs: [leg("10", hbf, halle, 0, 70), leg("594", halle, gesundbrunnen, 80, 158)], source: .transitous)
        #expect(calls.isDetour(viaHalle))

        // ICE 700 reaches Gesundbrunnen at minute 48, but the route leaves it earlier and goes on by another train.
        let offEarly = Journey(legs: [leg("700", hbf, leipzig, 0, 20), leg("11", leipzig, gesundbrunnen, 30, 60)], source: .transitous)
        #expect(calls.isDetour(offEarly))

        let normal = Journey(legs: [leg("10", hbf, halle, 0, 70), leg("12", halle, leipzig, 80, 110)], source: .transitous)
        #expect(!calls.isDetour(normal))
        #expect(!calls.isDetour(Journey(legs: [leg("594", hbf, gesundbrunnen, 150, 158)], source: .transitous)))

        // Transitous' routing offers ICE 594 from Hbf as a normal ride; the stop times mark it "Nur Ausstieg".
        var direct = leg("594", hbf, gesundbrunnen, 150, 158)
        direct.stopovers = [Stopover(station: hbf, arrival: nil, departure: direct.departure, arrivalPlatform: nil, departurePlatform: nil, cancelled: false),
                            Stopover(station: gesundbrunnen, arrival: direct.arrival, departure: nil, arrivalPlatform: nil, departurePlatform: nil, cancelled: false)]
        let marked = calls.marking(Journey(legs: [direct], source: .transitous))
        #expect(marked.legs[0].stopovers.first?.access == .exitOnly)
        #expect(marked.legs[0].stopovers.last?.access == .normal)
        #expect(StationCalls.directTripIds([marked, viaHalle]) == ["594"])
    }

    /// Expert option "Nur Ein-/Ausstieg ignorieren": only trains you may not board at the origin, or
    /// not leave at the destination, are looked up; normal ones the search already has.
    @Test func restrictedCandidatesAreTrainsWithoutBoardingOrAlighting() {
        func entry(_ tripId: String, _ access: StopAccess, product: Product = .highSpeed, cancelled: Bool = false) -> BoardEntry {
            BoardEntry(kind: .departures, tripId: tripId, station: station("1", "Berlin Hbf"),
                       line: Line(name: "ICE \(tripId)", number: tripId, product: product, operatorName: nil), otherEnd: nil,
                       time: TimeInfo(planned: .now, actual: nil), platform: PlatformInfo(planned: nil, actual: nil),
                       cancelled: cancelled, terminatesOrOriginatesHere: false, remarks: [], access: access, source: .transitous)
        }
        let atOrigin = [entry("1", .exitOnly), entry("2", .normal), entry("3", .normal), entry("4", .exitOnly, cancelled: true),
                        entry("5", .exitOnly, product: .bus), entry("1", .exitOnly)]
        let atDestination = [entry("3", .entryOnly), entry("2", .normal)]
        let candidates = TrainPicker.restrictedCandidates(departures: atOrigin, atDestination: atDestination)
        #expect(candidates.map(\.tripId) == ["1", "3"])
    }

    final class SlowProvider: TransitProvider, @unchecked Sendable {
        let source = DataSource.bahnDe
        let finished = Mutex(false)
        func searchStations(_ query: String) async throws -> [Station] {
            try await Task.sleep(for: .seconds(30))
            finished.withLock { $0 = true }
            return []
        }
        func journeys(_ query: JourneyQuery) async throws -> JourneyPage { throw TransitError.timeout }
        func board(_ kind: BoardKind, at station: Station, date: Date, duration: Int, products: Set<Product>) async throws -> [BoardEntry] { [] }
        func trip(id: String) async throws -> Trip { throw TransitError.timeout }
    }

    @Test func slowPrimaryFallsBackQuickly() async throws {
        let slow = SlowProvider()
        let combined = CombinedProvider(primary: slow, fallback: MockProvider(source: .transitous), bahnDe: nil)
        let result = try await combined.searchStations("Köln")
        #expect(result.first?.source == .transitous)
        // Fell back without waiting for the slow provider (checked against it, not a stopwatch).
        #expect(!slow.finished.withLock { $0 })
    }

    /// The deadline holds even when the work is slow to stop once cancelled (a URL request winding
    /// down), so a hanging extra query can't hold up the station search.
    @Test func deadlineDoesntWaitForWorkSlowToStop() async {
        let stopped = Mutex(false)
        let result = try? await CombinedProvider.withDeadline(.milliseconds(100)) {
            await withCheckedContinuation { continuation in
                DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                    stopped.withLock { $0 = true }
                    continuation.resume()
                }
            }
            return 1
        }
        #expect(result == nil)
        #expect(!stopped.withLock { $0 })
    }
}

@Suite struct BahnDeFormationTests {
    /// A saved journey keeps the Tz once seen; formations without one, or unchanged ones, change nothing.
    @Test func remembersFormationsNamingATz() {
        let tz = TrainFormation(units: [TrainFormation.Unit(model: "ICE 4", number: "9457", name: "Bundesrepublik Deutschland")])
        let modelOnly = TrainFormation(units: [TrainFormation.Unit(model: "ICE 4", number: nil)])
        let stored = TrainFormation.remembering(tz, for: "a", in: nil)
        #expect(stored == ["a": tz])
        #expect(TrainFormation.remembering(tz, for: "a", in: stored) == nil)
        #expect(TrainFormation.remembering(modelOnly, for: "a", in: stored) == nil)
        let swapped = TrainFormation(units: [TrainFormation.Unit(model: "ICE 4", number: "9018")])
        #expect(TrainFormation.remembering(swapped, for: "a", in: stored) == ["a": swapped])
        #expect(TrainFormation.remembering(swapped, for: "b", in: stored) == ["a": tz, "b": swapped])
    }

    /// The key survives a refresh renaming the train or changing its trip.
    @Test func formationKeyIgnoresTrainNameAndTrip() {
        let at = { (minutes: Double) in TimeInfo(planned: Date(timeIntervalSince1970: 1_800_000_000 + minutes * 60), actual: nil) }
        func leg(_ name: String, tripId: String, departure: Double) -> Leg {
            Leg(origin: station("8002549", "Hamburg Hbf"), destination: station("8010085", "Dresden Hbf"),
                departure: at(departure), arrival: at(150), departurePlatform: nil, arrivalPlatform: nil, tripId: tripId,
                line: Line(name: name, number: "171", product: .highSpeed, operatorName: nil), direction: nil,
                isWalking: false, cancelled: false, stopovers: [], remarks: [], source: .transitous)
        }
        #expect(leg("ICE 171", tripId: "x", departure: 0).formationKey == leg("RJ 171", tripId: "y", departure: 0).formationKey)
        #expect(leg("ICE 171", tripId: "x", departure: 0).formationKey != leg("ICE 171", tripId: "x", departure: 60).formationKey)
    }

    @Test func carriageReadsCountryAndSeriesFromUICNumber() {
        let car = Carriage(vehicleID: "93805401002-1", constructionType: "Apmzf")
        #expect(car.uic == "938054010021")
        #expect(car.country == 80)
        #expect(car.model == 401)
        #expect(Carriage(vehicleID: nil, constructionType: nil).model == nil)
    }

    @Test func detectsSeriesFromUICNumbers() {
        let cars = { (ids: [String]) in ids.map { Carriage(vehicleID: $0, constructionType: nil) } }
        #expect(TrainModel.detect(cars(["938054010021", "938058010034"]), category: "ICE")?.name == "ICE 1")
        #expect(TrainModel.detect(cars(["938054030151", "938054030169"]), category: "ICE")?.series == "BR 403, 1. Serie")
        #expect(TrainModel.detect(cars(["938054030501", "938054030519"]), category: "ICE")?.series == "BR 403, 2. Serie")
        #expect(TrainModel.detect(cars(["938054080011", "938054080029"]), category: "ICE")?.name == "ICE 3neo")
        #expect(TrainModel.detect(cars(["938054120011", "938058120029"]), category: "ICE")?.name == "ICE 4")
        #expect(TrainModel.detect(cars(["938140110011", "938140110029"]), category: "ICE")?.name == "ICE T")
        // A single matching vehicle is inconclusive.
        #expect(TrainModel.detect(cars(["938054080011"]), category: "ICE") == nil)
    }

    @Test func tellsFlirt1430FromSBahn430() {
        let cars = { (ids: [String]) in ids.map { Carriage(vehicleID: $0, constructionType: nil) } }
        // FLIRT 3 (BR 1430/1830): its model digits are "430" like the S-Bahn's.
        #expect(TrainModel.detect(cars(["948014300011", "948018300015", "948014300029"]), category: "RE")?.series == "BR 1430")
        #expect(TrainModel.detect(cars(["948004300011", "948008300015", "948004310019"]), category: "S")?.series == "BR 430")
        #expect(TrainModel.detect(cars(["948014400011", "948014410019"]), category: "RE")?.series == "BR 1440")
        #expect(TrainModel.detect(cars(["948004400011", "948004410019"]), category: "RE")?.series == "BR 440")
    }

    @Test func detectsIntercity2FromDoubleDeckCoaches() {
        let cars = ["508026810011", "508026810029"].map { Carriage(vehicleID: $0, constructionType: "DApza") }
        #expect(TrainModel.detect(cars, category: "IC")?.name == "IC 2 Twindexx")
    }

    @Test func constructionTypeFallback() {
        #expect(BahnDeClient.model(constructionTypes: ["I4080", "I4081"], groupName: "ICE8033", category: "ICE") == "ICE 3neo")
        #expect(BahnDeClient.model(constructionTypes: ["I0812", "I1412", "I1812"], groupName: "ICE9465", category: "ICE") == "ICE 4")
        #expect(BahnDeClient.model(constructionTypes: ["I4010", "I8010"], groupName: "ICE0160", category: "ICE") == "ICE 1")
        #expect(BahnDeClient.model(constructionTypes: ["I4110", "I4115"], groupName: "ICE1162", category: "ICE") == "ICE T")
        #expect(BahnDeClient.model(constructionTypes: ["R8911", "R8921"], groupName: "ICE1811", category: "ICE") == "ICE L")
        #expect(BahnDeClient.model(constructionTypes: ["E1465", "R6682"], groupName: "ICD2854", category: "IC") == "IC 2 Twindexx")
    }

    @Test func marksRedesignedICE3neo() {
        #expect(TrainModel.name("ICE 3neo", unit: "8016") == "ICE 3neo")
        #expect(TrainModel.name("ICE 3neo", unit: "8017") == "ICE 3neo Redesign")
        #expect(TrainModel.name("ICE 3neo", unit: "8045") == "ICE 3neo Redesign")
        #expect(TrainModel.name("ICE 3neo", unit: nil) == "ICE 3neo")
        #expect(TrainModel.name("ICE 4", unit: "9465") == "ICE 4")
        #expect(TrainModel.name(nil, unit: "8030") == nil)
    }

    @Test func unitNumbersAndTrainsetNames() {
        #expect(BahnDeClient.unitNumber(from: "ICE9457") == "9457")
        #expect(BahnDeClient.unitNumber(from: "ICE0169") == "169")
        #expect(BahnDeClient.unitNumber(from: "373-planned") == nil)
        #expect(BahnDeClient.trainsetName(from: "ICE9457") == "Bundesrepublik Deutschland")
        #expect(BahnDeClient.trainsetName(from: "ICE0169") == "Worms")
        #expect(BahnDeClient.trainsetName(from: "IC 2054") == nil)
    }

    /// Double traction of ICE 4 coupled with a second half running as another train: only the
    /// requested train's groups count, each with its own Tz and Taufname.
    @Test func decodesSequenceAndKeepsOwnTrainsGroups() throws {
        let json = #"""
        {"groups": [
            {"name": "ICE9457", "transport": {"category": "ICE", "number": 950},
             "vehicles": [
                {"vehicleID": "938054120011", "wagonIdentificationNumber": 1, "type": {"category": "POWERCAR", "constructionType": "I1412"}, "platformPosition": {"sector": "A"}},
                {"vehicleID": "938058120029", "wagonIdentificationNumber": 2, "type": {"category": "PASSENGERCARRIAGE_FIRST_CLASS", "constructionType": "I1812"}}]},
            {"name": "ICE9018", "transport": {"category": "ICE", "number": 950},
             "vehicles": [
                {"vehicleID": "938054120037", "type": {"category": "POWERCAR", "constructionType": "I1412"}},
                {"vehicleID": "938058120045", "type": {"category": "PASSENGERCARRIAGE_ECONOMY_CLASS", "constructionType": "I1812"}}]},
            {"name": "ICE8033", "transport": {"category": "ICE", "number": 940},
             "vehicles": [
                {"vehicleID": "938054080011", "type": {"category": "POWERCAR", "constructionType": "I4080"}},
                {"vehicleID": "938054080029", "type": {"category": "POWERCAR", "constructionType": "I4081"}}]}
        ]}
        """#
        let response = try JSONDecoding.decoder.decode(BahnDeClient.SequenceResponse.self, from: Data(json.utf8))
        let formation = BahnDeClient.formation(from: response, category: "ICE", number: 950)
        #expect(formation.units == [
            .init(model: "ICE 4", number: "9457", name: "Bundesrepublik Deutschland"),
            .init(model: "ICE 4", number: "9018", name: "Freistaat Bayern"),
        ])
        #expect(formation.modelSummary == "2× ICE 4")
        #expect(formation.unitDescription == "Tz 9457 „Bundesrepublik Deutschland“ + 9018 „Freistaat Bayern“")
    }

    /// A group without vehicles (or other missing fields) must not lose the whole formation.
    @Test func toleratesMissingFields() throws {
        let json = #"""
        {"groups": [
            {"name": "ICE9457", "transport": {"category": "ICE", "number": 950}},
            {"vehicles": [{"vehicleID": "938054120011"}, {"vehicleID": "938058120029"}]}
        ]}
        """#
        let response = try JSONDecoding.decoder.decode(BahnDeClient.SequenceResponse.self, from: Data(json.utf8))
        let formation = BahnDeClient.formation(from: response, category: "ICE", number: 950)
        #expect(formation.units.first?.number == "9457")
        #expect(formation.units.first?.name == "Bundesrepublik Deutschland")
        // Asked for another train, only the group without a number is left.
        let other = BahnDeClient.formation(from: response, category: "ICE", number: 1)
        #expect(other.units.map(\.model) == ["ICE 4"])
        #expect(try JSONDecoding.decoder.decode(BahnDeClient.SequenceResponse.self, from: Data("{}".utf8)).groups == nil)
    }

    /// bahn.de answered RE 6 at Itzehoe with another train's FLIRTs: units that all name a different
    /// train show neither as the train's type nor as its Wagenreihung.
    @Test func ignoresAnotherTrainsSequence() throws {
        let json = #"""
        {"groups": [
            {"name": "RP1", "transport": {"category": "RE", "number": 21075},
             "vehicles": [{"vehicleID": "948014300011"}, {"vehicleID": "948014300029"}]}
        ]}
        """#
        let response = try JSONDecoding.decoder.decode(BahnDeClient.SequenceResponse.self, from: Data(json.utf8))
        #expect(BahnDeClient.formation(from: response, category: "RE", number: 11013).units.isEmpty)
        let sequence = BahnDeClient.coachSequence(from: response, category: "RE", number: 11013)
        #expect(sequence.coaches.isEmpty && sequence.groups.isEmpty)
        #expect(BahnDeClient.formation(from: response, category: "RE", number: 21075).modelSummary == "FLIRT")
    }

    /// A real bahn.de response (ICE 117 at Frankfurt (Main) Hbf, Gleis 12): coaches from the front,
    /// with class, amenities and platform positions.
    @Test func decodesCoachSequence() throws {
        let response = try fixture("bahnde-vehicle-sequence", as: BahnDeClient.SequenceResponse.self)
        let sequence = BahnDeClient.coachSequence(from: response, category: "ICE", number: 117)
        #expect(sequence.platform == "12")
        #expect(sequence.platformLength == 319.05)
        #expect(sequence.sectors.map(\.name) == ["A", "B", "C", "D", "E"])
        #expect(sequence.coaches.map(\.number) == ["21", "22", "23", "24", "25", "26", "27"])
        #expect(sequence.travelsTowardsPlatformEnd == true)
        #expect(sequence.differsFromSchedule)
        #expect(sequence.groups.first?.destination == "Graz Hbf")
        #expect(sequence.groups.first?.trainName == "ICE 117")
        #expect(sequence.groups.first?.unit?.number == "9226")
        #expect(!sequence.hasOtherTrains)

        let first = sequence.coaches[0]
        #expect(first.secondClass && !first.firstClass)
        #expect(first.sector == "D")
        #expect(first.start == 188.1)
        #expect(first.bikeSpaces == 8)
        #expect(first.amenities == [.bikeSpace, .severelyDisabledSeats])
        #expect(sequence.coaches[4].amenities.contains(.wheelchairSpace))
        #expect(sequence.coaches[5].kind == .halfDiningCar && sequence.coaches[5].firstClass)
        #expect(sequence.formation.units.first?.number == "9226")
    }

    /// bahn.de flags this ordinary ICE T as differing; compared with the plan nothing does, whichever
    /// way round the plan stands.
    @Test func coachSequenceDeviationsFromThePlan() throws {
        let response = try fixture("bahnde-vehicle-sequence", as: BahnDeClient.SequenceResponse.self)
        let actual = BahnDeClient.coachSequence(from: response, category: "ICE", number: 117)
        var plan = actual
        plan.source = .vagonweb(validFrom: nil, validUntil: nil)
        plan.coaches = actual.coaches.reversed()
        #expect(actual.differsFromSchedule)
        #expect(actual.deviations(fromPlan: plan).isEmpty)
        #expect(actual.deviations(fromPlan: plan.turned(after: ["Frankfurt (Main) Hbf"])).isEmpty)

        // A second trainset in the plan that didn't come, and a coach in the other class.
        var double = plan
        double.coaches += (31...37).map { number in
            var coach = actual.coaches[1]
            coach.number = String(number)
            return coach
        }
        double.coaches[6].firstClass = true
        #expect(actual.deviations(fromPlan: double) == ["Wagen 31–37 fehlen", "Wagen 21: 2. statt 1. Klasse"])

        // A shorter plan: the extra coaches are named.
        var short = plan
        short.coaches.removeAll { $0.number == "23" }
        #expect(actual.deviations(fromPlan: short) == ["Zusätzlich Wagen 23"])

        // Numbered differently: only the counts are compared.
        var renumbered = plan
        for index in renumbered.coaches.indices { renumbered.coaches[index].number = "\(index + 1)" }
        #expect(actual.deviations(fromPlan: renumbered).isEmpty)
        renumbered.coaches.removeLast()
        #expect(actual.deviations(fromPlan: renumbered).first == "7 statt 6 Wagen")
    }

    @Test func coachNumberList() {
        #expect(CoachSequence.numberList(["25"]) == "25")
        #expect(CoachSequence.numberList(["23", "21"]) == "21, 23")
        #expect(CoachSequence.numberList(["39", "31", "32", "33", "35", "36", "37", "38"]) == "31–33, 35–39")
        #expect(CoachSequence.numberList(["21", "22"]) == "21, 22")
    }

    /// A locomotive listed as its own group, ending where it is changed, is no train part with another destination.
    @Test func coachSequenceIgnoresLocomotiveChange() throws {
        let json = #"""
        {"groups": [
            {"name": "IC2013", "transport": {"category": "IC", "number": 2013, "destination": {"name": "Stuttgart Hbf"}},
             "vehicles": [{"type": {"category": "LOCOMOTIVE"}}]},
            {"name": "IC2013", "transport": {"category": "IC", "number": 2013, "destination": {"name": "Oberstdorf"}},
             "vehicles": [{"wagonIdentificationNumber": 1, "type": {"category": "PASSENGERCARRIAGE_FIRST_CLASS"}},
                          {"wagonIdentificationNumber": 2, "type": {"category": "PASSENGERCARRIAGE_ECONOMY_CLASS"}}]}
        ]}
        """#
        let response = try JSONDecoding.decoder.decode(BahnDeClient.SequenceResponse.self, from: Data(json.utf8))
        let sequence = BahnDeClient.coachSequence(from: response, category: "IC", number: 2013)
        #expect(sequence.isLocomotiveOnly(group: 0))
        #expect(!sequence.isLocomotiveOnly(group: 1))
        #expect(sequence.travellingGroups.compactMap(\.destination) == ["Oberstdorf"])
        #expect(!sequence.partsGoToDifferentPlaces)
        #expect(!sequence.hasOtherTrains)
        #expect(!sequence.hasSeveralTrains)
    }

    /// Coupled trains: the other half keeps its own destination, and power cars have no coach number.
    @Test func coachSequenceMarksOtherTrains() throws {
        let json = #"""
        {"platform": {"name": "7", "start": 10, "end": 410, "sectors": [{"name": "A", "start": 10, "end": 110}]},
         "groups": [
            {"name": "ICE8033", "transport": {"category": "ICE", "number": 940, "destination": {"name": "Münster (Westf) Hbf"}},
             "vehicles": [{"wagonIdentificationNumber": 38, "type": {"category": "POWERCAR"}, "platformPosition": {"start": 20, "end": 45}}]},
            {"name": "ICE8005", "transport": {"category": "ICE", "number": 950, "destination": {"name": "Berlin Hbf"}},
             "vehicles": [{"wagonIdentificationNumber": 21, "status": "CLOSED", "type": {"category": "PASSENGERCARRIAGE_ECONOMY_CLASS"}, "platformPosition": {"start": 220, "end": 245}}]}
        ]}
        """#
        let response = try JSONDecoding.decoder.decode(BahnDeClient.SequenceResponse.self, from: Data(json.utf8))
        let sequence = BahnDeClient.coachSequence(from: response, category: "ICE", number: 950)
        #expect(sequence.groups.map(\.isRequestedTrain) == [false, true])
        #expect(sequence.hasOtherTrains)
        #expect(sequence.coaches.map(\.number) == [nil, "21"])
        #expect(sequence.coaches[1].closed)
        #expect(sequence.coaches[1].secondClass)
        // Measured from the platform's start.
        #expect(sequence.coaches[0].start == 10)
        #expect(sequence.sectors.first?.end == 100)
        #expect(sequence.platformLength == 400)
        #expect(sequence.travelsTowardsPlatformEnd == false)
    }

    /// DB Regio's trains have coach sequences too, asked for by run number; categories bahn.de
    /// doesn't know are sent as RB, since an unknown one is refused with a 403.
    @Test func sequenceReferenceForRegionalTrains() {
        let re = Line(name: "RE 50", number: "50", product: .regionalExpress, operatorName: nil, tripNumber: "4530")
        #expect(BahnDeClient.sequenceReference(for: re)?.category == "RE")
        #expect(BahnDeClient.sequenceReference(for: re)?.number == "4530")
        let mex = Line(name: "MEX 12", number: "12", product: .regional, operatorName: nil, tripNumber: "19310")
        #expect(BahnDeClient.sequenceReference(for: mex)?.category == "RB")
        #expect(BahnDeClient.sequenceReference(for: Line(name: "RB 48", number: "48", product: .regional, operatorName: nil)) == nil)
        #expect(BahnDeClient.sequenceReference(for: Line(name: "S 8", number: "8", product: .suburban, operatorName: nil, tripNumber: "37856")) == nil)
    }

    /// A regional train's groups are named after fleet IDs, which are no Tz.
    @Test func regionalSequenceHasNoTrainsetNumbers() throws {
        let json = #"""
        {"departurePlatform": "9", "groups": [
            {"name": "918061462605", "transport": {"category": "RE", "number": 4530, "destination": {"name": "Fulda"}},
             "vehicles": [{"vehicleID": "918061462605", "type": {"category": "LOCOMOTIVE", "constructionType": "E1463"}, "platformPosition": {"start": 181.27, "end": 200.17}}]},
            {"name": "RP8352001", "transport": {"category": "RE", "number": 4530, "destination": {"name": "Fulda"}},
             "vehicles": [
                {"type": {"category": "DOUBLEDECK_FIRST_ECONOMY_CLASS", "hasEconomyClass": true, "hasFirstClass": true}, "platformPosition": {"start": 100.87, "end": 127.67}},
                {"type": {"category": "DOUBLEDECK_CONTROLCAR_ECONOMY_CLASS", "hasEconomyClass": true, "hasFirstClass": false},
                 "amenities": [{"type": "BIKE_SPACE", "status": "UNDEFINED", "amount": 0}], "platformPosition": {"start": 20, "end": 47.27}}]}
        ]}
        """#
        let response = try JSONDecoding.decoder.decode(BahnDeClient.SequenceResponse.self, from: Data(json.utf8))
        let sequence = BahnDeClient.coachSequence(from: response, category: "RE", number: 4530)
        #expect(sequence.groups.allSatisfy { $0.unit == nil })
        #expect(sequence.formation.unitDescription == nil)
        #expect(sequence.coaches.map(\.kind) == [.locomotive, .passenger, .passenger])
        #expect(sequence.coaches[1].firstClass && sequence.coaches[1].secondClass)
        #expect(sequence.coaches[2].amenities == [.bikeSpace])
        #expect(sequence.travelsTowardsPlatformEnd == true)
    }

    /// Transitous only knows Westerland as the combined "Westerland(Sylt) ZOB/Bahnhof" stop, and
    /// bahn.de's nearest hit is a meta station bundling it with the bus station, whose ID has no
    /// platforms in Timetables. The railway station itself must win.
    @Test func evaSkipsMetaStationsAndBusStops() {
        let make = { (id: String, name: String, lat: Double, lon: Double, trains: Bool) in
            BahnDeClient.Candidate(station: Station(id: id, name: name, coordinate: Coordinate(latitude: lat, longitude: lon),
                                                    evaNumber: id, source: .bahnDe), hasTrains: trains)
        }
        let candidates = [
            make("709827", "Westerland Bahnhof/ZOB, Sylt", 54.906185, 8.310824, true),
            make("8070262", "Westerland Alte Post, Sylt", 54.906900, 8.310900, false),
            make("8006369", "Westerland(Sylt)", 54.90763, 8.309979, true),
            make("8030918", "Westerland (Sylt) Autoverladung", 54.904736, 8.313638, true),
        ]
        let transitous = Station(id: "de-DELFI_de:01054:98523", name: "Westerland(Sylt) ZOB/Bahnhof",
                                 coordinate: Coordinate(latitude: 54.906837, longitude: 8.310925), evaNumber: nil, source: .transitous)
        #expect(BahnDeClient.bestEVA(for: transitous, among: candidates) == "8006369")
    }

    @Test func formationSummary() {
        let formation = TrainFormation(units: [.init(model: "ICE 3neo", number: "8030"), .init(model: "ICE 3neo", number: "8005")])
        #expect(formation.modelSummary == "ICE 3neo Redesign + ICE 3neo")
        #expect(formation.unitSummary == "Tz 8030 + 8005")
        #expect(formation.unitDescription == "Tz 8030 + 8005")
    }

    @Test func formationURLUsesGermanDayAndUTCMilliseconds() throws {
        // 00:30 in Berlin on the 30th is still the 29th in UTC; bahn.de wants the German day (it
        // answers 404 for the 29th, e.g. ICE 1540 leaving Brandenburg Hbf at 00:41).
        let departure = try #require(JSONDecoding.parseISODate("2026-09-29T22:30:00Z"))
        let request = BahnDeClient.FormationRequest(category: "ICE", number: "693", station: station("8000105", "Frankfurt (Main) Hbf"), plannedDeparture: departure)
        let url = BahnDeClient.formationURL(request, eva: "8000105").absoluteString
        #expect(url.hasPrefix("https://betterbahn2.betterbahn.workers.dev/web/api/reisebegleitung/wagenreihung/vehicle-sequence?"))
        #expect(url.contains("administrationId=80"))
        #expect(url.contains("date=2026-09-30"))
        #expect(url.contains("time=2026-09-29T22:30:00.000Z"))
        #expect(url.contains("number=693"))
    }

    /// bahn.de only has Berlin Hbf's lower-level trains under "Berlin Hbf (tief)" (8098160), which station
    /// search never returns: a 404 at 8011160 is asked again there.
    @Test func coachSequenceTriesBerlinHbfLowerLevel() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LowerLevelSequenceProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let bahnDe = BahnDeClient(http: HTTPClient(session: session), gate: BahnDeGate())
        let departure = try #require(JSONDecoding.parseISODate("2026-10-01T21:51:00Z"))
        let request = BahnDeClient.FormationRequest(category: "ICE", number: "117", station: station("8011160", "Berlin Hbf"),
                                                    plannedDeparture: departure)

        let sequence = try await bahnDe.coachSequence(request)

        #expect(sequence?.coaches.isEmpty == false)
        #expect(LowerLevelSequenceProtocol.requestedEVAs.withLock { $0 } == ["8011160", "8098160"])
        #expect(BahnDeClient.otherLevel(of: "8000105") == nil)
    }

    /// Only a stop where the train still departs, and only when that is soon enough for bahn.de.
    @Test func formationRequestPicksNextDepartingStop() throws {
        let now = try #require(JSONDecoding.parseISODate("2026-09-29T12:00:00Z"))
        let line = Line(name: "ICE 693", number: "693", product: .highSpeed, operatorName: nil)
        let at = { (minutes: Double) in TimeInfo(planned: now.addingTimeInterval(minutes * 60), actual: nil) }
        let stops = [(station: station("1", "Gone"), departure: Optional(at(-10))),
                     (station: station("2", "Next"), departure: Optional(at(20))),
                     (station: station("3", "Later"), departure: Optional(at(60)))]
        #expect(BahnDeClient.formationRequest(line: line, stops: stops, now: now)?.station.name == "Next")
        #expect(BahnDeClient.formationRequest(line: line, stops: [(station: station("4", "Tonight"), departure: at(8 * 60))], now: now)?.station.name == "Tonight")
        #expect(BahnDeClient.formationRequest(line: line, stops: [(station: station("5", "Tomorrow"), departure: at(13 * 60))], now: now) == nil)
        // vagonweb's planned Wagenreihung has no lookahead.
        #expect(BahnDeClient.formationRequest(line: line, stops: [(station: station("5", "Tomorrow"), departure: at(13 * 60))], now: now, lookahead: nil)?.station.name == "Tomorrow")
        let regional = Line(name: "RE 5", number: "5", product: .regional, operatorName: nil)
        #expect(BahnDeClient.formationRequest(line: regional, stops: stops, now: now) == nil)
    }

    @Test func browserHeadersLikeDBRIS() {
        let headers = BahnDeClient.headers()
        #expect(headers["Origin"] == "https://www.bahn.de")
        #expect(headers["Referer"] == "https://www.bahn.de/buchung/fahrplan/suche")
        #expect(headers["User-Agent"]?.hasPrefix("Mozilla/5.0") == true)
        #expect(headers["User-Agent"]?.contains("XXXX") == false)
        #expect(headers["x-correlation-id"]?.contains("_") == true)
    }

    @Test func trainReferenceOnlyForLongDistance() {
        let line = { (name: String, number: String) in Line(name: name, number: number, product: .highSpeed, operatorName: nil) }
        #expect(BahnDeClient.trainReference(for: line("ICE 950", "950"))?.category == "ICE")
        #expect(BahnDeClient.trainReference(for: line("RE 5", "5")) == nil)
        #expect(BahnDeClient.trainReference(for: nil) == nil)
    }

    @Test func berlinDayUsesLocalCalendarDay() {
        // 23:30 UTC on the 19th is already the 20th in Berlin (CEST).
        let date = Date(timeIntervalSince1970: 1_789_860_600)
        #expect(BahnDeClient.berlinDay(date) == "2026-09-20")
    }

    /// A 403 (`OPS_BLOCKED`) pauses bahn.de entirely instead of retrying.
    @Test func blockPausesFurtherRequests() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [BlockedProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let gate = BahnDeGate()
        let bahnDe = BahnDeClient(http: HTTPClient(session: session), gate: gate)
        let request = BahnDeClient.FormationRequest(category: "ICE", number: "693", station: station("8000105", "Frankfurt (Main) Hbf"), plannedDeparture: .now)

        await #expect(throws: TransitError.rateLimited) { try await bahnDe.formation(request) }
        #expect(await gate.isBlocked)
        await #expect(throws: TransitError.rateLimited) { try await bahnDe.formation(request) }
        #expect(BlockedProtocol.requests.withLock { $0 } == 1)
    }
}

private final class BlockedProtocol: URLProtocol, @unchecked Sendable {
    static let requests = Mutex(0)
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.withLock { $0 += 1 }
        let response = HTTPURLResponse(url: request.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"status":"ERROR","code":"OPS_BLOCKED"}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// bahn.expert is only used for the train type, since it has DB's planned formation for days ahead.
@Suite struct BahnExpertTrainTypeTests {
    @Test func familyStripsVariantAndClass() {
        #expect(TrainTypeLookup.family(of: "ICE 4 Lang (BR412)") == "ICE 4")
        #expect(TrainTypeLookup.family(of: "ICE 3neo (BR408)") == "ICE 3neo")
        #expect(TrainTypeLookup.family(of: "ICE 3") == "ICE 3")
    }

    @Test func familyPrefersBaureiheNumber() {
        let group = { (number: String?, name: String?) in
            TrainTypeLookup.Group(seriesName: name, baureihe: number, unitNumber: nil, origin: nil, destination: nil, coachCount: 0)
        }
        #expect(group("412", "ICE 4 Lang (BR412)").family == "ICE 4")
        #expect(group("407", "ICE 3 Velaro (BR407)").family == "ICE 3")
        #expect(group("408", "ICE 3neo (BR408)").family == "ICE 3neo")
        #expect(group(nil, "ICE L").family == "ICE L")
        #expect(group(nil, nil).family == nil)
    }

    @Test func summaryDeduplicatesFamiliesAndFormationAddsTaufname() {
        let group = { (name: String, unit: String?) in
            TrainTypeLookup.Group(seriesName: name, baureihe: nil, unitNumber: unit, origin: nil, destination: nil, coachCount: 13)
        }
        let lookup = TrainTypeLookup(category: "ICE", number: "373", date: "2026-09-20", administration: "80",
                                     groups: [group("ICE 4 Lang (BR412)", "9457"), group("ICE 4 Kurz (BR412)", nil)], status: .realtime,
                                     source: "DB", retrievedAt: .now)
        #expect(lookup.summary == "ICE 4")
        #expect(lookup.formation.unitDescription == "Tz 9457 „Bundesrepublik Deutschland“")
    }

    @Test func summaryMarksRedesignedICE3neo() {
        let group = { (unit: String?) in
            TrainTypeLookup.Group(seriesName: "ICE 3neo (BR408)", baureihe: "408", unitNumber: unit, origin: nil, destination: nil, coachCount: 8)
        }
        let lookup = { (groups: [TrainTypeLookup.Group]) in
            TrainTypeLookup(category: "ICE", number: "144", date: "2026-10-02", administration: "80", groups: groups,
                            status: .realtime, source: "DB", retrievedAt: .now)
        }
        #expect(lookup([group("8020")]).summary == "ICE 3neo Redesign")
        #expect(lookup([group("8020")]).formation.modelSummary == "ICE 3neo Redesign")
        #expect(lookup([group("8020"), group("8005")]).summary == "ICE 3neo Redesign + ICE 3neo")
        #expect(lookup([group(nil)]).summary == "ICE 3neo")
        #expect(lookup([group("8039")]).hasUnitNumbers)
        #expect(!lookup([group(nil)]).hasUnitNumbers)
    }

    /// Formations remembered before the Redesign rule stored plain "ICE 3neo" for Tz 8039.
    @Test func rememberedFormationMarksRedesignedICE3neo() {
        let formation = TrainFormation(units: [.init(model: "ICE 3neo", number: "8039"), .init(model: "ICE 3neo", number: "8005")])
        #expect(formation.modelSummary == "ICE 3neo Redesign + ICE 3neo")
        #expect(TrainFormation(units: [.init(model: "ICE 3neo Redesign", number: "8039")]).modelSummary == "ICE 3neo Redesign")
        #expect(TrainFormation(units: [.init(model: "ICE 3neo", number: nil)]).modelSummary == "ICE 3neo")
    }

    /// Real response for IC 2271 (2026-10-01): bahn.expert has no Baureihe for IC 2 Twindexx sets.
    @Test func twindexxSeriesFromGroupName() throws {
        let json = """
        {"isRealtime": true, "source": "DB-risTransports", "sequence": {"groups": [
            {"name": "ICD2868", "journeyNumber": 2271, "baureihe": null, "coaches": []}]}}
        """
        let response = try JSONDecoding.decoder.decode(BahnExpertClient.SequenceResponse.self, from: Data(json.utf8))
        let group = try #require(response.sequence?.groups.first)
        #expect(BahnExpertClient.seriesName(of: group, category: "IC") == "IC 2 Twindexx")
        #expect(BahnExpertClient.seriesName(of: group, category: "ICE") == nil)
        #expect(TrainTypeLookup.Group(seriesName: "IC 2 Twindexx", baureihe: nil, unitNumber: "2868", origin: nil,
                                      destination: nil, coachCount: 0).family == "IC 2 Twindexx")
    }

    /// Real response for ICE 693 two days ahead (2026-10-01): DB's plan, no Tz yet.
    @Test func decodesPlannedSequence() throws {
        let json = """
        {"isRealtime": false, "source": "DB-plan", "sequence": {"groups": [
            {"name": "693-planned", "journeyNumber": 693, "originName": "Berlin Gesundbrunnen",
             "baureihe": {"identifier": "412", "baureihe": "412", "name": "ICE 4 (BR412)"},
             "coaches": [{"type": "Apmzf"}, {"type": "Bpmz"}]}]}}
        """
        let response = try JSONDecoding.decoder.decode(BahnExpertClient.SequenceResponse.self, from: Data(json.utf8))
        #expect(!response.isRealtime)
        #expect(response.sequence?.groups.first?.baureihe?.name == "ICE 4 (BR412)")
        #expect(response.sequence?.groups.first?.coaches?.count == 2)
    }

    @Test func decodesSplitTrainGroupsWithTheirOwnJourneyNumbers() throws {
        let json = #"""
        {"isRealtime": true, "sequence": {"groups": [
            {"name": "ICE9220", "journeyNumber": 940, "baureihe": {"baureihe": "412", "name": "ICE 4 Kurz (BR412)"}},
            {"name": "ICE9227", "journeyNumber": 950, "baureihe": {"baureihe": "412", "name": "ICE 4 Kurz (BR412)"}}]}}
        """#
        let response = try JSONDecoding.decoder.decode(BahnExpertClient.SequenceResponse.self, from: Data(json.utf8))
        #expect(response.sequence?.groups.map(\.journeyNumber) == [940, 950])
    }

    /// Without a Referer bahn.expert returns an empty 206 and every lookup silently fails.
    @Test func requestsCarryTheRefererBahnExpertRequires() throws {
        let request = try BahnExpertClient.request(procedure: "journey/find", input: ["json": ["journeyNumber": 373]])
        #expect(request.value(forHTTPHeaderField: "Referer") == "https://bahn.expert/")
        #expect(request.url?.absoluteString == "https://bahn.expert/api/orpc/journey/find")
        #expect(request.httpMethod == "POST")
    }

    @Test func dayValidation() {
        #expect(BahnExpertClient.isValidDay("2026-09-20"))
        #expect(!BahnExpertClient.isValidDay("2026-02-31"))
        #expect(!BahnExpertClient.isValidDay("20.09.2026"))
    }
}

@Suite struct BahnDeJourneyTests {
    /// Real ICE 372 run (2026-09-22): it skipped Frankfurt (Main) Hbf and instead picked up an
    /// unscheduled stop at Frankfurt (Main) Süd. bahn.de flags that pair either directly
    /// (`canceled` / `additional`) or through messages, which DBRIS reads the same way.
    static let details = #"""
    {"halte": [
        {"id": "A=1@O=Mannheim Hbf@X=8469268@Y=49479181@L=8000244@", "extId": "8000244", "name": "Mannheim Hbf",
         "ankunftsZeitpunkt": "2026-09-22T12:22:00", "ezAnkunftsZeitpunkt": "2026-09-22T12:58:00",
         "abfahrtsZeitpunkt": "2026-09-22T12:30:00", "ezAbfahrtsZeitpunkt": "2026-09-22T13:02:00", "gleis": "3"},
        {"id": "A=1@O=Frankfurt(Main)Hbf@L=8000105@", "name": "Frankfurt(Main)Hbf",
         "abfahrt": {"sollzeit": "2026-09-22T13:15:00"},
         "priorisierteMeldungen": [{"type": "HALT_AUSFALL", "text": "Halt entfällt"}]},
        {"id": "A=1@O=Frankfurt(Main)Süd@X=8686303@Y=50099365@L=8002041@", "extId": "8002041", "name": "Frankfurt(Main)Süd",
         "abfahrt": {"sollzeit": "2026-09-22T13:19:00", "echtzeit": "2026-09-22T13:58:04"}, "gleis": "6", "ezGleis": "7",
         "priorisierteMeldungen": [{"text": "Zusatzhalt"}]},
        {"extId": "8000150", "name": "Hanau Hbf", "canceled": false,
         "ankunftsZeitpunkt": "2026-09-22T13:28:00", "abfahrtsZeitpunkt": "2026-09-22T13:30:00"},
        {"extId": "8000152", "name": "Hannover Hbf", "risMeldungen": [{"key": "text.realtime.stop.cancelled", "value": "Halt entfällt"}]}
    ]}
    """#

    static func stops() throws -> [JourneyStop] {
        try JSONDecoding.decoder.decode(BahnDeClient.JourneyDetails.self, from: Data(details.utf8)).halte.compactMap(JourneyStop.init)
    }

    @Test func decodesStopsLikeDBRIS() throws {
        let stops = try Self.stops()
        #expect(stops.map(\.evaNumber) == ["8000244", "8000105", "8002041", "8000150", "8000152"])
        #expect(stops[1].isCancelled && !stops[1].isAdditional)
        #expect(stops[2].isAdditional && !stops[2].isCancelled)
        #expect(stops[4].isCancelled)
        #expect(!stops[0].isAdditional && !stops[0].isCancelled && !stops[3].isCancelled)
        // Zone-less local times are Berlin time (CEST = UTC+2).
        #expect(stops[0].arrival?.planned == JSONDecoding.parseISODate("2026-09-22T10:22:00Z"))
        #expect(stops[0].departure?.actual == JSONDecoding.parseISODate("2026-09-22T11:02:00Z"))
        #expect(stops[2].departure?.actual == JSONDecoding.parseISODate("2026-09-22T11:58:04Z"))
        #expect(stops[2].departurePlatform == PlatformInfo(planned: "6", actual: "7"))
        let coordinate = try #require(stops[2].coordinate)
        #expect(abs(coordinate.latitude - 50.099365) < 0.000001 && abs(coordinate.longitude - 8.686303) < 0.000001)
    }

    @Test func findsTheZusatzhaltHop() throws {
        let stops = try Self.stops()
        let zusatzhalt = station("8002041", "Frankfurt (Main) Süd")
        let match = try #require(BahnDeClient.nextRegularStop(after: zusatzhalt, in: stops))
        #expect(match.zusatzhalt.evaNumber == "8002041")
        #expect(match.nextRegular.evaNumber == "8000150")
        // A regular (non-additional) stop is never mistaken for a Zusatzhalt.
        #expect(BahnDeClient.nextRegularStop(after: station("8000244", "Mannheim Hbf"), in: stops) == nil)
        // No regular stop left after the Zusatzhalt (e.g. it's also the run's last stop).
        #expect(BahnDeClient.nextRegularStop(after: zusatzhalt, in: Array(stops.prefix(3))) == nil)
    }

    /// `Trip`/`Leg` stopovers only ever come from Transitous, which never has a Zusatzhalt at all —
    /// `inserting(_:into:)` splices Frankfurt (Main) Süd into the existing (already realtime-overlaid)
    /// stop list rather than it being silently missing from the journey view.
    @Test func insertsTheZusatzhaltAtItsRightfulPlace() throws {
        let stops = try Self.stops()
        let existing = [
            station("8000244", "Mannheim Hbf"),
            station("8000105", "Frankfurt (Main) Hbf"),
            station("8000150", "Hanau Hbf"),
        ].enumerated().map { index, s in
            Stopover(station: s, arrival: nil, departure: nil, arrivalPlatform: nil, departurePlatform: nil, cancelled: index == 1)
        }

        let merged = BahnDeClient.inserting(stops, into: existing)

        #expect(merged.map(\.station.name) == ["Mannheim Hbf", "Frankfurt (Main) Hbf", "Frankfurt(Main)Süd", "Hanau Hbf"])
        #expect(merged[1].cancelled)
        #expect(merged[2].isAdditional)
        #expect(!merged[0].isAdditional && !merged[3].isAdditional)

        // Nothing to insert: the list comes back untouched.
        #expect(BahnDeClient.inserting(stops.filter { !$0.isAdditional }, into: existing) == existing)
        // Stopovers never loaded for this leg/trip: stays empty rather than showing a partial list.
        #expect(BahnDeClient.inserting(stops, into: []).isEmpty)
        // Re-running on an already merged list doesn't duplicate the Zusatzhalt.
        #expect(BahnDeClient.inserting(stops, into: merged) == merged)
    }

    /// DB's feed in Transitous has no platforms at Hamburg Hbf and Hamburg-Altona at all; bahn.de's
    /// journey details fill them in, matched by planned time and place even under another name.
    @Test func fillsMissingPlatformsFromBahnDeJourney() throws {
        let start = try #require(JSONDecoding.parseISODate("2026-10-02T07:16:00Z"))
        func at(_ minutes: Double) -> TimeInfo { TimeInfo(planned: start.addingTimeInterval(minutes * 60), actual: nil) }
        let altona = Station(id: "de-DELFI_de:02000:80953", name: "Hamburg-Altona", coordinate: Coordinate(latitude: 53.5527, longitude: 9.9352),
                             evaNumber: nil, source: .transitous)
        let hbf = Station(id: "de-DELFI_de:02000:10950", name: "Hamburg Hbf", coordinate: nil, evaNumber: nil, source: .transitous)
        let spandau = Station(id: "de-DELFI_spandau", name: "S Spandau Bhf (Berlin)", coordinate: Coordinate(latitude: 52.5343, longitude: 13.1975),
                              evaNumber: nil, source: .transitous)
        let leg = Leg(origin: altona, destination: spandau, departure: at(0), arrival: at(100),
                      departurePlatform: PlatformInfo(planned: nil, actual: nil), arrivalPlatform: PlatformInfo(planned: "5", actual: nil),
                      tripId: "rj", line: Line(name: "RJ 175", number: "175", product: .highSpeed, operatorName: nil),
                      direction: nil, isWalking: false, cancelled: false,
                      stopovers: [Stopover(station: altona, arrival: nil, departure: at(0), arrivalPlatform: nil, departurePlatform: nil, cancelled: false),
                                  Stopover(station: hbf, arrival: at(16), departure: at(18), arrivalPlatform: nil, departurePlatform: nil, cancelled: false),
                                  Stopover(station: spandau, arrival: at(100), departure: nil, arrivalPlatform: PlatformInfo(planned: "5", actual: nil),
                                           departurePlatform: nil, cancelled: false)],
                      remarks: [], source: .transitous)
        let stops = [
            JourneyStop(evaNumber: "8002553", name: "Hamburg-Altona", coordinate: Coordinate(latitude: 53.5526, longitude: 9.9351),
                        departure: at(0), departurePlatform: PlatformInfo(planned: "9", actual: nil)),
            JourneyStop(evaNumber: "8002549", name: "Hamburg Hbf", arrival: at(16), departure: at(18),
                        arrivalPlatform: PlatformInfo(planned: "8", actual: "7"), departurePlatform: PlatformInfo(planned: "8", actual: "7")),
            JourneyStop(evaNumber: "8010404", name: "Berlin-Spandau", coordinate: Coordinate(latitude: 52.5344, longitude: 13.1974),
                        arrival: at(100), arrivalPlatform: PlatformInfo(planned: "4", actual: nil)),
        ]

        let filled = BahnDeClient.fillingMissingPlatforms(in: leg, from: stops)

        #expect(filled.departurePlatform?.best == "9")
        #expect(filled.stopovers[0].departurePlatform?.best == "9")
        #expect(filled.stopovers[1].arrivalPlatform?.best == "7")
        #expect(filled.stopovers[1].departurePlatform?.best == "7")
        // Platforms Transitous already has stay.
        #expect(filled.arrivalPlatform?.best == "5")
        #expect(filled.stopovers[2].arrivalPlatform?.best == "5")
        #expect(BahnDeClient.lacksPlatforms(leg))
        #expect(!BahnDeClient.lacksPlatforms(filled))
        // Another time at the same station isn't this stop.
        let later = stops.map { var stop = $0; stop.departure = stop.departure.map { TimeInfo(planned: $0.planned.addingTimeInterval(3600), actual: nil) }; return stop }
        #expect(BahnDeClient.fillingMissingPlatforms(in: leg, from: later).departurePlatform?.best == nil)
    }

    @Test func findsJourneyIdOnBoard() throws {
        let json = #"""
        {"entries": [
            {"journeyId": "2|#VN#1#ST#1|wrong-time", "zeit": "2026-09-29T15:02:00", "verkehrmittel": {"name": "ICE 693"}},
            {"journeyId": "2|#VN#1#ST#1|other-train", "zeit": "2026-09-29T14:30:00", "verkehrmittel": {"name": "ICE 1093"}},
            {"journeyId": "2|#VN#1#ST#1|right", "zeit": "2026-09-29T14:31:00", "verkehrmittel": {"name": "ICE 693"}}
        ]}
        """#
        let board = try JSONDecoding.decoder.decode(BahnDeClient.Board.self, from: Data(json.utf8))
        let line = Line(name: "ICE 693", number: "693", product: .highSpeed, operatorName: nil)
        let planned = try #require(JSONDecoding.parseISODate("2026-09-29T12:30:00Z"))
        #expect(BahnDeClient.journeyId(in: board, for: line, plannedDeparture: planned) == "2|#VN#1#ST#1|right")
        let farOff = try #require(JSONDecoding.parseISODate("2026-09-29T06:00:00Z"))
        #expect(BahnDeClient.journeyId(in: board, for: line, plannedDeparture: farOff) == nil)
    }

    /// RE 3 from Bernau (bei Berlin) at 12:08 (2026-10-05) stopped additionally at Berlin-Lichtenberg.
    /// Regional trains are looked up by their run number (3307, Transitous' trip short name "003307")
    /// on bahn.de's regional board; the journey ID's number tells apart the RE 3 the other way.
    @Test func findsRegionalJourneyIdByRunNumber() throws {
        let json = #"""
        {"entries": [
            {"journeyId": "2|#VN#1#ST#1#PI#0#ZI#1#TA#0#DA#51026#1S#8010381#CA#RE#ZE#3306#ZB#RE 3    #PC#3#", "zeit": "2026-10-05T12:07:00", "verkehrmittel": {"name": "RE 3"}},
            {"journeyId": "2|#VN#1#ST#1#PI#0#ZI#2#TA#0#DA#51026#1S#8010338#CA#RE#ZE#3307#ZB#RE 3    #PC#3#", "zeit": "2026-10-05T12:08:00", "verkehrmittel": {"name": "RE 3"}}
        ]}
        """#
        let board = try JSONDecoding.decoder.decode(BahnDeClient.Board.self, from: Data(json.utf8))
        let line = Line(name: "RE3", number: "3", product: .regionalExpress, operatorName: nil, tripNumber: "3307")
        let ref = try #require(BahnDeClient.journeyReference(for: line))
        #expect(ref.category == "RE" && ref.number == "3307" && ref.isRegional)
        #expect(BahnDeClient.journeyReference(for: Line(name: "ICE 693", number: "693", product: .highSpeed, operatorName: nil))?.isRegional == false)
        // Without a run number a regional train can't be told apart from the line's other runs.
        #expect(BahnDeClient.journeyReference(for: Line(name: "RE3", number: "3", product: .regionalExpress, operatorName: nil)) == nil)

        let planned = try #require(JSONDecoding.parseISODate("2026-10-05T10:08:00Z"))
        #expect(BahnDeClient.journeyId(in: board, for: line, plannedDeparture: planned)?.contains("#ZE#3307#") == true)
        #expect(BahnDeClient.journeyNumber(in: board.entries[0].journeyId) == "3306")

        let url = BahnDeClient.boardURL(eva: "8010338", at: planned, products: BahnDeClient.regionalProducts).absoluteString
        #expect(url.contains("verkehrsmittel%5B%5D=REGIONAL") || url.contains("verkehrsmittel[]=REGIONAL"))
        #expect(!url.contains("EC_IC"))
    }

    /// Transitous' VBB names ("S Bernau Bhf") and missing EVA numbers don't match bahn.de's own
    /// ("Bernau(b Berlin)"), so the Zusatzhalt is placed by display name or coordinates instead of
    /// landing in front of the whole run.
    @Test func insertsRegionalZusatzhaltByPlace() throws {
        func stopover(_ name: String, _ lat: Double, _ lon: Double) -> Stopover {
            Stopover(station: Station(id: "de-DELFI_\(name)", name: name, coordinate: Coordinate(latitude: lat, longitude: lon),
                                      evaNumber: nil, source: .transitous),
                     arrival: nil, departure: nil, arrivalPlatform: nil, departurePlatform: nil, cancelled: false)
        }
        let existing = [
            stopover("Eberswalde, Hauptbahnhof", 52.8331, 13.7871),
            stopover("S Bernau Bhf", 52.6755, 13.5915),
            stopover("S+U Gesundbrunnen Bhf (Berlin)", 52.5486, 13.3887),
            stopover("S+U Berlin Hauptbahnhof", 52.5250, 13.3696),
        ]
        let stops = [
            JourneyStop(evaNumber: "8010334", name: "Eberswalde Hbf", coordinate: Coordinate(latitude: 52.8329, longitude: 13.7877)),
            JourneyStop(evaNumber: "8010338", name: "Bernau(b Berlin)", coordinate: Coordinate(latitude: 52.6757, longitude: 13.5920)),
            JourneyStop(evaNumber: "8010036", name: "Berlin-Lichtenberg", coordinate: Coordinate(latitude: 52.5100, longitude: 13.4967),
                        isAdditional: true),
            JourneyStop(evaNumber: "8011102", name: "Berlin Gesundbrunnen", coordinate: Coordinate(latitude: 52.5489, longitude: 13.3881)),
            JourneyStop(evaNumber: "8011160", name: "Berlin Hbf", coordinate: Coordinate(latitude: 52.5251, longitude: 13.3694)),
        ]

        let merged = BahnDeClient.inserting(stops, into: existing)

        #expect(merged.map(\.station.name) == ["Eberswalde, Hauptbahnhof", "S Bernau Bhf", "Berlin-Lichtenberg",
                                               "S+U Gesundbrunnen Bhf (Berlin)", "S+U Berlin Hauptbahnhof"])
        #expect(merged[2].isAdditional)
    }

    /// Transitous calls the ČD Railjet Hamburg–Dresden "ICE 171"; bahn.de's board has "RJ 171".
    @Test func findsJourneyIdByNumberWhenBrandsDiffer() throws {
        let json = #"{"entries": [{"journeyId": "rj", "zeit": "2026-09-30T05:34:00", "verkehrmittel": {"name": "RJ 171"}}]}"#
        let board = try JSONDecoding.decoder.decode(BahnDeClient.Board.self, from: Data(json.utf8))
        let line = Line(name: "ICE 171", number: "171", product: .highSpeed, operatorName: nil)
        let planned = try #require(JSONDecoding.parseISODate("2026-09-30T03:34:00Z"))
        #expect(BahnDeClient.journeyId(in: board, for: line, plannedDeparture: planned) == "rj")
    }

    @Test func takesTrainNamesFromBahnDeBoard() throws {
        let json = #"""
        {"entries": [
            {"journeyId": "a", "zeit": "2026-09-30T05:34:00", "verkehrmittel": {"name": "RJ 171"}},
            {"journeyId": "b", "zeit": "2026-09-30T05:45:00", "verkehrmittel": {"name": "ICE 515"}},
            {"journeyId": "c", "zeit": "2026-09-30T07:34:00", "verkehrmittel": {"name": "RJ 175"}}
        ]}
        """#
        let board = try JSONDecoding.decoder.decode(BahnDeClient.Board.self, from: Data(json.utf8)).entries
        let hamburg = station("8002549", "Hamburg Hbf")
        func departure(_ name: String, _ number: String, _ product: Product, _ utc: String) throws -> BoardEntry {
            BoardEntry(kind: .departures, tripId: name, station: hamburg,
                       line: Line(name: name, number: number, product: product, operatorName: nil),
                       otherEnd: "Dresden Hbf", time: TimeInfo(planned: try #require(JSONDecoding.parseISODate(utc)), actual: nil),
                       platform: PlatformInfo(planned: "13", actual: nil), cancelled: false,
                       terminatesOrOriginatesHere: false, remarks: [], source: .transitous)
        }
        let entries = [
            try departure("ICE 171", "171", .highSpeed, "2026-09-30T03:34:00Z"),
            try departure("ICE 515", "515", .highSpeed, "2026-09-30T03:45:00Z"),
            try departure("RE 5", "5", .regional, "2026-09-30T03:40:00Z"),
            // Same number as a bahn.de entry, but hours apart: a different run.
            try departure("ICE 175", "175", .highSpeed, "2026-09-30T03:50:00Z"),
        ]

        let corrected = BahnDeClient.correctingTrainNames(entries, using: board)

        #expect(corrected.map(\.line.name) == ["RJ 171", "ICE 515", "RE 5", "ICE 175"])
        #expect(corrected[0].line.alternateName == "ICE 171")
        #expect(corrected[0].line.number == "171")
        #expect(corrected[1] == entries[1])
    }

    /// DB's live time from bahn.de's board replaces Transitous' (DELFI's forecast had ICE 146 leave
    /// Berlin Hbf at 9:08, a minute early); trains without one there keep Transitous' time.
    @Test func takesLiveTimesFromBahnDeBoard() throws {
        let json = #"""
        {"entries": [
            {"journeyId": "a", "zeit": "2026-10-06T09:09:00", "ezZeit": "2026-10-06T09:12:00", "verkehrmittel": {"name": "ICE 146"}},
            {"journeyId": "b", "zeit": "2026-10-06T09:20:00", "verkehrmittel": {"name": "ICE 1005"}}
        ]}
        """#
        let board = try JSONDecoding.decoder.decode(BahnDeClient.Board.self, from: Data(json.utf8)).entries
        let berlin = station("8011160", "Berlin Hbf")
        func departure(_ name: String, _ number: String, planned: String, actual: String?) throws -> BoardEntry {
            BoardEntry(kind: .departures, tripId: name, station: berlin,
                       line: Line(name: name, number: number, product: .highSpeed, operatorName: nil),
                       otherEnd: "Amsterdam Centraal",
                       time: TimeInfo(planned: try #require(JSONDecoding.parseISODate(planned)),
                                      actual: actual.flatMap(JSONDecoding.parseISODate)),
                       platform: PlatformInfo(planned: "6", actual: nil), cancelled: false,
                       terminatesOrOriginatesHere: false, remarks: [], source: .transitous)
        }
        let entries = [
            try departure("ICE 146", "146", planned: "2026-10-06T07:09:00Z", actual: "2026-10-06T07:08:00Z"),
            try departure("ICE 1005", "1005", planned: "2026-10-06T07:20:00Z", actual: "2026-10-06T07:25:00Z"),
            try departure("ICE 148", "148", planned: "2026-10-06T07:30:00Z", actual: nil),
        ]

        let corrected = BahnDeClient.applyingLiveTimes(entries, using: board)

        #expect(corrected[0].time.actual == JSONDecoding.parseISODate("2026-10-06T07:12:00Z"))
        #expect(corrected[1] == entries[1])
        #expect(corrected[2] == entries[2])
        // Regional and S-Bahn trains by their run number, which bahn.de's journey ID carries; a line
        // name alone only at the same minute and when just one entry has it.
        let localJSON = #"""
        {"entries": [
            {"journeyId": "2|#VN#1#ST#1#PI#0#ZI#1#TA#0#DA#61025#1S#1#1T#1#LS#1#LT#1#PU#80#RT#1#CA#RE#ZE#3148#ZB#RE 4#PC#3#FR#1#FT#1#TO#1#TT#1#", "zeit": "2026-10-06T09:09:00", "ezZeit": "2026-10-06T09:11:00", "verkehrmittel": {"name": "RE 4", "produktGattung": "REGIONAL"}},
            {"journeyId": "2|#CA#S#ZE#5540#ZB#S 5#", "zeit": "2026-10-06T09:11:00", "ezZeit": "2026-10-06T09:13:00", "verkehrmittel": {"name": "S 5", "produktGattung": "SBAHN"}},
            {"journeyId": "x", "zeit": "2026-10-06T09:09:00", "ezZeit": "2026-10-06T09:30:00", "verkehrmittel": {"name": "S 9", "produktGattung": "SBAHN"}},
            {"journeyId": "y", "zeit": "2026-10-06T09:09:00", "ezZeit": "2026-10-06T09:40:00", "verkehrmittel": {"name": "S 9", "produktGattung": "SBAHN"}}
        ]}
        """#
        let localBoard = try JSONDecoding.decoder.decode(BahnDeClient.Board.self, from: Data(localJSON.utf8)).entries
        func local(_ name: String, _ product: Product, run: String?, planned: String) throws -> BoardEntry {
            var entry = try departure(name, "", planned: planned, actual: planned)
            entry.line = Line(name: name, number: nil, product: product, operatorName: nil, tripNumber: run)
            return entry
        }
        let locals = [
            try local("RE4", .regionalExpress, run: "3148", planned: "2026-10-06T07:09:00Z"),
            try local("S5", .suburban, run: "5540", planned: "2026-10-06T07:11:00Z"),
            // Another S5 run at the same minute: not this entry.
            try local("S5", .suburban, run: "5541", planned: "2026-10-06T07:11:00Z"),
            // Two S 9 at that minute on bahn.de, no run number: ambiguous, unchanged.
            try local("S9", .suburban, run: nil, planned: "2026-10-06T07:09:00Z"),
        ]
        let localCorrected = BahnDeClient.applyingLiveTimes(locals, using: localBoard)
        #expect(localCorrected[0].time.actual == JSONDecoding.parseISODate("2026-10-06T07:11:00Z"))
        #expect(localCorrected[1].time.actual == JSONDecoding.parseISODate("2026-10-06T07:13:00Z"))
        #expect(localCorrected[2] == locals[2])
        #expect(localCorrected[3] == locals[3])
        // Long-distance trains of other brands (NJ, FLX) by name and minute, never from a regional entry.
        let otherJSON = #"""
        {"entries": [
            {"journeyId": "nj", "zeit": "2026-10-06T09:09:00", "ezZeit": "2026-10-06T09:19:00", "verkehrmittel": {"name": "NJ 40491", "produktGattung": "EC_IC"}},
            {"journeyId": "rb", "zeit": "2026-10-06T09:09:00", "ezZeit": "2026-10-06T09:30:00", "verkehrmittel": {"name": "NJ 40491", "produktGattung": "REGIONAL"}}
        ]}
        """#
        let otherBoard = try JSONDecoding.decoder.decode(BahnDeClient.Board.self, from: Data(otherJSON.utf8)).entries
        let nightjet = try local("NJ 40491", .longDistance, run: nil, planned: "2026-10-06T07:09:00Z")
        #expect(BahnDeClient.applyingLiveTimes([nightjet], using: otherBoard).first?.time.actual
                == JSONDecoding.parseISODate("2026-10-06T07:19:00Z"))
        // Subway, tram and bus are never looked up.
        let tram = try local("M5", .tram, run: nil, planned: "2026-10-06T07:09:00Z")
        #expect(!BahnDeClient.isLookedUp(tram.line))
        #expect(BahnDeClient.isLookedUp(nightjet.line))
        // A long-distance train never takes a regional entry's time, even with the same number.
        let ice4 = try departure("ICE 4", "4", planned: "2026-10-06T07:09:00Z", actual: nil)
        #expect(BahnDeClient.applyingLiveTimes([ice4], using: localBoard) == [ice4])

        // A departures board never touches arrivals.
        var arrival = entries[0]
        arrival.kind = .arrivals
        #expect(BahnDeClient.applyingLiveTimes([arrival], using: board) == [arrival])
    }

    /// Arrivals are matched against bahn.de's arrivals board, by arrival time.
    @Test func takesTrainNamesFromBahnDeArrivalsBoard() throws {
        let json = #"{"entries": [{"journeyId": "a", "zeit": "2026-09-30T09:07:00", "verkehrmittel": {"name": "RJ 171"}}]}"#
        let board = try JSONDecoding.decoder.decode(BahnDeClient.Board.self, from: Data(json.utf8)).entries
        let arrival = BoardEntry(kind: .arrivals, tripId: "ice-171", station: station("8010085", "Dresden Hbf"),
                                 line: Line(name: "ICE 171", number: "171", product: .highSpeed, operatorName: nil),
                                 otherEnd: "Hamburg Hbf", time: TimeInfo(planned: try #require(JSONDecoding.parseISODate("2026-09-30T07:07:00Z")), actual: nil),
                                 platform: PlatformInfo(planned: "9", actual: nil), cancelled: false,
                                 terminatesOrOriginatesHere: true, remarks: [], source: .transitous)

        #expect(BahnDeClient.correctingTrainNames([arrival], using: board, kind: .arrivals).map(\.line.name) == ["RJ 171"])
        // A departures board never renames arrivals.
        #expect(BahnDeClient.correctingTrainNames([arrival], using: board).map(\.line.name) == ["ICE 171"])

        let departure = try #require(JSONDecoding.parseISODate("2026-09-30T07:07:00Z"))
        #expect(BahnDeClient.boardURL(eva: "8010085", at: departure, kind: .arrivals).path().hasSuffix("/reiseloesung/ankuenfte"))
    }

    /// Journey search legs get bahn.de's name too, from its board at the leg's origin.
    @Test func takesTrainNamesFromBahnDeBoardForJourneyLegs() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HamburgBoardProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let bahnDe = BahnDeClient(http: HTTPClient(session: session), gate: BahnDeGate())

        let departure = try #require(JSONDecoding.parseISODate("2026-09-30T03:34:00Z"))
        func leg(_ name: String, _ number: String, product: Product = .highSpeed) -> Leg {
            Leg(origin: station("8002549", "Hamburg Hbf"), destination: station("8010085", "Dresden Hbf"),
                departure: TimeInfo(planned: departure, actual: nil),
                arrival: TimeInfo(planned: departure.addingTimeInterval(4 * 3600), actual: nil),
                departurePlatform: nil, arrivalPlatform: nil, tripId: name,
                line: Line(name: name, number: number, product: product, operatorName: nil),
                direction: "Dresden Hbf", isWalking: false, cancelled: false, stopovers: [], remarks: [],
                source: .transitous)
        }
        let journeys = [Journey(legs: [leg("ICE 171", "171")], source: .transitous),
                        Journey(legs: [leg("RE 5", "5", product: .regional)], source: .transitous)]

        let corrected = await bahnDe.correctingTrainNames(in: journeys)

        #expect(corrected[0].legs[0].line?.name == "RJ 171")
        #expect(corrected[0].legs[0].line?.alternateName == "ICE 171")
        #expect(corrected[1] == journeys[1])
    }

    @Test func requestURLs() throws {
        let journey = BahnDeClient.journeyURL("2|#VN#1#ST#1759#PI#0#ZI#1#TA#0#DA#290926#").absoluteString
        #expect(journey == "https://betterbahn2.betterbahn.workers.dev/web/api/reiseloesung/fahrt?journeyId=2%7C%23VN%231%23ST%231759%23PI%230%23ZI%231%23TA%230%23DA%23290926%23&poly=false")

        let departure = try #require(JSONDecoding.parseISODate("2026-09-29T12:30:00Z"))
        let board = try #require(URLComponents(url: BahnDeClient.boardURL(eva: "8000105", at: departure), resolvingAgainstBaseURL: false))
        let items = board.queryItems ?? []
        #expect(items.first { $0.name == "datum" }?.value == "2026-09-29")
        #expect(items.first { $0.name == "zeit" }?.value == "14:29:00")
        #expect(items.first { $0.name == "ortExtId" }?.value == "8000105")
        #expect(items.filter { $0.name == "verkehrsmittel[]" }.map(\.value) == ["ICE", "EC_IC"])
    }
}

@Suite struct BahnJetztTests {
    static let list = #"""
    [
      {"journeyId": "20260929-65771c12", "position": [9.1162, 48.7455], "speed": null, "name": "RE14a",
       "details": {"origin": {"evaNumber": "8000096", "name": "Stuttgart Hbf"}, "destination": {"evaNumber": "8000322", "name": "Rottweil"},
                   "transportAtStart": {"type": "REGIONAL_TRAIN", "journeyName": "RE14a", "journeyNumber": 17677, "category": "RE", "label": ""}}},
      {"journeyId": "20260928-aaaa", "position": [11.0, 50.0], "speed": 120.0, "name": "ICE 693",
       "details": {"transportAtStart": {"type": "HIGH_SPEED_TRAIN", "journeyName": "ICE 693", "journeyNumber": 693, "category": "ICE"}}},
      {"journeyId": "20260929-bbbb", "position": [8.6632, 50.1068], "speed": 243.5, "name": "ICE 693",
       "details": {"transportAtStart": {"type": "HIGH_SPEED_TRAIN", "journeyName": "ICE 693", "journeyNumber": 693, "category": "ICE"}}}
    ]
    """#

    @Test func matchesByNumberAndPrefersTheLegsDay() throws {
        let journeys = try JSONDecoding.decoder.decode([BahnJetztClient.Journey].self, from: Data(Self.list.utf8))
        let departure = try #require(JSONDecoding.parseISODate("2026-09-29T10:00:00Z"))
        #expect(BahnJetztClient.match(category: "ICE", number: 693, departure: departure, in: journeys)?.journeyId == "20260929-bbbb")
        #expect(BahnJetztClient.match(category: "IC", number: 693, departure: departure, in: journeys) == nil)
        // Just after midnight, yesterday's run still underway is the one.
        let earlyNextDay = try #require(JSONDecoding.parseISODate("2026-09-29T22:30:00Z"))
        #expect(BahnJetztClient.match(category: "ICE", number: 693, departure: earlyNextDay, in: journeys)?.journeyId == "20260929-bbbb")
    }

    /// Regional trains by their run number; RE vs. RB doesn't matter, but a long-distance train with
    /// the same number never counts.
    @Test func matchesRegionalTrainsByRunNumber() throws {
        let journeys = try JSONDecoding.decoder.decode([BahnJetztClient.Journey].self, from: Data(Self.list.utf8))
        let departure = try #require(JSONDecoding.parseISODate("2026-09-29T10:00:00Z"))
        let re = Line(name: "RE 14a", number: "14", product: .regionalExpress, operatorName: nil, tripNumber: "17677")
        let ref = try #require(BahnJetztClient.reference(for: re))
        #expect(ref.category == "RE" && ref.number == "17677")
        #expect(BahnJetztClient.match(category: "RB", number: 17677, departure: departure, in: journeys)?.journeyId == "20260929-65771c12")
        #expect(BahnJetztClient.match(category: "RB", number: 693, departure: departure, in: journeys) == nil)
        // Without a run number the line number would match some other train.
        #expect(!BahnJetztClient.supports(Line(name: "RE 14a", number: "14", product: .regionalExpress, operatorName: nil)))
        #expect(BahnJetztClient.supports(Line(name: "S 1", number: "1", product: .suburban, operatorName: nil, tripNumber: "7746")))
        #expect(!BahnJetztClient.supports(Line(name: "U 2", number: "2", product: .subway, operatorName: nil, tripNumber: "12")))
    }

    /// A regional run number can belong to a train in another country: the match must head for the
    /// same destination or be near the route.
    @Test func regionalMatchMustFitTheRoute() throws {
        let json = #"""
        {"journeyId": "20260930-x", "position": [8.54, 47.37], "name": "RB 19170",
         "details": {"destination": {"evaNumber": "8000096", "name": "Stuttgart Hbf"},
                     "transportAtStart": {"category": "RB", "journeyNumber": 19170}}}
        """#
        let journey = try JSONDecoding.decoder.decode(BahnJetztClient.Journey.self, from: Data(json.utf8))
        let here = Coordinate(latitude: 48.70, longitude: 9.10)
        // Zürich S11 to Aarau, around Zürich: neither destination nor route fits a train near Stuttgart.
        let zurich = BahnJetztClient.RouteHint(destination: "Aarau", path: [Coordinate(latitude: 47.378, longitude: 8.540),
                                                                          Coordinate(latitude: 47.392, longitude: 8.051)])
        #expect(!BahnJetztClient.isPlausible(journey, at: here, for: zurich))
        // Same destination (spelled as Transitous does), even far from the leg.
        #expect(BahnJetztClient.isPlausible(journey, at: here, for: .init(destination: "Stuttgart Hauptbahnhof", path: zurich.path)))
        // Close to the route between two stops 60 km apart.
        let route = [Coordinate(latitude: 48.40, longitude: 9.10), Coordinate(latitude: 48.94, longitude: 9.10)]
        #expect(BahnJetztClient.isPlausible(journey, at: here, for: .init(destination: "Heilbronn Hbf", path: route)))
        #expect(try #require(BahnJetztClient.distance(from: here, to: route)) < 100)
    }

    @Test func positionFromSharedList() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [BahnJetztListProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let client = BahnJetztClient(http: HTTPClient(session: session), state: BahnJetztClient.State())
        let departure = try #require(JSONDecoding.parseISODate("2026-09-29T10:00:00Z"))
        let leg = Leg(origin: station("8000105", "Frankfurt (Main) Hbf"), destination: station("8000261", "München Hbf"),
                      departure: TimeInfo(planned: departure, actual: nil), arrival: TimeInfo(planned: departure.addingTimeInterval(14_400), actual: nil),
                      departurePlatform: nil, arrivalPlatform: nil, tripId: nil,
                      line: Line(name: "ICE 693", number: "693", product: .highSpeed, operatorName: nil),
                      direction: nil, isWalking: false, cancelled: false, stopovers: [], remarks: [], source: .transitous)

        let position = try #require(try await client.position(for: leg))
        #expect(position.coordinate == Coordinate(latitude: 50.1068, longitude: 8.6632))
        #expect(position.speedKmh == 243.5)
        #expect(position.source == "bahn.jetzt")
        // A second leg in the same refresh reuses the list instead of fetching it again.
        _ = try await client.position(for: leg)
        #expect(BahnJetztListProtocol.requests.withLock { $0 } == 1)
        #expect(BahnJetztListProtocol.userAgent.withLock { $0 } == HTTPClient.identifyingUserAgent)
    }

    @Test func userAgentNamesVersionAndContact() {
        #expect(HTTPClient.userAgent(version: "1.2") == "BetterBahn/1.2 (iOS; +https://betterbahn.betterbahn.workers.dev/support)")
        #expect(HTTPClient.identifyingUserAgent.hasPrefix("BetterBahn/"))
        #expect(HTTPClient.identifyingUserAgent.contains(HTTPClient.contactURL))
    }

    @Test func staleness() {
        let position = TrainPosition(coordinate: .init(latitude: 50, longitude: 8), time: .now, speedKmh: nil, source: nil)
        #expect(!position.isStale(now: position.time.addingTimeInterval(30)))
        #expect(position.isStale(now: position.time.addingTimeInterval(300)))
    }
}

/// Answers `/v5/trip` with the Köln–Duisburg ICE leg that has its `legGeometry`.
private final class TripGeometryProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = Bundle.module.url(forResource: "transitous-leg-geometry", withExtension: "json", subdirectory: "Fixtures")!
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: (try? Data(contentsOf: url)) ?? Data())
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class BahnJetztListProtocol: URLProtocol, @unchecked Sendable {
    static let requests = Mutex(0)
    static let userAgent = Mutex<String?>(nil)
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.withLock { $0 += 1 }
        Self.userAgent.withLock { $0 = request.value(forHTTPHeaderField: "User-Agent") }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(BahnJetztTests.list.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
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

    /// A train opened from the board (not a journey) keeps its track geometry, so its live map
    /// follows the tracks instead of joining the stops with straight lines.
    @Test func transitousTripHasTrackGeometry() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [TripGeometryProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let provider = TransitousProvider(http: HTTPClient(session: session))

        let trip = try await provider.trip(id: "ice")

        let geometry = try #require(trip.geometry)
        #expect(geometry.count > 50)
        let decoded = try JSONDecoder().decode(Trip.self, from: JSONEncoder().encode(trip))
        #expect(decoded.geometry == geometry)
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

    @Test func issuesUseDisplayNames() {
        let hbf = "S+U Berlin Hauptbahnhof"
        let journey = Journey(legs: [leg("RE 3", "A", hbf, dep: 0, arr: 60, arrDelay: 15), leg("ICE 2", hbf, "C", dep: 70, arr: 120)],
                              source: .bahnDe)
        #expect(journey.connectionIssues().first?.title == "Umstieg in Berlin Hbf klappt nicht mehr")
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

    /// A search result looked fine when found; the live data loaded afterwards shows ICE 1 now 15
    /// minutes late, so the 10-minute transfer to ICE 2 no longer works.
    @Test func refreshingEndsFindsAMissedTransfer() async {
        func stop(_ name: String, _ minute: Double, delay: Double) -> Stopover {
            let time = TimeInfo(planned: base.addingTimeInterval(minute * 60), actual: base.addingTimeInterval((minute + delay) * 60))
            return Stopover(station: station(name, name), arrival: time, departure: time,
                            arrivalPlatform: nil, departurePlatform: nil, cancelled: false)
        }
        let mock = MockProvider(source: .bahnDe)
        mock.trips["ICE 1"] = Trip(id: "ICE 1", line: nil, direction: nil,
                                   stopovers: [stop("A", 0, delay: 15), stop("B", 60, delay: 15)],
                                   cancelled: false, remarks: [], source: .bahnDe)
        let found = Journey(legs: [leg("ICE 1", "A", "B", dep: 0, arr: 60), leg("ICE 2", "B", "C", dep: 70, arr: 120)], source: .bahnDe)
        #expect(found.connectionIssues().isEmpty)
        let refresher = JourneyRefresher(provider: CombinedProvider(primary: mock, fallback: nil, bahnDe: nil))

        let live = await refresher.refreshEnds(found, now: base)

        #expect(live.id == found.id)
        #expect(live.legs[0].arrival.actual == base.addingTimeInterval(75 * 60))
        #expect(live.connectionIssues().first?.title == "Umstieg in B klappt nicht mehr")
        #expect(live.connectionIssues().first?.isBlocking == true)

        // Meanwhile the results got ICE 2's platform from DB; the live version keeps it.
        var filled = found
        filled.legs[1].departurePlatform = PlatformInfo(planned: "7", actual: nil)
        #expect(JourneyRefresher.keepingPlatforms(of: filled, in: live).legs[1].departurePlatform?.best == "7")
    }

    @Test func onlyResultsStartingSoonAndNotOverAreCheckedLive() {
        let journey = Journey(legs: [leg("ICE 1", "A", "B", dep: 0, arr: 60), leg("ICE 2", "B", "C", dep: 70, arr: 120)], source: .bahnDe)
        #expect(JourneyRefresher.isWorthLiveCheck(journey, now: base.addingTimeInterval(-11 * 3600)))
        #expect(JourneyRefresher.isWorthLiveCheck(journey, now: base.addingTimeInterval(90 * 60)))
        #expect(!JourneyRefresher.isWorthLiveCheck(journey, now: base.addingTimeInterval(-13 * 3600)))
        #expect(!JourneyRefresher.isWorthLiveCheck(journey, now: base.addingTimeInterval(121 * 60)))
    }

    @Test func refreshOnRingLinePicksTheVisitAtTheSavedTime() {
        // S41 passes Gesundbrunnen and Wedding every hour on the same trip; the saved 9:41 ride must
        // not be moved to the trip's first 6:41 pass when refreshed.
        func stop(_ name: String, _ minute: Double) -> Stopover {
            let time = TimeInfo(planned: base.addingTimeInterval(minute * 60), actual: base.addingTimeInterval((minute + 2) * 60))
            return Stopover(station: station(name, name), arrival: time, departure: time,
                            arrivalPlatform: nil, departurePlatform: nil, cancelled: false)
        }
        let laps = [0.0, 60, 120, 180, 240]
        let trip = Trip(id: "S41", line: nil, direction: nil,
                        stopovers: laps.flatMap { [stop("Gesundbrunnen", $0), stop("Wedding", $0 + 2)] },
                        cancelled: false, remarks: [], source: .bahnDe)
        let saved = leg("S41", "Gesundbrunnen", "Wedding", dep: 180, arr: 182)
        let refreshed = JourneyRefresher.apply(trip, to: saved)
        #expect(refreshed.departure.planned == saved.departure.planned)
        #expect(refreshed.arrival.planned == saved.arrival.planned)
        #expect(refreshed.departure.actual == base.addingTimeInterval(182 * 60))

        let fromTripView = trip.leg(fromIndex: 6, toIndex: 7)
        #expect(fromTripView?.departure.planned == saved.departure.planned)
        #expect(fromTripView?.arrival.planned == saved.arrival.planned)
    }

    /// Issue #68: a Berlin–Amsterdam ICE's journey leg names only where the German feed stops
    /// modelling it ("Hengelo"); the trip runs through to Amsterdam, and the refresh adopts that.
    @Test func refreshTakesTheDirectionOfTheWholeTrip() {
        func stop(_ name: String, _ minute: Double) -> Stopover {
            let time = TimeInfo(planned: base.addingTimeInterval(minute * 60), actual: nil)
            return Stopover(station: station(name, name), arrival: time, departure: time,
                            arrivalPlatform: nil, departurePlatform: nil, cancelled: false)
        }
        let trip = Trip(id: "ICE 144", line: nil, direction: "Amsterdam Centraal",
                        stopovers: [stop("Berlin", 0), stop("Osnabrück", 180), stop("Hengelo", 240), stop("Amsterdam Centraal", 360)],
                        cancelled: false, remarks: [], source: .bahnDe)
        var saved = leg("ICE 144", "Berlin", "Osnabrück", dep: 0, arr: 180)
        saved.direction = "Hengelo"
        #expect(JourneyRefresher.apply(trip, to: saved).direction == "Amsterdam Centraal")

        // A trip cut short at the border doesn't reach a leg merged across it: keep the leg's direction.
        let cutShort = Trip(id: "ICE 144", line: nil, direction: "Hengelo",
                            stopovers: [stop("Berlin", 0), stop("Hengelo", 240)], cancelled: false, remarks: [], source: .bahnDe)
        var merged = leg("ICE 144", "Berlin", "Amsterdam Centraal", dep: 0, arr: 360)
        merged.direction = "Amsterdam Centraal"
        #expect(JourneyRefresher.apply(cutShort, to: merged).direction == "Amsterdam Centraal")
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

/// Expert option "Nur Ein-/Ausstieg ignorieren": a train you may not board at the origin that ends
/// short of the destination, continued from where it stops (ICE 204 Harburg → Hamburg Hbf, RJ 177 on).
@Suite struct RestrictedTrainContinuationTests {
    let harburg = station("8000147", "Hamburg-Harburg", 53.456, 9.992)
    let hbf = station("8002549", "Hamburg Hbf", 53.553, 10.007)
    let altona = station("8002553", "Hamburg-Altona", 53.552, 9.935)
    let berlin = station("8011160", "Berlin Hbf", 52.525, 13.369)
    let base = Date(timeIntervalSince1970: 1_800_000_000)

    func time(_ minutes: Double) -> TimeInfo { TimeInfo(planned: base.addingTimeInterval(minutes * 60), actual: nil) }

    func trip(_ id: String, _ name: String, _ stops: [Stopover]) -> Trip {
        Trip(id: id, line: Line(name: name, number: String(name.split(separator: " ").last!), product: .highSpeed,
                                operatorName: nil),
             direction: stops.last?.station.name, stopovers: stops, cancelled: false, remarks: [], source: .bahnDe)
    }

    @Test func ridesRestrictedTrainAndContinues() async throws {
        let ice204 = trip("ice204", "ICE 204", [
            Stopover(station: harburg, arrival: time(-2), departure: time(0), arrivalPlatform: nil, departurePlatform: nil,
                     cancelled: false, access: .exitOnly),
            Stopover(station: hbf, arrival: time(11), departure: time(14), arrivalPlatform: nil, departurePlatform: nil, cancelled: false),
            Stopover(station: altona, arrival: time(22), departure: nil, arrivalPlatform: nil, departurePlatform: nil, cancelled: false),
        ])
        let rj177 = trip("rj177", "RJ 177", [
            Stopover(station: hbf, arrival: nil, departure: time(28), arrivalPlatform: nil, departurePlatform: nil, cancelled: false),
            Stopover(station: berlin, arrival: time(139), departure: nil, arrivalPlatform: nil, departurePlatform: nil, cancelled: false),
        ])
        let slower = trip("ice801", "ICE 801", [
            Stopover(station: hbf, arrival: nil, departure: time(47), arrivalPlatform: nil, departurePlatform: nil, cancelled: false),
            Stopover(station: berlin, arrival: time(167), departure: nil, arrivalPlatform: nil, departurePlatform: nil, cancelled: false),
        ])
        let mock = RoutingMockProvider()
        mock.trips["ice204"] = ice204
        mock.routes["\(hbf.name) -> \(berlin.name)"] = [Journey(legs: [slower.leg(from: hbf, to: berlin)!], source: .bahnDe),
                                                         Journey(legs: [rj177.leg(from: hbf, to: berlin)!], source: .bahnDe)]
        let entry = BoardEntry(kind: .departures, tripId: "ice204", station: harburg, line: ice204.line!, otherEnd: altona.name,
                               time: time(0), platform: PlatformInfo(planned: "2", actual: nil), cancelled: false,
                               terminatesOrOriginatesHere: false, remarks: [], access: .exitOnly, source: .bahnDe)
        let calls = StationCalls(departuresAtOrigin: [entry], departuresAtDestination: [], arrivalsAtDestination: [])
        let picker = TrainPicker(provider: CombinedProvider(primary: mock, bahnDe: nil, bahnExpert: nil, vagonweb: nil, bahnJetzt: nil))

        let journeys = await picker.journeysContinuingFromRestrictedTrains(
            JourneyQuery(from: harburg, to: berlin, date: base), calls: calls, end: base.addingTimeInterval(3600), maxAlightStops: 1)
        let best = try #require(journeys.first)
        #expect(journeys.count == 1)
        #expect(best.transitLegs.map { $0.line?.name } == ["ICE 204", "RJ 177"])
        #expect(best.transitLegs.first?.breaksBoardingRules == true)
        #expect(best.arrival?.planned == time(139).planned)
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
        let timetables = TimetablesClient(http: HTTPClient(session: session))
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
        let client = TimetablesClient(http: HTTPClient(session: session))
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

    /// DB lists only changes, so a scheduled stop without one is on time, once the train is about to run.
    @Test func unchangedTrainAboutToRunIsOnTime() async throws {
        let (timetables, session) = client(UnchangedS15Protocol.self)
        defer { session.invalidateAndCancel() }

        let override = await timetables.realtime(for: leg(departurePlatform: nil), now: departure.addingTimeInterval(-600))

        #expect(override?.departure?.actual == departure)
        #expect(override?.departure?.delayMinutes == 0)
    }

    /// A journey tomorrow: DB has the schedule but nothing live yet, so no made-up "pünktlich".
    @Test func unchangedTrainTomorrowHasNoLiveTime() async throws {
        let (timetables, session) = client(UnchangedS15Protocol.self)
        defer { session.invalidateAndCancel() }

        let override = await timetables.realtime(for: leg(departurePlatform: nil), now: departure.addingTimeInterval(-86_400))

        #expect(override?.departure?.actual == nil)
        #expect(override?.departure?.delayMinutes == nil)
        #expect(override?.departurePlatform?.planned == "12")
    }

    /// Saved journeys keep an earlier refresh's made-up "on time" until the train is close.
    @Test func refreshDropsInferredOnTimeForTrainsHoursAhead() {
        var saved = leg(departurePlatform: nil)
        saved.departure.actual = departure
        saved.arrival.actual = departure.addingTimeInterval(720)
        saved.stopovers = [Stopover(station: berlinHbf, arrival: nil, departure: TimeInfo(planned: departure, actual: departure),
                                    arrivalPlatform: nil, departurePlatform: nil, cancelled: false)]

        let tomorrow = JourneyRefresher.droppingInferredOnTime(saved, now: departure.addingTimeInterval(-86_400))
        #expect(tomorrow.departure.actual == nil)
        #expect(tomorrow.arrival.actual == departure.addingTimeInterval(720))
        #expect(tomorrow.stopovers[0].departure?.actual == nil)

        let soon = JourneyRefresher.droppingInferredOnTime(saved, now: departure.addingTimeInterval(-600))
        #expect(soon == saved)
    }
}

/// Issue #76, for a station not in `lowerLevels`: station search only finds "Hamburg-Altona" (8002553),
/// whose `plan` has none of the S-Bahn; DB lists those under "Hamburg-Altona(S)" (8098553), named in
/// 8002553's `/station` `meta` (real data from 2026-10-02).
@Suite struct TimetablesOtherLevelTests {
    let dammtor = station("8002548", "Hamburg Dammtor", 53.560, 9.990, source: .bahnDe)
    let altona = station("8002553", "Hamburg-Altona", 53.552, 9.935, source: .bahnDe)
    // 2027-01-15 08:00 UTC == 09:00 Europe/Berlin (CET) -> IRIS "2701150900".
    let departure = Date(timeIntervalSince1970: 1_800_000_000)

    var leg: Leg {
        Leg(origin: dammtor, destination: altona,
            departure: TimeInfo(planned: departure, actual: nil),
            arrival: TimeInfo(planned: departure.addingTimeInterval(180), actual: departure.addingTimeInterval(180)),
            departurePlatform: nil, arrivalPlatform: nil, tripId: "s7",
            line: Line(name: "S7", number: "7", product: .suburban, operatorName: nil, tripNumber: "47137"),
            direction: "Altona", isWalking: false, cancelled: false, stopovers: [], remarks: [],
            source: .transitous)
    }

    @Test func findsTheSBahnAtTheStationsOtherLevel() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HamburgSBahnLevelProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let timetables = TimetablesClient(http: HTTPClient(session: session))

        let override = try #require(await timetables.realtime(for: leg))

        #expect(override.arrival?.actual == departure.addingTimeInterval(360))
        #expect(override.arrivalPlatform == PlatformInfo(planned: "4", actual: nil))
        #expect(override.departure?.actual == departure.addingTimeInterval(180))
        let requested = HamburgSBahnLevelProtocol.requestedPaths.withLock { $0 }
        // Bus stops and other non-EVA ids in `meta` are never asked for.
        #expect(!requested.contains { $0.contains("140269") || $0.contains("692757") })
    }
}

private final class HamburgSBahnLevelProtocol: URLProtocol, @unchecked Sendable {
    static let requestedPaths = Mutex<[String]>([])

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let path = request.url!.path
        Self.requestedPaths.withLock { $0.append(path) }
        let body = switch path {
        case _ where path.hasSuffix("plan/8002548/270115/09"):
            #"<timetable station='Hamburg Dammtor'><s id="d"><tl c="S" n="47137"/><ar pt="2701150859"/><dp pt="2701150900" pp="3"/></s></timetable>"#
        case _ where path.hasSuffix("fchg/8002548"):
            #"<timetable station='Hamburg Dammtor'><s id="d" eva="8002548"><ar ct="2701150902"/><dp ct="2701150903"/></s></timetable>"#
        case _ where path.hasSuffix("plan/8002553/270115/09"):
            #"<timetable station='Hamburg-Altona'><s id="re"><tl c="RE" n="21007"/><ar pt="2701150903" pp="9"/></s></timetable>"#
        case _ where path.hasSuffix("station/8002553"):
            #"<stations><station meta="140269|210426|510421|692757|8098553" name="Hamburg-Altona" eva="8002553"/></stations>"#
        case _ where path.hasSuffix("plan/8098553/270115/09"):
            #"<timetable station='Hamburg-Altona(S)'><s id="a"><tl c="S" n="47137"/><ar pt="2701150903" pp="4"/></s></timetable>"#
        case _ where path.hasSuffix("fchg/8098553"):
            #"<timetable station='Hamburg-Altona(S)'><s id="a" eva="8098553"><ar ct="2701150906"/></s></timetable>"#
        default:
            "<timetable></timetable>"
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

/// Issue #76 as seen in a saved journey: S7 Bergedorf 12:58 → Hamburg Hbf 13:19 running 3 minutes late.
/// Transitous had no realtime for it (its stops then carry the plan as "actual"), so only DB's
/// Timetables can tell, and the refreshed leg must end with DB's +3 like the trip view does.
@Suite(.serialized) struct JourneyRefresherSBahnLevelTests {
    @Test func refreshedLegEndsWithDBsDelayAtTheSBahnLevel() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [BergedorfS7Protocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let timetables = TimetablesClient(http: HTTPClient(session: session))

        let bergedorf = station("8000148", "Hamburg-Bergedorf", 53.490, 10.206, source: .bahnDe)
        let hauptbahnhof = station("8002549", "Hamburg Hbf", 53.553, 10.007, source: .bahnDe)
        let departure = try #require(ISO8601DateFormatter().date(from: "2026-10-02T10:58:00Z"))
        let arrival = departure.addingTimeInterval(21 * 60)
        let line = Line(name: "S7", number: "7", product: .suburban, operatorName: nil, tripNumber: "47124")
        let stops = [
            Stopover(station: bergedorf, arrival: TimeInfo(planned: departure.addingTimeInterval(-60), actual: departure.addingTimeInterval(-60)),
                     departure: TimeInfo(planned: departure, actual: departure), arrivalPlatform: nil, departurePlatform: nil, cancelled: false),
            Stopover(station: hauptbahnhof, arrival: TimeInfo(planned: arrival, actual: arrival),
                     departure: TimeInfo(planned: arrival.addingTimeInterval(60), actual: arrival.addingTimeInterval(60)),
                     arrivalPlatform: nil, departurePlatform: nil, cancelled: false),
        ]
        let mock = MockProvider(source: .transitous)
        mock.trips["s7"] = Trip(id: "s7", line: line, direction: "Altona", stopovers: stops, cancelled: false, remarks: [], source: .transitous)
        let leg = Leg(origin: bergedorf, destination: hauptbahnhof,
                      departure: TimeInfo(planned: departure, actual: nil), arrival: TimeInfo(planned: arrival, actual: nil),
                      departurePlatform: nil, arrivalPlatform: nil, tripId: "s7", line: line, direction: "Altona",
                      isWalking: false, cancelled: false, stopovers: stops, remarks: [], source: .transitous)
        let refresher = JourneyRefresher(provider: CombinedProvider(primary: mock, fallback: nil, bahnDe: nil), timetables: timetables)

        let refreshed = await refresher.refresh(Journey(legs: [leg], source: .transitous), now: departure)

        #expect(refreshed.legs[0].departure.actual == departure.addingTimeInterval(180))
        #expect(refreshed.legs[0].arrival.actual == arrival.addingTimeInterval(180))
        #expect(refreshed.legs[0].stopovers.last?.arrival?.actual == arrival.addingTimeInterval(180))
    }

    /// The first request for Hamburg Hbf's (large) `fchg` fails, as a timeout would; the stops'
    /// lookup right after gets through. The leg's end must still show DB's +3, not Transitous' "+0".
    @Test func legEndKeepsTheStopsDelayWhenItsOwnLookupFailed() async throws {
        BergedorfS7Protocol.failHbfChangesOnce.withLock { $0 = true }
        defer { BergedorfS7Protocol.failHbfChangesOnce.withLock { $0 = false } }
        try await refreshedLegEndsWithDBsDelayAtTheSBahnLevel()
    }

    /// Hours after the ride neither source has live data any more: Transitous sends the bare schedule
    /// and DB has dropped the train from `fchg`. The delay saved while it ran must stay, not become "+0".
    @Test func finishedLegKeepsItsDelayOnceLiveDataIsGone() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [BergedorfS7Protocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let timetables = TimetablesClient(http: HTTPClient(session: session))

        let bergedorf = station("8000148", "Hamburg-Bergedorf", 53.490, 10.206, source: .bahnDe)
        let hauptbahnhof = station("8002549", "Hamburg Hbf", 53.553, 10.007, source: .bahnDe)
        let departure = try #require(ISO8601DateFormatter().date(from: "2026-10-02T10:58:00Z"))
        let arrival = departure.addingTimeInterval(21 * 60)
        let line = Line(name: "S7", number: "7", product: .suburban, operatorName: nil, tripNumber: "47124")
        let scheduled = [
            Stopover(station: bergedorf, arrival: nil, departure: TimeInfo(planned: departure, actual: nil),
                     arrivalPlatform: nil, departurePlatform: nil, cancelled: false),
            Stopover(station: hauptbahnhof, arrival: TimeInfo(planned: arrival, actual: nil), departure: nil,
                     arrivalPlatform: nil, departurePlatform: nil, cancelled: false),
        ]
        var known = scheduled
        known[0].departure?.actual = departure.addingTimeInterval(120)
        known[1].arrival?.actual = arrival.addingTimeInterval(300)
        let mock = MockProvider(source: .transitous)
        mock.trips["s7"] = Trip(id: "s7", line: line, direction: "Altona", stopovers: scheduled, cancelled: false, remarks: [], source: .transitous)
        let leg = Leg(origin: bergedorf, destination: hauptbahnhof,
                      departure: TimeInfo(planned: departure, actual: departure.addingTimeInterval(120)),
                      arrival: TimeInfo(planned: arrival, actual: arrival.addingTimeInterval(300)),
                      departurePlatform: nil, arrivalPlatform: nil, tripId: "s7", line: line, direction: "Altona",
                      isWalking: false, cancelled: false, stopovers: known, remarks: [], source: .transitous)
        let refresher = JourneyRefresher(provider: CombinedProvider(primary: mock, fallback: nil, bahnDe: nil), timetables: timetables)

        let refreshed = await refresher.refresh(Journey(legs: [leg], source: .transitous), now: arrival.addingTimeInterval(6 * 3600))

        #expect(refreshed.legs[0].departure.actual == departure.addingTimeInterval(120))
        #expect(refreshed.legs[0].arrival.actual == arrival.addingTimeInterval(300))
        #expect(refreshed.legs[0].stopovers.last?.arrival?.actual == arrival.addingTimeInterval(300))
    }

    /// A journey finished over 24 hours ago shows no delay at all, neither "+0" nor a real one.
    @Test func droppingActualTimesShowsTheJourneyAsPlanned() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let a = station("a", "A"), b = station("b", "B"), c = station("c", "C")
        let stops = [
            Stopover(station: a, arrival: nil, departure: TimeInfo(planned: start, actual: start),
                     arrivalPlatform: nil, departurePlatform: nil, cancelled: false),
            Stopover(station: b, arrival: TimeInfo(planned: start.addingTimeInterval(60), actual: start.addingTimeInterval(240)),
                     departure: nil, arrivalPlatform: nil, departurePlatform: nil, cancelled: false),
            Stopover(station: c, arrival: TimeInfo(planned: start.addingTimeInterval(120), actual: start.addingTimeInterval(300)),
                     departure: nil, arrivalPlatform: nil, departurePlatform: nil, cancelled: false),
        ]
        let leg = Leg(origin: a, destination: c, departure: TimeInfo(planned: start, actual: start),
                      arrival: TimeInfo(planned: start.addingTimeInterval(120), actual: start.addingTimeInterval(300)),
                      departurePlatform: nil, arrivalPlatform: nil, tripId: "ic", line: nil, direction: nil,
                      isWalking: false, cancelled: false, stopovers: stops, remarks: [], source: .transitous)

        let cleaned = Journey(legs: [leg], source: .transitous).droppingActualTimes().legs[0]

        #expect(cleaned.departure == TimeInfo(planned: start, actual: nil))
        #expect(cleaned.arrival == TimeInfo(planned: start.addingTimeInterval(120), actual: nil))
        #expect(cleaned.stopovers.allSatisfy { $0.arrival?.actual == nil && $0.departure?.actual == nil })
        #expect(cleaned.stopovers[1].arrival?.planned == start.addingTimeInterval(60))
    }

    /// MOTIS repeats the schedule as a stop's time when it has no realtime; that's not a live "+0".
    @Test func transitousStopsWithoutRealtimeHaveNoActualTime() throws {
        let json = """
        {"mode": "SUBURBAN", "realTime": false, "tripId": "s7", "displayName": "S7",
         "from": {"name": "Hamburg-Bergedorf", "lat": 53.49, "lon": 10.2,
                  "departure": "2026-10-02T10:58:00Z", "scheduledDeparture": "2026-10-02T10:58:00Z"},
         "to": {"name": "Hamburg Hbf", "lat": 53.55, "lon": 10.0,
                "arrival": "2026-10-02T11:19:00Z", "scheduledArrival": "2026-10-02T11:19:00Z"},
         "startTime": "2026-10-02T10:58:00Z", "endTime": "2026-10-02T11:19:00Z"}
        """
        let leg = try JSONDecoding.decoder.decode(MLeg.self, from: Data(json.utf8)).toLeg()

        #expect(leg.stopovers.count == 2)
        #expect(leg.stopovers.allSatisfy { $0.arrival?.actual == nil && $0.departure?.actual == nil })
        #expect(leg.stopovers.last?.arrival?.planned == leg.arrival.planned)
        #expect(leg.arrival.delayMinutes == nil)
    }
}

/// IRIS for S 47124 on 2026-10-02 (real ids/times): Bergedorf lists it, Hamburg Hbf (8002549) doesn't,
/// "Hamburg Hbf (S-Bahn)" (8098549) does, 3 minutes late.
private final class BergedorfS7Protocol: URLProtocol, @unchecked Sendable {
    static let failHbfChangesOnce = Mutex(false)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let path = request.url!.path
        if path.hasSuffix("fchg/8098549"), Self.failHbfChangesOnce.withLock({ fail in defer { fail = false }; return fail }) {
            let response = HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data())
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let body = switch path {
        case _ where path.contains("plan/8000148/"):
            #"<timetable station='Hamburg-Bergedorf'><s id="b"><tl c="S" n="47124"/><ar pt="2610021257" pp="5"/><dp pt="2610021258" pp="5"/></s></timetable>"#
        case _ where path.hasSuffix("fchg/8000148"):
            #"<timetable station='Hamburg-Bergedorf'><s id="b" eva="8000148"><ar ct="2610021259"/><dp ct="2610021301"/></s></timetable>"#
        case _ where path.contains("plan/8098549/"):
            #"<timetable station='Hamburg Hbf (S-Bahn)'><s id="-7201046121150801590-2610021248-12"><tl c="S" n="47124"/><ar pt="2610021319" pp="1" l="S7"/><dp pt="2610021320" pp="1" l="S7"/></s></timetable>"#
        case _ where path.hasSuffix("fchg/8098549"):
            #"<timetable station='Hamburg Hbf (S-Bahn)'><s id="-7201046121150801590-2610021248-12" eva="8098549"><ar ct="2610021322" l="S7"/><dp ct="2610021324" l="S7"/></s></timetable>"#
        default:
            "<timetable></timetable>"
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

/// Issue #76: an S4 ending at München Hbf showed its arrival on time while running 3 minutes late.
/// DB's Timetables only lists the S-Bahn under "München Hbf (tief)", which station search never finds.
@Suite struct TimetablesLowerLevelTests {
    @Test func findsTheSBahnUnderTheStationsLowerLevel() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [LowerLevelS4Protocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let timetables = TimetablesClient(http: HTTPClient(session: session))
        // 2027-01-15 08:00 UTC == 09:00 Europe/Berlin (CET).
        let departure = Date(timeIntervalSince1970: 1_800_000_000)
        let leg = Leg(origin: station("8004158", "München-Pasing", 48.150, 11.461, source: .bahnDe),
                      destination: station("8000261", "München Hbf", 48.140, 11.558, source: .bahnDe),
                      departure: TimeInfo(planned: departure, actual: nil),
                      arrival: TimeInfo(planned: departure.addingTimeInterval(600), actual: departure.addingTimeInterval(600)),
                      departurePlatform: nil, arrivalPlatform: nil, tripId: "s4",
                      line: Line(name: "S4", number: "4", product: .suburban, operatorName: nil, tripNumber: "6467"),
                      direction: nil, isWalking: false, cancelled: false, stopovers: [], remarks: [], source: .transitous)

        let override = await timetables.realtime(for: leg)

        #expect(override?.arrival?.actual == departure.addingTimeInterval(13 * 60))
    }
}

/// München Hbf's own `/plan` doesn't have the S4; its lower level (8098263) does, 3 minutes late.
private final class LowerLevelS4Protocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.path
        let body: Data
        if path.contains("plan/8098263/") {
            body = Data("""
            <timetable station='München Hbf (tief)'><s id="7"><tl c="S" n="6467"/><ar pt="2701150910" pp="1" l="4"/></s></timetable>
            """.utf8)
        } else if path.contains("fchg/8098263") {
            body = Data("""
            <timetable station='München Hbf (tief)'><s id="7"><ar ct="2701150913"/></s></timetable>
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
        let timetables = TimetablesClient(http: HTTPClient(session: session))

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

@Suite struct TimetablesMatchTests {
    /// DB files private operators' trains under the operator's code (National Express's RE1 is
    /// `c="NX"`), and an ÖBB Railjet can be "RJ" in DB's feed but "ICE" in Transitous'.
    static let plan = TimetablesXMLParser.parse(Data("""
    <timetable station="Aachen Hbf">
      <s id="nx"><tl t="p" o="NXRE" c="NX" n="26836"/><ar pt="2609301507" pp="2" l="RE1"/></s>
      <s id="rj"><tl t="p" o="81" c="RJ" n="171"/><dp pt="2609301530" pp="6"/></s>
      <s id="re"><tl t="p" o="800" c="RE" n="171"/><dp pt="2609301800" pp="3" l="RE9"/></s>
    </timetable>
    """.utf8))

    static func time(_ hour: Int, _ minute: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimetablesClient.berlin
        return calendar.date(from: DateComponents(year: 2026, month: 9, day: 30, hour: hour, minute: minute))!
    }

    @Test func matchesPrivateOperatorByLineName() {
        let stop = TimetablesClient.match(Self.plan, category: "RE", number: "26836", plannedTime: Self.time(15, 7), side: \.arrival)
        #expect(stop?.id == "nx")
        #expect(stop?.arrival?.plannedPlatform == "2")
    }

    @Test func matchesDifferentlyBrandedTrainByNumberAndTime() {
        let stop = TimetablesClient.match(Self.plan, category: "ICE", number: "171", plannedTime: Self.time(15, 30), side: \.departure)
        #expect(stop?.id == "rj")
        #expect(TimetablesClient.match(Self.plan, category: "ICE", number: "172", plannedTime: Self.time(15, 30), side: \.departure) == nil)
        #expect(TimetablesClient.match(Self.plan, category: "ICE", number: "171", plannedTime: Self.time(16, 30), side: \.departure) == nil)
    }
}

@Suite struct TimetablesMessageTests {
    /// A `fchg` stop with a delay reason, a quality notice and a deleted message, as DB Navigator
    /// shows them under "Aktuelle Informationen".
    @Test func parsesDelayReasonsAndNotices() {
        let xml = Data("""
        <timetable station="Hamm(Westf)Hbf" eva="8000149">
          <s id="-123-2409221000-5" eva="8000149">
            <m id="r1" t="q" c="93" ts="2409221010"/>
            <ar ct="2409221215">
              <m id="r2" t="d" c="34" ts="2409221210"/>
              <m id="r3" t="d" c="43" ts="2409221205" del="1"/>
            </ar>
          </s>
        </timetable>
        """.utf8)

        let stops = TimetablesXMLParser.parse(xml)
        let messages = TimetablesMessage.resolve(stops.flatMap(\.messages))

        #expect(stops.count == 1)
        #expect(messages.map(\.text) == ["Keine behindertengerechte Einrichtung", "Reparatur an einem Signal"])
        #expect(messages.map(\.kind) == [.notice, .delay])
        #expect(messages.containsDelayReason)
    }

    /// "Keine Qualitätsmängel" clears the quality notices reported before it, and isn't shown itself.
    @Test func allClearRemovesOlderNotices() {
        let messages = TimetablesMessage.resolve([
            TimetablesMessage(code: 70, timestamp: Date(timeIntervalSince1970: 100)),
            TimetablesMessage(code: 88, timestamp: Date(timeIntervalSince1970: 200)),
            TimetablesMessage(code: 91, timestamp: Date(timeIntervalSince1970: 300)),
            TimetablesMessage(code: 99, timestamp: Date(timeIntervalSince1970: 50)),
        ])

        #expect(messages.map(\.text) == ["Verzögerungen im Betriebsablauf", "Fahrradmitnahme nicht möglich"])
    }

    /// The same notice reported at several stations shows once, at its first report.
    @Test func mergesRepeatedMessages() {
        let merged = TrainMessage.merged([
            TrainMessage(kind: .notice, text: "WLAN nicht verfügbar", timestamp: Date(timeIntervalSince1970: 200)),
            TrainMessage(kind: .notice, text: "WLAN nicht verfügbar", timestamp: Date(timeIntervalSince1970: 100)),
        ])

        #expect(merged.count == 1)
        #expect(merged.first?.timestamp == Date(timeIntervalSince1970: 100))
    }

    /// Journeys saved before `messages` existed still decode.
    @Test func decodesLegWithoutMessages() throws {
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(PreviewLegs.leg)) as! [String: Any]
        json.removeValue(forKey: "messages")
        let leg = try JSONDecoder().decode(Leg.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(leg.messages.isEmpty)
    }
}

private enum PreviewLegs {
    static let station = Station(id: "8000149", name: "Hamm(Westf)Hbf", coordinate: nil, evaNumber: "8000149", source: .transitous)
    static let leg = Leg(origin: station, destination: station, departure: TimeInfo(planned: .now, actual: nil),
                         arrival: TimeInfo(planned: .now, actual: nil), departurePlatform: nil, arrivalPlatform: nil,
                         tripId: "t", line: nil, direction: nil, isWalking: false, cancelled: false, stopovers: [],
                         remarks: [], messages: [TrainMessage(kind: .delay, text: "Bauarbeiten", timestamp: nil)],
                         source: .transitous)
}

// MARK: - Stop cancellations

/// Real-world case reported for RE 3318 (Lutherstadt Wittenberg → Pasewalk) on 2026-09-27:
/// Transitous' realtime feed flagged Wittenberg–Zahna and the Pasewalk terminus as skipped, while
/// DB's own IRIS feed had the train running from Wittenberg and arriving in Pasewalk as planned.
/// DB's per-side status has to win over Transitous' single per-stop flag wherever DB knows the stop.
@Suite struct StopCancellationTests {
    let wittenberg = station("8010222", "Lutherstadt Wittenberg Hbf")
    let bloensdorf = station("8011210", "Blönsdorf")
    let pasewalk = station("8010268", "Pasewalk")
    /// 2026-09-27 19:51 Europe/Berlin (CEST).
    let start = Date(timeIntervalSince1970: 1_790_531_460)

    func trip(cancelled: Bool) -> Trip {
        func at(_ minutes: Double) -> TimeInfo { TimeInfo(planned: start.addingTimeInterval(minutes * 60), actual: nil) }
        let stops = [
            Stopover(station: wittenberg, arrival: nil, departure: at(0), arrivalPlatform: nil, departurePlatform: nil, cancelled: cancelled),
            Stopover(station: bloensdorf, arrival: at(17), departure: at(18), arrivalPlatform: nil, departurePlatform: nil, cancelled: false),
            Stopover(station: pasewalk, arrival: at(208), departure: nil, arrivalPlatform: nil, departurePlatform: nil, cancelled: cancelled),
        ]
        return Trip(id: "re3318", line: Line(name: "RE 3", number: "3318", product: .regionalExpress, operatorName: nil,
                                             tripNumber: "3318"),
                    direction: "Pasewalk", stopovers: stops, cancelled: false, remarks: [], source: .transitous)
    }

    func client(_ protocolClass: URLProtocol.Type) -> (TimetablesClient, URLSession) {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [protocolClass]
        let session = URLSession(configuration: config)
        return (TimetablesClient(http: HTTPClient(session: session)), session)
    }

    @Test func dbRunningLiftsTransitousSkippedStops() async {
        let (timetables, session) = client(RE3318RunningProtocol.self)
        defer { session.invalidateAndCancel() }

        let result = await timetables.tripWithRealtime(trip(cancelled: true), now: start)

        #expect(result.stopovers.allSatisfy { !$0.cancelled })
    }

    /// IRIS reports a cancellation as a bare `cs="c"` with no time at all — it must still count.
    @Test func dbCancellationWithoutTimeIsKept() async {
        let (timetables, session) = client(RE3318CancelledProtocol.self)
        defer { session.invalidateAndCancel() }

        let result = await timetables.tripWithRealtime(trip(cancelled: false), now: start)

        #expect(result.stopovers[2].arrivalCancelled)
        #expect(result.stopovers[2].cancelled)
        #expect(!result.stopovers[1].cancelled)
    }

    /// A train cut short keeps its arrival; only the departure is gone — not the whole stop.
    @Test func departureOnlyCancellationKeepsTheArrival() {
        var stop = Stopover(station: pasewalk, arrival: TimeInfo(planned: start, actual: nil),
                            departure: TimeInfo(planned: start.addingTimeInterval(120), actual: nil),
                            arrivalPlatform: nil, departurePlatform: nil, cancelled: false)
        stop.departureCancelled = true
        #expect(!stop.cancelled)
        stop.arrivalCancelled = true
        #expect(stop.cancelled)
    }

    /// Without `fchg` DB can't tell whether the train runs, so Transitous' verdict stands.
    @Test func keepsTransitousCancellationWhenChangesAreUnavailable() async {
        let (timetables, session) = client(RE3318NoChangesProtocol.self)
        defer { session.invalidateAndCancel() }

        let result = await timetables.tripWithRealtime(trip(cancelled: true), now: start)

        #expect(result.stopovers[2].cancelled)
    }

    @Test func decodesStopoversSavedWithTheOldSingleFlag() throws {
        let saved = Stopover(station: pasewalk, arrival: TimeInfo(planned: start, actual: nil), departure: nil,
                             arrivalPlatform: nil, departurePlatform: nil, cancelled: true)
        var old = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as? [String: Any])
        old["arrivalCancelled"] = nil
        old["departureCancelled"] = nil
        let stop = try JSONDecoder().decode(Stopover.self, from: JSONSerialization.data(withJSONObject: old))
        #expect(stop.arrivalCancelled && stop.departureCancelled)

        let roundTripped = try JSONDecoder().decode(Stopover.self, from: JSONEncoder().encode(stop))
        #expect(roundTripped == stop)
    }
}

/// IRIS `plan` for RE 3318 at Wittenberg (departure), Blönsdorf and Pasewalk (arrival only, the
/// train terminates there). `fchg` is empty except for Pasewalk, which each subclass sets; `nil`
/// makes every `fchg` request fail.
private class RE3318Protocol: URLProtocol, @unchecked Sendable {
    class var fchgPasewalk: String? { "<timetable></timetable>" }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.path
        var status = 200
        let body: String
        if path.contains("plan/8010222") {
            body = #"<timetable><s id="3318-lw"><tl c="RE" n="3318"/><dp pt="2609271951" pp="1"/></s></timetable>"#
        } else if path.contains("plan/8011210") {
            body = #"<timetable><s id="3318-lbd"><tl c="RE" n="3318"/><ar pt="2609272008"/><dp pt="2609272009"/></s></timetable>"#
        } else if path.contains("plan/8010268") {
            body = #"<timetable><s id="3318-pw"><tl c="RE" n="3318"/><ar pt="2609272319" pp="1"/></s></timetable>"#
        } else if path.contains("fchg/8010268") {
            if let fchg = Self.fchgPasewalk { body = fchg } else { status = 500; body = "" }
        } else if path.contains("fchg/"), Self.fchgPasewalk == nil {
            status = 500; body = ""
        } else {
            body = "<timetable></timetable>"
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class RE3318RunningProtocol: RE3318Protocol, @unchecked Sendable {}

private final class RE3318CancelledProtocol: RE3318Protocol, @unchecked Sendable {
    override class var fchgPasewalk: String? {
        #"<timetable station='Pasewalk'><s id="3318-pw"><ar cs="c" clt="2609271500"/></s></timetable>"#
    }
}

private final class RE3318NoChangesProtocol: RE3318Protocol, @unchecked Sendable {
    override class var fchgPasewalk: String? { nil }
}

private final class HamburgBoardProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let body = Data(#"{"entries": [{"journeyId": "rj", "zeit": "2026-09-30T05:34:00", "verkehrmittel": {"name": "RJ 171"}}]}"#.utf8)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class MainStationGeocodeProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let text = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "text" }?.value
        let potsdam = #"[{"name":"Deutschland","adminLevel":2},{"name":"Brandenburg","adminLevel":4},{"name":"Potsdam","adminLevel":6,"default":true}]"#
        let body = text == "Potsdam Hbf"
            ? #"[{"type":"STOP","id":"potsdamHbf","name":"S Potsdam Hauptbahnhof","lat":52.391,"lon":13.067,"country":"DE","modes":["LONG_DISTANCE","REGIONAL_RAIL","SUBURBAN"],"importance":0.0038,"areas":\#(potsdam)},"#
                + #"{"type":"STOP","id":"erfurtHbf","name":"Erfurt, Hauptbahnhof","lat":50.972,"lon":11.038,"country":"DE","modes":["LONG_DISTANCE","REGIONAL_RAIL"],"importance":0.0059}]"#
            : #"[{"type":"STOP","id":"golm","name":"Potsdam, Golm Bhf","lat":52.409,"lon":12.970,"country":"DE","modes":["REGIONAL_RAIL","BUS"],"importance":0.0008,"areas":\#(potsdam)}]"#
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// "Po Hbf" answers at once, "Po Bahnhof" only after 5 s, everything else with nothing.
private final class SlowExtraGeocodeProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    private let stopped = Mutex(false)
    /// Set once the slow "Po Bahnhof" answer is due, whether or not the request was still waiting for it.
    static let answeredSlowly = Mutex(false)
    override func stopLoading() { stopped.withLock { $0 = true } }

    override func startLoading() {
        let text = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "text" }?.value ?? ""
        let body = text == "Po Hbf"
            ? #"[{"type":"STOP","id":"potsdamHbf","name":"S Potsdam Hauptbahnhof","lat":52.391,"lon":13.067,"country":"DE","modes":["LONG_DISTANCE","REGIONAL_RAIL"],"importance":0.0038}]"#
            : "[]"
        let finish: @Sendable () -> Void = { [self] in
            guard !stopped.withLock({ $0 }) else { return }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        if text == "Po Bahnhof" {
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                Self.answeredSlowly.withLock { $0 = true }
                finish()
            }
        } else {
            finish()
        }
    }
}

/// Geocode answers for `searchStationsAsksForStationsInTheNearbyTownAndAliases`.
private final class NearbyGeocodeProtocol: URLProtocol, @unchecked Sendable {
    static let requestedTexts = Mutex<[String]>([])

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let text = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "text" }?.value ?? ""
        Self.requestedTexts.withLock { $0.append(text) }
        let berlin = #"[{"name":"Deutschland","adminLevel":2},{"name":"Berlin","adminLevel":4,"default":true}]"#
        let body = switch text {
        case "ost":
            #"[{"type":"STOP","id":"ulmOst","name":"Ulm Ost","lat":48.407,"lon":9.995,"country":"DE","modes":["REGIONAL_RAIL"],"importance":0.00025}]"#
        case "Berlin ost":
            #"[{"type":"STOP","id":"ostbf","name":"Berlin Ostbf","lat":52.510,"lon":13.435,"country":"DE","modes":["LONG_DISTANCE","REGIONAL_RAIL","SUBURBAN"],"importance":0.0057,"areas":\#(berlin)},"#
                + #"{"type":"STOP","id":"hbf","name":"Berlin Hbf","lat":52.525,"lon":13.369,"country":"DE","modes":["LONG_DISTANCE","REGIONAL_RAIL"],"importance":0.02,"areas":\#(berlin)}]"#
        case "ber":
            #"[{"type":"STOP","id":"bern","name":"Bern","lat":46.949,"lon":7.439,"country":"CH","modes":["LONG_DISTANCE","REGIONAL_RAIL"],"importance":0.0518}]"#
        case "Flughafen BER":
            #"[{"type":"STOP","id":"ber","name":"Flughafen BER","lat":52.365,"lon":13.510,"country":"DE","modes":["LONG_DISTANCE","REGIONAL_RAIL","SUBURBAN"],"importance":0.0033},"#
                + #"{"type":"STOP","id":"zrh","name":"Zürich Flughafen","lat":47.450,"lon":8.562,"country":"CH","modes":["LONG_DISTANCE"],"importance":0.019}]"#
        case "Be Hbf":
            #"[{"type":"STOP","id":"berlinHbf","name":"Berlin Hauptbahnhof","lat":52.525,"lon":13.369,"country":"DE","modes":["LONG_DISTANCE","REGIONAL_RAIL"],"importance":0.02},"#
                + #"{"type":"STOP","id":"erfurtHbf","name":"Erfurt, Hauptbahnhof","lat":50.972,"lon":11.038,"country":"DE","modes":["LONG_DISTANCE","REGIONAL_RAIL"],"importance":0.0059}]"#
        default:
            "[]"
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

/// 404 for Berlin Hbf's upper level, the fixture's coach sequence for its lower level.
private final class LowerLevelSequenceProtocol: URLProtocol, @unchecked Sendable {
    static let requestedEVAs = Mutex<[String]>([])

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let eva = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "evaNumber" })?.value ?? ""
        Self.requestedEVAs.withLock { $0.append(eva) }
        let found = eva == "8098160"
        let body = found
            ? (try? Data(contentsOf: Bundle.module.url(forResource: "bahnde-vehicle-sequence", withExtension: "json", subdirectory: "Fixtures")!)) ?? Data()
            : Data(#"{"code":"WEB_RBL_NOTFOUND","status":"ERROR"}"#.utf8)
        let response = HTTPURLResponse(url: request.url!, statusCode: found ? 200 : 404, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
}
