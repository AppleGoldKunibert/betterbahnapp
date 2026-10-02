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
