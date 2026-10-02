import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Kit

// Runs the app's station search (TransitousProvider.searchStations with our ranking) against live
// Transitous for each scenario: "<place> | <query> | <expected name part>[; <another>] | <top n>".
// "-" as place searches without a location; "=Bern" wants exactly that name; top 0 means none of the
// names may be among the first five. DETAIL=1 also prints each hit's region, distance and ID.
let places: [String: Coordinate] = [
    "-": Coordinate(latitude: 0, longitude: 0),
    "Berlin": .init(latitude: 52.520, longitude: 13.405), "München": .init(latitude: 48.137, longitude: 11.576),
    "Hamburg": .init(latitude: 53.551, longitude: 9.994), "Köln": .init(latitude: 50.938, longitude: 6.960),
    "Frankfurt": .init(latitude: 50.111, longitude: 8.682), "Freiburg": .init(latitude: 47.999, longitude: 7.842),
    "Görlitz": .init(latitude: 51.153, longitude: 14.987), "Passau": .init(latitude: 48.567, longitude: 13.432),
    "Aachen": .init(latitude: 50.776, longitude: 6.084), "Konstanz": .init(latitude: 47.660, longitude: 9.176),
    "Flensburg": .init(latitude: 54.794, longitude: 9.437), "Dresden": .init(latitude: 51.050, longitude: 13.738),
    "Leipzig": .init(latitude: 51.340, longitude: 12.375), "Stuttgart": .init(latitude: 48.776, longitude: 9.183),
    "Bernau": .init(latitude: 52.679, longitude: 13.587), "Eberswalde": .init(latitude: 52.833, longitude: 13.833),
    "Rosenheim": .init(latitude: 47.856, longitude: 12.128), "Saarbrücken": .init(latitude: 49.234, longitude: 6.995),
    "Nürnberg": .init(latitude: 49.452, longitude: 11.077), "Hannover": .init(latitude: 52.376, longitude: 9.738),
    "Rostock": .init(latitude: 54.092, longitude: 12.099), "Erfurt": .init(latitude: 50.978, longitude: 11.029),
    "Karlsruhe": .init(latitude: 49.007, longitude: 8.404), "Lindau": .init(latitude: 47.546, longitude: 9.684),
    "Kassel": .init(latitude: 51.312, longitude: 9.480), "Bremen": .init(latitude: 53.079, longitude: 8.802),
    "Münster": .init(latitude: 51.961, longitude: 7.626), "Kiel": .init(latitude: 54.323, longitude: 10.123),
    "Magdeburg": .init(latitude: 52.121, longitude: 11.628), "Würzburg": .init(latitude: 49.792, longitude: 9.953),
    "Regensburg": .init(latitude: 49.013, longitude: 12.102), "Trier": .init(latitude: 49.750, longitude: 6.637),
    "Ulm": .init(latitude: 48.401, longitude: 9.988), "Cottbus": .init(latitude: 51.756, longitude: 14.333),
    "Schwerin": .init(latitude: 53.629, longitude: 11.415), "Bielefeld": .init(latitude: 52.022, longitude: 8.532),
    "Düsseldorf": .init(latitude: 51.227, longitude: 6.774), "Essen": .init(latitude: 51.456, longitude: 7.012),
    "Dortmund": .init(latitude: 51.514, longitude: 7.466), "Mannheim": .init(latitude: 49.487, longitude: 8.466),
    "Augsburg": .init(latitude: 48.371, longitude: 10.898), "Halle": .init(latitude: 51.483, longitude: 11.970),
    // Rural places, away from the big towns in NearbyTowns.
    "Perleberg": .init(latitude: 53.074, longitude: 11.860), "Kempten": .init(latitude: 47.726, longitude: 10.314),
    "Meppen": .init(latitude: 52.692, longitude: 7.296), "Prenzlau": .init(latitude: 53.316, longitude: 13.863),
    "Plauen": .init(latitude: 50.495, longitude: 12.137), "Gerolstein": .init(latitude: 50.223, longitude: 6.661),
    "Westerland": .init(latitude: 54.907, longitude: 8.310), "Wernigerode": .init(latitude: 51.835, longitude: 10.785),
    "Weiden": .init(latitude: 49.676, longitude: 12.156), "Husum": .init(latitude: 54.477, longitude: 9.051),
    "Garmisch": .init(latitude: 47.492, longitude: 11.095), "Stralsund": .init(latitude: 54.309, longitude: 13.082),
    "Bautzen": .init(latitude: 51.181, longitude: 14.424), "Fulda": .init(latitude: 50.555, longitude: 9.680),
    "Neuruppin": .init(latitude: 52.925, longitude: 12.803), "Lübben": .init(latitude: 51.940, longitude: 13.892),
    // Abroad, near the border.
    "Salzburg": .init(latitude: 47.809, longitude: 13.055), "Basel": .init(latitude: 47.560, longitude: 7.588),
    "Strasbourg": .init(latitude: 48.584, longitude: 7.736), "Szczecin": .init(latitude: 53.428, longitude: 14.553),
    "Venlo": .init(latitude: 51.370, longitude: 6.172), "Wien": .init(latitude: 48.208, longitude: 16.373),
]

let file = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "scenarios.txt"
let only = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : nil
let lines = try String(contentsOfFile: file, encoding: .utf8).split(separator: "\n")
    .map { $0.trimmingCharacters(in: .whitespaces) }
    .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    .filter { only == nil || $0.localizedCaseInsensitiveContains(only!) }

let provider = TransitousProvider()
var failures = 0
for line in lines {
    let parts = line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    guard parts.count >= 3, let place = places[parts[0]] else { print("?? bad line: \(line)"); continue }
    let location: Coordinate? = parts[0] == "-" ? nil : place
    let expected = parts[2].split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    let top = parts.count > 3 ? Int(parts[3]) ?? 3 : 3
    let start = Date()
    var names: [String] = []
    var stations: [Station] = []
    var errorText: String?
    for attempt in 0..<3 {
        do {
            stations = try await provider.searchStations(parts[1], near: location)
            names = stations.map(\.displayName)
            errorText = nil
            break
        } catch {
            errorText = "\(error)"
            try? await Task.sleep(for: .seconds(1 + attempt))
        }
    }
    let seconds = Date().timeIntervalSince(start)
    let missing = expected.filter { want in
        // "=Bern" wants exactly that name, "Bern" any name containing it.
        want.hasPrefix("=") ? !names.prefix(top).contains(String(want.dropFirst()))
            : !names.prefix(top).contains { $0.localizedCaseInsensitiveContains(want) }
    }
    // Top 0 turns it around: none of the expected names may be among the first 5.
    let ok = errorText == nil && (top == 0
        ? !names.prefix(5).contains { name in expected.contains { name.localizedCaseInsensitiveContains($0) } }
        : missing.isEmpty)
    if !ok { failures += 1 }
    print("\(ok ? "PASS" : "FAIL") [\(parts[0])] \"\(parts[1])\" want \(expected) in top \(top)\(errorText.map { " ERROR \($0)" } ?? "") (\(String(format: "%.1f", seconds)) s)")
    if ProcessInfo.processInfo.environment["DETAIL"] != nil {
        for station in stations.prefix(12) {
            let km = station.coordinate.map { Int(place.distance(to: $0) / 1000) } ?? -1
            print("       \(station.displayName) | \(station.region ?? "-") | \(km) km | \(station.id)")
        }
    }
    print("     " + names.prefix(8).enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: " · "))
}
if ProcessInfo.processInfo.environment["DETAIL"] != nil { }
print("\(failures) of \(lines.count) failed")
