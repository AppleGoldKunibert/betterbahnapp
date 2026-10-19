import Foundation

/// What the user takes along, picked in the settings: nothing to show, a folding bike or a normal bike. A folded
/// folding bike counts as luggage everywhere, a normal bike needs a space, often a reservation and a bike ticket.
public enum BikeOption: String, Codable, Sendable, CaseIterable, Hashable {
    case hidden
    case foldingBike
    case bike

    public var displayName: String {
        switch self {
        case .hidden: "Ausblenden"
        case .foldingBike: "Klapprad"
        case .bike: "Fahrrad"
        }
    }

    /// The search option's title: "Mit Klapprad", "Mit Fahrrad".
    public var searchTitle: String? {
        switch self {
        case .hidden: nil
        case .foldingBike: "Mit Klapprad"
        case .bike: "Mit Fahrrad"
        }
    }
}

/// Whether a bike can come along on a train, for the search option "Mit Fahrrad" (#398), and what it needs: a
/// reservation, a bike ticket, or nothing.
///
/// Transitous can't tell: DELFI's German trains all come back `bikesAllowed: false` (tested 2026-10-19), also the
/// RE 3 that takes bikes, and `requireBikeTransport` found nothing for Berlin Hbf → Eberswalde. So bahn.de's train
/// attributes decide (`BahnDeClient.bikeTransport(for:)`), DB's notices on the leg can rule bikes out for the day,
/// a train without bike spaces takes none (`hasBikeSpaces`), and where bahn.de says nothing the rules `rule(for:)`
/// stand in: long-distance trains need DB's Fahrradkarte Fernverkehr with a reservation, regional trains the
/// Verbund's bike ticket (`BikeTariff`). A folded folding bike rides free as luggage everywhere.
public struct BikeTransport: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        /// Bikes come along without a reservation.
        case allowed
        /// Bikes come along while there is room ("Fahrradmitnahme begrenzt möglich").
        case limited
        /// Only with a bike reservation ("Fahrradmitnahme reservierungspflichtig").
        case reservationRequired
        /// No bikes on this train.
        case notAllowed
        /// A folded folding bike, free as luggage.
        case luggage
    }

    public var kind: Kind
    /// The part of the leg this holds for, as bahn.de names it ("Basel SBB – Zürich HB"); nil for all of it.
    public var section: String?
    /// Whether bahn.de or DB said so, rather than the rules.
    public var isConfirmed: Bool
    /// The bike ticket needed, e.g. "VBB 24-Stunden-Karte Fahrrad (ab 5,10 €)"; nil where the bike rides free.
    public var ticket: String?
    /// What else to know: "Nur Mo–Fr 6–9 Uhr kostenpflichtig", "Dieser Zug hat keine Fahrradstellplätze".
    public var note: String?

    public init(kind: Kind, section: String? = nil, isConfirmed: Bool, ticket: String? = nil, note: String? = nil) {
        self.kind = kind
        self.section = section
        self.isConfirmed = isConfirmed
        self.ticket = ticket
        self.note = note
    }

    public var needsReservation: Bool { kind == .reservationRequired }

    /// "Fahrrad nur mit Reservierung", with "meist" where only the rules say so.
    public var title: String {
        switch kind {
        case .allowed: ticket == nil ? "Fahrrad kostenlos" : "Fahrrad mit Fahrradkarte"
        case .limited: "Fahrradmitnahme begrenzt möglich"
        case .reservationRequired: isConfirmed ? "Fahrrad nur mit Reservierung" : "Fahrrad meist nur mit Reservierung"
        case .notAllowed: "Keine Fahrradmitnahme"
        case .luggage: "Klapprad zusammengeklappt kostenlos"
        }
    }

    /// The rules where bahn.de has nothing: long-distance trains (ICE, IC/EC, night trains, FLX) take bikes only with a
    /// reservation where they take them at all, with DB's Fahrradkarte Fernverkehr in Germany; regional trains and
    /// S-Bahns in Germany without one, with the ticket the Verbund asks for at the leg's departure (`BikeTariff`).
    /// Nil for anything else (buses, trams, regional trains abroad): no guess there.
    public static func rule(for leg: Leg) -> BikeTransport? {
        guard !leg.isWalking, let line = leg.line else { return nil }
        if line.product.isLongDistance || line.isNightTrain {
            let inGermany = StationNames.isGerman(leg.origin) && StationNames.isGerman(leg.destination)
            return BikeTransport(kind: .reservationRequired, isConfirmed: false,
                                 ticket: inGermany ? fernverkehrTicket : "Fahrradkarte")
        }
        switch line.product {
        case .regionalExpress, .regional, .suburban:
            guard let origin = StationNames.district(of: leg.origin), let destination = StationNames.district(of: leg.destination)
            else { return nil }
            return BikeTariff.tariff(from: origin, to: destination).transport(for: line.product, departure: leg.departure.planned)
        default:
            return nil
        }
    }

    static let fernverkehrTicket = "Fahrradkarte Fernverkehr (ab 7,99 €, mit Reservierung)"

    /// What to show for `leg` with `bike`. A folding bike rides as luggage on every train. For a normal bike: DB's
    /// notice "Fahrradmitnahme nicht möglich" on the leg first (it concerns this very day), then a train without bike
    /// spaces (`hasBikeSpaces` false), then bahn.de's attributes, else the rules; bahn.de's answer keeps the rules'
    /// ticket. "Eingeschränkte Fahrradmitnahme" limits a train that takes bikes, but never lifts a reservation.
    public static func resolved(bahnDe: BikeTransport?, for leg: Leg, bike: BikeOption = .bike,
                                hasBikeSpaces: Bool? = nil) -> BikeTransport? {
        guard !leg.isWalking, leg.line != nil, bike != .hidden else { return nil }
        if bike == .foldingBike { return BikeTransport(kind: .luggage, isConfirmed: true) }
        let texts = Set(leg.messages.map(\.text))
        if texts.contains(TrainMessageCodes.noBikesText) { return BikeTransport(kind: .notAllowed, isConfirmed: true) }
        if hasBikeSpaces == false {
            return BikeTransport(kind: .notAllowed, isConfirmed: true, note: "Dieser Zug hat keine Fahrradstellplätze")
        }
        let rule = rule(for: leg)
        guard var transport = bahnDe ?? rule else { return nil }
        if bahnDe != nil, transport.kind != .notAllowed {
            transport.ticket = rule?.ticket
            if transport.note == nil { transport.note = rule?.note }
        }
        if texts.contains(TrainMessageCodes.limitedBikesText), transport.kind == .allowed {
            transport.kind = .limited
            transport.isConfirmed = true
        }
        return transport
    }

    /// Series without any bike spaces: ICE 1, ICE 2 and ICE 3 (BR 403/406, Velaro BR 407), also redesigned. The
    /// 5-car ICE T (BR 415) has none either, but shares its name with the 7-car one (BR 411, 3 spaces since 2019).
    static let familiesWithoutBikes: Set<String> = ["ICE 1", "ICE 2", "ICE 3", "ICE 3 Velaro"]

    /// Whether `line`'s train has bike spaces at all, nil when that isn't known: yes once its Wagenreihung shows a
    /// coach with bike spaces; no for an ICE whose Wagenreihung from bahn.de shows none (also the ICE T BR 415), or
    /// whose trainsets are all of a series without (`familiesWithoutBikes`, from the formation or the planned train type).
    /// vagonweb's plan only ever says yes: its coaches don't always list bike spaces.
    public static func hasBikeSpaces(line: Line?, families: [String], sequence: CoachSequence?) -> Bool? {
        guard let line, line.product.isLongDistance else { return nil }
        let isICE = line.name.uppercased().hasPrefix("ICE")
        if let sequence, sequence.coaches.contains(where: \.isPassengerCoach) {
            if !sequence.bikeCoaches.isEmpty { return true }
            if isICE, sequence.source == .bahnDe { return false }
        }
        guard isICE, !families.isEmpty else { return nil }
        return families.allSatisfy(familiesWithoutBikes.contains) ? false : nil
    }

    /// One of bahn.de's bike attributes, read by its key and else by its wording, since bahn.de's full list of
    /// keys isn't known: "FR" (Fahrradmitnahme reservierungspflichtig, on Nightjet NJ 471 2026-10-08) and "FB"
    /// (begrenzt möglich, as in HAFAS). Nil for any other attribute.
    static func kind(ofAttribute key: String?, category: String?, value: String?) -> Kind? {
        switch key {
        case "FR": return .reservationRequired
        case "FB": return .limited
        default: break
        }
        let text = (value ?? "").lowercased()
        guard category == "FAHRRADMITNAHME" || text.hasPrefix("fahrradmitnahme") || text.hasPrefix("fahrradbeförderung")
        else { return nil }
        if text.contains("reservierungspflicht") { return .reservationRequired }
        if text.contains("nicht") || text.contains("keine") { return .notAllowed }
        if text.contains("begrenzt") || text.contains("eingeschränkt") { return .limited }
        return .allowed
    }

    /// The strictest of several (for different sections of the train): a needed reservation first, as that is
    /// what the warning on saving is about.
    static func strictest(_ transports: [BikeTransport]) -> BikeTransport? {
        let order: [Kind] = [.reservationRequired, .notAllowed, .limited, .allowed, .luggage]
        return transports.min { order.firstIndex(of: $0.kind)! < order.firstIndex(of: $1.kind)! }
    }
}

extension TrainMessageCodes {
    /// The texts of codes 91 and 92 (`texts`), which `BikeTransport.resolved(bahnDe:for:)` looks for on a leg.
    static var noBikesText: String { text(for: 91)! }
    static var limitedBikesText: String { text(for: 92)! }
}

// MARK: - Coaches with bike spaces

extension CoachSequence {
    /// A coach with bike spaces and the platform sectors it stands in.
    public struct BikeCoach: Sendable, Hashable, Identifiable {
        /// `Coach.id`, for highlighting it.
        public var id: Int
        public var number: String?
        public var spaces: Int?
        public var sectors: [String]
    }

    /// The coaches with bike spaces of the parts that run as the requested train, front first.
    public var bikeCoaches: [BikeCoach] {
        let parts = Set(groups.indices.filter { groups[$0].isRequestedTrain })
        return coaches.filter { coach in
            coach.amenities.contains(.bikeSpace) && !coach.closed && (parts.isEmpty || parts.contains(coach.group))
        }
        .map { BikeCoach(id: $0.id, number: $0.number, spaces: $0.bikeSpaces, sectors: sectors(of: $0)) }
    }

    /// The sectors where the bike coaches stop, in platform order, for highlighting them.
    public var bikeSectors: [String] {
        let names = Set(bikeCoaches.flatMap(\.sectors))
        return sectors.map(\.name).filter(names.contains)
    }

    /// "Wagen 1 und 7 · Abschnitt A, E", for the Wagenreihung in bike mode; nil without bike coaches.
    public var bikeCoachSummary: String? {
        let coaches = bikeCoaches
        guard !coaches.isEmpty else { return nil }
        let numbers = coaches.compactMap(\.number)
        let sectors = bikeSectors
        var parts: [String] = []
        if !numbers.isEmpty { parts.append("Wagen " + Self.germanList(numbers)) }
        if !sectors.isEmpty { parts.append("Abschnitt " + sectors.joined(separator: ", ")) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// "1", "1 und 7", "1, 7 und 12".
    private static func germanList(_ items: [String]) -> String {
        guard items.count > 1 else { return items.first ?? "" }
        return items.dropLast().joined(separator: ", ") + " und " + items.last!
    }
}
