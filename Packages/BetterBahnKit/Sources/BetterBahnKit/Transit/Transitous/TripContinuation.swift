import Foundation

/// A train DB's feed ends at the border and another trip carries on. The ICE 171 Hamburg-Altona → Praha
/// is two trips in Transitous: DB's "ICE 171" ends at Děčín, and the Czech "RJ 171" leaves Děčín four
/// minutes later for Praha. Journeys fold the two into one leg (`mergeThroughTrainLegs`); this does the
/// same for the train's own trip, so its page shows the whole run, named as the Railjet it is.
extension TransitousProvider {
    /// How long after the first trip arrives the continuation may leave (the stop at the border).
    static let continuationDwell: TimeInterval = 10 * 60

    /// Whether `trip` may stop short at a border: a long-distance trip from DB's feed (DELFI) whose last
    /// stop is one of another country's. DELFI numbers its German stops "de-DELFI_de:…", foreign ones
    /// without the "de:".
    static func mayEndAtBorder(_ trip: Trip) -> Bool {
        guard trip.id.contains("_de-DELFI_"), let line = trip.line, line.number != nil,
              [.highSpeed, .longDistance].contains(line.product),
              let last = trip.stopovers.last, last.arrival != nil, trip.stopovers.count >= 2 else { return false }
        return last.station.id.hasPrefix("de-DELFI_") && !last.station.id.hasPrefix("de-DELFI_de:")
    }

    /// `trip` with the trip that carries on from where it ends (see above); unchanged if it doesn't end at
    /// a border, none carries on or it can't be loaded.
    public func joiningContinuation(of trip: Trip) async -> Trip {
        guard Self.mayEndAtBorder(trip), let next = await continuation(of: trip),
              let joined = Self.joining(trip, with: next) else { return trip }
        return joined
    }

    /// The trip that goes on from `trip`'s last stop under the same number. Which one is remembered for
    /// the day; its times are loaded fresh, they are live.
    private func continuation(of trip: Trip) async -> Trip? {
        guard let id = try? await continuationCache.value(for: trip.id, maxAge: 12 * 3600, fetch: { [self] in
            try await continuationID(of: trip) ?? ""
        }), !id.isEmpty else { return nil }
        return try? await self.trip(id: id)
    }

    private func continuationID(of trip: Trip) async throws -> String? {
        guard let last = trip.stopovers.last, let arrival = last.arrival?.planned, let number = trip.line?.number else { return nil }
        let stopTimes = try await fetchStopTimes(stopId: last.station.id, date: arrival.addingTimeInterval(-60),
                                                 duration: Int(Self.continuationDwell / 60) + 1, kind: .departures,
                                                 modes: ["HIGHSPEED_RAIL", "LONG_DISTANCE", "NIGHT_RAIL"], count: 20)
        return Self.continuationCandidate(of: trip.id, number: number, product: trip.line?.product, arrivingAt: arrival, in: stopTimes)?.tripId
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
    /// for DB's "ICE 171"), the first's staying as `alternateName`. Nil when `next` doesn't start where
    /// `first` ends.
    static func joining(_ first: Trip, with next: Trip) -> Trip? {
        guard var border = first.stopovers.last, let start = next.stopovers.first, border.station.isSamePlace(as: start.station),
              next.stopovers.count >= 2 else { return nil }
        border.departure = start.departure
        border.departurePlatform = start.departurePlatform
        border.departureCancelled = start.departureCancelled
        if border.access == .exitOnly { border.access = start.access }
        var joined = first
        joined.stopovers = Array(first.stopovers.dropLast()) + [border] + next.stopovers.dropFirst()
        joined.direction = next.direction ?? next.destination?.displayName
        joined.cancelled = first.cancelled || next.cancelled
        joined.remarks = first.remarks + next.remarks.filter { !first.remarks.contains($0) }
        joined.line = lineAfterBorder(first.line, next.line)
        switch (first.geometry, next.geometry) {
        case let (a?, b?): joined.geometry = a + b
        case let (a?, nil): joined.geometry = a
        case let (nil, b?): joined.geometry = b
        case (nil, nil): joined.geometry = nil
        }
        return joined
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
