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

    // MARK: As seen from the platform (#474)

    @Test func turnsRoundToLeaveAsSeenFromThePlatform() {
        // Leaving towards sector A (the platform's start) with the platform on the train's right: people
        // there see it leave to their right, so A comes on the right.
        let sequence = train(numbers(21...24), from: 10, towardsEnd: false)
        let turned = sequence.asSeenFromPlatform(side: .right)
        #expect(turned.travelsTowardsPlatformEnd == true)
        #expect(turned.sectors.first?.name == "H")
        #expect(turned.sectors.last == CoachSequence.Sector(name: "A", start: 350, end: 400))
        // The front coach stood at 10–36 m, now at 364–390 m; the order from the front stays.
        #expect(turned.coaches.map(\.number) == sequence.coaches.map(\.number))
        #expect(turned.coaches.first?.start == 364)
        #expect(turned.coaches.first?.end == 390)
        // Already the way they see it, or nothing known: unchanged.
        #expect(sequence.asSeenFromPlatform(side: .left) == sequence)
        #expect(train(numbers(21...24), from: 10, towardsEnd: true).asSeenFromPlatform(side: .right).travelsTowardsPlatformEnd == true)
        #expect(sequence.asSeenFromPlatform(side: nil) == sequence)
        var plan = sequence
        plan.source = .vagonweb(validFrom: nil, validUntil: nil)
        #expect(plan.asSeenFromPlatform(side: .right) == plan)
        // A train standing past the platform's end (400 m) keeps every position at 0 or more.
        let long = train(numbers(21...36), from: 10, towardsEnd: false).asSeenFromPlatform(side: .right)
        #expect(long.coaches.allSatisfy { ($0.start ?? -1) >= 0 })
        #expect(long.coaches.last?.start == 0)
    }

    // MARK: Transfer at the same platform

    @Test func boardsOppositeTheConnectingTrain() throws {
        // ICE 100 stands at 10–322 m on track 12; the connection on track 11 at 200–382 m (in track 12's
        // positions), its own positions running the other way.
        let arriving = train(numbers(21...32), from: 10, towardsEnd: false)
        let departing = train(numbers(31...37), from: 18, towardsEnd: false, platform: "11", sectors: Self.reversedSectors, name: "ICE 200")
        let advice = try #require(CoachAdvice.transfer(arriving: arriving, departing: departing, platforms: hannover, station: "Hannover Hbf"))
        // Opposite the middle of the connecting train.
        #expect(advice.coaches == ["31", "32"])
        #expect(advice.target == .connection(coach: nil))
        #expect(advice.text() == "In Wagen 31 oder 32 einsteigen, um in Hannover Hbf direkt an deinem Anschluss auszusteigen.")
        #expect(advice.text(boarded: true) == "In Wagen 31 oder 32 wechseln, um in Hannover Hbf direkt an deinem Anschluss auszusteigen.")
        #expect(advice.legend == "Die markierten Wagen halten in Hannover Hbf direkt an deinem Anschluss.")
    }

    @Test func boardsOppositeTheReservedCoach() throws {
        let arriving = train(numbers(21...32), from: 10, towardsEnd: false)
        // Wagen 35 of ICE 200 stands at 252–278 m in track 12's positions.
        let departing = train(numbers(31...37), from: 18, towardsEnd: false, platform: "11", sectors: Self.reversedSectors, name: "ICE 200")
        let advice = try #require(CoachAdvice.transfer(arriving: arriving, departing: departing, platforms: hannover,
                                                       station: "Hannover Hbf", reservation: (coach: "35", train: "ICE 200")))
        #expect(advice.coaches == ["30", "31"])
        #expect(advice.target == .connection(coach: "35"))
        #expect(advice.text() == "In Wagen 30 oder 31 einsteigen, um in Hannover Hbf direkt an Wagen 35 deines Anschlusses auszusteigen.")
    }

    @Test func walksFromAReservedSeatBeforeArriving() throws {
        let arriving = train(numbers(21...32), from: 10, towardsEnd: false)
        let departing = train(numbers(31...37), from: 18, towardsEnd: false, platform: "11", sectors: Self.reversedSectors, name: "ICE 200")
        // The seat in Wagen 22 stands 138 m short of the connecting train: walk to Wagen 30–32 before arriving.
        let advice = try #require(CoachAdvice.transfer(arriving: arriving, departing: departing, platforms: hannover,
                                                       station: "Hannover Hbf", seat: (coach: "22", train: "ICE 100")))
        #expect(advice.coaches == ["31", "32"])
        #expect(advice.walkBeforeArrival)
        #expect(advice.text() == "Vor der Ankunft in Wagen 31 oder 32 wechseln, um in Hannover Hbf direkt an deinem Anschluss auszusteigen.")
        // Next to the transfer, which names the station already.
        #expect(advice.text(boarded: true, namingStation: false) == "Vor der Ankunft in Wagen 31 oder 32 wechseln, um direkt an deinem Anschluss auszusteigen.")
        // The seat's coach is framed in the Wagenreihung too, so the note says which coaches.
        #expect(advice.legend == advice.text())
        // A seat 8 m short of it or opposite it is right already, and one in a coach the train lacks says nothing.
        for coach in ["27", "31"] {
            let right = try #require(CoachAdvice.transfer(arriving: arriving, departing: departing, platforms: hannover,
                                                          station: "Hannover Hbf", seat: (coach: coach, train: "ICE 100")))
            #expect(right.alreadyThere)
            #expect(!right.walkBeforeArrival)
            #expect(right.coaches == [coach])
            #expect(right.text(boarded: true, namingStation: false) == "Du sitzt schon im richtigen Wagen, um direkt an deinem Anschluss auszusteigen.")
            #expect(right.legend == "Du sitzt schon im richtigen Wagen, um in Hannover Hbf direkt an deinem Anschluss auszusteigen.")
        }
        #expect(CoachAdvice.transfer(arriving: arriving, departing: departing, platforms: hannover, station: "Hannover Hbf",
                                     seat: (coach: "45", train: "ICE 100")) == nil)
    }

    @Test func aimsForTheTravelClass() throws {
        // On the same track: ICE 200 leaves later from 200–382 m, its first class at the far end.
        let arriving = train(numbers(21...32), from: 10, towardsEnd: false)
        let departing = train(numbers(31...37), from: 200, towardsEnd: true, firstClass: ["31", "32"], name: "ICE 200")
        let second = try #require(CoachAdvice.transfer(arriving: arriving, departing: departing, platforms: nil, station: "Fulda", travelClass: 2))
        #expect(second.coaches == ["30", "31"])
        // First class only has ICE 100's coaches 31 and 32, both near ICE 200's first class: the nearer one still.
        let firstClass = train(numbers(21...32), from: 10, towardsEnd: false, firstClass: ["31", "32"])
        let first = try #require(CoachAdvice.transfer(arriving: firstClass, departing: departing, platforms: nil, station: "Fulda",
                                                      travelClass: 1))
        #expect(first.coaches == ["32"])
        // A seat in second class tells the class, whatever the settings say.
        let seated = try #require(CoachAdvice.transfer(arriving: firstClass, departing: departing, platforms: nil, station: "Fulda",
                                                       travelClass: 1, seat: (coach: "22", train: "ICE 100")))
        #expect(seated.coaches == ["29", "30"])
        #expect(seated.walkBeforeArrival)
    }

    @Test func saysNothingWhenAnyCoachDoes() {
        // The arriving train stands wholly alongside the connecting one.
        let arriving = train(numbers(21...27), from: 100, towardsEnd: false)
        let departing = train(numbers(31...42), from: 50, towardsEnd: true, name: "ICE 200")
        #expect(CoachAdvice.transfer(arriving: arriving, departing: departing, platforms: nil, station: "Fulda") == nil)
        // Nor that a seat is right, when every one is.
        #expect(CoachAdvice.transfer(arriving: arriving, departing: departing, platforms: nil, station: "Fulda",
                                     seat: (coach: "24", train: "ICE 100")) == nil)
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
        #expect(advice.text() == "In Wagen 31 oder 32 einsteigen, um in Hannover Hbf direkt an der Treppe auszusteigen.")
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
        #expect(advice.coaches == ["25", "26"])
        #expect(advice.target == .access(.stairs))
    }

    @Test func namesBothStairsAlongALongTrain() throws {
        // Köln Hbf has stairs at both underpasses: here at 60 m and 300 m, both within the train.
        let track = StationPlatforms.Track(start: .init(latitude: 50.943, longitude: 6.958), end: .init(latitude: 50.9466, longitude: 6.958),
                                           length: 400, accesses: [.init(kind: .stairs, position: 60), .init(kind: .stairs, position: 300)],
                                           sectorSigns: Self.sectors.map { .init(name: $0.name, position: ($0.start + $0.end) / 2) })
        let platforms = StationPlatforms(tracks: ["12": track])
        let advice = try #require(CoachAdvice.exit(sequence: train(numbers(21...32), from: 10, towardsEnd: false),
                                                   platforms: platforms, station: "Köln Hbf"))
        #expect(advice.groups == [["22", "23"], ["31", "32"]])
        #expect(advice.text() == "In Wagen 22–23 oder 31–32 einsteigen, um in Köln Hbf direkt an der Treppe auszusteigen.")
        // On the train, without a known seat, the stairs nearest the middle of the class (Wagen 27).
        let aboard = try #require(CoachAdvice.exit(sequence: train(numbers(21...32), from: 10, towardsEnd: false),
                                                   platforms: platforms, station: "Köln Hbf", aboard: true))
        #expect(aboard.groups == [["22", "23"]])
        #expect(aboard.text(boarded: true) == "In Wagen 22 oder 23 wechseln, um in Köln Hbf direkt an der Treppe auszusteigen.")
        // From a seat towards the rear, the stairs there.
        let seated = try #require(CoachAdvice.exit(sequence: train(numbers(21...32), from: 10, towardsEnd: false),
                                                   platforms: platforms, station: "Köln Hbf", seat: (coach: "29", train: "ICE 100")))
        #expect(seated.groups == [["31", "32"]])
        #expect(seated.text() == "Vor der Ankunft in Wagen 31 oder 32 wechseln, um in Köln Hbf direkt an der Treppe auszusteigen.")
    }

    @Test func takesTheMiddleOfTheClass() {
        let sequence = train(numbers(21...32), from: 10, towardsEnd: false, firstClass: ["30", "31", "32"])
        #expect(CoachAdvice.middle(of: sequence.boardable(travelClass: 2))?.number == "25")
        #expect(CoachAdvice.middle(of: sequence.boardable(travelClass: 1))?.number == "31")
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

    @Test func placesTheExitOfATerminusTheTrainGoesOnFrom() throws {
        // Stralsund Hbf: track 2 runs 322 m south from the buffer stops at its northern start. The train came
        // from the south and goes on, reversing, to Bergen auf Rügen, which lies east: no help in telling the ends apart.
        let track = StationPlatforms.Track(start: .init(latitude: 54.3085, longitude: 13.078), end: .init(latitude: 54.3056, longitude: 13.078),
                                           length: 322, accesses: [.init(kind: .exit, position: 0)])
        let platforms = StationPlatforms(tracks: ["2": track])
        let bergen = CoachAdvice.Course(previous: .init(latitude: 54.09, longitude: 13.38), next: .init(latitude: 54.307, longitude: 13.42))
        // It leaves away from the buffer stops: towards bahn.de's end, its rear coach (9) at the buffer stops by bahn.de's start …
        let leaving = train(numbers(1...9), from: 8, towardsEnd: true, platform: "2", sectors: [])
        let advice = try #require(CoachAdvice.exit(sequence: leaving, platforms: platforms, station: "Stralsund Hbf", course: bergen,
                                                   toExit: true))
        #expect(advice.coaches == ["9"])
        #expect(advice.text() == "In Wagen 9 einsteigen, um in Stralsund Hbf direkt am Ausgang auszusteigen.")
        // … or towards bahn.de's start, the buffer stops by its end.
        let other = train(numbers(1...9), from: 400 - 8 - 9 * Self.coachLength, towardsEnd: false, platform: "2", sectors: [])
        #expect(CoachAdvice.exit(sequence: other, platforms: platforms, station: "Stralsund Hbf", course: bergen, toExit: true)?.coaches == ["9"])
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
        #expect(advice.text() == "In Wagen 21 einsteigen, um in Frankfurt (Main) Hbf direkt am Ausgang auszusteigen.")
        #expect(advice.legend == "Die markierten Wagen halten in Frankfurt (Main) Hbf direkt am Ausgang.")
    }

    @Test func endsAtTheFrontOfATerminusPastItsUnderpass() throws {
        // Stairs down to an underpass at 150 m and the exit to the station hall at the buffer stops, 300 m.
        let track = StationPlatforms.Track(start: .init(latitude: 50.105, longitude: 8.659), end: .init(latitude: 50.107, longitude: 8.663),
                                           length: 300, accesses: [.init(kind: .stairs, position: 150), .init(kind: .exit, position: 300)])
        let platforms = StationPlatforms(tracks: ["13": track])
        let before = train(numbers(21...27), from: 50, towardsEnd: false, platform: "5")
        // Where the journey ends, out through the hall: the front of the train.
        let out = try #require(CoachAdvice.exit(endingAt: "13", before: before, platforms: platforms, station: "Frankfurt (Main) Hbf",
                                                toExit: true))
        #expect(out.coaches == ["21"])
        #expect(out.target == .access(.exit))
        // With a seat at the rear, walk to the front before arriving.
        let seated = try #require(CoachAdvice.exit(endingAt: "13", before: before, platforms: platforms, station: "Frankfurt (Main) Hbf",
                                                   seat: (coach: "26", train: "ICE 100"), toExit: true))
        #expect(seated.text() == "Vor der Ankunft in Wagen 21 wechseln, um in Frankfurt (Main) Hbf direkt am Ausgang auszusteigen.")
        // Changing trains, the underpass counts too.
        let changing = try #require(CoachAdvice.exit(endingAt: "13", before: before, platforms: platforms, station: "Frankfurt (Main) Hbf"))
        #expect(changing.groups.count == 2)
        // First class at the rear: from a seat there, walk through second class to the front.
        let rearFirst = train(numbers(21...27), from: 50, towardsEnd: false, platform: "5", firstClass: ["26", "27"])
        let fromFirst = try #require(CoachAdvice.exit(endingAt: "13", before: rearFirst, platforms: platforms, station: "Frankfurt (Main) Hbf",
                                                      travelClass: 1, seat: (coach: "27", train: "ICE 100"), toExit: true))
        #expect(fromFirst.coaches == ["21"])
        #expect(fromFirst.text() == "Vor der Ankunft in Wagen 21 (2. Klasse) wechseln, um in Frankfurt (Main) Hbf direkt am Ausgang auszusteigen.")
        // Without one: first class's coach nearest the front, before departure and on the way …
        let boarding = try #require(CoachAdvice.exit(endingAt: "13", before: rearFirst, platforms: platforms, station: "Frankfurt (Main) Hbf",
                                                     travelClass: 1, toExit: true))
        #expect(boarding.coaches == ["26"])
        #expect(boarding.text() == "In Wagen 26 einsteigen, um in Frankfurt (Main) Hbf möglichst nah am Ausgang auszusteigen.")
        #expect(boarding.legend == "Die markierten Wagen halten in Frankfurt (Main) Hbf möglichst nah am Ausgang.")
        let aboard = try #require(CoachAdvice.exit(endingAt: "13", before: rearFirst, platforms: platforms, station: "Frankfurt (Main) Hbf",
                                                   travelClass: 1, aboard: true, toExit: true))
        #expect(aboard.coaches == ["26"])
        // … and shortly before arriving the front, in second class.
        let approaching = try #require(CoachAdvice.exit(endingAt: "13", before: rearFirst, platforms: platforms, station: "Frankfurt (Main) Hbf",
                                                        travelClass: 1, aboard: true, approaching: true, toExit: true))
        #expect(approaching.text(boarded: true) == "In Wagen 21 (2. Klasse) wechseln, um in Frankfurt (Main) Hbf direkt am Ausgang auszusteigen.")
        // In second class the front is right: no class to name.
        let second = try #require(CoachAdvice.exit(endingAt: "13", before: rearFirst, platforms: platforms, station: "Frankfurt (Main) Hbf",
                                                   travelClass: 2, aboard: true, approaching: true, toExit: true))
        #expect(second.text(boarded: true) == "In Wagen 21 wechseln, um in Frankfurt (Main) Hbf direkt am Ausgang auszusteigen.")
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
        #expect(advice.coaches == ["24", "25"])
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
        #expect(advice[journey.legs[0].id]?.coaches == ["31", "32"])
        #expect(advice[journey.legs[0].id]?.station == "Hannover Hbf")
        // ICE 200's run is unknown, so there's nothing for getting off in Hamburg.
        #expect(advice[journey.legs[1].id] == nil)

        // With a seat reserved on ICE 100 (Wagen 25, 60 m short of ICE 200), walk forward before arriving.
        let reserved = await CoachAdvice.plan(for: journey, reservations: [journey.legs[0].id: (coach: "25", train: "ICE 100")], now: now,
                                              sequence: sequence, stops: { _ in run })
        #expect(reserved[journey.legs[0].id]?.coaches == ["31", "32"])
        #expect(reserved[journey.legs[0].id]?.walkBeforeArrival == true)
        // One opposite it already: say so.
        let opposite = await CoachAdvice.plan(for: journey, reservations: [journey.legs[0].id: (coach: "31", train: "ICE 100")], now: now,
                                              sequence: sequence, stops: { _ in run })
        #expect(opposite[journey.legs[0].id]?.alreadyThere == true)
        // On the way without one, still the coaches opposite ICE 200.
        let underway = await CoachAdvice.plan(for: journey, now: now.addingTimeInterval(90 * 60), sequence: sequence, stops: { _ in run })
        #expect(underway[journey.legs[0].id]?.coaches == ["31", "32"])
        #expect(underway[journey.legs[0].id]?.walkBeforeArrival == false)
        // One on ICE 200 is where to get to.
        let connecting = await CoachAdvice.plan(for: journey, reservations: [journey.legs[1].id: (coach: "35", train: "ICE 200")], now: now,
                                                sequence: sequence, stops: { _ in run })
        #expect(connecting[journey.legs[0].id]?.target == .connection(coach: "35"))

        // 20 minutes at the same platform is time enough to find ICE 200.
        var relaxed = journey
        relaxed.legs[1] = leg("ICE 200", from: hannoverHbf, at: 140, to: hamburg, at: 220)
        #expect(await CoachAdvice.plan(for: relaxed, now: now, sequence: sequence, stops: { _ in run }).isEmpty)
        // Nothing once ICE 100 has arrived.
        #expect(await CoachAdvice.plan(for: journey, now: now.addingTimeInterval(125 * 60), sequence: sequence, stops: { _ in run }).isEmpty)
    }

    @Test func plansStairsForAConnectionWithoutWagenreihung() async throws {
        // ICE 100 arrives on track 12; 9 minutes later S 5 leaves from track 1, another platform. bahn.de
        // has no Wagenreihung for the S-Bahn, so its platform alone says: make for the stairs.
        var platforms = hannover
        platforms.tracks["12"] = .init(start: .init(latitude: 52, longitude: 9), end: .init(latitude: 52.0036, longitude: 9), length: 400,
                                       accesses: [.init(kind: .stairs, position: 290)],
                                       sectorSigns: Self.sectors.map { .init(name: $0.name, position: ($0.start + $0.end) / 2) })
        var sBahn = leg("ICE 200", from: hannoverHbf, at: 129, to: hamburg, at: 210)
        sBahn.line = Line(name: "S 5", number: "5", product: .suburban, operatorName: nil)
        sBahn.departurePlatform = PlatformInfo(planned: "1", actual: nil)
        var journey = Journey(legs: [leg("ICE 100", from: goettingen, at: 60, to: hannoverHbf, at: 120, platform: "12"), sBahn], source: .bahnDe)
        let arriving = train(numbers(21...32), from: 10, towardsEnd: false)
        let run = run100
        let sequence: @Sendable (BahnDeClient.FormationRequest) async -> CoachSequence? = { request in
            request.number == "100" ? arriving : nil
        }
        let advice = await CoachAdvice.plan(for: journey, now: now, sequence: sequence, stops: { _ in run }, platformsAt: { _ in platforms })
        #expect(advice[journey.legs[0].id]?.coaches == ["31", "32"])
        #expect(advice[journey.legs[0].id]?.target == .access(.stairs))
        // 25 minutes later still the stairs: only the connecting train's spot is left out.
        var later = journey
        later.legs[1].departure = TimeInfo(planned: now.addingTimeInterval(145 * 60), actual: nil)
        let relaxed = await CoachAdvice.plan(for: later, now: now, sequence: sequence, stops: { _ in run }, platformsAt: { _ in platforms })
        #expect(relaxed[later.legs[0].id]?.coaches == ["31", "32"])
        // Getting off there at the end: the stairs too, but nothing with a seat reserved, which decides there.
        let ending = Journey(legs: [journey.legs[0]], source: .bahnDe)
        let exit = await CoachAdvice.plan(for: ending, now: now, sequence: sequence, stops: { _ in run }, platformsAt: { _ in platforms })
        #expect(exit[ending.legs[0].id]?.target == .access(.stairs))
        let seated = await CoachAdvice.plan(for: ending, reservations: [ending.legs[0].id: (coach: "22", train: "ICE 100")], now: now,
                                            sequence: sequence, stops: { _ in run }, platformsAt: { _ in platforms })
        #expect(seated.isEmpty)
        // Across the platform (track 11) it's unknown where the S-Bahn stops, so nothing is said.
        journey.legs[1].departurePlatform = PlatformInfo(planned: "11", actual: nil)
        #expect(await CoachAdvice.plan(for: journey, now: now, sequence: sequence, stops: { _ in run }, platformsAt: { _ in platforms }).isEmpty)
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

    /// Getting off where the journey ends at a terminus: the front, also from a seat.
    @Test func walksToTheFrontForATerminus() async throws {
        let frankfurt = station("8000105", "Frankfurt (Main) Hbf", 50.107, 8.663)
        let track = StationPlatforms.Track(start: .init(latitude: 50.105, longitude: 8.659), end: .init(latitude: 50.107, longitude: 8.663),
                                           length: 300, accesses: [.init(kind: .stairs, position: 150), .init(kind: .exit, position: 300)])
        let ride = leg("ICE 100", from: goettingen, at: 60, to: frankfurt, at: 200, platform: "13")
        let journey = Journey(legs: [ride], source: .bahnDe)
        let run = [stop(goettingen, arrival: nil, departure: 60), stop(frankfurt, arrival: 200, departure: nil)]
        let before = train(numbers(21...27), from: 50, towardsEnd: false, platform: "5")
        let sequence: @Sendable (BahnDeClient.FormationRequest) async -> CoachSequence? = { _ in before }
        let platformsAt: (String) -> StationPlatforms? = { $0 == "8000105" ? StationPlatforms(tracks: ["13": track]) : nil }
        let free = await CoachAdvice.plan(for: journey, now: now, sequence: sequence, stops: { _ in run }, platformsAt: platformsAt)
        #expect(free[ride.id]?.coaches == ["21"])
        let seated = await CoachAdvice.plan(for: journey, reservations: [ride.id: (coach: "26", train: "ICE 100")], now: now,
                                            sequence: sequence, stops: { _ in run }, platformsAt: platformsAt)
        #expect(seated[ride.id]?.coaches == ["21"])
        #expect(seated[ride.id]?.walkBeforeArrival == true)
        // In first class at the rear: its coach nearest the front, until 15 minutes before arriving.
        let rearFirst = train(numbers(21...27), from: 50, towardsEnd: false, platform: "5", firstClass: ["26", "27"])
        let first: @Sendable (BahnDeClient.FormationRequest) async -> CoachSequence? = { _ in rearFirst }
        for (minutes, coaches) in [(0.0, ["26"]), (150, ["26"]), (190, ["21"])] {
            let advice = await CoachAdvice.plan(for: journey, travelClass: 1, now: now.addingTimeInterval(minutes * 60), sequence: first,
                                                stops: { _ in run }, platformsAt: platformsAt)
            #expect(advice[ride.id]?.coaches == coaches)
            #expect(advice[ride.id]?.otherClass == (minutes == 190 ? 2 : nil))
        }
    }

    // MARK: A saved seat (#410)

    @Test func savesASeatForTheRide() {
        var ride = leg("ICE 100", from: goettingen, at: 60, to: hannoverHbf, at: 120)
        let seat = SavedSeat(leg: ride, coach: "23", seat: " 45 ")
        #expect(seat.description == "Wagen 23 · Platz 45")
        #expect(seat.trainName == "ICE 100")
        #expect(SavedSeat(leg: ride, coach: "23", seat: "").description == "Wagen 23")
        // The feed's trip ID can change on the way; the ride stays the same.
        ride.tripId = "another ID"
        #expect(seat.belongs(to: ride))
        #expect(!seat.belongs(to: leg("ICE 200", from: hannoverHbf, at: 128, to: hamburg, at: 210)))
        // A regional line's run, as reservations name it.
        ride.line = Line(name: "RE 5", number: "5", product: .regional, operatorName: nil, tripNumber: "3307")
        #expect(SavedSeat(leg: ride, coach: "2").trainName == "RE 3307")
    }

    @Test func offersSavingWhileRiding() {
        let ride = leg("ICE 100", from: goettingen, at: 60, to: hannoverHbf, at: 120)
        #expect(!SavedSeat.offered(on: ride, now: now.addingTimeInterval(40 * 60)))
        #expect(SavedSeat.offered(on: ride, now: now.addingTimeInterval(50 * 60)))
        #expect(SavedSeat.offered(on: ride, now: now.addingTimeInterval(100 * 60)))
        #expect(!SavedSeat.offered(on: ride, now: now.addingTimeInterval(120 * 60)))
    }

    @Test func keepsOneSeatPerRideUntilAfterIt() {
        let first = leg("ICE 100", from: goettingen, at: 60, to: hannoverHbf, at: 120)
        let second = leg("ICE 200", from: hannoverHbf, at: 128, to: hamburg, at: 210)
        let old = SavedSeat(leg: first, coach: "23")
        let moved = SavedSeat(leg: first, coach: "31", seat: "12")
        let next = SavedSeat(leg: second, coach: "7")
        let during = now.addingTimeInterval(100 * 60)
        #expect(SavedSeat.saving(moved, for: first, in: [old, next], now: during) == [next, moved])
        #expect(SavedSeat.saving(nil, for: first, in: [old, next], now: during) == [next])
        // Hours after ICE 100 arrived its seat goes; ICE 200's stays a while longer.
        let later = now.addingTimeInterval((120 + 6 * 60 + 1) * 60)
        #expect(SavedSeat.saving(nil, for: second, in: [old, next], now: later).isEmpty)
        #expect(SavedSeat.saving(nil, for: first, in: [old, next], now: later) == [next])
    }

    @Test func listsTheCoachesToSaveASeatIn() {
        var sequence = train(["32", "21", "22", "BR"], from: 10, towardsEnd: true)
        sequence.coaches[3].kind = .diningCar
        sequence.coaches[2].closed = true
        #expect(sequence.seatCoachNumbers == ["21", "32"])
    }

    // MARK: Pieces

    @Test func listsCoaches() {
        #expect(CoachAdvice(coaches: ["21"], target: .access(.lift), station: "Celle").coachList == "Wagen 21")
        #expect(CoachAdvice(coaches: ["21", "22"], target: .access(.lift), station: "Celle").coachList == "Wagen 21 oder 22")
        #expect(CoachAdvice(coaches: ["21", "22", "23"], target: .access(.lift), station: "Celle").coachList == "Wagen 21–23")
        #expect(CoachAdvice(coaches: ["25", "26", "28"], target: .access(.lift), station: "Celle").coachList == "Wagen 25, 26 oder 28")
        // At two places.
        #expect(CoachAdvice(groups: [["22", "23"], ["31", "32"]], target: .access(.stairs), station: "Köln Hbf").coachList == "Wagen 22–23 oder 31–32")
        #expect(CoachAdvice(groups: [["24"], ["26"]], target: .access(.stairs), station: "Köln Hbf").coachList == "Wagen 24 oder 26")
        #expect(CoachAdvice(coaches: ["5"], target: .access(.lift), station: "Celle").text() == "In Wagen 5 einsteigen, um in Celle direkt am Aufzug auszusteigen.")
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
        // A track's sections: "3a/b" is track 3 (or its "3a") where there's nothing for "3a/b" itself.
        #expect(StationPlatforms.trackKeys("Gleis 3a/b") == ["3a/b", "3a", "3"])
        let sections = StationPlatforms(sharedPlatforms: [["2", "3"]], tracks: ["3": track])
        #expect(sections.track("3a/b") == track)
        #expect(sections.sharePlatform("3a/b", "2"))
        #expect(sections.sharePlatform("3a", "3b"))
        #expect(!sections.sharePlatform("3a/b", "1a"))
        // The app's own data: Hannover Hbf's tracks 11 and 12 share a platform.
        #expect(StationPlatforms.at(eva: "8000152")?.sharePlatform("11", "12") == true)
        #expect(StationPlatforms.at(eva: "8000152")?.sharePlatform("12", "13") == false)
    }
}
