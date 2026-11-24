import Foundation
import Testing
@testable import BetterBahnKit

@Suite struct KomfortCheckinTests {
    private func ticket() throws -> DBTicket {
        let url = try #require(Bundle.module.url(forResource: "bahnde-order-kci", withExtension: "json", subdirectory: "Fixtures"))
        return try #require(try DBOrder.tickets(from: Data(contentsOf: url), orderNumber: "123456789012").first)
    }

    private func date(_ string: String) -> Date { JSONDecoding.parseISODate(string)! }

    @Test func readsCheckinFromOrder() throws {
        let ticket = try ticket()
        let checkin = try #require(ticket.komfortCheckin)
        #expect(checkin.tripUUID == "00000000-0000-0000-0000-0000000000aa")
        #expect(checkin.legs.count == 1)
        let leg = checkin.legs[0]
        #expect(leg.index == 0)
        #expect(leg.trainName == "ICE 1101")
        #expect(leg.status.isAvailable)
        #expect(!leg.status.isCheckedIn)
        #expect(leg.status.possibleFrom == date("2026-11-24T13:34:00Z"))
        #expect(leg.status.reservedSeats == [KomfortCheckin.Seat(coach: "39", seat: "73")])
        #expect(ticket.needsBahnCardForCheckin)
        #expect(ticket.reservedSeat(on: leg) == KomfortCheckin.Seat(coach: "39", seat: "73"))
    }

    @Test func opensFromPossibleTimeUntilArrival() throws {
        let ticket = try ticket()
        #expect(ticket.komfortCheckinLegs(at: date("2026-11-24T13:00:00Z")).isEmpty)
        #expect(ticket.komfortCheckinLegs(at: date("2026-11-24T13:34:00Z")).count == 1)
        #expect(ticket.komfortCheckinLegs(at: date("2026-11-24T18:00:00Z")).count == 1)
        // 19:19 in Munich is 18:19 UTC.
        #expect(ticket.komfortCheckinLegs(at: date("2026-11-24T18:20:00Z")).isEmpty)
    }

    @Test func buildsRequest() throws {
        let ticket = try ticket()
        let checkin = try #require(ticket.komfortCheckin)
        let leg = checkin.legs[0]
        let reserved = checkin.request(for: leg, bundleID: ticket.bundleID, seats: [.init(coach: "39", seat: "73")],
                                       bahnCardNumber: "7081 4100 0000 0000")
        #expect(try reserved.json() == #"{"bahncardNumber":"7081410000000000","legIdx":0,"leistungsbuendelId":"KC1A2B3C","mitSitzplatzwechsel":false,"plaetze":[{"platznummer":"73","wagennummer":"39"}],"tripUUID":"00000000-0000-0000-0000-0000000000aa"}"#)
        let other = checkin.request(for: leg, bundleID: ticket.bundleID, seats: [.init(coach: "39", seat: "75")], bahnCardNumber: nil)
        #expect(other.mitSitzplatzwechsel)
        #expect(other.bahncardNumber == nil)
        #expect(try !other.json().contains("bahncardNumber"))

        // No reservation in bahn.de's status: the ticket's decides.
        var unlisted = leg
        unlisted.status.reservedSeats = []
        #expect(!checkin.request(for: unlisted, bundleID: "B", seats: [.init(coach: "39", seat: "73")], bahnCardNumber: nil,
                                 ticketReservation: ticket.reservedSeat(on: leg)).mitSitzplatzwechsel)
        #expect(!checkin.request(for: unlisted, bundleID: "B", seats: [.init(coach: "39", seat: "73")], bahnCardNumber: nil).mitSitzplatzwechsel)
    }

    @Test func readsCheckinAnswer() throws {
        let answer = #"{"kciFaehig":true,"kciMoeglichAb":"2026-11-24T13:34:00Z","kontrollstatus":"EINGECHECKT","checkinId":"x","eingechecktePlaetze":[{"wagennummer":"39","platznummer":"75"}],"reserviertePlaetze":[],"umcheckenMoeglich":true,"umcheckenMoeglichAb":"2026-11-24T13:45:41Z","stichprobe":true}"#
        let status = try DBOrderPage.checkinStatus(from: ["state": "ok", "response": answer])
        #expect(status.isCheckedIn)
        #expect(status.checkedInSeats == [KomfortCheckin.Seat(coach: "39", seat: "75")])
        #expect(status.spotCheck == true)

        var ticket = try ticket()
        ticket.updateKomfortCheckin(legIndex: 0, status: status)
        let leg = try #require(ticket.komfortCheckin?.legs.first)
        #expect(leg.status.isCheckedIn)
        #expect(!leg.canChangeSeat(at: date("2026-11-24T13:45:00Z")))
        #expect(leg.canChangeSeat(at: date("2026-11-24T13:46:00Z")))
    }

    @Test func readsCheckinErrors() {
        #expect(throws: DBOrderPage.Failure.notReady) { try DBOrderPage.checkinStatus(from: ["state": "noToken"]) }
        #expect(throws: DBOrderPage.Failure.checkinRefused("Platz ist belegt")) {
            try DBOrderPage.checkinStatus(from: ["state": "error", "status": 400, "response": #"{"message":"Platz ist belegt"}"#] as [String: Any])
        }
        #expect(throws: DBOrderPage.Failure.sessionExpired) {
            try DBOrderPage.checkinStatus(from: ["state": "error", "status": 401, "response": ""] as [String: Any])
        }
        #expect(throws: DBOrderPage.Failure.http(500)) {
            try DBOrderPage.checkinStatus(from: ["state": "error", "status": 500, "response": "oops"] as [String: Any])
        }
    }

    @Test func checksBahnCardNumber() {
        #expect(KomfortCheckin.isValidBahnCardNumber("7081 4100 0000 0000"))
        #expect(!KomfortCheckin.isValidBahnCardNumber("7081"))
    }

    @Test func oldTicketsStillLoad() throws {
        var saved = try JSONSerialization.jsonObject(with: JSONEncoder().encode(try ticket())) as! [String: Any]
        saved["komfortCheckin"] = nil
        let data = try JSONSerialization.data(withJSONObject: saved)
        #expect(try JSONDecoder().decode(DBTicket.self, from: data).komfortCheckin == nil)
    }
}
