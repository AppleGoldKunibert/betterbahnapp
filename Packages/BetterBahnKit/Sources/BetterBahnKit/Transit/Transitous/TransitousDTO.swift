import Foundation

// MOTIS API as served by https://api.transitous.org

struct MPlace: Decodable {
    var name: String
    var stopId: String?
    var parentId: String?
    var lat: Double
    var lon: Double
    var arrival: Date?
    var departure: Date?
    var scheduledArrival: Date?
    var scheduledDeparture: Date?
    var track: String?
    var scheduledTrack: String?
    /// VBB's S-Bahn Berlin feed (unlike its U-Bahn one) leaves `track`/`scheduledTrack` unset and only
    /// encodes the platform as free text here, e.g. "S-Bahnsteig Gleis 4" - see `descriptionTrack`.
    var description: String?
    var cancelled: Bool?
    var pickupType: String?
    var dropoffType: String?

    var access: StopAccess {
        StopAccess(pickupAllowed: pickupType != "NOT_ALLOWED", dropoffAllowed: dropoffType != "NOT_ALLOWED")
    }

    /// The platform number out of `description`'s "... Gleis <n>" (e.g. "S-Bahnsteig Gleis 4" -> "4"),
    /// for stops whose feed never fills in `track`/`scheduledTrack` at all - reported for the S-Bahn at
    /// Berlin Gesundbrunnen, which otherwise showed no platform anywhere despite the U8 at the very
    /// same station having one (its feed does populate `track` directly).
    var descriptionTrack: String? {
        guard let description,
              let match = description.range(of: #"Gleis\s+(\w+)"#, options: .regularExpression) else { return nil }
        return String(description[match]).replacingOccurrences(of: "Gleis", with: "")
            .trimmingCharacters(in: .whitespaces)
    }

    /// Whether this place is a bus bay ("Steig F/G | Steig F") rather than a railway platform.
    /// DELFI's feed puts some trains at a station's bus stop instead of their actual track - reported
    /// for trains at Hanau Hbf showing "Gleis F" (the bus bay) instead of Gleis 6.
    var isBusBay: Bool {
        guard let description else { return false }
        return description.hasPrefix("Steig") && !description.contains("Gleis")
    }

    /// The track and platform numbers `description` names: "Bahnsteig Gleis 2+3" -> 2 and 3, "Gleis 7-10 (DB)"
    /// -> 7 to 10, "Gleis 2, Gleis 3", "Gleise 5+6", "Gleis1/11", "Gleis 2b" -> 2, and as OWL writes them
    /// "Bahnsteig 2", "Bahn6+7", "B22+23". Empty when it names none.
    var descriptionTracks: Set<Int> {
        guard let description else { return [] }
        var tracks: Set<Int> = []
        for list in description.matches(of: /\b(?:Gleise?|Gl\.?|Bahnsteig|Bahnstg\.|Bahn|B)\s*(\d+[a-zA-Z]*(?:\s*[+\/,-]\s*\d+[a-zA-Z]*)*)/) {
            for part in list.1.matches(of: /(\d+)[a-zA-Z]*(?:\s*-\s*(\d+))?/) {
                guard let first = Int(part.1) else { continue }
                let last = part.2.flatMap { Int($0) } ?? first
                tracks.formUnion(first <= last && last - first <= 20 ? Array(first...last) : [first, last])
            }
        }
        return tracks
    }

    /// Whether `scheduledTrack` is the feed's own number for the stop rather than its track, while `description`
    /// names the real platform: VRS's stops around Köln carry "85" at Köln Hbf ("Bahnsteig Gleis 2+3", Gleis 3) and
    /// "84" to "94" at Köln Messe/Deutz (#445), OWL's around Bielefeld "91" to "98" (Bielefeld Hbf "94" at
    /// "Bahnsteig 2", Gleis 4; IC 2044 showed a platform change at every stop from Minden to Gütersloh, #458). Only a
    /// number from 70 to 99 counts, where all of those lie: a description may name only the platform ("Bahnsteig
    /// 02" for Gleis 3 at Solingen Hbf) or be cut off ("Gleis 2+" for Gleis 3 at Koblenz Hbf), and real tracks
    /// that high start at 101 (Koblenz Hbf 109, Stuttgart's S-Bahn 101).
    var hasStopNumberAsTrack: Bool {
        guard let number = Self.trainTrack(scheduledTrack)?.firstMatch(of: /^\s*(\d+)/).flatMap({ Int($0.1) }),
              (70..<100).contains(number) else { return false }
        let tracks = descriptionTracks
        return !tracks.isEmpty && !tracks.contains(number)
    }

    /// A train's track as the feed writes it, cleaned like every platform (`PlatformInfo.cleaned`) and without
    /// the "G" Paderborn Hbf puts in front ("G4" -> "4"); a bus bay's letter is left alone, as it isn't a train's.
    static func trainTrack(_ track: String?) -> String? {
        guard let track = PlatformInfo.cleaned(track) else { return nil }
        if let match = track.wholeMatch(of: /G(\d.*)/) { return String(match.1) }
        return track
    }

    /// The platform as `PlatformInfo`; `actual` only when `realtime` is set. For a train (`isRail`)
    /// a bus bay's letter (`isBusBay`) and a stop's own number (`hasStopNumberAsTrack`) are dropped,
    /// so DB's own Timetables schedule can fill in the real track instead (see
    /// `TimetablesClient.fillMissingPlatforms`) rather than showing a wrong one. A live track other
    /// than that number stays: DB's live data puts the real one there (Siegburg/Bonn "80" -> "3",
    /// Minden "93" -> "11"), not as a platform change.
    func platform(isRail: Bool, realtime: Bool = true) -> PlatformInfo {
        guard !(isRail && isBusBay) else { return PlatformInfo(planned: nil, actual: nil) }
        let scheduled = isRail ? Self.trainTrack(scheduledTrack) : scheduledTrack
        let live = isRail ? Self.trainTrack(track) : track
        if isRail && hasStopNumberAsTrack {
            return PlatformInfo(planned: nil, actual: realtime && live != scheduled ? live : nil)
        }
        return PlatformInfo(planned: scheduled ?? descriptionTrack,
                            actual: realtime ? (live ?? descriptionTrack) : nil)
    }

    /// DELFI stop areas whose feed name leaves out the city, keyed by their DHID. Stuttgart Hbf is
    /// split into "Hauptbahnhof (oben)" (the terminus) and "Hauptbahnhof (tief)" (the S-Bahn below),
    /// which otherwise showed up as two separate stations named "oben Hbf" and "tief Hbf".
    private static let namesWithoutCity: [String: String] = [
        "de:08111:6115": "Stuttgart Hbf",
        "de:08111:6118": "Stuttgart Hbf",
    ]

    /// `name`, or the full name from `namesWithoutCity` when this stop belongs to one of those areas.
    var stationName: String {
        let ids = [parentId, stopId].compactMap { $0 }
        for (dhid, fullName) in Self.namesWithoutCity
        where ids.contains(where: { $0.hasSuffix("_\(dhid)") || $0.contains("_\(dhid):") }) {
            return fullName
        }
        return name
    }

    /// A trip's `headsign` is only the feed's bare stop name, so for one of `namesWithoutCity` it
    /// showed up as "Hbf" alone (e.g. ICE 573 "Hauptbahnhof (oben)"); this stop's full name instead
    /// when `headsign` names it.
    func resolving(_ headsign: String) -> String {
        headsign == name ? stationName : headsign
    }

    /// `headsign` as shown when it names this stop: like the stop itself, so a train's direction reads
    /// like its stops ("Dresden-Neustadt", not DELFI's "Dresden Bahnhof Neustadt"); nil for another stop.
    func displayName(ofHeadsign headsign: String) -> String? {
        headsign == name || headsign == stationName ? toStation().displayName : nil
    }

    /// `headsign` as shown: like the first of `places` it names, else on its own
    /// (`StationNames.displayName(forName:)`).
    static func displayName(ofHeadsign headsign: String, namingOneOf places: [MPlace?]) -> String {
        for place in places.compactMap({ $0 }) {
            if let shown = place.displayName(ofHeadsign: headsign) { return shown }
        }
        return StationNames.displayName(forName: headsign)
    }

    func toStation() -> Station {
        Station(
            id: parentId ?? stopId ?? "\(lat),\(lon)", name: stationName,
            coordinate: Coordinate(latitude: lat, longitude: lon),
            evaNumber: nil, source: .transitous
        )
    }

    /// `actual` times only when `realtime` is set: without it MOTIS repeats the schedule there, which
    /// would read as a live "+0".
    func toStopover(isRail: Bool, realtime: Bool) -> Stopover {
        let platform = platform(isRail: isRail)
        return Stopover(
            station: toStation(),
            arrival: timeInfo(planned: scheduledArrival ?? arrival, actual: realtime ? arrival : nil),
            departure: timeInfo(planned: scheduledDeparture ?? departure, actual: realtime ? departure : nil),
            arrivalPlatform: platform,
            departurePlatform: platform,
            cancelled: cancelled ?? false,
            access: access
        )
    }
}

struct MLineInfo {
    var mode: String
    var displayName: String?
    var routeShortName: String?
    var tripShortName: String?
    var agencyName: String?
    var routeColor: String?

    func toLine() -> Line {
        let name = MLineInfo.uppercasingTrainCategory(trainNameInsteadOfLine ?? displayName ?? tripShortName ?? routeShortName ?? mode)
        // Only the letters: DELFI writes the line number right after the category, "RE3 (3349)", "RB10".
        let prefix = String(name.prefix { $0.isLetter }).uppercased()
        let product = MLineInfo.product(mode: mode, prefix: prefix)
        let digitsInName = name.split(separator: " ").last.map(String.init)?.filter(\.isNumber)
        var number = (digitsInName?.isEmpty == false ? digitsInName : tripShortName?.filter(\.isNumber))
            .map { String($0.drop(while: { $0 == "0" })) }
        // Some feeds only give a bare product code ("RJ") with the actual run number buried in a raw
        // trip code ("000385") instead of the display name — fold it in, otherwise unrelated
        // departures under the same product all look identically labeled.
        var displayedName = (digitsInName?.isEmpty != false) ? number.map { "\(name) \($0)" } ?? name : name
        let tripNumber = tripShortName.map { String($0.filter(\.isNumber).drop(while: { $0 == "0" })) }.flatMap { $0.isEmpty ? nil : $0 }
        // DELFI names a regional run "RE3 (3309)", but VBB's own feed (Berlin/Brandenburg) only "RE3",
        // with the run number as trip short name ("03309"). Name those the DELFI way, so the number
        // shows whichever feed the train comes from.
        if ["REGIONAL_RAIL", "REGIONAL_FAST_RAIL"].contains(mode), digitsInName?.isEmpty == false, !name.contains("("),
           let tripNumber, tripNumber != number, tripShortName?.allSatisfy(\.isNumber) == true {
            displayedName = "\(name) (\(tripNumber))"
            number = tripNumber
        }
        return Line(name: displayedName, number: number, product: product, operatorName: agencyName, tripNumber: tripNumber,
                    nightRail: mode == "NIGHT_RAIL" ? true : nil, feedColorHex: Line.hex(fromFeedColor: routeColor))
    }

    /// Long-distance train categories a Czech feed puts behind its line name.
    private static let bracketedTrainCategories: Set<String> = ["ICE", "ECE", "RJ", "RJX", "EC", "IC", "EN", "NJ"]

    /// Czech feeds (CZPTT) name a long-distance train after its line, with the train in brackets:
    /// "Ex5 (rj 383)" for the Railjet København → Praha, "Ex2 (EC 223)". It's the train passengers and
    /// bahn.de know ("RJ 383"; Czech writes ČD's railjet "rj"), and only under that name does it match
    /// the same train from DB's or DSB's feed.
    var trainNameInsteadOfLine: String? {
        guard let displayName, let tripShortName else { return nil }
        let parts = tripShortName.split(separator: " ")
        guard parts.count == 2, parts[1].allSatisfy(\.isNumber), displayName.hasSuffix("(\(tripShortName))") else { return nil }
        let category = parts[0].uppercased()
        guard Self.bracketedTrainCategories.contains(category) else { return nil }
        return "\(category) \(parts[1])"
    }

    /// `name` with a lowercase long-distance category written the way bahn.de does: the Slovak feed
    /// (ZSSK) names ČD's Railjet "rj 174", which read as a different train next to DB's "RJ 174".
    static func uppercasingTrainCategory(_ name: String) -> String {
        let parts = name.split(separator: " ", maxSplits: 1)
        guard parts.count == 2, parts[0].allSatisfy(\.isLowercase), parts[1].allSatisfy(\.isNumber),
              bracketedTrainCategories.contains(parts[0].uppercased()) else { return name }
        return "\(parts[0].uppercased()) \(parts[1])"
    }

    /// Whether this is a train (as opposed to bus, tram, subway, ferry, …).
    var isRail: Bool {
        ["HIGHSPEED_RAIL", "LONG_DISTANCE", "NIGHT_RAIL", "REGIONAL_FAST_RAIL", "REGIONAL_RAIL", "SUBURBAN", "RAIL"]
            .contains(mode)
    }

    static func product(mode: String, prefix: String) -> Product {
        // A high-speed train is never regional, whatever its feed says: DSB's feed (Rejseplanen) has the
        // Railjet København → Praha as a regional "RJ".
        if ["REGIONAL_FAST_RAIL", "REGIONAL_RAIL"].contains(mode), ProductGuess.fromLinePrefix(prefix) == .highSpeed {
            return .highSpeed
        }
        switch mode {
        case "HIGHSPEED_RAIL": return .highSpeed
        case "LONG_DISTANCE", "NIGHT_RAIL": return .longDistance
        case "REGIONAL_FAST_RAIL": return .regionalExpress
        case "REGIONAL_RAIL": return ProductGuess.fromLinePrefix(prefix) == .regionalExpress ? .regionalExpress : .regional
        case "SUBURBAN": return .suburban
        case "SUBWAY", "METRO": return .subway
        case "TRAM", "CABLE_CAR", "FUNICULAR": return .tram
        case "BUS": return .bus
        case "COACH": return .coach
        case "FERRY": return .ferry
        default: return ProductGuess.fromLinePrefix(prefix) ?? .other
        }
    }

    /// Raw MOTIS modes that can classify as `product` (inverse of `product(mode:prefix:)`), so the
    /// stoptimes request can ask the server for just those modes instead of relying on `n` to catch them.
    static func motisModes(for product: Product) -> [String] {
        switch product {
        case .highSpeed: return ["HIGHSPEED_RAIL"]
        // Feeds disagree on what a night train or an IR/FLX is, so all three groups ask for both modes
        // and the client-side filter (`Line.filterProduct`) tells them apart.
        case .longDistance, .nightTrain, .interregio: return ["LONG_DISTANCE", "NIGHT_RAIL"]
        case .regionalExpress: return ["REGIONAL_FAST_RAIL", "REGIONAL_RAIL"]
        case .regional: return ["REGIONAL_RAIL"]
        case .suburban: return ["SUBURBAN"]
        case .subway: return ["SUBWAY", "METRO"]
        case .tram: return ["TRAM", "CABLE_CAR", "FUNICULAR"]
        case .bus: return ["BUS"]
        case .coach: return ["COACH"]
        case .ferry: return ["FERRY"]
        case .other: return []
        }
    }
}

struct MLeg: Decodable {
    var mode: String
    var from: MPlace
    var to: MPlace
    var startTime: Date
    var endTime: Date
    var scheduledStartTime: Date?
    var scheduledEndTime: Date?
    var realTime: Bool?
    var headsign: String?
    /// The trip's final stop, beyond this leg's `to`.
    var tripTo: MPlace?
    var tripId: String?
    var routeShortName: String?
    var displayName: String?
    var tripShortName: String?
    var agencyName: String?
    var routeColor: String?
    var intermediateStops: [MPlace]?
    var cancelled: Bool?
    var tripCancelled: Bool?
    var legGeometry: MGeometry?

    struct MGeometry: Decodable { var points: String; var precision: Int? }

    var geometry: [Coordinate]? {
        legGeometry.map { Polyline.decode($0.points, precision: $0.precision ?? 6) }
    }

    var isWalking: Bool { ["WALK", "BIKE", "CAR", "RENTAL", "FLEX", "ODM"].contains(mode) }

    var lineInfo: MLineInfo {
        MLineInfo(mode: mode, displayName: displayName, routeShortName: routeShortName,
                  tripShortName: tripShortName, agencyName: agencyName, routeColor: routeColor)
    }

    /// `headsign` as reported by the feed, corrected for a border-truncated source trip: a leg that
    /// was stitched together across a border (e.g. a Munich–Innsbruck ICE whose German feed data only
    /// covers the domestic portion up to Kufstein) keeps arriving at the requested destination, but
    /// its `headsign` still names that feed's own truncated endpoint — which then shows up as just
    /// another intermediate stop of this same leg rather than as its `to`. Prefer the leg's actual
    /// destination whenever `headsign` names a stop the train already passes through on the way there.
    var direction: String? {
        guard var headsign else { return nil }
        headsign = to.resolving(headsign)
        if let tripTo { headsign = tripTo.resolving(headsign) }
        let passesHeadsignAsIntermediateStop = (intermediateStops ?? [])
            .contains { Station.normalize($0.stationName) == Station.normalize(headsign) }
        if passesHeadsignAsIntermediateStop { return to.toStation().displayName }
        return MPlace.displayName(ofHeadsign: headsign, namingOneOf: [to, tripTo])
    }

    func toLeg() -> Leg {
        let realtime = realTime ?? false
        let dep = TimeInfo(planned: scheduledStartTime ?? startTime, actual: realtime ? startTime : nil)
        let arr = TimeInfo(planned: scheduledEndTime ?? endTime, actual: realtime ? endTime : nil)
        var stopovers: [Stopover] = []
        if !isWalking {
            let isRail = lineInfo.isRail
            stopovers = [from.toStopover(isRail: isRail, realtime: realtime)]
                + (intermediateStops ?? []).map { $0.toStopover(isRail: isRail, realtime: realtime) }
                + [to.toStopover(isRail: isRail, realtime: realtime)]
        }
        return Leg(
            origin: from.toStation(), destination: to.toStation(),
            departure: dep, arrival: arr,
            departurePlatform: from.platform(isRail: lineInfo.isRail),
            arrivalPlatform: to.platform(isRail: lineInfo.isRail),
            tripId: tripId, line: isWalking ? nil : lineInfo.toLine(), direction: direction,
            isWalking: isWalking, cancelled: (cancelled ?? false) || (tripCancelled ?? false),
            stopovers: stopovers, remarks: [], source: .transitous, geometry: geometry
        )
    }
}

struct MItinerary: Decodable {
    var legs: [MLeg]
}

struct MPlanResponse: Decodable {
    var itineraries: [MItinerary]
    var previousPageCursor: String?
    var nextPageCursor: String?
}

struct MStopTime: Decodable {
    var place: MPlace
    var mode: String
    var realTime: Bool?
    var headsign: String?
    var tripFrom: MPlace?
    var tripTo: MPlace?
    var tripId: String
    var routeShortName: String?
    var displayName: String?
    var tripShortName: String?
    var agencyName: String?
    var routeColor: String?
    var cancelled: Bool?
    var tripCancelled: Bool?

    var lineInfo: MLineInfo {
        MLineInfo(mode: mode, displayName: displayName, routeShortName: routeShortName,
                  tripShortName: tripShortName, agencyName: agencyName, routeColor: routeColor)
    }

    func toEntry(kind: BoardKind) -> BoardEntry? {
        let realtime = realTime ?? false
        let planned = kind == .departures ? place.scheduledDeparture : place.scheduledArrival
        let actual = kind == .departures ? place.departure : place.arrival
        guard let time = timeInfo(planned: planned, actual: realtime ? actual : nil) else { return nil }
        let station = place.toStation()
        let otherEnd = kind == .departures ? tripTo : tripFrom
        let line = lineInfo.toLine()
        let otherEndName = kind == .departures
            ? (headsign.map { MPlace.displayName(ofHeadsign: $0, namingOneOf: [tripTo]) } ?? tripTo?.toStation().displayName)
            : tripFrom?.toStation().displayName
        return BoardEntry(
            kind: kind, tripId: tripId, station: station, line: line,
            otherEnd: otherEndName,
            time: time,
            platform: place.platform(isRail: lineInfo.isRail, realtime: realtime),
            cancelled: (cancelled ?? false) || (tripCancelled ?? false),
            terminatesOrOriginatesHere: otherEnd.map { $0.toStation().isSamePlace(as: station) },
            remarks: [], access: place.access, source: .transitous
        )
    }
}

struct MStopTimesResponse: Decodable {
    var stopTimes: [MStopTime]
    var previousPageCursor: String?
    var nextPageCursor: String?
}

struct MGeocodeMatch: Decodable {
    /// One level of the place hierarchy a stop sits in (country → state → district → town → …),
    /// from least to most specific. `isDefault` marks the level that best names the immediate area.
    struct Area: Decodable {
        var name: String
        var adminLevel: Double?
        var isDefault: Bool?

        enum CodingKeys: String, CodingKey {
            case name, adminLevel
            case isDefault = "default"
        }
    }

    var type: String
    var name: String
    var id: String
    var lat: Double
    var lon: Double
    var country: String?
    var modes: [String]?
    var areas: [Area]?
    /// How busy the stop is, roughly its share of all departures: about 0.02 for Frankfurt (M) Hbf,
    /// 0.003 for Frankfurt (Oder), well under 0.001 for small stations and bus stops.
    var importance: Double? = nil

    /// Higher is better: train stations in Germany first.
    var relevance: Int {
        let modes = modes ?? []
        var score = 0
        if modes.contains(where: { ["HIGHSPEED_RAIL", "LONG_DISTANCE", "NIGHT_RAIL"].contains($0) }) { score += 4 }
        if modes.contains(where: { ["REGIONAL_RAIL", "REGIONAL_FAST_RAIL", "SUBURBAN", "RAIL"].contains($0) }) { score += 3 }
        if country == "DE" { score += 2 }
        return score
    }

    /// "Bayern" for a stop just named "Bernau" – the shortest qualifier that places it, meant to be
    /// shown as "Bernau (Bayern)" next to same-named stops elsewhere in the country. Prefers the
    /// state; falls back to the most specific named area if a stop has none (foreign stops).
    var region: String? {
        guard let areas, !areas.isEmpty else { return nil }
        if let state = areas.first(where: { $0.adminLevel == 4 })?.name { return state }
        return areas.first { $0.isDefault == true }?.name
    }

    /// The town this stop is in, e.g. "Stuttgart" or "München".
    var town: String? { areas?.first { $0.isDefault == true }?.name }

    /// The town and the parts of it the stop is in ("Berlin", "Spandau"), not the wider areas above
    /// the town – otherwise every stop in the state of Brandenburg would match "Brandenburg".
    var localAreaNames: [String] {
        guard let areas, let town = areas.first(where: { $0.isDefault == true }) else { return [] }
        let townLevel = town.adminLevel ?? 0
        return areas.filter { $0.isDefault == true || ($0.adminLevel ?? 0) > townLevel }.map(\.name)
    }

    /// `name`, with the town put in front when the feed left it out of a main station's name -
    /// "Hauptbahnhof (tief)" in Stuttgart or "Hauptbahnhof Süd" in München showed up as just "Hbf"
    /// and "Hbf Süd" in search, with nothing saying which city they're in.
    var fullName: String {
        guard let town, ["Hauptbahnhof", "Hauptbf", "Hbf"].contains(where: { name.hasPrefix($0) }) else { return name }
        return "\(town) \(name)"
    }

    func toStation() -> Station {
        Station(id: id, name: fullName, coordinate: Coordinate(latitude: lat, longitude: lon), evaNumber: nil,
                source: .transitous, region: region, country: country)
    }
}

private func timeInfo(planned: Date?, actual: Date?) -> TimeInfo? {
    guard let planned = planned ?? actual else { return nil }
    return TimeInfo(planned: planned, actual: actual)
}

private enum ProductGuess {
    static func fromLinePrefix(_ prefix: String) -> Product? {
        switch prefix {
        case "ICE", "TGV", "RJ", "RJX", "ECE", "EST", "THA": .highSpeed
        case "IC", "EC", "EN", "NJ", "FLX", "ES", "D", "IRE": .longDistance
        case "RE", "RS", "MEX", "FEX": .regionalExpress
        case "RB", "ERB", "NWB", "HLB", "BRB", "WFB": .regional
        case "S": .suburban
        case "U": .subway
        case "STR", "TRAM": .tram
        case "BUS": .bus
        default: nil
        }
    }
}
