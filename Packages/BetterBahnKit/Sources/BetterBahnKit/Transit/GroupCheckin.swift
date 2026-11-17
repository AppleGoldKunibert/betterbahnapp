import Foundation

/// Checking in on every train of a journey at once (#574): one form for all of them, then one check-in after
/// the other in the journey's order. Keeps how far each train got, so the ones that need the user (a train
/// Träwelling doesn't know, another check-in at that time) can be finished one by one.
public struct GroupCheckin: Sendable, Hashable {
    public enum State: Sendable, Hashable {
        case waiting
        case sending
        case checkedIn(points: Int, companions: Int)
        /// Checked in before the group check-in started (on its own, or a reminder's button).
        case alreadyCheckedIn
        /// Träwelling doesn't know the train: it can be entered by hand.
        case trainNotFound
        /// Träwelling has the user on another train at that time: they can check in anyway.
        case collision
        case failed(String)

        public var isCheckedIn: Bool {
            switch self {
            case .checkedIn, .alreadyCheckedIn: true
            default: false
            }
        }
    }

    /// The trains in the journey's order.
    public let legIDs: [String]
    public private(set) var states: [String: State]

    /// - Parameter checkedIn: IDs of the legs the user has checked in on already.
    public init(legs: [Leg], checkedIn: Set<String>) {
        legIDs = legs.map(\.id)
        states = Dictionary(legs.map { ($0.id, checkedIn.contains($0.id) ? State.alreadyCheckedIn : .waiting) },
                            uniquingKeysWith: { first, _ in first })
    }

    public func state(of legID: String) -> State { states[legID] ?? .waiting }

    public mutating func set(_ state: State, for legID: String) {
        guard states[legID] != nil else { return }
        states[legID] = state
    }

    /// What "Alle einchecken" sends, in order: the trains not tried yet and those that failed for another
    /// reason. A train Träwelling doesn't know or a collision waits for the user's own choice.
    public var toSend: [String] {
        legIDs.filter {
            switch state(of: $0) {
            case .waiting, .failed: true
            default: false
            }
        }
    }

    public var isSending: Bool { states.values.contains(.sending) }
    /// Every train is checked in.
    public var isDone: Bool { legIDs.allSatisfy { state(of: $0).isCheckedIn } }
    /// Whether anything has been sent yet: the form stays editable until then.
    public var hasStarted: Bool {
        states.values.contains { state in
            switch state {
            case .waiting, .alreadyCheckedIn: false
            default: true
            }
        }
    }

    /// The points of the check-ins made here.
    public var points: Int {
        states.values.reduce(0) { sum, state in
            if case .checkedIn(let points, _) = state { sum + points } else { sum }
        }
    }

    /// The trains checked in here (not the ones checked in before).
    public var checkedInCount: Int {
        states.values.filter { if case .checkedIn = $0 { true } else { false } }.count
    }
}

public extension Journey {
    /// The trains a group check-in covers (#574): every train that isn't cancelled, in order.
    var groupCheckinLegs: [Leg] { transitLegs.filter { !$0.cancelled } }

    /// Whether "Alle Züge" is offered: only for a journey with more than one train.
    var offersGroupCheckin: Bool { groupCheckinLegs.count > 1 }
}

public extension Leg {
    /// This leg as checked in when the user sits in the coupled train `name` (`Line.coupledTrains`); the leg
    /// itself for its own train's name or none.
    func riding(trainNamed name: String?) -> Leg {
        guard let name, let train = line?.coupledTrains?.first(where: { $0.name == name }) else { return self }
        return riding(train)
    }

    /// Whether Träwelling needs to be told which of the coupled trains the user sits in.
    var needsCoupledTrainChoice: Bool { !(line?.coupledTrains ?? []).isEmpty }
}
