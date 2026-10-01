#if canImport(ActivityKit) && os(iOS)
import ActivityKit
import Foundation

/// Live Activity for a journey. Basic version – more details (transfers, push updates) later.
public struct TripActivityAttributes: ActivityAttributes {
    /// Details of the incoming train shown once a transfer is close (see `ContentState.transfer`).
    public struct TransferDetails: Codable, Hashable, Sendable {
        public var incomingLine: String
        public var incomingPlannedArrival: Date
        public var incomingExpectedArrival: Date
        public var incomingPlatform: String?

        public init(incomingLine: String, incomingPlannedArrival: Date, incomingExpectedArrival: Date, incomingPlatform: String?) {
            self.incomingLine = incomingLine
            self.incomingPlannedArrival = incomingPlannedArrival
            self.incomingExpectedArrival = incomingExpectedArrival
            self.incomingPlatform = incomingPlatform
        }

        public var incomingDelayMinutes: Int { Int((incomingExpectedArrival.timeIntervalSince(incomingPlannedArrival) / 60).rounded()) }
    }

    public struct ContentState: Codable, Hashable, Sendable {
        public var lineName: String
        public var nextStopName: String
        public var plannedTime: Date
        public var expectedTime: Date
        public var platform: String?
        /// "Abfahrt" before boarding, "Ankunft" while riding.
        public var isDeparture: Bool
        public var cancelled: Bool
        /// Start and end of the current leg (or the wait before it) for the progress bar.
        public var progressStart: Date
        public var progressEnd: Date
        public var product: Product
        /// E.g. "Anschluss in Hannover Hbf nicht mehr möglich".
        public var warning: String?
        /// Set once a transfer is within 10 minutes, so the UI can show both trains' delay and platforms.
        public var transfer: TransferDetails?
        /// Delay at the next stop (departure before boarding, next intermediate stop while riding),
        /// shown next to the train name. Unlike `delayMinutes` this isn't the delay at the exit.
        public var currentDelayMinutes: Int?
        /// Platform of the next train to board, set only shortly before arriving at the transfer stop.
        public var transferPlatform: String?
        /// The planned platform when the one to go to (`platform` before boarding, `transferPlatform`
        /// while riding) was changed to another track, shown struck through next to the new one.
        public var replacedPlatform: String?
        /// Wrapped in an array because a struct can't contain itself directly; see `followUp`.
        private var followUpStorage: [Self]?
        /// Optional so activities started by older versions still decode; see `arrived`.
        private var arrivedFlag: Bool?

        /// The journey's final arrival has passed: the widget shows "Angekommen" instead of a
        /// countdown stuck at 0:00, until the activity is removed `arrivedDisplayDuration` after arriving.
        public var arrived: Bool { arrivedFlag == true }

        /// What to show once `followUpDate` has passed (e.g. the arrival after the departure), so the
        /// widget can move on by itself when the countdown ends instead of freezing at 0:00 until the
        /// app gets to run again. At the final arrival it's the same state marked `arrived`.
        public var followUp: Self? { followUpStorage?.first }

        /// When the state moves on to `followUp`: at a departure, or a minute after an arrival (see
        /// the hold in `base`). Used as the activity's stale date.
        public var followUpDate: Date { isDeparture ? expectedTime : expectedTime.addingTimeInterval(60) }

        public init(lineName: String, nextStopName: String, plannedTime: Date, expectedTime: Date,
                    platform: String?, isDeparture: Bool, cancelled: Bool,
                    progressStart: Date, progressEnd: Date, product: Product, warning: String? = nil,
                    transfer: TransferDetails? = nil, currentDelayMinutes: Int? = nil,
                    transferPlatform: String? = nil, replacedPlatform: String? = nil) {
            self.transferPlatform = transferPlatform
            self.replacedPlatform = replacedPlatform
            self.currentDelayMinutes = currentDelayMinutes
            self.warning = warning
            self.progressStart = progressStart
            self.progressEnd = max(progressEnd, progressStart.addingTimeInterval(60))
            self.product = product
            self.lineName = lineName
            self.nextStopName = nextStopName
            self.plannedTime = plannedTime
            self.expectedTime = expectedTime
            self.platform = platform
            self.isDeparture = isDeparture
            self.cancelled = cancelled
            self.transfer = transfer
        }

        /// Platform worth showing: the boarding platform before departure; while riding only once the
        /// transfer is close, as "arrival platform → platform to change to" (e.g. "1 → 12").
        public var displayPlatform: String? {
            if isDeparture { return platform }
            guard let transferPlatform else { return nil }
            return platform.map { "\($0) → \(transferPlatform)" } ?? transferPlatform
        }

        public var delayMinutes: Int { Int((expectedTime.timeIntervalSince(plannedTime) / 60).rounded()) }
    }

    /// How long the activity stays up after the journey's final arrival before it's removed.
    public static let arrivedDisplayDuration: TimeInterval = 5 * 60

    public var originName: String
    public var destinationName: String
    public var journeyID: String

    public init(originName: String, destinationName: String, journeyID: String) {
        self.originName = originName
        self.destinationName = destinationName
        self.journeyID = journeyID
    }
}

public extension TripActivityAttributes.ContentState {
    /// Derives the current state from a journey: next departure before boarding, next arrival while riding.
    static func from(_ journey: Journey, now: Date = .now) -> Self? {
        guard var state = withWarning(journey, now: now) else { return nil }
        if isFinalArrival(state, of: journey) {
            var arrived = state
            arrived.arrivedFlag = true
            if now >= state.followUpDate { return arrived }
            state.followUpStorage = [arrived]
        } else if let next = withWarning(journey, now: state.followUpDate.addingTimeInterval(1)), next != state {
            state.followUpStorage = [next]
        }
        return state
    }

    private static func isFinalArrival(_ state: Self, of journey: Journey) -> Bool {
        guard !state.isDeparture, let last = journey.transitLegs.last else { return false }
        return state.expectedTime == last.arrival.best && state.nextStopName == last.destination.displayName
    }

    private static func withWarning(_ journey: Journey, now: Date) -> Self? {
        var state = base(journey, now: now)
        state?.warning = journey.connectionIssues().first(where: \.isBlocking)?.title
        return state
    }

    private static func base(_ journey: Journey, now: Date) -> Self? {
        let legs = journey.transitLegs
        guard !legs.isEmpty else { return nil }
        var previousArrival = min(now, legs[0].departure.best.addingTimeInterval(-30 * 60))
        var previousLeg: Leg?
        for (index, leg) in legs.enumerated() {
            let line = leg.line?.name ?? "Zug"
            let product = leg.line?.product ?? .other
            if now < leg.departure.best {
                var transfer: TripActivityAttributes.TransferDetails?
                if let previousLeg, leg.departure.best.timeIntervalSince(now) <= 10 * 60 {
                    transfer = TripActivityAttributes.TransferDetails(
                        incomingLine: previousLeg.line?.name ?? "Zug",
                        incomingPlannedArrival: previousLeg.arrival.planned,
                        incomingExpectedArrival: previousLeg.arrival.best,
                        incomingPlatform: previousLeg.arrivalPlatform?.best)
                }
                return Self(lineName: line, nextStopName: leg.origin.displayName, plannedTime: leg.departure.planned,
                            expectedTime: leg.departure.best, platform: leg.departurePlatform?.best,
                            isDeparture: true, cancelled: leg.cancelled,
                            progressStart: previousArrival, progressEnd: leg.departure.best, product: product,
                            transfer: transfer, currentDelayMinutes: leg.departure.delayMinutes ?? 0,
                            replacedPlatform: Self.replacedPlatform(leg.departurePlatform))
            }
            // Stays on this leg for a minute after arrival: if the delay grows in that time we're
            // still on the train, so the state jumps back instead of already moving on. Never
            // extends past the next leg's departure.
            var holdUntil = leg.arrival.best.addingTimeInterval(60)
            if index + 1 < legs.count { holdUntil = min(holdUntil, max(leg.arrival.best, legs[index + 1].departure.best)) }
            if now < holdUntil {
                let showsTransfer = index + 1 < legs.count && leg.arrival.best.timeIntervalSince(now) <= 10 * 60
                return Self(lineName: line, nextStopName: leg.destination.displayName, plannedTime: leg.arrival.planned,
                            expectedTime: leg.arrival.best, platform: leg.arrivalPlatform?.best,
                            isDeparture: false, cancelled: leg.cancelled,
                            progressStart: leg.departure.best, progressEnd: leg.arrival.best, product: product,
                            currentDelayMinutes: nextStopDelay(of: leg, now: now),
                            transferPlatform: showsTransfer ? legs[index + 1].departurePlatform?.best : nil,
                            replacedPlatform: showsTransfer ? Self.replacedPlatform(legs[index + 1].departurePlatform) : nil)
            }
            previousArrival = leg.arrival.best
            previousLeg = leg
        }
        let last = legs[legs.count - 1]
        return Self(lineName: last.line?.name ?? "Zug", nextStopName: last.destination.displayName,
                    plannedTime: last.arrival.planned, expectedTime: last.arrival.best,
                    platform: last.arrivalPlatform?.best, isDeparture: false, cancelled: last.cancelled,
                    progressStart: last.departure.best, progressEnd: last.arrival.best,
                    product: last.line?.product ?? .other, currentDelayMinutes: last.arrival.delayMinutes ?? 0)
    }

    /// Delay at the next stop the train has yet to reach; falls back to the leg's arrival.
    /// The planned platform if the train now leaves from another track (not just another sector).
    static func replacedPlatform(_ platform: PlatformInfo?) -> String? {
        guard let platform, PlatformInfo.isDifferentTrack(platform.planned, platform.actual) else { return nil }
        return platform.planned
    }

    private static func nextStopDelay(of leg: Leg, now: Date) -> Int {
        let next = leg.stopovers.dropFirst().first { ($0.arrival?.best ?? .distantPast) >= now }
        return (next?.arrival ?? leg.arrival).delayMinutes ?? 0
    }
}
#endif
