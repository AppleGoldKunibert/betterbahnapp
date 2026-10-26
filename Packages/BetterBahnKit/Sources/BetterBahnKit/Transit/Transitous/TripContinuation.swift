import Foundation

/// A train DB's feed ends at the border and another trip carries on. The ICE 171 Hamburg-Altona → Praha
/// is two trips in Transitous: DB's "ICE 171" ends at Děčín, and the Czech "RJ 171" leaves Děčín four
/// minutes later for Praha. Journeys fold the two into one leg (`mergeThroughTrainLegs`); this does the
/// same for the train's own trip, so its page shows the whole run, named as the Railjet it is.
extension TransitousProvider {
    /// How long after the first trip arrives the continuation may leave (the stop at the border).
    static let continuationDwell: TimeInterval = 10 * 60

    /// Whether `trip` may stop short at a border: a long-distance trip from DB's feed (DELFI) whose last
    /// stop is one of another country's.
    static func mayEndAtBorder(_ trip: Trip) -> Bool {
        guard let last = trip.stopovers.last, last.arrival != nil, trip.stopovers.count >= 2 else { return false }
        return mayEndAtBorder(tripId: trip.id, line: trip.line, lastStopId: last.station.id)
    }

    /// `mayEndAtBorder(_:)` for a trip known by its ID, line and last stop (a leg's or board row's `tripTo`).
    /// DELFI numbers its German stops "de-DELFI_de:…", foreign ones without the "de:".
    static func mayEndAtBorder(tripId: String, line: Line?, lastStopId: String?) -> Bool {
        guard tripId.contains("_de-DELFI_"), let line, line.number != nil, [.highSpeed, .longDistance].contains(line.product),
              let lastStopId else { return false }
        return lastStopId.hasPrefix("de-DELFI_") && !lastStopId.hasPrefix("de-DELFI_de:")
    }

    /// `trip` with the trip that carries on from where it ends (see above); unchanged if it doesn't end at
    /// a border, none carries on or it can't be loaded.
    public func joiningContinuation(of trip: Trip) async -> Trip {
        guard Self.mayEndAtBorder(trip), let next = await continuation(of: trip),
              let joined = Self.joining(trip, with: next) else { return trip }
        return joined
    }

    /// Where a train whose DB trip ends at the border really goes: the destination of the trip carrying on
    /// ("Warszawa Wschodnia" for the EC 47 that DB's feed ends at Rzepin). Nil when it doesn't end at a
    /// border or nothing carries on. Takes one request per train and day.
    func directionBeyondBorder(of trip: Trip) async -> String? {
        guard Self.mayEndAtBorder(trip), let last = trip.stopovers.last, let arrival = last.arrival?.planned,
              let number = trip.line?.number else { return nil }
        return try? await borderContinuation(of: trip.id, number: number, product: trip.line?.product,
                                             endingAt: last.station.id, arrival: arrival).direction
    }

    /// `directionBeyondBorder(of:)` for the legs of a search, which only know their trip's last stop (`tripTo`),
    /// by trip ID. All within `borderDirectionDeadline`, so a search isn't held up; past it none, and the
    /// lookups still finish for the next search.
    func directionsBeyondBorder(of legs: [MLeg]) async -> [String: String] {
        var ends: [String: (line: Line, number: String, stopId: String, arrival: Date)] = [:]
        for leg in legs where !leg.isWalking {
            let line = leg.lineInfo.toLine()
            guard let id = leg.tripId, let end = leg.tripTo, Self.mayEndAtBorder(tripId: id, line: line, lastStopId: end.stopId),
                  let number = line.number, let stopId = end.stopId, let arrival = end.scheduledArrival else { continue }
            ends[id] = (line, number, stopId, arrival)
        }
        guard !ends.isEmpty else { return [:] }
        let trips = ends
        return (try? await CombinedProvider.withDeadline(Self.borderDirectionDeadline) { [self] in
            await withTaskGroup(of: (String, String?).self) { group in
                for (id, end) in trips {
                    group.addTask {
                        let continuation = try? await self.borderContinuation(of: id, number: end.number, product: end.line.product,
                                                                              endingAt: end.stopId, arrival: end.arrival)
                        return (id, continuation?.direction)
                    }
                }
                var directions: [String: String] = [:]
                for await (id, direction) in group { directions[id] = direction }
                return directions
            }
        }) ?? [:]
    }

    static let borderDirectionDeadline: Duration = .seconds(2)

    /// The trip that goes on from `trip`'s last stop under the same number. Which one is remembered for
    /// the day; its times are loaded fresh, they are live.
    private func continuation(of trip: Trip) async -> Trip? {
        guard let last = trip.stopovers.last, let arrival = last.arrival?.planned, let number = trip.line?.number,
              let id = try? await borderContinuation(of: trip.id, number: number, product: trip.line?.product,
                                                     endingAt: last.station.id, arrival: arrival).tripId else { return nil }
        return try? await self.trip(id: id)
    }

    /// The trip carrying on from where trip `tripId` ends, remembered for the day.
    private func borderContinuation(of tripId: String, number: String, product: Product?, endingAt stopId: String,
                                    arrival: Date) async throws -> BorderContinuation {
        try await continuationCache.value(for: tripId, maxAge: 12 * 3600) { [self] in
            let stopTimes = try await fetchStopTimes(stopId: stopId, date: arrival.addingTimeInterval(-60),
                                                     duration: Int(Self.continuationDwell / 60) + 1, kind: .departures,
                                                     modes: ["HIGHSPEED_RAIL", "LONG_DISTANCE", "NIGHT_RAIL"], count: 20)
            guard let row = Self.continuationCandidate(of: tripId, number: number, product: product, arrivingAt: arrival, in: stopTimes)
            else { return BorderContinuation() }
            return BorderContinuation(tripId: row.tripId,
                                      direction: row.headsign.map { MPlace.displayName(ofHeadsign: $0, namingOneOf: [row.tripTo]) })
        }
    }

    /// The row of train `number` leaving within `continuationDwell` of `arrival`, the earliest one. The number
    /// may be only the trip's: DELFI's EC 55 Berlin → Kraków carries on from Rzepin as "96", trip "000055".
    /// A trip starting there wins over one that only passes (PKP's "IC 55 Odra" from Frankfurt (Oder) at the
    /// same time), as only that one can be joined.
    static func continuationCandidate(of tripId: String, number: String, product: Product?, arrivingAt arrival: Date,
                                      in stopTimes: [MStopTime]) -> MStopTime? {
        stopTimes.filter { stopTime in
            guard stopTime.tripId != tripId, stopTime.cancelled != true, stopTime.tripCancelled != true,
                  let departure = stopTime.place.scheduledDeparture else { return false }
            let line = stopTime.lineInfo.toLine()
            let sameKind = product.map { isSameKind($0, line.product) } ?? true
            return (line.number == number || line.tripNumber == number) && sameKind
                && departure >= arrival.addingTimeInterval(-60) && departure <= arrival.addingTimeInterval(continuationDwell)
        }.min { a, b in
            let (departureA, departureB) = (a.place.scheduledDeparture ?? .distantFuture, b.place.scheduledDeparture ?? .distantFuture)
            guard departureA == departureB else { return departureA < departureB }
            return a.place.scheduledArrival == nil && b.place.scheduledArrival != nil
        }
    }

    /// `first` and `next` as one run: the stop where `first` ends arrives with `first` and leaves with
    /// `next`. The train goes by the continuation's name when that names it otherwise (the Czech "RJ 171"
    /// for DB's "ICE 171"), the first's staying as `alternateName`. `next` may start before that stop (PKP's
    /// "EIC 47" from Frankfurt (Oder), where DB's EC 47 ends at Rzepin): it is joined from there. Nil when
    /// `next` doesn't call where `first` ends or ends there.
    static func joining(_ first: Trip, with next: Trip) -> Trip? {
        guard var border = first.stopovers.last,
              let startIndex = next.stopovers.firstIndex(where: { $0.station.isSamePlace(as: border.station) }),
              startIndex < next.stopovers.count - 1 else { return nil }
        let start = next.stopovers[startIndex]
        border.departure = start.departure
        border.departurePlatform = start.departurePlatform
        border.departureCancelled = start.departureCancelled
        if border.access == .exitOnly { border.access = start.access }
        var joined = first
        joined.stopovers = Array(first.stopovers.dropLast()) + [border] + next.stopovers.dropFirst(startIndex + 1)
        joined.direction = next.direction ?? next.destination?.displayName
        joined.cancelled = first.cancelled || next.cancelled
        joined.remarks = first.remarks + next.remarks.filter { !first.remarks.contains($0) }
        joined.line = lineAfterBorder(first.line, next.line)
        let onward = startIndex == 0 ? next.geometry : next.geometry.map { geometry(of: $0, from: border.station) }
        switch (first.geometry, onward) {
        case let (a?, b?): joined.geometry = a + b
        case let (a?, nil): joined.geometry = a
        case let (nil, b?): joined.geometry = b
        case (nil, nil): joined.geometry = nil
        }
        return joined
    }

    /// `geometry` from its point nearest to `station`; whole when the station has no coordinate.
    static func geometry(of geometry: [Coordinate], from station: Station) -> [Coordinate] {
        guard let coordinate = station.coordinate,
              let nearest = geometry.indices.min(by: { geometry[$0].distance(to: coordinate) < geometry[$1].distance(to: coordinate) })
        else { return geometry }
        return Array(geometry[nearest...])
    }

    /// The continuation's line when it is a long-distance train of another name, else `first`'s.
    static func lineAfterBorder(_ first: Line?, _ second: Line?) -> Line? {
        guard let first, let second, Line.normalize(first.name) != Line.normalize(second.name),
              let category = second.name.split(separator: " ").first.map({ $0.uppercased() }),
              BahnDeClient.longDistanceCategories.contains(category) else { return first ?? second }
        var line = second
        line.alternateName = line.alternateName ?? first.name
        return line
    }
}

/// The trip carrying on at a border (see `TransitousProvider.borderContinuation`); empty when none does.
struct BorderContinuation: Sendable {
    var tripId: String?
    var direction: String?
}
