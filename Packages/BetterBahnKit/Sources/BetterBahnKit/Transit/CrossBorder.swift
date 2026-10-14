import Foundation

extension Station {
    /// ISO country code ("DE", "CZ") when the stop ID or EVA number tells: a 7-digit EVA/UIC number
    /// ("8000207", "000005400003" in DELFI, "cz:0:5455659:1:1" in ÖBB's), an IFOPT prefix ("at:43:1")
    /// or a CZPTT stop. `nil` if the feed gives none of these.
    var countryCode: String? {
        if let code = TrainSearchCountry.code(eva: evaNumber) { return code }
        if id.hasPrefix(TransitousProvider.czechTimetableFeed) { return "CZ" }
        let local = id.split(separator: "_", maxSplits: 1).last ?? Substring(id)
        let parts = local.split(separator: ":")
        for part in parts where part.allSatisfy(\.isNumber) {
            let digits = part.drop { $0 == "0" }
            if digits.count == 7, let code = TrainSearchCountry.uicCodes[String(digits.prefix(2))] { return code }
        }
        if parts.count > 1, let first = parts.first?.uppercased(),
           TrainSearchCountry.uicCodes.values.contains(first) {
            return first
        }
        return nil
    }
}

/// Where a Deutschlandticket or BahnCard 100 stops being valid: at the border.
enum CrossBorder {
    /// Border stations both tickets reach (normalized names, see `Station.normalize`).
    static let coveredStations: [String] = ["salzburghbf", "kufstein"]

    /// Whether `station` is known to be outside Germany and not one of the `coveredStations`.
    static func isAbroad(_ station: Station) -> Bool {
        guard let code = station.countryCode, code != "DE" else { return false }
        let name = Station.normalize(station.name)
        return !coveredStations.contains { name.hasPrefix($0) }
    }

    /// Whether a ride starts or ends abroad, so the ticket does not cover all of it.
    static func runsAbroad(_ leg: Leg) -> Bool {
        !leg.isWalking && (isAbroad(leg.origin) || isAbroad(leg.destination))
    }
}
