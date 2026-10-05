import Foundation
import Testing
@testable import BetterBahnKit

private func vagonwebPage(_ name: String) throws -> String {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "html", subdirectory: "Fixtures"))
    return try String(contentsOf: url, encoding: .utf8)
}

private func berlinDate(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12) -> Date {
    VagonwebComposition.calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
}

/// vagonweb.cz's scheduled compositions: the train type and planned Wagenreihung for days ahead.
@Suite struct VagonwebTests {
    @Test func readsTheScheduledComposition() throws {
        let compositions = VagonwebComposition.scheduled(fromHTML: try vagonwebPage("vagonweb-ice154"))
        let composition = try #require(compositions.first)
        #expect(compositions.count == 1)
        #expect(composition.validFrom == nil && composition.validUntil == nil)
        #expect(composition.coaches.map(\.number) == ["21", "22", "23", "24", "25", "26", "28", "29"])
        let first = composition.coaches[0]
        #expect(first.series == "408.5")
        #expect(first.typeCode == "Bpmdzf")
        #expect(first.baureihe == "408")
        #expect(first.secondClass && !first.firstClass)
        #expect(first.bikeSpaces == 8)
        #expect(composition.coaches[1].notes == ["quiet zone"])
        let bistro = composition.coaches[5]
        #expect(bistro.typeCode == "BRpmz")
        #expect(bistro.diningSeats == 16)
        #expect(composition.coaches[7].firstClass)
    }

    @Test func leavesOutReportedCompositions() throws {
        // ICE 377 also has one people saw on 17.6.2026, in reverse order.
        let compositions = VagonwebComposition.scheduled(fromHTML: try vagonwebPage("vagonweb-ice377"))
        #expect(compositions.count == 1)
        #expect(compositions.first?.coaches.first?.number == "1")
        #expect(compositions.first?.coaches.last?.number == "14")
    }

    @Test func readsTheDatesAComposition() throws {
        let composition = try #require(VagonwebComposition.scheduled(fromHTML: try vagonwebPage("vagonweb-ice1005")).first)
        #expect(composition.validFrom == berlinDate(2025, 12, 14))
        #expect(composition.validUntil == berlinDate(2026, 10, 30))
        #expect(composition.applies(on: berlinDate(2026, 10, 30, hour: 23)))
        #expect(!composition.applies(on: berlinDate(2026, 10, 31, hour: 0)))
        #expect(!composition.applies(on: berlinDate(2025, 12, 13)))
    }

    @Test func splitsCoupledTrainsets() throws {
        let composition = try #require(VagonwebComposition.scheduled(fromHTML: try vagonwebPage("vagonweb-ice1005")).first)
        #expect(composition.units.map { $0.compactMap(\.number) } == [
            ["31", "32", "33", "35", "36", "37", "38", "39"],
            ["21", "22", "23", "25", "26", "27", "28", "29"],
        ])
        let lookup = composition.trainType(category: "ICE", number: "1005", date: "2026-10-05")
        #expect(lookup.summary == "ICE 3")
        #expect(lookup.source == "vagonweb")
        #expect(lookup.status == .planned)
        #expect(composition.coachSequence(trainName: "ICE 1005").formation.modelSummary == "2× ICE 3")
    }

    @Test func trainTypeUsesTheTrainsetsSeries() throws {
        // ICE 4 coaches are "812" or "412"; the drawings say BR 412.
        let ice4 = try #require(VagonwebComposition.scheduled(fromHTML: try vagonwebPage("vagonweb-ice377")).first)
        #expect(ice4.trainType(category: "ICE", number: "377", date: "2026-10-05").summary == "ICE 4")
        let neo = try #require(VagonwebComposition.scheduled(fromHTML: try vagonwebPage("vagonweb-ice154")).first)
        #expect(neo.trainType(category: "ICE", number: "154", date: "2026-10-05").summary == "ICE 3neo")
    }

    @Test func plannedCoachSequence() throws {
        let composition = try #require(VagonwebComposition.scheduled(fromHTML: try vagonwebPage("vagonweb-ice377")).first)
        let sequence = composition.coachSequence(trainName: "ICE 377")
        #expect(sequence.source == .vagonweb(validFrom: nil, validUntil: nil))
        #expect(sequence.coaches.count == 13)
        #expect(sequence.coaches.allSatisfy { $0.start == nil && $0.sector == nil })
        #expect(sequence.platform == nil)
        #expect(sequence.groups.count == 1)
        #expect(!sequence.hasOtherTrains)

        let first = sequence.coaches[0]
        #expect(first.number == "1")
        #expect(first.kind == .passenger)
        #expect(first.bikeSpaces == 8)
        #expect(first.amenities.contains(.bikeSpace))
        #expect(first.amenities.contains(.severelyDisabledSeats))

        let restaurant = sequence.coaches[9]
        #expect(restaurant.number == "10")
        #expect(restaurant.kind == .halfDiningCar)
        #expect(restaurant.firstClass)

        let family = sequence.coaches[8]
        #expect(family.amenities.contains(.wheelchairSpace))
        #expect(family.amenities.contains(.familyZone))
        #expect(family.amenities.contains(.infantCabin))
        #expect(sequence.coaches[2].amenities == [.quietZone])
        #expect(sequence.coaches[10].amenities == [.bahnComfortSeats])
    }

    @Test func fullDiningCar() throws {
        let composition = try #require(VagonwebComposition.scheduled(fromHTML: try vagonwebPage("vagonweb-ice1005")).first)
        let sequence = composition.coachSequence(trainName: "ICE 1005")
        let restaurant = try #require(sequence.coaches.first { $0.number == "36" })
        #expect(restaurant.kind == .diningCar)
        #expect(!restaurant.firstClass && !restaurant.secondClass)
        #expect(sequence.groups.count == 2)
    }

    @Test func timetableYearStartsAtTheDecemberChange() {
        #expect(VagonwebClient.timetableYear(of: berlinDate(2025, 12, 13, hour: 23)) == 2025)
        #expect(VagonwebClient.timetableYear(of: berlinDate(2025, 12, 14, hour: 0)) == 2026)
        #expect(VagonwebClient.timetableYear(of: berlinDate(2026, 10, 4)) == 2026)
        #expect(VagonwebClient.timetableYear(of: berlinDate(2026, 12, 12)) == 2026)
        #expect(VagonwebClient.timetableYear(of: berlinDate(2026, 12, 13)) == 2027)
    }

    @Test func trainURL() {
        let url = VagonwebClient.trainURL(category: "ice", number: "377", timetableYear: 2026)
        #expect(url.absoluteString == "https://www.vagonweb.cz/razeni/vlak.php?zeme=DB&kategorie=ICE&cislo=377&rok=2026&lang=en")
    }

    @Test func recognisesCloudflaresCheck() throws {
        #expect(VagonwebClient.isChallenge("<html><head><title>Just a moment...</title></head><script>window._cf_chl_opt = {}</script></html>"))
        #expect(!VagonwebClient.isChallenge(try vagonwebPage("vagonweb-ice154")))
    }

    @Test func picksTheCompositionForTheDay() async throws {
        let html = try vagonwebPage("vagonweb-ice1005")
        let client = VagonwebClient(http: HTTPClient(session: VagonwebStubProtocol.session(number: "1005", html: html)))
        #expect(try await client.composition(category: "ICE", number: "1005", on: berlinDate(2026, 10, 5))?.coaches.count == 16)
        // Only dated compositions and none for the day: nothing rather than the wrong plan.
        #expect(try await client.composition(category: "ICE", number: "1005", on: berlinDate(2026, 11, 5)) == nil)
    }

    @Test func fallsBackToTheBrowserWhenCloudflareChecks() async throws {
        let html = try vagonwebPage("vagonweb-ice154")
        let challenge = "<html><head><title>Just a moment...</title></head><body><script>window._cf_chl_opt = {}</script></body></html>"
        let client = VagonwebClient(http: HTTPClient(session: VagonwebStubProtocol.session(number: "154", html: challenge, status: 403)),
                                    browserLoader: { _ in html })
        let lookup = try await client.trainType(category: "ICE", number: "154", on: berlinDate(2026, 10, 5))
        #expect(lookup?.summary == "ICE 3neo")
    }

    @Test func recognisesTheAnzeigenPage() throws {
        #expect(VagonwebClient.isGate(try vagonwebPage("vagonweb-ice804-gate")))
        #expect(VagonwebComposition.scheduled(fromHTML: try vagonwebPage("vagonweb-ice804-gate")).isEmpty)
        #expect(!VagonwebClient.isGate(try vagonwebPage("vagonweb-ice154")))
    }

    @Test func asksAgainAfterTheAnzeigenPage() async throws {
        let client = VagonwebClient(http: HTTPClient(session: VagonwebStubProtocol.session(
            number: "377", html: try vagonwebPage("vagonweb-ice804-gate"), revisit: try vagonwebPage("vagonweb-ice377"))))
        let lookup = try await client.trainType(category: "ICE", number: "377", on: berlinDate(2026, 10, 5))
        #expect(lookup?.summary == "ICE 4")
    }

    @Test func plannedCompositionsRequest() throws {
        let page = VagonwebClient.trainURL(category: "ICE", number: "804", timetableYear: 2026)
        let request = try #require(VagonwebClient.plannedCompositionsRequest(for: page))
        #expect(request.url?.absoluteString == "https://www.vagonweb.cz/razeni/ajax_dalsi_razeni_vlak.php")
        #expect(request.httpMethod == "POST")
        let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        #expect(body.contains("cislo=804") && body.contains("rok=2026") && body.contains("vsechny_planovane=1") && body.contains("nazev=_n_"))
        #expect(request.value(forHTTPHeaderField: "Referer") == page.absoluteString)
    }

    @Test func anzeigenPageForeverGoesToTheBrowser() async throws {
        let gate = try vagonwebPage("vagonweb-ice804-gate")
        let html = try vagonwebPage("vagonweb-ice1005")
        let client = VagonwebClient(http: HTTPClient(session: VagonwebStubProtocol.session(number: "804", html: gate)),
                                    browserLoader: { _ in html })
        #expect(try await client.coachSequence(category: "ICE", number: "804", on: berlinDate(2026, 10, 5))?.coaches.count == 16)
    }

    @Test func readsWhereTheTrainChangesDirection() throws {
        let composition = try #require(VagonwebComposition.scheduled(fromHTML: try vagonwebPage("vagonweb-ice377")).first)
        #expect(composition.reversalStations == ["Frankfurt (Main) Hbf", "Basel SBB", "Bern"])
        let ice154 = try #require(VagonwebComposition.scheduled(fromHTML: try vagonwebPage("vagonweb-ice154")).first)
        #expect(ice154.reversalStations.isEmpty)
        // English only, and German with "in" repeated and a sentence after it.
        #expect(VagonwebComposition.reversalStations(fromNotes: "<div class='info_i'><span class=info1d>i</span> Changes direction in Leipzig Hbf, from Leipzig in reverse order</div>")
            == ["Leipzig Hbf"])
        #expect(VagonwebComposition.reversalStations(fromNotes: "<div class='info_i'>Fahrtrichtungswechsel in Stuttgart Hbf und in St. Gallen. Ab dort umgekehrt</div>")
            == ["Stuttgart Hbf", "St. Gallen"])
        #expect(VagonwebComposition.reversalStations(fromNotes: "<div class='info_i'>quiet zone</div>").isEmpty)
    }

    @Test func comparesStationNamesLooselyForReversals() {
        #expect(VagonwebClient.stationKey("Frankfurt (Main) Hbf") == VagonwebClient.stationKey("Frankfurt(Main)Hbf"))
        #expect(VagonwebClient.stationKey("Frankfurt (M) Hauptbahnhof") == "frankfurtmain")
        #expect(VagonwebClient.stationKey("Zürich HB") == VagonwebClient.stationKey("Zurich"))
        #expect(VagonwebClient.stationKey("Basel SBB") != VagonwebClient.stationKey("Basel Bad Bf"))
    }

    @Test func countsTheReversalsUpToTheStop() {
        let route = ["Berlin Gesundbrunnen", "Berlin Hbf", "Erfurt Hbf", "Frankfurt(Main)Hbf", "Mannheim Hbf",
                     "Basel Bad Bf", "Basel SBB", "Olten", "Bern", "Thun", "Interlaken Ost"]
        let candidates = ["Frankfurt (Main) Hbf", "Basel SBB", "Bern"] + VagonwebClient.terminusStations
        let at = { (stop: String) in
            VagonwebClient.reversals(at: stop, route: Array(route[...route.firstIndex(of: stop)!]), in: candidates)
        }
        #expect(at("Berlin Hbf") == [])
        // Leaving Frankfurt it already runs the other way round.
        #expect(at("Frankfurt(Main)Hbf") == ["Frankfurt(Main)Hbf"])
        #expect(at("Mannheim Hbf") == ["Frankfurt(Main)Hbf"])
        #expect(at("Olten")?.count == 2)
        #expect(at("Thun")?.count == 3)
        // A train starting at a terminus doesn't change direction there.
        #expect(VagonwebClient.reversals(at: "Fulda", route: ["Frankfurt (Main) Hbf", "Hanau Hbf", "Fulda"], in: candidates) == [])
        #expect(VagonwebClient.reversals(at: "Köln Hbf", route: ["Berlin Hbf"], in: candidates) == nil)
    }

    @Test func plannedSequenceTurnsRoundAfterAReversal() async throws {
        let html = try vagonwebPage("vagonweb-ice377")
        let client = VagonwebClient(http: HTTPClient(session: VagonwebStubProtocol.session(number: "377", html: html)))
        let at = { (name: String) in
            BahnDeClient.FormationRequest(category: "ICE", number: "377", station: station("x", name), plannedDeparture: berlinDate(2026, 10, 5))
        }
        let before = try #require(try await client.coachSequence(for: at("Erfurt Hbf"), route: ["Berlin Hbf", "Erfurt Hbf"]))
        #expect(before.coaches.first?.number == "1")
        #expect(before.travelsTowardsPlatformEnd == false)
        #expect(before.reversals.isEmpty)

        let after = try #require(try await client.coachSequence(for: at("Mannheim Hbf"),
                                                                route: ["Berlin Hbf", "Frankfurt (Main) Hbf", "Mannheim Hbf"]))
        #expect(after.coaches.first?.number == "14")
        #expect(after.coaches.last?.number == "1")
        #expect(after.coaches.map(\.id) == Array(0..<13))
        #expect(after.reversals == ["Frankfurt (Main) Hbf"])

        // Without the train's stops the direction stays unknown.
        let unknown = try #require(try await client.coachSequence(for: at("Mannheim Hbf")))
        #expect(unknown.travelsTowardsPlatformEnd == nil)
        #expect(unknown.coaches.first?.number == "1")
    }

    @Test func formationRequestKnowsTheStopsBefore() throws {
        let now = berlinDate(2026, 10, 5, hour: 10)
        let line = Line(name: "ICE 377", number: "377", product: .highSpeed, operatorName: nil)
        let stops = [("Berlin Hbf", -60.0), ("Frankfurt (Main) Hbf", 30), ("Mannheim Hbf", 70)].map { name, minutes in
            (station: station(name, name), departure: Optional(TimeInfo(planned: now.addingTimeInterval(minutes * 60), actual: nil)))
        }
        let request = try #require(BahnDeClient.formationRequest(line: line, stops: stops, wholeRun: true, now: now))
        #expect(request.station.name == "Frankfurt (Main) Hbf")
        #expect(request.stopsBefore == ["Berlin Hbf"])
        #expect(BahnDeClient.formationRequest(line: line, stops: stops, now: now)?.stopsBefore == nil)
    }

    @Test func withoutBrowserCloudflaresCheckCountsAsBlocked() async throws {
        let challenge = "<html><head><title>Just a moment...</title></head><body><script>window._cf_chl_opt = {}</script></body></html>"
        let client = VagonwebClient(http: HTTPClient(session: VagonwebStubProtocol.session(number: "155", html: challenge, status: 403)))
        await #expect(throws: TransitError.rateLimited) {
            try await client.trainType(category: "ICE", number: "155", on: berlinDate(2026, 10, 5))
        }
    }
}

/// Answers requests for a train's page with the page registered for it. Keyed by URL, so tests running
/// in parallel need different trains.
final class VagonwebStubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var pages: [URL: (html: String, status: Int, revisit: String?)] = [:]
    static let lock = NSLock()

    /// - Parameter revisit: the page when it is asked for again (with a `Referer`), like vagonweb
    ///   answers after its "anzeigen" page.
    static func session(number: String, html: String, status: Int = 200, revisit: String? = nil) -> URLSession {
        let url = VagonwebClient.trainURL(category: "ICE", number: number, timetableYear: 2026)
        lock.withLock { pages[url] = (html, status, revisit) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [VagonwebStubProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let page = request.url.flatMap { url in Self.lock.withLock { Self.pages[url] } } ?? (html: "", status: 404, revisit: nil)
        let html = request.value(forHTTPHeaderField: "Referer") != nil ? page.revisit ?? page.html : page.html
        let response = HTTPURLResponse(url: request.url!, statusCode: page.status, httpVersion: nil, headerFields: ["Content-Type": "text/html"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(html.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
