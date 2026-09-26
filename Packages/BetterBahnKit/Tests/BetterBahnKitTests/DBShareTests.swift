import Foundation
import Testing
@testable import BetterBahnKit

@Suite struct DBShareTests {
    private let webText = """
        Verbindung am Sa. 26.09.2026
        • von Stuttgart Hbf, Abfahrt 16:57 Uhr Gl. 16 mit 89687
        • nach Berlin Hbf, Ankunft 22:22 Uhr Gl. 5 mit ICE 1502
        Verbindung ansehen: https://www.bahn.de/buchung/start?vbid=1cea41f0-5a87-4d9f-8456-305c9d635d36
        """

    private let navigatorText = """
        Schaffhausen → Berlin Hbf
        27.09.2026

        IC 488
        Nach Stuttgart Hbf
        Ab 12:16 Schaffhausen, Gleis 4
        An 14:43 Stuttgart Hbf, Gleis 3

        ICE 576
        Nach Hamburg Hbf
        Ab 15:23 Stuttgart Hbf, Gleis 6
        An 16:40 Frankfurt(Main)Hbf, Gleis 8

        ICE 834
        Nach Berlin Gesundbrunnen
        Ab 17:02 Frankfurt(Main)Hbf, Gleis 13
        An 20:54 Berlin Hbf, Gleis 6

        Verbindung ansehen:
        https://www.bahn.de/buchung/start?vbid=aaae3fa2%2D4333%2D4b83%2D9a0f%2D7b01fe3bd5d4
        """

    private func berlin(_ string: String) -> Date {
        var components = DateComponents()
        let parts = string.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        (components.year, components.month, components.day, components.hour, components.minute) =
            (parts[0], parts[1], parts[2], parts[3], parts[4])
        return DBShare.berlinCalendar.date(from: components)!
    }

    @Test func findsVbidInBothFormats() {
        #expect(DBShare.vbid(in: webText) == "1cea41f0-5a87-4d9f-8456-305c9d635d36")
        #expect(DBShare.vbid(in: navigatorText) == "aaae3fa2-4333-4b83-9a0f-7b01fe3bd5d4")
        #expect(DBShare.vbid(in: "https://www.bahn.de/buchung/start?vbid=nonsense") == nil)
    }

    @Test func parsesWebText() throws {
        let connection = try #require(DBShare.connection(fromText: webText))
        #expect(connection.origin.name == "Stuttgart Hbf")
        #expect(connection.destination.name == "Berlin Hbf")
        #expect(connection.departure == berlin("2026-09-26 16:57"))
        #expect(connection.arrival == berlin("2026-09-26 22:22"))
        #expect(connection.legs.isEmpty)
        #expect(connection.firstTrain == "89687")
        #expect(connection.lastTrain == "ICE 1502")
    }

    @Test func parsesNavigatorText() throws {
        let connection = try #require(DBShare.connection(fromText: navigatorText))
        #expect(connection.legs.map(\.trainName) == ["IC 488", "ICE 576", "ICE 834"])
        #expect(connection.legs.map(\.origin.name) == ["Schaffhausen", "Stuttgart Hbf", "Frankfurt(Main)Hbf"])
        #expect(connection.legs.map(\.destination.name) == ["Stuttgart Hbf", "Frankfurt(Main)Hbf", "Berlin Hbf"])
        #expect(connection.departure == berlin("2026-09-27 12:16"))
        #expect(connection.arrival == berlin("2026-09-27 20:54"))
    }

    @Test func navigatorTimesRollOverMidnight() throws {
        let text = """
            München Hbf → Berlin Hbf
            27.09.2026

            ICE 1000
            Nach Berlin Hbf
            Ab 23:10 München Hbf, Gleis 1
            An 04:05 Berlin Hbf, Gleis 2
            """
        let connection = try #require(DBShare.connection(fromText: text))
        #expect(connection.arrival == berlin("2026-09-28 04:05"))
    }

    @Test func rejectsOtherText() {
        #expect(!DBShare.isConnection("Schau mal: https://www.bahn.de/"))
        #expect(!DBShare.isConnection("Treffen am 27.09.2026 um 12:00"))
        #expect(DBShare.isConnection(webText))
        #expect(DBShare.isConnection(navigatorText))
    }

    @Test func parsesRecon() throws {
        let recon = "¶HKI¶T$A=1@O=Stuttgart Hbf@X=9182760@Y=48784782@L=8000096@a=128@$A=1@O=Nürnberg Hbf@X=11082989@Y=49445615@L=8000284@a=128@$202609261657$202609261921$            89687$$1$$$$$$§T$A=1@O=Nürnberg Hbf@X=11082989@Y=49445615@L=8000284@a=128@$A=1@O=Berlin Hbf@X=13369549@Y=52525589@L=8098160@a=128@$202609261936$202609262222$ICE          1502$$1$$$$$$¶KC¶#VE#2#"
        let legs = try #require(DBShare.legs(fromRecon: recon))
        #expect(legs.map(\.trainName) == ["89687", "ICE 1502"])
        #expect(legs[0].origin.evaNumber == "8000096")
        #expect(legs[0].destination.name == "Nürnberg Hbf")
        #expect(abs((legs[1].destination.coordinate?.latitude ?? 0) - 52.525589) < 0.000_001)
        #expect(legs[0].departure == berlin("2026-09-26 16:57"))
        #expect(legs[1].arrival == berlin("2026-09-26 22:22"))
    }

    @Test func appURLRoundTrips() throws {
        let url = try #require(DBShare.appURL(for: navigatorText))
        #expect(DBShare.text(fromAppURL: url) == navigatorText)
        #expect(DBShare.text(fromAppURL: URL(string: "betterbahn://share?data=abc")!) == nil)
    }

    @Test func bareTrainNumberMatchesRunNumber() {
        let line = Line(name: "RE 8", number: "8", product: .regionalExpress, operatorName: nil, tripNumber: "89687")
        #expect(DBShareImporter.matches("89687", line))
        #expect(DBShareImporter.matches("ICE 1502", Line(name: "ICE 1502", number: "1502", product: .highSpeed, operatorName: nil)))
        #expect(!DBShareImporter.matches("ICE 1502", Line(name: "ICE 1503", number: "1503", product: .highSpeed, operatorName: nil)))
    }
}
