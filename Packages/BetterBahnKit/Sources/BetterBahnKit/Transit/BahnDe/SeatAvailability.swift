import Foundation

/// Which seats of a train can still be reserved on a ride, per coach: bahn.de's seat picker (`gsd/gsd_v3`, the page
/// its booking opens for "Sitzplatz wählen"), asked through our server. A seat that is free here has no
/// reservation for the stretch asked for, in the class asked for; seats of the other class are never free.
public struct SeatAvailability: Sendable, Hashable {
    /// bahn.de's `status` per seat.
    public enum Status: Int, Sendable, Hashable {
        /// Reserved, of the other class, or not to be reserved at all.
        case unavailable = 0
        case free = 1
        /// Free, and the seat bahn.de would pick.
        case suggested = 2

        public var isFree: Bool { self != .unavailable }
    }

    /// Seat number → status, per coach number.
    public var coaches: [String: [String: Status]]
    /// bahn.de answered that nothing is left to reserve on this stretch in this class (409).
    public var bookedOut: Bool

    public init(coaches: [String: [String: Status]], bookedOut: Bool = false) {
        self.coaches = coaches
        self.bookedOut = bookedOut
    }

    public static let bookedOutAnswer = SeatAvailability(coaches: [:], bookedOut: true)

    /// Whether bahn.de listed the coach at all; coaches of a train coupled to it are missing.
    public func knows(coach: String?) -> Bool {
        bookedOut || coach.map { coaches[$0] != nil } ?? false
    }

    /// The seats in `coach` that are still free.
    public func freeSeats(in coach: String?) -> Set<String> {
        guard let coach, let seats = coaches[coach] else { return [] }
        return Set(seats.filter(\.value.isFree).keys)
    }

    public var freeCount: Int {
        coaches.values.reduce(0) { $0 + $1.values.count(where: \.isFree) }
    }
}

extension BahnDeClient {
    /// Everything the seat picker needs: the train, where the ride starts and ends (planned times) and the class.
    public struct SeatRequest: Hashable, Sendable {
        public var category: String
        public var number: String
        public var origin: Station
        public var plannedDeparture: Date
        public var destination: Station
        public var plannedArrival: Date
        public var travelClass: TravelClass

        public init(category: String, number: String, origin: Station, plannedDeparture: Date, destination: Station,
                    plannedArrival: Date, travelClass: TravelClass) {
            self.category = category
            self.number = number
            self.origin = origin
            self.plannedDeparture = plannedDeparture
            self.destination = destination
            self.plannedArrival = plannedArrival
            self.travelClass = travelClass
        }
    }

    /// The free seats on `leg`'s long-distance train from the next stop where it still departs (its origin until it
    /// has left) to the leg's end: on board, a seat is only free if nobody boarding later has reserved it.
    /// nil once there's no such stop, and for anything bahn.de doesn't sell seats on.
    public static func seatRequest(for leg: Leg, travelClass: TravelClass, now: Date = .now) -> SeatRequest? {
        guard !leg.cancelled, !leg.isWalking, let ref = trainReference(for: leg.line) else { return nil }
        let stops = [(station: leg.origin, departure: Optional(leg.departure))]
            + leg.stopovers.filter { !$0.cancelled && !$0.station.isSamePlace(as: leg.destination) }
                .map { (station: $0.station, departure: $0.departure) }
        guard let start = stops.first(where: { $0.departure.map { $0.best >= now } ?? false }),
              let departure = start.departure, departure.planned < leg.arrival.planned else { return nil }
        return SeatRequest(category: ref.category, number: ref.number, origin: start.station, plannedDeparture: departure.planned,
                           destination: leg.destination, plannedArrival: leg.arrival.planned, travelClass: travelClass)
    }

    private static let seatCache = ExpiringCache<SeatAvailability?>()
    /// Seats get reserved all the time; a minute keeps reopening the seat map from asking again.
    public static let seatMaxAge: TimeInterval = 60

    /// Which seats are free on the ride, nil when bahn.de has no seat picker for it (not reservable, unknown
    /// train, already left). Berlin Hbf's other level is tried when bahn.de doesn't know the train at the one asked.
    public func seatAvailability(_ request: SeatRequest) async throws -> SeatAvailability? {
        guard usesSharedCaches else { return try await fetchSeatAvailability(request) }
        return try await Self.seatCache.value(for: Self.seatKey(request), maxAge: Self.seatMaxAge) {
            try await fetchSeatAvailability(request)
        }
    }

    static func seatKey(_ request: SeatRequest) -> String {
        [request.category, request.number, request.origin.id, utcTimestamp(request.plannedDeparture), request.destination.id,
         utcTimestamp(request.plannedArrival), request.travelClass.rawValue].joined(separator: "|")
    }

    private func fetchSeatAvailability(_ request: SeatRequest) async throws -> SeatAvailability? {
        guard let origin = try await evaNumber(for: request.origin),
              let destination = try await evaNumber(for: request.destination) else { return nil }
        var tried = [(origin, destination)]
        let twins = (Self.otherLevel(of: origin) ?? origin, Self.otherLevel(of: destination) ?? destination)
        if twins != (origin, destination) { tried.append(twins) }
        for (from, to) in tried {
            do {
                let page = try await getPage(Self.seatURL(request, originEVA: from, destinationEVA: to))
                if let seats = Self.seatAvailability(fromPage: page) { return seats }
            } catch TransitError.http(let status, _) where status == 409 {
                return .bookedOutAnswer
            } catch let error as TransitError where error.isBahnDeAnswer {
                // 422: bahn.de doesn't know the train like that; maybe at the other level.
                continue
            }
        }
        return nil
    }

    /// bahn.de's seat picker page, its request in `data` as the booking sends it. `correlationID` can be anything.
    static func seatURL(_ request: SeatRequest, originEVA: String, destinationEVA: String,
                        correlationID: String = "\(UUID().uuidString.lowercased())_\(UUID().uuidString.lowercased())") -> URL {
        let data = SeatPickerData(
            displayinformation: .init(zugbezeichnung: "\(request.category) \(request.number)", abfahrtsbahnhof: request.origin.name,
                                      ankunftsbahnhof: request.destination.name),
            buchungskontext: .init(quellSystem: "SIMA", buchungsKontextDaten: .init(
                zugnummer: request.number,
                abfahrtHalt: .init(locationId: originEVA, abfahrtZeit: berlinLocalTime(request.plannedDeparture)),
                ankunftHalt: .init(locationId: destinationEVA, ankunftZeit: berlinLocalTime(request.plannedArrival)),
                inventarsystem: "RIFF",
                platzbedarfe: [.init(platzprofilCode: "StandardEinzelperson", anzahl: 1,
                                     klasse: request.travelClass == .first ? "KLASSE_1" : "KLASSE_2")])),
            correlationID: correlationID, lang: "de", theme: "web")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let json = String(decoding: (try? encoder.encode(data)) ?? Data(), as: UTF8.self)
        // Everything but unreserved characters escaped: a "&" or "+" in a station's name must stay in `data`.
        let value = json.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? ""
        var components = URLComponents(url: baseURL.appending(path: "gsd/gsd_v3"), resolvingAgainstBaseURL: false)!
        components.percentEncodedQuery = "data=\(value)"
        return components.url!
    }

    /// "2026-11-05T05:27:00": the booking's times, local time in Germany without a zone.
    static func berlinLocalTime(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = berlin
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(format: "%04d-%02d-%02dT%02d:%02d:%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    }

    /// The seats from the page's `ssr_data` script; nil when it has none (an error page).
    static func seatAvailability(fromPage page: String) -> SeatAvailability? {
        guard let marker = page.range(of: "id='ssr_data'") ?? page.range(of: "id=\"ssr_data\""),
              let open = page[marker.upperBound...].firstIndex(of: ">"),
              let close = page[open...].range(of: "</script>") else { return nil }
        let json = page[page.index(after: open)..<close.lowerBound]
        guard let data = try? JSONDecoder().decode(SeatPickerPage.self, from: Data(json.utf8)), data.type == "gsd",
              let parts = data.zugfahrt?.zugteile else { return nil }
        var coaches: [String: [String: SeatAvailability.Status]] = [:]
        for coach in parts.flatMap({ $0.wagen ?? [] }) {
            guard let number = coach.nummer else { continue }
            var seats = coaches[number] ?? [:]
            for seat in coach.plaetze ?? [] {
                guard let seatNumber = seat.nummer else { continue }
                seats[seatNumber] = seat.status.flatMap(SeatAvailability.Status.init(rawValue:)) ?? .unavailable
            }
            coaches[number] = seats
        }
        return coaches.isEmpty ? nil : SeatAvailability(coaches: coaches)
    }

    struct SeatPickerData: Encodable {
        struct Display: Encodable { var zugbezeichnung, abfahrtsbahnhof, ankunftsbahnhof: String }
        struct Context: Encodable { var quellSystem: String; var buchungsKontextDaten: Details }
        struct Details: Encodable {
            var zugnummer: String
            var abfahrtHalt: Departure
            var ankunftHalt: Arrival
            var inventarsystem: String
            var platzbedarfe: [Need]
        }
        struct Departure: Encodable { var locationId, abfahrtZeit: String }
        struct Arrival: Encodable { var locationId, ankunftZeit: String }
        struct Need: Encodable { var platzprofilCode: String; var anzahl: Int; var klasse: String }

        var displayinformation: Display
        var buchungskontext: Context
        var correlationID: String
        var lang: String
        var theme: String
    }

    struct SeatPickerPage: Decodable {
        struct Journey: Decodable { var zugteile: [Part]? }
        struct Part: Decodable { var wagen: [Coach]? }
        struct Coach: Decodable { var nummer: String?; var plaetze: [Seat]? }
        struct Seat: Decodable { var nummer: String?; var status: Int? }

        var type: String?
        var zugfahrt: Journey?
    }
}
