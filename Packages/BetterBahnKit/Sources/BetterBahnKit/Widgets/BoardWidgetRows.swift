import Foundation

/// One row of the departure board widget: a departure from the widget's station, or (for a commuter
/// route) the next connection to its destination, shown by its first train.
public struct BoardWidgetRow: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var departure: TimeInfo
    public var cancelled: Bool
    public var lineName: String
    public var product: Product
    public var isNightTrain: Bool
    /// Where the train goes (a departure), or the route's destination (a connection).
    public var destination: String
    public var platform: String?
    /// Connections only: when the route's destination is reached.
    public var arrival: TimeInfo?
    /// Connections only: how often one changes trains.
    public var transfers: Int?

    public init(id: String, departure: TimeInfo, cancelled: Bool, lineName: String, product: Product, isNightTrain: Bool,
                destination: String, platform: String?, arrival: TimeInfo? = nil, transfers: Int? = nil) {
        self.id = id
        self.departure = departure
        self.cancelled = cancelled
        self.lineName = lineName
        self.product = product
        self.isNightTrain = isNightTrain
        self.destination = destination
        self.platform = platform
        self.arrival = arrival
        self.transfers = transfers
    }

    public var delayMinutes: Int? { departure.delayMinutes }
}

/// Builds the departure board widget's rows and tells when they change (WidgetKit shows a timeline
/// of entries, so rows whose train has left drop off without a reload).
public enum BoardWidgetRows {
    /// A departure stays on the widget this long after its (live) time: the train may still stand there.
    public static let grace: TimeInterval = 60

    /// The board's departures as rows: filtered like the app's board, trains nobody may board left out,
    /// those that have left (before `now`, with `grace`) too, soonest first.
    public static func rows(board entries: [BoardEntry], products: Set<Product> = Set(Product.allCases), now: Date) -> [BoardWidgetRow] {
        let filtered = BoardFilter(products: products).apply(entries).filter { $0.access.allowsBoarding }
        var seen = Set<String>()
        return filtered.compactMap { entry in
            guard entry.kind == .departures else { return nil }
            let row = BoardWidgetRow(id: entry.id, departure: entry.time, cancelled: entry.cancelled,
                                     lineName: entry.line.displayName, product: entry.line.product,
                                     isNightTrain: entry.line.isNightTrain,
                                     destination: entry.otherEnd ?? "?", platform: entry.platform.best)
            guard seen.insert(row.id).inserted else { return nil }
            return row
        }
        .filter { isAhead($0, at: now) }
    }

    /// Connections to the route's destination as rows, each by its first train (walking to the
    /// station first doesn't count); the arrival and the number of changes come along.
    public static func rows(journeys: [Journey], destination: Station, now: Date) -> [BoardWidgetRow] {
        var seen = Set<String>()
        return journeys.compactMap { journey -> BoardWidgetRow? in
            guard let leg = journey.transitLegs.first, let line = leg.line, let arrival = journey.arrival else { return nil }
            let row = BoardWidgetRow(id: leg.id + ">" + arrival.planned.description, departure: leg.departure,
                                     cancelled: journey.legs.contains(where: \.cancelled),
                                     lineName: line.displayName, product: line.product, isNightTrain: line.isNightTrain,
                                     destination: destination.displayName, platform: leg.departurePlatform?.best,
                                     arrival: arrival, transfers: journey.transfers)
            guard seen.insert(row.id).inserted else { return nil }
            return row
        }
        .sorted { $0.departure.best < $1.departure.best }
        .filter { isAhead($0, at: now) }
    }

    /// The rows whose train hasn't left at `date` (with `grace`), at most `limit`.
    public static func visible(_ rows: [BoardWidgetRow], at date: Date, limit: Int) -> [BoardWidgetRow] {
        Array(rows.filter { isAhead($0, at: date) }.prefix(limit))
    }

    /// When a row drops off: the moments after `after` up to `until` at which the widget shows
    /// something else, for the timeline's entries.
    public static func changeDates(of rows: [BoardWidgetRow], after: Date, until: Date) -> [Date] {
        Set(rows.map { $0.departure.best.addingTimeInterval(grace) })
            .filter { $0 > after && $0 <= until }
            .sorted()
    }

    static func isAhead(_ row: BoardWidgetRow, at date: Date) -> Bool {
        row.departure.best.addingTimeInterval(grace) > date
    }
}
