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

    // MARK: Nightjet, Euronight and the ÖBB's and SBB's trains

    private func request(_ category: String, _ number: String, at name: String, on date: Date) -> BahnDeClient.FormationRequest {
        BahnDeClient.FormationRequest(category: category, number: number, station: station("x", name), plannedDeparture: date)
    }

    @Test func readsTheVehiclesOfEachSection() throws {
        let composition = try #require(VagonwebComposition.scheduled(fromHTML: try vagonwebPage("vagonweb-ec163")).first)
        // The locomotive changes on the way: vagonweb stacks them in one position, each with its section.
        let locomotives = composition.coaches.filter { $0.number == nil }
        #expect(locomotives.map(\.series) == ["460", "1116", "1116", "1116"])
        #expect(locomotives.first?.section?.from == "Zürich" && locomotives.first?.section?.to == "Buchs")
        #expect(composition.coaches.filter { $0.section == nil }.compactMap(\.number).first == "302")
        // Notes are the ones under a coach, not its rating.
        #expect(composition.coaches.first { $0.number == "312" }?.notes == ["seats 103-106 for service"])
    }

    @Test func cutsTheCompositionDownToTheStopsSection() throws {
        let composition = try #require(VagonwebComposition.scheduled(fromHTML: try vagonwebPage("vagonweb-ec163")).first)
        let atZurich = composition.restricted(to: ["Zürich HB"])
        #expect(atZurich.coaches.filter { $0.number == nil }.map(\.series) == ["460"])
        #expect(atZurich.coaches.compactMap(\.number) == (302...312).map(String.init))
        // After Buchs the SBB's locomotive is gone and the ÖBB's one, which takes over there, is in.
        let atInnsbruck = composition.restricted(to: ["Zürich HB", "Sargans", "Buchs SG", "Feldkirch", "Innsbruck Hbf"])
        #expect(atInnsbruck.coaches.filter { $0.number == nil }.map(\.section?.to) == ["Selzthal"])
        #expect(atInnsbruck.coaches.compactMap(\.number) == (302...312).map(String.init))
        // A route that has none of the sections' stations (names spelt differently): the coaches for the whole run, no locomotive.
        let nowhere = composition.restricted(to: ["Nowhere"])
        #expect(nowhere.coaches.compactMap(\.number) == (302...312).map(String.init) && nowhere.coaches.allSatisfy { $0.number != nil })
    }

    @Test func picksTheCompositionOfTheSectionAndLeavesOutCoupledTrains() async throws {
        let html = try vagonwebPage("vagonweb-rjx161")
        let client = VagonwebClient(http: HTTPClient(session: VagonwebStubProtocol.session(category: "RJX", country: "OBB", number: "161", html: html)))
        let date = berlinDate(2026, 10, 15)
        let route = ["Zürich HB", "Sargans", "Buchs SG", "Feldkirch", "Innsbruck Hbf", "Salzburg Hbf"]
        let first = try #require(try await client.coachSequence(for: request("RJX", "161", at: "Feldkirch", on: date), route: Array(route[...3])))
        #expect(first.coaches.compactMap(\.number) == ["27", "26", "25", "24", "23", "22", "21"])
        #expect(first.coaches.last?.kind == .locomotive)
        // From Innsbruck the composition for that section: the coaches of RJX 184 running together with it are left out.
        let second = try #require(try await client.coachSequence(for: request("RJX", "161", at: "Salzburg Hbf", on: date), route: route))
        #expect(second.coaches.compactMap(\.number) == ["27", "26", "25", "24", "23", "22", "21"])
        #expect(second.coaches.filter { $0.kind == .locomotive }.count == 1)
        // Without the stops the first composition is the one.
        let unknown = try #require(try await client.coachSequence(for: request("RJX", "161", at: "Salzburg Hbf", on: date)))
        #expect(unknown.coaches.compactMap(\.number) == ["27", "26", "25", "24", "23", "22", "21"])
    }

    @Test func turnsTheStretchBeforeTheReversalRound() async throws {
        let composition = try #require(VagonwebComposition.scheduled(fromHTML: try vagonwebPage("vagonweb-rjx161")).first)
        // "Changes direction in Buchs SG, from Zürich until Buchs in reverse order": the drawing is the train after Buchs.
        #expect(composition.reversalStations == ["Buchs SG"] && composition.startsReversed)
        // Where a stretch starts at a station the train changes direction at anyway, counting reversals is enough.
        let ice = try #require(VagonwebComposition.scheduled(fromHTML: try vagonwebPage("vagonweb-ice377")).first)
        #expect(!ice.startsReversed)

        let html = try vagonwebPage("vagonweb-rjx161")
        let client = VagonwebClient(http: HTTPClient(session: VagonwebStubProtocol.session(category: "RJX", country: "OBB", number: "161", html: html)))
        let date = berlinDate(2026, 10, 15)
        let atStart = try #require(try await client.coachSequence(for: request("RJX", "161", at: "Zürich HB", on: date), route: ["Zürich HB"]))
        #expect(atStart.coaches.first?.kind == .locomotive && atStart.coaches.last?.number == "27")
        let afterBuchs = try #require(try await client.coachSequence(
            for: request("RJX", "161", at: "Feldkirch", on: date), route: ["Zürich HB", "Buchs SG", "Feldkirch"]))
        #expect(afterBuchs.coaches.first?.number == "27" && afterBuchs.coaches.last?.kind == .locomotive)
    }

    @Test func readsSleepingCouchetteAndCarCarrierWagons() async throws {
        let html = try vagonwebPage("vagonweb-nj465")
        let client = VagonwebClient(http: HTTPClient(session: VagonwebStubProtocol.session(category: "NJ", country: "OBB", number: "465", html: html)))
        let date = berlinDate(2026, 3, 10)
        let atStart = try #require(try await client.coachSequence(for: request("NJ", "465", at: "Zürich HB", on: date), route: ["Zürich HB"]))
        let kinds = atStart.coaches.map(\.kind)
        #expect(kinds.first == .locomotive)
        #expect(kinds.contains(.sleeper) && kinds.contains(.couchette))
        // The car transporters only run from Feldkirch.
        #expect(!kinds.contains(.other))
        let atInnsbruck = try #require(try await client.coachSequence(
            for: request("NJ", "465", at: "Innsbruck Hbf", on: date), route: ["Zürich HB", "Buchs SG", "Feldkirch", "Innsbruck Hbf"]))
        // The second car transporter only runs until 2 February.
        #expect(atInnsbruck.coaches.filter { $0.kind == .other }.count == 1)
        let winter = try #require(try await client.coachSequence(
            for: request("NJ", "465", at: "Innsbruck Hbf", on: berlinDate(2026, 2, 1)), route: ["Zürich HB", "Buchs SG", "Feldkirch", "Innsbruck Hbf"]))
        #expect(winter.coaches.filter { $0.kind == .other }.count == 2)
        // The HŽPP coaches for Zagreb are only there up to Schwarzach-St.Veit, the Zürich–Graz ones all the way.
        #expect(atInnsbruck.coaches.contains { $0.number == "318" } && atInnsbruck.coaches.contains { $0.number == "314" })
        let atVillach = try #require(try await client.coachSequence(
            for: request("NJ", "465", at: "Villach Hbf", on: date),
            route: ["Zürich HB", "Buchs SG", "Feldkirch", "Innsbruck Hbf", "Schwarzach-St. Veit", "Villach Hbf"]))
        #expect(!atVillach.coaches.contains { $0.number == "318" } && atVillach.coaches.contains { $0.number == "314" })
        // The page is for the timetable year, but this composition only applies until 13 June.
        #expect(try await client.coachSequence(for: request("NJ", "465", at: "Zürich HB", on: berlinDate(2026, 10, 15)), route: ["Zürich HB"]) == nil)
    }

    @Test func looksUnderTheCountriesOfTheRailways() async throws {
        #expect(VagonwebClient.countries(for: "NJ") == ["OBB", "SBB", "DB"])
        #expect(VagonwebClient.countries(for: "ec") == ["DB", "OBB", "SBB"])
        #expect(VagonwebClient.trainURL(category: "EC", number: "163", timetableYear: 2026, country: "SBB").absoluteString
            == "https://www.vagonweb.cz/razeni/vlak.php?zeme=SBB&kategorie=EC&cislo=163&rok=2026&lang=en")
        // Not under DB's (404), not under ÖBB's, but under the SBB's.
        let html = try vagonwebPage("vagonweb-ec163")
        let client = VagonwebClient(http: HTTPClient(session: VagonwebStubProtocol.session(category: "EC", country: "SBB", number: "163", html: html)))
        let composition = try await client.composition(category: "EC", number: "163", on: berlinDate(2026, 10, 15))
        #expect(composition?.coaches.compactMap(\.number).first == "302")
        // Only DB's trains are asked for their ICE series.
        #expect(try await client.trainType(category: "EC", number: "163", on: berlinDate(2026, 10, 15)) == nil)
    }

    @Test func nightjetsAreOnlyAskedOfVagonwebNeverOfBahnDe() async throws {
        let line = Line(name: "NJ 465", number: "465", product: .nightTrain, operatorName: nil)
        let ref = try #require(BahnDeClient.sequenceReference(for: line))
        #expect(ref.category == "NJ" && ref.number == "465")
        let req = request("NJ", "465", at: "Zürich HB", on: berlinDate(2026, 10, 15))
        // No request to bahn.de: its client has no stub here, so one would have gone to the real server.
        #expect(try await BahnDeClient().coachSequence(req) == nil)
        #expect(BahnDeClient.sequenceReference(for: Line(name: "FLX 20", number: "20", product: .regionalExpress, operatorName: nil)) == nil
                || BahnDeClient.sequenceReference(for: Line(name: "FLX 20", number: "20", product: .regionalExpress, operatorName: nil))?.category != "FLX")
    }

    // MARK: Days a coach runs on

    /// EC 163's coaches 302 and 303: "runs on ⑥, ⑦ until 13.6. and from 17.10., on 24., 25., 26., 31.12., 1., 2., 5., 6.1., …".
    @Test func readsTheDaysACoachRunsOn() throws {
        let note = "runs on ⑥ , ⑦ until 13.6. and from 17.10., on 24., 25., 26., 31.12., 1., 2., 5., 6.1., 6.4., 1., 14., 15., 25.5., 4., 5.6., 26.10., 7., 8.12."
        let restriction = try #require(DayRestriction(note: note))
        #expect(restriction.weekdays == [6, 7])
        // Friday 16.10. is before the new period starts, Saturday 17.10. is in it, a Sunday in June after the 13th is not.
        #expect(!restriction.runs(month: 10, day: 16, weekday: 5))
        #expect(restriction.runs(month: 10, day: 17, weekday: 6))
        #expect(restriction.runs(month: 6, day: 13, weekday: 6))
        #expect(!restriction.runs(month: 6, day: 14, weekday: 7))
        #expect(restriction.runs(month: 3, day: 7, weekday: 6))
        #expect(!restriction.runs(month: 3, day: 9, weekday: 1))
        // The holidays listed run whatever the weekday: the month of a bare "24." is the next one named (12).
        #expect(restriction.runs(month: 12, day: 24, weekday: 4))
        #expect(restriction.runs(month: 1, day: 6, weekday: 3))
        #expect(restriction.runs(month: 5, day: 14, weekday: 4))
        #expect(restriction.runs(month: 10, day: 26, weekday: 1) && restriction.runs(month: 12, day: 8, weekday: 2))
        #expect(!restriction.runs(month: 12, day: 23, weekday: 3))

        let until = try #require(DayRestriction(note: "runs until 02.02."))
        #expect(until.runs(month: 2, day: 2, weekday: 1) && until.runs(month: 12, day: 20, weekday: 1))
        #expect(!until.runs(month: 2, day: 3, weekday: 2) && !until.runs(month: 10, day: 1, weekday: 4))
        #expect(DayRestriction(note: "runs from 17.10.")?.runs(month: 11, day: 1, weekday: 7) == true)
        #expect(DayRestriction(note: "runs on ⑤, ⑦")?.runs(month: 4, day: 3, weekday: 5) == true)
        #expect(DayRestriction(note: "runs on ⑤, ⑦")?.runs(month: 4, day: 4, weekday: 6) == false)
        #expect(DayRestriction(note: "runs on 24., 25.12.")?.runs(month: 12, day: 25, weekday: 5) == true)
        #expect(DayRestriction(note: "runs on 24., 25.12.")?.runs(month: 12, day: 26, weekday: 6) == false)
    }

    @Test func leavesNotesItDoesNotUnderstandAlone() {
        for note in ["quiet zone", "service is provided by DoN boardservice", "seats 103-106 for service", "runs Mon-Fri",
                     "runs on ⑧", "runs on ⑥, ⑦ except 24.12.", "runs on ⑥, not on 3.4.", "runs on 24.", "runs on ⑥, on 24., 25.",
                     "runs until 32.13.", "runs together with RJX 184", "Fahrtrichtung wechselt", "8.4", ""] {
            #expect(DayRestriction(note: note) == nil, "\(note)")
        }
    }

    @Test func readsWhichTrainTheCompositionIsFiledFor() throws {
        #expect(VagonwebComposition.scheduled(fromHTML: try vagonwebPage("vagonweb-ice377")).first?.train == "ICE 377")
        #expect(VagonwebComposition.scheduled(fromHTML: try vagonwebPage("vagonweb-ice154")).first?.train == "ICE 154")
        #expect(VagonwebComposition.scheduled(fromHTML: try vagonwebPage("vagonweb-ec163")).first?.train == "EC 163")
        #expect(VagonwebComposition.scheduled(fromHTML: try vagonwebPage("vagonweb-nj465")).first?.train == "NJ 465")
    }

    @Test func skipsAnotherRailwaysTrainWithTheSameNumber() async throws {
        // ICE 2506 ran instead of ICE 706 and has no plan under DB's; a train with its number under the
        // SBB's is another one (vagonweb's EC 163 standing in for it here).
        let html = try vagonwebPage("vagonweb-ec163")
        let client = VagonwebClient(http: HTTPClient(session: VagonwebStubProtocol.session(category: "ICE", country: "SBB", number: "163", html: html)))
        #expect(try await client.composition(category: "ICE", number: "163", on: berlinDate(2026, 10, 15)) == nil)
        let composition = try #require(VagonwebComposition.scheduled(fromHTML: html).first)
        #expect(composition.isTrain(category: "ec", number: "163"))
        #expect(!composition.isTrain(category: "ICE", number: "163"))
        #expect(!composition.isTrain(category: "EC", number: "164"))
        var unnamed = composition
        unnamed.train = nil
        #expect(unnamed.isTrain(category: "ICE", number: "2506"))
        // DB's own page counts whatever train it names (vagonweb files some trains under another number).
        let dbClient = VagonwebClient(http: HTTPClient(session: VagonwebStubProtocol.session(category: "ICE", country: "DB", number: "2506", html: html)))
        #expect(try await dbClient.composition(category: "ICE", number: "2506", on: berlinDate(2026, 10, 15)) != nil)
    }

    @Test func leavesOutCoachesThatDoNotRunThatDay() async throws {
        let html = try vagonwebPage("vagonweb-ec163")
        let client = VagonwebClient(http: HTTPClient(session: VagonwebStubProtocol.session(category: "EC", country: "SBB", number: "163", html: html)))
        let numbers = { (day: Date) async throws -> [String] in
            let sequence = try await client.coachSequence(for: request("EC", "163", at: "Zürich HB", on: day), route: ["Zürich HB"])
            return try #require(sequence).coaches.compactMap(\.number)
        }
        // Friday 16 October: 302 and 303 run on Saturdays and Sundays from 17 October.
        let friday = try await numbers(berlinDate(2026, 10, 16, hour: 8))
        #expect(!friday.contains("302") && !friday.contains("303") && friday.contains("304") && friday.contains("312"))
        let saturday = try await numbers(berlinDate(2026, 10, 17, hour: 8))
        #expect(saturday.contains("302") && saturday.contains("303") && saturday.contains("304") && saturday.contains("312"))
        // Christmas Eve 2025 is a Wednesday (and in the timetable year 2026), but listed.
        let christmasEve = try await numbers(berlinDate(2025, 12, 24, hour: 8))
        #expect(christmasEve.contains("302") && christmasEve.contains("303"))
        // The plain composition keeps every coach: only a train's day cuts it down.
        let composition = try #require(VagonwebComposition.scheduled(fromHTML: html).first)
        #expect(composition.coaches.compactMap(\.number).count == 11)
        #expect(composition.operating(on: berlinDate(2026, 10, 16, hour: 8)).coaches.compactMap(\.number).count == 9)
    }

    @Test func aTrainAfterMidnightCountsForTheDayItStartedOn() {
        // 0:54 on Saturday 17 October is still the operating day of Friday the 16th.
        let night = VagonwebComposition.operatingDay(of: berlinDate(2026, 10, 17, hour: 0))
        #expect(night.day == 16 && night.weekday == 5)
        let morning = VagonwebComposition.operatingDay(of: berlinDate(2026, 10, 17, hour: 6))
        #expect(morning.day == 17 && morning.weekday == 6)
        #expect(VagonwebComposition.operatingDay(of: berlinDate(2026, 10, 18, hour: 12)).weekday == 7)
    }

    @Test func stationNamesWithBahnhofMatch() {
        #expect(VagonwebClient.stationKey("Feldkirch Bahnhof") == VagonwebClient.stationKey("Feldkirch"))
        #expect(VagonwebClient.stationKey("Buchs SG") == VagonwebClient.stationKey("Buchs (SG)"))
        #expect(VagonwebClient.stationKey("Buchs SG") == VagonwebClient.stationKey("Buchs"))
        #expect(VagonwebClient.stationKey("Zürich HB") == VagonwebClient.stationKey("Zürich"))
        // Another station of the same town is another station.
        #expect(VagonwebClient.stationKey("Wien Meidling") != VagonwebClient.stationKey("Wien Hbf"))
        #expect(VagonwebClient.stationKey("Schwarzach-St. Veit") == VagonwebClient.stationKey("Schwarzach-St.Veit"))
    }
}

/// Answers requests for a train's page with the page registered for it. Keyed by URL, so tests running
/// in parallel need different trains.
final class VagonwebStubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var pages: [URL: (html: String, status: Int, revisit: String?)] = [:]
    static let lock = NSLock()

    /// - Parameter revisit: the page when it is asked for again (with a `Referer`), like vagonweb
    ///   answers after its "anzeigen" page.
    static func session(category: String = "ICE", country: String = "DB", number: String, html: String, status: Int = 200,
                        revisit: String? = nil, otherPages: [String: String] = [:]) -> URLSession {
        let url = VagonwebClient.trainURL(category: category, number: number, timetableYear: 2026, country: country)
        for (otherCountry, page) in otherPages {
            let other = VagonwebClient.trainURL(category: category, number: number, timetableYear: 2026, country: otherCountry)
            lock.withLock { pages[other] = (page, 200, nil) }
        }
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
