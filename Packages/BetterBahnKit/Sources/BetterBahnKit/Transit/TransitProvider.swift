import Foundation

public struct JourneyQuery: Sendable, Hashable {
    public var from: Station
    public var to: Station
    public var date: Date
    /// If true, `date` is the latest arrival instead of the earliest departure.
    public var isArrival: Bool
    public var cursor: String?

    public init(from: Station, to: Station, date: Date, isArrival: Bool = false, cursor: String? = nil) {
        self.from = from
        self.to = to
        self.date = date
        self.isArrival = isArrival
        self.cursor = cursor
    }
}

public protocol TransitProvider: Sendable {
    var source: DataSource { get }
    func searchStations(_ query: String) async throws -> [Station]
    func journeys(_ query: JourneyQuery) async throws -> JourneyPage
    /// `products` lets a provider that supports server-side mode filtering (e.g. Transitous) avoid
    /// having rare long-distance trains crowded out of a fixed-size result page by frequent local ones.
    func board(_ kind: BoardKind, at station: Station, date: Date, duration: Int, products: Set<Product>) async throws -> [BoardEntry]
    func trip(id: String) async throws -> Trip
}

public extension TransitProvider {
    func departures(at station: Station, date: Date = .now, duration: Int = 60, products: Set<Product> = Set(Product.allCases)) async throws -> [BoardEntry] {
        try await board(.departures, at: station, date: date, duration: duration, products: products)
    }

    func arrivals(at station: Station, date: Date = .now, duration: Int = 60, products: Set<Product> = Set(Product.allCases)) async throws -> [BoardEntry] {
        try await board(.arrivals, at: station, date: date, duration: duration, products: products)
    }
}
