import Foundation

/// Compensation owed under the EU/DB passenger rights (Fahrgastrechte, #311) for a journey that
/// reached its destination 60 or more minutes late: 25 % of the fare from 60 minutes, 50 % from 120.
/// Only percentages are shown, never amounts: they depend on the fare, and passes like the
/// Deutschland-Ticket have flat rates.
public struct PassengerRightsClaim: Codable, Sendable, Hashable {
    public enum Compensation: Int, Codable, Sendable {
        case quarter = 25
        case half = 50

        public var percent: Int { rawValue }
    }

    /// Why the arrival was late.
    public enum Cause: String, Codable, Sendable {
        /// The planned trains ran, but late.
        case delay
        /// A delay made the user miss a connection, which led to the late arrival.
        case missedConnection
        /// A cancellation or missed connection: the plan was replaced and the new one arrived late.
        case replanned
    }

    public var delayMinutes: Int
    public var compensation: Compensation
    public var cause: Cause
    /// The arrival of the plan as it was booked, and when the journey really arrived.
    public var plannedArrival: Date
    public var actualArrival: Date
    /// The user has a BahnCard 100: other rules (a flat rate) apply, so the card only points to bahn.de.
    public var isFlatRate: Bool

    /// Remembers that the user was told about this level (`SavedJourney.notifiedIssues`).
    public var notificationID: String { "passengerRights|\(compensation.percent)" }

    public init(delayMinutes: Int, compensation: Compensation, cause: Cause, plannedArrival: Date,
                actualArrival: Date, isFlatRate: Bool) {
        self.delayMinutes = delayMinutes
        self.compensation = compensation
        self.cause = cause
        self.plannedArrival = plannedArrival
        self.actualArrival = actualArrival
        self.isFlatRate = isFlatRate
    }
}

public enum PassengerRights {
    /// DB's online form (the short link leads to the passenger rights page).
    public static let formURL = URL(string: "https://www.bahn.de/fahrgastrechte")!

    static let firstThreshold = 60
    static let secondThreshold = 120

    public static func compensation(forDelay minutes: Int) -> PassengerRightsClaim.Compensation? {
        if minutes >= secondThreshold { return .half }
        if minutes >= firstThreshold { return .quarter }
        return nil
    }

    /// The claim for a journey that has arrived, or nil when there is none or it can't be told.
    ///
    /// The delay is measured against the arrival of the plan as it was first booked: `earlierPlans`
    /// (newest first, as `SavedJourney.previousVersions`) that ended at the same place count, so a
    /// cancellation or missed connection that led to a later arrival is included.
    ///
    /// Shown only when it is likely to apply: the user has a ticket for the journey or a BahnCard 100,
    /// or the journey has a long-distance train. On local trains with only a Deutschland-Ticket the
    /// flat 1.50 € per 60 minutes is hardly worth a form, so nothing is shown there.
    public static func claim(for journey: Journey, earlierPlans: [Journey] = [], hasTicket: Bool,
                             hasBahnCard100: Bool, now: Date = .now) -> PassengerRightsClaim? {
        guard let last = journey.legs.last, !last.cancelled, let arrival = journey.arrival else { return nil }
        let original = bookedPlan(replacedBy: journey, earlierPlans: earlierPlans)
        let baseline = original ?? journey
        guard let planned = baseline.arrival?.planned else { return nil }
        // Without live data nothing is known about the real arrival, unless a replacement was chosen.
        guard arrival.actual != nil || original != nil else { return nil }
        let actual = arrival.best
        guard actual <= now else { return nil }

        let minutes = Int(actual.timeIntervalSince(planned) / 60)
        guard let compensation = compensation(forDelay: minutes) else { return nil }

        let longDistance = ([journey] + (original.map { [$0] } ?? []))
            .contains { $0.transitLegs.contains { $0.line?.product.isLongDistance == true } }
        guard hasTicket || hasBahnCard100 || longDistance else { return nil }

        // The plan as booked had a transfer its delays broke: that is why the arrival is late.
        let cause: PassengerRightsClaim.Cause = !baseline.brokenTransferIndices.isEmpty ? .missedConnection
            : original == nil ? .delay : .replanned
        return PassengerRightsClaim(delayMinutes: minutes, compensation: compensation,
                                    cause: cause,
                                    plannedArrival: planned, actualArrival: actual,
                                    isFlatRate: hasBahnCard100)
    }

    /// The oldest of `earlierPlans` (newest first) that ended at the same place as `journey`: the plan as
    /// it was booked, before a cancellation or missed connection replaced it. Nil when it wasn't replaced.
    public static func bookedPlan(replacedBy journey: Journey, earlierPlans: [Journey]) -> Journey? {
        guard let destination = journey.legs.last?.destination else { return nil }
        return earlierPlans.last { plan in
            plan.legs.last.map { $0.destination.isSamePlace(as: destination) } ?? false
        }
    }

    /// One thing DB's form asks for.
    public struct RequestField: Sendable, Hashable, Identifiable {
        public var label: String
        public var value: String
        public var id: String { label }
    }

    /// Everything DB's form asks for: day, route, trains, planned and real times and the order
    /// numbers of the tickets. Day, route, departure and trains are those of the plan as booked
    /// (`bookedPlan`); when it was replaced, the trains really taken follow separately.
    public static func requestFields(for journey: Journey, earlierPlans: [Journey] = [], claim: PassengerRightsClaim,
                                     orderNumbers: [String]) -> [RequestField] {
        let berlin = TimeZone(identifier: "Europe/Berlin") ?? .current
        let german = Locale(identifier: "de_DE")
        func time(_ date: Date) -> String {
            date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: german, timeZone: berlin))
        }
        func day(_ date: Date) -> String {
            date.formatted(Date.FormatStyle(date: .numeric, time: .omitted, locale: german, timeZone: berlin))
        }
        func trains(of plan: Journey) -> String {
            plan.transitLegs.map { leg in
                let name = leg.line?.displayName ?? String(kit: "Zug")
                return "\(name): \(leg.origin.displayName) \(time(leg.departure.planned)) → \(leg.destination.displayName) \(time(leg.arrival.planned))"
            }.joined(separator: "\n")
        }
        let original = bookedPlan(replacedBy: journey, earlierPlans: earlierPlans)
        let booked = original ?? journey
        var fields: [RequestField] = []
        if let departure = booked.departure?.planned { fields.append(RequestField(label: String(kit: "Reisedatum"), value: day(departure))) }
        if let first = booked.legs.first, let last = booked.legs.last {
            fields.append(RequestField(label: String(kit: "Von"), value: first.origin.displayName))
            fields.append(RequestField(label: String(kit: "Nach"), value: last.destination.displayName))
        }
        if let departure = booked.departure?.planned { fields.append(RequestField(label: String(kit: "Geplante Abfahrt"), value: time(departure))) }
        let bookedTrains = trains(of: booked)
        if original == nil {
            if !bookedTrains.isEmpty { fields.append(RequestField(label: String(kit: "Züge"), value: bookedTrains)) }
        } else {
            if !bookedTrains.isEmpty { fields.append(RequestField(label: String(kit: "Gebuchte Züge"), value: bookedTrains)) }
            let takenTrains = trains(of: journey)
            if !takenTrains.isEmpty { fields.append(RequestField(label: String(kit: "Gefahrene Züge"), value: takenTrains)) }
        }
        fields.append(RequestField(label: String(kit: "Geplante Ankunft"), value: time(claim.plannedArrival)))
        fields.append(RequestField(label: String(kit: "Tatsächliche Ankunft"), value: time(claim.actualArrival)))
        fields.append(RequestField(label: String(kit: "Verspätung am Ziel"), value: String(kit: "%lld Minuten", claim.delayMinutes)))
        if !orderNumbers.isEmpty {
            fields.append(RequestField(label: String(kit: "Auftragsnummer"), value: orderNumbers.joined(separator: ", ")))
        }
        return fields
    }

    /// `requestFields` as one text to copy.
    public static func requestText(for journey: Journey, earlierPlans: [Journey] = [], claim: PassengerRightsClaim,
                                   orderNumbers: [String]) -> String {
        requestFields(for: journey, earlierPlans: earlierPlans, claim: claim, orderNumbers: orderNumbers).map { field in
            field.value.contains("\n") ? "\(field.label):\n\(field.value)" : "\(field.label): \(field.value)"
        }.joined(separator: "\n")
    }
}
