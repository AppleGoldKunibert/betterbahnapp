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

        public init(lineName: String, nextStopName: String, plannedTime: Date, expectedTime: Date,
                    platform: String?, isDeparture: Bool, cancelled: Bool,
                    progressStart: Date, progressEnd: Date, product: Product, warning: String? = nil,
                    transfer: TransferDetails? = nil) {
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

        public var delayMinutes: Int { Int((expectedTime.timeIntervalSince(plannedTime) / 60).rounded()) }
    }

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
        var state = base(journey, now: now)
        state?.warning = journey.connectionIssues().first(where: \.isBlocking)?.title
        return state
    }

    private static func base(_ journey: Journey, now: Date) -> Self? {
        let legs = journey.transitLegs
        guard !legs.isEmpty else { return nil }
        var previousArrival = min(now, legs[0].departure.best.addingTimeInterval(-30 * 60))
        var previousLeg: Leg?
        for leg in legs {
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
                return Self(lineName: line, nextStopName: leg.origin.name, plannedTime: leg.departure.planned,
                            expectedTime: leg.departure.best, platform: leg.departurePlatform?.best,
                            isDeparture: true, cancelled: leg.cancelled,
                            progressStart: previousArrival, progressEnd: leg.departure.best, product: product,
                            transfer: transfer)
            }
            if now < leg.arrival.best {
                return Self(lineName: line, nextStopName: leg.destination.name, plannedTime: leg.arrival.planned,
                            expectedTime: leg.arrival.best, platform: leg.arrivalPlatform?.best,
                            isDeparture: false, cancelled: leg.cancelled,
                            progressStart: leg.departure.best, progressEnd: leg.arrival.best, product: product)
            }
            previousArrival = leg.arrival.best
            previousLeg = leg
        }
        let last = legs[legs.count - 1]
        return Self(lineName: last.line?.name ?? "Zug", nextStopName: last.destination.name,
                    plannedTime: last.arrival.planned, expectedTime: last.arrival.best,
                    platform: last.arrivalPlatform?.best, isDeparture: false, cancelled: last.cancelled,
                    progressStart: last.departure.best, progressEnd: last.arrival.best,
                    product: last.line?.product ?? .other)
    }
}
#endif
