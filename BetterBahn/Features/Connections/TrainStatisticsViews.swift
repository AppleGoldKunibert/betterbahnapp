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

/// What past runs say about a train, as short lines: delays, cancellations, platform changes and
/// vehicles. Only what has enough runs behind it (`TrainStatistics.minimumRuns`) shows up.
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
            if let outlook = figures.platformOutlook(planned: stop.platform) {
                let planned = "Gl. \(stop.platform ?? "")"
                if outlook.changeShare >= 0.01, let changed = Self.percent(outlook.changeShare) {
                    let others = outlook.alternatives.prefix(3).compactMap { option in
                        Self.percent(option.share).map { "Gl. \(option.platform) (\($0))" }
                    }
                    add("signpost.right.and.left.fill", "Gleiswechsel in \(name) bei \(changed) der Fahrten",
                        detail: others.isEmpty ? nil : "Statt \(planned) meist \(others.joined(separator: ", "))",
                        tint: outlook.changeShare >= 0.3 ? .heavyDelay : .slightDelay)
                } else {
                    add("signpost.right.fill", "Gleis in \(name) war bisher immer wie geplant", tint: .punctual)
                }
            }
        }

        // The whole run cancelled only matters when no stop said it already.
        if !rows.contains(where: { $0.systemImage == "xmark.octagon.fill" }),
           let share = lookup.statistics.cancelledShare, let text = Self.percent(share), share >= 0.01 {
            add("xmark.octagon.fill", "Fällt bei \(text) der Fahrten aus", tint: share >= 0.1 ? .heavyDelay : .slightDelay)
        }

        if let vehicles = lookup.statistics.varyingVehicles {
            let shares = vehicles.prefix(3).compactMap { vehicle in
                Self.percent(lookup.statistics.share(of: vehicle)).map { "\(vehicle.name) (\($0))" }
            }
            if shares.count > 1 { add("tram.fill", "Fahrzeug: \(shares.joined(separator: ", "))") }
        }

        guard !rows.isEmpty else { return nil }
        self.rows = rows
        self.subtitle = "Letzte \(lookup.statistics.days) Tage · \(lookup.statistics.runs) Fahrten"
    }

    /// "+6 min", "-1 min".
    static func minutes(_ value: Int) -> String { value >= 0 ? "+\(value) min" : "\(value) min" }

    /// "33 %".
    static func percentText(_ share: Double) -> String { "\(Int((share * 100).rounded())) %" }

    /// "33 %"; nil when it rounds to nothing.
    static func percent(_ share: Double) -> String? {
        Int((share * 100).rounded()) > 0 ? percentText(share) : nil
    }

    /// The text for a transfer the incoming train often misses: "ICE 578 kommt in Fulda bei 33 % der Fahrten zu spät für den Umstieg."
    static func transferWarning(line: Line?, place: String, outlook: TrainStatistics.Stop.TransferOutlook) -> String? {
        guard outlook.isRisky, let share = percent(outlook.lateShare) else { return nil }
        return "\(line?.name ?? "Der Zug") kommt \(place) bei \(share) der Fahrten zu spät für den Umstieg."
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

    func load(line: Line?, stops: [StatisticsStop], date: Date, bahnDe: BahnDeClient?) async {
        var resolve: TrainStatisticsStore.EVAResolver?
        if let bahnDe { resolve = { station in try? await bahnDe.evaNumber(for: station) } }
        let lookup = await TrainStatisticsStore.shared.lookup(line: line, at: stops.map(\.station), on: date, resolve: resolve)
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
                  let text = TrainStatisticsRows.transferWarning(line: transfer.line, place: here ? "hier" : "in \(transfer.station.displayName)", outlook: outlook)
            else { continue }
            warnings[transfer.id] = text
        }
        return warnings
    }
}
