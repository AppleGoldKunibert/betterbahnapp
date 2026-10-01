import Foundation

/// Reads the content of a UIC ticket barcode (IRS 90918-9 static barcode, "#UT"), as printed on DB
/// tickets and shown for the Deutschland-Ticket in DB Navigator.
///
/// The barcode holds a header, the issuer's signature (not checked here) and zlib-compressed records.
/// Only the "U_FLEX" record (FCB version 3, ASN.1 unaligned PER) is read, and of that only what a
/// pass needs: issuing date, travellers and the first open ticket or pass with its validity.
public enum UICBarcode {
    public struct Content: Sendable, Hashable {
        public struct Traveller: Sendable, Hashable {
            public var firstName: String?
            public var lastName: String?
            public var birthDate: DateComponents?
            public var isTicketHolder: Bool
        }

        public struct Document: Sendable, Hashable {
            /// The tariff, e.g. "Deutschland-Ticket", or the product name if there's none.
            public var name: String?
            /// 1 or 2; nil for other classes.
            public var travelClass: Int?
            public var validFrom: Date?
            public var validUntil: Date?
        }

        public var issuerName: String?
        public var issued: Date
        public var travellers: [Traveller]
        /// The first open ticket or pass; nil if the barcode holds something else (e.g. a reservation).
        public var document: Document?
    }

    public enum DecodingError: Error {
        case notUICBarcode, unsupportedRecord, malformed
    }

    public static func content(of payload: Data) throws -> Content {
        let bytes = [UInt8](payload)
        // "#UT" + version (2) + issuer RICS (4) + key ID (5), then the signature: 50 bytes in
        // version 1, 64 in version 2. Then the compressed length (4 digits) and the data.
        guard bytes.count > 14, bytes.starts(with: Array("#UT".utf8)),
              let version = Int(ascii: bytes[3..<5]) else { throw DecodingError.notUICBarcode }
        let signatureLength = switch version {
        case 1: 50
        case 2: 64
        default: throw DecodingError.notUICBarcode
        }
        let lengthStart = 14 + signatureLength
        guard bytes.count >= lengthStart + 4, let length = Int(ascii: bytes[lengthStart..<lengthStart + 4]),
              bytes.count >= lengthStart + 4 + length else { throw DecodingError.malformed }
        let records = try inflate(Array(bytes[(lengthStart + 4)..<(lengthStart + 4 + length)]))

        // Records: ID (6) + version (2) + length including this header (4), then the data.
        var index = 0
        while index + 12 <= records.count {
            guard let recordLength = Int(ascii: records[(index + 8)..<(index + 12)]), recordLength >= 12,
                  index + recordLength <= records.count else { throw DecodingError.malformed }
            let id = String(decoding: records[index..<(index + 6)], as: UTF8.self)
            let recordVersion = Int(ascii: records[(index + 6)..<(index + 8)])
            if id == "U_FLEX" && recordVersion == 3 {
                var reader = UPERReader(Array(records[(index + 12)..<(index + recordLength)]))
                return try FCB3.ticketData(&reader)
            }
            index += recordLength
        }
        throw DecodingError.unsupportedRecord
    }

    /// zlib data (RFC 1950): DEFLATE with a 2-byte header and a 4-byte checksum, which Foundation
    /// doesn't want.
    static func inflate(_ data: [UInt8]) throws -> [UInt8] {
        guard data.count > 6, data[0] & 0x0F == 8 else { throw DecodingError.malformed }
        let deflated = Data(data[2..<(data.count - 4)])
        guard let inflated = try? (deflated as NSData).decompressed(using: .zlib) else { throw DecodingError.malformed }
        return [UInt8](inflated as Data)
    }

    /// The FCB's day numbers and times as dates. The issuing day counts from January 1st, the
    /// validity start from the issuing day and its end from the start. Times with a UTC offset (in
    /// quarter hours, UTC = local + offset) are local; those without are taken as German time.
    static func date(year: Int, dayOfYear: Int, plusDays days: Int, minutes: Int, utcOffset: Int?) -> Date? {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        guard let newYear = utc.date(from: DateComponents(year: year, month: 1, day: 1)),
              let day = utc.date(byAdding: .day, value: dayOfYear - 1 + days, to: newYear) else { return nil }
        if let utcOffset {
            return day.addingTimeInterval(TimeInterval((minutes + utcOffset * 15) * 60))
        }
        var components = utc.dateComponents([.year, .month, .day], from: day)
        components.minute = minutes
        return DBShare.berlinCalendar.date(from: components)
    }
}

private extension Int {
    init?(ascii bytes: ArraySlice<UInt8>) {
        guard let value = Int(String(decoding: bytes, as: UTF8.self)) else { return nil }
        self = value
    }
}

// MARK: - FCB version 3

/// The parts of the FCB 3 schema (uicRailTicketData_v3.0.x.asn) on the way to an open ticket's or
/// pass's validity. Unaligned PER has no field lengths, so every field before those has to be read,
/// even if it's thrown away.
private enum FCB3 {
    typealias Content = UICBarcode.Content

    static func ticketData(_ r: inout UPERReader) throws -> Content {
        _ = try r.bit() // extensible
        var present = try r.presence(4)
        let issuing = try issuingData(&r)
        var travellers: [Content.Traveller] = []
        if present.next() { travellers = try travelerData(&r) }
        var document: Content.Document?
        // Only the first document is read: after anything else there's no knowing where it ends.
        if present.next(), try r.length() > 0 { document = try documentData(&r, issuingYear: issuing.year, issuingDay: issuing.day) }
        guard let issued = UICBarcode.date(year: issuing.year, dayOfYear: issuing.day, plusDays: 0,
                                           minutes: issuing.minutes, utcOffset: 0) else { throw UICBarcode.DecodingError.malformed }
        return Content(issuerName: issuing.name, issued: issued, travellers: travellers, document: document)
    }

    static func issuingData(_ r: inout UPERReader) throws -> (year: Int, day: Int, minutes: Int, name: String?) {
        let extended = try r.bit()
        var present = try r.presence(13)
        if present.next() { _ = try r.constrained(1, 32000) } // securityProviderNum
        if present.next() { _ = try r.ia5() } // securityProviderIA5
        if present.next() { _ = try r.constrained(1, 32000) } // issuerNum
        if present.next() { _ = try r.ia5() } // issuerIA5
        let year = try r.constrained(2016, 2269)
        let day = try r.constrained(1, 366)
        let minutes = try r.constrained(0, 1439)
        let name = present.next() ? try r.utf8() : nil
        _ = try r.bit(); _ = try r.bit(); _ = try r.bit() // specimen, securePaperTicket, activated
        if present.next() { _ = try r.ia5(size: 3) } // currency
        if present.next() { _ = try r.constrained(1, 3) } // currencyFract
        if present.next() { _ = try r.ia5() } // issuerPNR
        if present.next() { try extensionData(&r) }
        if present.next() { _ = try r.integer() } // issuedOnTrainNum
        if present.next() { _ = try r.ia5() } // issuedOnTrainIA5
        if present.next() { _ = try r.integer() } // issuedOnLine
        if present.next() { try geoCoordinate(&r) } // pointOfSale
        try r.skipExtensionAdditions(extended)
        return (year, day, minutes, name)
    }

    static func extensionData(_ r: inout UPERReader) throws {
        _ = try r.ia5()
        _ = try r.octets()
    }

    static func geoCoordinate(_ r: inout UPERReader) throws {
        var present = try r.presence(5)
        if present.next() { _ = try r.enumerated(5) } // geoUnit
        if present.next() { _ = try r.enumerated(2) } // coordinateSystem
        if present.next() { _ = try r.enumerated(2) } // hemisphereLongitude
        if present.next() { _ = try r.enumerated(2) } // hemisphereLatitude
        _ = try r.integer(); _ = try r.integer() // longitude, latitude
        if present.next() { _ = try r.enumerated(5) } // accuracy
    }

    // MARK: Travellers

    static func travelerData(_ r: inout UPERReader) throws -> [Content.Traveller] {
        let extended = try r.bit()
        var present = try r.presence(3)
        var travellers: [Content.Traveller] = []
        if present.next() { travellers = try r.sequence(of: traveler) }
        if present.next() { _ = try r.ia5(size: 2) } // preferredLanguage
        if present.next() { _ = try r.utf8() } // groupName
        try r.skipExtensionAdditions(extended)
        return travellers
    }

    static func traveler(_ r: inout UPERReader) throws -> Content.Traveller {
        let extended = try r.bit()
        var present = try r.presence(18)
        let firstName = present.next() ? try r.utf8() : nil
        if present.next() { _ = try r.utf8() } // secondName
        let lastName = present.next() ? try r.utf8() : nil
        if present.next() { _ = try r.ia5() } // idCard
        if present.next() { _ = try r.ia5() } // passportId
        if present.next() { _ = try r.ia5(sizeFrom: 1, to: 3) } // title
        if present.next() { _ = try r.enumerated(4, extensible: true) } // gender
        if present.next() { _ = try r.ia5() } // customerIdIA5
        if present.next() { _ = try r.integer() } // customerIdNum
        var birth = DateComponents()
        if present.next() { birth.year = try r.constrained(1901, 2155) }
        if present.next() { birth.month = try r.constrained(1, 12) }
        if present.next() { birth.day = try r.constrained(1, 31) }
        let isTicketHolder = try r.bit()
        if present.next() { _ = try r.enumerated(8, extensible: true) } // passengerType
        if present.next() { _ = try r.bit() } // passengerWithReducedMobility
        for _ in 0..<3 where present.next() { _ = try r.constrained(1, 999) } // countries of residence, passport, ID card
        if present.next() { _ = try r.sequence(of: customerStatus) }
        try r.skipExtensionAdditions(extended)
        return Content.Traveller(firstName: firstName, lastName: lastName,
                                 birthDate: birth.year == nil ? nil : birth, isTicketHolder: isTicketHolder)
    }

    static func customerStatus(_ r: inout UPERReader) throws {
        var present = try r.presence(4)
        if present.next() { _ = try r.constrained(1, 32000) }
        if present.next() { _ = try r.ia5() }
        if present.next() { _ = try r.integer() }
        if present.next() { _ = try r.ia5() }
    }

    // MARK: Documents

    static func documentData(_ r: inout UPERReader, issuingYear: Int, issuingDay: Int) throws -> Content.Document? {
        _ = try r.bit() // extensible
        var present = try r.presence(1)
        if present.next() { // token
            var tokenPresent = try r.presence(3)
            if tokenPresent.next() { _ = try r.integer() }
            if tokenPresent.next() { _ = try r.ia5() }
            if tokenPresent.next() { _ = try r.ia5() }
            _ = try r.octets()
        }
        guard let choice = try r.choice(12) else { return nil }
        var validity: Validity
        var document: Content.Document
        switch choice {
        case 2: (document, validity) = try openTicket(&r)
        case 3: (document, validity) = try pass(&r)
        default: return nil
        }
        validity.year = issuingYear
        validity.issuingDay = issuingDay
        document.validFrom = validity.from
        document.validUntil = validity.until
        return document
    }

    struct Validity {
        var fromDay = 0, fromTime: Int?, fromOffset: Int?
        var untilDay = 0, untilTime: Int?, untilOffset: Int?
        var year = 0, issuingDay = 0

        mutating func read(_ r: inout UPERReader, _ present: inout UPERReader.Presence) throws {
            if present.next() { fromDay = try r.constrained(-367, 700) }
            if present.next() { fromTime = try r.constrained(0, 1439) }
            if present.next() { fromOffset = try r.constrained(-60, 60) }
            if present.next() { untilDay = try r.constrained(-1, 500) }
            if present.next() { untilTime = try r.constrained(0, 1439) }
            if present.next() { untilOffset = try r.constrained(-60, 60) }
        }

        var from: Date? {
            UICBarcode.date(year: year, dayOfYear: issuingDay, plusDays: fromDay, minutes: fromTime ?? 0, utcOffset: fromOffset)
        }

        /// Without a time the ticket is valid to the end of the day.
        var until: Date? {
            UICBarcode.date(year: year, dayOfYear: issuingDay, plusDays: fromDay + untilDay,
                            minutes: untilTime ?? 1440, utcOffset: untilOffset ?? fromOffset)
        }
    }

    static func travelClass(_ code: Int?) -> Int? {
        switch code {
        case 1: 1
        case 2: 2
        default: nil
        }
    }

    static func openTicket(_ r: inout UPERReader) throws -> (Content.Document, Validity) {
        _ = try r.bit() // extensible; the additions come after the fields read here
        var present = try r.presence(40)
        if present.next() { _ = try r.integer() } // referenceNum
        if present.next() { _ = try r.ia5() } // referenceIA5
        if present.next() { _ = try r.constrained(1, 32000) } // productOwnerNum
        if present.next() { _ = try r.ia5() } // productOwnerIA5
        if present.next() { _ = try r.constrained(0, 65535) } // productIdNum
        let productName = present.next() ? try r.ia5() : nil
        if present.next() { _ = try r.integer() } // extIssuerId
        if present.next() { _ = try r.integer() } // issuerAutorizationId
        _ = try r.bit() // returnIncluded
        if present.next() { _ = try r.enumerated(5) } // stationCodeTable
        try stations(&r, &present)
        let regionDescription = present.next() ? try r.utf8() : nil
        if present.next() { _ = try r.sequence(of: regionalValidity) }
        if present.next() { try returnRouteDescription(&r) }
        var validity = Validity()
        try validity.read(&r, &present)
        if present.next() { _ = try r.sequence { try $0.constrained(0, 500) } } // activatedDay
        let classCode = present.next() ? try r.enumerated(12, extensible: true) : 2
        if present.next() { _ = try r.ia5(sizeFrom: 1, to: 2) } // serviceLevel
        if present.next() { _ = try r.sequence { try $0.constrained(1, 32000) } } // carrierNum
        if present.next() { _ = try r.sequence { try $0.ia5() } } // carrierIA5
        if present.next() { _ = try r.sequence { try $0.constrained(1, 32000) } } // includedServiceBrands
        if present.next() { _ = try r.sequence { try $0.constrained(1, 32000) } } // excludedServiceBrands
        let tariffs = present.next() ? try r.sequence(of: tariff) : []
        let name = tariffs.compactMap(\.self).first ?? productName ?? regionDescription
        return (Content.Document(name: name, travelClass: travelClass(classCode)), validity)
    }

    static func pass(_ r: inout UPERReader) throws -> (Content.Document, Validity) {
        _ = try r.bit() // extensible
        var present = try r.presence(34)
        if present.next() { _ = try r.integer() } // referenceNum
        if present.next() { _ = try r.ia5() } // referenceIA5
        if present.next() { _ = try r.constrained(1, 32000) } // productOwnerNum
        if present.next() { _ = try r.ia5() } // productOwnerIA5
        if present.next() { _ = try r.constrained(0, 65535) } // productIdNum
        let productName = present.next() ? try r.ia5() : nil
        if present.next() { _ = try r.constrained(1, 250) } // passType
        let description = present.next() ? try r.utf8() : nil
        let classCode = present.next() ? try r.enumerated(12, extensible: true) : 2
        var validity = Validity()
        try validity.read(&r, &present)
        return (Content.Document(name: description ?? productName, travelClass: travelClass(classCode)), validity)
    }

    /// from/to station number, IA5 code and UTF-8 name, in the schema's order.
    static func stations(_ r: inout UPERReader, _ present: inout UPERReader.Presence) throws {
        if present.next() { _ = try r.constrained(1, 9_999_999) }
        if present.next() { _ = try r.ia5() }
        if present.next() { _ = try r.constrained(1, 9_999_999) }
        if present.next() { _ = try r.ia5() }
        if present.next() { _ = try r.utf8() }
        if present.next() { _ = try r.utf8() }
    }

    static func returnRouteDescription(_ r: inout UPERReader) throws {
        let extended = try r.bit()
        var present = try r.presence(8)
        try stations(&r, &present)
        if present.next() { _ = try r.utf8() } // validReturnRegionDesc
        if present.next() { _ = try r.sequence(of: regionalValidity) }
        try r.skipExtensionAdditions(extended)
    }

    static func regionalValidity(_ r: inout UPERReader) throws {
        switch try r.choice(5) {
        case 0: try trainLink(&r)
        case 1: try viaStation(&r)
        case 2: try zone(&r)
        case 3: try line(&r)
        case 4:
            try geoCoordinate(&r)
            _ = try r.sequence { _ = try $0.integer(); _ = try $0.integer() }
        default: break
        }
    }

    static func trainLink(_ r: inout UPERReader) throws {
        var present = try r.presence(9)
        if present.next() { _ = try r.integer() } // trainNum
        if present.next() { _ = try r.ia5() } // trainIA5
        _ = try r.constrained(-1, 500) // travelDate
        _ = try r.constrained(0, 1439) // departureTime
        if present.next() { _ = try r.constrained(-60, 60) }
        try stations(&r, &present)
    }

    static func viaStation(_ r: inout UPERReader) throws {
        let extended = try r.bit()
        var present = try r.presence(11)
        if present.next() { _ = try r.enumerated(5) } // stationCodeTable
        if present.next() { _ = try r.constrained(1, 9_999_999) }
        if present.next() { _ = try r.ia5() }
        if present.next() { _ = try r.sequence(of: viaStation) } // alternativeRoutes
        if present.next() { _ = try r.sequence(of: viaStation) } // route
        _ = try r.bit() // border
        if present.next() { _ = try r.sequence { try $0.constrained(1, 32000) } }
        if present.next() { _ = try r.sequence { try $0.ia5() } }
        if present.next() { _ = try r.integer() } // seriesId
        if present.next() { _ = try r.integer() } // routeId
        if present.next() { _ = try r.sequence { try $0.constrained(1, 32000) } }
        if present.next() { _ = try r.sequence { try $0.constrained(1, 32000) } }
        try r.skipExtensionAdditions(extended)
    }

    static func zone(_ r: inout UPERReader) throws {
        let extended = try r.bit()
        var present = try r.presence(11)
        if present.next() { _ = try r.constrained(1, 32000) } // carrierNum
        if present.next() { _ = try r.ia5() } // carrierIA5
        if present.next() { _ = try r.enumerated(5) } // stationCodeTable
        if present.next() { _ = try r.constrained(1, 9_999_999) }
        if present.next() { _ = try r.ia5() }
        if present.next() { _ = try r.constrained(1, 9_999_999) }
        if present.next() { _ = try r.ia5() }
        if present.next() { _ = try r.integer() } // city
        if present.next() { _ = try r.sequence { try $0.integer() } } // zoneId
        if present.next() { _ = try r.octets() } // binaryZoneId
        if present.next() { _ = try r.ia5() } // nutsCode
        try r.skipExtensionAdditions(extended)
    }

    static func line(_ r: inout UPERReader) throws {
        let extended = try r.bit()
        var present = try r.presence(9)
        if present.next() { _ = try r.constrained(1, 32000) } // carrierNum
        if present.next() { _ = try r.ia5() } // carrierIA5
        if present.next() { _ = try r.sequence { try $0.integer() } } // lineId
        if present.next() { _ = try r.enumerated(5) } // stationCodeTable
        if present.next() { _ = try r.constrained(1, 9_999_999) }
        if present.next() { _ = try r.ia5() }
        if present.next() { _ = try r.constrained(1, 9_999_999) }
        if present.next() { _ = try r.ia5() }
        if present.next() { _ = try r.integer() } // city
        try r.skipExtensionAdditions(extended)
    }

    /// The tariff's description, e.g. "Deutschland-Ticket".
    static func tariff(_ r: inout UPERReader) throws -> String? {
        let extended = try r.bit()
        var present = try r.presence(11)
        if present.next() { _ = try r.constrained(1, 200) } // numberOfPassengers
        if present.next() { _ = try r.enumerated(8, extensible: true) } // passengerType
        if present.next() { _ = try r.constrained(1, 64) } // ageBelow
        if present.next() { _ = try r.constrained(1, 128) } // ageAbove
        if present.next() { _ = try r.sequence { try $0.constrained(1, 254) } } // travelerid
        _ = try r.bit() // restrictedToCountryOfResidence
        if present.next() { // restrictedToRouteSection
            var section = try r.presence(7)
            if section.next() { _ = try r.enumerated(5) }
            try stations(&r, &section)
        }
        if present.next() { // seriesDataDetails
            var series = try r.presence(3)
            if series.next() { _ = try r.constrained(1, 32000) }
            if series.next() { _ = try r.constrained(1, 99) }
            if series.next() { _ = try r.integer() }
        }
        if present.next() { _ = try r.integer() } // tariffIdNum
        if present.next() { _ = try r.ia5() } // tariffIdIA5
        let description = present.next() ? try r.utf8() : nil
        if present.next() { _ = try r.sequence(of: cardReference) } // reductionCard
        try r.skipExtensionAdditions(extended)
        return description
    }

    static func cardReference(_ r: inout UPERReader) throws {
        let extended = try r.bit()
        var present = try r.presence(10)
        if present.next() { _ = try r.constrained(1, 32000) } // cardIssuerNum
        if present.next() { _ = try r.ia5() } // cardIssuerIA5
        if present.next() { _ = try r.integer() } // cardIdNum
        if present.next() { _ = try r.ia5() } // cardIdIA5
        if present.next() { _ = try r.utf8() } // cardName
        if present.next() { _ = try r.integer() } // cardType
        if present.next() { _ = try r.integer() } // leadingCardIdNum
        if present.next() { _ = try r.ia5() } // leadingCardIdIA5
        if present.next() { _ = try r.integer() } // trailingCardIdNum
        if present.next() { _ = try r.ia5() } // trailingCardIdIA5
        try r.skipExtensionAdditions(extended)
    }
}

// MARK: - Unaligned PER

/// Reads ASN.1 unaligned PER (X.691) bit by bit – only the encodings the FCB uses.
struct UPERReader {
    private let bytes: [UInt8]
    private var position = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    /// The presence bits of a sequence's OPTIONAL and DEFAULT fields, taken in order.
    struct Presence {
        fileprivate var bits: [Bool]
        fileprivate var index = 0

        mutating func next() -> Bool {
            defer { index += 1 }
            return index < bits.count && bits[index]
        }
    }

    mutating func bit() throws -> Bool {
        guard position < bytes.count * 8 else { throw UICBarcode.DecodingError.malformed }
        defer { position += 1 }
        return bytes[position / 8] & (0x80 >> (position % 8)) != 0
    }

    mutating func bits(_ count: Int) throws -> Int {
        var value = 0
        for _ in 0..<count { value = value << 1 | (try bit() ? 1 : 0) }
        return value
    }

    mutating func presence(_ count: Int) throws -> Presence {
        var bits: [Bool] = []
        for _ in 0..<count { bits.append(try bit()) }
        return Presence(bits: bits)
    }

    /// INTEGER (lower..upper): the offset from `lower` in as few bits as the range needs.
    mutating func constrained(_ lower: Int, _ upper: Int) throws -> Int {
        let range = upper - lower
        return lower + (try bits(range == 0 ? 0 : Int.bitWidth - range.leadingZeroBitCount))
    }

    /// Unconstrained length determinant; fragmented lengths (16K and more) aren't supported.
    mutating func length() throws -> Int {
        if try !bit() { return try bits(7) }
        guard try !bit() else { throw UICBarcode.DecodingError.malformed }
        return try bits(14)
    }

    /// Unconstrained INTEGER: length in bytes, then two's complement.
    mutating func integer() throws -> Int {
        let count = try length()
        guard (1...8).contains(count) else { throw UICBarcode.DecodingError.malformed }
        var value = try bits(8)
        if value >= 0x80 { value -= 0x100 }
        for _ in 1..<count { value = value << 8 | (try bits(8)) }
        return value
    }

    /// The index of an ENUMERATED; extension values come back as -1.
    mutating func enumerated(_ rootCount: Int, extensible: Bool = false) throws -> Int {
        if extensible, try bit() {
            _ = try normallySmallNumber()
            return -1
        }
        return try constrained(0, rootCount - 1)
    }

    /// The alternative of a CHOICE; nil (and skipped) for one from an extension.
    mutating func choice(_ rootCount: Int, extensible: Bool = true) throws -> Int? {
        if extensible, try bit() {
            _ = try normallySmallNumber()
            try skipOpenType()
            return nil
        }
        return try constrained(0, rootCount - 1)
    }

    mutating func octets() throws -> [UInt8] {
        let count = try length()
        return try (0..<count).map { _ in UInt8(try bits(8)) }
    }

    mutating func utf8() throws -> String {
        String(decoding: try octets(), as: UTF8.self)
    }

    /// IA5String: 7 bits per character, the length first unless it's fixed.
    mutating func ia5(size: Int? = nil) throws -> String {
        let count = try size ?? length()
        return String(decoding: try (0..<count).map { _ in UInt8(try bits(7)) }, as: UTF8.self)
    }

    mutating func ia5(sizeFrom lower: Int, to upper: Int) throws -> String {
        try ia5(size: constrained(lower, upper))
    }

    mutating func sequence<T>(of item: (inout UPERReader) throws -> T) throws -> [T] {
        let count = try length()
        var items: [T] = []
        for _ in 0..<count { items.append(try item(&self)) }
        return items
    }

    /// Skips the additions of an extended sequence: their count, a presence bitmap, then each as an
    /// open type.
    mutating func skipExtensionAdditions(_ extended: Bool) throws {
        guard extended else { return }
        let count = try (bit() ? length() : bits(6)) + 1
        let present = try presence(count)
        for flag in present.bits where flag { try skipOpenType() }
    }

    private mutating func normallySmallNumber() throws -> Int {
        try bit() ? bits(8 * length()) : bits(6)
    }

    private mutating func skipOpenType() throws {
        let count = try length()
        guard position + count * 8 <= bytes.count * 8 else { throw UICBarcode.DecodingError.malformed }
        position += count * 8
    }
}
