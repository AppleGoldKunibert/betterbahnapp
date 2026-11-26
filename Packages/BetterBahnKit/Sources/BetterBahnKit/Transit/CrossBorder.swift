import Foundation

extension Station {
    /// ISO country code ("DE", "CZ") when the stop ID or EVA number tells: a 7-digit EVA/UIC number
    /// ("8000207", "000005400003" in DELFI, "cz:0:5455659:1:1" in ÖBB's), an IFOPT prefix ("at:43:1")
    /// or a CZPTT stop; the source's own `country` comes first. `nil` if the feed gives none of these.
    var countryCode: String? {
        if let country { return country.uppercased() }
        if let code = TrainSearchCountry.code(eva: evaNumber) { return code }
        if id.hasPrefix(TransitousProvider.czechTimetableFeed) { return "CZ" }
        let parts = Self.feedStopID(id).split(separator: ":")
        for part in parts where part.allSatisfy(\.isNumber) {
            let digits = part.drop { $0 == "0" }
            if digits.count == 7, let code = TrainSearchCountry.uicCodes[String(digits.prefix(2))] { return code }
        }
        if parts.count > 1, let first = parts.first?.uppercased(),
           TrainSearchCountry.uicCodes.values.contains(first) {
            return first
        }
        // Transitous names its feeds after their country: "at-Railway-…", "gb-great-britain", "de-DELFI".
        // The Eurostar feed covers several countries, so it says nothing. A DELFI ID of a stop abroad
        // ("de-DELFI_at:49:1349") was already read from its own "at:" above.
        let feed = id.prefix { $0.isLetter }
        if feed.count == 2, !id.contains("eurostar"), TrainSearchCountry.uicCodes.values.contains(feed.uppercased()) {
            return feed.uppercased()
        }
        return nil
    }

    /// The feed's own ID of a Transitous stop, without the feed in front: "de:11000:900003201" for
    /// "de-DELFI_de:11000:900003201". ÖBB's reference data marks a parent station with a "P" before its
    /// IFOPT ("at-Railway-…_Pde:11000:900058101", Berlin Südkreuz), which is left out, so the stop reads
    /// as German and not as the feed's Austria.
    static func feedStopID(_ id: String) -> Substring {
        let local = id.split(separator: "_", maxSplits: 1).last ?? Substring(id)
        guard local.first == "P", let colon = local.firstIndex(of: ":") else { return local }
        let country = local[local.index(after: local.startIndex)..<colon]
        guard country.count == 2, country.allSatisfy(\.isLowercase),
              TrainSearchCountry.uicCodes.values.contains(country.uppercased()) else { return local }
        return local.dropFirst()
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
