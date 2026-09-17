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
    var cancelled: Bool?
    var pickupType: String?
    var dropoffType: String?

    var access: StopAccess {
        StopAccess(pickupAllowed: pickupType != "NOT_ALLOWED", dropoffAllowed: dropoffType != "NOT_ALLOWED")
    }

    func toStation() -> Station {
        Station(
            id: parentId ?? stopId ?? "\(lat),\(lon)", name: name,
            coordinate: Coordinate(latitude: lat, longitude: lon),
            evaNumber: nil, source: .transitous
        )
    }

    func toStopover() -> Stopover {
        Stopover(
            station: toStation(),
            arrival: timeInfo(planned: scheduledArrival, actual: arrival),
            departure: timeInfo(planned: scheduledDeparture, actual: departure),
            arrivalPlatform: PlatformInfo(planned: scheduledTrack, actual: track),
            departurePlatform: PlatformInfo(planned: scheduledTrack, actual: track),
            cancelled: cancelled ?? false
        )
    }
}

struct MLineInfo {
    var mode: String
    var displayName: String?
    var routeShortName: String?
    var tripShortName: String?
    var agencyName: String?

    func toLine() -> Line {
        let name = displayName ?? tripShortName ?? routeShortName ?? mode
        let prefix = name.split(separator: " ").first.map { String($0).uppercased() } ?? ""
        let product = MLineInfo.product(mode: mode, prefix: prefix)
        let digitsInName = name.split(separator: " ").last.map(String.init)?.filter(\.isNumber)
        let number = (digitsInName?.isEmpty == false ? digitsInName : tripShortName?.filter(\.isNumber))
            .map { String($0.drop(while: { $0 == "0" })) }
        // Some feeds only give a bare product code ("RJ") with the actual run number buried in a raw
        // trip code ("000385") instead of the display name — fold it in, otherwise unrelated
        // departures under the same product all look identically labeled.
        let displayedName = (digitsInName?.isEmpty != false) ? number.map { "\(name) \($0)" } ?? name : name
        return Line(name: displayedName, number: number, product: product, operatorName: agencyName)
    }

    static func product(mode: String, prefix: String) -> Product {
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
        case .longDistance: return ["LONG_DISTANCE", "NIGHT_RAIL"]
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
    var tripId: String?
    var routeShortName: String?
    var displayName: String?
    var tripShortName: String?
    var agencyName: String?
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
                  tripShortName: tripShortName, agencyName: agencyName)
    }

    func toLeg() -> Leg {
        let realtime = realTime ?? false
        let dep = TimeInfo(planned: scheduledStartTime ?? startTime, actual: realtime ? startTime : nil)
        let arr = TimeInfo(planned: scheduledEndTime ?? endTime, actual: realtime ? endTime : nil)
        var stopovers: [Stopover] = []
        if !isWalking {
            stopovers = [from.toStopover()] + (intermediateStops ?? []).map { $0.toStopover() } + [to.toStopover()]
        }
        return Leg(
            origin: from.toStation(), destination: to.toStation(),
            departure: dep, arrival: arr,
            departurePlatform: PlatformInfo(planned: from.scheduledTrack, actual: from.track),
            arrivalPlatform: PlatformInfo(planned: to.scheduledTrack, actual: to.track),
            tripId: tripId, line: isWalking ? nil : lineInfo.toLine(), direction: headsign,
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
    var cancelled: Bool?
    var tripCancelled: Bool?

    func toEntry(kind: BoardKind) -> BoardEntry? {
        let realtime = realTime ?? false
        let planned = kind == .departures ? place.scheduledDeparture : place.scheduledArrival
        let actual = kind == .departures ? place.departure : place.arrival
        guard let time = timeInfo(planned: planned, actual: realtime ? actual : nil) else { return nil }
        let station = place.toStation()
        let otherEnd = kind == .departures ? tripTo : tripFrom
        let line = MLineInfo(mode: mode, displayName: displayName, routeShortName: routeShortName,
                             tripShortName: tripShortName, agencyName: agencyName).toLine()
        return BoardEntry(
            kind: kind, tripId: tripId, station: station, line: line,
            otherEnd: kind == .departures ? (headsign ?? tripTo?.name) : tripFrom?.name,
            time: time,
            platform: PlatformInfo(planned: place.scheduledTrack, actual: realtime ? place.track : nil),
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
    var type: String
    var name: String
    var id: String
    var lat: Double
    var lon: Double
    var country: String?
    var modes: [String]?

    /// Higher is better: train stations in Germany first.
    var relevance: Int {
        let modes = modes ?? []
        var score = 0
        if modes.contains(where: { ["HIGHSPEED_RAIL", "LONG_DISTANCE", "NIGHT_RAIL"].contains($0) }) { score += 4 }
        if modes.contains(where: { ["REGIONAL_RAIL", "REGIONAL_FAST_RAIL", "SUBURBAN", "RAIL"].contains($0) }) { score += 3 }
        if country == "DE" { score += 2 }
        return score
    }

    func toStation() -> Station {
        Station(id: id, name: name, coordinate: Coordinate(latitude: lat, longitude: lon), evaNumber: nil, source: .transitous)
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
        case "RE", "RS", "MEX": .regionalExpress
        case "RB", "ERB", "NWB", "HLB", "BRB", "WFB": .regional
        case "S": .suburban
        case "U": .subway
        case "STR", "TRAM": .tram
        case "BUS": .bus
        default: nil
        }
    }
}
