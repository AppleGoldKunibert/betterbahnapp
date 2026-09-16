import Foundation

/// Decides whether a train can be used with a BahnCard 100.
///
/// The BahnCard 100 covers DB trains and local transport operators in Germany, but not
/// independent long-distance operators. The default lists are a best effort and can be edited
/// in the settings.
public struct BC100Rules: Codable, Sendable, Hashable {
    /// Case-insensitive substrings of the operator name that are not valid.
    public var excludedOperators: [String]
    /// Line prefixes (e.g. "FLX") that are not valid.
    public var excludedLinePrefixes: [String]
    /// Products that are never valid (long-distance buses).
    public var excludedProducts: Set<Product>

    public init(excludedOperators: [String], excludedLinePrefixes: [String], excludedProducts: Set<Product>) {
        self.excludedOperators = excludedOperators
        self.excludedLinePrefixes = excludedLinePrefixes
        self.excludedProducts = excludedProducts
    }

    public static let `default` = BC100Rules(
        excludedOperators: ["flixtrain", "flix train", "flixbus", "european sleeper", "eurostar", "thalys",
                            "snälltåget", "snalltaget", "rdc deutschland", "alpen-sylt", "nachtexpress"],
        excludedLinePrefixes: ["FLX", "ES", "EST", "THA", "SJ"],
        excludedProducts: [.coach]
    )

    public func isValid(_ line: Line?) -> Bool {
        guard let line else { return true } // walking
        if excludedProducts.contains(line.product) { return false }
        if let op = line.operatorName?.lowercased(),
           excludedOperators.contains(where: { op.contains($0.lowercased()) }) {
            return false
        }
        let prefix = line.name.split(separator: " ").first.map { String($0).uppercased() } ?? ""
        let letters = String(line.name.uppercased().prefix { $0.isLetter })
        return !excludedLinePrefixes.contains { $0.uppercased() == prefix || $0.uppercased() == letters }
    }

    public func isValid(_ leg: Leg) -> Bool { leg.isWalking || isValid(leg.line) }
    public func isValid(_ journey: Journey) -> Bool { journey.legs.allSatisfy(isValid) }
    public func isValid(_ entry: BoardEntry) -> Bool { isValid(entry.line) }
}
