import Foundation

/// The ticket the connection filters check trains against.
public enum TicketType: String, Codable, Sendable, CaseIterable, Hashable {
    case deutschlandticket
    case bahnCard100

    public var displayName: String {
        switch self {
        case .deutschlandticket: "Deutschlandticket"
        case .bahnCard100: "BahnCard 100"
        }
    }

    /// Compact name for chips, e.g. "D-Ticket".
    public var shortName: String {
        switch self {
        case .deutschlandticket: "D-Ticket"
        case .bahnCard100: "BC100"
        }
    }
}

/// Decides whether a train can be used with the chosen ticket.
public enum TicketFilter: Sendable, Hashable {
    /// Local transport only: no ICE/IC/EC, no long-distance buses and no private long-distance trains.
    case deutschlandticket
    case bahnCard100(BC100Rules)

    public var type: TicketType {
        switch self {
        case .deutschlandticket: .deutschlandticket
        case .bahnCard100: .bahnCard100
        }
    }

    /// Products the Deutschlandticket never covers.
    static let excludedDeutschlandticketProducts: Set<Product> = [.highSpeed, .longDistance, .coach]

    /// Long-distance line prefixes, in case a provider files such a train under a regional product.
    static let excludedDeutschlandticketPrefixes: Set<String> = [
        "ICE", "IC", "EC", "ECE", "TGV", "RJ", "RJX", "NJ", "EN", "FLX", "ES", "EST", "THA", "WB",
    ]

    public func isValid(_ line: Line?) -> Bool {
        switch self {
        case .bahnCard100(let rules):
            return rules.isValid(line)
        case .deutschlandticket:
            guard let line else { return true } // walking
            if Self.excludedDeutschlandticketProducts.contains(line.product) { return false }
            // Only trains: city bus or tram lines can carry letters like "EN" or "RJ" too.
            guard line.product.isTrain else { return true }
            let prefix = line.name.split(separator: " ").first.map { String($0).uppercased() } ?? ""
            let letters = String(line.name.uppercased().prefix { $0.isLetter })
            return !Self.excludedDeutschlandticketPrefixes.contains(prefix)
                && !Self.excludedDeutschlandticketPrefixes.contains(letters)
        }
    }

    public func isValid(_ leg: Leg) -> Bool { leg.isWalking || isValid(leg.line) }
    public func isValid(_ journey: Journey) -> Bool { journey.legs.allSatisfy(isValid) }
    public func isValid(_ entry: BoardEntry) -> Bool { isValid(entry.line) }
}
