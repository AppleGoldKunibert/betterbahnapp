import Foundation

/// What was typed into a station field (#90): the name, plus one-letter shortcuts as separate words
/// at the start or end – "b" bus stops, "t" tram stops, "l" nearest first – e.g. "b l Rathaus" or
/// "Alexanderplatz t". Without "b", stops served only by buses are left out.
public struct StationSearch: Sendable, Hashable {
    public enum Mode: String, Sendable, Hashable, CaseIterable {
        case bus, tram

        /// MOTIS modes a stop needs (any of them) to count as this mode.
        var motisModes: Set<String> {
            switch self {
            case .bus: ["BUS", "COACH"]
            case .tram: ["TRAM"]
            }
        }
    }

    /// The name to look for, without the shortcuts.
    public var text: String
    /// Only stops where at least one of these stops (also if others stop there too). Empty: every
    /// stop except bus-only ones.
    public var modes: Set<Mode>
    /// Nearest first, ignoring the usual ranking.
    public var byDistance: Bool

    public init(text: String, modes: Set<Mode> = [], byDistance: Bool = false) {
        self.text = text
        self.modes = modes
        self.byDistance = byDistance
    }

    /// Splits off the shortcuts. A lone letter only counts once a space follows it, so the "B" typed
    /// as the start of "Berlin" doesn't flash up as a bus filter.
    public init(parsing input: String) {
        var words = input.split(whereSeparator: \.isWhitespace).map(String.init)
        var modes: Set<Mode> = []
        var byDistance = false
        func take(_ word: String) -> Bool {
            switch word.lowercased() {
            case "b": modes.insert(.bus)
            case "t": modes.insert(.tram)
            case "l": byDistance = true
            default: return false
            }
            return true
        }
        if words.count > 1 || input.last?.isWhitespace == true {
            while let first = words.first, take(first) { words.removeFirst() }
            while let last = words.last, take(last) { words.removeLast() }
        }
        self.init(text: words.joined(separator: " "), modes: modes, byDistance: byDistance)
    }

    public var hasShortcuts: Bool { !modes.isEmpty || byDistance }

    /// With `byDistance` and a known `location`, `stations` nearest first (stations without a
    /// position last); otherwise unchanged.
    public func ordered(_ stations: [Station], near location: Coordinate?) -> [Station] {
        guard byDistance, let location else { return stations }
        return stations.enumerated().sorted {
            let a = $0.element.coordinate.map(location.distance(to:)) ?? .infinity
            let b = $1.element.coordinate.map(location.distance(to:)) ?? .infinity
            return a != b ? a < b : $0.offset < $1.offset
        }.map(\.element)
    }
}
