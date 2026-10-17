import Foundation
import Testing
@testable import BetterBahnKit

@Suite struct BoardWidgetTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func minutes(_ value: Double) -> Date { now.addingTimeInterval(value * 60) }

    private func station(_ name: String, eva: String? = nil, region: String? = nil) -> Station {
        Station(id: "de:11000:" + name, name: name, coordinate: Coordinate(latitude: 52.5, longitude: 13.4),
                evaNumber: eva, source: .transitous, region: region)
    }

    private func entry(_ line: String, product: Product = .regionalExpress, to: String, depart: Double, delay: Double? = nil,
                       platform: String? = "3", cancelled: Bool = false, access: StopAccess = .normal,
                       kind: BoardKind = .departures) -> BoardEntry {
        BoardEntry(kind: kind, tripId: "trip-\(line)-\(depart)", station: station("Berlin Hbf"),
                   line: Line(name: line, number: nil, product: product, operatorName: nil), otherEnd: to,
                   time: TimeInfo(planned: minutes(depart), actual: delay.map { minutes(depart + $0) }),
                   platform: PlatformInfo(planned: platform, actual: nil), cancelled: cancelled,
                   terminatesOrOriginatesHere: nil, remarks: [], access: access, source: .transitous)
    }

    // MARK: Link

    @Test func linkCarriesTheStationItself() {
        let berlin = station("Berlin Hbf", eva: "8011160", region: "Berlin")
        let url = BoardWidgetLink.url(station: berlin)
        #expect(url.scheme == "betterbahn")
        #expect(url.host() == "board")
        #expect(BoardWidgetLink.target(from: url) == .board(berlin))
    }

    @Test func linkWithDestinationOpensTheRoute() {
        let berlin = station("Berlin Hbf", eva: "8011160")
        let potsdam = station("Potsdam Hbf", region: "Brandenburg")
        let target = BoardWidgetLink.target(from: BoardWidgetLink.url(station: berlin, destination: potsdam))
        #expect(target == .route(from: berlin, to: potsdam))
    }

    @Test func encodedStationIsURLSafeAndRoundTrips() {
        let odd = Station(id: "de:08135:620/x+y", name: "Bernau (b Berlin) Ü", coordinate: nil, evaNumber: nil,
                          source: .bahnDe, region: "Bayern")
        let encoded = BoardWidgetLink.encode(odd)
        #expect(!encoded.contains("+") && !encoded.contains("/") && !encoded.contains("="))
        #expect(BoardWidgetLink.decode(encoded) == odd)
        // The same station always encodes alike: the widget's entity ID must be stable.
        #expect(BoardWidgetLink.encode(odd) == encoded)
    }

    @Test func linkIgnoresOtherURLs() {
        #expect(BoardWidgetLink.target(from: URL(string: "betterbahn://journey?id=1")!) == nil)
        #expect(BoardWidgetLink.target(from: URL(string: "betterbahn://board?station=not-json")!) == nil)
        #expect(BoardWidgetLink.target(from: URL(string: "betterbahn://board")!) == nil)
    }

    // MARK: Rows from a board

    @Test func boardRowsKeepBoardableDeparturesAheadInOrder() {
        let entries = [
            entry("RE 1", to: "Magdeburg Hbf", depart: 12),
            entry("S 5", product: .suburban, to: "Strausberg", depart: 3, delay: 2),
            entry("ICE 1234", product: .highSpeed, to: "München Hbf", depart: -5),            // left 5 min ago
            entry("RB 24", product: .regional, to: "Eberswalde", depart: 8, access: .exitOnly), // nobody may board
            entry("IC 2431", product: .longDistance, to: "Köln Hbf", depart: 20, kind: .arrivals),
            entry("RE 1", to: "Magdeburg Hbf", depart: 12),                                     // duplicate
            entry("ICE 1000", product: .highSpeed, to: "Hamburg Hbf", depart: -0.5),           // standing there still
        ]
        let rows = BoardWidgetRows.rows(board: entries, now: now)
        #expect(rows.map(\.lineName) == ["ICE 1000", "S 5", "RE 1"])
        #expect(rows[1].delayMinutes == 2)
        #expect(rows[1].destination == "Strausberg")
        #expect(rows[1].platform == "3")
        #expect(rows[1].arrival == nil && rows[1].transfers == nil)
    }

    @Test func boardRowsFollowTheProductFilter() {
        let entries = [
            entry("RE 1", to: "Magdeburg Hbf", depart: 12),
            entry("S 5", product: .suburban, to: "Strausberg", depart: 3),
            entry("ICE 1000", product: .highSpeed, to: "Hamburg Hbf", depart: 5),
        ]
        #expect(BoardWidgetRows.rows(board: entries, products: Product.regionalProducts, now: now).map(\.lineName) == ["RE 1"])
        #expect(BoardWidgetRows.rows(board: entries, products: Product.longDistanceProducts, now: now).map(\.lineName) == ["ICE 1000"])
    }

    @Test func cancelledDeparturesStayOnTheBoard() {
        let rows = BoardWidgetRows.rows(board: [entry("RE 1", to: "Magdeburg Hbf", depart: 12, cancelled: true)], now: now)
        #expect(rows.count == 1)
        #expect(rows[0].cancelled)
    }

    // MARK: Rows from connections

    private func leg(_ line: String?, from: String, to: String, depart: Double, arrive: Double, delay: Double? = nil,
                     platform: String? = nil, cancelled: Bool = false) -> Leg {
        Leg(origin: station(from), destination: station(to),
            departure: TimeInfo(planned: minutes(depart), actual: delay.map { minutes(depart + $0) }),
            arrival: TimeInfo(planned: minutes(arrive), actual: delay.map { minutes(arrive + $0) }),
            departurePlatform: platform.map { PlatformInfo(planned: $0, actual: nil) }, arrivalPlatform: nil,
            tripId: line.map { "trip-\($0)" }, line: line.map { Line(name: $0, number: nil, product: .regionalExpress, operatorName: nil) },
            direction: to, isWalking: line == nil, cancelled: cancelled, stopovers: [], remarks: [], source: .transitous)
    }

    @Test func routeRowsShowTheFirstTrainArrivalAndChanges() {
        let potsdam = station("Potsdam Hbf")
        let journeys = [
            Journey(legs: [leg("RE 1", from: "Berlin Hbf", to: "Potsdam Hbf", depart: 10, arrive: 35, delay: 4, platform: "14")], source: .transitous),
            // Walking to the station first: the train is still the row's line.
            Journey(legs: [leg(nil, from: "Berlin Hbf", to: "Berlin Hbf", depart: 2, arrive: 5),
                           leg("S 7", from: "Berlin Hbf", to: "Wannsee", depart: 5, arrive: 25, platform: "15"),
                           leg("RB 23", from: "Wannsee", to: "Potsdam Hbf", depart: 30, arrive: 45)], source: .transitous),
            Journey(legs: [leg("RE 1", from: "Berlin Hbf", to: "Potsdam Hbf", depart: -3, arrive: 22)], source: .transitous),
        ]
        let rows = BoardWidgetRows.rows(journeys: journeys, destination: potsdam, now: now)
        #expect(rows.map(\.lineName) == ["S 7", "RE 1"])
        #expect(rows[0].transfers == 1)
        #expect(rows[0].platform == "15")
        #expect(rows[0].arrival?.planned == minutes(45))
        #expect(rows[0].destination == "Potsdam Hbf")
        #expect(rows[1].transfers == 0)
        #expect(rows[1].delayMinutes == 4)
        #expect(rows[1].arrival?.delayMinutes == 4)
    }

    // MARK: Timeline

    @Test func rowsDropOffAfterTheirTrainLeft() {
        let rows = BoardWidgetRows.rows(board: [
            entry("S 5", product: .suburban, to: "Strausberg", depart: 3, delay: 2),
            entry("RE 1", to: "Magdeburg Hbf", depart: 12),
            entry("RE 2", to: "Cottbus Hbf", depart: 30),
        ], now: now)
        #expect(BoardWidgetRows.visible(rows, at: minutes(4), limit: 2).map(\.lineName) == ["S 5", "RE 1"])
        // The S 5 is live at :05 and stays a minute longer.
        #expect(BoardWidgetRows.visible(rows, at: minutes(5.5), limit: 2).map(\.lineName) == ["S 5", "RE 1"])
        #expect(BoardWidgetRows.visible(rows, at: minutes(6.5), limit: 2).map(\.lineName) == ["RE 1", "RE 2"])
        #expect(BoardWidgetRows.changeDates(of: rows, after: now, until: minutes(20)) == [minutes(6), minutes(13)])
        #expect(BoardWidgetRows.changeDates(of: rows, after: minutes(6), until: minutes(60)) == [minutes(13), minutes(31)])
    }
}
