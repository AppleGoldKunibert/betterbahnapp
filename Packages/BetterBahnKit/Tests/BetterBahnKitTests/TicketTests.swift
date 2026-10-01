import CoreImage
import Foundation
import Testing
@testable import BetterBahnKit

@Suite struct TicketTests {
    private func orderData() throws -> Data {
        let url = try #require(Bundle.module.url(forResource: "bahnde-order", withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    private func berlin(_ string: String) -> Date {
        let parts = string.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        return DBShare.berlinCalendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2],
                                                                hour: parts[3], minute: parts[4]))!
    }

    private func tickets() throws -> [DBTicket] {
        try DBOrder.tickets(from: orderData(), orderNumber: "123456789012", fetchedAt: berlin("2026-10-01 12:00"))
    }

    // MARK: - Order

    @Test func readsDBTicket() throws {
        let all = try tickets()
        #expect(all.count == 2)
        let ticket = all[0]
        #expect(ticket.id == "123456789012-AB1C2345")
        #expect(ticket.offerName == "Sparpreis Europa")
        #expect(ticket.travelClass == 1)
        #expect(ticket.isTrainBound)
        #expect(ticket.conditions.first == "Zugbindung")
        #expect(ticket.materialisationType == "52")
        #expect(!ticket.isPartnerDocument)
        #expect(ticket.direction == .outward)
        #expect(ticket.travellers.map(\.displayName) == ["1 Erwachsener (BahnCard 50)", "1 Kind"])
        #expect(ticket.validFrom == JSONDecoding.parseISODate("2026-10-16T22:00:00Z"))
        #expect(ticket.validUntil == JSONDecoding.parseISODate("2026-10-19T01:00:00Z"))
        #expect(ticket.routeDescription == "Bernau (bei Berlin) → Bruxelles Midi")
        #expect(ticket.seats.isEmpty)
    }

    @Test func splitsLegsBetweenTickets() throws {
        let all = try tickets()
        let db = all[0], eurostar = all[1]
        // The walk inside Brussels station is no train.
        #expect(db.connection.map(\.trainName) == ["3343", "ICE 652", "ICE 314", "EUR 9149"])
        #expect(db.legs.map(\.trainName) == ["3343", "ICE 652", "ICE 314"])
        #expect(db.legs.map(\.displayName) == ["RE3", "ICE 652", "ICE 314"])
        #expect(db.legs[0].originEVA == "8013470")
        #expect(db.legs[0].departurePlatform == "4")
        #expect(db.legs[0].arrivalPlatform == "2")
        #expect(db.legs[0].departure == berlin("2026-10-17 07:08"))

        #expect(eurostar.isPartnerDocument)
        #expect(eurostar.issuer == "EUROSTAR")
        #expect(eurostar.legs.map(\.trainName) == ["EUR 9149"])
        #expect(eurostar.seats.map(\.description) == ["EUROSTAR 9149: Wagen 2, Platz 37, 38"])
    }

    @Test func readsForeignTimesInTheirOwnZone() throws {
        let eurostar = try tickets()[1].legs[0]
        // 16:51 in Brussels, 17:57 in London: 2 h 6 min.
        #expect(eurostar.departure == berlin("2026-10-17 16:51"))
        #expect(eurostar.arrival.timeIntervalSince(eurostar.departure) == 126 * 60)
    }

    @Test func readsReservationOnlyOrder() throws {
        let url = try #require(Bundle.module.url(forResource: "bahnde-order-reservation", withExtension: "json", subdirectory: "Fixtures"))
        let found = try DBOrder.tickets(from: Data(contentsOf: url), orderNumber: "123456789013")
        #expect(found.count == 1)
        let reservation = try #require(found.first)
        #expect(reservation.isReservationOnly)
        #expect(!reservation.isTrainBound)
        #expect(reservation.offerName == "Reservierung aus Kontingent")
        #expect(reservation.travelClass == 1)
        #expect(reservation.materialisationType == "9")
        #expect(reservation.legs.map(\.trainName) == ["ICE 804", "RJ 179"])
        #expect(reservation.seats.map(SeatReservation.init).map(\.description)
                == ["Wagen 14 · Plätze 103, 105, 106", "Wagen 262 · Plätze 101, 102, 105"])
        #expect(WalletPassPayload(ticket: reservation) == nil)
        // Tickets saved before reservation-only bookings existed still load.
        var saved = try JSONSerialization.jsonObject(with: JSONEncoder().encode(try tickets()[0])) as! [String: Any]
        saved.removeValue(forKey: "reservationOnly")
        let decoded = try JSONDecoder().decode(DBTicket.self, from: JSONSerialization.data(withJSONObject: saved))
        #expect(!decoded.isReservationOnly)
    }

    @Test func rejectsOtherJSON() {
        #expect(throws: DBOrder.ReadError.unreadable) {
            try DBOrder.tickets(from: Data("[1, 2]".utf8), orderNumber: "1")
        }
        #expect(throws: DBOrder.ReadError.noTickets) {
            try DBOrder.tickets(from: Data("{}".utf8), orderNumber: "1")
        }
    }

    // MARK: - Saved journeys

    private func leg(_ from: Station, _ to: Station, _ departure: String, _ arrival: String, line: String?, number: String?) -> Leg {
        Leg(origin: from, destination: to,
            departure: TimeInfo(planned: berlin(departure), actual: nil), arrival: TimeInfo(planned: berlin(arrival), actual: nil),
            departurePlatform: nil, arrivalPlatform: nil, tripId: line.map { "trip-\($0)" },
            line: line.map { Line(name: $0, number: number, product: .highSpeed, operatorName: nil) },
            direction: nil, isWalking: line == nil, cancelled: false, stopovers: [], remarks: [], source: .transitous)
    }

    private func bookedJourney(firstTrain: String = "RE 3", firstNumber: String = "3343") -> Journey {
        let bernau = station("a", "Bernau (bei Berlin)", source: .transitous)
        let berlinHbf = station("b", "Berlin Hbf", source: .transitous)
        let koeln = station("c", "Köln Hbf", source: .transitous)
        let midi = station("d", "Bruxelles-Midi", source: .transitous)
        let london = station("e", "London St Pancras International", source: .transitous)
        let arrivalLondon = DBOrder.localDate("2026-10-17T17:57:00", eva: "7004428")!
        var last = leg(midi, london, "2026-10-17 16:51", "2026-10-17 18:57", line: "EST 9149", number: "9149")
        last.arrival = TimeInfo(planned: arrivalLondon, actual: nil)
        return Journey(legs: [
            leg(bernau, berlinHbf, "2026-10-17 07:08", "2026-10-17 07:29", line: firstTrain, number: firstNumber),
            leg(berlinHbf, koeln, "2026-10-17 07:41", "2026-10-17 13:15", line: "ICE 652", number: "652"),
            leg(koeln, midi, "2026-10-17 13:42", "2026-10-17 15:35", line: "ICE 314", number: "314"),
            last,
        ], source: .transitous)
    }

    @Test func matchesTheBookedJourney() throws {
        let ticket = try tickets()[0]
        #expect(ticket.matches(bookedJourney()))
        // Same times, but a different first train.
        #expect(!ticket.matches(bookedJourney(firstTrain: "RB 24", firstNumber: "28812")))
    }

    @Test func describesConnectionForImport() throws {
        let shared = try #require(try tickets()[0].sharedConnection)
        #expect(shared.origin.evaNumber == "8013470")
        #expect(shared.destination.evaNumber == "7004428")
        #expect(shared.legs.count == 4)
        #expect(shared.firstTrain == "3343")
        #expect(shared.lastTrain == "EUR 9149")
    }

    // MARK: - Seat reservations

    @Test func reservationMatchesItsTrainOnly() throws {
        let journey = bookedJourney()
        let reservation = SeatReservation(try tickets()[1].seats[0])
        #expect(reservation.description == "Wagen 2 · Plätze 37, 38")
        // Booked as "EUROSTAR 9149", the feed calls it "EST 9149".
        #expect(journey.legs.map(reservation.matches) == [false, false, false, true])
        // Another train instead (e.g. after "Anderer Zug"): nothing matches, so nothing is shown.
        var replaced = journey
        replaced.legs[3].line = Line(name: "EST 9151", number: "9151", product: .highSpeed, operatorName: nil)
        #expect(!replaced.legs.contains(where: reservation.matches))
    }

    // MARK: - bahn.de page

    @Test func findsOrderNumberInPageURL() {
        #expect(DBOrderPage.orderNumber(in: URL(string: "https://www.bahn.de/buchung/reise?auftragsnummer=123456789012&gesamtreise-id=x")) == "123456789012")
        #expect(DBOrderPage.orderNumber(in: URL(string: "https://www.bahn.de/buchung/meine-reisen")) == nil)
        #expect(DBOrderPage.orderNumber(in: URL(string: "https://example.com/buchung/reise?auftragsnummer=1")) == nil)
        // Only bahn.de itself: the fetch script would otherwise run on (and import from) another site.
        #expect(DBOrderPage.orderNumber(in: URL(string: "https://evilbahn.de/buchung/reise?auftragsnummer=1")) == nil)
        #expect(DBOrderPage.orderNumber(in: URL(string: "https://bahn.de.evil.example/buchung/reise?auftragsnummer=1")) == nil)
        #expect(DBOrderPage.orderNumber(in: URL(string: "http://www.bahn.de/buchung/reise?auftragsnummer=1")) == nil)
    }

    @Test func readsPageResult() throws {
        let pdf = Data("%PDF-1.7".utf8)
        let result = try DBOrderPage.result(from: [
            "state": "ok", "order": "{}", "pdfs": ["AB1C2345": pdf.base64EncodedString()],
        ] as [String: Any])
        #expect(result.order == Data("{}".utf8))
        #expect(result.pdfs == ["AB1C2345": pdf])

        #expect(throws: DBOrderPage.Failure.notReady) { try DBOrderPage.result(from: ["state": "noToken"]) }
        #expect(throws: DBOrderPage.Failure.notFound) {
            try DBOrderPage.result(from: ["state": "error", "status": NSNumber(value: 404)] as [String: Any])
        }
        #expect(throws: DBOrderPage.Failure.blocked) {
            try DBOrderPage.result(from: ["state": "error", "status": NSNumber(value: 403)] as [String: Any])
        }
        #expect(throws: DBOrderPage.Failure.unreadable) { try DBOrderPage.result(from: nil) }
    }

    // MARK: - Barcode

    /// Every possible byte, like the binary (zlib-compressed) payload of a UIC ticket barcode.
    private let binaryPayload = Data((0...255).map(UInt8.init) + (0...255).reversed().map(UInt8.init))

    @Test func readsAztecBytesFromPDF() throws {
        let pdf = try #require(Self.pdf(withAztec: binaryPayload))
        let barcode = try #require(TicketBarcodeReader.barcode(inPDF: pdf))
        #expect(barcode.payload == binaryPayload)
        #expect(barcode.image != nil)
    }

    @Test func walletPassKeepsEveryByte() throws {
        var ticket = try tickets()[0]
        #expect(WalletPassPayload(ticket: ticket) == nil)
        ticket.barcode = DBTicket.Barcode(payload: binaryPayload, image: nil)
        let pass = try #require(WalletPassPayload(ticket: ticket))
        let json = try JSONSerialization.jsonObject(with: pass.json()) as? [String: Any]
        let barcode = try #require((json?["barcodes"] as? [[String: Any]])?.first)
        #expect(barcode["format"] as? String == "PKBarcodeFormatAztec")
        #expect(barcode["messageEncoding"] as? String == "iso-8859-1")
        let message = try #require(barcode["message"] as? String)
        #expect(message.data(using: .isoLatin1) == binaryPayload)
        #expect(pass.serialNumber == "123456789012-AB1C2345")
        let primary = pass.boardingPass.primaryFields
        #expect(primary.map(\.value) == ["Bernau (bei Berlin)", "Bruxelles Midi"])
        #expect(primary.map(\.label) == ["Ab 7:08", "An 15:35"])
        #expect(pass.boardingPass.auxiliaryFields.first?.label == "Zugbindung")
        #expect(pass.boardingPass.transitType == "PKTransitTypeGeneric")
    }

    /// An A4 PDF with `payload` as an Aztec code, like DB's ticket.
    static func pdf(withAztec payload: Data) -> Data? {
        let filter = CIFilter(name: "CIAztecCodeGenerator")!
        filter.setValue(payload, forKey: "inputMessage")
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 4, y: 4)),
              let image = CIContext().createCGImage(output, from: output.extent) else { return nil }
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let consumer = CGDataConsumer(data: data),
              let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { return nil }
        context.beginPDFPage(nil)
        context.draw(image, in: CGRect(x: 60, y: 560, width: 180, height: 180))
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }
}
