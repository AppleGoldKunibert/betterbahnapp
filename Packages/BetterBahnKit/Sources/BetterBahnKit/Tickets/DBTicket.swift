import Foundation

/// One ticket from a bahn.de order ("Auftrag"), as far as bahn.de describes it.
///
/// An order can hold several tickets ("Leistungsbündel"), e.g. a DB Sparpreis to Brussels plus a
/// Eurostar ticket issued by the partner. Each has its own PDF and barcode; partner tickets bahn.de
/// only hands out as separate documents (`isPartnerDocument`) aren't fetched.
public struct DBTicket: Codable, Sendable, Hashable, Identifiable {
    public enum Direction: String, Codable, Sendable {
        case outward, `return`

        public var displayName: String { self == .outward ? "Hinfahrt" : "Rückfahrt" }
    }

    public struct Traveller: Codable, Sendable, Hashable {
        /// DB's type, e.g. "ERWACHSENER", "KIND", "FAMILIENKIND".
        public var type: String
        public var count: Int
        /// e.g. ["BahnCard 50"].
        public var reductions: [String]

        public var displayName: String {
            let name = switch type {
            case "ERWACHSENER": count == 1 ? "Erwachsener" : "Erwachsene"
            case "KIND", "FAMILIENKIND": count == 1 ? "Kind" : "Kinder"
            case "JUGENDLICHER": "Jugendliche"
            case "SENIOR": "Senioren"
            default: type.capitalized
            }
            let base = "\(count) \(name)"
            return reductions.isEmpty ? base : base + " (" + reductions.joined(separator: ", ") + ")"
        }
    }

    public struct Leg: Codable, Sendable, Hashable {
        public var originName: String
        public var originEVA: String?
        public var destinationName: String
        public var destinationEVA: String?
        public var departure: Date
        public var arrival: Date
        /// As bahn.de names it, e.g. "ICE 652" or just "3343" for regional trains.
        public var trainName: String
        public var trainNumber: String?
        /// e.g. "RE3", nicer to show than a bare run number.
        public var displayName: String
        public var departurePlatform: String?
        public var arrivalPlatform: String?

        /// The train as a `Line`, for matching it against a journey's legs.
        var line: Line { Line(name: trainName, number: trainNumber, product: .other, operatorName: nil) }
    }

    public struct Seat: Codable, Sendable, Hashable {
        public var train: String
        public var coach: String
        public var seats: [String]

        /// "EUROSTAR 9149: Wagen 2, Platz 37, 38"
        public var description: String {
            "\(train): Wagen \(coach), Platz " + seats.joined(separator: ", ")
        }
    }

    /// What the barcode on the PDF holds.
    public struct Barcode: Codable, Sendable, Hashable {
        /// The Aztec code's bytes exactly as printed on DB's ticket (a UIC ticket barcode), if they
        /// could be read.
        public var payload: Data?
        /// The code as cut out of the PDF (PNG), shown when the bytes couldn't be read.
        public var image: Data?

        public init(payload: Data?, image: Data?) {
            self.payload = payload
            self.image = image
        }
    }

    public var id: String { orderNumber + "-" + bundleID }
    public var orderNumber: String
    /// bahn.de's "leistungsbuendelId", e.g. "EU1G8684".
    public var bundleID: String
    /// How bahn.de hands the ticket out ("52" = PDF), needed to fetch it.
    public var materialisationType: String
    /// Issued by a partner (e.g. Eurostar) as a separate document bahn.de doesn't give out directly.
    public var isPartnerDocument: Bool
    /// e.g. "EUROSTAR" for partner tickets.
    public var issuer: String?
    /// e.g. "Sparpreis Europa".
    public var offerName: String
    /// 1 or 2; nil for tickets without a class.
    public var travelClass: Int?
    /// Only valid on the trains printed on it.
    public var isTrainBound: Bool
    /// bahn.de's short conditions, e.g. "Zugbindung", "Stornierung vor 1. Geltungstag kostenpflichtig".
    public var conditions: [String]
    public var travellers: [Traveller]
    public var validFrom: Date?
    public var validUntil: Date?
    public var direction: Direction
    /// Where the ticket is valid, e.g. "Bernau(b Berlin)" → "Bruxelles Midi".
    public var validOrigin: String
    public var validDestination: String
    /// The trains this ticket covers.
    public var legs: [Leg]
    /// Every train of the booked connection in this direction, including other tickets' parts –
    /// what the saved journey has to match.
    public var connection: [Leg]
    public var seats: [Seat]
    public var barcode: Barcode?
    public var fetchedAt: Date
    /// Only seat reservations, no ticket (e.g. booked with a BahnCard 100). Optional so tickets saved
    /// before this existed still load.
    public var reservationOnly: Bool?

    /// Only seat reservations: the ticket to travel with is separate.
    public var isReservationOnly: Bool { reservationOnly ?? false }

    /// "1. Klasse"
    public var classDescription: String? { travelClass.map { "\($0). Klasse" } }

    public var routeDescription: String {
        "\(Station.displayName(for: validOrigin)) → \(Station.displayName(for: validDestination))"
    }
}
