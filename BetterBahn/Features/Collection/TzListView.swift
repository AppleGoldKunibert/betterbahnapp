import BetterBahnKit
import SwiftUI

/// Every ICE and IC trainset ("Tz", #502) with the train it runs today, from our server's Tz log. Opened from
/// the Sammlung; a Tz you have ridden is marked.
struct TzListView: View {
    let collection: TravelCollection?
    @State private var units: [TzUnit]?
    @State private var failed = false
    @State private var search = ""
    @State private var series: String?

    var body: some View {
        List {
            if let units {
                if units.isEmpty {
                    Text("Unser Server sammelt die Züge erst seit Kurzem. Die Liste füllt sich nach und nach.")
                        .foregroundStyle(.secondary)
                } else {
                    Section {
                        ForEach(filtered(units)) { unit in
                            NavigationLink {
                                TzRunsView(number: unit.number ?? 0, title: title(of: unit), subtitle: subtitle(of: unit),
                                           rides: rides(of: unit), startsWithAll: true)
                            } label: {
                                TzRow(unit: unit, rides: rides(of: unit).count)
                            }
                        }
                    } footer: {
                        Text("Nur ICE und IC. Der Verlauf reicht ein Jahr zurück.")
                    }
                }
            } else if failed {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Die Liste ist gerade nicht verfügbar.")
                    Button("Erneut versuchen") { Task { await load() } }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .navigationTitle("Alle Triebzüge")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "Tz, Name oder Zug")
        .toolbar {
            if let units, !seriesNames(units).isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu("Baureihe", systemImage: "line.3.horizontal.decrease") {
                        Picker("Baureihe", selection: $series) {
                            Text("Alle").tag(String?.none)
                            ForEach(seriesNames(units), id: \.self) { Text($0).tag(Optional($0)) }
                        }
                    }
                }
            }
        }
        .tabBarSafePadding()
        .task { if units == nil { await load() } }
    }

    private func load() async {
        failed = false
        do {
            units = try await TzLogClient().units()
        } catch {
            failed = true
        }
    }

    private func rides(of unit: TzUnit) -> [TravelCollection.Sighting] {
        unit.number.flatMap { collection?.unitSightings[$0] } ?? []
    }

    private func title(of unit: TzUnit) -> String { String(localized: "Tz \(unit.tz)") }

    private func subtitle(of unit: TzUnit) -> String? {
        [unit.series, unit.name, unit.livery].compactMap(\.self).joined(separator: " · ").nilIfEmpty
    }

    private func seriesNames(_ units: [TzUnit]) -> [String] {
        Array(Set(units.compactMap(\.series))).sorted()
    }

    private func filtered(_ units: [TzUnit]) -> [TzUnit] {
        let query = search.trimmingCharacters(in: .whitespaces)
        return units.filter { unit in
            if let series, unit.series != series { return false }
            guard !query.isEmpty else { return true }
            let haystack = [unit.tz, unit.series, unit.name, unit.livery].compactMap(\.self)
                + unit.trains.map(\.trainName) + unit.trains.map { String($0.number) }
            return haystack.contains { $0.localizedStandardContains(query) }
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

private struct TzRow: View {
    let unit: TzUnit
    let rides: Int

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("Tz \(unit.tz)").font(.headline)
                    if rides > 0 {
                        Image(systemName: "checkmark.seal.fill").foregroundStyle(Color.brand)
                            .accessibilityLabel("Schon gefahren")
                    }
                }
                if let detail = [unit.series, unit.name, unit.livery].compactMap(\.self).joined(separator: " · ").nilIfEmpty {
                    Text(detail).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 2) {
                if unit.lastDay == TzRun.day(), let first = unit.trains.first {
                    Text(first.trainName).font(.subheadline.weight(.semibold))
                    if unit.trains.count > 1 {
                        Text("+\(unit.trains.count - 1)").font(.caption).foregroundStyle(.secondary)
                    }
                } else if let date = unit.trains.first?.date {
                    Text("zuletzt \(date.formatted(.dateTime.day().month()))").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// The trains of one Tz: the ones you rode, and every train it ran as today and over the last year.
struct TzRunsView: View {
    let number: Int
    let title: String
    let subtitle: String?
    let rides: [TravelCollection.Sighting]
    @State var startsWithAll: Bool
    @State private var runs: [TzRun]?
    @State private var failed = false

    init(number: Int, title: String, subtitle: String?, rides: [TravelCollection.Sighting], startsWithAll: Bool) {
        self.number = number
        self.title = title
        self.subtitle = subtitle
        self.rides = rides
        _startsWithAll = State(initialValue: startsWithAll)
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.title3.weight(.semibold))
                    if let subtitle { Text(subtitle).foregroundStyle(.secondary) }
                }
                Picker("Fahrten", selection: $startsWithAll) {
                    Text("Meine").tag(false)
                    Text("Alle").tag(true)
                }
                .pickerStyle(.segmented)
            }
            if startsWithAll {
                allRuns
            } else if rides.isEmpty {
                Section {
                    Text("Du bist mit diesem Triebzug noch nicht gefahren.").foregroundStyle(.secondary)
                }
            } else {
                Section("\(rides.count) Fahrten") {
                    ForEach(Array(rides.enumerated()), id: \.offset) { SightingRow(sighting: $0.element) }
                }
            }
        }
        .navigationTitle("Fahrten")
        .navigationBarTitleDisplayMode(.inline)
        .task { if runs == nil { await load() } }
    }

    @ViewBuilder private var allRuns: some View {
        if let runs {
            if runs.isEmpty {
                Section {
                    Text("Dieser Triebzug ist unserem Server noch nicht aufgefallen.").foregroundStyle(.secondary)
                }
            } else {
                let days = Dictionary(grouping: runs, by: \.day).sorted { $0.key > $1.key }
                ForEach(Array(days.enumerated()), id: \.element.key) { index, day in
                    Section(header: Text(header(for: day.key, first: index == 0))) {
                        ForEach(day.value) { RunRow(run: $0) }
                    }
                }
            }
        } else if failed {
            Section {
                Text("Der Verlauf ist gerade nicht verfügbar.")
                Button("Erneut versuchen") { Task { await load() } }
            }
        } else {
            Section { ProgressView().frame(maxWidth: .infinity) }
        }
    }

    private func header(for day: String, first: Bool) -> String {
        if day == TzRun.day() { return String(localized: "Heute") }
        let date = TzRun(day: day, category: "", number: 0).date?.formatted(date: .long, time: .omitted) ?? day
        return first ? String(localized: "Zuletzt am \(date)") : date
    }

    private func load() async {
        failed = false
        do {
            runs = try await TzLogClient().history(of: String(number))
        } catch {
            failed = true
        }
    }
}

private struct RunRow: View {
    let run: TzRun

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(run.trainName).font(.subheadline.weight(.semibold))
            if let destination = run.destination {
                Text("nach \(destination)").font(.subheadline).foregroundStyle(.secondary)
            }
            if run.changedFromPlan {
                Text("Kurzfristig getauscht").font(.caption).foregroundStyle(.orange)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
