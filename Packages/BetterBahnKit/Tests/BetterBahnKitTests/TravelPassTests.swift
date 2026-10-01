import CoreImage
import Foundation
import Testing
@testable import BetterBahnKit

@Suite struct TravelPassTests {
    /// UIC barcodes like DB Navigator's Deutschland-Ticket (made-up traveller, zeroed signature):
    /// one of a BahnCard 100, valid three months, and a monthly one.
    private func payload(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "bin", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    private func berlin(_ string: String) -> Date {
        let parts = string.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        return DBShare.berlinCalendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2],
                                                                hour: parts[3], minute: parts[4]))!
    }

    @Test func readsUICBarcode() throws {
        let content = try UICBarcode.content(of: payload("uic-dticket-bc100"))
        #expect(content.issuerName == "DB AG")
        #expect(content.issued == JSONDecoding.parseISODate("2026-09-01T19:37:00Z"))
        #expect(content.travellers.count == 1)
        #expect(content.travellers.first?.firstName == "Erika")
        #expect(content.travellers.first?.lastName == "Mustermann")
        #expect(content.travellers.first?.isTicketHolder == true)
        let document = try #require(content.document)
        #expect(document.name == "Deutschland-Ticket")
        #expect(document.travelClass == 2)
        #expect(document.validFrom == berlin("2026-09-02 00:00"))
        #expect(document.validUntil == berlin("2026-12-02 03:00"))
    }

    @Test func bahnCard100DeutschlandTicket() throws {
        let pass = try TravelPass(barcode: DBTicket.Barcode(payload: payload("uic-dticket-bc100"), image: nil))
        #expect(pass.name == "Deutschland-Ticket")
        #expect(pass.isDeutschlandTicket)
        #expect(pass.isBahnCard100)
        #expect(pass.kindDescription == "BahnCard 100")
        #expect(pass.classDescription == "2. Klasse")
        #expect(pass.holder?.name == "Erika Mustermann")
        #expect(pass.holder?.birthDateDescription == "12.04.1990")
        #expect(pass.isValid(at: berlin("2026-10-01 12:00")))
        #expect(pass.isValid(at: berlin("2026-12-02 02:59")))
        #expect(pass.isExpired(at: berlin("2026-12-02 03:00")))
        #expect(!pass.isValid(at: berlin("2026-09-01 23:59")))
    }

    @Test func monthlyDeutschlandTicket() throws {
        let pass = try TravelPass(barcode: DBTicket.Barcode(payload: payload("uic-dticket-month"), image: nil))
        #expect(pass.validFrom == berlin("2026-10-01 00:00"))
        #expect(pass.validUntil == berlin("2026-11-01 03:00"))
        #expect(pass.isDeutschlandTicket)
        #expect(!pass.isBahnCard100)
        #expect(pass.kindDescription == "Abo")
    }

    @Test func rejectsOtherBarcodes() {
        #expect(throws: TravelPass.ImportError.self) {
            try TravelPass(barcode: DBTicket.Barcode(payload: Data("Hallo".utf8), image: nil))
        }
        #expect(throws: TravelPass.ImportError.self) {
            try TravelPass(barcode: DBTicket.Barcode(payload: nil, image: nil))
        }
    }

    @Test func readsBarcodeFromScreenshot() throws {
        let payload = try payload("uic-dticket-bc100")
        let image = try #require(Self.screenshot(withAztec: payload))
        let barcode = try #require(TicketBarcodeReader.barcode(inImage: image))
        #expect(barcode.payload == payload)
        #expect(try TravelPass(barcode: barcode).isBahnCard100)
    }

    @Test func keepsOnlyTheCodeFromScreenshot() throws {
        let payload = try payload("uic-dticket-bc100")
        let pass = try TravelPass(barcode: DBTicket.Barcode(payload: payload, image: Data([1, 2, 3])))
        #expect(pass.barcode.payload == payload)
        #expect(pass.barcode.image == nil)
    }

    @Test func walletPass() throws {
        let payload = try payload("uic-dticket-bc100")
        let pass = try TravelPass(barcode: DBTicket.Barcode(payload: payload, image: nil))
        let wallet = try #require(WalletPassPayload(pass: pass))
        let barcode = try #require(wallet.barcodes.first)
        #expect(wallet.barcodes.count == 1)
        #expect(barcode.format == "PKBarcodeFormatAztec")
        #expect(barcode.message.data(using: .isoLatin1) == payload)
        #expect(barcode.altText == nil)
        #expect(wallet.description == "Deutschland-Ticket")
        #expect(wallet.expirationDate == "2026-12-02T02:00:00Z")
        #expect(wallet.boardingPass.headerFields.map(\.value) == ["BahnCard 100"])
        #expect(wallet.boardingPass.primaryFields.map(\.label) == ["Ab 0:00", "Bis 3:00"])
        #expect(wallet.boardingPass.secondaryFields.map(\.value) == ["Deutschland-Ticket", "2. Klasse"])
        #expect(wallet.boardingPass.auxiliaryFields.map(\.value) == ["Erika Mustermann"])

        // The same barcode imported again gets the same serial number, so Wallet replaces it.
        let again = try TravelPass(barcode: DBTicket.Barcode(payload: payload, image: nil))
        #expect(WalletPassPayload(pass: again)?.serialNumber == wallet.serialNumber)
        let monthly = try TravelPass(barcode: DBTicket.Barcode(payload: self.payload("uic-dticket-month"), image: nil))
        #expect(WalletPassPayload(pass: monthly)?.serialNumber != wallet.serialNumber)
    }

    /// The pass signer refuses UIC barcodes whose signature doesn't verify (like the fixtures' zeroed
    /// one) with a 422, which the app explains instead of showing a bare server error.
    @Test func explainsARefusedBarcode() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UnverifiedBarcodeProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let pass = try TravelPass(barcode: DBTicket.Barcode(payload: payload("uic-dticket-month"), image: nil))
        let wallet = try #require(WalletPassPayload(pass: pass))

        await #expect(throws: WalletPassError.unverifiedBarcode) {
            try await WalletPassClient(http: HTTPClient(session: session)).signedPass(wallet)
        }
    }

    /// A phone-sized PNG with `payload` as an Aztec code on white, like a DB Navigator screenshot.
    static func screenshot(withAztec payload: Data) -> Data? {
        let filter = CIFilter(name: "CIAztecCodeGenerator")!
        filter.setValue(payload, forKey: "inputMessage")
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let code = CIContext().createCGImage(output, from: output.extent),
              let context = CGContext(data: nil, width: 1179, height: 2556, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 1179, height: 2556))
        context.draw(code, in: CGRect(x: 70, y: 1100, width: 1040, height: 1040))
        return context.makeImage().flatMap(TicketBarcodeReader.png)
    }
}

private final class UnverifiedBarcodeProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 422, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"error":"unverified_barcode"}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
