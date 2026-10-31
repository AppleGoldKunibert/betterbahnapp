import Foundation

/// Where a journey stands right now, for the live lines on a saved journey's ticket (#504): the step that
/// comes next (the departure, the train being ridden, or a transfer underway), the transfer after it, and the
/// trains still ahead in order (whose series the ticket names, the ridden one first).
public struct JourneyLiveStatus: Sendable, Hashable {
    public enum Step: Sendable, Hashable {
        /// Before the first train: its departure from the journey's start.
        case departure(Leg)
        /// On a train, until it reaches the leg's destination.
        case riding(Leg)
        /// Between two trains: `next` departs from the station `previous` arrived at.
        case transfer(previous: Leg, next: Leg)
    }

    /// A change of trains after the current step.
    public struct Transfer: Sendable, Hashable {
        /// The train to change into; it departs from `next.origin`.
        public var next: Leg
        /// Minutes from the arrival to the next train's departure, live where known; negative when the
        /// connection is already missed.
        public var minutes: Int
    }

    public var step: Step
    public var nextTransfer: Transfer?
    /// The trains not yet arrived, in order: the one being ridden or waited for first.
    public var upcomingLegs: [Leg]

    /// The status of `journey` at `now`; nil once it has arrived (or without any train).
    public static func at(_ now: Date, of journey: Journey) -> JourneyLiveStatus? {
        let legs = journey.transitLegs
        guard let index = legs.firstIndex(where: { $0.arrival.best > now }) else { return nil }
        let leg = legs[index]
        let step: Step
        if leg.departure.best <= now {
            step = .riding(leg)
        } else if index == 0 {
            step = .departure(leg)
        } else {
            step = .transfer(previous: legs[index - 1], next: leg)
        }
        var transfer: Transfer?
        if index + 1 < legs.count {
            let next = legs[index + 1]
            transfer = Transfer(next: next, minutes: minutes(from: leg.arrival.best, to: next.departure.best))
        }
        return JourneyLiveStatus(step: step, nextTransfer: transfer, upcomingLegs: Array(legs[index...]))
    }

    /// Minutes between two times, rounded down so "2 min" never promises more than there is.
    public static func minutes(from start: Date, to end: Date) -> Int {
        Int((end.timeIntervalSince(start) / 60).rounded(.down))
    }
}
