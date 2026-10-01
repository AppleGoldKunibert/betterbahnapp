import CryptoKit
import Foundation

/// The `pass.json` of an Apple Wallet pass for a DB ticket or a pass like the Deutschland-Ticket. The `Cloudflare/pass-signer` Worker adds
/// the pass type and team, the images and the signature – it never touches the barcode.
public struct WalletPassPayload: Encodable, Sendable, Hashable {
    public struct Barcode: Encodable, Sendable, Hashable {
        public var format = "PKBarcodeFormatAztec"
        public var message: String
        /// Wallet turns `message` back into bytes with this encoding. ISO-8859-1 maps every byte 0–255
        /// to one character, so the binary UIC barcode comes out exactly as DB printed it.
        public var messageEncoding = "iso-8859-1"
        public var altText: String?
    }

    public struct Field: Encodable, Sendable, Hashable {
        public var key: String
        public var label: String?
        public var value: String
    }

    public struct BoardingPass: Encodable, Sendable, Hashable {
        /// Wallet always draws a symbol between the two stations; "generic" is a plain arrow instead
        /// of the train picture.
        public var transitType = "PKTransitTypeGeneric"
        public var headerFields: [Field] = []
        public var primaryFields: [Field] = []
        public var secondaryFields: [Field] = []
        public var auxiliaryFields: [Field] = []
        public var backFields: [Field] = []
    }

    public var serialNumber: String
    public var description: String
    public var organizationName = "BetterBahn"
    public var foregroundColor = "rgb(255, 255, 255)"
    public var labelColor = "rgb(255, 214, 219)"
    public var backgroundColor = "rgb(219, 23, 48)"
    public var relevantDate: String?
    public var expirationDate: String?
    public var barcodes: [Barcode]
    public var boardingPass: BoardingPass

    /// A pass for `ticket`, or nil when its barcode's bytes couldn't be read (a pass must carry the
    /// original code, never a re-created one).
    public init?(ticket: DBTicket) {
        guard let payload = ticket.barcode?.payload, !payload.isEmpty,
              let message = String(data: payload, encoding: .isoLatin1) else { return nil }
        serialNumber = ticket.id
        description = "\(ticket.offerName) \(ticket.routeDescription)"
        barcodes = [Barcode(message: message, altText: ticket.orderNumber)]

        let first = ticket.legs.first, last = ticket.legs.last
        relevantDate = first.map { JSONDecoding.isoString($0.departure) }
        expirationDate = (ticket.validUntil ?? last?.arrival.addingTimeInterval(24 * 60 * 60)).map(JSONDecoding.isoString)

        var pass = BoardingPass()
        if let first {
            pass.headerFields = [Field(key: "date", label: "Datum",
                                       value: first.departure.formatted(Self.dateStyle))]
        }
        pass.primaryFields = [
            Field(key: "from", label: first.map { "Ab " + $0.departure.formatted(Self.timeStyle(for: $0.originEVA)) },
                  value: Station.displayName(for: ticket.validOrigin)),
            Field(key: "to", label: last.map { "An " + $0.arrival.formatted(Self.timeStyle(for: $0.destinationEVA)) },
                  value: Station.displayName(for: ticket.validDestination)),
        ]
        pass.secondaryFields = [Field(key: "offer", label: "Ticket", value: ticket.offerName)]
        if let travelClass = ticket.classDescription {
            pass.secondaryFields.append(Field(key: "class", label: "Klasse", value: travelClass))
        }
        let trains = ticket.legs.map(\.displayName).joined(separator: ", ")
        if !trains.isEmpty {
            pass.auxiliaryFields.append(Field(key: "trains", label: ticket.isTrainBound ? "Zugbindung" : "Züge", value: trains))
        }
        let seats = ticket.seats.map(SeatReservation.init)
        if !seats.isEmpty {
            pass.auxiliaryFields.append(Field(key: "seats", label: "Sitzplatz",
                                              value: seats.map(\.description).joined(separator: "\n")))
        }
        pass.backFields = [
            Field(key: "order", label: "Auftragsnummer", value: ticket.orderNumber),
            Field(key: "travellers", label: "Reisende", value: ticket.travellers.map(\.displayName).joined(separator: "\n")),
            Field(key: "conditions", label: "Bedingungen", value: ticket.conditions.joined(separator: "\n")),
            Field(key: "legs", label: "Verbindung", value: ticket.legs.map { leg in
                "\(leg.displayName): \(Station.displayName(for: leg.originName)) \(leg.departure.formatted(Self.timeStyle(for: leg.originEVA)))"
                    + " → \(Station.displayName(for: leg.destinationName)) \(leg.arrival.formatted(Self.timeStyle(for: leg.destinationEVA)))"
            }.joined(separator: "\n")),
            Field(key: "note", label: "Hinweis",
                  value: "Der Barcode stammt unverändert aus deinem DB-Ticket. Gültig nur mit dem bei der Buchung angegebenen Ausweis."),
        ].filter { !$0.value.isEmpty }
        boardingPass = pass
    }

    /// A pass for a `TravelPass` such as the Deutschland-Ticket. Wallet draws the code from the
    /// barcode's bytes alone, so nothing else from the screenshot ends up on the pass. The serial
    /// number comes from those bytes: adding the same pass again replaces it in Wallet.
    public init?(pass: TravelPass) {
        guard let payload = pass.barcode.payload, !payload.isEmpty,
              let message = String(data: payload, encoding: .isoLatin1) else { return nil }
        serialNumber = "pass-" + SHA256.hash(data: payload).prefix(12).map { String(format: "%02x", $0) }.joined()
        description = pass.name
        // No text under the code: the barcode area shows the code only.
        barcodes = [Barcode(message: message, altText: nil)]
        expirationDate = pass.validUntil.map(JSONDecoding.isoString)

        var fields = BoardingPass()
        if let kind = pass.kindDescription {
            fields.headerFields = [Field(key: "kind", label: "Art", value: kind)]
        }
        // Validity as the "route": from → until.
        fields.primaryFields = [
            Field(key: "from", label: pass.validFrom.map { "Ab " + $0.formatted(Self.berlinTime) } ?? "Ab",
                  value: pass.validFrom.map { $0.formatted(Self.dateStyle) } ?? "–"),
            Field(key: "until", label: pass.validUntil.map { "Bis " + $0.formatted(Self.berlinTime) } ?? "Bis",
                  value: pass.validUntil.map { $0.formatted(Self.dateStyle) } ?? "–"),
        ]
        fields.secondaryFields = [Field(key: "offer", label: "Ticket", value: pass.name)]
        if let travelClass = pass.classDescription {
            fields.secondaryFields.append(Field(key: "class", label: "Klasse", value: travelClass))
        }
        if let holder = pass.holder?.name, !holder.isEmpty {
            fields.auxiliaryFields = [Field(key: "holder", label: "Inhaber", value: holder)]
        }
        fields.backFields = [
            Field(key: "birthDate", label: "Geburtsdatum", value: pass.holder?.birthDateDescription ?? ""),
            Field(key: "issuer", label: "Ausgestellt von", value: pass.issuer ?? ""),
            Field(key: "note", label: "Hinweis",
                  value: "Der Barcode stammt unverändert aus deinem Ticket. Bei der Kontrolle gilt die Karte in der App, in der du sie gekauft hast."),
        ].filter { !$0.value.isEmpty }
        boardingPass = fields
    }

    public func json() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    private static var dateStyle: Date.FormatStyle {
        Date.FormatStyle(date: .abbreviated, time: .omitted, locale: Locale(identifier: "de_DE"),
                         timeZone: TimeZone(identifier: "Europe/Berlin")!)
    }

    private static var berlinTime: Date.FormatStyle {
        Date.FormatStyle(date: .omitted, time: .shortened, locale: Locale(identifier: "de_DE"),
                         timeZone: TimeZone(identifier: "Europe/Berlin")!)
    }

    /// Times in the station's own zone, as on the ticket.
    private static func timeStyle(for eva: String?) -> Date.FormatStyle {
        Date.FormatStyle(date: .omitted, time: .shortened, locale: Locale(identifier: "de_DE"),
                         timeZone: DBOrder.timeZone(forEVA: eva))
    }
}

/// Has the `Cloudflare/pass-signer` Worker sign a pass (the certificate must never ship in the app).
/// Only the genuine app may use it, so requests carry the App Attest token (`WorkerAuth`).
public struct WalletPassClient: Sendable {
    public static let baseURL = URL(string: "https://betterbahn-pass.kunibert88.workers.dev")!

    let http: HTTPClient
    let auth: WorkerAuth?

    /// `auth` defaults to `WorkerAuth.shared` on the app's real session and none on others (tests).
    public init(http: HTTPClient = HTTPClient(timeout: 20), auth: WorkerAuth? = nil) {
        self.http = http
        self.auth = http.workerAuth(auth)
    }

    /// The signed `.pkpass`.
    public func signedPass(_ payload: WalletPassPayload) async throws -> Data {
        var request = URLRequest(url: Self.baseURL.appending(path: "pass"), timeoutInterval: http.timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/vnd.apple.pkpass", forHTTPHeaderField: "Accept")
        request.httpBody = try payload.json()
        return try await http.sendRaw(request, auth: auth)
    }
}
