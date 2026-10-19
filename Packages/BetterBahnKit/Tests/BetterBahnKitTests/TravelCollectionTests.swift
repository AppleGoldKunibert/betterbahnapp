import Foundation
import Testing
@testable import BetterBahnKit

@Suite struct TravelCollectionTests {
    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }

    private func station(_ name: String, eva: String) -> Station {
        Station(id: eva, name: name, coordinate: nil, evaNumber: eva, source: .bahnDe)
    }

    private var berlin: Station { station("Berlin Hbf", eva: "8011160") }
    private var hamburg: Station { station("Hamburg Hbf", eva: "8002549") }
    private var buechen: Station { station("Büchen", eva: "8000059") }

    private let stations = [
        BigStation(dhid: "berlin", name: "Berlin Hbf", priceClass: 1),
        BigStation(dhid: "hamburg", name: "Hamburg Hbf", priceClass: 1),
        BigStation(dhid: "hannover", name: "Hannover Hbf", priceClass: 2),
    ]

    private func dhid(_ station: Station) -> String? {
        ["8011160": "berlin", "8002549": "hamburg", "8000152": "hannover"][station.evaNumber ?? ""]
    }

    private func ride(_ line: String, _ from: Station, _ to: Station, departure: String, minutes: Double = 100,
                      cancelled: Bool = false, units: [TrainFormation.Unit] = []) -> TravelCollection.Ride {
        let start = date(departure)
        let leg = Leg(origin: from, destination: to,
                      departure: TimeInfo(planned: start, actual: nil),
                      arrival: TimeInfo(planned: start.addingTimeInterval(minutes * 60), actual: nil),
                      departurePlatform: nil, arrivalPlatform: nil, tripId: nil,
                      line: Line(name: line, number: nil, product: .highSpeed, operatorName: nil), direction: nil,
                      isWalking: false, cancelled: cancelled, stopovers: [], remarks: [], source: .transitous)
        return TravelCollection.Ride(leg: leg, formation: units.isEmpty ? nil : TrainFormation(units: units))
    }

    private func collection(_ rides: [TravelCollection.Ride], now: String = "2026-10-18T12:00:00Z") -> TravelCollection {
        TravelCollection(rides: rides, now: date(now), stations: stations,
                         liveries: [304: "Regenbogen", 8029: "Blauer Streifen (Europa)"],
                         trainsetNames: [304: "Wetzlar", 9018: "Freiburg im Breisgau"], dhid: dhid)
    }

    @Test func collectsLiveriesSeriesAndTrainsetsFromRememberedFormations() {
        let result = collection([
            ride("ICE 597", berlin, hamburg, departure: "2026-05-01T08:00:00Z",
                 units: [.init(model: "ICE 4", number: "9018", name: "Freiburg im Breisgau"),
                         .init(model: "ICE 3neo Redesign", number: "8029")]),
            ride("ICE 598", hamburg, berlin, departure: "2026-06-01T08:00:00Z",
                 units: [.init(model: "ICE 4 Lang (BR412)", number: "9018")]),
            ride("ICE 1000", berlin, hamburg, departure: "2026-07-01T08:00:00Z"), // no formation known
        ])
        let liveries = result.group(.liveries)!
        #expect(liveries.total == 2 && liveries.collected == 1)
        #expect(liveries.items.first { $0.isCollected }?.title == "Blauer Streifen (Europa)")

        let series = result.group(.series)!
        #expect(series.total == TravelCollection.series.count)
        #expect(Set(series.items.filter(\.isCollected).map(\.title)) == ["ICE 4", "ICE 3neo"])
        let ice4 = series.items.first { $0.title == "ICE 4" }!
        #expect(ice4.sightings.count == 2)
        #expect(ice4.firstSighting?.train == "ICE 597")
        #expect(ice4.firstSighting?.from == "Berlin Hbf")

        let trainsets = result.group(.trainsets)!
        #expect(trainsets.items.map(\.title) == ["Tz 304", "Tz 9018"])
        #expect(trainsets.items[1].subtitle == "Freiburg im Breisgau" && trainsets.items[1].sightings.count == 2)
        #expect(!trainsets.items[0].isCollected)
    }

    @Test func leavesOutRidesNotTravelled() {
        let result = collection([
            ride("ICE 1", berlin, hamburg, departure: "2026-10-18T11:00:00Z", units: [.init(model: "ICE 1", number: "304")]),
            ride("ICE 2", berlin, hamburg, departure: "2026-05-01T08:00:00Z", cancelled: true,
                 units: [.init(model: "ICE 2", number: "9018")]),
        ])
        #expect(result.collectedIDs.isEmpty)
    }

    @Test func ignoresTheCoachSetNumberOfAnIC1() {
        let result = collection([
            ride("IC 2000", berlin, hamburg, departure: "2026-05-01T08:00:00Z", units: [.init(model: "IC 1", number: nil)]),
        ])
        #expect(result.group(.series)!.collected == 0)
    }

    @Test func countsBoardingAlightingAndChangingOnceAtBigStations() {
        let result = collection([
            // Berlin → Hamburg, changing there for Büchen, back the next day via Hamburg.
            ride("ICE 1", berlin, hamburg, departure: "2026-05-01T08:00:00Z", minutes: 110),
            ride("RE 1", hamburg, buechen, departure: "2026-05-01T10:20:00Z", minutes: 40),
            ride("RE 1", buechen, hamburg, departure: "2026-05-02T08:00:00Z", minutes: 40),
        ])
        let stations = result.group(.stations)!
        #expect(stations.collected == 2)
        let hamburg = stations.items.first { $0.title == "Hamburg Hbf" }!
        #expect(hamburg.sightings.count == 2)
        #expect(hamburg.firstSighting?.train == "ICE 1")
        #expect(hamburg.subtitle == "Großer Bahnhof")
        let hannover = stations.items.first { $0.title == "Hannover Hbf" }!
        #expect(!hannover.isCollected && hannover.subtitle == "Mittlerer Bahnhof")
    }

    @Test func newItemsAreThoseCollectedSinceLastLook() {
        let result = collection([
            ride("ICE 597", berlin, hamburg, departure: "2026-05-01T08:00:00Z",
                 units: [.init(model: "ICE 4", number: "9018")]),
        ])
        #expect(result.newIDs(since: nil).isEmpty)
        #expect(result.newIDs(since: ["station:berlin", "station:hamburg"]) == ["series:ICE 4", "trainset:9018"])
        #expect(result.newIDs(since: result.collectedIDs).isEmpty)
    }

    @Test func bigStationsAreTheOfficialPriceClassesOneAndTwo() {
        let all = BigStations.all
        // 21 + 87 in October 2026; the monthly data update may move a few.
        #expect(all.count(where: { $0.priceClass == 1 }) >= 15 && all.count > 80)
        #expect(all.allSatisfy { [1, 2].contains($0.priceClass) })
        #expect(Set(all.map(\.dhid)).count == all.count)
        // Every station is in the offline list, so stops can be matched to it.
        #expect(all.allSatisfy { StationNames.index.byDHID[$0.dhid] != nil })
    }

    @Test func matchesEitherLevelOfBerlinHbf() {
        let upper = station("Berlin Hbf", eva: "8011160")
        let lower = station("Berlin Hbf (tief)", eva: "8098160")
        let delfi = Station(id: "de-DELFI_de:11000:900003201", name: "S+U Berlin Hauptbahnhof", coordinate: nil,
                            evaNumber: nil, source: .transitous)
        #expect(StationNames.dhid(for: upper) == "de:11000:900003201")
        #expect(StationNames.dhid(for: lower) == "de:11000:900003201")
        #expect(StationNames.dhid(for: delfi) == "de:11000:900003201")
        let collection = TravelCollection(rides: [ride("ICE 1", lower, hamburg, departure: "2026-05-01T08:00:00Z")],
                                          now: date("2026-10-18T12:00:00Z"))
        #expect(collection.collectedIDs.contains("station:de:11000:900003201"))
        #expect(collection.collectedIDs.contains { $0.hasPrefix("station:de:02000:") })
    }
}
