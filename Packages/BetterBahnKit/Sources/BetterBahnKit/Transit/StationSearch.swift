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
    /// ISO code from a flag typed at the start or end ("Wien 🇦🇹"): only stations in that country.
    public var country: String?

    public init(text: String, modes: Set<Mode> = [], byDistance: Bool = false, country: String? = nil) {
        self.text = text
        self.modes = modes
        self.byDistance = byDistance
        self.country = country
    }

    /// Splits off the shortcuts. A lone letter only counts once a space follows it, so the "B" typed
    /// as the start of "Berlin" or the end of "München Terminal B" doesn't turn into a bus filter. A
    /// flag can't be part of a name and counts right away.
    public init(parsing input: String) {
        var words = input.split(whereSeparator: \.isWhitespace).map(String.init)
        var modes: Set<Mode> = []
        var byDistance = false
        var country: String?
        func take(_ word: String) -> Bool {
            if let code = TrainSearchCountry.code(forFlag: word) {
                country = code
                return true
            }
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
            let endsWithSpace = input.last?.isWhitespace == true
            while let last = words.last, endsWithSpace || TrainSearchCountry.code(forFlag: last) != nil, take(last) {
                words.removeLast()
            }
        }
        self.init(text: words.joined(separator: " "), modes: modes, byDistance: byDistance, country: country)
    }

    public var hasShortcuts: Bool { !modes.isEmpty || byDistance || country != nil }

    /// With a `country`, only the `stations` there (those of unknown country stay); otherwise unchanged.
    public func filtered(_ stations: [Station]) -> [Station] {
        guard let country else { return stations }
        return stations.filter { $0.countryCode.map { $0 == country } ?? true }
    }

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
