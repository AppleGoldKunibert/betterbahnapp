import Foundation

/// Reads the order bahn.de's "Auftragssuche" returns (`GET /web/api/buchung/auftrag/{nr}`) into
/// `DBTicket`s.
///
/// bahn.de only answers that request after the traveller solved a captcha on its own page, so the
/// app never calls it itself: `DBOrderPage` runs it inside bahn.de's page and hands the JSON over.
public enum DBOrder {
    public enum ReadError: Error, Sendable, Equatable, LocalizedError {
        case unreadable
        case noTickets

        public var errorDescription: String? {
            switch self {
            case .unreadable: "Die Buchung konnte nicht gelesen werden."
            case .noTickets: "In dieser Buchung ist kein Ticket enthalten."
            }
        }
    }

    /// Every ticket of the order, outward journey first.
    public static func tickets(from data: Data, orderNumber: String, barcodes: [String: DBTicket.Barcode] = [:],
                               fetchedAt: Date = .now) throws -> [DBTicket] {
        let order: Response
        do {
            order = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw ReadError.unreadable
        }
        let infos = Dictionary((order.ticketMaterialisierungsInfos ?? []).map { ($0.leistungsbuendelId, $0) },
                               uniquingKeysWith: { first, _ in first })
        var tickets: [DBTicket] = []
        for (direction, part) in [(DBTicket.Direction.outward, order.gesamtangebot?.hinfahrt),
                                  (.return, order.gesamtangebot?.rueckfahrt)] {
            guard let part else { continue }
            let connection = (part.verbindung?.verbindungsAbschnitte ?? []).compactMap(Self.leg)
            let seatSections = (part.sitzplatzAngebote ?? []).flatMap { $0.abschnitte ?? [] }
            let seats = seatSections.compactMap(\.reservierung).map(Self.seat)
            for offer in part.angebote ?? [] where offer.isStorniert != true {
                guard let bundle = offer.leistungsbuendelId else { continue }
                let info = infos[bundle]
                let conditions = (offer.konditionsAnzeigen ?? []).sorted { ($0.prioritaet ?? 99) < ($1.prioritaet ?? 99) }
                    .compactMap(\.textKurz)
                let origin = offer.gueltigkeitsstrecke?.abgangsbahnhofName ?? connection.first?.originName ?? ""
                let destination = offer.gueltigkeitsstrecke?.zielbahnhofName ?? connection.last?.destinationName ?? ""
                let covered = Self.legs(of: connection, from: origin, to: destination)
                let coveredTrains = Set(covered.compactMap(\.trainNumber))
                tickets.append(DBTicket(
                    orderNumber: orderNumber,
                    bundleID: bundle,
                    materialisationType: info?.materialisierungsArtId ?? "",
                    isPartnerDocument: info?.multiDokument ?? false,
                    issuer: offer.issuer,
                    offerName: offer.name ?? "Ticket",
                    travelClass: offer.klasse.flatMap(Self.travelClass),
                    isTrainBound: conditions.contains { $0.localizedCaseInsensitiveContains("Zugbindung") },
                    conditions: conditions,
                    travellers: (offer.reisende ?? []).map(Self.traveller),
                    validFrom: part.zeitlicheGueltigkeit?.ersterGeltungszeitpunkt.flatMap(JSONDecoding.parseISODate),
                    validUntil: part.zeitlicheGueltigkeit?.letzterGeltungszeitpunkt.flatMap(JSONDecoding.parseISODate),
                    direction: direction,
                    validOrigin: origin,
                    validDestination: destination,
                    legs: covered,
                    connection: connection,
                    seats: seats.filter { seat in coveredTrains.contains { seat.train.hasSuffix($0) } },
                    barcode: barcodes[bundle],
                    fetchedAt: fetchedAt))
            }
            // Reservations booked on their own (e.g. with a BahnCard 100 or from a contingent) have no
            // ticket offer, only seat offers with their own "Leistungsbündel".
            let ticketBundles = Set((part.angebote ?? []).compactMap(\.leistungsbuendelId))
            var reservationBundles: [String] = []
            for section in seatSections {
                guard let bundle = section.angebot?.leistungsbuendelId, section.angebot?.isStorniert != true,
                      !ticketBundles.contains(bundle), !reservationBundles.contains(bundle) else { continue }
                reservationBundles.append(bundle)
            }
            for bundle in reservationBundles {
                let sections = seatSections.filter { $0.angebot?.leistungsbuendelId == bundle }
                let offers = sections.compactMap(\.angebot)
                let fee = (part.sitzplatzAngebote ?? []).first { ($0.abschnitte ?? []).contains { $0.angebot?.leistungsbuendelId == bundle } }?.angebot
                let info = infos[bundle]
                let origin = offers.first?.gueltigkeitsstrecke?.abgangsbahnhofName ?? connection.first?.originName ?? ""
                let destination = offers.last?.gueltigkeitsstrecke?.zielbahnhofName ?? connection.last?.destinationName ?? ""
                let conditions = (offers.first?.konditionsAnzeigen ?? []).sorted { ($0.prioritaet ?? 99) < ($1.prioritaet ?? 99) }
                    .compactMap(\.textKurz)
                tickets.append(DBTicket(
                    orderNumber: orderNumber,
                    bundleID: bundle,
                    materialisationType: info?.materialisierungsArtId ?? "",
                    isPartnerDocument: info?.multiDokument ?? false,
                    issuer: nil,
                    offerName: fee?.name ?? offers.first?.name ?? "Sitzplatzreservierung",
                    travelClass: offers.first?.klasse.flatMap(Self.travelClass),
                    isTrainBound: false,
                    conditions: conditions,
                    travellers: (offers.first?.reisende ?? []).map(Self.traveller),
                    validFrom: part.zeitlicheGueltigkeit?.ersterGeltungszeitpunkt.flatMap(JSONDecoding.parseISODate),
                    validUntil: part.zeitlicheGueltigkeit?.letzterGeltungszeitpunkt.flatMap(JSONDecoding.parseISODate),
                    direction: direction,
                    validOrigin: origin,
                    validDestination: destination,
                    legs: connection,
                    connection: connection,
                    seats: sections.compactMap(\.reservierung).map(Self.seat),
                    barcode: barcodes[bundle],
                    fetchedAt: fetchedAt,
                    reservationOnly: true))
            }
        }
        guard !tickets.isEmpty else { throw ReadError.noTickets }
        return tickets
    }

    /// The legs between the ticket's first and last station (matched by name, as bahn.de only names
    /// them); all legs if the names can't be found.
    static func legs(of connection: [DBTicket.Leg], from origin: String, to destination: String) -> [DBTicket.Leg] {
        let start = Station.normalize(origin), end = Station.normalize(destination)
        guard let first = connection.firstIndex(where: { Station.normalize($0.originName) == start }),
              let last = connection[first...].firstIndex(where: { Station.normalize($0.destinationName) == end })
        else { return connection }
        return Array(connection[first...last])
    }

    // MARK: - Mapping

    private static func leg(_ section: Section) -> DBTicket.Leg? {
        // Walks ("Übergang", "Fußweg") aren't trains the ticket covers. Kept as legs, the import would
        // look for a train leaving at the walk's time and could ride along on any one, e.g. the Ring.
        guard !walkTypes.contains(section.verkehrsmittel?.typ ?? section.typ ?? ""),
              let originName = section.startHalt?.name ?? section.abfahrtsOrt,
              let destinationName = section.zielHalt?.name ?? section.ankunftsOrt else { return nil }
        let originEVA = section.startHalt?.extId ?? section.abfahrtsOrtExtId
        let destinationEVA = section.zielHalt?.extId ?? section.ankunftsOrtExtId
        guard let departure = (section.abfahrt ?? section.startHalt?.abfahrt)?.sollzeit.flatMap({ localDate($0, eva: originEVA) }),
              let arrival = (section.ankunft ?? section.zielHalt?.ankunft)?.sollzeit.flatMap({ localDate($0, eva: destinationEVA) })
        else { return nil }
        let vehicle = section.verkehrsmittel
        let name = vehicle?.name ?? vehicle?.mittelText ?? ""
        return DBTicket.Leg(
            originName: originName, originEVA: originEVA,
            destinationName: destinationName, destinationEVA: destinationEVA,
            departure: departure, arrival: arrival,
            trainName: name, trainNumber: vehicle?.nummer,
            displayName: vehicle?.mittelText ?? name,
            departurePlatform: section.halte?.first?.gleis,
            arrivalPlatform: (section.halte?.count ?? 0) > 1 ? section.halte?.last?.gleis : nil)
    }

    /// bahn.de's types for sections that are walked, not ridden.
    static let walkTypes: Set<String> = ["TRANSFER", "WALK", "FUSSWEG"]

    private static func seat(_ reservation: Reservation) -> DBTicket.Seat {
        let train = reservation.zugname ?? [reservation.zugtyp, reservation.zugnummer].compactMap(\.self).joined(separator: " ")
        let coaches = reservation.wagen ?? []
        return DBTicket.Seat(
            train: train,
            coach: coaches.compactMap(\.wagennummer).joined(separator: ", "),
            seats: coaches.flatMap { $0.plaetze ?? [] }.compactMap { place -> String? in
                guard let from = place.vonPlatz else { return nil }
                guard let to = place.bisPlatz, to != from else { return from }
                return "\(from)–\(to)"
            }
            // bahn.de lists seats in booking order ("106, 103, 105").
            .sorted { (Int($0) ?? .max, $0) < (Int($1) ?? .max, $1) })
    }

    private static func traveller(_ traveller: Traveller) -> DBTicket.Traveller {
        let reductions = (traveller.ermaessigungen ?? []).compactMap { reduction -> String? in
            guard let art = reduction.art, art != "KEINE_ERMAESSIGUNG" else { return nil }
            return reductionName(art)
        }
        var unique: [String] = []
        for reduction in reductions where !unique.contains(reduction) { unique.append(reduction) }
        return DBTicket.Traveller(type: traveller.typ ?? "", count: traveller.anzahl ?? 1, reductions: unique)
    }

    /// "BAHNCARD50" → "BahnCard 50"
    static func reductionName(_ art: String) -> String {
        if art.hasPrefix("BAHNCARDBUSINESS") { return "BahnCard Business " + art.dropFirst("BAHNCARDBUSINESS".count) }
        if art.hasPrefix("BAHNCARD") { return "BahnCard " + art.dropFirst("BAHNCARD".count) }
        return art.replacingOccurrences(of: "_", with: " ").capitalized
    }

    static func travelClass(_ klasse: String) -> Int? {
        switch klasse {
        case "KLASSE_1": 1
        case "KLASSE_2": 2
        default: nil
        }
    }

    /// bahn.de gives times as local wall-clock times without a zone, in the station's own time zone
    /// (e.g. London St. Pancras in UK time). EVA numbers start with the UIC country code.
    static func localDate(_ string: String, eva: String?) -> Date? {
        let parts = string.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        guard parts.count >= 5 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone(forEVA: eva)
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2],
                                                  hour: parts[3], minute: parts[4], second: parts.count > 5 ? parts[5] : 0))
    }

    static func timeZone(forEVA eva: String?) -> TimeZone {
        let zone = switch eva?.prefix(2) {
        case "70": "Europe/London"
        case "60": "Europe/Dublin"
        case "94": "Europe/Lisbon"
        case "10": "Europe/Helsinki"
        case "24", "25", "26": "Europe/Vilnius" // Lithuania, Latvia, Estonia
        case "73": "Europe/Athens"
        case "52": "Europe/Sofia"
        case "53": "Europe/Bucharest"
        default: "Europe/Berlin"
        }
        return TimeZone(identifier: zone) ?? TimeZone(identifier: "Europe/Berlin")!
    }

    // MARK: - Response

    struct Response: Decodable {
        var gesamtangebot: Offers?
        var ticketMaterialisierungsInfos: [MaterialisationInfo]?
    }

    struct Offers: Decodable {
        var hinfahrt: Part?
        var rueckfahrt: Part?
    }

    struct Part: Decodable {
        var angebote: [Offer]?
        var sitzplatzAngebote: [SeatOffer]?
        var verbindung: Connection?
        var zeitlicheGueltigkeit: Validity?
    }

    struct Offer: Decodable {
        var name: String?
        var klasse: String?
        var konditionsAnzeigen: [Condition]?
        var gueltigkeitsstrecke: ValidRoute?
        var leistungsbuendelId: String?
        var issuer: String?
        var isStorniert: Bool?
        var reisende: [Traveller]?
    }

    struct Condition: Decodable {
        var textKurz: String?
        var prioritaet: Int?
    }

    struct ValidRoute: Decodable {
        var abgangsbahnhofName: String?
        var zielbahnhofName: String?
    }

    struct Traveller: Decodable {
        struct Reduction: Decodable { var art: String? }
        var typ: String?
        var anzahl: Int?
        var ermaessigungen: [Reduction]?
    }

    struct SeatOffer: Decodable {
        struct Section: Decodable {
            var angebot: Offer?
            var reservierung: Reservation?
        }
        /// The fee for all seats, e.g. "Reservierung aus Kontingent".
        var angebot: Offer?
        var abschnitte: [Section]?
    }

    struct Reservation: Decodable {
        struct Coach: Decodable {
            struct Place: Decodable { var vonPlatz: String?; var bisPlatz: String? }
            var wagennummer: String?
            var plaetze: [Place]?
        }
        var zugtyp: String?
        var zugnummer: String?
        var zugname: String?
        var wagen: [Coach]?
    }

    struct Connection: Decodable {
        var verbindungsAbschnitte: [Section]?
    }

    struct Time: Decodable { var sollzeit: String? }

    struct Stop: Decodable {
        var extId: String?
        var name: String?
        var abfahrt: Time?
        var ankunft: Time?
        var gleis: String?
    }

    struct Vehicle: Decodable {
        var name: String?
        var nummer: String?
        var mittelText: String?
        var typ: String?
    }

    struct Section: Decodable {
        var abfahrtsOrt: String?
        var abfahrtsOrtExtId: String?
        var ankunftsOrt: String?
        var ankunftsOrtExtId: String?
        var startHalt: Stop?
        var zielHalt: Stop?
        var abfahrt: Time?
        var ankunft: Time?
        var halte: [Stop]?
        var verkehrsmittel: Vehicle?
        /// Some sections carry their type here instead of on `verkehrsmittel`.
        var typ: String?
    }

    struct Validity: Decodable {
        var ersterGeltungszeitpunkt: String?
        var letzterGeltungszeitpunkt: String?
    }

    struct MaterialisationInfo: Decodable {
        var leistungsbuendelId: String
        var materialisierungsArtId: String?
        var multiDokument: Bool?
    }
}

// MARK: - Saved journeys

extension DBTicket {
    /// The booked connection as a shared connection, so `DBShareImporter` can find it in the app's
    /// own timetable data.
    public var sharedConnection: SharedConnection? {
        guard let first = connection.first, let last = connection.last else { return nil }
        func station(_ name: String, _ eva: String?) -> Station {
            Station(id: eva ?? name, name: name, coordinate: nil, evaNumber: eva, source: .bahnDe)
        }
        return SharedConnection(
            origin: station(first.originName, first.originEVA),
            destination: station(last.destinationName, last.destinationEVA),
            departure: first.departure,
            arrival: last.arrival,
            legs: connection.map {
                SharedConnection.Leg(trainName: $0.trainName,
                                     origin: station($0.originName, $0.originEVA),
                                     destination: station($0.destinationName, $0.destinationEVA),
                                     departure: $0.departure, arrival: $0.arrival)
            },
            firstTrain: first.trainName,
            lastTrain: last.trainName)
    }

    /// Whether `journey` is the connection this ticket was booked for: same first departure and
    /// last arrival, riding the same first and last trains.
    public func matches(_ journey: Journey) -> Bool {
        guard var shared = sharedConnection else { return false }
        // Feeds split some rides differently (a through coach, a walk inside a station), so only the
        // ends and their trains have to agree, not every leg.
        shared.legs = []
        return DBShareImporter.fits(journey, shared) && DBShareImporter.ridesNamedTrains(journey, shared)
    }
}
