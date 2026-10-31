import Foundation
import Testing
@testable import BetterBahnKit

@Suite struct LiveTrainFieldTests {
    /// About 11.1 km straight north from Frankfurt, then 7.2 km east: a curve the trains must follow.
    static let corner = Coordinate(latitude: 50.2, longitude: 8.6)
    static let track = [Coordinate(latitude: 50.1, longitude: 8.6), corner, Coordinate(latitude: 50.2, longitude: 8.7)]
    static let start = Date(timeIntervalSince1970: 1_800_000_000)

    static func segment(trip: String = "t1", name: String = "ICE 79", departure: Date = start, minutes: Double = 10,
                        longDistance: Bool = true) -> LiveTrainSegment {
        LiveTrainSegment(tripId: trip, name: name, from: "A", to: "B", departure: departure,
                         arrival: departure.addingTimeInterval(minutes * 60), track: TrackPath(track), isLongDistance: longDistance)
    }

    static func running(_ name: String, category: String, number: Int?, line: String? = nil, at coordinate: Coordinate,
                        time: Date, speed: Double?) -> BahnJetztClient.RunningTrain {
        .init(id: "j-\(name)-\(coordinate.latitude)", name: name, category: category, number: number, lineName: line ?? name,
              destination: nil, position: TrainPosition(coordinate: coordinate, time: time, speedKmh: speed, source: "bahn.jetzt"))
    }

    @Test func trackPathPlacesPointsByMetersRun() throws {
        let path = TrackPath(Self.track)
        #expect(abs(path.length - 18_270) < 150)
        let corner = try #require(path.coordinate(at: Self.track[0].distance(to: Self.corner)))
        #expect(corner.distance(to: Self.corner) < 1)
        // Past the corner the point lies on the eastward leg, not on a straight line from start to end.
        let beyond = try #require(path.coordinate(at: path.length - 1_000))
        #expect(abs(beyond.latitude - 50.2) < 0.0001)
        #expect(path.coordinate(at: -5) == Self.track[0])
        #expect(path.coordinate(at: 1e9) == Self.track[2])
        let located = try #require(path.locate(Coordinate(latitude: 50.15, longitude: 8.601)))
        #expect(located.distance < 100)
        #expect(abs(located.meters - path.length * 5_560 / 18_270) < 200)
    }

    @Test func timetableTrainsRunEvenlyBetweenStops() throws {
        let field = LiveTrainField(segments: [Self.segment()], running: [])
        let halfway = try #require(field.markers(at: Self.start.addingTimeInterval(300)).first)
        let expected = try #require(TrackPath(Self.track).coordinate(at: TrackPath(Self.track).length / 2))
        #expect(halfway.coordinate.distance(to: expected) < 1)
        #expect(halfway.followsTrack)
        #expect(halfway.nextStop == "B")
        // Long before departure and long after arrival nothing is shown.
        #expect(field.markers(at: Self.start.addingTimeInterval(-600)).isEmpty)
        #expect(field.markers(at: Self.start.addingTimeInterval(1_200)).isEmpty)
    }

    @Test func waitsAtTheStopBetweenTwoStretches() throws {
        let first = Self.segment(minutes: 10)
        var second = Self.segment(departure: Self.start.addingTimeInterval(12 * 60))
        second.from = "B"
        second.to = "C"
        let field = LiveTrainField(segments: [second, first], running: [])
        let waiting = try #require(field.markers(at: Self.start.addingTimeInterval(11 * 60)).first)
        #expect(waiting.coordinate == Self.track[2])
        #expect(waiting.nextStop == "B")
    }

    @Test func bahnJetztFixRunsOnAtItsSpeedAroundTheCurve() throws {
        let fixTime = Self.start.addingTimeInterval(60)
        // Just before the corner, at 180 km/h (50 m/s): 30 s later it's 1.5 km on, round the corner.
        let fix = Coordinate(latitude: 50.195, longitude: 8.6)
        let field = LiveTrainField(segments: [Self.segment()], running: [
            Self.running("ICE 79", category: "ICE", number: 79, at: fix, time: fixTime, speed: 180),
        ])
        let marker = try #require(field.markers(at: fixTime.addingTimeInterval(30)).first)
        #expect(marker.speedKmh == 180)
        #expect(abs(marker.coordinate.latitude - 50.2) < 0.0001)
        #expect(abs(marker.coordinate.distance(to: Self.corner) - (1_500 - fix.distance(to: Self.corner))) < 30)
        #expect(field.markers(at: fixTime).count == 1)
    }

    @Test func extrapolationStopsAtTheNextStopAndAfterAWhile() throws {
        let fixTime = Self.start.addingTimeInterval(60)
        let fix = Coordinate(latitude: 50.2, longitude: 8.69)
        let field = LiveTrainField(segments: [Self.segment()], running: [
            Self.running("ICE 79", category: "ICE", number: 79, at: fix, time: fixTime, speed: 200),
        ])
        let atStop = try #require(field.markers(at: fixTime.addingTimeInterval(60)).first)
        #expect(atStop.coordinate == Self.track[2])
        // An old fix no longer counts: the timetable takes over.
        let stale = try #require(field.markers(at: fixTime.addingTimeInterval(LiveTrainField.maxExtrapolation + 1)).first)
        #expect(stale.speedKmh == nil)
    }

    @Test func regionalTrainsOfTheSameLineGoToTheRightTrip() throws {
        let early = Self.segment(trip: "early", name: "RE8", departure: Self.start, longDistance: false)
        let late = Self.segment(trip: "late", name: "RE8", departure: Self.start.addingTimeInterval(8 * 60), longDistance: false)
        let fixTime = Self.start.addingTimeInterval(9 * 60)
        let path = TrackPath(Self.track)
        // The early train is nearly at B, the late one just left A.
        let nearEnd = try #require(path.coordinate(at: path.length - 1_000))
        let nearStart = try #require(path.coordinate(at: 1_500))
        let field = LiveTrainField(segments: [early, late], running: [
            Self.running("RE8", category: "RE", number: 11444, at: nearStart, time: fixTime, speed: 0),
            Self.running("RE8", category: "RE", number: 11446, at: nearEnd, time: fixTime, speed: 0),
        ])
        let markers = Dictionary(uniqueKeysWithValues: field.markers(at: fixTime).map { ($0.id, $0) })
        #expect(markers.count == 2)
        #expect(try #require(markers["early"]).coordinate.distance(to: nearEnd) < 5)
        #expect(try #require(markers["late"]).coordinate.distance(to: nearStart) < 5)
    }

    @Test func regionalTrainsMatchByRunNumber() throws {
        var segment = Self.segment(trip: "rb", name: "RB58", longDistance: false)
        segment.runNumber = 4761
        let fixTime = Self.start.addingTimeInterval(60)
        let fix = Coordinate(latitude: 50.15, longitude: 8.6)
        // bahn.jetzt files it as RE with another line spelling; another RB58 runs elsewhere on the track.
        let field = LiveTrainField(segments: [segment], running: [
            Self.running("RB 58", category: "RB", number: 4763, line: "RB58", at: Self.track[0], time: fixTime, speed: 0),
            Self.running("RE 58", category: "RE", number: 4761, line: "RE 58", at: fix, time: fixTime, speed: 100),
        ])
        let marker = try #require(field.markers(at: fixTime).first { $0.id == "rb" })
        #expect(marker.coordinate.distance(to: fix) < 5)
        #expect(marker.speedKmh == 100)
    }

    @Test func unmatchedBahnJetztTrainsStayWhereTheyWereSeen() throws {
        let somewhere = Coordinate(latitude: 52.5, longitude: 13.4)
        let field = LiveTrainField(segments: [], running: [
            Self.running("S 5", category: "S", number: 7000, line: "S5", at: somewhere, time: Self.start, speed: 60),
        ])
        let marker = try #require(field.markers(at: Self.start.addingTimeInterval(30)).first)
        #expect(marker.coordinate == somewhere)
        #expect(!marker.followsTrack)
        #expect(field.markers(at: Self.start, in: MapArea(south: 50, west: 8, north: 51, east: 9)).isEmpty)
    }

    @Test func ownTrainIsLeftOutButNotOthersOfItsLine() throws {
        let field = LiveTrainField(segments: [Self.segment(trip: "own", name: "RE 8", longDistance: false),
                                              Self.segment(trip: "other", name: "RE 8", departure: Self.start.addingTimeInterval(-540),
                                                           longDistance: false)],
                                   running: [], ownTrains: [(name: "RE8", coordinate: Self.track[0])])
        let markers = field.markers(at: Self.start.addingTimeInterval(1))
        #expect(markers.map(\.id) == ["other"])
    }

    @Test func limitKeepsTheTrainsNearTheMiddle() {
        let running = (0 ..< 10).map { index in
            Self.running("S \(index)", category: "S", number: index, at: Coordinate(latitude: 50 + Double(index) * 0.05, longitude: 8.5),
                         time: Self.start, speed: nil)
        }
        let field = LiveTrainField(segments: [], running: running)
        let area = MapArea(south: 49.9, west: 8, north: 50.5, east: 9)
        let markers = field.markers(at: Self.start, in: area, limit: 3)
        #expect(Set(markers.map(\.name)) == ["S 3", "S 4", "S 5"])
    }

    @Test func transitousSegmentsKeepTrainsOnly() throws {
        let polyline = Polyline.encode(Self.track, precision: 5)
        let json = """
        [
          {"trips":[{"tripId":"a","routeShortName":"ICE 79"}],"mode":"HIGHSPEED_RAIL","from":{"name":"A"},"to":{"name":"B"},
           "departure":"2027-01-15T08:00:00Z","arrival":"2027-01-15T08:10:00Z","polyline":"\(polyline)"},
          {"trips":[{"tripId":"a","routeShortName":"ICE 79"}],"mode":"HIGHSPEED_RAIL","from":{"name":"A"},"to":{"name":"B"},
           "departure":"2027-01-15T08:00:00Z","arrival":"2027-01-15T08:10:00Z","polyline":"\(polyline)"},
          {"trips":[{"tripId":"b","routeShortName":"20N"}],"mode":"LONG_DISTANCE","from":{"name":"A"},"to":{"name":"B"},
           "departure":"2027-01-15T08:00:00Z","arrival":"2027-01-15T08:10:00Z","polyline":"\(polyline)"},
          {"trips":[{"tripId":"c","routeShortName":"M5"}],"mode":"TRAM","from":{"name":"A"},"to":{"name":"B"},
           "departure":"2027-01-15T08:00:00Z","arrival":"2027-01-15T08:10:00Z","polyline":"\(polyline)"},
          {"trips":[{"tripId":"d","routeShortName":"S3"}],"mode":"METRO","from":{"name":"A"},"to":{"name":"B"},
           "departure":"2027-01-15T08:00:00Z","arrival":"2027-01-15T08:10:00Z","polyline":"\(polyline)"},
          {"trips":[{"tripId":"e","routeShortName":"U8"}],"mode":"SUBWAY","from":{"name":"A"},"to":{"name":"B"},
           "departure":"2027-01-15T08:00:00Z","arrival":"2027-01-15T08:10:00Z","polyline":"\(polyline)"},
          {"trips":[{"tripId":"f","routeShortName":"RB58 (4761)"}],"mode":"REGIONAL_RAIL","from":{"name":"A"},"to":{"name":"B"},
           "departure":"2027-01-15T08:00:00Z","arrival":"2027-01-15T08:10:00Z","polyline":"\(polyline)"}
        ]
        """
        let decoded = try JSONDecoding.decoder.decode([TransitousProvider.MTripSegment].self, from: Data(json.utf8))
        let segments = TransitousProvider.liveTrainSegments(from: decoded)
        #expect(segments.map(\.name) == ["ICE 79", "S3", "RB58"])
        #expect(segments.map(\.runNumber) == [nil, nil, 4761])
        #expect(segments[0].isLongDistance)
        #expect(!segments[1].isLongDistance)
        #expect(try #require(segments[0].track.points.first).distance(to: Self.track[0]) < 2)
    }

    @Test func coverageLoadsOnlyWhenNeeded() {
        let visible = MapArea(center: Self.corner, latitudeSpan: 0.4, longitudeSpan: 0.6)
        let now = Self.start
        let area = LiveTrainCoverage.areaToLoad(visible: visible, loaded: nil, now: now)
        #expect(area?.contains(visible) == true)
        let loaded = LiveTrainCoverage(area: area!, until: now.addingTimeInterval(LiveTrainCoverage.window))
        // A small pan stays inside what's loaded; a far one or the window running out loads again.
        let panned = MapArea(center: Coordinate(latitude: 50.22, longitude: 8.62), latitudeSpan: 0.4, longitudeSpan: 0.6)
        #expect(LiveTrainCoverage.areaToLoad(visible: panned, loaded: loaded, now: now) == nil)
        let far = MapArea(center: Coordinate(latitude: 51.0, longitude: 8.6), latitudeSpan: 0.4, longitudeSpan: 0.6)
        #expect(LiveTrainCoverage.areaToLoad(visible: far, loaded: loaded, now: now) != nil)
        #expect(LiveTrainCoverage.areaToLoad(visible: visible, loaded: loaded, now: now.addingTimeInterval(19 * 60)) != nil)
        // All of Germany is too much.
        #expect(LiveTrainCoverage.areaToLoad(visible: MapArea(south: 47, west: 6, north: 55, east: 15), loaded: nil, now: now) == nil)
        #expect(LiveTrainCoverage.zoom(for: MapArea(center: Self.corner, latitudeSpan: 0.1, longitudeSpan: 0.2)) == 11)
        #expect(LiveTrainCoverage.zoom(for: MapArea(south: 49, west: 7, north: 51, east: 11)) == 9)
    }

    @Test func ownTrainMotionFollowsTrackAndWaitsAtStops() throws {
        let stop = try #require(TrackPath(Self.track).coordinate(at: 6_000))
        var motion = LiveTrainMotion(track: Self.track, stops: [Self.track[0], stop, Self.track[2]])
        #expect(motion.coordinate(at: Self.start) == nil)
        motion.update(with: TrainPosition(coordinate: Self.track[0], time: Self.start, speedKmh: 72, source: nil))
        // 20 m/s: after 80 s 1.6 km along the track, and no further than the extrapolation limit.
        let moved = try #require(motion.coordinate(at: Self.start.addingTimeInterval(80)))
        #expect(abs(moved.distance(to: Self.track[0]) - 1_600) < 10)
        let limited = try #require(motion.coordinate(at: Self.start.addingTimeInterval(600)))
        #expect(abs(limited.distance(to: Self.track[0]) - 20 * LiveTrainField.maxExtrapolation) < 10)
        // Never past the next stop.
        motion.update(with: TrainPosition(coordinate: Self.track[0], time: Self.start, speedKmh: 300, source: nil))
        let held = try #require(motion.coordinate(at: Self.start.addingTimeInterval(80)))
        #expect(held.distance(to: stop) < 1)
        motion.update(with: TrainPosition(coordinate: Coordinate(latitude: 51, longitude: 10), time: Self.start, speedKmh: 72, source: nil))
        #expect(motion.coordinate(at: Self.start.addingTimeInterval(10)) == Coordinate(latitude: 51, longitude: 10))
    }

    @Test func smootherClosesJumpsOverAFewSeconds() throws {
        var smoother = LiveTrainSmoother()
        let a = Coordinate(latitude: 50, longitude: 8), b = Coordinate(latitude: 50.001, longitude: 8)
        #expect(smoother.positions(["x": a], dataChanged: true, at: Self.start)["x"] == a)
        let blended = try #require(smoother.positions(["x": b], dataChanged: true, at: Self.start)["x"])
        #expect(blended == a)
        let halfway = try #require(smoother.positions(["x": b], dataChanged: false,
                                                      at: Self.start.addingTimeInterval(LiveTrainSmoother.blendDuration / 2))["x"])
        #expect(abs(halfway.latitude - 50.0005) < 0.00001)
        #expect(smoother.positions(["x": b], dataChanged: false, at: Self.start.addingTimeInterval(5))["x"] == b)
        // Far jumps aren't blended.
        let far = Coordinate(latitude: 51, longitude: 8)
        #expect(smoother.positions(["x": far], dataChanged: true, at: Self.start.addingTimeInterval(6))["x"] == far)
    }

    @Test func sBahnsAreOnlyShownWithARealFix() throws {
        var segment = Self.segment(trip: "s3", name: "S3", longDistance: false)
        segment.isSuburban = true
        let halfway = Self.start.addingTimeInterval(300)
        // No fix: not placed by the timetable.
        #expect(LiveTrainField(segments: [segment], running: []).markers(at: halfway).isEmpty)
        // With a fix it runs on, and an old fix only stops it moving.
        let fix = try #require(segment.track.coordinate(at: segment.scheduledMeters(at: halfway)))
        let field = LiveTrainField(segments: [segment], running: [
            Self.running("S3", category: "S", number: 35_123, at: fix, time: halfway, speed: 36),
        ])
        let moved = try #require(field.markers(at: halfway.addingTimeInterval(10)).first)
        #expect(abs(moved.coordinate.distance(to: fix) - 100) < 5)
        #expect(moved.tripId == "s3")
        let frozen = try #require(field.markers(at: halfway.addingTimeInterval(600)).first)
        #expect(abs(frozen.coordinate.distance(to: fix) - 10 * LiveTrainField.maxExtrapolation) < 10)
        // An S3 far from where the timetable has this one is another train.
        let elsewhere = try #require(segment.track.coordinate(at: segment.scheduledMeters(at: halfway) + 6_000))
        let other = LiveTrainField(segments: [segment], running: [
            Self.running("S3", category: "S", number: 35_125, at: elsewhere, time: halfway, speed: 36),
        ])
        #expect(other.markers(at: halfway).allSatisfy { $0.tripId == nil })
    }

    @Test func ownTrainSpeedIsWorkedOutWhenBahnJetztSendsNone() throws {
        var motion = LiveTrainMotion(track: Self.track, stops: [])
        let path = TrackPath(Self.track)
        let a = try #require(path.coordinate(at: 1_000)), b = try #require(path.coordinate(at: 2_000))
        motion.update(with: TrainPosition(coordinate: a, time: Self.start, speedKmh: nil, source: nil))
        #expect(motion.speedKmh == nil)
        // Repeated position: no speed yet.
        motion.update(with: TrainPosition(coordinate: a, time: Self.start.addingTimeInterval(15), speedKmh: nil, source: nil))
        #expect(motion.speedKmh == nil)
        // 1 km in 30 s: 120 km/h, and it runs on from where it was last seen moving.
        motion.update(with: TrainPosition(coordinate: b, time: Self.start.addingTimeInterval(30), speedKmh: nil, source: nil))
        #expect(abs((motion.speedKmh ?? 0) - 120) < 1)
        let on = try #require(motion.coordinate(at: Self.start.addingTimeInterval(45)))
        #expect(abs(path.locate(on)!.meters - 2_500) < 10)
        // bahn.jetzt's own speed wins; a position unchanged for over a minute means standing.
        motion.update(with: TrainPosition(coordinate: b, time: Self.start.addingTimeInterval(45), speedKmh: 90, source: nil))
        #expect(motion.speedKmh == 90)
        motion.update(with: TrainPosition(coordinate: b, time: Self.start.addingTimeInterval(120), speedKmh: nil, source: nil))
        #expect(motion.speedKmh == 0)
    }

    @Test func tappedTrainOpensAtItsNextStop() throws {
        func stop(_ name: String, _ minutes: Double, last: Bool = false) -> Stopover {
            let time = TimeInfo(planned: Self.start.addingTimeInterval(minutes * 60), actual: nil)
            return Stopover(station: Station(id: name, name: name, coordinate: nil, evaNumber: nil, source: .transitous),
                            arrival: minutes == 0 ? nil : time, departure: last ? nil : time,
                            arrivalPlatform: nil, departurePlatform: nil, cancelled: false)
        }
        let trip = Trip(id: "t", line: Line(name: "ICE 79", number: "79", product: .highSpeed, operatorName: nil), direction: "C",
                        stopovers: [stop("A", 0), stop("B", 10), stop("C", 20, last: true)], cancelled: false, remarks: [],
                        source: .transitous)
        let entry = try #require(BoardEntry.liveTrain(trip, at: Self.start.addingTimeInterval(5 * 60)))
        #expect(entry.station.name == "B")
        #expect(entry.kind == .departures)
        #expect(entry.otherEnd == "C")
        #expect(entry.tripId == "t")
        let ended = try #require(BoardEntry.liveTrain(trip, at: Self.start.addingTimeInterval(30 * 60)))
        #expect(ended.station.name == "C")
        #expect(ended.kind == .arrivals)
    }
}
