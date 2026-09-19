import Foundation

public struct JourneyQuery: Sendable, Hashable {
    public var from: Station
    public var to: Station
    public var date: Date
    /// If true, `date` is the latest arrival instead of the earliest departure.
    public var isArrival: Bool
    public var cursor: String?
    /// Vehicle types a journey may use; journeys with a leg outside this set are dropped.
    public var products: Set<Product>
    /// Upper bound for the number of transfers, `nil` for no limit.
    public var maxTransfers: Int?

    public init(from: Station, to: Station, date: Date, isArrival: Bool = false, cursor: String? = nil,
                products: Set<Product> = Set(Product.allCases), maxTransfers: Int? = nil) {
        self.from = from
        self.to = to
        self.date = date
        self.isArrival = isArrival
        self.cursor = cursor
        self.products = products
        self.maxTransfers = maxTransfers
    }

    /// True when the query restricts vehicle types or transfers at all.
    public var isFiltered: Bool { products != Set(Product.allCases) || maxTransfers != nil }

    /// Whether `journey` satisfies the product and transfer limits. Applied client-side as well,
    /// since not every provider filters server-side.
    public func allows(_ journey: Journey) -> Bool {
        if let maxTransfers, journey.transfers > maxTransfers { return false }
        return journey.transitLegs.allSatisfy { leg in leg.line.map { products.contains($0.product) } ?? true }
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

    /// If another feed also lists this leg's departure (same time + destination) under a different
    /// name — see the deduplication in `TransitousProvider.board` — returns that other name too, so
    /// callers can retry something that failed to match the leg's primary name (e.g. a Träwelling
    /// check-in) before giving up.
    func alternateLineName(for leg: Leg) async -> String? {
        guard let line = leg.line, !leg.isWalking else { return nil }
        guard let entries = try? await board(.departures, at: leg.origin,
                                             date: leg.departure.planned.addingTimeInterval(-2 * 60),
                                             duration: 6, products: Set(Product.allCases)) else { return nil }
        let wantedName = Line.normalize(line.name)
        return entries.first {
            Line.normalize($0.line.name) == wantedName
                && abs($0.time.planned.timeIntervalSince(leg.departure.planned)) <= 2 * 60
        }?.line.alternateName
    }
}
