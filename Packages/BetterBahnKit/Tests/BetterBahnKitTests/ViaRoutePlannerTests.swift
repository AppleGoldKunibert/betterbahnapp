import Foundation
import Testing
@testable import BetterBahnKit

@Suite struct ViaRoutePlannerTests {
    let a = station("8000207", "Köln Hbf", 50.943, 6.958)
    let b = station("8000149", "Hamm (Westf)", 51.678, 7.808)
    let c = station("8000152", "Hannover Hbf", 52.377, 9.741)
    let base = Date(timeIntervalSince1970: 1_800_000_000)

    func time(_ minutes: Double) -> TimeInfo { TimeInfo(planned: base.addingTimeInterval(minutes * 60), actual: nil) }

    func stop(_ s: Station, arr: Double?, dep: Double?) -> Stopover {
        Stopover(station: s, arrival: arr.map(time), departure: dep.map(time),
                 arrivalPlatform: nil, departurePlatform: nil, cancelled: false)
    }

    func trip(_ id: String, _ name: String, _ stops: [Stopover]) -> Trip {
        Trip(id: id, line: Line(name: name, number: String(name.split(separator: " ").last!), product: .highSpeed,
                                operatorName: nil),
             direction: stops.last?.station.name, stopovers: stops, cancelled: false, remarks: [], source: .bahnDe)
    }

    func journey(_ trip: Trip, _ from: Station, _ to: Station) -> Journey {
        Journey(legs: [trip.leg(from: from, to: to)!], source: .bahnDe)
    }

    /// Train 1 runs A – B – C: via B with the routes A → B and B → C both on train 1.
    func provider(onward: Trip? = nil) -> RoutingMockProvider {
        let train = trip("ice1", "ICE 1", [stop(a, arr: nil, dep: 10), stop(b, arr: 70, dep: 72), stop(c, arr: 130, dep: nil)])
        let mock = RoutingMockProvider()
        mock.routes["\(a.name) -> \(b.name)"] = [journey(train, a, b)]
        let next = onward ?? train
        mock.routes["\(b.name) -> \(c.name)"] = [journey(next, b, c)]
        return mock
    }

    @Test func zeroStayKeepsSameTrainAsOneLeg() async throws {
        let planner = ViaRoutePlanner(provider: provider())
        let journeys = try await planner.journeys(from: a, to: c, via: [ViaWaypoint(station: b)], date: base)
        let legs = try #require(journeys.first).legs
        #expect(legs.count == 1)
        #expect(legs.first?.origin.isSamePlace(as: a) == true)
        #expect(legs.first?.destination.isSamePlace(as: c) == true)
        #expect(legs.first?.stopovers.map(\.station.name) == [a.name, b.name, c.name])
        // The via stop is an intermediate stop with both its arrival and departure.
        #expect(legs.first?.stopovers[1].arrival == time(70))
        #expect(legs.first?.stopovers[1].departure == time(72))
    }

    @Test func minimumStaySplitsAtVia() async throws {
        let planner = ViaRoutePlanner(provider: provider())
        let journeys = try await planner.journeys(from: a, to: c, via: [ViaWaypoint(station: b, minStayMinutes: 15)], date: base)
        #expect(journeys.first?.legs.count == 2)
    }

    @Test func zeroStayKeepsTransferToOtherTrain() async throws {
        let other = trip("ice2", "ICE 2", [stop(b, arr: nil, dep: 80), stop(c, arr: 140, dep: nil)])
        let planner = ViaRoutePlanner(provider: provider(onward: other))
        let journeys = try await planner.journeys(from: a, to: c, via: [ViaWaypoint(station: b)], date: base)
        #expect(journeys.first?.legs.map { $0.line?.name } == ["ICE 1", "ICE 2"])
    }

    func sBahn(_ id: String, run: String, _ stops: [Stopover]) -> Trip {
        Trip(id: id, line: Line(name: "S7", number: "7", product: .suburban, operatorName: nil, tripNumber: run),
             direction: stops.last?.station.name, stopovers: stops, cancelled: false, remarks: [], source: .bahnDe)
    }

    @Test func zeroStayKeepsTransferBetweenRunsOfSameLine() async throws {
        let first = sBahn("s7a", run: "37101", [stop(a, arr: nil, dep: 10), stop(b, arr: 70, dep: nil)])
        let second = sBahn("s7b", run: "37202", [stop(b, arr: nil, dep: 80), stop(c, arr: 140, dep: nil)])
        let mock = RoutingMockProvider()
        mock.routes["\(a.name) -> \(b.name)"] = [journey(first, a, b)]
        mock.routes["\(b.name) -> \(c.name)"] = [journey(second, b, c)]
        let journeys = try await ViaRoutePlanner(provider: mock).journeys(from: a, to: c, via: [ViaWaypoint(station: b)], date: base)
        #expect(journeys.first?.legs.count == 2)
    }

    @Test func zeroStayKeepsTrainBackTheOtherWay() async throws {
        // Out to B on the line, then the line's other direction back through A (no run numbers known).
        let out = trip("re1", "RE 7", [stop(a, arr: nil, dep: 10), stop(b, arr: 70, dep: nil)])
        let back = trip("re2", "RE 7", [stop(b, arr: nil, dep: 80), stop(a, arr: 140, dep: nil)])
        let mock = RoutingMockProvider()
        mock.routes["\(a.name) -> \(b.name)"] = [journey(out, a, b)]
        mock.routes["\(b.name) -> \(a.name)"] = [journey(back, b, a)]
        let journeys = try await ViaRoutePlanner(provider: mock).journeys(from: a, to: a, via: [ViaWaypoint(station: b)], date: base)
        #expect(journeys.first?.legs.count == 2)
    }

    @Test func identicalRoutesAreListedOnce() async throws {
        // Both routes to B lead to the same onward train, so several beam candidates end up the same journey.
        let mock = provider()
        let toB = try #require(mock.routes["\(a.name) -> \(b.name)"]?.first)
        mock.routes["\(a.name) -> \(b.name)"] = [toB, toB]
        let journeys = try await ViaRoutePlanner(provider: mock).journeys(from: a, to: c, via: [ViaWaypoint(station: b)], date: base)
        #expect(journeys.count == 1)
        #expect(Set(journeys.map(\.id)).count == journeys.count)
    }

    // MARK: Earlier and later routes (#571)

    /// Train k runs A (dep 10 + 60k) – B – C (arr 130 + 60k) for each hour k in `hours`.
    func hourlyProvider(hours: [Int] = Array(0..<12)) -> TimedMockProvider {
        let mock = TimedMockProvider()
        for k in hours {
            let shift = Double(60 * k)
            let train = trip("ice\(k)", "ICE \(100 + k)", [stop(a, arr: nil, dep: 10 + shift), stop(b, arr: 70 + shift, dep: 72 + shift),
                                                         stop(c, arr: 130 + shift, dep: nil)])
            mock.routes["\(a.name) -> \(b.name)", default: []].append(journey(train, a, b))
            mock.routes["\(b.name) -> \(c.name)", default: []].append(journey(train, b, c))
        }
        return mock
    }

    /// Minutes after `base` each journey leaves.
    func departures(_ journeys: [Journey]) -> [Double] {
        journeys.compactMap { $0.departure.map { $0.planned.timeIntervalSince(base) / 60 } }
    }

    let via = [ViaWaypoint(station: b)]
    var fourHoursIn: Date { base.addingTimeInterval(4 * 3600) }

    @Test func laterRoutesLeaveAfterTheShownOnes() async throws {
        let planner = ViaRoutePlanner(provider: hourlyProvider())
        let shown = try await planner.journeys(from: a, to: c, via: via, date: fourHoursIn)
        let latest = try #require(departures(shown).max())
        let later = try await planner.journeys(from: a, to: c, via: via, after: shown)
        #expect(!later.isEmpty)
        #expect(departures(later).allSatisfy { $0 > latest })
        // The next train after the latest shown one, not some hours on.
        #expect(departures(later).min() == latest + 60)
    }

    @Test func earlierRoutesLeaveBeforeTheShownOnes() async throws {
        let planner = ViaRoutePlanner(provider: hourlyProvider())
        let shown = try await planner.journeys(from: a, to: c, via: via, date: fourHoursIn)
        #expect(departures(shown).min() == 250)
        let earlier = try await planner.journeys(from: a, to: c, via: via, before: shown)
        #expect(Set(departures(earlier)) == [190])
        #expect(Set(earlier.map(\.id)).isDisjoint(with: shown.map(\.id)))
    }

    @Test func earlierRoutesLookFurtherBackAfterAGap() async throws {
        // Nothing runs in the two hours before the shown trains: the first try only finds those again.
        let planner = ViaRoutePlanner(provider: hourlyProvider(hours: [0, 1, 4, 5]))
        let shown = try await planner.journeys(from: a, to: c, via: via, date: fourHoursIn)
        #expect(departures(shown).min() == 250)
        let earlier = try await planner.journeys(from: a, to: c, via: via, before: shown)
        #expect(Set(departures(earlier)) == [70])
    }

    @Test func noEarlierOrLaterRoutesWithoutAny() async throws {
        let planner = ViaRoutePlanner(provider: hourlyProvider(hours: [4]))
        let shown = try await planner.journeys(from: a, to: c, via: via, date: fourHoursIn)
        #expect(departures(shown) == [250])
        #expect(try await planner.journeys(from: a, to: c, via: via, before: shown).isEmpty)
        #expect(try await planner.journeys(from: a, to: c, via: via, after: shown).isEmpty)
        #expect(try await planner.journeys(from: a, to: c, via: via, after: []).isEmpty)
    }
}

/// Journeys keyed by "<from> -> <to>", answered like a real search: the ones leaving at or after the asked time, in order.
final class TimedMockProvider: TransitProvider, @unchecked Sendable {
    let source: DataSource = .bahnDe
    var routes: [String: [Journey]] = [:]

    func searchStations(_ query: String) async throws -> [Station] { [] }

    func journeys(_ query: JourneyQuery) async throws -> JourneyPage {
        let found = (routes["\(query.from.name) -> \(query.to.name)"] ?? [])
            .filter { ($0.departure?.planned ?? .distantPast) >= query.date }
            .sorted { ($0.departure?.planned ?? .distantPast) < ($1.departure?.planned ?? .distantPast) }
        return JourneyPage(journeys: Array(found.prefix(6)), earlierCursor: nil, laterCursor: nil, source: source)
    }

    func board(_ kind: BoardKind, at station: Station, date: Date, duration: Int, products: Set<Product>) async throws -> [BoardEntry] { [] }

    func trip(id: String) async throws -> Trip { throw TransitError.notFound(id) }
}
