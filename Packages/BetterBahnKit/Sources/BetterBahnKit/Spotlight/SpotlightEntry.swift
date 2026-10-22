import Foundation

/// What the iOS search (Spotlight) shows for a favourite station or a saved journey (#387). The entry's
/// `id` is its deep link (`BoardWidgetLink` for a station's board, `LiveActivityLink` for a journey), so
/// a tapped result opens through the app's usual link handling.
public struct SpotlightEntry: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Hashable {
        case station
        case journey
    }

    public var kind: Kind
    /// "Köln Hbf – Abfahrten", "ICE 597 nach München Hbf, Fr 14:12".
    public var title: String
    public var subtitle: String?
    /// Further words the entry is found by: RIL100 codes, train numbers, the stations on the way.
    public var keywords: [String]
    /// When Spotlight drops the entry by itself: a journey's end (`Journey.isOver`), nil for stations.
    public var expiry: Date?
    public var url: URL

    public var id: String { url.absoluteString }

    /// The link of an entry from its `id`, as Spotlight hands it back when a result is tapped.
    public static func url(forID id: String) -> URL? {
        guard let url = URL(string: id), BoardWidgetLink.target(from: url) != nil || LiveActivityLink.journeyID(from: url) != nil
        else { return nil }
        return url
    }

    /// A favourite station: opens its departure board.
    public static func station(_ station: Station) -> SpotlightEntry {
        let name = station.displayName
        return SpotlightEntry(kind: .station, title: "\(name) – Abfahrten", subtitle: station.region,
                              keywords: keywords(for: [station]) + ["Abfahrten", "Abfahrt", "Ankünfte", "Bahnhof"],
                              expiry: nil, url: BoardWidgetLink.url(station: station))
    }

    /// A saved journey: opens it. Nil once it's over (`Journey.isOver`), or for a journey without legs.
    /// Times are the planned ones, so a delay doesn't change the entry; `timeZone` is the device's.
    public static func journey(_ journey: Journey, now: Date = .now, timeZone: TimeZone = .current) -> SpotlightEntry? {
        guard let first = journey.legs.first, let last = journey.legs.last, !journey.isOver(now: now) else { return nil }
        let trains = journey.transitLegs.compactMap(\.line)
        let destination = last.destination.displayName
        let what = trains.first.map(\.displayName) ?? "Reise"
        let when = departureText(first.departure.planned, now: now, timeZone: timeZone)
        var subtitle = "\(first.origin.displayName) → \(destination)"
        if trains.count > 1 {
            subtitle += " · " + trains.map(\.displayName).joined(separator: ", ")
        }
        var stations = [first.origin]
        for leg in journey.legs where !stations.contains(leg.destination) { stations.append(leg.destination) }
        var words: [String] = []
        for line in trains {
            words += line.allNames
            words += line.allNames.map { $0.replacingOccurrences(of: " ", with: "") }
            words += [line.number, line.tripNumber].compactMap { $0 }
        }
        words += keywords(for: stations) + ["Reise", "Verbindung"]
        return SpotlightEntry(kind: .journey, title: "\(what) nach \(destination), \(when)", subtitle: subtitle,
                              keywords: unique(words), expiry: journey.arrival.map { $0.best.addingTimeInterval(10 * 60) },
                              url: LiveActivityLink.url(journeyID: journey.id))
    }

    /// Every entry for the favourites and the saved journeys, the journeys that are over left out.
    public static func entries(favorites: [Station], journeys: [Journey], now: Date = .now,
                               timeZone: TimeZone = .current) -> [SpotlightEntry] {
        var seen = Set<String>()
        let all = favorites.map(station) + journeys.compactMap { journey($0, now: now, timeZone: timeZone) }
        return all.filter { seen.insert($0.id).inserted }
    }

    /// IDs of `previous` entries that `current` no longer has, to remove from the index.
    public static func removedIDs(previous: some Sequence<String>, current: [SpotlightEntry]) -> [String] {
        let kept = Set(current.map(\.id))
        return previous.filter { !kept.contains($0) }
    }

    /// The names the stations are shown and fed under, plus their RIL100 codes ("KK" for Köln Hbf).
    private static func keywords(for stations: [Station]) -> [String] {
        unique(stations.flatMap { station in [station.displayName, station.name, Ril100.code(for: station)].compactMap { $0 } })
    }

    private static func unique(_ words: [String]) -> [String] {
        var seen = Set<String>()
        return words.filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    /// "Fr 14:12" within the coming week, else with the date: "Fr 23.10. 14:12".
    static func departureText(_ date: Date, now: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 0
        // The weekday by hand: ICU writes "Fr." or "Fr" depending on its version.
        let weekday = weekdays[(calendar.component(.weekday, from: date) - 1) % 7]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = (-1...6).contains(days) ? "HH:mm" : "dd.MM. HH:mm"
        return weekday + " " + formatter.string(from: date)
    }

    private static let weekdays = ["So", "Mo", "Di", "Mi", "Do", "Fr", "Sa"]
}
