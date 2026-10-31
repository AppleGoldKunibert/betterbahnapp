import Foundation

/// A lift out of order at one station (#486), with the tracks whose platform it reaches.
public struct LiftAlert: Sendable, Hashable, Identifiable {
    public var lift: BrokenLift
    /// Tracks whose platform the lift reaches, from DB's description ("zu Gleis 4/5") or, without one there,
    /// the lifts OpenStreetMap draws on the platforms (`StationPlatforms`). Every track along that platform
    /// counts. Empty when it can't be told (a lift to the hall or an underpass).
    public var tracks: [String]

    public init(lift: BrokenLift, tracks: [String]) {
        self.lift = lift
        self.tracks = tracks
    }

    public var id: Int { lift.id }

    /// Whether the lift takes you to (or from) `track`'s platform.
    public func serves(track: String) -> Bool {
        let key = StationPlatforms.trackKeys(track).last
        return tracks.contains { StationPlatforms.trackKeys($0).last == key }
    }

    /// "Aufzug zu Gleis 4/5 wegen Wartung außer Betrieb", "Aufzug außer Betrieb: Empfangsgebäude"
    public var text: String {
        let reason = lift.reasonText.map { "wegen \($0) " } ?? ""
        let description = lift.description
        if let first = description.first, first.isLowercase {
            return "Aufzug \(description) \(reason)außer Betrieb"
        }
        if description.isEmpty {
            return tracks.isEmpty ? "Ein Aufzug ist \(reason)außer Betrieb"
                : "Aufzug zu Gleis \(tracks.joined(separator: "/")) \(reason)außer Betrieb"
        }
        return "Aufzug \(reason)außer Betrieb: \(description)"
    }
}

/// A lift out of order on the way of a journey (#486): where it starts, changes trains or arrives.
public struct JourneyLiftAlert: Sendable, Hashable, Identifiable {
    public enum Place: String, Sendable, Hashable {
        case start, transfer, destination
    }

    public var place: Place
    /// The transit leg leaving the start, or arriving at the transfer or destination.
    public var legID: String
    public var station: String
    public var alert: LiftAlert

    public init(place: Place, legID: String, station: String, alert: LiftAlert) {
        self.place = place
        self.legID = legID
        self.station = station
        self.alert = alert
    }

    /// Notifies once per lift and place of a journey.
    public var id: String { "lift|\(place.rawValue)|\(legID)|\(alert.id)" }

    /// "Aufzug defekt in Fulda"
    public var title: String { "Aufzug defekt in \(station)" }

    /// "Aufzug zu Gleis 4/5 außer Betrieb. Du steigst hier um."
    public var message: String {
        let note = switch place {
        case .start: "Hier fährst du los."
        case .transfer: "Du steigst hier um."
        case .destination: "Hier kommst du an."
        }
        return "\(alert.text). \(note)"
    }
}

/// Which lifts out of order (`FacilityClient`) matter at a station or on a journey (#486). DB's FaSta API
/// knows its stations by their own number, not the EVA number, so lifts go to a station by where they are:
/// next to its platforms when `StationPlatforms` knows them, else close to the station itself.
public enum LiftCheck {
    /// A lift this close to one of the station's platform edges belongs to it.
    static let platformRadius: Double = 60
    /// A lift this close to the station's position belongs to it; less when its platforms are known.
    static let stationRadius: Double = 300
    static let stationRadiusWithPlatforms: Double = 150
    /// A FaSta lift this close to a lift OpenStreetMap draws on a platform is that one.
    static let liftRadius: Double = 30

    /// The lifts out of order at `station`, those reaching a platform first by track.
    public static func alerts(at station: Station, among lifts: [BrokenLift],
                              platformsAt: (String) -> StationPlatforms? = StationPlatforms.at(eva:)) -> [LiftAlert] {
        let eva = station.evaNumber ?? StationNames.evaNumber(for: station)
        let platforms = eva.flatMap(platformsAt).flatMap { $0.tracks.isEmpty ? nil : $0 }
        let alerts = lifts.compactMap { lift -> LiftAlert? in
            guard let point = lift.coordinate else { return nil }
            let nearPlatforms = platforms?.tracks.values.contains { distance(from: point, toEdgeOf: $0) < platformRadius } ?? false
            let radius = platforms == nil ? stationRadius : stationRadiusWithPlatforms
            let nearStation = station.coordinate.map { $0.distance(to: point) < radius } ?? false
            guard nearPlatforms || nearStation else { return nil }
            var tracks = describedTracks(lift.description)
            if tracks.isEmpty, let platforms {
                tracks = platforms.tracks.filter { _, track in
                    track.accesses.contains { $0.kind == .lift && position($0.position, on: track).distance(to: point) < liftRadius }
                }.map(\.key)
            }
            return LiftAlert(lift: lift, tracks: alongPlatforms(tracks, platforms))
        }
        return alerts.sorted { a, b in
            switch (a.tracks.first.map(trackNumber), b.tracks.first.map(trackNumber)) {
            case let (x?, y?) where x != y: x < y
            case (.some, nil): true
            case (nil, .some): false
            default: a.id < b.id
            }
        }
    }

    /// "zu Gleis 4/5" → ["4", "5"]; "Gleis 1-3" → ["1", "2", "3"]; "Gl. 11 und 12" → ["11", "12"].
    static func describedTracks(_ description: String) -> [String] {
        let pattern = /(?i)(?:gleis(?:e|en)?|gl\.)\s*(\d+[a-z]?(?:\s*(?:\/|,|\+|-|–|und|u\.|bis)\s*\d+[a-z]?)*)/
        var tracks: [String] = []
        for match in description.matches(of: pattern) {
            // Track numbers and the range signs between them ("-", "–", "bis" are all "-").
            let tokens = match.output.1.lowercased().matches(of: /\d+[a-z]?|[-–]|bis/).map { token in
                token.output.first!.isNumber ? String(token.output) : "-"
            }
            var index = 0
            while index < tokens.count {
                let token = tokens[index]
                if token == "-", let last = tokens[..<index].last.flatMap({ Int($0) }),
                   index + 1 < tokens.count, let end = Int(tokens[index + 1]), end > last, end - last <= 4 {
                    tracks += (last + 1...end).map(String.init)
                    index += 2
                    continue
                }
                if token != "-", !tracks.contains(token) { tracks.append(token) }
                index += 1
            }
        }
        return tracks
    }

    /// A lift reaches a platform, so every track along it: "zu Gleis 4" is Gleis 5's lift too when they share it.
    static func alongPlatforms(_ tracks: [String], _ platforms: StationPlatforms?) -> [String] {
        guard let platforms else { return tracks }
        var all = tracks
        for track in tracks {
            for group in platforms.sharedPlatforms where group.contains(where: { StationPlatforms.sameTrack($0, track) }) {
                for other in group where !all.contains(where: { StationPlatforms.sameTrack($0, other) }) { all.append(other) }
            }
        }
        return all.sorted { trackNumber($0) == trackNumber($1) ? $0 < $1 : trackNumber($0) < trackNumber($1) }
    }

    private static func trackNumber(_ track: String) -> Int {
        Int(track.prefix(while: \.isNumber)) ?? .max
    }

    /// The point `metres` along `track`'s edge, on the straight line from its start to its end.
    static func position(_ metres: Double, on track: StationPlatforms.Track) -> Coordinate {
        let share = track.length > 0 ? min(max(metres / track.length, 0), 1) : 0
        return Coordinate(latitude: track.start.latitude + (track.end.latitude - track.start.latitude) * share,
                          longitude: track.start.longitude + (track.end.longitude - track.start.longitude) * share)
    }

    /// Metres from `point` to the straight line along `track`'s edge (flat within a station).
    static func distance(from point: Coordinate, toEdgeOf track: StationPlatforms.Track) -> Double {
        let metresPerDegree = 111_320.0
        let scale = cos(point.latitude * .pi / 180)
        func xy(_ c: Coordinate) -> (x: Double, y: Double) {
            ((c.longitude - point.longitude) * metresPerDegree * scale, (c.latitude - point.latitude) * metresPerDegree)
        }
        let a = xy(track.start), b = xy(track.end)
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        let t = lengthSquared > 0 ? min(max(-(a.x * dx + a.y * dy) / lengthSquared, 0), 1) : 0
        let x = a.x + t * dx, y = a.y + t * dy
        return (x * x + y * y).squareRoot()
    }
}

public extension Journey {
    /// The lifts out of order where this journey needs one: the platform it starts from, both platforms of a
    /// transfer (not when both trains stop at the same platform) and the one it arrives at. Only places still
    /// ahead of `now` and with a known track.
    func liftAlerts(among lifts: [BrokenLift], now: Date = .now,
                    platformsAt: (String) -> StationPlatforms? = StationPlatforms.at(eva:)) -> [JourneyLiftAlert] {
        guard !lifts.isEmpty else { return [] }
        let legs = transitLegs.filter { !$0.cancelled }
        var found: [JourneyLiftAlert] = []
        var atStation: [String: [LiftAlert]] = [:]
        func alerts(at station: Station, track: String?) -> [LiftAlert] {
            guard let track else { return [] }
            let key = station.evaNumber ?? station.id
            if atStation[key] == nil { atStation[key] = LiftCheck.alerts(at: station, among: lifts, platformsAt: platformsAt) }
            return atStation[key]!.filter { $0.serves(track: track) }
        }
        func add(_ place: JourneyLiftAlert.Place, _ leg: Leg, _ station: Station, _ alerts: [LiftAlert]) {
            for alert in alerts where !found.contains(where: { $0.legID == leg.id && $0.place == place && $0.alert.id == alert.id }) {
                found.append(JourneyLiftAlert(place: place, legID: leg.id, station: station.displayName, alert: alert))
            }
        }
        for (index, leg) in legs.enumerated() {
            if index == 0, leg.departure.best > now {
                add(.start, leg, leg.origin, alerts(at: leg.origin, track: leg.departurePlatform?.best))
            }
            guard leg.arrival.best > now || (index + 1 < legs.count && legs[index + 1].departure.best > now) else { continue }
            guard index + 1 < legs.count else {
                add(.destination, leg, leg.destination, alerts(at: leg.destination, track: leg.arrivalPlatform?.best))
                continue
            }
            let next = legs[index + 1]
            let arrivalTrack = leg.arrivalPlatform?.best, departureTrack = next.departurePlatform?.best
            if next.origin.isSamePlace(as: leg.destination), let arrivalTrack, let departureTrack {
                let eva = leg.destination.evaNumber ?? StationNames.evaNumber(for: leg.destination)
                let samePlatform = eva.flatMap(platformsAt)?.sharePlatform(arrivalTrack, departureTrack)
                    ?? StationPlatforms.sameTrack(arrivalTrack, departureTrack)
                if samePlatform { continue }
            }
            add(.transfer, leg, leg.destination, alerts(at: leg.destination, track: arrivalTrack))
            add(.transfer, leg, next.origin, alerts(at: next.origin, track: departureTrack))
        }
        return found
    }
}
