import Foundation

/// Which coaches to board so you get off at the right spot (#383): at a tight transfer to a train at
/// the same platform, opposite the connecting train (its reserved coach, else its part going your way
/// in your class); else next to the stairs, a lift or, at a terminus, the exit. Positions come from
/// bahn.de's Wagenreihung at that stop; the stairs from `StationPlatforms`, placed on bahn.de's
/// platform by the sector signs or, without them, by the way the train runs.
public struct CoachAdvice: Sendable, Hashable {
    public enum Target: Sendable, Hashable {
        /// The connecting train at the same platform; `coach` is the reserved one in it.
        case connection(coach: String?)
        /// The nearest way off the platform.
        case access(StationPlatforms.Access.Kind)
    }

    /// Coach numbers to board, by place: one place, or two when there are stairs at both (Köln Hbf's
    /// two underpasses); from the front of the train.
    public var groups: [[String]]
    public var target: Target
    /// Where you get off, as shown: "Hannover Hbf".
    public var station: String
    /// Your reserved seat is in another coach: walk to these before the train arrives.
    public var walkBeforeArrival: Bool
    /// Your seat's coach (`coaches`) already stops at the spot.
    public var alreadyThere: Bool

    public init(groups: [[String]], target: Target, station: String, walkBeforeArrival: Bool = false, alreadyThere: Bool = false) {
        self.groups = groups
        self.target = target
        self.station = station
        self.walkBeforeArrival = walkBeforeArrival
        self.alreadyThere = alreadyThere
    }

    public init(coaches: [String], target: Target, station: String, walkBeforeArrival: Bool = false, alreadyThere: Bool = false) {
        self.init(groups: [coaches], target: target, station: station, walkBeforeArrival: walkBeforeArrival, alreadyThere: alreadyThere)
    }

    /// From what `nearest` picked; `seat` tells whether it was from a known seat.
    init(_ pick: Pick, target: Target, station: String, seat: Bool) {
        self.init(groups: pick.places.map { $0.compactMap(\.number) }, target: target, station: station,
                  walkBeforeArrival: seat && !pick.alreadyThere, alreadyThere: pick.alreadyThere)
    }

    /// Every coach to board, from the front of the train.
    public var coaches: [String] { groups.flatMap(\.self) }

    /// "Wagen 21", "Wagen 31 oder 32", at two places "Wagen 22–23 oder 31–32"
    public var coachList: String {
        guard groups.count > 1 else {
            let parts = CoachSequence.numberList(coaches).components(separatedBy: ", ")
            guard let last = parts.last, parts.count > 1 else { return "Wagen \(parts.joined())" }
            return "Wagen \(parts.dropLast().joined(separator: ", ")) oder \(last)"
        }
        let places = groups.compactMap { group in group.first.map { first in group.count > 1 ? "\(first)–\(group.last!)" : first } }
        return "Wagen \(places.dropLast().joined(separator: ", ")) oder \(places.last ?? "")"
    }

    /// "In Wagen 30 oder 31 einsteigen, um in Hannover Hbf direkt an deinem Anschluss auszusteigen."; on
    /// the train "In Wagen … wechseln, um …", with a seat elsewhere "Vor der Ankunft in Wagen … wechseln, um …",
    /// with one in the right coach "Du sitzt schon im richtigen Wagen, um …".
    /// - Parameters:
    ///   - boarded: already on the train, so the advice is to walk to those coaches.
    ///   - namingStation: false next to the transfer, which says where already.
    public func text(boarded: Bool = false, namingStation: Bool = true) -> String {
        let place = namingStation ? " in \(station)" : ""
        if alreadyThere { return "Du sitzt schon im richtigen Wagen, um\(place) \(spot) auszusteigen." }
        let first = walkBeforeArrival ? "Vor der Ankunft in \(coachList) wechseln"
            : boarded ? "In \(coachList) wechseln" : "In \(coachList) einsteigen"
        return "\(first), um\(place) \(spot) auszusteigen."
    }

    /// Below the Wagenreihung with these coaches marked: "Die markierten Wagen halten in Hannover Hbf
    /// direkt an deinem Anschluss." With a seat, whose coach is framed too, the whole advice.
    public var legend: String {
        walkBeforeArrival || alreadyThere ? text() : "Die markierten Wagen halten in \(station) \(spot)."
    }

    /// "direkt an deinem Anschluss", "direkt an der Treppe"
    private var spot: String {
        switch target {
        case .connection(let coach?): "direkt an Wagen \(coach) deines Anschlusses"
        case .connection(nil): "direkt an deinem Anschluss"
        case .access(.stairs): "direkt an der Treppe"
        case .access(.lift): "direkt am Aufzug"
        case .access(.exit): "direkt am Ausgang"
        }
    }

    /// Where the stops before and after lie, to tell which end of the platform the train heads for.
    public struct Course: Sendable, Hashable {
        public var previous: Coordinate?
        public var next: Coordinate?

        public init(previous: Coordinate?, next: Coordinate?) {
            self.previous = previous
            self.next = next
        }
    }

    /// Only worth saying when the coaches you could board stand this far apart from the spot (metres).
    static let minimumSpread: Double = 60
    /// Worth walking through the train to from a reserved seat when that saves this much on the platform (metres).
    static let worthWalking: Double = 30
    /// Coaches this much farther from the spot than the nearest one still count as near (metres).
    static let nearSlack: Double = 12
    /// At most two coaches (about 50 m) at each place, and at most two places.
    static let maximumCoaches = 2
    static let maximumPlaces = 2
    /// A train stops this far short of the buffer stop at a terminus (metres).
    static let bufferGap: Double = 8
    /// Coach length when bahn.de gave no positions (metres), as in the Wagenreihung.
    static let fallbackCoachLength: Double = 26.4
}

// MARK: - Transfer

extension CoachAdvice {
    /// Advice for the train arriving at a transfer: `arriving` is its Wagenreihung at the transfer
    /// station, `departing` the connecting train's. At the same platform the coaches opposite the
    /// connecting train's reserved coach (`reservation`: "12" in "ICE 940") or else its part going your
    /// way in your `travelClass`; at another platform those next to the stairs. With your own `seat` on
    /// the arriving train, the coaches to walk to before arriving when that saves a good way, else that it
    /// is right already. `aboard` without a known seat counts from the middle of your class. Nil when any
    /// coach would do or positions are missing.
    public static func transfer(arriving: CoachSequence, departing: CoachSequence, platforms: StationPlatforms?,
                                station: String, reservation: Reservation? = nil, travelClass: Int? = nil,
                                course: Course? = nil, seat: Reservation? = nil, aboard: Bool = false) -> CoachAdvice? {
        guard let arrivalTrack = arriving.platform, let departureTrack = departing.platform else { return nil }
        let samePlatform = platforms?.sharePlatform(arrivalTrack, departureTrack)
            ?? StationPlatforms.sameTrack(arrivalTrack, departureTrack)
        guard samePlatform else {
            return platforms.flatMap { exit(sequence: arriving, platforms: $0, station: station, travelClass: travelClass,
                                            course: course, seat: seat, aboard: aboard) }
        }
        guard let mapping = arriving.mapping(from: departing) else { return nil }
        var reservedCoach: String?
        var spots: [ClosedRange<Double>] = []
        if let reservation, let id = departing.position(ofCoach: reservation.coach, train: reservation.train).coachID,
           let span = departing.coaches.first(where: { $0.id == id })?.span {
            reservedCoach = reservation.coach
            spots = [span]
        } else {
            spots = merged(departing.boardable(travelClass: travelClass).compactMap(\.span))
        }
        guard !spots.isEmpty else { return nil }
        let mapped = spots.map { span in
            let a = mapping(span.lowerBound), b = mapping(span.upperBound)
            return min(a, b)...max(a, b)
        }
        guard let pick = nearest(in: arriving, travelClass: travelClass, to: mapped, seat: seat, aboard: aboard) else { return nil }
        return CoachAdvice(pick, target: .connection(coach: reservedCoach), station: station, seat: seat != nil)
    }

    /// Advice for a train that ends at a transfer station's terminus platform, where bahn.de has no
    /// Wagenreihung: it stands with its front at the buffer stops, so its coaches are laid out from
    /// there in their order at `before`, its last stop before. At the same platform only when both tracks
    /// end at the buffer stops: the connecting train leaves away from them, so its rear is where the arriving
    /// train's front stops. To another platform the way is through the station hall, past the exit.
    public static func transfer(endingAt arrivalTrack: String, before: CoachSequence, departing: CoachSequence,
                                platforms: StationPlatforms, station: String, reservation: Reservation? = nil,
                                travelClass: Int? = nil, seat: Reservation? = nil, aboard: Bool = false) -> CoachAdvice? {
        guard let departureTrack = departing.platform else { return nil }
        guard platforms.sharePlatform(arrivalTrack, departureTrack) else {
            return exit(endingAt: arrivalTrack, before: before, platforms: platforms, station: station, travelClass: travelClass,
                        seat: seat, aboard: aboard)
        }
        guard platforms.track(arrivalTrack)?.hasExit == true, platforms.track(departureTrack)?.hasExit == true,
              let towardsEnd = departing.travelsTowardsPlatformEnd, let length = departing.platformLength
        else { return nil }
        var arriving = before.standing(frontAt: towardsEnd ? 0 : length, facingIncreasing: !towardsEnd)
        arriving.platform = arrivalTrack
        // Laid out along the connecting train's platform already, so both use the same positions.
        var departingHere = departing
        departingHere.platform = arrivalTrack
        return transfer(arriving: arriving, departing: departingHere, platforms: nil, station: station,
                        reservation: reservation, travelClass: travelClass, seat: seat, aboard: aboard)
    }
}

// MARK: - Exit

extension CoachAdvice {
    /// Advice for getting off at `station`: the coaches next to the nearest stairs, lift or exit of the
    /// platform the train stops at (`sequence` is its Wagenreihung there); with your `seat` elsewhere,
    /// those to walk to before arriving (as for `transfer(arriving:…)`, also `aboard`).
    public static func exit(sequence: CoachSequence, platforms: StationPlatforms, station: String,
                            travelClass: Int? = nil, course: Course? = nil, seat: Reservation? = nil,
                            aboard: Bool = false) -> CoachAdvice? {
        guard let name = sequence.platform, let track = platforms.track(name), !track.accesses.isEmpty,
              let mapping = sequence.mapping(from: track, course: course) else { return nil }
        let spots = track.accesses.map { access in mapping(access.position) }
        guard let pick = nearest(in: sequence, travelClass: travelClass, to: spots.map { $0...$0 }, seat: seat, aboard: aboard)
        else { return nil }
        return CoachAdvice(pick, target: .access(kind(nearestTo: pick.places.flatMap(\.self), accesses: track.accesses, at: spots)),
                           station: station, seat: seat != nil)
    }

    /// Advice for getting off where the train ends at a terminus platform (no Wagenreihung there): it
    /// stands with its front at the buffer stops, so its coaches are laid out from the exit in their
    /// order at `before`, its last stop before.
    public static func exit(endingAt trackName: String, before: CoachSequence, platforms: StationPlatforms,
                            station: String, travelClass: Int? = nil, seat: Reservation? = nil, aboard: Bool = false) -> CoachAdvice? {
        guard let track = platforms.track(trackName),
              let exit = track.accesses.first(where: { $0.kind == .exit }) else { return nil }
        let atStart = exit.position < track.length / 2
        let standing = before.standing(frontAt: atStart ? 0 : track.length, facingIncreasing: !atStart)
        let spots = track.accesses.map(\.position)
        guard let pick = nearest(in: standing, travelClass: travelClass, to: spots.map { $0...$0 }, seat: seat, aboard: aboard)
        else { return nil }
        return CoachAdvice(pick, target: .access(kind(nearestTo: pick.places.flatMap(\.self), accesses: track.accesses, at: spots)),
                           station: station, seat: seat != nil)
    }

    /// The kind of the way off the platform nearest to `coaches` (`spots` are the accesses' positions on their platform).
    private static func kind(nearestTo coaches: [CoachSequence.Coach], accesses: [StationPlatforms.Access],
                             at spots: [Double]) -> StationPlatforms.Access.Kind {
        let spans = coaches.compactMap(\.span)
        func distance(_ spot: Double) -> Double { spans.map { gap($0, spot...spot) }.min() ?? 0 }
        return zip(accesses, spots).min { distance($0.1) < distance($1.1) }?.0.kind ?? .stairs
    }
}

// MARK: - A journey

extension CoachAdvice {
    /// Transfers up to this many minutes get advice, as for the "oft verpasst" warning.
    public static let tightTransfer = 15

    /// A seat reserved on a train: "12" in "ICE 940".
    public typealias Reservation = (coach: String, train: String)

    /// Advice for each leg of `journey` still ahead (by leg ID): where to board for each tight transfer
    /// (up to `tightTransfer` minutes) and for getting off at the end. With a seat reservation on a leg
    /// (`reservations`, by leg ID) it boards at the seat: for a transfer, where to walk before arriving or
    /// that it is right already; for getting off at the end, nothing. On the train without one, the place
    /// nearest the middle of your class is named. The connecting train's reservation is where to get to. A
    /// connecting train without a Wagenreihung (an S-Bahn, a bus) still tells by its platform whether to
    /// make for the stairs.
    /// - Parameters:
    ///   - sequence: bahn.de's Wagenreihung for a request, nil when there's none.
    ///   - stops: every stop of a leg's train run, to find the stops around where you get off; nil when
    ///     the run can't be loaded.
    ///   - platformsAt: a station's platforms by EVA number.
    public static func plan(for journey: Journey, reservations: [String: Reservation] = [:], travelClass: Int? = nil,
                            now: Date = .now,
                            sequence: @Sendable (BahnDeClient.FormationRequest) async -> CoachSequence?,
                            stops: @Sendable (Leg) async -> [Stopover]?,
                            platformsAt: (String) -> StationPlatforms? = StationPlatforms.at(eva:)) async -> [String: CoachAdvice] {
        let legs = journey.transitLegs
        var advice: [String: CoachAdvice] = [:]
        for (index, leg) in legs.enumerated() {
            guard !leg.cancelled, leg.arrival.best > now, BahnDeClient.sequenceReference(for: leg.line) != nil else { continue }
            let next = legs.indices.contains(index + 1) ? legs[index + 1] : nil
            let seat = reservations[leg.id]
            let aboard = seat == nil && leg.departure.best <= now
            let station = leg.destination.displayName
            let stationEVA = leg.destination.evaNumber ?? StationNames.evaNumber(for: leg.destination)
            if let next {
                let minutes = Int((next.departure.best.timeIntervalSince(leg.arrival.best) / 60).rounded())
                guard minutes > 0, minutes <= tightTransfer, next.origin.isSamePlace(as: leg.destination),
                      let arrival = await arrival(of: leg, now: now, stops: stops) else { continue }
                var departing: CoachSequence?
                if let request = BahnDeClient.formationRequest(for: next, now: now), request.station.isSamePlace(as: next.origin) {
                    departing = await sequence(request)
                }
                guard let departureTrack = departing?.platform ?? next.departurePlatform?.best else { continue }
                switch arrival {
                case .continuing(let request, let course):
                    guard let arriving = await sequence(request) else { continue }
                    let here = (departing?.eva ?? arriving.eva ?? stationEVA).flatMap(platformsAt)
                    if let departing {
                        advice[leg.id] = transfer(arriving: arriving, departing: departing, platforms: here, station: station,
                                                  reservation: reservations[next.id], travelClass: travelClass, course: course,
                                                  seat: seat, aboard: aboard)
                    } else if let here, let track = arriving.platform, !here.sharePlatform(track, departureTrack) {
                        advice[leg.id] = exit(sequence: arriving, platforms: here, station: station, travelClass: travelClass,
                                              course: course, seat: seat, aboard: aboard)
                    }
                case .ending(let request):
                    guard let here = (departing?.eva ?? stationEVA).flatMap(platformsAt), let track = leg.arrivalPlatform?.best,
                          let before = await sequence(request) else { continue }
                    if let departing {
                        advice[leg.id] = transfer(endingAt: track, before: before, departing: departing, platforms: here,
                                                  station: station, reservation: reservations[next.id], travelClass: travelClass,
                                                  seat: seat, aboard: aboard)
                    } else if !here.sharePlatform(track, departureTrack) {
                        advice[leg.id] = exit(endingAt: track, before: before, platforms: here, station: station,
                                              travelClass: travelClass, seat: seat, aboard: aboard)
                    }
                }
            } else if seat == nil {
                switch await arrival(of: leg, now: now, stops: stops) {
                case .continuing(let request, let course):
                    guard let here = await sequence(request), let platforms = (here.eva ?? stationEVA).flatMap(platformsAt) else { continue }
                    advice[leg.id] = exit(sequence: here, platforms: platforms, station: station, travelClass: travelClass, course: course,
                                          aboard: aboard)
                case .ending(let request):
                    guard let platforms = stationEVA.flatMap(platformsAt), let track = leg.arrivalPlatform?.best,
                          let before = await sequence(request) else { continue }
                    advice[leg.id] = exit(endingAt: track, before: before, platforms: platforms, station: station, travelClass: travelClass,
                                          aboard: aboard)
                case nil:
                    continue
                }
            }
        }
        return advice
    }

    /// How a leg's train gets to where you get off.
    enum Arrival {
        /// It goes on from there: the request for its Wagenreihung there, and where it comes from and goes.
        case continuing(BahnDeClient.FormationRequest, Course)
        /// It ends there: the request for its Wagenreihung at the stop before.
        case ending(BahnDeClient.FormationRequest)
    }

    /// Where `leg`'s train goes after you get off, from its whole run; nil when the run is unknown or
    /// bahn.de wouldn't have the Wagenreihung yet (`BahnDeClient.formationLookahead`).
    static func arrival(of leg: Leg, now: Date, stops: @Sendable (Leg) async -> [Stopover]?) async -> Arrival? {
        guard let ref = BahnDeClient.sequenceReference(for: leg.line), let run = await stops(leg),
              let index = run.lastIndex(where: { stop in
                  stop.station.isSamePlace(as: leg.destination)
                      && abs((stop.arrival ?? stop.departure)?.planned.timeIntervalSince(leg.arrival.planned) ?? 0) < 30 * 60
              }) else { return nil }
        func request(at stop: Stopover) -> BahnDeClient.FormationRequest? {
            guard let departure = stop.departure, !stop.departureCancelled,
                  departure.planned <= now.addingTimeInterval(BahnDeClient.formationLookahead) else { return nil }
            return BahnDeClient.FormationRequest(category: ref.category, number: ref.number, station: stop.station,
                                                 plannedDeparture: departure.planned, coupledNumbers: leg.line?.coupledNumbers ?? [],
                                                 tripId: leg.tripId, tripSource: leg.source)
        }
        let stop = run[index]
        if stop.departure != nil, !stop.departureCancelled {
            guard let here = request(at: stop) else { return nil }
            let previous = index > 0 ? run[index - 1].station.coordinate : nil
            let next = index + 1 < run.count ? run[index + 1].station.coordinate : nil
            return .continuing(here, Course(previous: previous, next: next))
        }
        guard let before = run[..<index].last(where: { $0.departure != nil && !$0.departureCancelled }).flatMap(request(at:))
        else { return nil }
        return .ending(before)
    }
}

// MARK: - Picking the coaches

extension CoachAdvice {
    /// What `nearest` picked: the coaches to go to by place, or your seat's coach when it stands right already.
    struct Pick {
        var places: [[CoachSequence.Coach]]
        var alreadyThere = false
    }

    /// The boardable coaches nearest to any of `spots` (metres along `sequence`'s platform), by place: up
    /// to two next to each other, at up to two places as near (stairs at both ends of the train); nil
    /// when they all stand about as near, so any coach does. With a `seat` on the train, its coach when it
    /// is within `worthWalking` of those, else only the place nearest to it; `aboard` without a seat, the
    /// place nearest the middle coach of your class (you could be sitting anywhere).
    static func nearest(in sequence: CoachSequence, travelClass: Int?, to spots: [ClosedRange<Double>],
                        seat: Reservation? = nil, aboard: Bool = false) -> Pick? {
        let candidates = sequence.boardable(travelClass: travelClass).filter { $0.span != nil }
        guard !candidates.isEmpty, !spots.isEmpty else { return nil }
        let distances = candidates.map { coach in spots.map { gap(coach.span!, $0) }.min()! }
        let best = distances.min()!, worst = distances.max()!
        // Where you sit, to walk from.
        var sitting: ClosedRange<Double>?
        if let seat {
            guard let id = sequence.position(ofCoach: seat.coach, train: seat.train).coachID,
                  let coach = sequence.coaches.first(where: { $0.id == id }), let span = coach.span else { return nil }
            if spots.map({ gap(span, $0) }).min()! - best < worthWalking {
                // Only worth saying when another coach would be wrong.
                return worst - best >= minimumSpread ? Pick(places: [[coach]], alreadyThere: true) : nil
            }
            sitting = span
        } else {
            guard worst - best >= minimumSpread else { return nil }
            if aboard { sitting = middle(of: candidates)?.span }
        }
        // Among coaches about as near, the one whose middle is nearest a spot's middle (opposite the
        // middle of the connecting train's part rather than at its end) first.
        func offCentre(_ coach: CoachSequence.Coach) -> Double {
            spots.map { abs(coach.span!.middle - $0.middle) }.min()!
        }
        let ranked = zip(candidates, distances).filter { $0.1 <= best + nearSlack }
            .sorted { ($0.1, offCentre($0.0), $0.0.id) < ($1.1, offCentre($1.0), $1.0.id) }.map(\.0)
        let rank = Dictionary(uniqueKeysWithValues: ranked.enumerated().map { ($1.id, $0) })
        // Near coaches next to each other are one place; from each its best coach and the better neighbour.
        var runs: [[CoachSequence.Coach]] = []
        for coach in ranked.sorted(by: { $0.id < $1.id }) {
            if let last = runs.last?.last, coach.id == last.id + 1 {
                runs[runs.count - 1].append(coach)
            } else {
                runs.append([coach])
            }
        }
        let places = runs.compactMap { run -> [CoachSequence.Coach]? in
            guard let first = run.min(by: { rank[$0.id]! < rank[$1.id]! }) else { return nil }
            let neighbours = run.filter { abs($0.id - first.id) == 1 }.sorted { rank[$0.id]! < rank[$1.id]! }
            return ([first] + neighbours.prefix(maximumCoaches - 1)).sorted { $0.id < $1.id }
        }
        if let sitting {
            func away(_ place: [CoachSequence.Coach]) -> Double { place.map { abs($0.span!.middle - sitting.middle) }.min()! }
            return places.min { (away($0), $0[0].id) < (away($1), $1[0].id) }.map { Pick(places: [$0]) }
        }
        let chosen = places.sorted { a, b in a.map { rank[$0.id]! }.min()! < b.map { rank[$0.id]! }.min()! }.prefix(maximumPlaces)
        return Pick(places: chosen.sorted { $0[0].id < $1[0].id })
    }

    /// The coach in the middle of `coaches` along the platform, where someone whose seat isn't known is
    /// taken to sit.
    static func middle(of coaches: [CoachSequence.Coach]) -> CoachSequence.Coach? {
        let spans = coaches.compactMap(\.span)
        guard let low = spans.map(\.lowerBound).min(), let high = spans.map(\.upperBound).max() else { return nil }
        let centre = (low + high) / 2
        return coaches.filter { $0.span != nil }.min { (abs($0.span!.middle - centre), $0.id) < (abs($1.span!.middle - centre), $1.id) }
    }

    /// Coaches standing next to each other as one stretch of platform each.
    static func merged(_ spans: [ClosedRange<Double>]) -> [ClosedRange<Double>] {
        spans.sorted { $0.lowerBound < $1.lowerBound }.reduce(into: []) { result, span in
            if let last = result.last, span.lowerBound <= last.upperBound + 5 {
                result[result.count - 1] = last.lowerBound...max(last.upperBound, span.upperBound)
            } else {
                result.append(span)
            }
        }
    }

    /// Metres between two stretches of platform; 0 when they overlap.
    static func gap(_ a: ClosedRange<Double>, _ b: ClosedRange<Double>) -> Double {
        max(0, max(a.lowerBound, b.lowerBound) - min(a.upperBound, b.upperBound))
    }
}

extension ClosedRange<Double> {
    var middle: Double { (lowerBound + upperBound) / 2 }
}

extension CoachSequence.SeatPosition {
    /// The reserved coach's `id`, if the sequence has it.
    var coachID: Int? {
        switch self {
        case .sectors(_, let id), .noSectors(let id): id
        case .coachMissing: nil
        }
    }
}

extension StationPlatforms.Track {
    /// A terminus platform: its exit is at the buffer stops.
    var hasExit: Bool { accesses.contains { $0.kind == .exit } }
}

extension CoachSequence.Coach {
    /// Where the coach stands, from its lower to its higher position; nil without positions.
    var span: ClosedRange<Double>? {
        guard let start, let end else { return nil }
        return min(start, end)...max(start, end)
    }
}

extension CoachSequence {
    /// The coaches `advice` names, for marking them in the Wagenreihung: only in the part running as the
    /// requested train, as coach numbers repeat across coupled trains.
    public func coachIDs(for advice: CoachAdvice) -> Set<Int> {
        Set(coaches.filter { coach in
            coach.number.map(advice.coaches.contains) == true && groups.indices.contains(coach.group) && groups[coach.group].isRequestedTrain
        }.map(\.id))
    }

    /// Coaches you would ride in: open passenger coaches (and bistro halves) of the part running as the
    /// requested train, in `travelClass` when it has any.
    func boardable(travelClass: Int?) -> [Coach] {
        let riding = coaches.filter { coach in
            (coach.kind == .passenger || coach.kind == .halfDiningCar) && !coach.closed && coach.number != nil
                && groups.indices.contains(coach.group) && groups[coach.group].isRequestedTrain
        }
        let inClass = riding.filter { coach in
            switch travelClass {
            case 1: coach.firstClass
            case 2: coach.secondClass
            default: true
            }
        }
        return inClass.isEmpty ? riding : inClass
    }

    /// The same coaches standing at a terminus with the front `bufferGap` short of `front`, from there
    /// towards higher positions (`facingIncreasing` false) or lower ones: the train came in heading the
    /// other way. Lengths from `self`'s positions, else `fallbackCoachLength`.
    func standing(frontAt front: Double, facingIncreasing: Bool) -> CoachSequence {
        var sequence = self
        let direction: Double = facingIncreasing ? -1 : 1
        var offset = CoachAdvice.bufferGap
        sequence.coaches = coaches.map { coach in
            var coach = coach
            let length = coach.span.map { $0.upperBound - $0.lowerBound } ?? CoachAdvice.fallbackCoachLength
            coach.start = front + direction * offset
            coach.end = front + direction * (offset + length)
            coach.sector = nil
            offset += length
            return coach
        }
        sequence.travelsTowardsPlatformEnd = nil
        return sequence
    }

    /// Turns positions on `other`'s platform (another train at the same platform) into positions on
    /// this one's: the same where both stop at the same track, else by the sectors both share.
    func mapping(from other: CoachSequence) -> ((Double) -> Double)? {
        if let a = platform, let b = other.platform, StationPlatforms.sameTrack(a, b) {
            return { $0 }
        }
        let pairs = other.sectors.compactMap { sector -> (Double, Double)? in
            sectors.first { $0.name == sector.name }.map { ((sector.start + sector.end) / 2, ($0.start + $0.end) / 2) }
        }
        return Self.fit(pairs)
    }

    /// Turns positions along OpenStreetMap's platform edge into positions on bahn.de's platform: by the
    /// sector signs both have, else by which end of the platform the train heads for (the next stop
    /// lies that way, the previous one the other), with both platforms' middles at the same place.
    func mapping(from track: StationPlatforms.Track, course: CoachAdvice.Course?) -> ((Double) -> Double)? {
        let pairs = track.sectorSigns.compactMap { sign -> (Double, Double)? in
            sectors.first { $0.name == sign.name }.map { (sign.position, ($0.start + $0.end) / 2) }
        }
        if let fitted = Self.fit(pairs) { return fitted }
        guard let course, let towardsEnd = travelsTowardsPlatformEnd, let length = platformLength ?? sectors.last?.end
        else { return nil }
        // Which end of the edge the train heads for.
        let headsForEnd: Bool
        if let next = course.next {
            let toStart = next.distance(to: track.start), toEnd = next.distance(to: track.end)
            guard abs(toStart - toEnd) > track.length / 4 else { return nil }
            headsForEnd = toEnd < toStart
        } else if let previous = course.previous {
            let fromStart = previous.distance(to: track.start), fromEnd = previous.distance(to: track.end)
            guard abs(fromStart - fromEnd) > track.length / 4 else { return nil }
            headsForEnd = fromEnd > fromStart
        } else {
            return nil
        }
        let sign: Double = headsForEnd == towardsEnd ? 1 : -1
        return { sign * ($0 - track.length / 2) + length / 2 }
    }

    /// `to = ±from + offset` through at least two pairs of the same places: the direction from their
    /// order, the offset their median, and only when they agree within 40 m (the sector signs needn't
    /// hang in the middle of their sectors).
    static func fit(_ pairs: [(from: Double, to: Double)]) -> ((Double) -> Double)? {
        guard pairs.count >= 2 else { return nil }
        let meanFrom = pairs.map(\.from).reduce(0, +) / Double(pairs.count)
        let meanTo = pairs.map(\.to).reduce(0, +) / Double(pairs.count)
        let covariance = pairs.map { ($0.from - meanFrom) * ($0.to - meanTo) }.reduce(0, +)
        guard covariance != 0 else { return nil }
        let sign: Double = covariance > 0 ? 1 : -1
        let offsets = pairs.map { $0.to - sign * $0.from }.sorted()
        let offset = offsets.count % 2 == 1 ? offsets[offsets.count / 2]
            : (offsets[offsets.count / 2 - 1] + offsets[offsets.count / 2]) / 2
        let agreeing = offsets.count { abs($0 - offset) <= 40 }
        guard agreeing * 2 > offsets.count else { return nil }
        return { sign * $0 + offset }
    }
}
