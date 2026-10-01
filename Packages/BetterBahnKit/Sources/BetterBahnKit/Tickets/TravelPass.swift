import Foundation

/// A ticket valid for a period instead of a journey ("Zeitkarte"), e.g. the Deutschland-Ticket,
/// added from a screenshot of its barcode. Everything shown comes from the barcode itself.
public struct TravelPass: Codable, Sendable, Hashable, Identifiable {
    public struct Holder: Codable, Sendable, Hashable {
        public var firstName: String?
        public var lastName: String?
        public var birthDate: DateComponents?

        public var name: String { [firstName, lastName].compactMap(\.self).joined(separator: " ") }

        /// "12.04.1990"
        public var birthDateDescription: String? {
            guard let year = birthDate?.year, let month = birthDate?.month, let day = birthDate?.day else { return nil }
            return String(format: "%02d.%02d.%04d", day, month, year)
        }
    }

    public enum ImportError: LocalizedError {
        case noBarcode, unreadable, noPass

        public var errorDescription: String? {
            switch self {
            case .noBarcode: "Auf dem Bild wurde kein Ticket-Barcode gefunden."
            case .unreadable: "Der Barcode konnte nicht gelesen werden. Unterstützt werden Tickets mit UIC-Barcode, z. B. aus dem DB Navigator."
            case .noPass: "Der Barcode gehört zu keiner Zeitkarte."
            }
        }
    }

    /// DB issues the Deutschland-Ticket of a BahnCard 100 for several months at once; a subscription's
    /// is valid one calendar month (plus 3 hours into the next).
    static let monthlyValidity: TimeInterval = 35 * 24 * 60 * 60

    public var id: UUID
    /// The tariff, e.g. "Deutschland-Ticket".
    public var name: String
    public var travelClass: Int?
    /// e.g. "DB AG".
    public var issuer: String?
    public var holder: Holder?
    public var issued: Date
    public var validFrom: Date?
    public var validUntil: Date?
    public var barcode: DBTicket.Barcode
    public var addedAt: Date

    /// Reads the pass from its barcode's bytes.
    public init(barcode: DBTicket.Barcode, addedAt: Date = .now) throws {
        guard let payload = barcode.payload,
              let content = try? UICBarcode.content(of: payload) else { throw ImportError.unreadable }
        guard let document = content.document else { throw ImportError.noPass }
        let holder = content.travellers.first(where: \.isTicketHolder) ?? content.travellers.first
        id = UUID()
        name = document.name ?? "Zeitkarte"
        travelClass = document.travelClass
        issuer = content.issuerName
        self.holder = holder.map { Holder(firstName: $0.firstName, lastName: $0.lastName, birthDate: $0.birthDate) }
        issued = content.issued
        validFrom = document.validFrom
        validUntil = document.validUntil
        // Only the bytes: the cut-out image would carry parts of the screenshot around the code.
        self.barcode = DBTicket.Barcode(payload: payload, image: nil)
        self.addedAt = addedAt
    }

    public var isDeutschlandTicket: Bool {
        name.localizedCaseInsensitiveContains("Deutschland")
    }

    /// A Deutschland-Ticket valid for longer than a month belongs to a BahnCard 100 – the barcode
    /// itself doesn't say so.
    public var isBahnCard100: Bool {
        guard isDeutschlandTicket, let validFrom, let validUntil else { return false }
        return validUntil.timeIntervalSince(validFrom) > Self.monthlyValidity
    }

    /// "BahnCard 100" or "Abo" for a Deutschland-Ticket; nil otherwise.
    public var kindDescription: String? {
        guard isDeutschlandTicket else { return nil }
        return isBahnCard100 ? "BahnCard 100" : "Abo"
    }

    /// "2. Klasse"
    public var classDescription: String? { travelClass.map { "\($0). Klasse" } }

    public func isExpired(at date: Date = .now) -> Bool {
        validUntil.map { $0 <= date } ?? false
    }

    public func isValid(at date: Date = .now) -> Bool {
        (validFrom.map { $0 <= date } ?? true) && !isExpired(at: date)
    }

    /// Same barcode bytes: the same pass imported again.
    public func isSamePass(as other: TravelPass) -> Bool {
        barcode.payload != nil && barcode.payload == other.barcode.payload
    }
}
