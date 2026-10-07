import BetterBahnKit
import Foundation

/// The date ranges the travel map offers.
enum TravelMapRange: String, CaseIterable, Identifiable, Hashable {
    case week = "7 Tage", month = "30 Tage", year = "1 Jahr", all = "Alle", custom = "Eigene"
    var id: String { rawValue }

    /// Warmed at launch in this order: what the map opens with first, then the wider ranges.
    /// `.custom` has no fixed range to warm.
    static let prewarmOrder: [TravelMapRange] = [.month, .week, .year, .all]

    var days: Int? {
        switch self {
        case .week: 7
        case .month: 30
        case .year: 365
        case .all, .custom: nil
        }
    }
}

/// What the travel map shows: a date range plus the two source toggles. Shared by the map view and
/// by the prewarm at app start, so both select the same journeys and agree on the cache key.
struct TravelMapSelection: Hashable {
    var range: TravelMapRange = .month
    /// Only set while `range` is `.custom`; the defaults are derived from "now" and would otherwise
    /// change the cache key (and so throw the cache away) on every app launch.
    var customFrom: Date?
    var customTo: Date?
    var includeSaved = true
    var includeTraewelling = true

    var interval: DateInterval? {
        let calendar = Calendar.current
        switch range {
        case .all:
            return nil
        case .custom:
            let from = customFrom ?? .now, to = customTo ?? .now
            let start = calendar.startOfDay(for: min(from, to))
            let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: max(from, to)))!
            return DateInterval(start: start, end: end)
        default:
            // Up to the end of today, so today's saved trips are included.
            let endOfToday = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: .now))!
            let start = calendar.date(byAdding: .day, value: -(range.days ?? 0), to: .now)!
            return DateInterval(start: start, end: endOfToday)
        }
    }
}

extension AppModel {
    /// Saved journeys and Träwelling check-ins in the selected range. A ride that's both saved in
    /// the app and checked in on Träwelling, or checked in twice, counts once (see `RideMatch`):
    /// the check-in wins, so saved journeys only add the legs nobody checked in.
    func mapJourneys(for selection: TravelMapSelection) -> [Journey] {
        let checkins = selection.includeTraewelling ? RideMatch.deduplicated(checkins(in: selection.interval)) : []
        let saved = selection.includeSaved ? uncheckedJourneys(in: selection.interval) : []
        return saved + checkins
    }

    /// Saved train rides already travelled that no Träwelling check-in covers, newest first: what
    /// turning "Gespeichert" on adds to the map. Settings lists them so missing check-ins can be found.
    func uncheckedRides(in interval: DateInterval?) -> [Leg] {
        travelledLegs(of: uncheckedJourneys(in: interval)).map(\.leg).sorted { $0.departure.planned > $1.departure.planned }
    }

    private func checkins(in interval: DateInterval?) -> [Journey] {
        traewellingTrips.map(\.journey).filter { Self.departs($0, in: interval) }
    }

    /// Matched against every check-in, duplicates included: even one that isn't drawn proves that
    /// train was ridden then (e.g. the first version of a check-in redone or edited since).
    private func uncheckedJourneys(in interval: DateInterval?) -> [Journey] {
        // Filtered before matching: `uncovered` drops legs, which can move a journey's departure.
        RideMatch.uncovered(savedJourneys.map(\.journey).filter { Self.departs($0, in: interval) },
                            by: checkins(in: interval))
    }

    private static func departs(_ journey: Journey, in interval: DateInterval?) -> Bool {
        guard let interval else { return true }
        guard let departure = journey.departure?.planned else { return false }
        return interval.contains(departure)
    }

    /// The train legs of these journeys that have actually been ridden: a leg counts once it has
    /// arrived (delay included), even while the rest of its journey is still ahead.
    func travelledLegs(of journeys: [Journey]) -> [(leg: Leg, group: Int)] {
        journeys.enumerated().flatMap { index, journey in
            journey.transitLegs
                .filter { ($0.line?.product.isTrain ?? true) && $0.arrival.best <= .now }
                .map { (leg: $0, group: index) }
        }
    }

    /// Identifies everything a heatmap depends on, so unrelated view re-creations (e.g. switching
    /// tabs) don't invalidate the cached result.
    func mapHeatmapKey(for selection: TravelMapSelection) -> String {
        let custom = selection.range == .custom
            ? "\(selection.customFrom?.timeIntervalSince1970 ?? 0)|\(selection.customTo?.timeIntervalSince1970 ?? 0)"
            : ""
        // Bumped whenever the heatmap is built differently, so results cached by an older build
        // (with grid-snapped lines or the old duplicate matching) aren't shown again.
        let version = "v7"
        let legs = travelledLegs(of: mapJourneys(for: selection)).map(\.leg)
        // A check-in edited on Träwelling (another exit) changes no count, but its arrival.
        let arrivals = legs.reduce(0) { $0 &+ Int($1.arrival.planned.timeIntervalSince1970) }
        return "\(version)|\(selection.range.rawValue)|\(custom)|\(savedJourneys.count)|\(traewellingTrips.count)|\(legs.count)|\(arrivals)|\(selection.includeSaved)|\(selection.includeTraewelling)"
    }

    /// The finished heatmap for a selection, from the cache when possible.
    ///
    /// Legs whose track geometry is already cached are decoded and merged in one batch off the main
    /// thread; only the rest is loaded one by one, which may hit the network. Callers can follow
    /// along: `onProgress` reports how many legs are done and `onPartial` hands out a usable
    /// heatmap as more arrive. Pass `progressively: false` to skip the intermediate results — the
    /// background prewarm doesn't need them and they aren't free.
    func mapHeatmap(for selection: TravelMapSelection, progressively: Bool = true,
                    onProgress: (Int, Int) -> Void = { _, _ in },
                    onPartial: ([SegmentHeatmap.Run]) -> Void = { _ in }) async -> MapHeatmap? {
        // Otherwise a map opened right after launch would be built (and cached) without them.
        await loadTraewellingTrips()
        let key = mapHeatmapKey(for: selection)
        if let cached = await cachedMapHeatmap(for: key) { return cached }

        let journeys = mapJourneys(for: selection)
        let entries = travelledLegs(of: journeys)
        let legs = entries.map(\.leg)
        onProgress(0, legs.count)

        // Everything already on disk in one go, so the common case (reopening the map) never walks
        // a few hundred legs on the main actor.
        let (cachedLines, missing) = await cachedGeometries(for: legs)
        guard !Task.isCancelled else { return nil }
        var lines = cachedLines.map(\.coordinates)
        onProgress(legs.count - missing.count, legs.count)
        if progressively, !lines.isEmpty, !missing.isEmpty {
            onPartial(await runs(for: lines, priority: .userInitiated))
            guard !Task.isCancelled else { return nil }
        }

        // The rest has to be fetched; these calls really do suspend, so the UI stays responsive.
        var lastPartial = ContinuousClock.now
        for (index, leg) in missing.enumerated() {
            if Task.isCancelled { return nil }
            if let geometry = await geometry(for: leg) { lines.append(geometry) }
            onProgress(legs.count - missing.count + index + 1, legs.count)
            // Refresh every so often so the map fills in, but on a clock rather than every n legs:
            // each rebuild costs more as the history grows, and they'd otherwise pile up.
            if progressively, lastPartial.duration(to: .now) > .seconds(2) {
                lastPartial = .now
                onPartial(await runs(for: lines, priority: .userInitiated))
                guard !Task.isCancelled else { return nil }
            }
        }
        guard !Task.isCancelled else { return nil }

        let merged = await runs(for: lines, priority: progressively ? .userInitiated : .utility)
        guard !Task.isCancelled else { return nil }
        let kilometers = await Task.detached(priority: .utility) { [lines] in
            lines.reduce(0.0) { $0 + Polyline.length($1) / 1000 }
        }.value
        let hours = legs.reduce(0) { $0 + $1.arrival.best.timeIntervalSince($1.departure.best) } / 3600
        let heatmap = MapHeatmap(runs: merged, journeysCount: Set(entries.map(\.group)).count, legsCount: legs.count,
                                 kilometers: kilometers, hours: hours)
        await setCachedMapHeatmap(heatmap, for: key)
        return heatmap
    }

    private func runs(for lines: [[Coordinate]], priority: TaskPriority) async -> [SegmentHeatmap.Run] {
        await Task.detached(priority: priority) { SegmentHeatmap().runs(for: lines) }.value
    }
}
