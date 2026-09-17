#if DEBUG
import BetterBahnKit
import SwiftUI

/// Launch with `-debugScreen <name>` to render a screen with sample data (for screenshots).
extension AppModel {
    /// Launch with `-seedDemoTrips YES` to save a few real, overlapping journeys (for testing the map).
    func seedDemoTripsIfRequested() async {
        guard UserDefaults.standard.bool(forKey: "seedDemoTrips"), savedJourneys.count < 3 else { return }
        let routes = [("Köln Hbf", "Berlin Hbf"), ("Köln Hbf", "Hamburg Hbf"), ("Düsseldorf Hbf", "Hannover Hbf"), ("Köln Hbf", "Frankfurt(Main)Hbf")]
        for (from, to) in routes {
            guard let a = try? await provider.searchStations(from).first,
                  let b = try? await provider.searchStations(to).first,
                  let page = try? await provider.journeys(JourneyQuery(from: a, to: b, date: .now.addingTimeInterval(-6 * 3600))),
                  let journey = page.journeys.first else { continue }
            save(journey)
        }
    }
}

extension AppModel {
    /// Launch with `-seedBrokenTrip YES` to save a journey whose transfer no longer works.
    /// Re-seeds with fresh, relative-to-now times if the previous run's ICE 10 has already finished,
    /// since its times are frozen at first launch and would otherwise go stale across test sessions.
    func seedBrokenTripIfRequested() {
        guard UserDefaults.standard.bool(forKey: "seedBrokenTrip") else { return }
        if let existing = savedJourneys.first(where: { $0.journey.legs.first?.line?.name == "ICE 10" }) {
            guard existing.isFinished else { return }
            unsave(existing.journey)
        }
        let start = Date.now.addingTimeInterval(45 * 60)
        func t(_ minutes: Double, _ delay: Double = 0) -> TimeInfo {
            TimeInfo(planned: start.addingTimeInterval(minutes * 60), actual: start.addingTimeInterval((minutes + delay) * 60))
        }
        func station(_ id: String, _ name: String, _ lat: Double, _ lon: Double) -> Station {
            Station(id: id, name: name, coordinate: Coordinate(latitude: lat, longitude: lon), evaNumber: id, source: .bahnDe)
        }
        let koeln = station("8000207", "Köln Hbf", 50.943, 6.958)
        let hannover = station("8000152", "Hannover Hbf", 52.376, 9.741)
        let berlin = station("8011160", "Berlin Hbf", 52.525, 13.369)
        let first = Leg(origin: koeln, destination: hannover, departure: t(0, 5), arrival: t(160, 25),
                        departurePlatform: PlatformInfo(planned: "5", actual: "5"), arrivalPlatform: PlatformInfo(planned: "8", actual: "8"),
                        tripId: nil, line: Line(name: "ICE 10", number: "10", product: .highSpeed, operatorName: "DB Fernverkehr AG"),
                        direction: "Berlin Ostbahnhof", isWalking: false, cancelled: false, stopovers: [], remarks: [], source: .transitous)
        let second = Leg(origin: hannover, destination: berlin, departure: t(175), arrival: t(275),
                         departurePlatform: PlatformInfo(planned: "11", actual: "11"), arrivalPlatform: PlatformInfo(planned: "14", actual: "14"),
                         tripId: nil, line: Line(name: "ICE 849", number: "849", product: .highSpeed, operatorName: "DB Fernverkehr AG"),
                         direction: "Berlin Ostbahnhof", isWalking: false, cancelled: false, stopovers: [], remarks: [], source: .transitous)
        save(Journey(legs: [first, second], source: .transitous))
    }
}

struct DebugScreen: View {
    let name: String
    @State private var boarding: String? = PreviewData.trip.stopovers[1].id
    @State private var exit: String? = PreviewData.trip.stopovers[5].id

    static var requested: String? {
        UserDefaults.standard.string(forKey: "debugScreen")
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    switch name {
                    case "results":
                        JourneyCard(journey: PreviewData.journey)
                        JourneyCard(journey: PreviewData.directJourney)
                        JourneyCard(journey: PreviewData.regionalJourney)
                    case "legs":
                        LegCard(leg: PreviewData.firstLeg, onReplace: {}, onCheckin: {})
                        TransferRow(from: PreviewData.firstLeg, to: PreviewData.secondLeg, walk: PreviewData.walk)
                        LegCard(leg: PreviewData.secondLeg, onReplace: {}, onCheckin: {})
                    case "board":
                        Card(padding: 0) {
                            VStack(spacing: 0) {
                                ForEach(Array(PreviewData.board.enumerated()), id: \.element.id) { index, entry in
                                    if index > 0 { Divider().padding(.leading, 84) }
                                    BoardRow(entry: entry)
                                }
                            }
                        }
                    case "trip":
                        TripContent(trip: PreviewData.trip, highlight: PreviewData.duesseldorf, boardingID: $boarding, exitID: $exit)
                    case "ticket":
                        CheckinTicket(leg: PreviewData.firstLeg)
                        AlternativeRow(leg: PreviewData.secondLeg, current: PreviewData.firstLeg)
                    default:
                        Text("Unbekannt: \(name)")
                    }
                }
                .padding(.horizontal)
            }
            .background { AppBackground() }
            .navigationTitle(name.capitalized)
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
#endif
