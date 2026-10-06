import Foundation

/// What the journey widgets show at one moment, worked out from a saved journey's timetable (with
/// whatever live data the app last stored). The widget asks for the state at each `changeDates`
/// moment ahead of time, so it moves on through the journey by itself between the app's updates.
public struct JourneyWidgetState: Hashable, Sendable {
    public enum Phase: Hashable, Sendable {
        /// The journey hasn't started: shows the first departure (also the "next journey" fallback).
        case beforeDeparture
        /// On a train, more than `transferLead` before reaching the transfer station.
        case riding
        /// Close to or at a transfer: shows both trains and platforms.
        case transfer
        /// The final arrival has passed.
        case arrived
    }

    /// What the countdown counts down to (picked in the widget's settings).
    public enum CountdownTarget: String, Hashable, Sendable, CaseIterable {
        /// The next train's departure (the first one before the journey, the following one while
        /// riding); the final arrival on the last train.
        case nextConnection
        /// The final arrival.
        case destination
    }

    /// The train changed to at a transfer.
    public struct Transfer: Hashable, Sendable {
        public var station: String
        public var fromTrain: String
        public var toTrain: String
        public var fromPlatform: String?
        public var toPlatform: String?
        public var departure: Date
        public var departureDelayMinutes: Int?
        public var toProduct: Product
    }

    /// A stop of the current train still ahead (for the current-train widget).
    public struct UpcomingStop: Hashable, Sendable {
        public var name: String
        public var time: Date
        public var delayMinutes: Int?
        public var cancelled: Bool
    }

    public var phase: Phase
    /// The train ridden now, or boarded next before the journey/at a transfer.
    public var trainName: String
    public var product: Product
    /// Index of that train's leg in `Journey.legs` (for the map link).
    public var legIndex: Int
    /// Where that train is going (its direction), if known.
    public var direction: String?
    /// The next stop: the station to depart from before boarding, else the train's next stop.
    public var nextStopName: String
    public var nextStopTime: Date
    public var nextStopDelayMinutes: Int?
    /// The departure platform before boarding.
    public var platform: String?
    public var transfer: Transfer?
    public var originName: String
    public var destinationName: String
    public var finalArrival: Date
    public var finalDelayMinutes: Int?
    /// The next train's departure, nil on the last train once it has left.
    public var nextDeparture: Date?
    public var cancelled: Bool
    /// E.g. "Anschluss in Hannover Hbf nicht mehr möglich".
    public var warning: String?
    /// Where to get off that train, with the expected arrival, its delay and the platform.
    public var exitName: String
    public var exitTime: Date
    public var exitDelayMinutes: Int?
    public var exitPlatform: String?
    /// The train's next stops up to `exitName` (excluding it), at most `maxUpcomingStops`.
    public var upcomingStops: [UpcomingStop]
    /// Not on the train yet: before the journey or waiting at a transfer.
    public var isWaitingToBoard = false

    public static let maxUpcomingStops = 3

    /// A transfer shows from this long before arriving at the transfer station.
    public static let transferLead: TimeInterval = 10 * 60

    /// When the countdown for `target` ends.
    public func countdownEnd(_ target: CountdownTarget) -> Date {
        switch target {
        case .nextConnection: nextDeparture ?? finalArrival
        case .destination: finalArrival
        }
    }

    /// Whether `target` counts down to a departure ("Abfahrt in") rather than the arrival.
    public func countsToDeparture(_ target: CountdownTarget) -> Bool {
        target == .nextConnection && nextDeparture != nil
    }

    public static func from(_ journey: Journey, now: Date = .now) -> JourneyWidgetState? {
        let legs = journey.legs.enumerated().filter { !$0.element.isWalking }
        guard let first = legs.first?.element, let last = legs.last?.element else { return nil }
        var state = JourneyWidgetState(
            phase: .arrived, trainName: name(of: last), product: last.line?.product ?? .other,
            legIndex: legs[legs.count - 1].offset, direction: last.direction,
            nextStopName: last.destination.displayName, nextStopTime: last.arrival.best,
            nextStopDelayMinutes: last.arrival.delayMinutes, platform: nil, transfer: nil,
            originName: first.origin.displayName, destinationName: last.destination.displayName,
            finalArrival: last.arrival.best, finalDelayMinutes: last.arrival.delayMinutes,
            nextDeparture: nil, cancelled: last.cancelled,
            warning: journey.connectionIssues().first(where: \.isBlocking)?.title,
            exitName: last.destination.displayName, exitTime: last.arrival.best,
            exitDelayMinutes: last.arrival.delayMinutes, exitPlatform: last.arrivalPlatform?.best, upcomingStops: [])

        for (position, (index, leg)) in legs.enumerated() {
            let previous = position > 0 ? legs[position - 1].element : nil
            let following = position + 1 < legs.count ? legs[position + 1].element : nil
            state.trainName = name(of: leg)
            state.product = leg.line?.product ?? .other
            state.legIndex = index
            state.direction = leg.direction
            state.cancelled = leg.cancelled
            state.exitName = leg.destination.displayName
            state.exitTime = leg.arrival.best
            state.exitDelayMinutes = leg.arrival.delayMinutes
            state.exitPlatform = leg.arrivalPlatform?.best
            state.upcomingStops = upcomingStops(of: leg, after: now)
            if now < leg.departure.best {
                state.nextStopName = leg.origin.displayName
                state.nextStopTime = leg.departure.best
                state.nextStopDelayMinutes = leg.departure.delayMinutes
                state.platform = leg.departurePlatform?.best
                state.nextDeparture = leg.departure.best
                state.isWaitingToBoard = true
                if let previous {
                    state.phase = .transfer
                    state.transfer = transfer(from: previous, to: leg)
                } else {
                    state.phase = .beforeDeparture
                }
                return state
            }
            if now < leg.arrival.best {
                let next = leg.stopovers.dropFirst().first { !$0.cancelled && ($0.arrival?.best ?? .distantPast) > now }
                state.nextStopName = next?.station.displayName ?? leg.destination.displayName
                state.nextStopTime = next?.arrival?.best ?? leg.arrival.best
                state.nextStopDelayMinutes = (next?.arrival ?? leg.arrival).delayMinutes
                state.nextDeparture = following?.departure.best
                if let following, leg.arrival.best.timeIntervalSince(now) <= transferLead {
                    state.phase = .transfer
                    state.transfer = transfer(from: leg, to: following)
                } else {
                    state.phase = .riding
                }
                return state
            }
        }
        return state
    }

    /// The moments after `now` (up to `horizon`) at which `from(_:now:)` may give another state:
    /// departures, arrivals at every stop, and the start of each transfer's lead time.
    public static func changeDates(of journey: Journey, after now: Date = .now, horizon: TimeInterval = 24 * 3600) -> [Date] {
        var dates = Set<Date>()
        for leg in journey.transitLegs {
            dates.insert(leg.departure.best)
            dates.insert(leg.arrival.best)
            dates.insert(leg.arrival.best.addingTimeInterval(-transferLead))
            for stop in leg.stopovers { if let arrival = stop.arrival?.best { dates.insert(arrival) } }
        }
        let end = now.addingTimeInterval(horizon)
        return dates.filter { $0 > now && $0 <= end }.sorted()
    }

    /// Short train name for small widgets: the line for regional trains ("RE 5", "S 3"), the train
    /// number only where there's no line (long-distance trains, "ICE 645"); never the run number.
    public static func name(of leg: Leg) -> String {
        guard let line = leg.line, !line.isUnknown else { return "Zug" }
        return line.displayName
    }

    /// Intermediate stops of `leg` not yet reached at `now` (arrival, else departure, after it).
    static func upcomingStops(of leg: Leg, after now: Date) -> [UpcomingStop] {
        guard leg.stopovers.count > 2 else { return [] }
        return leg.stopovers.dropFirst().dropLast().compactMap { stop -> UpcomingStop? in
            guard let time = stop.arrival ?? stop.departure, time.best > now else { return nil }
            return UpcomingStop(name: stop.station.displayName, time: time.best, delayMinutes: time.delayMinutes,
                                cancelled: stop.cancelled)
        }.prefix(maxUpcomingStops).map { $0 }
    }

    private static func transfer(from previous: Leg, to next: Leg) -> Transfer {
        Transfer(station: next.origin.displayName, fromTrain: name(of: previous), toTrain: name(of: next),
                 fromPlatform: previous.arrivalPlatform?.best, toPlatform: next.departurePlatform?.best,
                 departure: next.departure.best, departureDelayMinutes: next.departure.delayMinutes,
                 toProduct: next.line?.product ?? .other)
    }
}

public extension JourneyWidgetState {
    /// The leg of the train ridden at this moment, whose live position the live widgets show; nil
    /// while waiting to board (they show the next stop with a timer instead) or after arriving.
    func ridingLeg(of journey: Journey) -> Leg? {
        guard !isWaitingToBoard, phase != .arrived, journey.legs.indices.contains(legIndex) else { return nil }
        return journey.legs[legIndex]
    }
}
