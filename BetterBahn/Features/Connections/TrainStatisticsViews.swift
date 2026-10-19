import BetterBahnKit
import SwiftUI

/// A stop of a train the experience values are shown for (#316).
struct StatisticsStop: Hashable {
    enum Role: Hashable {
        /// Getting on here: how late the train usually leaves.
        case departure
        /// Getting off here, or any other stop: how late the train usually arrives.
        case arrival
    }

    var station: Station
    var role: Role
    /// The planned platform, to tell how likely another one is.
    var platform: String?
}

/// What past runs say about a train, as short lines: delays, cancellations and platform changes.
/// Only what has enough runs behind it (`TrainStatistics.minimumRuns`) shows up.
struct TrainStatisticsRows {
    struct Row: Identifiable {
        let id: Int
        let systemImage: String
        let text: String
        var detail: String?
        var tint: Color = .secondary
    }

    let rows: [Row]
    let subtitle: String

    init?(lookup: TrainStatisticsLookup?, stops: [StatisticsStop]) {
        guard let lookup else { return nil }
        var rows: [Row] = []
        func add(_ systemImage: String, _ text: String, detail: String? = nil, tint: Color = .secondary) {
            rows.append(Row(id: rows.count, systemImage: systemImage, text: text, detail: detail, tint: tint))
        }

        for stop in stops {
            guard let figures = lookup.stop(at: stop.station) else { continue }
            let name = stop.station.displayName
            let summary = stop.role == .departure ? figures.departureSummary() : figures.arrivalSummary()
            if let summary {
                let verb = stop.role == .departure ? "Abfahrt" : "Ankunft"
                add("clock.fill", "\(verb) in \(name): im Schnitt \(Self.minutes(summary.average)), \(Self.percentText(summary.onTimeShare)) pünktlich",
                    tint: delayColor(summary.average))
            }
            if let share = figures.cancelledShare, share >= 0.01, let text = Self.percent(share) {
                add("xmark.octagon.fill", "Fällt in \(name) bei \(text) der Fahrten aus", tint: share >= 0.1 ? .heavyDelay : .slightDelay)
            }
        }

        // The whole run cancelled only matters when no stop said it already.
        if !rows.contains(where: { $0.systemImage == "xmark.octagon.fill" }),
           let share = lookup.statistics.cancelledShare, let text = Self.percent(share), share >= 0.01 {
            add("xmark.octagon.fill", "Fällt bei \(text) der Fahrten aus", tint: share >= 0.1 ? .heavyDelay : .slightDelay)
        }

        if TrainStatistics.testMode { rows += Self.testRows(lookup: lookup, stops: stops, from: rows.count) }

        guard !rows.isEmpty else { return nil }
        self.rows = rows
        self.subtitle = "Letzte \(lookup.statistics.days) Tage · \(lookup.statistics.runs) Fahrten"
    }

    /// Test mode (launch argument `-debugstats`): what the app asked for and the raw values the server answered, per stop.
    static func testRows(lookup: TrainStatisticsLookup, stops: [StatisticsStop], from id: Int) -> [Row] {
        let statistics = lookup.statistics
        var rows = [Row(id: id, systemImage: "ladybug.fill",
                        text: "Test: \(statistics.category) \(statistics.number), \(statistics.runs) Fahrten, \(statistics.cancelledRuns) ganz ausgefallen")]
        for stop in stops {
            let name = stop.station.displayName
            guard let eva = lookup.eva(of: stop.station) else {
                rows.append(Row(id: id + rows.count, systemImage: "ladybug", text: "\(name): keine EVA-Nummer"))
                continue
            }
            guard let figures = lookup.stop(at: stop.station) else {
                rows.append(Row(id: id + rows.count, systemImage: "ladybug", text: "\(name) (\(eva)): keine Daten"))
                continue
            }
            let delays = { (values: [Int]) in values.isEmpty ? "–" : values.map { $0 >= 0 ? "+\($0)" : "\($0)" }.joined(separator: " ") }
            let platforms = figures.platforms.map { "\($0.from)→\($0.to) ×\($0.n)" }.joined(separator: ", ")
            rows.append(Row(id: id + rows.count, systemImage: "ladybug",
                            text: "\(name) (\(eva)): \(figures.runs) Fahrten, \(figures.cancelled) ausgefallen",
                            detail: "An \(delays(figures.arrival)) · Ab \(delays(figures.departure))" + (platforms.isEmpty ? "" : " · Gleis \(platforms)")))
        }
        return rows
    }

    /// "+6 min", "-1 min".
    static func minutes(_ value: Int) -> String { value >= 0 ? "+\(value) min" : "\(value) min" }

    /// "33 %".
    static func percentText(_ share: Double) -> String { "\(Int((share * 100).rounded())) %" }

    /// "33 %"; nil when it rounds to nothing.
    static func percent(_ share: Double) -> String? {
        Int((share * 100).rounded()) > 0 ? percentText(share) : nil
    }

    /// The text for a transfer the incoming train often misses, as how often it works: "Klappt 7 von 10 Mal"
    /// at the transfer itself, "Umstieg in Fulda klappt 7 von 10 Mal" with the transfer's `station`.
    static func transferWarning(station: String? = nil, outlook: TrainStatistics.Stop.TransferOutlook) -> String? {
        guard outlook.isRisky else { return nil }
        let works = Int(((1 - outlook.lateShare) * 10).rounded())
        let often = works > 0 ? "\(works) von 10 Mal" : "fast nie"
        guard let station else { return "Klappt \(often)" }
        return "Umstieg in \(station) klappt \(often)"
    }
}

/// "Gleiswechsel in 30 % der Fälle (meist Gleis 18 (67 %) / Gleis 19 (33 %))": only above 10 % and with at
/// most two platforms, each with its share of the changes. "meist Gleis 18" without a share when every
/// change went there. Shown where the platform matters (below the Wagenreihung, 30 minutes before a stop).
struct PlatformChangeHint: Hashable {
    let text: String
    let severe: Bool

    init?(outlook: TrainStatistics.Stop.PlatformOutlook?) {
        guard let outlook, outlook.changeShare > 0.1, let changed = TrainStatisticsRows.percent(outlook.changeShare) else { return nil }
        let onlyOne = outlook.alternatives.count == 1
        let others = outlook.alternatives.prefix(2).compactMap { option -> String? in
            if onlyOne { return "Gleis \(option.platform)" }
            return TrainStatisticsRows.percent(option.shareOfChanges).map { "Gleis \(option.platform) (\($0))" }
        }
        text = "Gleiswechsel in \(changed) der Fälle" + (others.isEmpty ? "" : " (meist \(others.joined(separator: " / ")))")
        severe = outlook.changeShare >= 0.3
    }
}

struct PlatformChangeLabel: View {
    let hint: PlatformChangeHint
    /// The station, when several are listed together.
    var station: String?

    var body: some View {
        Label(station.map { "\($0): \(hint.text)" } ?? hint.text, systemImage: "signpost.right.and.left.fill")
            .font(.caption)
            .foregroundStyle(hint.severe ? Color.heavyDelay : Color.slightDelay)
    }
}

/// "Erfahrungswerte" in a card's details: past runs of this train, see `TrainStatisticsRows`.
struct TrainStatisticsSection: View {
    let content: TrainStatisticsRows

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Label("Erfahrungswerte", systemImage: "chart.bar.fill")
                    .font(.caption.weight(.semibold))
                Text(content.subtitle).font(.caption2).foregroundStyle(.secondary)
            }
            ForEach(content.rows) { row in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: row.systemImage)
                        .font(.caption)
                        .foregroundStyle(row.tint)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.text).font(.caption)
                        if let detail = row.detail {
                            Text(detail).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// A warning line for a transfer the incoming train often misses.
struct TransferWarning: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.caption.weight(.semibold))
            .foregroundStyle(Color.slightDelay)
    }
}

/// Loads `TrainStatisticsStore` figures for the stops of a train and keeps the rows to show.
/// The EVA numbers of stations the feed gave none for come from bahn.de.
@MainActor
@Observable
final class TrainStatisticsModel {
    private(set) var rows: TrainStatisticsRows?
    private(set) var lookup: TrainStatisticsLookup?

    /// How likely the train uses another platform than `planned` at `station`, if that is worth saying.
    func platformChange(at station: Station, planned: String?) -> PlatformChangeHint? {
        PlatformChangeHint(outlook: lookup?.stop(at: station)?.platformOutlook(planned: planned))
    }

    func load(line: Line?, stops: [StatisticsStop], date: Date, bahnDe: BahnDeClient?) async {
        var resolve: TrainStatisticsStore.EVAResolver?
        if let bahnDe { resolve = { station in try? await bahnDe.evaNumber(for: station) } }
        let lookup = await TrainStatisticsStore.shared.lookup(line: line, at: stops.map(\.station), on: date, resolve: resolve)
        self.lookup = lookup
        rows = TrainStatisticsRows(lookup: lookup, stops: stops)
    }
}

extension TrainStatisticsModel {
    /// Warnings for the tight transfers of `journey` (at most `limit` planned minutes) whose incoming train
    /// is often too late, by the incoming leg's ID. `here` words them for the transfer's own row.
    static func transferWarnings(for journey: Journey, upTo limit: Int, here: Bool, bahnDe: BahnDeClient?) async -> [String: String] {
        let transfers = journey.tightTransfers(upTo: limit)
        guard !transfers.isEmpty else { return [:] }
        var resolve: TrainStatisticsStore.EVAResolver?
        if let bahnDe { resolve = { station in try? await bahnDe.evaNumber(for: station) } }
        let outlooks = await TrainStatisticsStore.shared.outlooks(for: transfers, resolve: resolve)
        var warnings: [String: String] = [:]
        for transfer in transfers {
            guard let outlook = outlooks[transfer.id],
                  let text = TrainStatisticsRows.transferWarning(station: here ? nil : transfer.station.displayName, outlook: outlook)
            else { continue }
            warnings[transfer.id] = text
        }
        return warnings
    }
}
