import Foundation

/// Filters a departure/arrival board.
///
/// Pass-throughs (no passenger stop) are hidden. Trains that only let passengers alight
/// ("kein Einstieg") stay visible on the departure board and are marked in the UI.
public struct BoardFilter: Sendable, Hashable {
    public var products: Set<Product>
    public var bc100Rules: BC100Rules?
    public var hideCancelled: Bool

    public init(products: Set<Product> = Set(Product.allCases), bc100Rules: BC100Rules? = nil, hideCancelled: Bool = false) {
        self.products = products
        self.bc100Rules = bc100Rules
        self.hideCancelled = hideCancelled
    }

    public func apply(_ entries: [BoardEntry]) -> [BoardEntry] {
        entries.filter(includes).sorted { $0.time.best < $1.time.best }
    }

    public func includes(_ entry: BoardEntry) -> Bool {
        guard products.contains(entry.line.product) else { return false }
        if entry.access == .passThrough { return false }
        if hideCancelled, entry.cancelled { return false }
        if let bc100Rules, !bc100Rules.isValid(entry) { return false }
        // A departure whose final destination is this station ends here → not rideable.
        if entry.kind == .departures, entry.terminatesOrOriginatesHere == true,
           let other = entry.otherEnd, Station.normalize(other) == Station.normalize(entry.station.name) {
            return false
        }
        if entry.kind == .arrivals, entry.terminatesOrOriginatesHere == true,
           let other = entry.otherEnd, Station.normalize(other) == Station.normalize(entry.station.name) {
            return false
        }
        return true
    }
}
