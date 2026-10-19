import Foundation

/// Whether a bike can come along on a train, for the search option "Mit Fahrrad" (#398).
///
/// Transitous can't tell: DELFI's German trains all come back `bikesAllowed: false` (tested 2026-10-19), also the
/// RE 3 that takes bikes, and `requireBikeTransport` found nothing for Berlin Hbf → Eberswalde. So bahn.de's train
/// attributes decide (`BahnDeClient.bikeTransport(for:)`), DB's notices on the leg can rule bikes out for the day,
/// and where bahn.de says nothing the rule of thumb `rule(for:)` stands in (`resolved(bahnDe:for:)`).
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
    }

    public var kind: Kind
    /// The part of the leg this holds for, as bahn.de names it ("Basel SBB – Zürich HB"); nil for all of it.
    public var section: String?
    /// Whether bahn.de or DB said so, rather than the rule of thumb.
    public var isConfirmed: Bool

    public init(kind: Kind, section: String? = nil, isConfirmed: Bool) {
        self.kind = kind
        self.section = section
        self.isConfirmed = isConfirmed
    }

    public var needsReservation: Bool { kind == .reservationRequired }

    /// "Fahrrad nur mit Reservierung", with "meist" where only the rule of thumb says so.
    public var title: String {
        switch kind {
        case .allowed: isConfirmed ? "Fahrradmitnahme möglich" : "Fahrradmitnahme meist ohne Reservierung"
        case .limited: "Fahrradmitnahme begrenzt möglich"
        case .reservationRequired: isConfirmed ? "Fahrrad nur mit Reservierung" : "Fahrrad meist nur mit Reservierung"
        case .notAllowed: "Keine Fahrradmitnahme"
        }
    }

    /// The rule of thumb where bahn.de has nothing: regional trains and S-Bahns in Germany take bikes without a
    /// reservation, long-distance trains (ICE, IC/EC, night trains, FLX) only with one where bikes are allowed
    /// at all. Nil for anything else (buses, trams, regional trains abroad): no guess there.
    public static func rule(for leg: Leg) -> BikeTransport? {
        guard !leg.isWalking, let line = leg.line else { return nil }
        if line.product.isLongDistance || line.isNightTrain {
            return BikeTransport(kind: .reservationRequired, isConfirmed: false)
        }
        switch line.product {
        case .regionalExpress, .regional, .suburban:
            guard StationNames.isGerman(leg.origin), StationNames.isGerman(leg.destination) else { return nil }
            return BikeTransport(kind: .allowed, isConfirmed: false)
        default:
            return nil
        }
    }

    /// What to show for `leg`: DB's notice "Fahrradmitnahme nicht möglich" on the leg first (it concerns this
    /// very day), then bahn.de's attributes, else the rule of thumb. "Eingeschränkte Fahrradmitnahme" limits
    /// a train that takes bikes, but never lifts a reservation.
    public static func resolved(bahnDe: BikeTransport?, for leg: Leg) -> BikeTransport? {
        let texts = Set(leg.messages.map(\.text))
        if texts.contains(TrainMessageCodes.noBikesText) { return BikeTransport(kind: .notAllowed, isConfirmed: true) }
        guard var transport = bahnDe ?? rule(for: leg) else { return nil }
        if texts.contains(TrainMessageCodes.limitedBikesText), transport.kind == .allowed {
            transport.kind = .limited
            transport.isConfirmed = true
        }
        return transport
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
        let order: [Kind] = [.reservationRequired, .notAllowed, .limited, .allowed]
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
