import BetterBahnKit
import SwiftUI

/// Finds a train by its number (#183) and offers its train view, Wagenreihung and live map.
/// Opened from the train button on Verbindungen and the search button on the map.
struct TrainSearchSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var date = Date.now
    /// What was last searched for; changing it starts a new search (and cancels the running one).
    @State private var submitted: Submitted?
    @State private var results: [TrainSearchResult]?
    @State private var searching = false
    @State private var error: Error?
    @FocusState private var focused: Bool

    private struct Submitted: Equatable {
        var query: TrainNumberQuery
        var day: String
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Card { input }
                    if searching {
                        ProgressView("Suche Züge …")
                            .frame(maxWidth: .infinity)
                            .padding()
                    } else if let error {
                        ErrorBanner(error: error)
                    } else if let results {
                        if results.isEmpty {
                            Text("Kein Zug mit dieser Nummer an diesem Tag gefunden.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 4)
                        } else {
                            SectionHeader(title: results.count == 1 ? "Zug" : "\(results.count) Züge", systemImage: "tram.fill")
                            ForEach(results) { result in
                                NavigationLink(value: result) {
                                    TrainSearchRow(result: result)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding()
            }
            .scrollDismissesKeyboard(.interactively)
            .background { AppBackground() }
            .navigationTitle("Zug suchen")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: TrainSearchResult.self) { TrainSearchResultView(result: $0) }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Schließen", systemImage: "xmark", role: .cancel) { dismiss() }
                }
            }
            .onAppear { focused = true }
            .onChange(of: date) {
                if submitted != nil { submit() }
            }
            .task(id: submitted) { await search() }
        }
    }

    private var input: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                IconTile(systemImage: "number", color: .brand, size: 38)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Zugnummer").font(.headline)
                    Text("Fernzüge, Regionalzüge und S-Bahnen")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            TextField("z. B. ICE 123 oder 37856", text: $text)
                .font(.title3.weight(.semibold))
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused($focused)
                .onSubmit(submit)
                .padding(12)
                .background(Color.secondary.opacity(0.1), in: .rect(cornerRadius: 12, style: .continuous))
            DatePicker("Tag", selection: $date, displayedComponents: .date)
                .font(.subheadline)
            Button(action: submit) {
                Label("Suchen", systemImage: "magnifyingglass")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .tint(.brand)
            .controlSize(.large)
            .disabled(TrainNumberQuery(text) == nil)
        }
    }

    private func submit() {
        guard let query = TrainNumberQuery(text) else { return }
        focused = false
        submitted = Submitted(query: query, day: BahnDeClient.berlinDay(date))
    }

    private func search() async {
        guard let submitted, let finder = TrainNumberSearch(provider: model.provider) else { return }
        searching = true
        error = nil
        defer { if !Task.isCancelled { searching = false } }
        do {
            let found = try await finder.trains(submitted.query, on: date)
            guard !Task.isCancelled else { return }
            results = found
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled else { return }
            results = nil
            self.error = error
        }
    }
}

/// One train found by its number: what it is and where it runs.
private struct TrainSearchRow: View {
    let result: TrainSearchResult

    var body: some View {
        Card {
            HStack(spacing: 12) {
                IconTile(systemImage: result.product.symbolName, color: result.product.color, size: 38)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(result.name).font(.headline)
                        if let line = result.lineName {
                            InfoChip(text: line, systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                        }
                    }
                    Text("\(result.origin) → \(result.destination)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

/// What can be done with a train found by its number: its stops (to save the journey and check in),
/// its Wagenreihung and, while bahn.jetzt has it, its live position on the map.
struct TrainSearchResultView: View {
    let result: TrainSearchResult

    @Environment(AppModel.self) private var model
    @State private var entry: BoardEntry?
    @State private var trip: Trip?
    @State private var error: Error?
    /// bahn.de's sequence for the next stops, else vagonweb's plan; nil while checking or without one.
    @State private var sequence: CoachSequence?
    @State private var checkedSequence = false
    /// nil while checking.
    @State private var hasLivePosition: Bool?
    @State private var showSequence = false
    @State private var showMap = false

    private var color: Color { trip?.line?.product.color ?? result.product.color }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if let error {
                    ErrorBanner(error: error)
                } else if let entry, let trip {
                    options(entry: entry, trip: trip)
                } else {
                    ProgressView("Lade Fahrt …")
                        .frame(maxWidth: .infinity)
                        .padding()
                }
            }
            .padding()
        }
        .background { AppBackground() }
        .navigationTitle(result.name)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showSequence) {
            if let trip, let request = sequenceRequest(for: trip) {
                CoachSequenceView(request: request, trainName: trip.line?.name, sequence: sequence)
            }
        }
        .sheet(isPresented: $showMap) {
            if let trip {
                LiveTrainMapView(route: LiveTrainRoute(trip: trip))
            }
        }
        .task { await load() }
        .task(id: trip?.id) { await checkSequence() }
        .task(id: trip?.id) { await checkLivePosition() }
    }

    private var header: some View {
        Card {
            HStack(spacing: 12) {
                IconTile(systemImage: (trip?.line?.product ?? result.product).symbolName, color: color, size: 46)
                VStack(alignment: .leading, spacing: 3) {
                    if let trip {
                        TrainNameRow(name: trip.line?.nameWithTripNumber ?? result.name, font: .title3.weight(.bold), spacing: 8) {
                            TrainSeriesTag(trip: trip, savedLeg: nil)
                        }
                    } else {
                        Text(result.name).font(.title3.weight(.bold))
                    }
                    Text("\(trip?.origin?.displayName ?? result.origin) → \(trip?.destination?.displayName ?? result.destination)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if let departure = trip?.stopovers.lazy.compactMap(\.departure).first?.planned {
                        Text(departure.formatted(.dateTime.weekday(.wide).day().month().hour().minute()))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    @ViewBuilder
    private func options(entry: BoardEntry, trip: Trip) -> some View {
        NavigationLink {
            TripView(entry: entry, selectsStation: false)
        } label: {
            OptionRow(title: "Zugdetails anzeigen", subtitle: "Alle Halte; Ein- und Ausstieg wählen, um die Fahrt zu speichern",
                      systemImage: "list.bullet.rectangle.portrait", color: .brand)
        }
        .buttonStyle(.plain)

        if let sequence, !sequence.coaches.isEmpty {
            Button {
                showSequence = true
            } label: {
                OptionRow(title: sequence.source == .bahnDe ? "Wagenreihung" : "Plan-Wagenreihung",
                          subtitle: "Wagen, Klassen und Ausstattung",
                          systemImage: "train.side.front.car", color: .brand)
            }
            .buttonStyle(.plain)
        } else if !checkedSequence {
            OptionRow(title: "Wagenreihung", subtitle: "Wird gesucht …", systemImage: "train.side.front.car",
                      color: .secondary, loading: true)
        } else {
            OptionRow(title: "Wagenreihung", subtitle: "Für diesen Zug gibt es keine Wagenreihung.",
                      systemImage: "train.side.front.car", color: .secondary, showsChevron: false)
        }

        switch hasLivePosition {
        case true?:
            Button {
                showMap = true
            } label: {
                OptionRow(title: "Auf Karte zeigen", subtitle: "Wo der Zug gerade ist",
                          systemImage: "location.fill", color: .brand)
            }
            .buttonStyle(.plain)
        case nil:
            OptionRow(title: "Auf Karte zeigen", subtitle: "Live-Position wird gesucht …", systemImage: "location.fill",
                      color: .secondary, loading: true)
        case false?:
            EmptyView()
        }
    }

    private func load() async {
        guard trip == nil, let finder = TrainNumberSearch(provider: model.provider) else { return }
        do {
            let run = try await finder.run(of: result)
            entry = run.entry
            trip = run.trip
        } catch is CancellationError {
        } catch {
            self.error = error
        }
    }

    private func sequenceRequest(for trip: Trip) -> BahnDeClient.FormationRequest? {
        BahnDeClient.formationRequest(for: trip) ?? BahnDeClient.formationRequest(for: trip, lookahead: nil)
    }

    /// The same lookup as `CoachSequenceButton`: bahn.de's sequence within its lookahead, else the plan.
    private func checkSequence() async {
        guard let trip else { return }
        sequence = nil
        checkedSequence = false
        if let request = BahnDeClient.formationRequest(for: trip),
           let live = try? await model.coachSequence(for: request), !live.coaches.isEmpty {
            sequence = live
        } else if let planned = BahnDeClient.formationRequest(for: trip, lookahead: nil) {
            sequence = await model.plannedCoachSequence(for: planned)
        }
        guard !Task.isCancelled else { return }
        checkedSequence = true
    }

    /// Asks again now and then, like `LiveTrainIconTile`: a train only shows up in bahn.jetzt's list once it runs.
    private func checkLivePosition() async {
        guard let trip else { return }
        let route = LiveTrainRoute(trip: trip)
        guard route.isSupported else {
            hasLivePosition = false
            return
        }
        while !Task.isCancelled {
            if route.mayBeRunning() {
                let found = (try? await model.livePosition(of: route)) != nil
                guard !Task.isCancelled else { return }
                hasLivePosition = found
                if found { return }
            } else {
                hasLivePosition = false
                if Date.now > route.end { return }
            }
            try? await Task.sleep(for: .seconds(120))
        }
    }
}

/// A tappable option on `TrainSearchResultView`.
private struct OptionRow: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let color: Color
    var loading = false
    var showsChevron = true

    var body: some View {
        Card {
            HStack(spacing: 12) {
                IconTile(systemImage: systemImage, color: color, size: 38)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                        .foregroundStyle(color == .secondary ? .secondary : .primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if loading {
                    ProgressView().controlSize(.small)
                } else if showsChevron {
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }
}
