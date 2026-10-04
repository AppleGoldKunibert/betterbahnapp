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
    nonisolated(unsafe) static var pages: [URL: (html: String, status: Int)] = [:]
    static let lock = NSLock()

    static func session(number: String, html: String, status: Int = 200) -> URLSession {
        let url = VagonwebClient.trainURL(category: "ICE", number: number, timetableYear: 2026)
        lock.withLock { pages[url] = (html, status) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [VagonwebStubProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let page = request.url.flatMap { url in Self.lock.withLock { Self.pages[url] } } ?? (html: "", status: 404)
        let response = HTTPURLResponse(url: request.url!, statusCode: page.status, httpVersion: nil, headerFields: ["Content-Type": "text/html"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(page.html.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
