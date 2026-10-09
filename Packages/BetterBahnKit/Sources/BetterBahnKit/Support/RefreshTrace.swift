import Foundation

/// What one refresh of a journey asked each live source and what came back, per leg and in order
/// (Transitous, DB Timetables, bahn.de). A delay that stays stale is otherwise invisible: the
/// refresh swallows failed requests and keeps the last known time. Shown in Settings → Live-Daten-
/// Diagnose, as text to copy.
public struct RefreshTrace: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var date: Date
    public var legs: [LegTrace]

    public init(id: String, title: String, date: Date, legs: [LegTrace]) {
        self.id = id
        self.title = title
        self.date = date
        self.legs = legs
    }

    public struct LegTrace: Codable, Sendable, Hashable {
        public var train: String
        public var route: String
        public var steps: [Step]

        public init(train: String, route: String, steps: [Step]) {
            self.train = train
            self.route = route
            self.steps = steps
        }
    }

    public struct Step: Codable, Sendable, Hashable {
        public enum Outcome: String, Codable, Sendable {
            /// The source answered; `detail` has the times the leg shows afterwards.
            case ok
            /// The source answered without anything for this leg.
            case empty
            /// The request failed; `detail` has the error.
            case failed
            /// The source wasn't asked, `detail` says why.
            case skipped
        }

        public var source: String
        public var outcome: Outcome
        public var detail: String

        public init(source: String, outcome: Outcome, detail: String) {
            self.source = source
            self.outcome = outcome
            self.detail = detail
        }
    }

    /// The trace as plain text, to read in the app or paste into an issue.
    public var text: String {
        var lines = ["\(title)", "Aktualisiert: \(Self.dayAndTime(date))"]
        for leg in legs {
            lines.append("")
            lines.append("\(leg.train) · \(leg.route)")
            for step in leg.steps {
                lines.append("  \(Self.mark(step.outcome)) \(step.source): \(step.detail)")
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func mark(_ outcome: Step.Outcome) -> String {
        switch outcome {
        case .ok: "✓"
        case .empty: "∅"
        case .failed: "✗"
        case .skipped: "–"
        }
    }

    // MARK: Summaries

    /// "ab 18:32 → 18:51 (+19), an 19:55 → 20:01 (+6)"; without a live time only the planned one.
    static func summary(of leg: Leg) -> String {
        "ab \(describe(leg.departure)), an \(describe(leg.arrival))"
    }

    /// How many of `stops` carry a live time, and the delay at the first and the last of them.
    public static func summary(ofStopovers stops: [Stopover]) -> String {
        let times = stops.compactMap { $0.departure ?? $0.arrival }
        return summary(ofTimes: times)
    }

    /// The same for bahn.de's stops.
    public static func summary(ofStops stops: [JourneyStop]) -> String {
        summary(ofTimes: stops.compactMap { $0.departure ?? $0.arrival })
    }

    private static func summary(ofTimes times: [TimeInfo]) -> String {
        let live = times.filter { $0.actual != nil }
        guard let first = live.first, let last = live.last else { return "\(times.count) Halte, keiner mit Live-Zeit" }
        return "\(times.count) Halte, \(live.count) mit Live-Zeit, erster \(delay(first)), letzter \(delay(last))"
    }

    private static func describe(_ time: TimeInfo) -> String {
        guard time.actual != nil else { return "\(clock(time.planned)) (keine Live-Zeit)" }
        return "\(clock(time.planned)) → \(clock(time.best)) (\(delay(time)))"
    }

    private static func delay(_ time: TimeInfo) -> String {
        guard let minutes = time.delayMinutes else { return "?" }
        return minutes > 0 ? "+\(minutes)" : minutes == 0 ? "±0" : "\(minutes)"
    }

    private static func clock(_ date: Date) -> String {
        formatted(date, "HH:mm")
    }

    private static func dayAndTime(_ date: Date) -> String {
        formatted(date, "dd.MM. HH:mm:ss")
    }

    private static func formatted(_ date: Date, _ format: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Europe/Berlin")
        formatter.dateFormat = format
        return formatter.string(from: date)
    }

    // MARK: Building

    static func legTrace(for leg: Leg, steps: [Step]) -> LegTrace {
        LegTrace(train: leg.line?.name ?? "Fußweg", route: "\(leg.origin.displayName) → \(leg.destination.displayName)", steps: steps)
    }

    /// The trace of one train's stop list (the trip views): `steps` are what each source answered while it
    /// loaded; the last one is what the view shows afterwards.
    public static func trip(id: String, line: String, stopovers: [Stopover], steps: [Step], date: Date = .now) -> RefreshTrace {
        var steps = steps
        if !stopovers.isEmpty {
            steps.append(Step(source: "Angezeigt", outcome: .ok, detail: summary(ofStopovers: stopovers)))
        }
        let route = [stopovers.first, stopovers.last].compactMap { $0?.station.displayName }.joined(separator: " → ")
        return RefreshTrace(id: "trip|\(id)", title: "Zug \(line)", date: date,
                            legs: [LegTrace(train: line, route: route, steps: steps)])
    }

    static func title(of journey: Journey) -> String {
        guard let first = journey.legs.first, let last = journey.legs.last else { return "Reise" }
        return "\(first.origin.displayName) → \(last.destination.displayName)"
    }
}
