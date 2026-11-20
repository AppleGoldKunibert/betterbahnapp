import Foundation
import Testing
@testable import BetterBahnKit

/// A saved journey's leg and the run of its train get their live data through the same `LiveRun`, so the
/// journey card and the run opened from it never disagree (ICE 279: +3 / +18 on the card, "0" at every stop
/// of the run). What was seen before (the remembered run, the saved leg) only fills gaps.
@Suite(.serialized) struct LiveRunTests {
    /// 2026-10-20 04:43 UTC == 06:43 Europe/Berlin (CEST), ICE 279's departure from Berlin.
    let departure = Date(timeIntervalSince1970: 1_792_471_380)

    func at(_ minutes: TimeInterval) -> Date { departure.addingTimeInterval(minutes * 60) }

    let berlin = station("8011160", "Berlin Hbf", 52.525, 13.369, source: .bahnDe)
    let halle = station("8010159", "Halle (Saale) Hbf", 51.477, 11.987, source: .bahnDe)
    let erfurt = station("8010101", "Erfurt Hbf", 50.972, 11.038, source: .bahnDe)
    let frankfurt = station("8000105", "Frankfurt (Main) Hbf", 50.107, 8.663, source: .bahnDe)
    let line = Line(name: "ICE 279", number: "279", product: .highSpeed, operatorName: "DB Fernverkehr AG")

    func stop(_ station: Station, arrival: TimeInterval?, departure: TimeInterval?, platform: String? = nil,
              delay: TimeInterval? = nil) -> Stopover {
        func time(_ minutes: TimeInterval?) -> TimeInfo? {
            guard let minutes else { return nil }
            return TimeInfo(planned: at(minutes), actual: delay.map { at(minutes + $0) })
        }
        let platform = platform.map { PlatformInfo(planned: $0, actual: nil) }
        return Stopover(station: station, arrival: time(arrival), departure: time(departure),
                        arrivalPlatform: arrival == nil ? nil : platform, departurePlatform: departure == nil ? nil : platform, cancelled: false)
    }

    /// The run as Transitous has it hours ahead: the timetable, no live times, Erfurt's platform missing.
    var timetable: Trip {
        Trip(id: "ice279", line: line, direction: "Chur", stopovers: [
            stop(berlin, arrival: nil, departure: 0, platform: "3"),
            stop(halle, arrival: 68, departure: 70, platform: "6"),
            stop(erfurt, arrival: 102, departure: 104),
            stop(frankfurt, arrival: 241, departure: 247, platform: "7"),
        ], cancelled: false, remarks: [], source: .transitous)
    }

    func timetablesClient(_ session: URLSession) -> OpenBoardsClient {
        OpenBoardsClient(http: HTTPClient(session: session))
    }

    func delays(_ stops: [Stopover]) -> [Int?] { stops.map { $0.arrival?.delayMinutes ?? $0.departure?.delayMinutes } }
    func platforms(_ stops: [Stopover]) -> [String?] { stops.map { ($0.arrivalPlatform ?? $0.departurePlatform)?.best } }

    /// DB OpenBoards reports +3 at Berlin, +18 at Frankfurt and Erfurt's platform; the whole run and the leg
    /// Halle → Frankfurt cut from it end up with the same times and platforms at the stops they share.
    @Test func legAndRunGetTheSameTimesAndPlatformsFromTheSameAnswers() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ICE279OpenBoardsProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let mock = MockProvider(source: .transitous)
        mock.trips["ice279"] = timetable
        let provider = CombinedProvider(primary: mock, fallback: nil, bahnDe: nil, bahnExpert: nil)
        let timetables = timetablesClient(session)
        let now = at(-180)

        let run = await LiveRun(provider: provider, timetables: timetables).refresh(timetable, wholeRun: true, now: now)
        #expect(delays(run.stopovers) == [3, nil, nil, 18])
        #expect(platforms(run.stopovers) == ["3", "6", "2", "7"])

        let saved = try #require(timetable.leg(fromIndex: 1, toIndex: 3))
        let refresher = JourneyRefresher(provider: provider, timetables: timetables)
        let leg = await refresher.refresh(Journey(legs: [saved], source: .transitous), now: now).legs[0]

        #expect(delays(leg.stopovers) == Array(delays(run.stopovers)[1...]))
        #expect(platforms(leg.stopovers) == Array(platforms(run.stopovers)[1...]))
        #expect(leg.arrival == run.stopovers[3].arrival)
        #expect(leg.departure == run.stopovers[1].departure)
        #expect(leg.arrivalPlatform?.best == "7")
    }

    /// Hours ahead nothing is live yet (the card still shows what an earlier answer had), so DB's boards
    /// have no live time for a stop: the run opened from the card keeps the card's times
    /// through its baseline instead of showing plain times and "0".
    @Test func theRememberedRunFillsWhatTheFreshAnswersLack() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ICE279OpenBoardsProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let mock = MockProvider(source: .transitous)
        mock.trips["ice279"] = timetable
        let provider = CombinedProvider(primary: mock, fallback: nil, bahnDe: nil, bahnExpert: nil)

        var remembered = timetable
        remembered.stopovers[1].departure?.actual = at(70 + 5)
        remembered.stopovers[2].arrivalPlatform = PlatformInfo(planned: "1", actual: nil)
        remembered.stopovers[3].arrival?.actual = at(241 + 9)

        let run = await LiveRun(provider: provider, timetables: timetablesClient(session)).refresh(timetable, baseline: remembered, wholeRun: true, now: at(-180))

        // DB's +3 and +18 and Erfurt's platform 2 are fresh and win; Halle's +5 only the remembered run knew.
        #expect(delays(run.stopovers) == [3, 5, nil, 18])
        #expect(platforms(run.stopovers) == ["3", "6", "2", "7"])
    }

    @Test func aBaselineOnlyFillsGapsAndNeverOverridesFreshData() {
        var fresh = timetable
        fresh.stopovers[0].departure?.actual = at(3)
        fresh.stopovers[3].arrival?.actual = at(241 + 18)
        var known = timetable
        known.stopovers[0].departure?.actual = at(7)
        known.stopovers[1].arrival?.actual = at(68 + 4)
        known.stopovers[1].departure?.actual = at(70 + 4)
        known.stopovers[2].arrivalPlatform = PlatformInfo(planned: "1", actual: nil)
        known.stopovers[3].arrival?.actual = at(241 + 25)
        known.stopovers[3].arrivalPlatform = PlatformInfo(planned: "9", actual: nil)
        known.line?.nightRail = true

        let merged = LiveRun.keepingKnown(from: known, in: fresh)

        #expect(delays(merged.stopovers) == [3, 4, nil, 18])
        #expect(merged.stopovers[1].departure?.delayMinutes == 4)
        #expect(platforms(merged.stopovers) == ["3", "6", "1", "7"])
        #expect(merged.line?.nightRail == true)
        #expect(LiveRun.keepingKnown(from: nil, in: fresh) == fresh)
    }

    /// A ring line calls at the same station every lap: a stop of another lap (another planned time) is not
    /// this one, however much it knows.
    @Test func aStopAtAnotherPlannedTimeTakesNothing() {
        let fresh = timetable
        var otherLap = timetable
        for index in otherLap.stopovers.indices {
            otherLap.stopovers[index].arrival = otherLap.stopovers[index].arrival.map { TimeInfo(planned: $0.planned.addingTimeInterval(3600), actual: $0.planned.addingTimeInterval(3600 + 300)) }
            otherLap.stopovers[index].departure = otherLap.stopovers[index].departure.map { TimeInfo(planned: $0.planned.addingTimeInterval(3600), actual: $0.planned.addingTimeInterval(3600 + 300)) }
            otherLap.stopovers[index].arrivalPlatform = PlatformInfo(planned: "12", actual: nil)
            otherLap.stopovers[index].departurePlatform = PlatformInfo(planned: "12", actual: nil)
        }

        let merged = LiveRun.keepingKnown(from: otherLap, in: fresh)

        #expect(merged == fresh)
        #expect(!LiveRun.isSameVisit(fresh.stopovers[1], otherLap.stopovers[1]))
        #expect(LiveRun.isSameVisit(fresh.stopovers[1], fresh.stopovers[1]))
    }

    /// The Zusatzhalt a saved leg remembers comes back into the run (bahn.de only reports it while the train runs).
    @Test func theBaselinesZusatzhaltComesBack() {
        var known = timetable
        var extra = stop(station("8010222", "Leipzig Hbf", 51.346, 12.382, source: .bahnDe), arrival: 85, departure: 87)
        extra.isAdditional = true
        known.stopovers.insert(extra, at: 2)

        let merged = LiveRun.keepingKnown(from: known, in: timetable)

        #expect(merged.stopovers.map(\.station.name) == ["Berlin Hbf", "Halle (Saale) Hbf", "Leipzig Hbf", "Erfurt Hbf", "Frankfurt (Main) Hbf"])
        #expect(merged.stopovers[2].isAdditional)
    }

    /// A baseline's made-up "on time" (actual == planned) for a run hours ahead doesn't fill a gap.
    @Test func aBaselinesInferredOnTimeIsDroppedHoursAhead() async {
        let mock = MockProvider(source: .transitous)
        mock.trips["ice279"] = timetable
        let provider = CombinedProvider(primary: mock, fallback: nil, bahnDe: nil, bahnExpert: nil)
        var known = timetable
        known.stopovers[1].arrival?.actual = at(68)
        known.stopovers[3].arrival?.actual = at(241 + 9)

        let run = await LiveRun(provider: provider, timetables: nil).refresh(timetable, baseline: known, wholeRun: true, now: at(-5 * 60))

        #expect(delays(run.stopovers) == [nil, nil, nil, 9])
    }

    /// The journey refresh and the trip view decide alike when bahn.de is worth a request.
    @Test func bahnDeRulesAreTheSameForLegAndRun() {
        let run = timetable
        let span = LiveRun.span(of: run)
        #expect(span?.origin.name == "Berlin Hbf")
        #expect(span?.destination.name == "Frankfurt (Main) Hbf")
        #expect(span?.stopovers.count == 4)
        #expect(LiveRun.isRunningSoon(span!, now: at(-11 * 60)))
        #expect(!LiveRun.isRunningSoon(span!, now: at(-13 * 60)))
        // Erfurt lacks a platform: worth an hourly look up to a week ahead.
        #expect(LiveRun.needsPlatforms(span!, now: at(-3 * 24 * 60)))
        #expect(!LiveRun.needsPlatforms(span!, now: at(-8 * 24 * 60)))
    }
}

/// DB OpenBoards for ICE 279 on 20 Oct 2026: +3 leaving Berlin, +18 arriving at Frankfurt, nothing live at Halle
/// (the train isn't about to run) and only the schedule (platform 2) at Erfurt.
private final class ICE279OpenBoardsProtocol: OpenBoardsProtocol, @unchecked Sendable {
    override class func answer(_ side: BoardSide, evas: [String], url: URL) -> (Int, String) {
        func item(_ at: String, live: String? = nil, platform: String) -> [String: Any] {
            OpenBoardsJSON.item(side, "ICE", 279, at: "2026-10-20T\(at):00+02:00", live: live.map { "2026-10-20T\($0):00+02:00" }, platformSchedule: platform)
        }
        let items: [[String: Any]]? = switch (side, evas.first) {
        case (.departure, "8011160"): [item("06:43", live: "06:46", platform: "3")]
        case (.arrival, "8010159"): [item("07:51", platform: "6")]
        case (.departure, "8010159"): [item("07:53", platform: "6")]
        case (.arrival, "8010101"): [item("08:25", platform: "2")]
        case (.departure, "8010101"): [item("08:27", platform: "2")]
        case (.arrival, "8000105"): [item("10:44", live: "11:02", platform: "7")]
        case (.departure, "8000105"): [item("10:50", live: "11:05", platform: "7")]
        default: nil
        }
        return items.map { (200, OpenBoardsJSON.board(side, $0)) } ?? super.answer(side, evas: evas, url: url)
    }
}
