import Foundation

/// DB's "Komfort-Check-in" (#605): travellers with a seat (reserved or not) check in on the train,
/// and the conductor then skips their ticket check.
///
/// bahn.de lists per train of the order whether it takes part (`checkinStatus` on each
/// "verbindungsAbschnitt") and from when; the check-in itself is `POST /web/api/ticket/kci` with the
/// order's session token, run inside bahn.de's page like the ticket download (`DBOrderPage.checkinScript`).
public struct KomfortCheckin: Codable, Sendable, Hashable {
    public struct Seat: Codable, Sendable, Hashable {
        public var coach: String
        public var seat: String

        public init(coach: String, seat: String) {
            self.coach = coach
            self.seat = seat
        }

        /// "Wagen 39, Platz 75"
        public var description: String { String(kit: "Wagen %@, Platz %@", coach, seat) }
    }

    /// One train's check-in state, as bahn.de reports it.
    public struct Status: Codable, Sendable, Hashable {
        /// The train takes part in the Komfort-Check-in.
        public var isAvailable: Bool
        /// The check-in opens (about when the train departs from its first stop).
        public var possibleFrom: Date?
        /// bahn.de's "kontrollstatus", e.g. "EINGECHECKT".
        public var controlState: String?
        public var checkinID: String?
        public var checkedInSeats: [Seat]
        public var reservedSeats: [Seat]
        /// Another seat can be chosen after checking in.
        public var canChangeSeat: Bool
        public var changePossibleFrom: Date?
        /// bahn.de's "stichprobe": the conductor may still look at the ticket.
        public var spotCheck: Bool?

        public init(isAvailable: Bool, possibleFrom: Date? = nil, controlState: String? = nil, checkinID: String? = nil,
                    checkedInSeats: [Seat] = [], reservedSeats: [Seat] = [], canChangeSeat: Bool = false,
                    changePossibleFrom: Date? = nil, spotCheck: Bool? = nil) {
            self.isAvailable = isAvailable
            self.possibleFrom = possibleFrom
            self.controlState = controlState
            self.checkinID = checkinID
            self.checkedInSeats = checkedInSeats
            self.reservedSeats = reservedSeats
            self.canChangeSeat = canChangeSeat
            self.changePossibleFrom = changePossibleFrom
            self.spotCheck = spotCheck
        }

        public var isCheckedIn: Bool { controlState == "EINGECHECKT" || checkinID != nil && !checkedInSeats.isEmpty }
    }

    /// A train of the booked connection that takes part.
    public struct Leg: Codable, Sendable, Hashable, Identifiable {
        /// bahn.de's section index ("legIdx"), counting walks too.
        public var index: Int
        /// e.g. "ICE 1101"
        public var trainName: String
        public var trainNumber: String?
        public var departure: Date
        public var arrival: Date
        public var status: Status

        public var id: Int { index }

        /// The check-in can be started or changed: open and the train hasn't arrived yet.
        public func isOpen(at date: Date) -> Bool {
            guard date < arrival, status.isAvailable || status.isCheckedIn else { return false }
            return date >= (status.possibleFrom ?? departure.addingTimeInterval(-15 * 60))
        }

        /// Checked in and a seat change may be made now.
        public func canChangeSeat(at date: Date) -> Bool {
            status.isCheckedIn && status.canChangeSeat && date >= (status.changePossibleFrom ?? .distantPast)
        }
    }

    /// bahn.de's "tripUUID" of the booked connection.
    public var tripUUID: String
    public var legs: [Leg]

    public init(tripUUID: String, legs: [Leg]) {
        self.tripUUID = tripUUID
        self.legs = legs
    }

    /// The trains whose check-in can be done (or changed) now.
    public func openLegs(at date: Date) -> [Leg] { legs.filter { $0.isOpen(at: date) } }

    /// The check-in for the train a journey's `leg` rides (booking and feed names differ, so the
    /// train number decides).
    public func leg(for journeyLeg: BetterBahnKit.Leg) -> Leg? {
        legs.first { DBShareImporter.matches($0.trainName, journeyLeg.line) }
    }

    // MARK: - Request

    /// The body of `POST /web/api/ticket/kci`.
    public struct Request: Encodable, Sendable, Equatable {
        struct Place: Encodable, Sendable, Equatable {
            var platznummer: String
            var wagennummer: String
        }

        var tripUUID: String
        var leistungsbuendelId: String
        var plaetze: [Place]
        var legIdx: Int
        var mitSitzplatzwechsel: Bool
        /// Only for tickets booked with a BahnCard; left out otherwise.
        var bahncardNumber: String?

        public func json() throws -> String {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return String(decoding: try encoder.encode(self), as: UTF8.self)
        }
    }

    /// The check-in for `seats` on `leg`. `mitSitzplatzwechsel` is set when the traveller is already
    /// checked in (changing seats) or sits somewhere else than reserved. bahn.de's status doesn't
    /// always list the reservation, so the one printed on the ticket (`ticketReservation`) counts too.
    public func request(for leg: Leg, bundleID: String, seats: [Seat], bahnCardNumber: String?,
                        ticketReservation: Seat? = nil) -> Request {
        let reserved = Set(leg.status.reservedSeats + [ticketReservation].compactMap(\.self))
        let changing = leg.status.isCheckedIn || !reserved.isEmpty && !Set(seats).isSubset(of: reserved)
        let card = bahnCardNumber?.filter(\.isNumber)
        return Request(
            tripUUID: tripUUID,
            leistungsbuendelId: bundleID,
            plaetze: seats.map { .init(platznummer: $0.seat, wagennummer: $0.coach) },
            legIdx: leg.index,
            mitSitzplatzwechsel: changing,
            bahncardNumber: card?.isEmpty == false ? card : nil)
    }

    /// A BahnCard number has 16 digits (spaces allowed).
    public static func isValidBahnCardNumber(_ number: String) -> Bool {
        let digits = number.filter { !$0.isWhitespace }
        return digits.count == 16 && digits.allSatisfy(\.isASCII) && digits.allSatisfy(\.isNumber)
    }

    // MARK: - Response

    public enum ReadError: Error, Sendable, Equatable, LocalizedError {
        case unreadable

        public var errorDescription: String? { String(kit: "Die Antwort von bahn.de konnte nicht gelesen werden.") }
    }

    /// Reads the status bahn.de answers the check-in with (the same shape as an order's `checkinStatus`).
    public static func status(from data: Data) throws -> Status {
        guard let raw = try? JSONDecoder().decode(RawStatus.self, from: data) else { throw ReadError.unreadable }
        return raw.status
    }

    struct RawStatus: Decodable {
        struct Place: Decodable {
            var wagennummer: String?
            var platznummer: String?
        }

        var kciFaehig: Bool?
        var kciMoeglichAb: String?
        var kontrollstatus: String?
        var checkinId: String?
        var eingechecktePlaetze: [Place]?
        var reserviertePlaetze: [Place]?
        var umcheckenMoeglich: Bool?
        var umcheckenMoeglichAb: String?
        var stichprobe: Bool?

        var status: Status {
            func seats(_ places: [Place]?) -> [Seat] {
                (places ?? []).compactMap { place in
                    guard let coach = place.wagennummer, let seat = place.platznummer else { return nil }
                    return Seat(coach: coach, seat: seat)
                }
            }
            return Status(
                isAvailable: kciFaehig ?? false,
                possibleFrom: kciMoeglichAb.flatMap(JSONDecoding.parseISODate),
                controlState: kontrollstatus,
                checkinID: checkinId,
                checkedInSeats: seats(eingechecktePlaetze),
                reservedSeats: seats(reserviertePlaetze),
                canChangeSeat: umcheckenMoeglich ?? false,
                changePossibleFrom: umcheckenMoeglichAb.flatMap(JSONDecoding.parseISODate),
                spotCheck: stichprobe)
        }
    }
}

extension DBTicket {
    /// Booked with a BahnCard: the Komfort-Check-in then asks for its number.
    public var needsBahnCardForCheckin: Bool {
        travellers.contains { traveller in traveller.reductions.contains { $0.hasPrefix("BahnCard") } }
    }

    /// The Komfort-Check-in can be done (or changed) now on one of the ticket's trains.
    public func komfortCheckinLegs(at date: Date) -> [KomfortCheckin.Leg] {
        guard !isPartnerDocument else { return [] }
        return komfortCheckin?.openLegs(at: date) ?? []
    }

    /// The first seat reserved on `leg`'s train, as printed on the ticket ("Wagen 39, Platz 73–74" → 39/73).
    public func reservedSeat(on leg: KomfortCheckin.Leg) -> KomfortCheckin.Seat? {
        let line = Line(name: leg.trainName, number: leg.trainNumber, product: .other, operatorName: nil)
        guard let reserved = seats.first(where: { DBShareImporter.matches($0.train, line) }),
              let coach = reserved.coach.split(separator: ",").first?.trimmingCharacters(in: .whitespaces), !coach.isEmpty,
              let seat = reserved.seats.first?.split(separator: "–").first.map(String.init) else { return nil }
        return KomfortCheckin.Seat(coach: coach, seat: seat)
    }

    /// Takes over the status bahn.de answered a check-in on `legIndex` with.
    public mutating func updateKomfortCheckin(legIndex: Int, status: KomfortCheckin.Status) {
        guard let position = komfortCheckin?.legs.firstIndex(where: { $0.index == legIndex }) else { return }
        komfortCheckin?.legs[position].status = status
    }
}
