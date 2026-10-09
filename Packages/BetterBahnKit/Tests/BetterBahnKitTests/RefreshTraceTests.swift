import Foundation
import Testing
@testable import BetterBahnKit

/// The journey diagnostics: what a refresh asked each live source and what the leg shows afterwards.
struct RefreshTraceTests {
    let now = Date(timeIntervalSince1970: 1_790_000_000)

    func leg(_ name: String, departs: TimeInterval, arrives: TimeInterval, delay: TimeInterval? = nil) -> Leg {
        let departure = now.addingTimeInterval(departs), arrival = now.addingTimeInterval(arrives)
        return Leg(origin: station("gesundbrunnen", "Berlin Gesundbrunnen", source: .transitous),
                   destination: station("schwedt", "Schwedt (Oder)", source: .transitous),
                   departure: TimeInfo(planned: departure, actual: delay.map { departure.addingTimeInterval($0) }),
                   arrival: TimeInfo(planned: arrival, actual: delay.map { arrival.addingTimeInterval($0) }),
                   departurePlatform: nil, arrivalPlatform: nil, tripId: name,
                   line: Line(name: name, number: nil, product: .regionalExpress, operatorName: nil), direction: nil,
                   isWalking: false, cancelled: false, stopovers: [], remarks: [], source: .transitous)
    }

    /// No network: Transitous is a mock and the other sources aren't set up.
    func offlineProvider(failing: Bool = false) -> CombinedProvider {
        let mock = MockProvider(source: .transitous)
        mock.failing = failing
        return CombinedProvider(primary: mock, bahnDe: nil, bahnExpert: nil, vagonweb: nil, bahnJetzt: nil)
    }

    @Test func summaryShowsPlannedAndLiveTimeWithDelay() {
        let late = RefreshTrace.summary(of: leg("RE 3", departs: 0, arrives: 3600, delay: 19 * 60))
        #expect(late.contains("(+19)"))
        #expect(late.contains("→"))
        let onTime = RefreshTrace.summary(of: leg("RE 3", departs: 0, arrives: 3600, delay: 0))
        #expect(onTime.contains("(±0)"))
        let unknown = RefreshTrace.summary(of: leg("RE 3", departs: 0, arrives: 3600))
        #expect(unknown.contains("keine Live-Zeit"))
        #expect(!unknown.contains("→ "))
    }

    @Test func stopSummaryCountsLiveTimes() {
        func stop(_ id: String, _ minutes: TimeInterval, delay: TimeInterval?) -> JourneyStop {
            let planned = now.addingTimeInterval(minutes * 60)
            let time = TimeInfo(planned: planned, actual: delay.map { planned.addingTimeInterval($0 * 60) })
            return JourneyStop(evaNumber: id, name: id, arrival: time, departure: time)
        }
        let summary = RefreshTrace.summary(ofStops: [stop("a", 0, delay: 16), stop("b", 10, delay: nil), stop("c", 20, delay: 6)])
        #expect(summary == "3 Halte, 2 mit Live-Zeit, erster +16, letzter +6")
        #expect(RefreshTrace.summary(ofStops: [stop("a", 0, delay: nil)]) == "1 Halte, keiner mit Live-Zeit")
    }

    @Test func textListsEveryStepInOrder() {
        let trace = RefreshTrace(id: "x", title: "Berlin Gesundbrunnen → Schwedt (Oder)", date: now, legs: [
            .init(train: "RE 3", route: "Berlin Gesundbrunnen → Schwedt (Oder)", steps: [
                .init(source: "Transitous", outcome: .ok, detail: "ab 18:32 (±0)"),
                .init(source: "DB Timetables (Start/Ziel)", outcome: .empty, detail: "nichts erhalten"),
                .init(source: "bahn.de", outcome: .failed, detail: "Keine Antwort."),
            ]),
        ])
        let lines = trace.text.split(separator: "\n").map(String.init)
        #expect(lines[0] == "Berlin Gesundbrunnen → Schwedt (Oder)")
        #expect(lines.contains("RE 3 · Berlin Gesundbrunnen → Schwedt (Oder)"))
        let steps = lines.filter { $0.hasPrefix("  ") }
        #expect(steps == ["  ✓ Transitous: ab 18:32 (±0)", "  ∅ DB Timetables (Start/Ziel): nichts erhalten", "  ✗ bahn.de: Keine Antwort."])
    }

    @Test func traceSurvivesARestart() throws {
        let trace = RefreshTrace(id: "x", title: "Reise", date: now, legs: [
            .init(train: "RE 3", route: "A → B", steps: [.init(source: "bahn.de", outcome: .skipped, detail: "nicht eingerichtet")]),
        ])
        let decoded = try JSONDecoder().decode(RefreshTrace.self, from: JSONEncoder().encode(trace))
        #expect(decoded == trace)
    }

    /// A leg that arrived long ago isn't asked about any more; the trace says so instead of staying empty.
    @Test func refreshOfAFinishedLegExplainsWhyNothingWasAsked() async {
        let finished = leg("RE 3", departs: -4 * 3600, arrives: -3 * 3600, delay: 10 * 60)
        let journey = Journey(legs: [finished], source: .transitous)
        let (refreshed, trace) = await JourneyRefresher(provider: offlineProvider()).refreshTracing(journey, now: now)

        #expect(refreshed.legs == journey.legs)
        #expect(trace.id == journey.id)
        #expect(trace.title == "\(finished.origin.displayName) → \(finished.destination.displayName)")
        let steps = trace.legs.first?.steps ?? []
        #expect(steps.map(\.source) == ["Gespeichert", "Aktualisierung"])
        #expect(steps.last?.outcome == .skipped)
    }

    /// A failed request is what keeps an old delay on screen; the trace has to name it.
    @Test func refreshOfARunningLegNamesFailedAndMissingSources() async {
        let running = leg("RE 3", departs: -1800, arrives: 3600, delay: 10 * 60)
        let journey = Journey(legs: [running], source: .transitous)
        let (refreshed, trace) = await JourneyRefresher(provider: offlineProvider(failing: true)).refreshTracing(journey, now: now)

        // Nothing answered, so the last known delay stays.
        #expect(refreshed.legs.first?.departure.delayMinutes == 10)
        let steps = trace.legs.first?.steps ?? []
        #expect(steps.first?.source == "Gespeichert")
        #expect(steps.first { $0.source == "Transitous" }?.outcome == .failed)
        #expect(steps.first { $0.source == "DB Timetables (Start/Ziel)" }?.outcome == .skipped)
        #expect(steps.first { $0.source == "bahn.de" }?.outcome == .skipped)
    }
}
