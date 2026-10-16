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

    /// Short name with its article in the dative, e.g. "dem D-Ticket" (for "Mit …").
    public var dativeShortName: String {
        switch self {
        case .deutschlandticket: "dem D-Ticket"
        case .bahnCard100: "der BC100"
        }
    }
}

/// Decides whether a train can be used with the chosen ticket.
public enum TicketFilter: Sendable, Hashable {
    /// Local transport only: no ICE/IC/EC, no long-distance buses, no private long-distance trains and
    /// nothing that starts or ends abroad (except the border stops in `CrossBorder`).
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

    /// Per leg, whether the train itself is valid (ignoring where the ride goes). With the BahnCard 100
    /// the operator list stops applying from the first station abroad on, so a foreign operator's
    /// train there counts.
    private func trainsValid(_ legs: [Leg]) -> [Bool] {
        var abroad = false
        return legs.map { leg in
            if !abroad, CrossBorder.isAbroad(leg.origin, covered: []) { abroad = true }
            switch self {
            case .bahnCard100(let rules): return rules.isValid(leg.line, abroad: abroad)
            case .deutschlandticket: return isValid(leg.line)
            }
        }
    }

    /// Valid if the train is and the ride stays in Germany (see `CrossBorder`).
    public func isValid(_ leg: Leg) -> Bool {
        trainsValid([leg])[0] && (leg.isWalking || !CrossBorder.runsAbroad(leg, covered: CrossBorder.deutschlandticketStops))
    }

    public func isValid(_ journey: Journey) -> Bool {
        zip(journey.legs, trainsValid(journey.legs)).allSatisfy { leg, trainValid in
            trainValid && (leg.isWalking || !CrossBorder.runsAbroad(leg, covered: CrossBorder.deutschlandticketStops))
        }
    }

    /// Whether the ticket only falls short because the journey starts or ends a leg abroad: every
    /// train is fine, the border is the only problem. Shown with a warning when nothing else is left.
    public func crossesBorder(_ journey: Journey) -> Bool {
        trainsValid(journey.legs).allSatisfy { $0 }
            && journey.legs.contains { CrossBorder.runsAbroad($0, covered: CrossBorder.deutschlandticketStops) }
    }

    public func isValid(_ entry: BoardEntry) -> Bool {
        switch self {
        case .bahnCard100(let rules): rules.isValid(entry)
        case .deutschlandticket:
            isValid(entry.line) && !CrossBorder.isAbroad(entry.station, covered: CrossBorder.deutschlandticketStops)
        }
    }
}
