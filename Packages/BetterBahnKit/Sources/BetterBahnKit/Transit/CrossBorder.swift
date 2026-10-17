import Foundation

extension Station {
    /// ISO country code ("DE", "CZ") when the stop ID or EVA number tells: a 7-digit EVA/UIC number
    /// ("8000207", "000005400003" in DELFI, "cz:0:5455659:1:1" in ÖBB's), an IFOPT prefix ("at:43:1")
    /// or a CZPTT stop. `nil` if the feed gives none of these.
    var countryCode: String? {
        if let code = TrainSearchCountry.code(eva: evaNumber) { return code }
        if id.hasPrefix(TransitousProvider.czechTimetableFeed) { return "CZ" }
        // Transitous names its feeds after their country: "at-Railway-…", "gb-great-britain", "de-DELFI".
        // The Eurostar feed covers several countries, so it says nothing.
        let feed = id.prefix { $0.isLetter }
        if feed.count == 2, !id.contains("eurostar"), TrainSearchCountry.uicCodes.values.contains(feed.uppercased()) {
            return feed.uppercased()
        }
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
    /// Stops abroad the Deutschlandticket officially reaches, by name; the BahnCard 100 includes the Deutschlandticket, so it reaches the same (bus-und-bahn.de/deutschlandticket/grenzverkehr).
    /// Not Basel SBB and not Strasbourg. Basel Bad Bf is DB's own and counts as German anyway.
    static let deutschlandticketStops: [String] = [
        "Venlo", "Arnhem", "Enschede", "Hengelo", "Vaals", "Kerkrade",
        "Salzburg Hbf", "Kufstein", "Ehrwald", "Reutte",
        "Basel Bad", "Schaffhausen",
        "Wissembourg", "Lauterbourg", "Sarreguemines", "Saargemünd",
        "Świnoujście", "Swinoujscie", "Zgorzelec", "Krzewina Zgorzelecka",
        "Hrádek nad Nisou", "Hradek nad Nisou", "Vejprty", "Varnsdorf",
        "Tønder", "Tonder", "Kelmis",
    ]

    private static func fold(_ name: String) -> String {
        Station.normalize(name.folding(options: .diacriticInsensitive, locale: nil))
    }

    /// Big stations abroad on international trains. Transitous' Eurostar stops carry no country in their
    /// ID, so `countryCode` can't tell them; matched by name, folded as `fold` does.
    static let foreignStationNames: [String] = [
        "bruxelles", "brussel", "brussels", "paris", "london", "pancras", "amsterdam", "lille", "rotterdam", "calais",
        "ebbsfleet", "ashford international",
    ]

    /// Whether `station` is known to be outside Germany and not one of `covered` (matched by name start).
    static func isAbroad(_ station: Station, covered: [String]) -> Bool {
        let name = fold(station.name)
        let abroad = station.countryCode.map { $0 != "DE" } ?? foreignStationNames.contains { name.contains($0) }
        return abroad && !covered.contains { name.hasPrefix(fold($0)) }
    }

    /// Whether a ride starts or ends abroad, so the ticket does not cover all of it.
    static func runsAbroad(_ leg: Leg, covered: [String]) -> Bool {
        !leg.isWalking && (isAbroad(leg.origin, covered: covered) || isAbroad(leg.destination, covered: covered))
    }
}
