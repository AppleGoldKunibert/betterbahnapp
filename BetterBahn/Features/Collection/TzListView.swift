import BetterBahnKit
import SwiftUI

/// Opens the trips of one trainset (`TzRunsView`) from a Sammlung item, a Tz or a livery (#502).
struct TzRunsLink<Content: View>: View {
    let item: TravelCollection.Item
    let startsWithAll: Bool
    @ViewBuilder let label: Content

    var body: some View {
        NavigationLink {
            TzRunsView(number: item.unitNumber ?? 0, title: item.title, subtitle: item.subtitle,
                       rides: item.sightings, startsWithAll: startsWithAll)
        } label: {
            label
        }
    }
}

extension TzRunsLink where Content == Label<Text, Image> {
    /// The link under an opened Tz: "Alle Einsätze".
    init(item: TravelCollection.Item, startsWithAll: Bool) {
        self.init(item: item, startsWithAll: startsWithAll) {
            Label("Alle Einsätze", systemImage: "list.bullet")
        }
    }
}

/// The trains of one Tz: the ones you rode, and every train it ran as today and over the last year, from our
/// server's Tz log.
struct TzRunsView: View {
    let number: Int
    let title: String
    let subtitle: String?
    /// Your own rides with it; nil where they aren't known (the train search): then only "Alle" is shown.
    let rides: [TravelCollection.Sighting]?
    @State private var showsAll: Bool
    @State private var runs: [TzRun]?
    @State private var failed = false

    init(number: Int, title: String, subtitle: String?, rides: [TravelCollection.Sighting]?, startsWithAll: Bool) {
        self.number = number
        self.title = title
        self.subtitle = subtitle
        self.rides = rides
        _showsAll = State(initialValue: startsWithAll || rides == nil)
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.title3.weight(.semibold))
                    if let subtitle { Text(subtitle).foregroundStyle(.secondary) }
                }
                if rides != nil {
                    Picker("Fahrten", selection: $showsAll) {
                        Text("Meine").tag(false)
                        Text("Alle").tag(true)
                    }
                    .pickerStyle(.segmented)
                }
            }
            if showsAll {
                allRuns
            } else if let rides, rides.isEmpty {
                Section {
                    Text("Du bist mit diesem Triebzug noch nicht gefahren.").foregroundStyle(.secondary)
                }
            } else if let rides {
                Section("\(rides.count) Fahrten") {
                    ForEach(Array(rides.enumerated()), id: \.offset) { CollectionRideLink(sighting: $0.element) }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background { AppBackground() }
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
                        ForEach(day.value) { run in
                            NavigationLink { TzTrainRunView(run: run) } label: { RunRow(run: run) }
                        }
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
        if day == TzRun.day(of: Calendar.current.date(byAdding: .day, value: 1, to: .now) ?? .now) { return String(localized: "Morgen") }
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

/// The Zuglauf of a train a Tz ran as: the run is found by its number on that day like in the train search
/// (`TrainNumberSearch`) and shown like there (`TrainSearchResultView`: stops, Wagenreihung, map). Days that DB no
/// longer has say so.
struct TzTrainRunView: View {
    let run: TzRun
    @Environment(AppModel.self) private var model
    @State private var result: TrainSearchResult?
    @State private var missing = false
    @State private var failed = false

    var body: some View {
        Group {
            if let result {
                TrainSearchResultView(result: result)
            } else if missing {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Den Zuglauf von \(run.trainName) gibt es für diesen Tag nicht mehr.").font(.headline)
                    Text("DB hält die Fahrten nur für kurze Zeit vor.").font(.subheadline).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            } else if failed {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Der Zuglauf ist gerade nicht abrufbar.")
                    Button("Erneut versuchen") { Task { await load() } }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            } else {
                ProgressView().frame(maxWidth: .infinity).padding(.top, 60)
            }
        }
        .background { AppBackground() }
        .navigationTitle(run.trainName)
        .navigationBarTitleDisplayMode(.inline)
        .task { if result == nil && !missing { await load() } }
    }

    private func load() async {
        failed = false
        guard let finder = TrainNumberSearch(provider: model.provider) else {
            failed = true
            return
        }
        do {
            let found = try await finder.trains(TrainNumberQuery(category: run.category, number: run.number),
                                                on: run.date ?? .now, filter: TrainSearchFilter(countries: []))
            if let match = found.first(where: { $0.number == run.number && $0.category.uppercased() == run.category.uppercased() })
                ?? found.first {
                result = match
            } else {
                missing = true
            }
        } catch is CancellationError {
        } catch {
            failed = true
        }
    }
}
