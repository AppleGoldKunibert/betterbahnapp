import Foundation

/// One coach of an ICE seen from above with every seat, from DB's "Wagenreihungspläne" (© Deutsche Bahn
/// AG, as bahn.expert links them), shown when a coach in the Wagenreihung is tapped (#365). The app has
/// the drawing without seat numbers as image `imageName`; the numbers are drawn on top at `seats`, so they
/// stay upright when the coach is shown turned round and a reserved seat can be highlighted.
/// `scripts/make-seat-maps.py` builds `Resources/SeatMaps.json` and the images.
public struct SeatMap: Sendable, Hashable {
    public struct Seat: Sendable, Hashable {
        /// "45"
        public var number: String
        /// The number's box within the drawing, as fractions of its width and height (origin top left).
        public var x: Double
        public var y: Double
        public var width: Double
        public var height: Double
    }

    /// The sheet the coach comes from, e.g. "412.7".
    public var sheet: String
    /// Coach numbers this layout has in the trainset: "23" and "33" for the two halves of a double ICE 3.
    public var numbers: [String]
    /// "2. Kl.-Mittelwagen"
    public var title: String?
    /// Construction type, e.g. "Bpmz 403.7".
    public var type: String?
    /// Asset name in the app, e.g. "Seats-403-23".
    public var imageName: String
    /// Width divided by height of the drawing.
    public var aspectRatio: Double
    public var seats: [Seat]

    public func seat(_ number: String) -> Seat? {
        seats.first { $0.number == number }
    }

    /// The layout of coach `number` on `sheet`.
    public static func coach(_ number: String, sheet: String) -> SeatMap? {
        sheets[sheet]?.first { $0.numbers.contains(number) }
    }

    /// The sheet for a trainset of `subtype` (as `TrainModel` detects it, "403.S2", "412" …) with these
    /// coach numbers; nil for anything but the ICE series DB has a sheet for. The ICE 1 runs with 12
    /// middle coaches or, modernised, with 9; the ICE 4 with 7, 12 or 13.
    static func sheet(subtype: String?, coachNumbers: [String]) -> String? {
        let count = Set(coachNumbers).count
        return switch subtype {
        case "401": count >= 11 ? "401" : "401.LDV"
        case "402", "407", "408", "411.S1", "411.S2": subtype
        // Every BR 403 has been redesigned by now.
        case "403.S1", "403.S2", "403.R": "403"
        case "412": count <= 7 ? "412.7" : count >= 13 ? "412.13" : "412"
        default: nil
        }
    }

    /// Whether a trainset's coaches stand with the higher numbers on the left, given their numbers from
    /// left to right. The sheets draw every coach with the lower numbers on the left (21 left, 29 right),
    /// so such a trainset's coaches are shown turned round.
    public static func isTurned(numbersLeftToRight numbers: [String]) -> Bool {
        let values = numbers.compactMap { Int($0) }
        guard let first = values.first, let last = values.last else { return false }
        return first > last
    }

    static let sheets: [String: [SeatMap]] = {
        guard let url = Bundle.module.url(forResource: "SeatMaps", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return [:] }
        return parse(data)
    }()

    static func parse(_ data: Data) -> [String: [SeatMap]] {
        guard let file = try? JSONDecoder().decode([String: SheetFile].self, from: data) else { return [:] }
        return file.reduce(into: [:]) { result, entry in
            result[entry.key] = entry.value.coaches.map { coach in
                SeatMap(sheet: entry.key, numbers: coach.numbers, title: coach.title, type: coach.type,
                        imageName: coach.image, aspectRatio: coach.aspect, seats: coach.seats.map(\.seat))
            }
        }
    }

    private struct SheetFile: Decodable {
        var coaches: [CoachFile]
    }

    private struct CoachFile: Decodable {
        var numbers: [String]
        var title: String?
        var type: String?
        var image: String
        var aspect: Double
        var seats: [SeatRow]
    }

    /// `["45", x, y, width, height]`
    private struct SeatRow: Decodable {
        var seat: Seat

        init(from decoder: Decoder) throws {
            var row = try decoder.unkeyedContainer()
            seat = Seat(number: try row.decode(String.self), x: try row.decode(Double.self), y: try row.decode(Double.self),
                        width: try row.decode(Double.self), height: try row.decode(Double.self))
        }
    }
}

extension CoachSequence {
    /// The seat map of `coach`: only in bahn.de's Wagenreihung (not vagonweb's plan) and only for the ICE
    /// series DB draws.
    public func seatMap(for coach: Coach) -> SeatMap? {
        guard source == .bahnDe, coach.isPassengerCoach, let number = coach.number, groups.indices.contains(coach.group),
              let sheet = groups[coach.group].seatMapSheet else { return nil }
        return SeatMap.coach(number, sheet: sheet)
    }
}

extension CoachSequence {
    /// A made-up Wagenreihung of one trainset of `sheet` with its coaches in the sheet's order, on a platform
    /// with sectors, for trying the seat maps without a real train (the app's `-seedSeatMapTrips`). `turned`
    /// stands it with the higher coach numbers on the left; the train leaves to the left either way.
    public static func seatMapDemo(sheet: String, trainName: String, unit: TrainFormation.Unit, turned: Bool = false) -> CoachSequence? {
        guard let maps = SeatMap.sheets[sheet], !maps.isEmpty else { return nil }
        let coachLength = 26.0
        // Lower numbers on the left, as the sheets draw them.
        var leftToRight = maps.sorted { (Int($0.numbers[0]) ?? 0) < (Int($1.numbers[0]) ?? 0) }
        if turned { leftToRight.reverse() }
        // The ICE 1 and 2 have power cars at their ends.
        let powerCars = sheet.hasPrefix("401") ? 2 : sheet == "402" ? 1 : 0
        var coaches: [Coach] = []
        func add(_ kind: Coach.Kind, number: String?, firstClass: Bool = false) {
            let start = 10 + Double(coaches.count) * coachLength
            coaches.append(Coach(id: coaches.count, number: number, kind: kind, firstClass: firstClass,
                                 secondClass: kind != .diningCar && !firstClass, closed: false, amenities: [], bikeSpaces: nil,
                                 start: start, end: start + coachLength, sector: nil, group: 0))
        }
        if powerCars > 0 { add(.powerCar, number: nil) }
        for map in leftToRight {
            let title = map.title ?? ""
            let kind: Coach.Kind = title.hasPrefix("Bordrestaurant") ? (map.seats.isEmpty ? .diningCar : .halfDiningCar) : .passenger
            add(kind, number: map.numbers[0], firstClass: title.hasPrefix("1.") || (kind == .halfDiningCar && title.contains("1.")))
        }
        if powerCars > 1 { add(.powerCar, number: nil) }
        let length = 20 + Double(coaches.count) * coachLength
        let sectorLength = length / 6
        let sectors = ["A", "B", "C", "D", "E", "F"].enumerated().map { index, name in
            Sector(name: name, start: Double(index) * sectorLength, end: Double(index + 1) * sectorLength)
        }
        for index in coaches.indices {
            let middle = (coaches[index].start! + coaches[index].end!) / 2
            coaches[index].sector = sectors.first { $0.start <= middle && middle < $0.end }?.name
        }
        return CoachSequence(platform: "7", platformLength: length, sectors: sectors,
                             groups: [Group(trainName: trainName, destination: nil, unit: unit, isRequestedTrain: true, seatMapSheet: sheet)],
                             coaches: coaches, travelsTowardsPlatformEnd: false, differsFromSchedule: false,
                             formation: TrainFormation(units: [unit]))
    }
}
