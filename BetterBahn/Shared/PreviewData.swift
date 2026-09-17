import BetterBahnKit
import Foundation

/// Sample data for SwiftUI previews.
enum PreviewData {
    static let base = Calendar.current.date(bySettingHour: 18, minute: 12, second: 0, of: .now)!

    static func at(_ minutes: Double) -> Date { base.addingTimeInterval(minutes * 60) }

    static func station(_ id: String, _ name: String) -> Station {
        Station(id: id, name: name, coordinate: nil, evaNumber: id, source: .bahnDe)
    }

    static let koeln = station("8000207", "Köln Hbf")
    static let duesseldorf = station("8000085", "Düsseldorf Hbf")
    static let hannover = station("8000152", "Hannover Hbf")
    static let berlin = station("8011160", "Berlin Hbf")
    static let wolfsburg = station("8006552", "Wolfsburg Hbf")

    static let ice = Line(name: "ICE 645", number: "645", product: .highSpeed, operatorName: "DB Fernverkehr AG")
    static let ic = Line(name: "IC 2447", number: "2447", product: .longDistance, operatorName: "DB Fernverkehr AG")
    static let re = Line(name: "RE 1", number: nil, product: .regionalExpress, operatorName: "National Express")
    static let s = Line(name: "S 11", number: nil, product: .suburban, operatorName: "DB Regio NRW")

    static func stop(_ station: Station, arr: Double?, dep: Double?, delay: Double = 0, platform: String? = nil, changed: String? = nil) -> Stopover {
        Stopover(station: station,
                 arrival: arr.map { TimeInfo(planned: at($0), actual: at($0 + delay)) },
                 departure: dep.map { TimeInfo(planned: at($0), actual: at($0 + delay)) },
                 arrivalPlatform: PlatformInfo(planned: platform, actual: changed ?? platform),
                 departurePlatform: PlatformInfo(planned: platform, actual: changed ?? platform),
                 cancelled: false)
    }

    static let firstLeg = Leg(
        origin: koeln, destination: hannover,
        departure: TimeInfo(planned: at(0), actual: at(4)), arrival: TimeInfo(planned: at(162), actual: at(166)),
        departurePlatform: PlatformInfo(planned: "4", actual: "5"), arrivalPlatform: PlatformInfo(planned: "8", actual: "8"),
        tripId: "t1", line: ice, direction: "Berlin Ostbahnhof", isWalking: false, cancelled: false,
        stopovers: [stop(koeln, arr: nil, dep: 0, delay: 4, platform: "4", changed: "5"),
                    stop(duesseldorf, arr: 22, dep: 24, delay: 4, platform: "16"),
                    stop(station("8000098", "Essen Hbf"), arr: 45, dep: 47, delay: 4),
                    stop(station("8000080", "Dortmund Hbf"), arr: 68, dep: 71, delay: 4),
                    stop(station("8000036", "Bielefeld Hbf"), arr: 118, dep: 120, delay: 4),
                    stop(hannover, arr: 162, dep: nil, delay: 4, platform: "8")],
        remarks: ["Bauarbeiten zwischen Dortmund und Hamm – Umleitung mit ca. 5 Min. Verspätung"], source: .transitous)

    static let walk = Leg(
        origin: hannover, destination: hannover,
        departure: TimeInfo(planned: at(166), actual: nil), arrival: TimeInfo(planned: at(171), actual: nil),
        departurePlatform: nil, arrivalPlatform: nil, tripId: nil, line: nil, direction: nil,
        isWalking: true, cancelled: false, stopovers: [], remarks: [], source: .transitous)

    static let secondLeg = Leg(
        origin: hannover, destination: berlin,
        departure: TimeInfo(planned: at(180), actual: at(180)), arrival: TimeInfo(planned: at(279), actual: at(281)),
        departurePlatform: PlatformInfo(planned: "11", actual: "11"), arrivalPlatform: PlatformInfo(planned: "14", actual: "14"),
        tripId: "t2", line: Line(name: "ICE 849", number: "849", product: .highSpeed, operatorName: "DB Fernverkehr AG"),
        direction: "Berlin Ostbahnhof", isWalking: false, cancelled: false,
        stopovers: [stop(hannover, arr: nil, dep: 180, platform: "11"), stop(wolfsburg, arr: 212, dep: 214),
                    stop(station("8010404", "Berlin-Spandau"), arr: 262, dep: 264, delay: 2),
                    stop(berlin, arr: 279, dep: nil, delay: 2, platform: "14")],
        remarks: [], source: .transitous)

    static let journey = Journey(legs: [firstLeg, walk, secondLeg], source: .transitous)

    static let directJourney = Journey(legs: [Leg(
        origin: koeln, destination: berlin,
        departure: TimeInfo(planned: at(48), actual: at(48)), arrival: TimeInfo(planned: at(316), actual: at(325)),
        departurePlatform: PlatformInfo(planned: "6", actual: "6"), arrivalPlatform: PlatformInfo(planned: "12", actual: "12"),
        tripId: "t3", line: Line(name: "ICE 947", number: "947", product: .highSpeed, operatorName: nil),
        direction: "Berlin Ostbahnhof", isWalking: false, cancelled: false, stopovers: [], remarks: [], source: .transitous)],
        source: .transitous)

    static let regionalJourney = Journey(legs: [
        Leg(origin: koeln, destination: duesseldorf, departure: TimeInfo(planned: at(15), actual: at(15)),
            arrival: TimeInfo(planned: at(40), actual: at(40)), departurePlatform: nil, arrivalPlatform: nil,
            tripId: "r1", line: re, direction: nil, isWalking: false, cancelled: false, stopovers: [], remarks: [], source: .transitous),
        Leg(origin: duesseldorf, destination: berlin, departure: TimeInfo(planned: at(55), actual: nil),
            arrival: TimeInfo(planned: at(330), actual: nil), departurePlatform: nil, arrivalPlatform: nil,
            tripId: "r2", line: Line(name: "FLX 1245", number: "1245", product: .longDistance, operatorName: "FlixTrain"),
            direction: nil, isWalking: false, cancelled: true, stopovers: [], remarks: [], source: .transitous),
    ], source: .transitous)

    static func entry(_ line: Line, _ minutes: Double, delay: Double?, to: String, platform: String, changed: String? = nil,
                      cancelled: Bool = false, kind: BoardKind = .departures, remark: String? = nil) -> BoardEntry {
        BoardEntry(kind: kind, tripId: UUID().uuidString, station: koeln, line: line, otherEnd: to,
                   time: TimeInfo(planned: at(minutes), actual: delay.map { at(minutes + $0) }),
                   platform: PlatformInfo(planned: platform, actual: changed ?? platform), cancelled: cancelled,
                   terminatesOrOriginatesHere: false, remarks: remark.map { [$0] } ?? [], source: .transitous)
    }

    static let board: [BoardEntry] = [
        entry(ice, 0, delay: 4, to: "Berlin Ostbahnhof", platform: "4", changed: "5", remark: "Wagenreihung geändert"),
        entry(s, 3, delay: 0, to: "Düsseldorf Flughafen Terminal", platform: "10"),
        entry(re, 6, delay: 12, to: "Aachen Hbf", platform: "7"),
        entry(ic, 11, delay: nil, to: "Stuttgart Hbf", platform: "2", cancelled: true),
        entry(Line(name: "RB 25", number: nil, product: .regional, operatorName: nil), 14, delay: 1, to: "Lüdenscheid", platform: "11"),
        entry(Line(name: "EST 9459", number: "9459", product: .highSpeed, operatorName: "Eurostar"), 18, delay: 0, to: "Dortmund Hbf", platform: "3"),
    ]

    static let trip = Trip(id: "t1", line: ice, direction: "Berlin Ostbahnhof",
                           stopovers: firstLeg.stopovers + [stop(wolfsburg, arr: 200, dep: 202, delay: 4), stop(berlin, arr: 262, dep: nil, delay: 4, platform: "14")],
                           cancelled: false, remarks: [], source: .transitous)
}
