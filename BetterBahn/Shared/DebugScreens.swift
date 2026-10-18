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
    /// Launch with `-seedLateTrips YES` to add two finished journeys that arrived over an hour late (Fahrgastrechte,
    /// #311): an ICE 75 minutes late, and a missed connection replaced by a later train. Only adds, never
    /// removes saved journeys; remove them by hand afterwards (they sync through iCloud like any saved journey).
    func seedLateTripsIfRequested() {
        guard UserDefaults.standard.bool(forKey: "seedLateTrips"),
              !savedJourneys.contains(where: { $0.journey.legs.first?.tripId?.hasPrefix("lateseed-") == true }) else { return }
        func station(_ id: String, _ name: String) -> Station {
            Station(id: id, name: name, coordinate: nil, evaNumber: id, source: .bahnDe)
        }
        let hamburg = station("8002549", "Hamburg Hbf"), muenchen = station("8000261", "München Hbf")
        let koeln = station("8000207", "Köln Hbf"), frankfurt = station("8000105", "Frankfurt(Main)Hbf")
        func leg(_ id: String, _ name: String, from: Station, to: Station, departs: Double, arrives: Double,
                 departDelay: Double = 0, arriveDelay: Double = 0) -> Leg {
            func time(_ minutes: Double, _ delay: Double) -> TimeInfo {
                let planned = Date.now.addingTimeInterval(minutes * 60)
                return TimeInfo(planned: planned, actual: planned.addingTimeInterval(delay * 60))
            }
            let number = name.split(separator: " ").last.map(String.init)
            return Leg(origin: from, destination: to, departure: time(departs, departDelay), arrival: time(arrives, arriveDelay),
                       departurePlatform: nil, arrivalPlatform: nil, tripId: "lateseed-" + id,
                       line: Line(name: name, number: number, product: .highSpeed, operatorName: "DB Fernverkehr AG"),
                       direction: to.name, isWalking: false, cancelled: false, stopovers: [], remarks: [], source: .bahnDe)
        }
        // 1. The ICE arrived 75 minutes late.
        save(Journey(legs: [leg("1", "ICE 71", from: hamburg, to: muenchen, departs: -440, arrives: -120,
                                departDelay: 60, arriveDelay: 75)], source: .bahnDe))
        // 2. ICE 20 came 70 minutes late into Frankfurt, ICE 50 had left; ICE 928 was taken instead.
        let first = leg("2", "ICE 20", from: koeln, to: frankfurt, departs: -330, arrives: -240, departDelay: 60, arriveDelay: 70)
        let booked = Journey(legs: [first, leg("3", "ICE 50", from: frankfurt, to: muenchen, departs: -230, arrives: -110)], source: .bahnDe)
        let replacement = Journey(legs: [first, leg("4", "ICE 928", from: frankfurt, to: muenchen, departs: -140, arrives: -35)], source: .bahnDe)
        save(booked)
        if let entry = savedEntry(for: booked) {
            replaceSaved(id: entry.id, with: replacement, reason: "Anderer Zug gewählt")
        }
    }
}

extension AppModel {
    /// Launch with `-seedStressTrips <count>` to fill the map with a large synthetic trip history (perf testing only).
    func seedStressTripsIfRequested() async {
        await loadTraewellingTrips()
        let count = UserDefaults.standard.integer(forKey: "seedStressTrips")
        guard count > 0, traewellingTrips.count < count else { return }
        func station(_ id: String, _ name: String, _ lat: Double, _ lon: Double) -> Station {
            Station(id: id, name: name, coordinate: Coordinate(latitude: lat, longitude: lon), evaNumber: id, source: .traewelling)
        }
        let stations = [
            station("1", "Köln Hbf", 50.943, 6.958), station("2", "Berlin Hbf", 52.525, 13.369),
            station("3", "Hamburg Hbf", 53.553, 10.007), station("4", "München Hbf", 48.140, 11.558),
            station("5", "Frankfurt(Main)Hbf", 50.107, 8.663), station("6", "Hannover Hbf", 52.376, 9.741),
            station("7", "Stuttgart Hbf", 48.784, 9.182), station("8", "Leipzig Hbf", 51.345, 12.383),
        ]
        var trips: [ImportedTrip] = []
        for i in 0..<count {
            let from = stations[i % stations.count]
            let to = stations[(i + 1 + i / stations.count) % stations.count]
            let departure = Date.now.addingTimeInterval(-Double(i) * 6 * 3600)
            let leg = Leg(origin: from, destination: to,
                          departure: TimeInfo(planned: departure, actual: nil),
                          arrival: TimeInfo(planned: departure.addingTimeInterval(3600), actual: nil),
                          departurePlatform: nil, arrivalPlatform: nil, tripId: "stress-\(i)",
                          line: Line(name: "ICE \(100 + i % 400)", number: "\(100 + i % 400)", product: .highSpeed, operatorName: nil),
                          direction: nil, isWalking: false, cancelled: false, stopovers: [], remarks: [], source: .traewelling)
            trips.append(ImportedTrip(statusID: i, journey: Journey(legs: [leg], source: .traewelling)))
        }
        traewellingTrips = trips
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

extension AppModel {
    /// Launch with `-seedSeatMapTrips YES` to save two made-up ICE journeys leaving in 20 minutes, each with a seat
    /// reservation and a made-up Wagenreihung, for trying the seat maps (#365): ICE 9901 is an ICE 1 standing
    /// turned round (Wagen 12, Platz 43), ICE 9902 an ICE 3neo (Wagen 24, Platz 78). Re-seeds once they have
    /// left; remove them by hand afterwards (they sync through iCloud like any saved journey).
    func seedSeatMapTripsIfRequested() {
        guard UserDefaults.standard.bool(forKey: "seedSeatMapTrips") else { return }
        let seeded = savedJourneys.filter { $0.journey.legs.first?.tripId?.hasPrefix("seatseed-") == true }
        guard seeded.isEmpty || seeded.allSatisfy({ $0.journey.legs[0].departure.planned < .now }) else { return }
        seeded.forEach { unsave($0.journey) }
        func station(_ id: String, _ name: String, _ lat: Double, _ lon: Double) -> Station {
            Station(id: id, name: name, coordinate: Coordinate(latitude: lat, longitude: lon), evaNumber: id, source: .bahnDe)
        }
        let koeln = station("8000207", "Köln Hbf", 50.943, 6.958), frankfurt = station("8000105", "Frankfurt(Main)Hbf", 50.107, 8.663)
        let hamburg = station("8002549", "Hamburg Hbf", 53.553, 10.007), berlin = station("8011160", "Berlin Hbf", 52.525, 13.369)
        for (index, train) in Self.seatMapDemoTrains.enumerated() {
            let departure = Date.now.addingTimeInterval(Double(20 + index * 5) * 60)
            let (from, to) = index == 0 ? (hamburg, frankfurt) : (koeln, berlin)
            let leg = Leg(origin: from, destination: to,
                          departure: TimeInfo(planned: departure, actual: nil),
                          arrival: TimeInfo(planned: departure.addingTimeInterval(4 * 3600), actual: nil),
                          departurePlatform: PlatformInfo(planned: "7", actual: "7"), arrivalPlatform: PlatformInfo(planned: "9", actual: "9"),
                          tripId: "seatseed-\(train.number)",
                          line: Line(name: "ICE \(train.number)", number: train.number, product: .highSpeed, operatorName: "DB Fernverkehr AG"),
                          direction: to.name, isWalking: false, cancelled: false, stopovers: [], remarks: [], source: .bahnDe)
            save(Journey(legs: [leg], source: .bahnDe))
        }
    }

    private struct SeatMapDemoTrain {
        var number: String
        var sheet: String
        var unit: TrainFormation.Unit
        var turned: Bool
        var reservation: SeatReservation
    }

    private static let seatMapDemoTrains = [
        SeatMapDemoTrain(number: "9901", sheet: "401", unit: TrainFormation.Unit(model: "ICE 1", number: "199", name: "Testzug"),
                         turned: true, reservation: SeatReservation(trainName: "ICE 9901", coach: "12", seats: ["43"])),
        SeatMapDemoTrain(number: "9902", sheet: "408", unit: TrainFormation.Unit(model: "ICE 3neo", number: "8030"),
                         turned: false, reservation: SeatReservation(trainName: "ICE 9902", coach: "24", seats: ["78"])),
    ]

    /// The made-up Wagenreihung of a seeded seat-map train.
    func debugCoachSequence(for request: BahnDeClient.FormationRequest) -> CoachSequence? {
        if let advice = debugAdviceSequence(for: request) { return advice }
        guard request.category == "ICE", let train = Self.seatMapDemoTrains.first(where: { $0.number == request.number }) else { return nil }
        return CoachSequence.seatMapDemo(sheet: train.sheet, trainName: "ICE \(train.number)", unit: train.unit, turned: train.turned)
    }

    /// The seat reservation of a seeded seat-map train.
    func debugReservation(for leg: Leg) -> SeatReservation? {
        guard leg.tripId?.hasPrefix("seatseed-") == true else { return nil }
        return Self.seatMapDemoTrains.first { $0.number == leg.line?.number }?.reservation
    }
}

extension AppModel {
    /// Launch with `-seedCoachAdviceTrips YES` to save two made-up journeys leaving in 20 minutes with made-up
    /// Wagenreihungen, for trying the coach advice (#383): ICE 9911 Göttingen → Hannover Hbf (Gleis 12), going on
    /// to Hamburg, and ICE 9912 leaving 6 minutes later across the platform (Gleis 11, shorter, at the far end);
    /// ICE 9913 Mannheim → Frankfurt(Main)Hbf, ending at Gleis 13 of the terminus. Re-seeds once they have left;
    /// remove them by hand afterwards.
    func seedCoachAdviceTripsIfRequested() {
        guard UserDefaults.standard.bool(forKey: "seedCoachAdviceTrips") else { return }
        let seeded = savedJourneys.filter { $0.journey.legs.first?.tripId?.hasPrefix("adviceseed-") == true }
        guard seeded.isEmpty || seeded.allSatisfy({ $0.journey.legs[0].departure.planned < .now }) else { return }
        seeded.forEach { unsave($0.journey) }
        let start = Date.now.addingTimeInterval(20 * 60)
        func leg(_ number: String, _ from: Station, _ departure: Double, _ to: Station, _ arrival: Double,
                 from fromTrack: String, to toTrack: String) -> Leg {
            Leg(origin: from, destination: to,
                departure: TimeInfo(planned: start.addingTimeInterval(departure * 60), actual: nil),
                arrival: TimeInfo(planned: start.addingTimeInterval(arrival * 60), actual: nil),
                departurePlatform: PlatformInfo(planned: fromTrack, actual: nil), arrivalPlatform: PlatformInfo(planned: toTrack, actual: nil),
                tripId: "adviceseed-\(number)",
                line: Line(name: "ICE \(number)", number: number, product: .highSpeed, operatorName: "DB Fernverkehr AG"),
                direction: to.name, isWalking: false, cancelled: false, stopovers: [], remarks: [], source: .bahnDe)
        }
        let s = Self.adviceStations
        save(Journey(legs: [leg("9911", s.goettingen, 0, s.hannover, 60, from: "8", to: "12"),
                            leg("9912", s.hannover, 66, s.berlin, 160, from: "11", to: "14")], source: .bahnDe))
        save(Journey(legs: [leg("9913", s.mannheim, 5, s.frankfurt, 45, from: "3", to: "13")], source: .bahnDe))
    }

    private static let adviceStations = {
        func station(_ id: String, _ name: String, _ lat: Double, _ lon: Double) -> Station {
            Station(id: id, name: name, coordinate: Coordinate(latitude: lat, longitude: lon), evaNumber: id, source: .bahnDe)
        }
        return (goettingen: station("8000128", "Göttingen", 51.536, 9.927), hannover: station("8000152", "Hannover Hbf", 52.376, 9.741),
                hamburg: station("8002549", "Hamburg Hbf", 53.553, 10.007), berlin: station("8011160", "Berlin Hbf", 52.525, 13.369),
                mannheim: station("8000244", "Mannheim Hbf", 49.479, 8.469), frankfurt: station("8000105", "Frankfurt(Main)Hbf", 50.107, 8.663))
    }()

    /// The made-up Wagenreihung of a seeded coach-advice train: ICE 9911 a long ICE 4 on Gleis 12, ICE 9912 a
    /// short one on Gleis 11 at the far end, ICE 9913 an ICE 3neo.
    func debugAdviceSequence(for request: BahnDeClient.FormationRequest) -> CoachSequence? {
        guard request.category == "ICE", ["9911", "9912", "9913"].contains(request.number),
              var sequence = CoachSequence.seatMapDemo(sheet: request.number == "9913" ? "408" : "412", trainName: "ICE \(request.number)",
                                                       unit: TrainFormation.Unit(model: "ICE 4", number: "9\(request.number.suffix(3))"))
        else { return nil }
        sequence.eva = request.station.evaNumber
        sequence.platform = switch (request.number, request.station.id) {
        case ("9912", _): "11"
        case ("9911", "8000152"): "12"
        case ("9911", _): "8"
        default: "3"
        }
        if request.number == "9912", let long = CoachSequence.seatMapDemo(sheet: "412", trainName: "ICE 9911",
                                                                        unit: TrainFormation.Unit(model: "ICE 4", number: "9911")) {
            // Seven coaches standing at the far end of the long train's platform, with its sectors.
            sequence.coaches = Array(sequence.coaches.prefix(7)).map { coach in
                var coach = coach
                coach.start = coach.start.map { $0 + 130 }
                coach.end = coach.end.map { $0 + 130 }
                return coach
            }
            sequence.sectors = long.sectors
            sequence.platformLength = long.platformLength
        }
        return sequence
    }

    /// The made-up runs of the seeded coach-advice trains: ICE 9911 goes on to Hamburg, ICE 9913 ends in Frankfurt.
    func debugRunStops(of leg: Leg) -> [Stopover]? {
        guard leg.tripId?.hasPrefix("adviceseed-") == true else { return nil }
        func stop(_ station: Station, _ arrival: Date?, _ departure: Date?) -> Stopover {
            Stopover(station: station, arrival: arrival.map { TimeInfo(planned: $0, actual: nil) },
                     departure: departure.map { TimeInfo(planned: $0, actual: nil) }, arrivalPlatform: nil, departurePlatform: nil, cancelled: false)
        }
        let s = Self.adviceStations
        switch leg.line?.number {
        case "9911": return [stop(s.goettingen, nil, leg.departure.planned), stop(s.hannover, leg.arrival.planned, leg.arrival.planned.addingTimeInterval(180)),
                             stop(s.hamburg, leg.arrival.planned.addingTimeInterval(80 * 60), nil)]
        case "9913": return [stop(s.mannheim, nil, leg.departure.planned), stop(s.frankfurt, leg.arrival.planned, nil)]
        default: return nil
        }
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
                    case "transfers":
                        TransferRow(from: PreviewData.firstLeg, to: PreviewData.secondLeg, disposition: .waiting)
                        TransferRow(from: PreviewData.firstLeg, to: PreviewData.secondLeg, walk: PreviewData.walk, disposition: .notWaiting)
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
