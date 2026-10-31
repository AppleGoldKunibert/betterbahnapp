import Foundation
import Testing
@testable import BetterBahnKit

/// Regular trips (#397): which days ask "Fährst du heute?", the day's journey and the quiet rules.
@Suite struct RegularTripTests {
    private static let eberswalde = station("8010093", "Eberswalde Hbf")
    private static let gesundbrunnen = station("8011102", "Berlin Gesundbrunnen")
    private static let re3 = Line(name: "RE 3", number: "3", product: .regionalExpress, operatorName: "DB Regio AG", tripNumber: "3354")

    /// German time on a day in October 2026 (the 19th is a Monday, summer time ends on the 25th).
    private static func berlin(_ day: Int, _ hour: Int, _ minute: Int, month: Int = 10) -> Date {
        RegularTrip.calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
    }

    private static func re3Leg(day: Int, delay: Double = 0, tripId: String? = "trip-\(UUID())") -> Leg {
        let departure = berlin(day, 7, 42), arrival = berlin(day, 8, 14)
        return Leg(origin: eberswalde, destination: gesundbrunnen,
                   departure: TimeInfo(planned: departure, actual: departure.addingTimeInterval(delay * 60)),
                   arrival: TimeInfo(planned: arrival, actual: arrival.addingTimeInterval(delay * 60)),
                   departurePlatform: PlatformInfo(planned: "2", actual: "3"), arrivalPlatform: PlatformInfo(planned: "7", actual: nil),
                   tripId: tripId, line: re3, direction: "Berlin Südkreuz", isWalking: false, cancelled: false,
                   stopovers: [], remarks: [], source: .transitous)
    }

    /// Set up from Friday 16 October's ride.
    private static let trip = RegularTrip(journey: Journey(legs: [re3Leg(day: 16, delay: 4)], source: .transitous))

    @Test func daysAndKeys() {
        #expect(RegularTrip.weekday(of: Self.berlin(19, 7, 0)) == 1)
        #expect(RegularTrip.weekday(of: Self.berlin(25, 23, 30)) == 7)
        // 23:30 UTC on Sunday is already Monday in Germany.
        let lateSunday = ISO8601DateFormatter().date(from: "2026-10-18T23:30:00Z")!
        #expect(RegularTrip.weekday(of: lateSunday) == 1)
        #expect(RegularTrip.dayKey(of: lateSunday) == "2026-10-19")
        #expect(RegularTrip.dayKey(of: Self.berlin(19, 0, 5)) == "2026-10-19")
        #expect(RegularTrip.day(forKey: "2026-10-19") == Self.berlin(19, 0, 0))
        #expect(RegularTrip.day(forKey: "19.10.2026") == nil)
    }

    @Test func setUpFromAWorkingDayRunsMondayToFriday() {
        #expect(Self.trip.weekdays == [1, 2, 3, 4, 5])
        #expect(Self.trip.weekdaysDescription == "Mo–Fr")
        let saturday = RegularTrip(journey: Journey(legs: [Self.re3Leg(day: 24)], source: .transitous))
        #expect(saturday.weekdays == [6])
        var other = Self.trip
        other.weekdays = [1, 3, 5]
        #expect(other.weekdaysDescription == "Mo, Mi, Fr")
        other.weekdays = [6, 7]
        #expect(other.weekdaysDescription == "Sa, So")
        other.weekdays = Set(1...7)
        #expect(other.weekdaysDescription == "täglich")
    }

    /// The template keeps nothing of the day it was saved on.
    @Test func templateIsPlain() {
        let leg = Self.trip.template.legs[0]
        #expect(leg.departure.actual == nil)
        #expect(leg.departurePlatform == PlatformInfo(planned: "2", actual: nil))
        #expect(Self.trip.summary == "RE 3 7:42 Eberswalde Hbf → Berlin Gesundbrunnen")
    }

    @Test func questionsComeOnTravelDaysBeforeDeparture() {
        let questions = Self.trip.questions(from: Self.berlin(19, 7, 0), days: 7)
        #expect(questions.map(\.dayKey) == ["2026-10-19", "2026-10-20", "2026-10-21", "2026-10-22", "2026-10-23"])
        #expect(questions[0].date == Self.berlin(19, 7, 12))
        #expect(questions[0].departure == Self.berlin(19, 7, 42))
        // Too late for today's question.
        #expect(Self.trip.questions(from: Self.berlin(19, 7, 20), days: 2).map(\.dayKey) == ["2026-10-20"])
        // Already saved today, e.g. on another device.
        #expect(Self.trip.questions(from: Self.berlin(19, 7, 0), days: 2, answered: ["2026-10-19"]).map(\.dayKey) == ["2026-10-20"])
    }

    @Test func pausedDaysAreSkipped() {
        var trip = Self.trip
        trip.pausedUntil = Self.berlin(21, 0, 0)
        #expect(trip.isPaused(on: Self.berlin(21, 23, 0)))
        #expect(!trip.isPaused(on: Self.berlin(22, 0, 0)))
        #expect(trip.questions(from: Self.berlin(19, 7, 0), days: 7).map(\.dayKey) == ["2026-10-22", "2026-10-23"])
    }

    /// The train leaves at 7:42 German time before and after summer time ends.
    @Test func keepsTheTimeOfDayAcrossDaylightSaving() {
        #expect(Self.trip.departure(on: Self.berlin(23, 12, 0)) == Self.berlin(23, 7, 42))
        #expect(Self.trip.departure(on: Self.berlin(26, 12, 0)) == Self.berlin(26, 7, 42))
        #expect(Self.berlin(26, 7, 42).timeIntervalSince(Self.berlin(23, 7, 42)) == 3 * 86400 + 3600)
    }

    @Test func questionIdentifiersAndJourneyIDs() throws {
        let question = try #require(Self.trip.questions(from: Self.berlin(19, 7, 0), days: 1).first)
        let parsed = try #require(RegularTrip.question(fromNotificationID: question.notificationID))
        #expect(parsed.tripID == Self.trip.id)
        #expect(parsed.dayKey == "2026-10-19")
        #expect(RegularTrip.question(fromNotificationID: "platform|x") == nil)
        let monday = Self.trip.journeyID(forDay: "2026-10-19")
        #expect(monday == Self.trip.journeyID(forDay: "2026-10-19"))
        #expect(monday != Self.trip.journeyID(forDay: "2026-10-20"))
        #expect(monday != Self.trip.id)
    }

    @Test func plannedJourneyMovesTheTemplate() throws {
        let journey = Self.trip.plannedJourney(on: Self.berlin(26, 0, 0))
        let leg = try #require(journey.legs.first)
        #expect(leg.departure == TimeInfo(planned: Self.berlin(26, 7, 42), actual: nil))
        #expect(leg.arrival.planned == Self.berlin(26, 8, 14))
        #expect(leg.tripId == nil)
        #expect(Self.trip.matches(Journey(legs: [Self.re3Leg(day: 26, delay: 8)], source: .transitous)))
    }

    // MARK: Day's journey

    private static func entry(_ line: Line, at time: Date, tripId: String) -> BoardEntry {
        BoardEntry(kind: .departures, tripId: tripId, station: eberswalde, line: line, otherEnd: "Berlin Südkreuz",
                   time: TimeInfo(planned: time, actual: nil), platform: PlatformInfo(planned: "2", actual: nil), cancelled: false,
                   terminatesOrOriginatesHere: false, remarks: [], source: .transitous)
    }

    @Test func picksTheSameTrainAtTheSameTime() {
        let planned = Self.trip.plannedLeg(Self.trip.template.legs[0], on: Self.berlin(19, 0, 0))
        var friday = Self.re3
        friday.tripNumber = "3356"
        let other = Line(name: "RB 24", number: "24", product: .regional, operatorName: nil, tripNumber: "28800")
        let entries = [
            Self.entry(Self.re3, at: Self.berlin(19, 8, 42), tripId: "next-hour"),
            Self.entry(other, at: Self.berlin(19, 7, 42), tripId: "rb"),
            Self.entry(friday, at: Self.berlin(19, 7, 41), tripId: "other-run"),
            Self.entry(Self.re3, at: Self.berlin(19, 7, 43), tripId: "same-run"),
        ]
        #expect(RegularTripPlanner.candidates(in: entries, for: planned).map(\.tripId) == ["same-run", "other-run"])
    }

    /// A ring line passes a station twice: the visit at the planned time is boarded.
    @Test func boardsTheVisitAtThePlannedTime() throws {
        let planned = Self.trip.plannedLeg(Self.trip.template.legs[0], on: Self.berlin(19, 0, 0))
        func stop(_ station: Station, _ hour: Int, _ minute: Int) -> Stopover {
            let time = TimeInfo(planned: Self.berlin(19, hour, minute), actual: nil)
            return Stopover(station: station, arrival: time, departure: time, arrivalPlatform: nil, departurePlatform: nil, cancelled: false)
        }
        let trip = Trip(id: "ring", line: Self.re3, direction: nil, stopovers: [
            stop(Self.eberswalde, 6, 42), stop(Self.gesundbrunnen, 7, 14), stop(Self.eberswalde, 7, 42), stop(Self.gesundbrunnen, 8, 14),
        ], cancelled: false, remarks: [], source: .transitous)
        let leg = try #require(RegularTripPlanner.leg(of: trip, like: planned))
        #expect(leg.departure.planned == Self.berlin(19, 7, 42))
        #expect(leg.arrival.planned == Self.berlin(19, 8, 14))
        #expect(leg.tripId == "ring")
    }

    // MARK: Quiet rules

    @Test func reportsDelaysFromTheThresholdAndWhenTheyGrow() throws {
        let now = Self.berlin(19, 7, 15)
        func journey(_ delay: Double) -> Journey { Journey(legs: [Self.re3Leg(day: 19, delay: delay)], source: .transitous) }
        #expect(CommuteAlerts.delays(in: journey(4), threshold: 5, notified: [], now: now).isEmpty)
        let first = try #require(CommuteAlerts.delays(in: journey(7), threshold: 5, notified: [], now: now).first)
        #expect(first.title == "RE 3: +7 Min.")
        #expect(first.message == "Ab Eberswalde Hbf um 7:49 statt 7:42.")
        let notified = [first.notificationID]
        #expect(CommuteAlerts.delays(in: journey(9), threshold: 5, notified: notified, now: now).isEmpty)
        #expect(CommuteAlerts.delays(in: journey(12), threshold: 5, notified: notified, now: now).map(\.minutes) == [12])
        // Gone already, or not running at all.
        #expect(CommuteAlerts.delays(in: journey(7), threshold: 5, notified: [], now: Self.berlin(19, 7, 50)).isEmpty)
        var cancelled = journey(20)
        cancelled.legs[0].cancelled = true
        #expect(CommuteAlerts.delays(in: cancelled, threshold: 5, notified: [], now: now).isEmpty)
    }

    /// A refresh can bring a new trip ID; the train is still the one reported.
    @Test func delayReportsSurviveANewTripID() throws {
        let now = Self.berlin(19, 7, 15)
        let first = try #require(CommuteAlerts.delays(in: Journey(legs: [Self.re3Leg(day: 19, delay: 7, tripId: "a")], source: .transitous),
                                                      threshold: 5, notified: [], now: now).first)
        #expect(CommuteAlerts.delays(in: Journey(legs: [Self.re3Leg(day: 19, delay: 8, tripId: "b")], source: .transitous),
                                     threshold: 5, notified: [first.notificationID], now: now).isEmpty)
    }

    // MARK: Push Worker

    @Test func watchNamesTrainsByDBNumberAndStationsByEVA() async throws {
        let journey = Journey(legs: [Self.re3Leg(day: 19)], source: .transitous)
        let id = UUID()
        let watch = try #require(await CommuteWatch.make(journeyID: id, journey: journey, threshold: 5) { $0.evaNumber })
        #expect(watch.id == id.uuidString)
        #expect(watch.legs == [CommuteWatch.Leg(
            line: "RE 3", category: "RE", number: "3354",
            from: CommuteWatch.Stop(eva: "8010093", name: "Eberswalde Hbf", time: Int(Self.berlin(19, 7, 42).timeIntervalSince1970)),
            to: CommuteWatch.Stop(eva: "8011102", name: "Berlin Gesundbrunnen", time: Int(Self.berlin(19, 8, 14).timeIntervalSince1970)))])
        // A station without EVA number: the app looks after that journey itself.
        #expect(await CommuteWatch.make(journeyID: id, journey: journey, threshold: 5) { _ in nil } == nil)
    }

    @Test func pushUpdateSendsTheWatchesAndReadsWhatIsWatched() async throws {
        CommuteWorkerProtocol.reset()
        let push = CommutePush(http: HTTPClient(session: CommuteWorkerProtocol.session()), baseURL: URL(string: "https://push.test")!)
        let registration = CommutePushRegistration(id: "abc", secret: "s3cret")
        let watch = CommuteWatch(id: "J1", threshold: 5, legs: [])
        let watched = try await push.update(registration, deviceToken: "ff00", sandbox: true, watches: [watch])
        #expect(watched == ["J1"])
        let request = try #require(CommuteWorkerProtocol.requests.first)
        #expect(request.method == "PUT")
        #expect(request.path == "/commutes/abc")
        #expect(request.body["secret"] as? String == "s3cret")
        #expect(request.body["deviceToken"] as? String == "ff00")
        #expect(request.body["sandbox"] as? Bool == true)
        #expect((request.body["journeys"] as? [[String: Any]])?.first?["id"] as? String == "J1")
        #expect(request.body["language"] as? String == "de")
        let made = CommutePushRegistration.make()
        #expect(made.id.count == 32 && made.secret.count == 64 && made != CommutePushRegistration.make())
    }
}

/// A fake push Worker answering `PUT /commutes/<id>` with every journey it was sent as watched.
private final class CommuteWorkerProtocol: URLProtocol, @unchecked Sendable {
    struct Recorded: @unchecked Sendable {
        var method: String
        var path: String
        var body: [String: Any]
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var recorded: [Recorded] = []
    static var requests: [Recorded] { lock.withLock { recorded } }
    static func reset() { lock.withLock { recorded = [] } }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CommuteWorkerProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                data.append(buffer, count: count)
            }
            stream.close()
        }
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        Self.lock.withLock {
            Self.recorded.append(Recorded(method: request.httpMethod ?? "GET", path: request.url?.path ?? "", body: body))
        }
        let ids = (body["journeys"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
        let answer = try! JSONSerialization.data(withJSONObject: ["watched": ids])
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: answer)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
