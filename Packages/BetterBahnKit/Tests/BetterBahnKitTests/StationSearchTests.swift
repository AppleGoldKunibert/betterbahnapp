import Foundation
import Testing
@testable import BetterBahnKit

/// Shortcuts in the station search: "b" bus, "t" tram, "l" nearest first (#90).
struct StationSearchTests {
    @Test func parsesShortcutsAtStartAndEnd() {
        let front = StationSearch(parsing: "b Alexanderplatz")
        #expect(front.text == "Alexanderplatz")
        #expect(front.modes == [.bus])
        #expect(!front.byDistance)

        let back = StationSearch(parsing: "Alexanderplatz T")
        #expect(back.text == "Alexanderplatz")
        #expect(back.modes == [.tram])

        let combined = StationSearch(parsing: "b l Rathaus")
        #expect(combined.text == "Rathaus")
        #expect(combined.modes == [.bus])
        #expect(combined.byDistance)

        let bothEnds = StationSearch(parsing: "  l Rathaus Spandau  b ")
        #expect(bothEnds.text == "Rathaus Spandau")
        #expect(bothEnds.modes == [.bus])
        #expect(bothEnds.byDistance)
    }

    /// Names with single letters or words starting with them are left alone.
    @Test func namesAreNotMistakenForShortcuts() {
        for name in ["Bad Tölz", "Berlin S", "Bonn", "Bernau b Berlin", "Lübeck", "S Südkreuz"] {
            let search = StationSearch(parsing: name)
            #expect(search.text == name)
            #expect(!search.hasShortcuts)
        }
    }

    /// A lone letter is only a shortcut once a space follows it – "B" may be the start of "Berlin".
    /// A shortcut alone leaves no text, so nothing is searched yet.
    @Test func loneLetterNeedsASpace() {
        #expect(StationSearch(parsing: "B").text == "B")
        #expect(!StationSearch(parsing: "B").hasShortcuts)
        let typed = StationSearch(parsing: "b ")
        #expect(typed.text.isEmpty)
        #expect(typed.modes == [.bus])
    }

    private func match(_ id: String, modes: [String]?, lat: Double = 52.5, lon: Double = 13.4) -> MGeocodeMatch {
        MGeocodeMatch(type: "STOP", name: id, id: id, lat: lat, lon: lon, country: "DE", modes: modes)
    }

    /// The normal search drops stops only buses serve, but keeps mixed ones and stops without
    /// known modes; with nothing else left (a village without a station) the bus stops stay.
    @Test func normalSearchHidesBusOnlyStops() {
        let station = match("station", modes: ["REGIONAL_RAIL", "BUS"])
        let busStop = match("bus", modes: ["BUS"], lat: 52.6)
        let onDemand = match("odm", modes: ["BUS", "ODM"], lat: 52.7)
        let unknown = match("unknown", modes: nil, lat: 52.8)
        let normal = StationSearch(text: "x")

        #expect(TransitousProvider.applying(normal, to: [station, busStop, onDemand, unknown], near: nil).map(\.id)
            == ["station", "unknown"])
        #expect(TransitousProvider.applying(normal, to: [busStop, onDemand], near: nil).map(\.id) == ["bus", "odm"])
    }

    /// "b"/"t" keep every stop where buses/trams stop, mixed ones included, in the ranked order.
    @Test func modeFilterKeepsMixedStops() {
        let subwayTram = match("subwayTram", modes: ["SUBWAY", "TRAM"])
        let suburbanBus = match("suburbanBus", modes: ["SUBURBAN", "BUS"], lat: 52.6)
        let coach = match("coach", modes: ["COACH"], lat: 52.7)
        let train = match("train", modes: ["REGIONAL_RAIL"], lat: 52.8)
        let all = [subwayTram, suburbanBus, coach, train]

        #expect(TransitousProvider.applying(StationSearch(text: "x", modes: [.bus]), to: all, near: nil).map(\.id)
            == ["suburbanBus", "coach"])
        #expect(TransitousProvider.applying(StationSearch(text: "x", modes: [.tram]), to: all, near: nil).map(\.id)
            == ["subwayTram"])
        #expect(TransitousProvider.applying(StationSearch(text: "x", modes: [.bus, .tram]), to: all, near: nil).map(\.id)
            == ["subwayTram", "suburbanBus", "coach"])
    }

    /// A U-Bahn stop and the tram stop next to it come as two hits and are merged; the merged stop
    /// still counts as a tram stop.
    @Test func mergedStopKeepsBothStopsModes() {
        let subway = match("subway", modes: ["SUBWAY"], lat: 52.5000, lon: 13.4000)
        let tram = match("tram", modes: ["TRAM", "BUS"], lat: 52.5005, lon: 13.4000)

        let merged = TransitousProvider.mergingNearbyDuplicates([subway, tram])

        #expect(merged.map(\.id) == ["subway"])
        #expect(merged.first?.modes == ["SUBWAY", "TRAM", "BUS"])
        #expect(TransitousProvider.applying(StationSearch(text: "x", modes: [.tram]), to: merged, near: nil).map(\.id)
            == ["subway"])
    }

    /// "l" sorts by distance alone; without a location the ranked order stays.
    @Test func byDistanceSortsNearestFirst() {
        let far = match("far", modes: ["BUS"], lat: 53.0)
        let near = match("near", modes: ["BUS"], lat: 52.51)
        let middle = match("middle", modes: ["BUS"], lat: 52.7)
        let search = StationSearch(text: "x", modes: [.bus], byDistance: true)
        let here = Coordinate(latitude: 52.5, longitude: 13.4)

        #expect(TransitousProvider.applying(search, to: [far, near, middle], near: here).map(\.id) == ["near", "middle", "far"])
        #expect(TransitousProvider.applying(search, to: [far, near, middle], near: nil).map(\.id) == ["far", "near", "middle"])

        let stations = [far, near, middle].map { $0.toStation() }
        #expect(search.ordered(stations, near: here).map(\.id) == ["near", "middle", "far"])
    }
}
