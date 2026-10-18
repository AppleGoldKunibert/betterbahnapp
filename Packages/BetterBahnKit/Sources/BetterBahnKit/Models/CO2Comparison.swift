import Foundation

/// CO₂ of a trip by train compared with the same distance by car and by plane (#386).
///
/// Distance × the Umweltbundesamt's average greenhouse-gas emissions per passenger-km (CO₂ equivalents
/// incl. energy supply, reference year 2024, TREMOD 6.71B). Car and plane are taken over the same
/// distance the train runs.
public struct CO2Comparison: Sendable, Hashable {
    /// Kilometres of the legs that count (walks, ferries and unknown products are left out).
    public var kilometers: Double
    /// Kilograms by the trains and buses actually taken.
    public var train: Double
    public var car: Double
    public var plane: Double

    /// g/Pkm, Umweltbundesamt, reference year 2024.
    public enum Factor {
        public static let longDistanceRail = 26.0
        public static let regionalRail = 44.0
        public static let tramAndSubway = 42.0
        public static let bus = 90.0
        public static let coach = 30.0
        public static let car = 164.0
        public static let domesticFlight = 290.0
    }

    /// The UBA factor for a product, nil for those it has none for (ferries, unknown).
    public static func gramsPerKilometer(for product: Product) -> Double? {
        switch product {
        case .highSpeed, .longDistance, .nightTrain, .interregio: Factor.longDistanceRail
        case .regionalExpress, .regional, .suburban: Factor.regionalRail
        case .subway, .tram: Factor.tramAndSubway
        case .bus: Factor.bus
        case .coach: Factor.coach
        case .ferry, .other: nil
        }
    }

    /// From legs and their track length in km.
    public init(rides: [(leg: Leg, kilometers: Double)]) {
        var kilometers = 0.0, grams = 0.0
        for ride in rides where !ride.leg.isWalking && ride.kilometers > 0 {
            guard let product = ride.leg.line?.product, let factor = Self.gramsPerKilometer(for: product) else { continue }
            kilometers += ride.kilometers
            grams += ride.kilometers * factor
        }
        self.kilometers = kilometers
        train = grams / 1000
        car = kilometers * Factor.car / 1000
        plane = kilometers * Factor.domesticFlight / 1000
    }

    /// From legs and their track geometry by leg id; legs without one are measured along their stops.
    public init(legs: [Leg], geometries: [String: [Coordinate]] = [:]) {
        self.init(rides: legs.map { ($0, YearReview.Ride.kilometers(of: $0, geometry: geometries[$0.id])) })
    }

    /// Kilograms saved compared with the car; never negative.
    public var savedComparedToCar: Double { max(0, car - train) }
    public var savedComparedToPlane: Double { max(0, plane - train) }
}
