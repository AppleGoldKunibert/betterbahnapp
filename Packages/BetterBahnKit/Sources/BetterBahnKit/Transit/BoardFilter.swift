import Foundation

/// Filters a departure/arrival board.
///
/// Pass-throughs (no passenger stop) are hidden. Trains that only let passengers alight
/// ("kein Einstieg") stay visible on the departure board and are marked in the UI.
public struct BoardFilter: Sendable, Hashable {
    public var products: Set<Product>
    public var ticketFilter: TicketFilter?
    public var hideCancelled: Bool

    public init(products: Set<Product> = Set(Product.allCases), ticketFilter: TicketFilter? = nil, hideCancelled: Bool = false) {
        self.products = products
        self.ticketFilter = ticketFilter
        self.hideCancelled = hideCancelled
    }

    public func apply(_ entries: [BoardEntry]) -> [BoardEntry] {
        entries.filter(includes).sorted { $0.time.best < $1.time.best }
    }

    public func includes(_ entry: BoardEntry) -> Bool {
        guard products.contains(entry.line.filterProduct) else { return false }
        if entry.access == .passThrough { return false }
        if hideCancelled, entry.cancelled { return false }
        if let ticketFilter, !ticketFilter.isValid(entry) { return false }
        // A departure whose final destination is this station ends here → not rideable.
        if entry.terminatesOrOriginatesHere == true, Self.namesOwnStation(entry) { return false }
        return true
    }

    /// Whether the other end shown for `entry` is its own station, under the feed's name or as shown.
    private static func namesOwnStation(_ entry: BoardEntry) -> Bool {
        guard let other = entry.otherEnd.map(Station.normalize) else { return false }
        return other == Station.normalize(entry.station.name) || other == Station.normalize(entry.station.displayName)
    }
}
