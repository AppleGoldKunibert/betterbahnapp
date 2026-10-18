import Foundation
import Testing
@testable import BetterBahnKit

/// Which coaches to board for a quick transfer or exit (#383). Trains are laid out like bahn.de's
/// Wagenreihung: 26 m coaches on a 400 m platform with sectors A–H of 50 m each.
@Suite struct CoachAdviceTests {
    static let coachLength = 26.0

    /// A train whose coaches (numbers from the front) stand from `from` metres on, its front at the
    /// platform's end when it leaves towards it.
    func train(_ numbers: [String], from start: Double, towardsEnd: Bool, platform: String = "12", firstClass: Set<String> = [],
               sectors: [CoachSequence.Sector] = Self.sectors, name: String = "ICE 100") -> CoachSequence {
        let count = Double(numbers.count)
        let coaches = numbers.enumerated().map { index, number in
            let slot = towardsEnd ? count - 1 - Double(index) : Double(index)
            return CoachSequence.Coach(id: index, number: number, kind: .passenger, firstClass: firstClass.contains(number),
                                       secondClass: !firstClass.contains(number), closed: false, amenities: [], bikeSpaces: nil,
                                       start: start + slot * Self.coachLength, end: start + (slot + 1) * Self.coachLength,
                                       sector: nil, group: 0)
        }
        return CoachSequence(platform: platform, platformLength: 400, sectors: sectors,
                             groups: [.init(trainName: name, destination: nil, unit: nil, isRequestedTrain: true)],
                             coaches: coaches, travelsTowardsPlatformEnd: towardsEnd, differsFromSchedule: false,
                             formation: TrainFormation(units: []))
    }

    static let sectors = ["A", "B", "C", "D", "E", "F", "G", "H"].enumerated().map { index, name in
        CoachSequence.Sector(name: name, start: Double(index) * 50, end: Double(index + 1) * 50)
    }
    /// The same signs seen from the other track of the platform, whose positions run the other way.
    static let reversedSectors = sectors.map { CoachSequence.Sector(name: $0.name, start: 400 - $0.end, end: 400 - $0.start) }

    func numbers(_ range: ClosedRange<Int>) -> [String] { range.map(String.init) }

    let hannover = StationPlatforms(sharedPlatforms: [["11", "12"], ["13", "14"]])

    // MARK: Transfer at the same platform

    @Test func boardsOppositeTheConnectingTrain() throws {
        // ICE 100 stands at 10–322 m on track 12; the connection on track 11 at 200–382 m (in track 12's
        // positions), its own positions running the other way.
        let arriving = train(numbers(21...32), from: 10, towardsEnd: false)
        let departing = train(numbers(31...37), from: 18, towardsEnd: false, platform: "11", sectors: Self.reversedSectors, name: "ICE 200")
        let advice = try #require(CoachAdvice.transfer(arriving: arriving, departing: departing, platforms: hannover, station: "Hannover Hbf"))
        // Opposite the middle of the connecting train.
        #expect(advice.coaches == ["30", "31", "32"])
        #expect(advice.target == .connection(coach: nil))
        #expect(advice.text() == "Steig in Wagen 30–32 ein, dann stehst du in Hannover Hbf direkt an deinem Anschluss.")
        #expect(advice.text(boarded: true) == "Geh in Wagen 30–32, dann stehst du in Hannover Hbf direkt an deinem Anschluss.")
        #expect(advice.legend == "Die markierten Wagen halten in Hannover Hbf direkt an deinem Anschluss.")
    }

    @Test func boardsOppositeTheReservedCoach() throws {
        let arriving = train(numbers(21...32), from: 10, towardsEnd: false)
        // Wagen 35 of ICE 200 stands at 252–278 m in track 12's positions.
        let departing = train(numbers(31...37), from: 18, towardsEnd: false, platform: "11", sectors: Self.reversedSectors, name: "ICE 200")
        let advice = try #require(CoachAdvice.transfer(arriving: arriving, departing: departing, platforms: hannover,
                                                       station: "Hannover Hbf", reservation: (coach: "35", train: "ICE 200")))
        #expect(advice.coaches == ["29", "30", "31"])
        #expect(advice.target == .connection(coach: "35"))
        #expect(advice.text() == "Steig in Wagen 29–31 ein, dann stehst du in Hannover Hbf direkt an Wagen 35 deines Anschlusses.")
    }

    @Test func aimsForTheTravelClass() throws {
        // On the same track: ICE 200 leaves later from 200–382 m, its first class at the far end.
        let arriving = train(numbers(21...32), from: 10, towardsEnd: false)
        let departing = train(numbers(31...37), from: 200, towardsEnd: true, firstClass: ["31", "32"], name: "ICE 200")
        let second = try #require(CoachAdvice.transfer(arriving: arriving, departing: departing, platforms: nil, station: "Fulda", travelClass: 2))
        #expect(second.coaches == ["29", "30", "31"])
        // First class only has ICE 100's coaches 31 and 32 to choose from, which stand opposite each other anyway.
        let first = CoachAdvice.transfer(arriving: train(numbers(21...32), from: 10, towardsEnd: false, firstClass: ["31", "32"]),
                                         departing: departing, platforms: nil, station: "Fulda", travelClass: 1)
        #expect(first == nil)
    }

    @Test func saysNothingWhenAnyCoachDoes() {
        // The arriving train stands wholly alongside the connecting one.
        let arriving = train(numbers(21...27), from: 100, towardsEnd: false)
        let departing = train(numbers(31...42), from: 50, towardsEnd: true, name: "ICE 200")
        #expect(CoachAdvice.transfer(arriving: arriving, departing: departing, platforms: nil, station: "Fulda") == nil)
    }

    @Test func otherPlatformsDontCount() {
        // Tracks 12 and 13 aren't on the same platform, and there's nothing known about the stairs.
        let arriving = train(numbers(21...32), from: 10, towardsEnd: false)
        let departing = train(numbers(31...37), from: 200, towardsEnd: true, platform: "13", name: "ICE 200")
        #expect(CoachAdvice.transfer(arriving: arriving, departing: departing, platforms: hannover, station: "Hannover Hbf") == nil)
        // Without matching sectors, another track of the same platform can't be placed either.
        let unplaced = train(numbers(31...37), from: 200, towardsEnd: true, platform: "11", sectors: [], name: "ICE 200")
        #expect(CoachAdvice.transfer(arriving: arriving, departing: unplaced, platforms: hannover, station: "Hannover Hbf") == nil)
    }

    @Test func transferToAnotherPlatformAimsForTheStairs() throws {
        var platforms = hannover
        platforms.tracks["12"] = .init(start: .init(latitude: 52, longitude: 9), end: .init(latitude: 52.0036, longitude: 9), length: 400,
                                       accesses: [.init(kind: .stairs, position: 290)],
                                       sectorSigns: Self.sectors.map { .init(name: $0.name, position: ($0.start + $0.end) / 2) })
        let arriving = train(numbers(21...32), from: 10, towardsEnd: false)
        let departing = train(numbers(31...37), from: 200, towardsEnd: true, platform: "13", name: "ICE 200")
        let advice = try #require(CoachAdvice.transfer(arriving: arriving, departing: departing, platforms: platforms, station: "Hannover Hbf"))
        #expect(advice.coaches == ["31", "32"])
        #expect(advice.target == .access(.stairs))
        #expect(advice.text() == "Steig in Wagen 31 oder 32 ein, dann bist du in Hannover Hbf gleich an der Treppe.")
    }

    // MARK: Exit

    /// Hannover Hbf track 4 as OpenStreetMap has it: its sector signs a few metres off the middle of
    /// bahn.de's sectors (which run G–A there), stairs at 190 m and a lift at 213 m.
    let track4 = StationPlatforms.Track(
        start: .init(latitude: 52.378067, longitude: 9.739089), end: .init(latitude: 52.375731, longitude: 9.743995), length: 422,
        accesses: [.init(kind: .stairs, position: 190), .init(kind: .lift, position: 213)],
        sectorSigns: [("G", 14), ("F", 62), ("E", 120), ("D", 172), ("C", 224), ("B", 274), ("A", 330)].map { .init(name: $0.0, position: $0.1) })
    /// bahn.de's sectors of track 4 (from bahn.expert's percentages of its 422 m).
    let sectors4 = [("G", 0, 41.7), ("F", 41.7, 95.7), ("E", 95.7, 149.6), ("D", 149.6, 202.7), ("C", 202.7, 256.7),
                    ("B", 256.7, 311.4), ("A", 311.4, 422)].map { CoachSequence.Sector(name: $0.0, start: $0.1, end: $0.2) }

    @Test func placesStairsBySectorSigns() throws {
        let platforms = StationPlatforms(tracks: ["4": track4])
        // The stairs land at about 197 m, the lift at 220 m of bahn.de's platform.
        let sequence = train(numbers(21...32), from: 20, towardsEnd: true, platform: "4", sectors: sectors4)
        let advice = try #require(CoachAdvice.exit(sequence: sequence, platforms: platforms, station: "Hannover Hbf"))
        #expect(advice.coaches == ["24", "25", "26"])
        #expect(advice.target == .access(.stairs))
    }

    @Test func placesStairsByTheWayTheTrainRuns() throws {
        // A platform running 400 m north from its start, stairs 100 m from its southern end, no sector signs.
        let track = StationPlatforms.Track(start: .init(latitude: 52, longitude: 9), end: .init(latitude: 52.0036, longitude: 9),
                                           length: 400, accesses: [.init(kind: .stairs, position: 100)])
        let platforms = StationPlatforms(tracks: ["4": track])
        // The train leaves towards bahn.de's platform end, the front coach (21) there.
        let sequence = train(numbers(21...32), from: 20, towardsEnd: true, platform: "4", sectors: [])
        let north = CoachAdvice.Course(previous: nil, next: .init(latitude: 52.05, longitude: 9))
        // Heading north, bahn.de's end is the northern one: the stairs are near the rear.
        #expect(CoachAdvice.exit(sequence: sequence, platforms: platforms, station: "Celle", course: north)?.coaches == ["29", "30"])
        // Coming from the north it's heading south: the stairs are near the front.
        let south = CoachAdvice.Course(previous: .init(latitude: 52.05, longitude: 9), next: nil)
        #expect(CoachAdvice.exit(sequence: sequence, platforms: platforms, station: "Celle", course: south)?.coaches == ["21", "22"])
        // Without knowing the way, the stairs can't be placed.
        #expect(CoachAdvice.exit(sequence: sequence, platforms: platforms, station: "Celle") == nil)
    }

    @Test func endsAtTheExitOfATerminus() throws {
        // Track 13 ends at the buffer stops at 300 m, where the platform meets the station hall.
        let track = StationPlatforms.Track(start: .init(latitude: 50.105, longitude: 8.659), end: .init(latitude: 50.107, longitude: 8.663),
                                           length: 300, accesses: [.init(kind: .exit, position: 300)])
        let platforms = StationPlatforms(tracks: ["13": track])
        // Its Wagenreihung at the stop before, front first.
        let before = train(numbers(21...27), from: 50, towardsEnd: false, platform: "5")
        let advice = try #require(CoachAdvice.exit(endingAt: "13", before: before, platforms: platforms, station: "Frankfurt (Main) Hbf"))
        #expect(advice.coaches == ["21"])
        #expect(advice.text() == "Steig in Wagen 21 ein, dann bist du in Frankfurt (Main) Hbf gleich am Ausgang.")
        #expect(advice.legend == "Die markierten Wagen halten in Frankfurt (Main) Hbf gleich am Ausgang.")
    }

    @Test func transferAtATerminus() throws {
        // Both tracks end at the buffer stops; ICE 200 on track 13 leaves away from them (towards 325 m),
        // its Wagen 33 at 112–138 m from them. ICE 100 comes in on track 12 and stops at the buffer stops.
        let exit = StationPlatforms.Track(start: .init(latitude: 50.105, longitude: 8.659), end: .init(latitude: 50.107, longitude: 8.663),
                                          length: 325, accesses: [.init(kind: .exit, position: 0)])
        let platforms = StationPlatforms(sharedPlatforms: [["12", "13"]], tracks: ["12": exit, "13": exit])
        var departing = train(numbers(31...37), from: 8, towardsEnd: true, platform: "13", name: "ICE 200")
        departing.platformLength = 325
        let before = train(numbers(21...32), from: 30, towardsEnd: true, platform: "7")
        let advice = try #require(CoachAdvice.transfer(endingAt: "12", before: before, departing: departing, platforms: platforms,
                                                       station: "Frankfurt (Main) Hbf", reservation: (coach: "33", train: "ICE 200")))
        #expect(advice.coaches == ["24", "25", "26"])
        #expect(advice.target == .connection(coach: "33"))
        // Not where the tracks don't end at buffer stops.
        #expect(CoachAdvice.transfer(endingAt: "12", before: before, departing: departing, platforms: hannover, station: "Hannover Hbf") == nil)
        // To another platform it's through the station hall: the front, at the exit.
        var elsewhere = departing
        elsewhere.platform = "15"
        let hall = try #require(CoachAdvice.transfer(endingAt: "12", before: before, departing: elsewhere, platforms: platforms,
                                                     station: "Frankfurt (Main) Hbf"))
        #expect(hall.coaches == ["21"])
        #expect(hall.target == .access(.exit))
    }

    @Test func needsPositions() {
        // vagonweb's plan has no platform positions.
        var plan = train(numbers(21...32), from: 10, towardsEnd: false)
        plan.coaches = plan.coaches.map { var coach = $0; coach.start = nil; coach.end = nil; return coach }
        let departing = train(numbers(31...37), from: 200, towardsEnd: true, name: "ICE 200")
        #expect(CoachAdvice.transfer(arriving: plan, departing: departing, platforms: nil, station: "Fulda") == nil)
    }

    // MARK: A journey

    let now = Date(timeIntervalSince1970: 1_790_000_000)
    let goettingen = station("8000128", "Göttingen", 51.5365, 9.9268)
    let hannoverHbf = station("8000152", "Hannover Hbf", 52.3767, 9.7410)
    let hamburg = station("8002549", "Hamburg Hbf", 53.5530, 10.0070)

    func leg(_ name: String, from origin: Station, at departure: Double, to destination: Station, at arrival: Double,
             platform: String? = nil) -> Leg {
        Leg(origin: origin, destination: destination,
            departure: TimeInfo(planned: now.addingTimeInterval(departure * 60), actual: nil),
            arrival: TimeInfo(planned: now.addingTimeInterval(arrival * 60), actual: nil),
            departurePlatform: nil, arrivalPlatform: platform.map { PlatformInfo(planned: $0, actual: nil) }, tripId: name,
            line: Line(name: name, number: String(name.split(separator: " ")[1]), product: .highSpeed, operatorName: nil),
            direction: nil, isWalking: false, cancelled: false, stopovers: [], remarks: [], source: .bahnDe)
    }

    func stop(_ station: Station, arrival: Double?, departure: Double?) -> Stopover {
        Stopover(station: station, arrival: arrival.map { TimeInfo(planned: now.addingTimeInterval($0 * 60), actual: nil) },
                 departure: departure.map { TimeInfo(planned: now.addingTimeInterval($0 * 60), actual: nil) },
                 arrivalPlatform: nil, departurePlatform: nil, cancelled: false)
    }

    /// ICE 100 Göttingen → Hannover Hbf (track 12), going on to Hamburg, then 8 minutes later ICE 200 from track 11.
    var transferJourney: Journey {
        Journey(legs: [leg("ICE 100", from: goettingen, at: 60, to: hannoverHbf, at: 120, platform: "12"),
                       leg("ICE 200", from: hannoverHbf, at: 128, to: hamburg, at: 210)], source: .bahnDe)
    }

    var run100: [Stopover] {
        [stop(goettingen, arrival: nil, departure: 60), stop(hannoverHbf, arrival: 120, departure: 123), stop(hamburg, arrival: 200, departure: nil)]
    }

    @Test func plansATightTransfer() async throws {
        let arriving = train(numbers(21...32), from: 10, towardsEnd: false)
        let departing = train(numbers(31...37), from: 18, towardsEnd: false, platform: "11", sectors: Self.reversedSectors, name: "ICE 200")
        let run = run100
        let sequence: @Sendable (BahnDeClient.FormationRequest) async -> CoachSequence? = { request in
            guard request.station.id == "8000152" else { return nil }
            // Both asked for at Hannover Hbf, with its EVA number, which finds its platforms.
            var found = request.number == "100" ? arriving : departing
            found.eva = "8000152"
            return found
        }
        let journey = transferJourney
        let advice = await CoachAdvice.plan(for: journey, now: now, sequence: sequence, stops: { $0.tripId == "ICE 100" ? run : nil })
        #expect(advice[journey.legs[0].id]?.coaches == ["30", "31", "32"])
        #expect(advice[journey.legs[0].id]?.station == "Hannover Hbf")
        // ICE 200's run is unknown, so there's nothing for getting off in Hamburg.
        #expect(advice[journey.legs[1].id] == nil)

        // A seat reserved on ICE 100 decides where to board.
        let reserved = await CoachAdvice.plan(for: journey, reservations: [journey.legs[0].id: (coach: "25", train: "ICE 100")], now: now,
                                              sequence: sequence, stops: { _ in run })
        #expect(reserved.isEmpty)
        // One on ICE 200 is where to get to.
        let connecting = await CoachAdvice.plan(for: journey, reservations: [journey.legs[1].id: (coach: "35", train: "ICE 200")], now: now,
                                                sequence: sequence, stops: { _ in run })
        #expect(connecting[journey.legs[0].id]?.target == .connection(coach: "35"))

        // 20 minutes is time enough.
        var relaxed = journey
        relaxed.legs[1] = leg("ICE 200", from: hannoverHbf, at: 140, to: hamburg, at: 220)
        #expect(await CoachAdvice.plan(for: relaxed, now: now, sequence: sequence, stops: { _ in run }).isEmpty)
        // Nothing once ICE 100 has arrived.
        #expect(await CoachAdvice.plan(for: journey, now: now.addingTimeInterval(125 * 60), sequence: sequence, stops: { _ in run }).isEmpty)
    }

    @Test func findsWhereTheTrainGoesOn() async throws {
        let first = transferJourney.legs[0]
        let run = run100
        guard case .continuing(let request, let course) = await CoachAdvice.arrival(of: first, now: now, stops: { _ in run }) else {
            Issue.record("ICE 100 goes on from Hannover Hbf")
            return
        }
        #expect(request.station.id == "8000152")
        #expect(request.plannedDeparture == now.addingTimeInterval(123 * 60))
        #expect(course.previous == goettingen.coordinate)
        #expect(course.next == hamburg.coordinate)

        // Ending there, its Wagenreihung at the stop before counts.
        let ending = [stop(goettingen, arrival: nil, departure: 60), stop(hannoverHbf, arrival: 120, departure: nil)]
        guard case .ending(let before) = await CoachAdvice.arrival(of: first, now: now, stops: { _ in ending }) else {
            Issue.record("ICE 100 ends in Hannover Hbf")
            return
        }
        #expect(before.station.id == "8000128")
        #expect(before.plannedDeparture == now.addingTimeInterval(60 * 60))
        // Without the run it's unknown whether the train goes on.
        #expect(await CoachAdvice.arrival(of: first, now: now, stops: { _ in nil }) == nil)
    }

    // MARK: Pieces

    @Test func listsCoaches() {
        #expect(CoachAdvice(coaches: ["21"], target: .access(.lift), station: "Celle").coachList == "Wagen 21")
        #expect(CoachAdvice(coaches: ["21", "22"], target: .access(.lift), station: "Celle").coachList == "Wagen 21 oder 22")
        #expect(CoachAdvice(coaches: ["21", "22", "23"], target: .access(.lift), station: "Celle").coachList == "Wagen 21–23")
        #expect(CoachAdvice(coaches: ["25", "26", "28"], target: .access(.lift), station: "Celle").coachList == "Wagen 25, 26 oder 28")
        #expect(CoachAdvice(coaches: ["5"], target: .access(.lift), station: "Celle").text() == "Steig in Wagen 5 ein, dann bist du in Celle gleich am Aufzug.")
    }

    @Test func marksTheCoachesOfTheRequestedTrain() {
        var coupled = train(numbers(21...26) + numbers(21...26), from: 10, towardsEnd: false)
        coupled.groups.append(.init(trainName: "ICE 300", destination: "Köln Hbf", unit: nil, isRequestedTrain: false))
        for index in 6..<12 { coupled.coaches[index].group = 1 }
        let advice = CoachAdvice(coaches: ["22", "23"], target: .access(.stairs), station: "Hamm (Westf) Hbf")
        #expect(coupled.coachIDs(for: advice) == [1, 2])
    }

    @Test func fitsSectorSignsOnlyWhenTheyAgree() throws {
        let reversed = try #require(CoachSequence.fit([(from: 25, to: 375), (from: 125, to: 275), (from: 225, to: 175)]))
        #expect(reversed(0) == 400)
        #expect(CoachSequence.fit([(from: 0, to: 0), (from: 100, to: 300)]) == nil)
        #expect(CoachSequence.fit([(from: 0, to: 0)]) == nil)
    }

    @Test func readsPlatforms() throws {
        let json = #"{"8000152":{"p":[["11","12"]],"t":{"12":[52.379,9.738,52.376,9.743,438,[["s",286],["l",307],["x",438],["?",1]],[["F",108]]]}}}"#
        let platforms = try #require(StationPlatforms.parse(Data(json.utf8))["8000152"])
        #expect(platforms.sharePlatform("11", "Gleis 12"))
        #expect(!platforms.sharePlatform("11", "13"))
        #expect(platforms.sharePlatform("13", "13"))
        let track = try #require(platforms.track("12"))
        #expect(track.length == 438)
        #expect(track.accesses == [.init(kind: .stairs, position: 286), .init(kind: .lift, position: 307), .init(kind: .exit, position: 438)])
        #expect(track.sectorSigns == [.init(name: "F", position: 108)])
        // The app's own data: Hannover Hbf's tracks 11 and 12 share a platform.
        #expect(StationPlatforms.at(eva: "8000152")?.sharePlatform("11", "12") == true)
        #expect(StationPlatforms.at(eva: "8000152")?.sharePlatform("12", "13") == false)
    }
}
