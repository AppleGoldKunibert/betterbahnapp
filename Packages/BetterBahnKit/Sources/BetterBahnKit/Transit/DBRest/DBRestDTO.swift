import Foundation

// Friendly Public Transport Format as served by db-rest (v6.db.transport.rest).

struct DBLocation: Decodable {
    struct Coordinates: Decodable { var latitude: Double?; var longitude: Double? }
    var type: String?
    var id: String?
    var name: String?
    var location: Coordinates?
    var station: Box<DBLocation>?

    func toStation() -> Station? {
        guard let id, let name else { return nil }
        var coordinate: Coordinate?
        if let lat = location?.latitude, let lon = location?.longitude {
            coordinate = Coordinate(latitude: lat, longitude: lon)
        }
        let isEVA = id.count == 7 && id.allSatisfy(\.isNumber)
        return Station(id: id, name: name, coordinate: coordinate, evaNumber: isEVA ? id : nil, source: .dbRest)
    }
}

/// Indirection to allow recursive decodable structs.
final class Box<T: Decodable>: Decodable {
    let value: T
    required init(from decoder: Decoder) throws { value = try T(from: decoder) }
}

struct DBOperator: Decodable { var id: String?; var name: String? }

struct DBLine: Decodable {
    var name: String?
    var fahrtNr: String?
    var productName: String?
    var product: String?
    var mode: String?
    var `operator`: DBOperator?

    func toLine() -> Line {
        let product = DBLine.product(from: product, name: name)
        return Line(name: name ?? productName ?? "?", number: fahrtNr, product: product, operatorName: `operator`?.name)
    }

    static func product(from raw: String?, name: String?) -> Product {
        switch raw {
        case "nationalExpress": return .highSpeed
        case "national": return .longDistance
        case "regionalExpress": return .regionalExpress
        case "regional": return .regional
        case "suburban": return .suburban
        case "subway": return .subway
        case "tram": return .tram
        case "bus": return .bus
        case "ferry": return .ferry
        default:
            let prefix = name?.split(separator: " ").first.map(String.init)?.uppercased() ?? ""
            return ProductGuess.fromLinePrefix(prefix) ?? .other
        }
    }
}

enum ProductGuess {
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

struct DBRemark: Decodable {
    var type: String?
    var text: String?
    var summary: String?

    static func texts(_ remarks: [DBRemark]?) -> [String] {
        (remarks ?? []).filter { $0.type != "hint" }.compactMap { $0.summary ?? $0.text }
    }
}

struct DBStopover: Decodable {
    var stop: DBLocation
    var arrival: Date?
    var plannedArrival: Date?
    var departure: Date?
    var plannedDeparture: Date?
    var arrivalPlatform: String?
    var plannedArrivalPlatform: String?
    var departurePlatform: String?
    var plannedDeparturePlatform: String?
    var cancelled: Bool?

    func toStopover() -> Stopover? {
        guard let station = stop.toStation() else { return nil }
        return Stopover(
            station: station,
            arrival: timeInfo(planned: plannedArrival, actual: arrival),
            departure: timeInfo(planned: plannedDeparture, actual: departure),
            arrivalPlatform: PlatformInfo(planned: plannedArrivalPlatform, actual: arrivalPlatform),
            departurePlatform: PlatformInfo(planned: plannedDeparturePlatform, actual: departurePlatform),
            cancelled: cancelled ?? false
        )
    }
}

func timeInfo(planned: Date?, actual: Date?) -> TimeInfo? {
    guard let planned = planned ?? actual else { return nil }
    return TimeInfo(planned: planned, actual: actual)
}

struct DBLeg: Decodable {
    var origin: DBLocation
    var destination: DBLocation
    var departure: Date?
    var plannedDeparture: Date?
    var arrival: Date?
    var plannedArrival: Date?
    var departurePlatform: String?
    var plannedDeparturePlatform: String?
    var arrivalPlatform: String?
    var plannedArrivalPlatform: String?
    var tripId: String?
    var line: DBLine?
    var direction: String?
    var walking: Bool?
    var cancelled: Bool?
    var stopovers: [DBStopover]?
    var remarks: [DBRemark]?

    func toLeg() -> Leg? {
        guard let origin = origin.toStation(), let destination = destination.toStation(),
              let dep = timeInfo(planned: plannedDeparture, actual: departure),
              let arr = timeInfo(planned: plannedArrival, actual: arrival) else { return nil }
        return Leg(
            origin: origin, destination: destination, departure: dep, arrival: arr,
            departurePlatform: PlatformInfo(planned: plannedDeparturePlatform, actual: departurePlatform),
            arrivalPlatform: PlatformInfo(planned: plannedArrivalPlatform, actual: arrivalPlatform),
            tripId: tripId, line: line?.toLine(), direction: direction,
            isWalking: walking ?? false, cancelled: cancelled ?? false,
            stopovers: (stopovers ?? []).compactMap { $0.toStopover() },
            remarks: DBRemark.texts(remarks), source: .dbRest
        )
    }
}

struct DBJourneysResponse: Decodable {
    struct DBJourney: Decodable { var legs: [DBLeg] }
    var earlierRef: String?
    var laterRef: String?
    var journeys: [DBJourney]
}

struct DBBoardItem: Decodable {
    var tripId: String
    var stop: DBLocation?
    var when: Date?
    var plannedWhen: Date?
    var platform: String?
    var plannedPlatform: String?
    var direction: String?
    var provenance: String?
    var line: DBLine?
    var cancelled: Bool?
    var remarks: [DBRemark]?
    var origin: DBLocation?
    var destination: DBLocation?

    func toEntry(kind: BoardKind, fallbackStation: Station) -> BoardEntry? {
        guard let time = timeInfo(planned: plannedWhen, actual: when) else { return nil }
        let station = stop?.toStation() ?? fallbackStation
        let otherEndName = kind == .departures ? (direction ?? destination?.name) : (provenance ?? origin?.name)
        var terminal: Bool?
        let otherEndStation = kind == .departures ? destination?.toStation() : origin?.toStation()
        if let otherEndStation { terminal = otherEndStation.isSamePlace(as: station) }
        return BoardEntry(
            kind: kind, tripId: tripId, station: station,
            line: line?.toLine() ?? Line(name: "?", number: nil, product: .other, operatorName: nil),
            otherEnd: otherEndName, time: time,
            platform: PlatformInfo(planned: plannedPlatform, actual: platform),
            cancelled: cancelled ?? false, terminatesOrOriginatesHere: terminal,
            remarks: DBRemark.texts(remarks), access: DBRemark.access(remarks), source: .dbRest
        )
    }
}

extension DBRemark {
    /// HAFAS/vendo mark boarding restrictions only as remark texts.
    static func access(_ remarks: [DBRemark]?) -> StopAccess {
        let texts = (remarks ?? []).compactMap { ($0.text ?? "") + " " + ($0.summary ?? "") }.map { $0.lowercased() }
        let noBoarding = texts.contains { $0.contains("kein einstieg") || $0.contains("kein zustieg") || $0.contains("nur ausstieg") }
        let noAlighting = texts.contains { $0.contains("kein ausstieg") || $0.contains("nur einstieg") || $0.contains("nur zustieg") }
        return StopAccess(pickupAllowed: !noBoarding, dropoffAllowed: !noAlighting)
    }
}

/// db-rest v6 wraps boards in an object; older versions return a bare array.
struct DBBoardResponse: Decodable {
    var items: [DBBoardItem]

    private enum CodingKeys: String, CodingKey { case departures, arrivals }

    init(from decoder: Decoder) throws {
        if var array = try? decoder.unkeyedContainer() {
            var items: [DBBoardItem] = []
            while !array.isAtEnd { items.append(try array.decode(DBBoardItem.self)) }
            self.items = items
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        items = try container.decodeIfPresent([DBBoardItem].self, forKey: .departures)
            ?? container.decodeIfPresent([DBBoardItem].self, forKey: .arrivals) ?? []
    }
}

struct DBTripResponse: Decodable {
    struct DBTrip: Decodable {
        var id: String
        var line: DBLine?
        var direction: String?
        var stopovers: [DBStopover]?
        var cancelled: Bool?
        var remarks: [DBRemark]?
    }
    var trip: DBTrip
}
